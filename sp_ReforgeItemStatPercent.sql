DELIMITER $$

DROP PROCEDURE IF EXISTS `helper`.`sp_ReforgeItemStatPercent`$$

CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `helper`.`sp_ReforgeItemStatPercent`(
  IN p_entry INT UNSIGNED,
  IN p_source_token VARCHAR(32),
  IN p_pct DOUBLE,
  IN p_target_token VARCHAR(32),
  IN p_apply TINYINT(1)
)
proc_body:BEGIN
  /*
    Simple reforge helper that moves budget between primary stats, resistances,
    and bonus armor while preserving the total item budget derived from the
    true item level curves.  Specify the source stat token (e.g. 'STR', 'SPI',
    'BONUSARMOR', 'HOLY_RES', or the group token 'RESIST'), the percentage to
    remove from that stat, and optionally a target token to receive the entire
    budget.  When no target is supplied the removed budget is shared evenly
    across every other stat that currently carries budget on the item.

    Supported tokens follow the naming used elsewhere in the tooling:
      - Primaries: STR, AGI, STA, INT, SPI
      - Resistances: HOLY_RES, FIRE_RES, NATURE_RES, FROST_RES, SHADOW_RES,
        ARCANE_RES, or the group alias RESIST
      - Bonus Armor: BONUSARMOR (ArmorDamageModifier)
  */
  DECLARE v_apply TINYINT(1) DEFAULT 0;
  DECLARE v_source VARCHAR(32);
  DECLARE v_pct DOUBLE DEFAULT 0.0;
  DECLARE v_target VARCHAR(32);
  DECLARE v_exists INT DEFAULT 0;
  DECLARE v_removed_budget DOUBLE DEFAULT 0.0;
  DECLARE v_added_budget DOUBLE DEFAULT 0.0;
  DECLARE v_diff DOUBLE DEFAULT 0.0;
  DECLARE v_share DOUBLE DEFAULT 0.0;
  DECLARE v_target_count INT DEFAULT 0;
  DECLARE v_loop INT DEFAULT 0;
  DECLARE v_last_token VARCHAR(32);
  DECLARE v_last_value DOUBLE;
  DECLARE v_weight DOUBLE;
  DECLARE v_new_budget DOUBLE;
  DECLARE v_total_old DOUBLE;
  DECLARE v_total_new DOUBLE;
  DECLARE v_sum_floor DOUBLE;
  DECLARE v_adjust INT;
  DECLARE v_stat_type TINYINT;

  SET v_source := UPPER(TRIM(IFNULL(p_source_token,'')));
  SET v_pct := GREATEST(0.0, LEAST(IFNULL(p_pct,0.0), 100.0));
  SET v_target := UPPER(TRIM(IFNULL(p_target_token,'')));
  SET v_apply := CASE WHEN IFNULL(p_apply,0) <> 0 THEN 1 ELSE 0 END;

  IF v_source = '' THEN LEAVE proc_body; END IF;
  IF v_pct <= 0 THEN LEAVE proc_body; END IF;

  SELECT COUNT(*) INTO v_exists FROM lplusworld.item_template WHERE entry = p_entry;
  IF v_exists = 0 THEN LEAVE proc_body; END IF;

  /* weights (keep in sync with estimator/scaler) */
  SET @W_PRIMARY    := 230.0;
  SET @W_RESIST     := 230.0;
  SET @W_BONUSARMOR :=  22.0;

  /* snapshot stat slots */
  DROP TEMPORARY TABLE IF EXISTS tmp_reforge_slots;
  CREATE TEMPORARY TABLE tmp_reforge_slots(
    slot_no TINYINT PRIMARY KEY,
    stat_type TINYINT,
    stat_value DOUBLE
  ) ENGINE=Memory;

  INSERT INTO tmp_reforge_slots(slot_no, stat_type, stat_value)
  SELECT 1, stat_type1, stat_value1 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 2, stat_type2, stat_value2 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 3, stat_type3, stat_value3 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 4, stat_type4, stat_value4 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 5, stat_type5, stat_value5 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 6, stat_type6, stat_value6 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 7, stat_type7, stat_value7 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 8, stat_type8, stat_value8 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 9, stat_type9, stat_value9 FROM lplusworld.item_template WHERE entry=p_entry
  UNION ALL SELECT 10,stat_type10,stat_value10 FROM lplusworld.item_template WHERE entry=p_entry;

  DROP TEMPORARY TABLE IF EXISTS tmp_reforge_tokens;
  CREATE TEMPORARY TABLE tmp_reforge_tokens(
    token VARCHAR(32) PRIMARY KEY,
    kind ENUM('PRIMARY','RESIST','BONUS') NOT NULL,
    stat_type TINYINT NULL,
    base_value DOUBLE NOT NULL,
    weight DOUBLE NOT NULL,
    base_budget DOUBLE NOT NULL,
    new_value DOUBLE NOT NULL,
    new_budget DOUBLE NOT NULL
  ) ENGINE=Memory;

  /* primaries */
  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'STR','PRIMARY',4, SUM(IFNULL(stat_value,0)), @W_PRIMARY,
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5),
         SUM(IFNULL(stat_value,0)),
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5)
  FROM tmp_reforge_slots WHERE stat_type=4 HAVING base_value > 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'AGI','PRIMARY',3, SUM(IFNULL(stat_value,0)), @W_PRIMARY,
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5),
         SUM(IFNULL(stat_value,0)),
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5)
  FROM tmp_reforge_slots WHERE stat_type=3 HAVING base_value > 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'STA','PRIMARY',7, SUM(IFNULL(stat_value,0)), @W_PRIMARY,
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5),
         SUM(IFNULL(stat_value,0)),
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5)
  FROM tmp_reforge_slots WHERE stat_type=7 HAVING base_value > 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'INT','PRIMARY',5, SUM(IFNULL(stat_value,0)), @W_PRIMARY,
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5),
         SUM(IFNULL(stat_value,0)),
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5)
  FROM tmp_reforge_slots WHERE stat_type=5 HAVING base_value > 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'SPI','PRIMARY',6, SUM(IFNULL(stat_value,0)), @W_PRIMARY,
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5),
         SUM(IFNULL(stat_value,0)),
         POW(GREATEST(0,SUM(IFNULL(stat_value,0)) * @W_PRIMARY), 1.5)
  FROM tmp_reforge_slots WHERE stat_type=6 HAVING base_value > 0;

  /* resistances */
  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'HOLY_RES','RESIST',NULL, IFNULL(holy_res,0), @W_RESIST,
         POW(GREATEST(0,IFNULL(holy_res,0) * @W_RESIST), 1.5),
         IFNULL(holy_res,0),
         POW(GREATEST(0,IFNULL(holy_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(holy_res,0) <> 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'FIRE_RES','RESIST',NULL, IFNULL(fire_res,0), @W_RESIST,
         POW(GREATEST(0,IFNULL(fire_res,0) * @W_RESIST), 1.5),
         IFNULL(fire_res,0),
         POW(GREATEST(0,IFNULL(fire_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(fire_res,0) <> 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'NATURE_RES','RESIST',NULL, IFNULL(nature_res,0), @W_RESIST,
         POW(GREATEST(0,IFNULL(nature_res,0) * @W_RESIST), 1.5),
         IFNULL(nature_res,0),
         POW(GREATEST(0,IFNULL(nature_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(nature_res,0) <> 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'FROST_RES','RESIST',NULL, IFNULL(frost_res,0), @W_RESIST,
         POW(GREATEST(0,IFNULL(frost_res,0) * @W_RESIST), 1.5),
         IFNULL(frost_res,0),
         POW(GREATEST(0,IFNULL(frost_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(frost_res,0) <> 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'SHADOW_RES','RESIST',NULL, IFNULL(shadow_res,0), @W_RESIST,
         POW(GREATEST(0,IFNULL(shadow_res,0) * @W_RESIST), 1.5),
         IFNULL(shadow_res,0),
         POW(GREATEST(0,IFNULL(shadow_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(shadow_res,0) <> 0;

  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'ARCANE_RES','RESIST',NULL, IFNULL(arcane_res,0), @W_RESIST,
         POW(GREATEST(0,IFNULL(arcane_res,0) * @W_RESIST), 1.5),
         IFNULL(arcane_res,0),
         POW(GREATEST(0,IFNULL(arcane_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(arcane_res,0) <> 0;

  /* bonus armor */
  INSERT INTO tmp_reforge_tokens(token, kind, stat_type, base_value, weight, base_budget, new_value, new_budget)
  SELECT 'BONUSARMOR','BONUS',NULL, IFNULL(ArmorDamageModifier,0), @W_BONUSARMOR,
         POW(GREATEST(0,IFNULL(ArmorDamageModifier,0) * @W_BONUSARMOR), 1.5),
         IFNULL(ArmorDamageModifier,0),
         POW(GREATEST(0,IFNULL(ArmorDamageModifier,0) * @W_BONUSARMOR), 1.5)
  FROM lplusworld.item_template WHERE entry=p_entry AND IFNULL(ArmorDamageModifier,0) <> 0;

  DROP TEMPORARY TABLE IF EXISTS tmp_source_tokens;
  CREATE TEMPORARY TABLE tmp_source_tokens(token VARCHAR(32) PRIMARY KEY) ENGINE=Memory;

  IF v_source = 'RESIST' THEN
    INSERT INTO tmp_source_tokens(token)
    SELECT token FROM tmp_reforge_tokens WHERE kind='RESIST';
  ELSE
    INSERT INTO tmp_source_tokens(token)
    SELECT v_source FROM tmp_reforge_tokens WHERE token = v_source;
  END IF;

  IF (SELECT COUNT(*) FROM tmp_source_tokens) = 0 THEN
    LEAVE proc_body;
  END IF;

  /* apply removal */
  UPDATE tmp_reforge_tokens t
  JOIN tmp_source_tokens s ON t.token = s.token
  SET t.new_value = ROUND(GREATEST(0, t.base_value * (1.0 - v_pct/100.0)));

  UPDATE tmp_reforge_tokens SET new_budget = POW(GREATEST(0, new_value * weight), 1.5)
  WHERE token IN (SELECT token FROM tmp_source_tokens);

  SELECT SUM(base_budget - new_budget) INTO v_removed_budget
  FROM tmp_reforge_tokens WHERE token IN (SELECT token FROM tmp_source_tokens);

  IF v_removed_budget <= 0 THEN
    LEAVE proc_body;
  END IF;

  /* determine targets */
  DROP TEMPORARY TABLE IF EXISTS tmp_target_tokens;
  CREATE TEMPORARY TABLE tmp_target_tokens(token VARCHAR(32) PRIMARY KEY) ENGINE=Memory;

  IF v_target IN ('', 'ALL', 'EVEN') THEN
    INSERT INTO tmp_target_tokens(token)
    SELECT token FROM tmp_reforge_tokens
    WHERE token NOT IN (SELECT token FROM tmp_source_tokens)
      AND base_value > 0;
  ELSEIF v_target = 'RESIST' THEN
    INSERT INTO tmp_target_tokens(token)
    SELECT token FROM tmp_reforge_tokens
    WHERE kind='RESIST' AND token NOT IN (SELECT token FROM tmp_source_tokens);
  ELSE
    INSERT INTO tmp_target_tokens(token)
    SELECT v_target FROM tmp_reforge_tokens
    WHERE token = v_target AND token NOT IN (SELECT token FROM tmp_source_tokens);
  END IF;

  SET v_target_count := (SELECT COUNT(*) FROM tmp_target_tokens);
  IF v_target_count = 0 THEN
    LEAVE proc_body;
  END IF;

  SET v_share := v_removed_budget / v_target_count;

  UPDATE tmp_reforge_tokens t
  JOIN tmp_target_tokens g ON t.token = g.token
  SET t.new_budget = GREATEST(0, t.base_budget + v_share);

  UPDATE tmp_reforge_tokens t
  SET t.new_value = ROUND(GREATEST(0, POW(GREATEST(0, t.new_budget), 2.0/3.0) / t.weight))
  WHERE token IN (SELECT token FROM tmp_target_tokens);

  UPDATE tmp_reforge_tokens t
  SET t.new_budget = POW(GREATEST(0, t.new_value * t.weight), 1.5)
  WHERE token IN (SELECT token FROM tmp_target_tokens);

  SELECT SUM(new_budget - base_budget) INTO v_added_budget
  FROM tmp_reforge_tokens WHERE token IN (SELECT token FROM tmp_target_tokens);

  SET v_diff := v_removed_budget - v_added_budget;

  IF ABS(v_diff) > 0.5 THEN
    SELECT t.token INTO v_last_token
    FROM tmp_target_tokens g
    JOIN tmp_reforge_tokens t ON t.token = g.token
    ORDER BY t.base_budget DESC, t.token DESC
    LIMIT 1;

    SET v_loop := 0;
    adjustment_loop: WHILE ABS(v_diff) > 0.5 AND v_loop < 64 DO
      SET v_loop := v_loop + 1;
      SELECT new_value, weight INTO v_last_value, v_weight
      FROM tmp_reforge_tokens WHERE token = v_last_token;

      IF v_diff > 0 THEN
        SET v_last_value := v_last_value + 1;
      ELSE
        IF v_last_value <= 0 THEN LEAVE adjustment_loop; END IF;
        SET v_last_value := v_last_value - 1;
      END IF;

      SET v_new_budget := POW(GREATEST(0, v_last_value * v_weight), 1.5);
      UPDATE tmp_reforge_tokens
      SET new_value = v_last_value, new_budget = v_new_budget
      WHERE token = v_last_token;

      SELECT SUM(new_budget - base_budget) INTO v_added_budget
      FROM tmp_reforge_tokens WHERE token IN (SELECT token FROM tmp_target_tokens);

      SET v_diff := v_removed_budget - v_added_budget;
    END WHILE;
  END IF;

  /* redistribute primary slots */
  DROP TEMPORARY TABLE IF EXISTS tmp_primary_share;
  CREATE TEMPORARY TABLE tmp_primary_share(
    slot_no TINYINT PRIMARY KEY,
    stat_type TINYINT,
    base_value DOUBLE,
    proposed DOUBLE,
    frac DOUBLE,
    new_value INT
  ) ENGINE=Memory;

  INSERT INTO tmp_primary_share(slot_no, stat_type, base_value, proposed, frac, new_value)
  SELECT slot_no, stat_type, IFNULL(stat_value,0), 0, 0, ROUND(IFNULL(stat_value,0))
  FROM tmp_reforge_slots WHERE stat_type IN (3,4,5,6,7);

  DROP TEMPORARY TABLE IF EXISTS tmp_stat_types;
  CREATE TEMPORARY TABLE tmp_stat_types(stat_type TINYINT PRIMARY KEY) ENGINE=Memory;
  INSERT INTO tmp_stat_types(stat_type)
  SELECT DISTINCT stat_type FROM tmp_primary_share;

  stat_loop: WHILE (SELECT COUNT(*) FROM tmp_stat_types) > 0 DO
    SELECT stat_type INTO v_stat_type FROM tmp_stat_types ORDER BY stat_type LIMIT 1;
    DELETE FROM tmp_stat_types WHERE stat_type = v_stat_type;

    SELECT SUM(base_value) INTO v_total_old FROM tmp_primary_share WHERE stat_type = v_stat_type;
    SELECT new_value INTO v_total_new FROM tmp_reforge_tokens WHERE stat_type = v_stat_type;

    IF v_total_new IS NULL THEN
      SET v_total_new := v_total_old;
    END IF;

    IF v_total_old <= 0 THEN
      UPDATE tmp_primary_share SET new_value = 0 WHERE stat_type = v_stat_type;
      ITERATE stat_loop;
    END IF;

    UPDATE tmp_primary_share
    SET proposed = (base_value / v_total_old) * v_total_new
    WHERE stat_type = v_stat_type;

    UPDATE tmp_primary_share
    SET new_value = FLOOR(proposed),
        frac = proposed - FLOOR(proposed)
    WHERE stat_type = v_stat_type;

    SELECT SUM(new_value) INTO v_sum_floor FROM tmp_primary_share WHERE stat_type = v_stat_type;
    SET v_adjust := ROUND(v_total_new) - ROUND(v_sum_floor);

    WHILE v_adjust > 0 DO
      UPDATE tmp_primary_share ps
      JOIN (
        SELECT slot_no FROM tmp_primary_share
        WHERE stat_type = v_stat_type
        ORDER BY frac DESC, slot_no
        LIMIT 1
      ) pick ON pick.slot_no = ps.slot_no
      SET ps.new_value = ps.new_value + 1;
      SET v_adjust := v_adjust - 1;
    END WHILE;

    WHILE v_adjust < 0 DO
      UPDATE tmp_primary_share ps
      JOIN (
        SELECT slot_no FROM tmp_primary_share
        WHERE stat_type = v_stat_type
        ORDER BY frac ASC, slot_no
        LIMIT 1
      ) pick ON pick.slot_no = ps.slot_no
      SET ps.new_value = GREATEST(0, ps.new_value - 1);
      SET v_adjust := v_adjust + 1;
    END WHILE;
  END WHILE;

  DROP TEMPORARY TABLE IF EXISTS tmp_slot_final;
  CREATE TEMPORARY TABLE tmp_slot_final(
    slot_no TINYINT PRIMARY KEY,
    new_value INT
  ) ENGINE=Memory;

  INSERT INTO tmp_slot_final(slot_no, new_value)
  SELECT s.slot_no,
         CASE
           WHEN s.stat_type IN (3,4,5,6,7) THEN IFNULL(ps.new_value,0)
           ELSE ROUND(IFNULL(s.stat_value,0))
         END
  FROM tmp_reforge_slots s
  LEFT JOIN tmp_primary_share ps ON ps.slot_no = s.slot_no;

  IF v_apply = 1 THEN
    UPDATE lplusworld.item_template t
    JOIN (
      SELECT
        MAX(CASE WHEN slot_no=1 THEN new_value END) AS v1,
        MAX(CASE WHEN slot_no=2 THEN new_value END) AS v2,
        MAX(CASE WHEN slot_no=3 THEN new_value END) AS v3,
        MAX(CASE WHEN slot_no=4 THEN new_value END) AS v4,
        MAX(CASE WHEN slot_no=5 THEN new_value END) AS v5,
        MAX(CASE WHEN slot_no=6 THEN new_value END) AS v6,
        MAX(CASE WHEN slot_no=7 THEN new_value END) AS v7,
        MAX(CASE WHEN slot_no=8 THEN new_value END) AS v8,
        MAX(CASE WHEN slot_no=9 THEN new_value END) AS v9,
        MAX(CASE WHEN slot_no=10 THEN new_value END) AS v10
      FROM tmp_slot_final
    ) ns
    SET t.stat_value1 = IF(ns.v1 IS NULL, t.stat_value1, ns.v1),
        t.stat_value2 = IF(ns.v2 IS NULL, t.stat_value2, ns.v2),
        t.stat_value3 = IF(ns.v3 IS NULL, t.stat_value3, ns.v3),
        t.stat_value4 = IF(ns.v4 IS NULL, t.stat_value4, ns.v4),
        t.stat_value5 = IF(ns.v5 IS NULL, t.stat_value5, ns.v5),
        t.stat_value6 = IF(ns.v6 IS NULL, t.stat_value6, ns.v6),
        t.stat_value7 = IF(ns.v7 IS NULL, t.stat_value7, ns.v7),
        t.stat_value8 = IF(ns.v8 IS NULL, t.stat_value8, ns.v8),
        t.stat_value9 = IF(ns.v9 IS NULL, t.stat_value9, ns.v9),
        t.stat_value10= IF(ns.v10 IS NULL, t.stat_value10, ns.v10)
    WHERE t.entry = p_entry;

    /* resistances */
    UPDATE lplusworld.item_template t
    LEFT JOIN tmp_reforge_tokens h ON h.token='HOLY_RES'
    LEFT JOIN tmp_reforge_tokens f ON f.token='FIRE_RES'
    LEFT JOIN tmp_reforge_tokens n ON n.token='NATURE_RES'
    LEFT JOIN tmp_reforge_tokens r ON r.token='FROST_RES'
    LEFT JOIN tmp_reforge_tokens s ON s.token='SHADOW_RES'
    LEFT JOIN tmp_reforge_tokens a ON a.token='ARCANE_RES'
    LEFT JOIN tmp_reforge_tokens b ON b.token='BONUSARMOR'
    SET t.holy_res   = IF(h.token IS NULL, t.holy_res,   h.new_value),
        t.fire_res   = IF(f.token IS NULL, t.fire_res,   f.new_value),
        t.nature_res = IF(n.token IS NULL, t.nature_res, n.new_value),
        t.frost_res  = IF(r.token IS NULL, t.frost_res,  r.new_value),
        t.shadow_res = IF(s.token IS NULL, t.shadow_res, s.new_value),
        t.arcane_res = IF(a.token IS NULL, t.arcane_res, a.new_value),
        t.ArmorDamageModifier = IF(b.token IS NULL, t.ArmorDamageModifier, b.new_value)
    WHERE t.entry = p_entry;

    CALL helper.sp_EstimateItemLevels();
  END IF;

  SELECT token, kind, base_value, new_value, base_budget, new_budget
  FROM tmp_reforge_tokens
  ORDER BY token;

END$$

DELIMITER ;
