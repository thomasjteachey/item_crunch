CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_TuneTrueItemLevel_ConsumeQueue`(
  IN p_limit INT UNSIGNED   -- 0/NULL = all queued rows
)
BEGIN
  /* ===== DECLARES (must be first) ===== */
  DECLARE v_entry   INT UNSIGNED;
  DECLARE v_target  INT UNSIGNED;
  DECLARE v_apply   TINYINT(1);
  DECLARE done      INT DEFAULT 0;

  /* cursor over a temp table we'll create before OPEN */
  DECLARE cur CURSOR FOR
    SELECT entry, target_ilvl, apply_change
    FROM tmp_work
    ORDER BY entry;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  /* ===== minimal log table (ok after DECLAREs) ===== */
  CREATE TABLE IF NOT EXISTS helper.tune_ilvl_log (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    entry INT UNSIGNED NOT NULL,
    action ENUM('RUN','ERROR') NOT NULL,
    ilvl_before INT NULL,
    ilvl_after  INT NULL,
    target_ilvl INT NULL,
    note VARCHAR(255) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
  ) ENGINE=InnoDB;

  /* snapshot worklist to avoid racing live queue */
  DROP TEMPORARY TABLE IF EXISTS tmp_work;
  CREATE TEMPORARY TABLE tmp_work(
    entry INT UNSIGNED PRIMARY KEY,
    target_ilvl INT UNSIGNED NOT NULL,
    apply_change TINYINT(1) NOT NULL
  ) ENGINE=Memory;

  IF p_limit IS NULL OR p_limit = 0 THEN
    INSERT INTO tmp_work(entry,target_ilvl,apply_change)
    SELECT entry, target_ilvl, apply_change
    FROM helper.tune_queue
    WHERE status='queued';
  ELSE
    INSERT INTO tmp_work(entry,target_ilvl,apply_change)
    SELECT entry, target_ilvl, apply_change
    FROM helper.tune_queue
    WHERE status='queued'
    ORDER BY entry
    LIMIT p_limit;
  END IF;

  /* ===== iterate ===== */
  OPEN cur;
  readloop: LOOP
    FETCH cur INTO v_entry, v_target, v_apply;
    IF done = 1 THEN LEAVE readloop; END IF;

    /* mark processing */
    UPDATE helper.tune_queue
      SET status='processing', note=NULL
    WHERE entry=v_entry AND status='queued';

    /* snapshot before (iLvl, class/subclass/delay, DPS) */
    SELECT it.class, it.subclass, it.delay,
           CAST(IFNULL(it.trueItemLevel, it.ItemLevel) AS SIGNED) AS ilvl_before,
           (
             (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0))/2.0 +
             (COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0))/2.0
           ) / NULLIF(it.delay/1000.0,0) AS dps_before
      INTO @class, @subclass, @delay, @before, @dps_before
    FROM lplusworld.item_template it
    WHERE it.entry=v_entry;

    SET @is_weapon := IF(@class=2 AND IFNULL(@delay,0)>0, 1, 0);
    SET @dps_fail  := 0;

    /* ===== 1) If weapon, scale WEAPON DPS to target iLvl first =====
       Do this BEFORE the greedy scaler so the DPS model compares cur→target properly.
       Non-fatal on failure: we annotate and continue. */
    IF @is_weapon = 1 THEN
      BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET @dps_fail := 1;
        CALL helper.sp_ScaleWeaponDpsToIlvl_ByBracketMedian(v_entry, v_target, v_apply, 0);
      END;
    END IF;

    /* ===== 2) Run your greedy iLvl scaler (unchanged) ===== */
    CALL helper.sp_ScaleItemToIlvl_SimpleGreedy(v_entry, v_target, v_apply, 1);

    /* ===== 3) Refresh trueItemLevel estimates if applied ===== */
    IF v_apply = 1 THEN
      CALL helper.sp_EstimateItemLevels();
    END IF;

    /* snapshot after (iLvl + DPS) */
    SELECT CAST(IFNULL(it.trueItemLevel, it.ItemLevel) AS SIGNED),
           (
             (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0))/2.0 +
             (COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0))/2.0
           ) / NULLIF(it.delay/1000.0,0)
      INTO @after, @dps_after
    FROM lplusworld.item_template it
    WHERE it.entry=v_entry;

    /* finish queue row (keep done, but add note if DPS failed) */
    UPDATE helper.tune_queue
       SET status='done',
           note = CONCAT(
                   'apply=', v_apply,
                   IF(@is_weapon=1,
                      CONCAT(', dps ', ROUND(@dps_before,2), '→', ROUND(@dps_after,2),
                             IF(@dps_fail=1,' (DPS scale FAIL)','')
                      ),
                      ''
                   )
                 )
     WHERE entry=v_entry;

    INSERT INTO helper.tune_ilvl_log(entry,action,ilvl_before,ilvl_after,target_ilvl,note)
    VALUES (v_entry,'RUN',@before,@after,v_target,
            CONCAT(
               'apply=',v_apply,
               IF(@is_weapon=1,
                  CONCAT(', dps ', ROUND(@dps_before,2), '→', ROUND(@dps_after,2),
                         IF(@dps_fail=1,' (DPS scale FAIL)','')
                  ),
                  ''
               )
            ));
  END LOOP;
  CLOSE cur;

  /* summary */
  SELECT status, COUNT(*) AS cnt
  FROM helper.tune_queue
  WHERE status IN ('queued','processing','done','error')
  GROUP BY status;
END