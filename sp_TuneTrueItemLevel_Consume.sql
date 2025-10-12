CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_TuneTrueItemLevel_ConsumeQueue`(
  IN p_limit INT UNSIGNED   -- how many queued rows to process this run (NULL/0 = all)
)
BEGIN
  /* --- constants matching estimator --- */
  SET @W_PRIMARY := 230;

  /* slot modifiers by InventoryType */
  DROP TEMPORARY TABLE IF EXISTS tmp_slotmods;
  CREATE TEMPORARY TABLE tmp_slotmods(inv TINYINT PRIMARY KEY, slotmod DOUBLE) ENGINE=Memory;
  INSERT INTO tmp_slotmods(inv,slotmod) VALUES
    (1,1.00),(5,1.00),(20,1.00),(7,1.00),
    (3,1.35),(10,1.35),(6,1.35),(8,1.35),
    (12,1.47),
    (9,1.85),(2,1.85),(16,1.85),(11,1.85),
    (17,1.00),
    (13,2.44),(21,2.44),
    (14,1.92),(22,1.92),(23,1.92),
    (15,3.33),(26,3.33),(25,3.33);

  /* inverse quality curves: ISV = a*ilvl + b */
  DROP TEMPORARY TABLE IF EXISTS tmp_qcurve;
  CREATE TEMPORARY TABLE tmp_qcurve(quality TINYINT PRIMARY KEY, a DOUBLE, b DOUBLE) ENGINE=Memory;
  INSERT INTO tmp_qcurve VALUES
    (2, 1.21, -9.8),   -- green
    (3, 1.42, -4.2),   -- blue
    (4, 1.64, 11.2);   -- epic

  /* run log */
  CREATE TABLE IF NOT EXISTS helper.tune_ilvl_log (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    entry INT UNSIGNED NOT NULL,
    action ENUM('SKIP','CRUNCH','EXPAND','ERROR') NOT NULL,
    from_ilvl INT, to_ilvl INT,
    details VARCHAR(255),
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
  ) ENGINE=InnoDB;

  /* materialize the worklist now (do NOT iterate the live table) */
  DROP TEMPORARY TABLE IF EXISTS tmp_work;
  CREATE TEMPORARY TABLE tmp_work(
    entry INT UNSIGNED PRIMARY KEY,
    target_ilvl INT UNSIGNED,
    mode ENUM('auto','crunch','expand'),
    apply_change TINYINT(1)
  ) ENGINE=Memory;

  IF IFNULL(p_limit,0) = 0 THEN
    INSERT INTO tmp_work(entry,target_ilvl,mode,apply_change)
    SELECT entry,target_ilvl,mode,apply_change
    FROM helper.tune_queue
    WHERE status='queued';
  ELSE
    INSERT INTO tmp_work(entry,target_ilvl,mode,apply_change)
    SELECT entry,target_ilvl,mode,apply_change
    FROM helper.tune_queue
    WHERE status='queued'
    ORDER BY updated_at, entry
    LIMIT p_limit;
  END IF;

  /* cursor block */
  BEGIN
    DECLARE v_entry INT UNSIGNED;
    DECLARE v_target INT UNSIGNED;
    DECLARE v_mode ENUM('auto','crunch','expand');
    DECLARE v_apply TINYINT(1);

    DECLARE v_ilvl INT;
    DECLARE v_quality TINYINT;
    DECLARE v_inv TINYINT;
    DECLARE v_slotmod DOUBLE;
    DECLARE v_isv_cur DOUBLE; DECLARE v_isv_tgt DOUBLE;
    DECLARE v_itemval_cur DOUBLE; DECLARE v_itemval_tgt DOUBLE;
    DECLARE v_sum_cur DOUBLE; DECLARE v_sum_tgt DOUBLE; DECLARE v_delta_sum DOUBLE;

    DECLARE done INT DEFAULT 0;

    DECLARE cur CURSOR FOR
      SELECT entry,target_ilvl,mode,apply_change FROM tmp_work ORDER BY entry;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    /* per-item exception -> mark error, continue */
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
      UPDATE helper.tune_queue SET status='error', note='Exception during tune'
      WHERE entry = v_entry;
      INSERT INTO helper.tune_ilvl_log(entry,action,details) VALUES (IFNULL(v_entry,0),'ERROR','exception');
    END;

    OPEN cur;
    itemloop: LOOP
      FETCH cur INTO v_entry, v_target, v_mode, v_apply;
      IF done THEN LEAVE itemloop; END IF;

      UPDATE helper.tune_queue SET status='processing', note=NULL WHERE entry=v_entry;

      /* basics */
      SELECT CAST(trueItemLevel AS SIGNED), Quality, InventoryType
      INTO v_ilvl, v_quality, v_inv
      FROM lplusworld.item_template WHERE entry=v_entry;

      IF v_quality NOT IN (2,3,4) THEN
        UPDATE helper.tune_queue SET status='error', note='Unsupported quality' WHERE entry=v_entry;
        INSERT INTO helper.tune_ilvl_log(entry,action,from_ilvl,to_ilvl,details)
        VALUES (v_entry,'SKIP',v_ilvl,v_target,'unsupported quality');
        ITERATE itemloop;
      END IF;

      /* inverse curves */
      SELECT a,b INTO @qa,@qb FROM tmp_qcurve WHERE quality=v_quality;
      SET v_slotmod := IFNULL((SELECT slotmod FROM tmp_slotmods WHERE inv=v_inv),1.00);

      /* map ilvl -> current/tgt “sum” (pre 2/3 power) */
      SET v_isv_cur := @qa * v_ilvl   + @qb;
      SET v_isv_tgt := @qa * v_target + @qb;
      SET v_itemval_cur := v_isv_cur / v_slotmod;
      SET v_itemval_tgt := v_isv_tgt / v_slotmod;
      SET v_sum_cur := POW(v_itemval_cur*100.0, 1.5);
      SET v_sum_tgt := POW(v_itemval_tgt*100.0, 1.5);
      SET v_delta_sum := v_sum_tgt - v_sum_cur;

      /* choose direction */
      SET @dir :=
        CASE
          WHEN v_mode='crunch' THEN 'crunch'
          WHEN v_mode='expand' THEN 'expand'
          ELSE CASE WHEN v_ilvl > v_target THEN 'crunch' ELSE 'expand' END
        END;

      /* ---------------- CRUNCH ---------------- */
      IF @dir='crunch' THEN
        SET @iters := 0;
        WHILE v_ilvl > v_target AND @iters < 6 DO
          CALL helper.sp_ReforgeItemBudget(
            v_entry,
            'SPI,RESIST,SDONE,HEAL,MP5,HP5,BONUSARMOR',  -- remove soft/caster budget first
            '', 'dump', v_apply, 'NONE'
          );
          IF v_apply=1 THEN CALL helper.sp_EstimateItemLevels(); END IF;
          SELECT CAST(trueItemLevel AS SIGNED) INTO v_ilvl
          FROM lplusworld.item_template WHERE entry=v_entry;
          SET @iters := @iters + 1;
        END WHILE;

        INSERT INTO helper.tune_ilvl_log(entry,action,from_ilvl,to_ilvl,details)
        VALUES (v_entry,'CRUNCH',NULL,v_target,CONCAT('iters=',@iters));

      /* ---------------- EXPAND ---------------- */
      ELSE
        /* Read current 10 stat slots */
        SELECT stat_type1,stat_value1,stat_type2,stat_value2,stat_type3,stat_value3,
               stat_type4,stat_value4,stat_type5,stat_value5,stat_type6,stat_value6,
               stat_type7,stat_value7,stat_type8,stat_value8,stat_type9,stat_value9,
               stat_type10,stat_value10
        INTO @st1,@sv1,@st2,@sv2,@st3,@sv3,@st4,@sv4,@st5,@sv5,@st6,@sv6,
             @st7,@sv7,@st8,@sv8,@st9,@sv9,@st10,@sv10
        FROM lplusworld.item_template WHERE entry=v_entry;

        DROP TEMPORARY TABLE IF EXISTS tmp_pvals;
        CREATE TEMPORARY TABLE tmp_pvals(stat TINYINT PRIMARY KEY, val DOUBLE) ENGINE=Memory;

        INSERT INTO tmp_pvals(stat,val)
        SELECT s,v FROM (
          SELECT @st1 s,@sv1 v UNION ALL SELECT @st2,@sv2 UNION ALL SELECT @st3,@sv3 UNION ALL
                 SELECT @st4,@sv4 UNION ALL SELECT @st5,@sv5 UNION ALL SELECT @st6,@sv6 UNION ALL
                 SELECT @st7,@sv7 UNION ALL SELECT @st8,@sv8 UNION ALL SELECT @st9,@sv9 UNION ALL
                 SELECT @st10,@sv10
        ) t
        WHERE s IN (3,4,5,6,7) AND IFNULL(v,0) > 0;

        SET @k := (SELECT COUNT(*) FROM tmp_pvals);
        IF @k = 0 THEN
          INSERT INTO tmp_pvals VALUES (7,0);  -- if no primaries, create STA
          SET @k := 1;
        END IF;

        /* even share of delta-sum per primary */
        SET @delta_each := CASE WHEN v_delta_sum>0 THEN (v_delta_sum / @k) ELSE 0 END;

        DROP TEMPORARY TABLE IF EXISTS tmp_pvals_new;
        CREATE TEMPORARY TABLE tmp_pvals_new(stat TINYINT PRIMARY KEY, newv INT) ENGINE=Memory;

        INSERT INTO tmp_pvals_new(stat,newv)
        SELECT stat,
               ROUND( POW( POW(val*@W_PRIMARY,1.5) + @delta_each, 2.0/3.0) / @W_PRIMARY )
        FROM tmp_pvals;

        IF v_apply=1 THEN
          UPDATE lplusworld.item_template t
          LEFT JOIN tmp_pvals_new n1 ON @st1 = n1.stat
          LEFT JOIN tmp_pvals_new n2 ON @st2 = n2.stat
          LEFT JOIN tmp_pvals_new n3 ON @st3 = n3.stat
          LEFT JOIN tmp_pvals_new n4 ON @st4 = n4.stat
          LEFT JOIN tmp_pvals_new n5 ON @st5 = n5.stat
          LEFT JOIN tmp_pvals_new n6 ON @st6 = n6.stat
          LEFT JOIN tmp_pvals_new n7 ON @st7 = n7.stat
          LEFT JOIN tmp_pvals_new n8 ON @st8 = n8.stat
          LEFT JOIN tmp_pvals_new n9 ON @st9 = n9.stat
          LEFT JOIN tmp_pvals_new n10 ON @st10 = n10.stat
          SET t.stat_value1 = IF(n1.stat IS NULL, t.stat_value1, n1.newv),
              t.stat_value2 = IF(n2.stat IS NULL, t.stat_value2, n2.newv),
              t.stat_value3 = IF(n3.stat IS NULL, t.stat_value3, n3.newv),
              t.stat_value4 = IF(n4.stat IS NULL, t.stat_value4, n4.newv),
              t.stat_value5 = IF(n5.stat IS NULL, t.stat_value5, n5.newv),
              t.stat_value6 = IF(n6.stat IS NULL, t.stat_value6, n6.newv),
              t.stat_value7 = IF(n7.stat IS NULL, t.stat_value7, n7.newv),
              t.stat_value8 = IF(n8.stat IS NULL, t.stat_value8, n8.newv),
              t.stat_value9 = IF(n9.stat IS NULL, t.stat_value9, n9.newv),
              t.stat_value10= IF(n10.stat IS NULL,t.stat_value10,n10.newv)
          WHERE t.entry=v_entry;

          CALL helper.sp_EstimateItemLevels();
        END IF;

        SELECT CAST(trueItemLevel AS SIGNED) INTO v_ilvl
        FROM lplusworld.item_template WHERE entry=v_entry;

        INSERT INTO helper.tune_ilvl_log(entry,action,from_ilvl,to_ilvl,details)
        VALUES (v_entry,'EXPAND',NULL,v_target,CONCAT('k=',@k));
      END IF;

      UPDATE helper.tune_queue
      SET status='done', note=NULL
      WHERE entry=v_entry;

    END LOOP;
    CLOSE cur;
  END;

  /* quick summary */
  SELECT status, COUNT(*) AS cnt
  FROM helper.tune_queue
  WHERE status IN ('queued','processing','done','error')
  GROUP BY status;
END