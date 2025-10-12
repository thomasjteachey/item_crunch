DELIMITER $$

DROP PROCEDURE IF EXISTS `helper`.`sp_ReforgeItemStat`$$

CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `helper`.`sp_ReforgeItemStat`(
  IN p_entry INT UNSIGNED,
  IN p_source_key VARCHAR(32),
  IN p_pct DOUBLE,
  IN p_target_key VARCHAR(32),
  IN p_apply TINYINT(1)
)
proc:BEGIN
  DECLARE v_pct DOUBLE;
  DECLARE v_source_key VARCHAR(32);
  DECLARE v_target_key VARCHAR(32);
  DECLARE v_source_weight DOUBLE;
  DECLARE v_source_value DOUBLE;
  DECLARE v_source_term DOUBLE;
  DECLARE v_source_term_new DOUBLE;
  DECLARE v_delta_term DOUBLE;
  DECLARE v_target_count INT;
  DECLARE v_adjust_key VARCHAR(32);
  DECLARE v_diff_term DOUBLE;
  DECLARE v_iterations INT;
  DECLARE v_weight_target DOUBLE;
  DECLARE v_term_target DOUBLE;
  DECLARE v_value_target DOUBLE;
  DECLARE v_value_target_int DOUBLE;
  DECLARE v_res_holy DOUBLE;
  DECLARE v_res_fire DOUBLE;
  DECLARE v_res_nature DOUBLE;
  DECLARE v_res_frost DOUBLE;
  DECLARE v_res_shadow DOUBLE;
  DECLARE v_res_arcane DOUBLE;
  DECLARE v_bonus_armor DOUBLE;
  DECLARE done INT DEFAULT 0;
  DECLARE v_stat_type TINYINT;
  DECLARE v_new_total DOUBLE;
  DECLARE v_slot_count INT;
  DECLARE v_old_total DOUBLE;
  DECLARE v_slot_no TINYINT;
  DECLARE v_old_value INT;
  DECLARE v_new_value INT;
  DECLARE v_sum_new INT;
  DECLARE v_first_slot TINYINT;
  DECLARE done_slot INT DEFAULT 0;

  DECLARE cur_stat CURSOR FOR
    SELECT stat_type, actual_value
    FROM tmp_stat_plan
    WHERE stat_type IS NOT NULL;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  IF p_entry IS NULL THEN
    LEAVE proc;
  END IF;

  SET v_pct := GREATEST(0.0, LEAST(100.0, IFNULL(p_pct, 0.0)));
  IF v_pct <= 0 THEN
    LEAVE proc;
  END IF;

  SET v_source_key := UPPER(TRIM(IFNULL(p_source_key, '')));
  IF v_source_key = '' THEN
    LEAVE proc;
  END IF;

  SET v_target_key := UPPER(TRIM(IFNULL(p_target_key, '')));
  IF v_target_key = '' THEN
    SET v_target_key := NULL;
  END IF;

  SET @W_PRIMARY := 230.0;
  SET @W_AP      := 115.0;
  SET @W_RAP     :=  92.0;
  SET @W_HEAL    := 100.0;
  SET @W_SD_ALL  := 192.0;
  SET @W_SD_ONE  := 159.0;
  SET @W_MP5     :=  550.0;
  SET @W_HP5     :=  550.0;
  SET @W_RESIST  :=  230.0;
  SET @W_BONUSARMOR :=   22.0;

  DROP TEMPORARY TABLE IF EXISTS tmp_stat_catalog;
  CREATE TEMPORARY TABLE tmp_stat_catalog(
    key_code VARCHAR(32) NOT NULL PRIMARY KEY,
    stat_type TINYINT,
    weight DOUBLE NOT NULL,
    is_resist TINYINT NOT NULL DEFAULT 0,
    resist_column VARCHAR(32),
    is_bonus TINYINT NOT NULL DEFAULT 0
  ) ENGINE=Memory;

  INSERT INTO tmp_stat_catalog(key_code, stat_type, weight, is_resist, resist_column, is_bonus) VALUES
    ('AGI', 3, @W_PRIMARY, 0, NULL, 0),
    ('STR', 4, @W_PRIMARY, 0, NULL, 0),
    ('INT', 5, @W_PRIMARY, 0, NULL, 0),
    ('SPI', 6, @W_PRIMARY, 0, NULL, 0),
    ('STA', 7, @W_PRIMARY, 0, NULL, 0),
    ('AP', 38, @W_AP, 0, NULL, 0),
    ('RAP', 39, @W_RAP, 0, NULL, 0),
    ('HEAL', 41, @W_HEAL, 0, NULL, 0),
    ('SD_ALL', 45, @W_SD_ALL, 0, NULL, 0),
    ('MP5', 43, @W_MP5, 0, NULL, 0),
    ('HP5', 46, @W_HP5, 0, NULL, 0),
    ('RES_HOLY', NULL, @W_RESIST, 1, 'holy_res', 0),
    ('RES_FIRE', NULL, @W_RESIST, 1, 'fire_res', 0),
    ('RES_NATURE', NULL, @W_RESIST, 1, 'nature_res', 0),
    ('RES_FROST', NULL, @W_RESIST, 1, 'frost_res', 0),
    ('RES_SHADOW', NULL, @W_RESIST, 1, 'shadow_res', 0),
    ('RES_ARCANE', NULL, @W_RESIST, 1, 'arcane_res', 0),
    ('BONUS_ARMOR', NULL, @W_BONUSARMOR, 0, 'ArmorDamageModifier', 1);

  DROP TEMPORARY TABLE IF EXISTS tmp_stat_slots;
  CREATE TEMPORARY TABLE tmp_stat_slots(
    slot_no TINYINT NOT NULL PRIMARY KEY,
    stat_type TINYINT NOT NULL,
    stat_value INT NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_stat_slots(slot_no, stat_type, stat_value)
  SELECT 1, stat_type1, stat_value1 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 2, stat_type2, stat_value2 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 3, stat_type3, stat_value3 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 4, stat_type4, stat_value4 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 5, stat_type5, stat_value5 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 6, stat_type6, stat_value6 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 7, stat_type7, stat_value7 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 8, stat_type8, stat_value8 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 9, stat_type9, stat_value9 FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL SELECT 10, stat_type10, stat_value10 FROM lplusworld.item_template WHERE entry = p_entry;

  DROP TEMPORARY TABLE IF EXISTS tmp_stat_plan;
  CREATE TEMPORARY TABLE tmp_stat_plan(
    key_code VARCHAR(32) NOT NULL PRIMARY KEY,
    stat_type TINYINT,
    weight DOUBLE NOT NULL,
    value_old DOUBLE NOT NULL DEFAULT 0,
    desired_value DOUBLE NOT NULL DEFAULT 0,
    desired_term DOUBLE NOT NULL DEFAULT 0,
    desired_term_new DOUBLE NOT NULL DEFAULT 0,
    actual_value DOUBLE NOT NULL DEFAULT 0,
    actual_term DOUBLE NOT NULL DEFAULT 0,
    is_resist TINYINT NOT NULL DEFAULT 0,
    resist_column VARCHAR(32),
    is_bonus TINYINT NOT NULL DEFAULT 0
  ) ENGINE=Memory;

  INSERT INTO tmp_stat_plan(key_code, stat_type, weight, value_old, desired_value, desired_term, desired_term_new, actual_value, actual_term, is_resist, resist_column, is_bonus)
  SELECT c.key_code,
         c.stat_type,
         c.weight,
         IFNULL(SUM(CASE WHEN s.stat_type = c.stat_type THEN s.stat_value ELSE 0 END), 0) AS value_old,
         0,
         0,
         0,
         0,
         0,
         c.is_resist,
         c.resist_column,
         c.is_bonus
  FROM tmp_stat_catalog c
  LEFT JOIN tmp_stat_slots s ON s.stat_type = c.stat_type
  WHERE c.stat_type IS NOT NULL
  GROUP BY c.key_code;

  SELECT holy_res, fire_res, nature_res, frost_res, shadow_res, arcane_res, ArmorDamageModifier
    INTO v_res_holy, v_res_fire, v_res_nature, v_res_frost, v_res_shadow, v_res_arcane, v_bonus_armor
  FROM lplusworld.item_template
  WHERE entry = p_entry;

  INSERT INTO tmp_stat_plan(key_code, stat_type, weight, value_old, desired_value, desired_term, desired_term_new, actual_value, actual_term, is_resist, resist_column, is_bonus)
  VALUES
    ('RES_HOLY', NULL, @W_RESIST, IFNULL(v_res_holy,0), 0, 0, 0, 0, 0, 1, 'holy_res', 0),
    ('RES_FIRE', NULL, @W_RESIST, IFNULL(v_res_fire,0), 0, 0, 0, 0, 0, 1, 'fire_res', 0),
    ('RES_NATURE', NULL, @W_RESIST, IFNULL(v_res_nature,0), 0, 0, 0, 0, 0, 1, 'nature_res', 0),
    ('RES_FROST', NULL, @W_RESIST, IFNULL(v_res_frost,0), 0, 0, 0, 0, 0, 1, 'frost_res', 0),
    ('RES_SHADOW', NULL, @W_RESIST, IFNULL(v_res_shadow,0), 0, 0, 0, 0, 0, 1, 'shadow_res', 0),
    ('RES_ARCANE', NULL, @W_RESIST, IFNULL(v_res_arcane,0), 0, 0, 0, 0, 0, 1, 'arcane_res', 0),
    ('BONUS_ARMOR', NULL, @W_BONUSARMOR, IFNULL(v_bonus_armor,0), 0, 0, 0, 0, 0, 0, 'ArmorDamageModifier', 1);

  DELETE FROM tmp_stat_plan
  WHERE value_old <= 0;

  IF (SELECT COUNT(*) FROM tmp_stat_plan WHERE key_code = v_source_key) = 0 THEN
    LEAVE proc;
  END IF;

  IF v_target_key IS NOT NULL AND (SELECT COUNT(*) FROM tmp_stat_plan WHERE key_code = v_target_key) = 0 THEN
    LEAVE proc;
  END IF;

  UPDATE tmp_stat_plan
  SET desired_value = value_old,
      desired_term = POW(GREATEST(0, value_old * weight), 1.5),
      desired_term_new = POW(GREATEST(0, value_old * weight), 1.5)
  WHERE 1;

  SELECT weight, value_old, desired_term
    INTO v_source_weight, v_source_value, v_source_term
  FROM tmp_stat_plan
  WHERE key_code = v_source_key;

  SET v_source_value := GREATEST(0, v_source_value);
  SET v_source_term := GREATEST(0, v_source_term);
  SET v_source_term_new := POW(GREATEST(0, v_source_value * (1.0 - v_pct / 100.0) * v_source_weight), 1.5);
  SET v_delta_term := v_source_term - v_source_term_new;

  UPDATE tmp_stat_plan
  SET desired_value = GREATEST(0, v_source_value * (1.0 - v_pct / 100.0)),
      desired_term_new = v_source_term_new
  WHERE key_code = v_source_key;

  IF v_delta_term <= 0 THEN
    LEAVE proc;
  END IF;

  IF v_target_key IS NULL THEN
    SET v_target_count := (SELECT COUNT(*) FROM tmp_stat_plan WHERE key_code <> v_source_key);
    IF v_target_count <= 0 THEN
      LEAVE proc;
    END IF;

    UPDATE tmp_stat_plan
    SET desired_term_new = desired_term_new + (v_delta_term / v_target_count)
    WHERE key_code <> v_source_key;
  ELSE
    UPDATE tmp_stat_plan
    SET desired_term_new = desired_term_new + v_delta_term
    WHERE key_code = v_target_key;
  END IF;

  UPDATE tmp_stat_plan
  SET desired_value = CASE
        WHEN weight = 0 THEN desired_value
        ELSE POW(GREATEST(0, desired_term_new), 2.0/3.0) / weight
      END
  WHERE 1;

  UPDATE tmp_stat_plan
  SET actual_value = CASE
        WHEN is_resist = 1 THEN LEAST(255, ROUND(GREATEST(0, desired_value)))
        ELSE ROUND(GREATEST(0, desired_value))
      END
  WHERE 1;

  UPDATE tmp_stat_plan
  SET actual_term = POW(GREATEST(0, actual_value * weight), 1.5)
  WHERE 1;

  SET v_adjust_key := CASE
    WHEN v_target_key IS NOT NULL THEN v_target_key
    ELSE (
      SELECT key_code
      FROM tmp_stat_plan
      WHERE key_code <> v_source_key
      ORDER BY key_code
      LIMIT 1
    )
  END;

  IF v_adjust_key IS NULL THEN
    SET v_adjust_key := v_source_key;
  END IF;

  SET v_iterations := 0;
  adjust_loop: LOOP
    SET v_iterations := v_iterations + 1;
    SELECT SUM(desired_term_new - actual_term) INTO v_diff_term FROM tmp_stat_plan;
    IF ABS(IFNULL(v_diff_term,0)) <= 0.5 OR v_iterations >= 6 THEN
      LEAVE adjust_loop;
    END IF;

    SELECT weight, desired_term_new
      INTO v_weight_target, v_term_target
    FROM tmp_stat_plan
    WHERE key_code = v_adjust_key;

    SET v_term_target := GREATEST(0, v_term_target + IFNULL(v_diff_term,0));
    SET v_value_target := CASE
      WHEN v_weight_target = 0 THEN 0
      ELSE POW(GREATEST(0, v_term_target), 2.0/3.0) / v_weight_target
    END;
    SET v_value_target_int := CASE
      WHEN (SELECT is_resist FROM tmp_stat_plan WHERE key_code = v_adjust_key) = 1 THEN LEAST(255, ROUND(GREATEST(0, v_value_target)))
      ELSE ROUND(GREATEST(0, v_value_target))
    END;

    UPDATE tmp_stat_plan
    SET desired_term_new = v_term_target,
        desired_value = v_value_target,
        actual_value = v_value_target_int,
        actual_term = POW(GREATEST(0, v_value_target_int * weight), 1.5)
    WHERE key_code = v_adjust_key;
  END LOOP adjust_loop;

  DROP TEMPORARY TABLE IF EXISTS tmp_slot_updates;
  CREATE TEMPORARY TABLE tmp_slot_updates(
    slot_no TINYINT PRIMARY KEY,
    new_value INT NOT NULL
  ) ENGINE=Memory;

  SET done := 0;
  OPEN cur_stat;
  stat_loop: LOOP
    FETCH cur_stat INTO v_stat_type, v_new_total;
    IF done = 1 THEN
      LEAVE stat_loop;
    END IF;

    SELECT COUNT(*), IFNULL(SUM(stat_value),0)
      INTO v_slot_count, v_old_total
    FROM tmp_stat_slots
    WHERE stat_type = v_stat_type;

    IF v_slot_count = 0 THEN
      ITERATE stat_loop;
    END IF;

    DELETE FROM tmp_slot_updates;

    IF v_new_total <= 0 THEN
      INSERT INTO tmp_slot_updates(slot_no, new_value)
      SELECT slot_no, 0
      FROM tmp_stat_slots
      WHERE stat_type = v_stat_type;
    ELSE
      SET v_sum_new := 0;
      SET v_first_slot := NULL;
      SET done_slot := 0;
      BEGIN
        DECLARE cur_slots CURSOR FOR
          SELECT slot_no, stat_value
          FROM tmp_stat_slots
          WHERE stat_type = v_stat_type
          ORDER BY slot_no;
        DECLARE CONTINUE HANDLER FOR NOT FOUND SET done_slot = 1;

        OPEN cur_slots;
        slot_loop: LOOP
          FETCH cur_slots INTO v_slot_no, v_old_value;
          IF done_slot = 1 THEN
            LEAVE slot_loop;
          END IF;

          IF v_first_slot IS NULL THEN
            SET v_first_slot := v_slot_no;
          END IF;

          IF v_old_total <= 0 THEN
            SET v_new_value := CASE WHEN v_slot_no = v_first_slot THEN ROUND(v_new_total) ELSE 0 END;
          ELSE
            SET v_new_value := ROUND(v_new_total * v_old_value / v_old_total);
          END IF;

          INSERT INTO tmp_slot_updates(slot_no, new_value)
          VALUES (v_slot_no, GREATEST(0, v_new_value))
          ON DUPLICATE KEY UPDATE new_value = VALUES(new_value);

          SET v_sum_new := v_sum_new + GREATEST(0, v_new_value);
        END LOOP slot_loop;
        CLOSE cur_slots;
      END;

      SET v_new_value := ROUND(GREATEST(0, v_new_total));
      SET v_new_value := v_new_value - v_sum_new;
      IF v_new_value <> 0 AND v_first_slot IS NOT NULL THEN
        UPDATE tmp_slot_updates
        SET new_value = GREATEST(0, new_value + v_new_value)
        WHERE slot_no = v_first_slot;
      END IF;
    END IF;

    UPDATE tmp_stat_slots s
    JOIN tmp_slot_updates u ON u.slot_no = s.slot_no
    SET s.stat_value = u.new_value,
        s.stat_type = CASE WHEN u.new_value = 0 THEN 0 ELSE s.stat_type END
    WHERE s.stat_type = v_stat_type OR u.new_value = 0;
  END LOOP stat_loop;
  CLOSE cur_stat;

  DROP TEMPORARY TABLE IF EXISTS tmp_slots_final;
  CREATE TEMPORARY TABLE tmp_slots_final AS
  SELECT slot_no,
         stat_type,
         stat_value
  FROM tmp_stat_slots;

  SET @res_holy_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='RES_HOLY');
  SET @res_fire_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='RES_FIRE');
  SET @res_nature_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='RES_NATURE');
  SET @res_frost_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='RES_FROST');
  SET @res_shadow_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='RES_SHADOW');
  SET @res_arcane_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='RES_ARCANE');
  SET @bonus_armor_new := (SELECT actual_value FROM tmp_stat_plan WHERE key_code='BONUS_ARMOR');

  SET @statcount_new := (
    SELECT COUNT(*)
    FROM tmp_slots_final
    WHERE stat_type <> 0 AND stat_value <> 0
  );

  IF IFNULL(p_apply,0) <> 0 THEN
    UPDATE lplusworld.item_template t
    JOIN (
      SELECT
        MAX(CASE WHEN slot_no=1 THEN stat_type END) AS st1,
        MAX(CASE WHEN slot_no=1 THEN stat_value END) AS sv1,
        MAX(CASE WHEN slot_no=2 THEN stat_type END) AS st2,
        MAX(CASE WHEN slot_no=2 THEN stat_value END) AS sv2,
        MAX(CASE WHEN slot_no=3 THEN stat_type END) AS st3,
        MAX(CASE WHEN slot_no=3 THEN stat_value END) AS sv3,
        MAX(CASE WHEN slot_no=4 THEN stat_type END) AS st4,
        MAX(CASE WHEN slot_no=4 THEN stat_value END) AS sv4,
        MAX(CASE WHEN slot_no=5 THEN stat_type END) AS st5,
        MAX(CASE WHEN slot_no=5 THEN stat_value END) AS sv5,
        MAX(CASE WHEN slot_no=6 THEN stat_type END) AS st6,
        MAX(CASE WHEN slot_no=6 THEN stat_value END) AS sv6,
        MAX(CASE WHEN slot_no=7 THEN stat_type END) AS st7,
        MAX(CASE WHEN slot_no=7 THEN stat_value END) AS sv7,
        MAX(CASE WHEN slot_no=8 THEN stat_type END) AS st8,
        MAX(CASE WHEN slot_no=8 THEN stat_value END) AS sv8,
        MAX(CASE WHEN slot_no=9 THEN stat_type END) AS st9,
        MAX(CASE WHEN slot_no=9 THEN stat_value END) AS sv9,
        MAX(CASE WHEN slot_no=10 THEN stat_type END) AS st10,
        MAX(CASE WHEN slot_no=10 THEN stat_value END) AS sv10
      FROM tmp_slots_final
    ) s
    SET t.stat_type1 = IFNULL(s.st1,0), t.stat_value1 = IFNULL(s.sv1,0),
        t.stat_type2 = IFNULL(s.st2,0), t.stat_value2 = IFNULL(s.sv2,0),
        t.stat_type3 = IFNULL(s.st3,0), t.stat_value3 = IFNULL(s.sv3,0),
        t.stat_type4 = IFNULL(s.st4,0), t.stat_value4 = IFNULL(s.sv4,0),
        t.stat_type5 = IFNULL(s.st5,0), t.stat_value5 = IFNULL(s.sv5,0),
        t.stat_type6 = IFNULL(s.st6,0), t.stat_value6 = IFNULL(s.sv6,0),
        t.stat_type7 = IFNULL(s.st7,0), t.stat_value7 = IFNULL(s.sv7,0),
        t.stat_type8 = IFNULL(s.st8,0), t.stat_value8 = IFNULL(s.sv8,0),
        t.stat_type9 = IFNULL(s.st9,0), t.stat_value9 = IFNULL(s.sv9,0),
        t.stat_type10 = IFNULL(s.st10,0), t.stat_value10 = IFNULL(s.sv10,0),
        t.StatsCount = IFNULL(@statcount_new,0),
        t.holy_res = IFNULL(@res_holy_new,0),
        t.fire_res = IFNULL(@res_fire_new,0),
        t.nature_res = IFNULL(@res_nature_new,0),
        t.frost_res = IFNULL(@res_frost_new,0),
        t.shadow_res = IFNULL(@res_shadow_new,0),
        t.arcane_res = IFNULL(@res_arcane_new,0),
        t.ArmorDamageModifier = IFNULL(@bonus_armor_new,0)
    WHERE t.entry = p_entry;
  END IF;

  SELECT key_code,
         value_old,
         actual_value,
         desired_term,
         actual_term
  FROM tmp_stat_plan
  ORDER BY key_code;
END$$

DELIMITER ;
