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
  SET @W_HIT     := 2200.0;
  SET @W_SPHIT   := 2500.0;
  SET @W_CRIT    := 3200.0;
  SET @W_SPCRIT  := 2600.0;
  SET @W_MP5     :=  550.0;
  SET @W_HP5     :=  550.0;
  SET @W_RESIST  :=  230.0;
  SET @W_BONUSARMOR :=   22.0;

  SET @AURA_AP := 99;
  SET @AURA_RAP := 124;
  SET @AURA_HIT := 54;
  SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57;
  SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_MELEE := 308;
  SET @AURA_CRIT_RANGED := 290;
  SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_SD := 13;
  SET @MASK_SD_ALL := 126;
  SET @AURA_HEAL1 := 115;
  SET @AURA_HEAL2 := 135;
  SET @AURA_HEAL_PRIMARY := @AURA_HEAL2;
  SET @AURA_MP5 := 85;
  SET @AURA_HP5 := 83;

  SET @DESC_HEAL := 'Increases healing done by spells and effects by up to $s1.';
  SET @DESC_SD_ALL := 'Increases damage and healing done by magical spells and effects by up to $s1.';
  SET @DESC_CRIT := 'Improves your chance to get a critical strike by $s1%.';
  SET @DESC_SPHIT := 'Improves your chance to hit with spells by $s1%.';
  SET @DESC_HIT := 'Improves your chance to hit by $s1%.';
  SET @DESC_SPCRIT := 'Improves your chance to get a critical strike with spells by $s1%.';

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_slots;
  CREATE TEMPORARY TABLE tmp_spell_slots(
    slot_no TINYINT NOT NULL PRIMARY KEY,
    spellid INT UNSIGNED NOT NULL,
    spelltrigger TINYINT NOT NULL,
    spellcharges INT NOT NULL,
    spellppmRate DOUBLE NOT NULL,
    spellcooldown INT NOT NULL,
    spellcategory INT NOT NULL,
    spellcategorycooldown INT NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_slots(slot_no, spellid, spelltrigger, spellcharges, spellppmRate, spellcooldown, spellcategory, spellcategorycooldown)
  SELECT 1, IFNULL(spellid_1,0), IFNULL(spelltrigger_1,0), IFNULL(spellcharges_1,0), IFNULL(spellppmRate_1,0), IFNULL(spellcooldown_1,0), IFNULL(spellcategory_1,0), IFNULL(spellcategorycooldown_1,0)
  FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL
  SELECT 2, IFNULL(spellid_2,0), IFNULL(spelltrigger_2,0), IFNULL(spellcharges_2,0), IFNULL(spellppmRate_2,0), IFNULL(spellcooldown_2,0), IFNULL(spellcategory_2,0), IFNULL(spellcategorycooldown_2,0)
  FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL
  SELECT 3, IFNULL(spellid_3,0), IFNULL(spelltrigger_3,0), IFNULL(spellcharges_3,0), IFNULL(spellppmRate_3,0), IFNULL(spellcooldown_3,0), IFNULL(spellcategory_3,0), IFNULL(spellcategorycooldown_3,0)
  FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL
  SELECT 4, IFNULL(spellid_4,0), IFNULL(spelltrigger_4,0), IFNULL(spellcharges_4,0), IFNULL(spellppmRate_4,0), IFNULL(spellcooldown_4,0), IFNULL(spellcategory_4,0), IFNULL(spellcategorycooldown_4,0)
  FROM lplusworld.item_template WHERE entry = p_entry
  UNION ALL
  SELECT 5, IFNULL(spellid_5,0), IFNULL(spelltrigger_5,0), IFNULL(spellcharges_5,0), IFNULL(spellppmRate_5,0), IFNULL(spellcooldown_5,0), IFNULL(spellcategory_5,0), IFNULL(spellcategorycooldown_5,0)
  FROM lplusworld.item_template WHERE entry = p_entry;

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
    ('HIT', NULL, @W_HIT, 0, NULL, 0),
    ('SPHIT', NULL, @W_SPHIT, 0, NULL, 0),
    ('CRIT', NULL, @W_CRIT, 0, NULL, 0),
    ('SPCRIT', NULL, @W_SPCRIT, 0, NULL, 0),
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

  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells;
  CREATE TEMPORARY TABLE tmp_equip_spells(
    entry INT UNSIGNED NOT NULL,
    slot_no TINYINT NOT NULL,
    sid   INT UNSIGNED NOT NULL,
    PRIMARY KEY(entry, slot_no)
  ) ENGINE=Memory;

  INSERT INTO tmp_equip_spells(entry, slot_no, sid)
  SELECT entry, 1, spellid_1
  FROM lplusworld.item_template
  WHERE entry = p_entry
    AND spellid_1 <> 0
    AND spelltrigger_1 = 1
  UNION ALL
  SELECT entry, 2, spellid_2
  FROM lplusworld.item_template
  WHERE entry = p_entry
    AND spellid_2 <> 0
    AND spelltrigger_2 = 1
  UNION ALL
  SELECT entry, 3, spellid_3
  FROM lplusworld.item_template
  WHERE entry = p_entry
    AND spellid_3 <> 0
    AND spelltrigger_3 = 1
  UNION ALL
  SELECT entry, 4, spellid_4
  FROM lplusworld.item_template
  WHERE entry = p_entry
    AND spellid_4 <> 0
    AND spelltrigger_4 = 1
  UNION ALL
  SELECT entry, 5, spellid_5
  FROM lplusworld.item_template
  WHERE entry = p_entry
    AND spellid_5 <> 0
    AND spelltrigger_5 = 1;

  UPDATE dbc.spell_lplus s
  JOIN tmp_equip_spells es ON es.sid = s.ID
  SET s.Description_Lang_enUS = @DESC_HEAL
  WHERE IFNULL(s.Description_Lang_enUS,'') <> @DESC_HEAL
    AND (
          IFNULL(s.EffectAura_1,0) IN (@AURA_HEAL1, @AURA_HEAL2)
       OR IFNULL(s.EffectAura_2,0) IN (@AURA_HEAL1, @AURA_HEAL2)
       OR IFNULL(s.EffectAura_3,0) IN (@AURA_HEAL1, @AURA_HEAL2)
        );

  UPDATE dbc.spell_lplus s
  JOIN tmp_equip_spells es ON es.sid = s.ID
  SET s.Description_Lang_enUS = @DESC_SD_ALL
  WHERE IFNULL(s.Description_Lang_enUS,'') <> @DESC_SD_ALL
    AND (
          (IFNULL(s.EffectAura_1,0) = @AURA_SD AND (IFNULL(s.EffectMiscValue_1,0) & @MASK_SD_ALL) = @MASK_SD_ALL)
       OR (IFNULL(s.EffectAura_2,0) = @AURA_SD AND (IFNULL(s.EffectMiscValue_2,0) & @MASK_SD_ALL) = @MASK_SD_ALL)
       OR (IFNULL(s.EffectAura_3,0) = @AURA_SD AND (IFNULL(s.EffectMiscValue_3,0) & @MASK_SD_ALL) = @MASK_SD_ALL)
        );

  UPDATE dbc.spell_lplus s
  JOIN tmp_equip_spells es ON es.sid = s.ID
  SET s.Description_Lang_enUS = @DESC_HIT
  WHERE IFNULL(s.Description_Lang_enUS,'') <> @DESC_HIT
    AND (
          IFNULL(s.EffectAura_1,0) = @AURA_HIT
       OR IFNULL(s.EffectAura_2,0) = @AURA_HIT
       OR IFNULL(s.EffectAura_3,0) = @AURA_HIT
        );

  UPDATE dbc.spell_lplus s
  JOIN tmp_equip_spells es ON es.sid = s.ID
  SET s.Description_Lang_enUS = @DESC_SPHIT
  WHERE IFNULL(s.Description_Lang_enUS,'') <> @DESC_SPHIT
    AND (
          IFNULL(s.EffectAura_1,0) = @AURA_SPHIT
       OR IFNULL(s.EffectAura_2,0) = @AURA_SPHIT
       OR IFNULL(s.EffectAura_3,0) = @AURA_SPHIT
        );

  UPDATE dbc.spell_lplus s
  JOIN tmp_equip_spells es ON es.sid = s.ID
  SET s.Description_Lang_enUS = @DESC_SPCRIT
  WHERE IFNULL(s.Description_Lang_enUS,'') <> @DESC_SPCRIT
    AND (
          IFNULL(s.EffectAura_1,0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2)
       OR IFNULL(s.EffectAura_2,0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2)
       OR IFNULL(s.EffectAura_3,0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2)
        );

  UPDATE dbc.spell_lplus s
  JOIN tmp_equip_spells es ON es.sid = s.ID
  SET s.Description_Lang_enUS = @DESC_CRIT
  WHERE IFNULL(s.Description_Lang_enUS,'') <> @DESC_CRIT
    AND (
          IFNULL(s.EffectAura_1,0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED)
       OR IFNULL(s.EffectAura_2,0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED)
       OR IFNULL(s.EffectAura_3,0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED)
        );

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_contribs;
  CREATE TEMPORARY TABLE tmp_spell_contribs(
    entry INT UNSIGNED NOT NULL,
    slot_no TINYINT NOT NULL,
    sid INT UNSIGNED NOT NULL,
    ap_amt DOUBLE NOT NULL DEFAULT 0,
    rap_amt DOUBLE NOT NULL DEFAULT 0,
    hit_amt DOUBLE NOT NULL DEFAULT 0,
    hit_aura INT,
    hit_misc INT,
    sphit_amt DOUBLE NOT NULL DEFAULT 0,
    sphit_aura INT,
    sphit_misc INT,
    spcrit_amt DOUBLE NOT NULL DEFAULT 0,
    spcrit_aura INT,
    spcrit_misc INT,
    crit_amt DOUBLE NOT NULL DEFAULT 0,
    crit_aura INT,
    crit_misc INT,
    sd_all_amt DOUBLE NOT NULL DEFAULT 0,
    heal_amt DOUBLE NOT NULL DEFAULT 0,
    mp5_amt DOUBLE NOT NULL DEFAULT 0,
    hp5_amt DOUBLE NOT NULL DEFAULT 0,
    PRIMARY KEY(entry, slot_no)
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_contribs(entry, slot_no, sid, ap_amt, rap_amt, hit_amt, hit_aura, hit_misc,
                                 sphit_amt, sphit_aura, sphit_misc,
                                 spcrit_amt, spcrit_aura, spcrit_misc,
                                 crit_amt, crit_aura, crit_misc,
                                 sd_all_amt, heal_amt, mp5_amt, hp5_amt)
  SELECT raw.entry,
         raw.slot_no,
         raw.sid,
         CASE
           WHEN raw.ap_raw > 0 AND raw.rap_raw > 0 THEN GREATEST(raw.ap_raw, raw.rap_raw)
           ELSE raw.ap_raw
         END AS ap_amt,
         CASE
           WHEN raw.ap_raw > 0 AND raw.rap_raw > 0 THEN 0
           ELSE raw.rap_raw
         END AS rap_amt,
         raw.hit_raw AS hit_amt,
         raw.hit_aura_raw AS hit_aura,
         raw.hit_misc_raw AS hit_misc,
         raw.sphit_raw AS sphit_amt,
         raw.sphit_aura_raw AS sphit_aura,
         raw.sphit_misc_raw AS sphit_misc,
         raw.spcrit_raw AS spcrit_amt,
         raw.spcrit_aura_raw AS spcrit_aura,
         raw.spcrit_misc_raw AS spcrit_misc,
         raw.crit_raw AS crit_amt,
         raw.crit_aura_raw AS crit_aura,
         raw.crit_misc_raw AS crit_misc,
         raw.sd_all_amt,
         CASE
           WHEN raw.sd_all_amt > 0 AND raw.heal_raw > 0 THEN 0
           ELSE raw.heal_raw
         END AS heal_amt,
         raw.mp5_amt,
         raw.hp5_amt
  FROM (
    SELECT es.entry, es.slot_no, es.sid,
           (CASE
              WHEN s.EffectAura_1 = @AURA_AP THEN (s.EffectBasePoints_1 + 1)
              WHEN s.EffectAura_2 = @AURA_AP THEN (s.EffectBasePoints_2 + 1)
              WHEN s.EffectAura_3 = @AURA_AP THEN (s.EffectBasePoints_3 + 1)
              ELSE 0
            END) AS ap_raw,
           (CASE
              WHEN s.EffectAura_1 = @AURA_RAP THEN (s.EffectBasePoints_1 + 1)
              WHEN s.EffectAura_2 = @AURA_RAP THEN (s.EffectBasePoints_2 + 1)
              WHEN s.EffectAura_3 = @AURA_RAP THEN (s.EffectBasePoints_3 + 1)
              ELSE 0
            END) AS rap_raw,
            ((CASE WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_1 = @AURA_HIT THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_2 = @AURA_HIT THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_3 = @AURA_HIT THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS hit_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_1 = @AURA_HIT AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectAura_1
               WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_2 = @AURA_HIT AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectAura_2
               WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_3 = @AURA_HIT AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectAura_3
               ELSE NULL
             END) AS hit_aura_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_1 = @AURA_HIT AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectMiscValue_1
               WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_2 = @AURA_HIT AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectMiscValue_2
               WHEN s.Description_Lang_enUS = @DESC_HIT AND s.EffectAura_3 = @AURA_HIT AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectMiscValue_3
               ELSE NULL
             END) AS hit_misc_raw,
            ((CASE WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_1 = @AURA_SPHIT THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_2 = @AURA_SPHIT THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_3 = @AURA_SPHIT THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS sphit_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_1 = @AURA_SPHIT AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectAura_1
               WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_2 = @AURA_SPHIT AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectAura_2
               WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_3 = @AURA_SPHIT AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectAura_3
               ELSE NULL
             END) AS sphit_aura_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_1 = @AURA_SPHIT AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectMiscValue_1
               WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_2 = @AURA_SPHIT AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectMiscValue_2
               WHEN s.Description_Lang_enUS = @DESC_SPHIT AND s.EffectAura_3 = @AURA_SPHIT AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectMiscValue_3
               ELSE NULL
             END) AS sphit_misc_raw,
            ((CASE WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_1 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_2 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_3 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS spcrit_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_1 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectAura_1
               WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_2 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectAura_2
               WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_3 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectAura_3
               ELSE NULL
             END) AS spcrit_aura_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_1 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectMiscValue_1
               WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_2 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectMiscValue_2
               WHEN s.Description_Lang_enUS = @DESC_SPCRIT AND s.EffectAura_3 IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectMiscValue_3
               ELSE NULL
             END) AS spcrit_misc_raw,
            ((CASE WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_1 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_2 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_3 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS crit_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_1 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectAura_1
               WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_2 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectAura_2
               WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_3 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectAura_3
               ELSE NULL
             END) AS crit_aura_raw,
            (CASE
               WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_1 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND (s.EffectBasePoints_1 + 1) > 0 THEN s.EffectMiscValue_1
               WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_2 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND (s.EffectBasePoints_2 + 1) > 0 THEN s.EffectMiscValue_2
               WHEN s.Description_Lang_enUS = @DESC_CRIT AND s.EffectAura_3 IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND (s.EffectBasePoints_3 + 1) > 0 THEN s.EffectMiscValue_3
               ELSE NULL
             END) AS crit_misc_raw,
            ((CASE WHEN s.Description_Lang_enUS = @DESC_SD_ALL AND s.EffectAura_1 = @AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL) = @MASK_SD_ALL THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_SD_ALL AND s.EffectAura_2 = @AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL) = @MASK_SD_ALL THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_SD_ALL AND s.EffectAura_3 = @AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL) = @MASK_SD_ALL THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS sd_all_amt,
            ((CASE WHEN s.Description_Lang_enUS = @DESC_HEAL AND s.EffectAura_1 IN (@AURA_HEAL1, @AURA_HEAL2) THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_HEAL AND s.EffectAura_2 IN (@AURA_HEAL1, @AURA_HEAL2) THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.Description_Lang_enUS = @DESC_HEAL AND s.EffectAura_3 IN (@AURA_HEAL1, @AURA_HEAL2) THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS heal_raw,
            ((CASE WHEN s.EffectAura_1 = @AURA_MP5 AND s.EffectMiscValue_1 = 0 THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.EffectAura_2 = @AURA_MP5 AND s.EffectMiscValue_2 = 0 THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.EffectAura_3 = @AURA_MP5 AND s.EffectMiscValue_3 = 0 THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS mp5_amt,
            ((CASE WHEN s.EffectAura_1 = @AURA_HP5 THEN (s.EffectBasePoints_1 + 1) ELSE 0 END) +
             (CASE WHEN s.EffectAura_2 = @AURA_HP5 THEN (s.EffectBasePoints_2 + 1) ELSE 0 END) +
             (CASE WHEN s.EffectAura_3 = @AURA_HP5 THEN (s.EffectBasePoints_3 + 1) ELSE 0 END)) AS hp5_amt
    FROM tmp_equip_spells es
    JOIN dbc.spell_lplus s ON s.ID = es.sid
  ) raw;

  DROP TEMPORARY TABLE IF EXISTS tmp_aura_flat;
  CREATE TEMPORARY TABLE tmp_aura_flat(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    ap_amt DOUBLE NOT NULL DEFAULT 0,
    rap_amt DOUBLE NOT NULL DEFAULT 0,
    hit_amt DOUBLE NOT NULL DEFAULT 0,
    sphit_amt DOUBLE NOT NULL DEFAULT 0,
    spcrit_amt DOUBLE NOT NULL DEFAULT 0,
    crit_amt DOUBLE NOT NULL DEFAULT 0,
    sd_all_amt DOUBLE NOT NULL DEFAULT 0,
    heal_amt DOUBLE NOT NULL DEFAULT 0,
    mp5_amt DOUBLE NOT NULL DEFAULT 0,
    hp5_amt DOUBLE NOT NULL DEFAULT 0
  ) ENGINE=Memory;

  INSERT INTO tmp_aura_flat(entry, ap_amt, rap_amt, hit_amt, sphit_amt, spcrit_amt, crit_amt, sd_all_amt, heal_amt, mp5_amt, hp5_amt)
  SELECT entry,
         SUM(ap_amt),
         SUM(rap_amt),
         SUM(hit_amt),
         SUM(sphit_amt),
         SUM(spcrit_amt),
         SUM(crit_amt),
         SUM(sd_all_amt),
         SUM(heal_amt),
         SUM(mp5_amt),
         SUM(hp5_amt)
  FROM tmp_spell_contribs
  GROUP BY entry;

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_defaults;
  CREATE TEMPORARY TABLE tmp_spell_defaults(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    hit_aura INT,
    hit_misc INT,
    sphit_aura INT,
    sphit_misc INT,
    spcrit_aura INT,
    spcrit_misc INT,
    crit_aura INT,
    crit_misc INT
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_defaults(entry, hit_aura, hit_misc, sphit_aura, sphit_misc, spcrit_aura, spcrit_misc, crit_aura, crit_misc)
  SELECT entry,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN hit_amt > 0 AND hit_aura IS NOT NULL THEN hit_aura END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS hit_aura,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN hit_amt > 0 AND hit_misc IS NOT NULL THEN hit_misc END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS hit_misc,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN sphit_amt > 0 AND sphit_aura IS NOT NULL THEN sphit_aura END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS sphit_aura,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN sphit_amt > 0 AND sphit_misc IS NOT NULL THEN sphit_misc END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS sphit_misc,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN spcrit_amt > 0 AND spcrit_aura IS NOT NULL THEN spcrit_aura END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS spcrit_aura,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN spcrit_amt > 0 AND spcrit_misc IS NOT NULL THEN spcrit_misc END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS spcrit_misc,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN crit_amt > 0 AND crit_aura IS NOT NULL THEN crit_aura END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS crit_aura,
         CAST(NULLIF(SUBSTRING_INDEX(GROUP_CONCAT(CASE WHEN crit_amt > 0 AND crit_misc IS NOT NULL THEN crit_misc END ORDER BY slot_no SEPARATOR ','), ',', 1), '') AS SIGNED) AS crit_misc
  FROM tmp_spell_contribs
  GROUP BY entry;

  INSERT IGNORE INTO tmp_spell_defaults(entry)
  VALUES (p_entry);

  UPDATE tmp_stat_plan p
  LEFT JOIN tmp_aura_flat af ON af.entry = p_entry
  SET p.value_old = CASE p.key_code
                      WHEN 'AP' THEN p.value_old + IFNULL(af.ap_amt, 0)
                      WHEN 'RAP' THEN p.value_old + IFNULL(af.rap_amt, 0)
                      WHEN 'HIT' THEN p.value_old + IFNULL(af.hit_amt, 0)
                      WHEN 'SPHIT' THEN p.value_old + IFNULL(af.sphit_amt, 0)
                      WHEN 'SPCRIT' THEN p.value_old + IFNULL(af.spcrit_amt, 0)
                      WHEN 'CRIT' THEN p.value_old + IFNULL(af.crit_amt, 0)
                      WHEN 'SD_ALL' THEN p.value_old + IFNULL(af.sd_all_amt, 0)
                      WHEN 'HEAL' THEN p.value_old + IFNULL(af.heal_amt, 0)
                      WHEN 'MP5' THEN p.value_old + IFNULL(af.mp5_amt, 0)
                      WHEN 'HP5' THEN p.value_old + IFNULL(af.hp5_amt, 0)
                      ELSE p.value_old
                    END
  WHERE p.key_code IN ('AP','RAP','HIT','SPHIT','SPCRIT','CRIT','SD_ALL','HEAL','MP5','HP5');

  DROP TEMPORARY TABLE IF EXISTS tmp_aura_flat;
  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells;

  IF (SELECT COUNT(*) FROM tmp_stat_plan WHERE key_code = v_source_key) = 0 THEN
    LEAVE proc;
  END IF;

  IF v_target_key IS NOT NULL AND (SELECT COUNT(*) FROM tmp_stat_plan WHERE key_code = v_target_key) = 0 THEN
    INSERT INTO tmp_stat_plan(key_code, stat_type, weight, value_old, desired_value, desired_term, desired_term_new,
                              actual_value, actual_term, is_resist, resist_column, is_bonus)
    SELECT c.key_code, c.stat_type, c.weight, 0, 0, 0, 0, 0, 0, c.is_resist, c.resist_column, c.is_bonus
    FROM tmp_stat_catalog c
    WHERE c.key_code = v_target_key
    LIMIT 1;

    IF ROW_COUNT() = 0 THEN
      LEAVE proc;
    END IF;
  END IF;

  DELETE FROM tmp_stat_plan
  WHERE value_old <= 0
    AND key_code <> v_source_key
    AND (v_target_key IS NULL OR key_code <> v_target_key);

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
    SET v_target_count := (
      SELECT COUNT(*)
      FROM tmp_stat_plan
      WHERE key_code <> v_source_key
        AND value_old > 0
    );
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
      IF v_new_total > 0 THEN
        SET v_slot_no := (
          SELECT slot_no
          FROM tmp_stat_slots
          WHERE stat_type = 0
          ORDER BY slot_no
          LIMIT 1
        );

        IF v_slot_no IS NOT NULL THEN
          UPDATE tmp_stat_slots
          SET stat_type = v_stat_type,
              stat_value = ROUND(GREATEST(0, v_new_total))
          WHERE slot_no = v_slot_no;
        END IF;
      END IF;

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

  DROP TEMPORARY TABLE IF EXISTS tmp_aura_requirements;
  CREATE TEMPORARY TABLE tmp_aura_requirements(
    aura_code VARCHAR(32) NOT NULL,
    effect_aura INT NOT NULL,
    effect_misc INT NOT NULL,
    magnitude INT NOT NULL,
    desc_enUS VARCHAR(255),
    PRIMARY KEY(aura_code, magnitude)
  ) ENGINE=Memory;

  INSERT INTO tmp_aura_requirements(aura_code, effect_aura, effect_misc, magnitude, desc_enUS)
  SELECT p.key_code,
         CASE p.key_code
           WHEN 'AP' THEN @AURA_AP
           WHEN 'RAP' THEN @AURA_RAP
           WHEN 'HIT' THEN COALESCE(sd.hit_aura, @AURA_HIT)
           WHEN 'SPHIT' THEN COALESCE(sd.sphit_aura, @AURA_SPHIT)
           WHEN 'SPCRIT' THEN COALESCE(sd.spcrit_aura, @AURA_SPCRIT2)
           WHEN 'CRIT' THEN COALESCE(sd.crit_aura, @AURA_CRIT_GENERIC)
           WHEN 'SD_ALL' THEN @AURA_SD
           WHEN 'HEAL' THEN @AURA_HEAL_PRIMARY
           WHEN 'MP5' THEN @AURA_MP5
           WHEN 'HP5' THEN @AURA_HP5
           ELSE NULL
         END,
         CASE p.key_code
           WHEN 'HIT' THEN COALESCE(sd.hit_misc, 0)
           WHEN 'SPHIT' THEN COALESCE(sd.sphit_misc, 0)
           WHEN 'SPCRIT' THEN COALESCE(sd.spcrit_misc, 0)
           WHEN 'CRIT' THEN COALESCE(sd.crit_misc, 0)
           ELSE 0
         END,
         ROUND(GREATEST(0, p.actual_value)),
         CASE p.key_code
           WHEN 'HEAL' THEN @DESC_HEAL
           WHEN 'SD_ALL' THEN @DESC_SD_ALL
           WHEN 'HIT' THEN @DESC_HIT
           WHEN 'SPHIT' THEN @DESC_SPHIT
           WHEN 'SPCRIT' THEN @DESC_SPCRIT
           WHEN 'CRIT' THEN @DESC_CRIT
           ELSE NULL
         END
  FROM tmp_stat_plan p
  LEFT JOIN tmp_spell_defaults sd ON sd.entry = p_entry
  WHERE key_code IN ('AP','RAP','HIT','SPHIT','SPCRIT','CRIT','SD_ALL','HEAL','MP5','HP5')
    AND ROUND(GREATEST(0, actual_value)) > 0;

  DELETE FROM tmp_aura_requirements
  WHERE effect_aura IS NULL;

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_defaults;

  DROP TEMPORARY TABLE IF EXISTS tmp_aura_fixup;
  CREATE TEMPORARY TABLE tmp_aura_fixup(
    aura_code VARCHAR(32) NOT NULL,
    spellid INT UNSIGNED NOT NULL,
    new_desc VARCHAR(255) NOT NULL,
    PRIMARY KEY(aura_code, spellid)
  ) ENGINE=Memory;

  INSERT INTO tmp_aura_fixup(aura_code, spellid, new_desc)
  SELECT DISTINCT r.aura_code, s.ID, r.desc_enUS
  FROM tmp_aura_requirements r
  JOIN dbc.spell_lplus s ON (
        (IFNULL(s.EffectAura_1,0) = r.effect_aura AND IFNULL(s.EffectMiscValue_1,0) = r.effect_misc AND IFNULL(s.EffectBasePoints_1,0) + 1 = r.magnitude)
     OR (IFNULL(s.EffectAura_2,0) = r.effect_aura AND IFNULL(s.EffectMiscValue_2,0) = r.effect_misc AND IFNULL(s.EffectBasePoints_2,0) + 1 = r.magnitude)
     OR (IFNULL(s.EffectAura_3,0) = r.effect_aura AND IFNULL(s.EffectMiscValue_3,0) = r.effect_misc AND IFNULL(s.EffectBasePoints_3,0) + 1 = r.magnitude)
  )
  WHERE r.desc_enUS IS NOT NULL
    AND IFNULL(s.Description_Lang_enUS,'') <> r.desc_enUS;

  UPDATE dbc.spell_lplus s
  JOIN tmp_aura_fixup f ON f.spellid = s.ID
  SET s.Description_Lang_enUS = f.new_desc;

  DROP TEMPORARY TABLE IF EXISTS tmp_aura_missing;
  CREATE TEMPORARY TABLE tmp_aura_missing(
    aura_code VARCHAR(32) NOT NULL,
    effect_aura INT NOT NULL,
    effect_misc INT NOT NULL,
    magnitude INT NOT NULL,
    desc_enUS VARCHAR(255),
    PRIMARY KEY(aura_code, magnitude)
  ) ENGINE=Memory;

  INSERT INTO tmp_aura_missing(aura_code, effect_aura, effect_misc, magnitude, desc_enUS)
  SELECT r.aura_code, r.effect_aura, r.effect_misc, r.magnitude, r.desc_enUS
  FROM tmp_aura_requirements r
  WHERE NOT EXISTS (
    SELECT 1
    FROM dbc.spell_lplus s
    WHERE (
           (IFNULL(s.EffectAura_1,0) = r.effect_aura AND IFNULL(s.EffectMiscValue_1,0) = r.effect_misc AND IFNULL(s.EffectBasePoints_1,0) + 1 = r.magnitude)
        OR (IFNULL(s.EffectAura_2,0) = r.effect_aura AND IFNULL(s.EffectMiscValue_2,0) = r.effect_misc AND IFNULL(s.EffectBasePoints_2,0) + 1 = r.magnitude)
        OR (IFNULL(s.EffectAura_3,0) = r.effect_aura AND IFNULL(s.EffectMiscValue_3,0) = r.effect_misc AND IFNULL(s.EffectBasePoints_3,0) + 1 = r.magnitude)
          )
      AND (r.desc_enUS IS NULL OR IFNULL(s.Description_Lang_enUS,'') = r.desc_enUS)
  );

  SET @missing_aura_count := (SELECT COUNT(*) FROM tmp_aura_missing);

  IF @missing_aura_count > 0 THEN
    BEGIN
      DECLARE missing_done INT DEFAULT 0;
      DECLARE v_missing_aura_code VARCHAR(32);
      DECLARE v_missing_effect_aura INT;
      DECLARE v_missing_effect_misc INT;
      DECLARE v_missing_magnitude INT;
      DECLARE v_missing_desc VARCHAR(255);
      DECLARE v_template_id INT;
      DECLARE v_new_spellid INT;
      DECLARE cur_missing CURSOR FOR
        SELECT aura_code, effect_aura, effect_misc, magnitude, desc_enUS
        FROM tmp_aura_missing;
      DECLARE CONTINUE HANDLER FOR NOT FOUND SET missing_done = 1;

      SET @next_spell_id := NULL;
      SET missing_done := 0;

      OPEN cur_missing;
      missing_loop: LOOP
        FETCH cur_missing INTO v_missing_aura_code, v_missing_effect_aura, v_missing_effect_misc, v_missing_magnitude, v_missing_desc;
        IF missing_done = 1 THEN
          LEAVE missing_loop;
        END IF;

        SET v_template_id := NULL;

        SELECT sc.sid
          INTO v_template_id
        FROM tmp_spell_contribs sc
        WHERE sc.entry = p_entry
          AND ((v_missing_aura_code = 'AP' AND sc.ap_amt > 0)
            OR (v_missing_aura_code = 'RAP' AND sc.rap_amt > 0)
            OR (v_missing_aura_code = 'HIT' AND sc.hit_amt > 0)
            OR (v_missing_aura_code = 'SPHIT' AND sc.sphit_amt > 0)
            OR (v_missing_aura_code = 'SPCRIT' AND sc.spcrit_amt > 0)
            OR (v_missing_aura_code = 'CRIT' AND sc.crit_amt > 0)
            OR (v_missing_aura_code = 'SD_ALL' AND sc.sd_all_amt > 0)
            OR (v_missing_aura_code = 'HEAL' AND sc.heal_amt > 0)
            OR (v_missing_aura_code = 'MP5' AND sc.mp5_amt > 0)
            OR (v_missing_aura_code = 'HP5' AND sc.hp5_amt > 0))
        ORDER BY sc.slot_no
        LIMIT 1;

        IF v_template_id IS NULL THEN
          SELECT ID
            INTO v_template_id
          FROM dbc.spell_lplus
          WHERE (IFNULL(EffectAura_1,0) = v_missing_effect_aura AND IFNULL(EffectMiscValue_1,0) = v_missing_effect_misc)
             OR (IFNULL(EffectAura_2,0) = v_missing_effect_aura AND IFNULL(EffectMiscValue_2,0) = v_missing_effect_misc)
             OR (IFNULL(EffectAura_3,0) = v_missing_effect_aura AND IFNULL(EffectMiscValue_3,0) = v_missing_effect_misc)
          ORDER BY CASE
                     WHEN v_missing_desc IS NOT NULL AND IFNULL(Description_Lang_enUS,'') = v_missing_desc THEN 0
                     WHEN v_missing_aura_code = 'HEAL' AND IFNULL(Description_Lang_enUS,'') LIKE 'Increases healing done by spells and effects by up to $s1%' THEN 1
                     WHEN v_missing_aura_code = 'SD_ALL' AND IFNULL(Description_Lang_enUS,'') LIKE 'Increases damage and healing done by magical spells and effects by up to $s1%' THEN 1
                     WHEN v_missing_aura_code = 'AP' AND IFNULL(Description_Lang_enUS,'') LIKE 'Increases attack power by $s1%' THEN 1
                     WHEN v_missing_aura_code = 'RAP' AND IFNULL(Description_Lang_enUS,'') LIKE 'Increases ranged attack power by $s1%' THEN 1
                     WHEN v_missing_aura_code = 'MP5' AND IFNULL(Description_Lang_enUS,'') LIKE 'Restores $s1 mana per 5 sec%' THEN 1
                     WHEN v_missing_aura_code = 'HP5' AND (IFNULL(Description_Lang_enUS,'') LIKE 'Restores $s1 health every 5 sec%' OR IFNULL(Description_Lang_enUS,'') LIKE 'Restores $s1 health per 5 sec%') THEN 1
                     ELSE 2
                   END,
                   ID
          LIMIT 1;
        END IF;

        IF v_template_id IS NULL THEN
          ITERATE missing_loop;
        END IF;

        IF @next_spell_id IS NULL THEN
          SET @next_spell_id := (SELECT IFNULL(MAX(ID), 0) FROM dbc.spell_lplus);
        END IF;

        SET @next_spell_id := @next_spell_id + 1;
        SET v_new_spellid := @next_spell_id;

        DROP TEMPORARY TABLE IF EXISTS tmp_single_clone;
        CREATE TEMPORARY TABLE tmp_single_clone LIKE dbc.spell_lplus;

        INSERT INTO tmp_single_clone
        SELECT *
        FROM dbc.spell_lplus
        WHERE ID = v_template_id;

        UPDATE tmp_single_clone
        SET ID = v_new_spellid,
            EffectBasePoints_1 = CASE WHEN IFNULL(EffectAura_1,0) = v_missing_effect_aura AND IFNULL(EffectMiscValue_1,0) = v_missing_effect_misc THEN v_missing_magnitude - 1 ELSE EffectBasePoints_1 END,
            EffectBasePoints_2 = CASE WHEN IFNULL(EffectAura_2,0) = v_missing_effect_aura AND IFNULL(EffectMiscValue_2,0) = v_missing_effect_misc THEN v_missing_magnitude - 1 ELSE EffectBasePoints_2 END,
            EffectBasePoints_3 = CASE WHEN IFNULL(EffectAura_3,0) = v_missing_effect_aura AND IFNULL(EffectMiscValue_3,0) = v_missing_effect_misc THEN v_missing_magnitude - 1 ELSE EffectBasePoints_3 END,
            Description_Lang_enUS = CASE WHEN v_missing_desc IS NOT NULL THEN v_missing_desc ELSE Description_Lang_enUS END;

        INSERT INTO dbc.spell_lplus
        SELECT * FROM tmp_single_clone;

        DROP TEMPORARY TABLE IF EXISTS tmp_single_clone;
      END LOOP missing_loop;
      CLOSE cur_missing;
    END;
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_slot_tracked;
  CREATE TEMPORARY TABLE tmp_slot_tracked(
    slot_no TINYINT NOT NULL PRIMARY KEY
  ) ENGINE=Memory;

  INSERT INTO tmp_slot_tracked(slot_no)
  SELECT DISTINCT slot_no
  FROM tmp_spell_contribs
  WHERE entry = p_entry
    AND (ap_amt > 0 OR rap_amt > 0 OR hit_amt > 0 OR sphit_amt > 0 OR spcrit_amt > 0 OR crit_amt > 0
      OR sd_all_amt > 0 OR heal_amt > 0 OR mp5_amt > 0 OR hp5_amt > 0);

  IF (SELECT COUNT(*) FROM tmp_slot_tracked) = 0 THEN
    INSERT INTO tmp_slot_tracked(slot_no)
    SELECT slot_no
    FROM tmp_spell_slots
    WHERE spelltrigger = 1
    ORDER BY slot_no;
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_slot_available;
  CREATE TEMPORARY TABLE tmp_slot_available(
    slot_no TINYINT NOT NULL PRIMARY KEY
  ) ENGINE=Memory;

  INSERT INTO tmp_slot_available(slot_no)
  SELECT slot_no
  FROM tmp_slot_tracked;

  DROP TEMPORARY TABLE IF EXISTS tmp_stat_slot_plan;
  CREATE TEMPORARY TABLE tmp_stat_slot_plan(
    aura_code VARCHAR(32) NOT NULL,
    slot_no TINYINT,
    magnitude INT NOT NULL,
    effect_aura INT NOT NULL,
    effect_misc INT NOT NULL,
    PRIMARY KEY(aura_code)
  ) ENGINE=Memory;

  INSERT INTO tmp_stat_slot_plan(aura_code, slot_no, magnitude, effect_aura, effect_misc)
  SELECT aura_code, NULL, magnitude, effect_aura, effect_misc
  FROM tmp_aura_requirements;

  BEGIN
    DECLARE assign_done INT DEFAULT 0;
    DECLARE v_plan_aura_code VARCHAR(32);
    DECLARE v_plan_magnitude INT;
    DECLARE v_plan_effect_aura INT;
    DECLARE v_plan_effect_misc INT;
    DECLARE v_plan_slot TINYINT;

    DECLARE cur_plan CURSOR FOR
      SELECT aura_code, magnitude, effect_aura, effect_misc
      FROM tmp_stat_slot_plan
      ORDER BY aura_code;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET assign_done = 1;

    OPEN cur_plan;
    plan_loop: LOOP
      FETCH cur_plan INTO v_plan_aura_code, v_plan_magnitude, v_plan_effect_aura, v_plan_effect_misc;
      IF assign_done = 1 THEN
        LEAVE plan_loop;
      END IF;

      SET v_plan_slot := NULL;

      SELECT sc.slot_no
        INTO v_plan_slot
      FROM tmp_spell_contribs sc
      JOIN tmp_slot_available av ON av.slot_no = sc.slot_no
      WHERE sc.entry = p_entry
        AND ((v_plan_aura_code = 'AP' AND sc.ap_amt > 0)
          OR (v_plan_aura_code = 'RAP' AND sc.rap_amt > 0)
          OR (v_plan_aura_code = 'HIT' AND sc.hit_amt > 0)
          OR (v_plan_aura_code = 'SPHIT' AND sc.sphit_amt > 0)
          OR (v_plan_aura_code = 'SPCRIT' AND sc.spcrit_amt > 0)
          OR (v_plan_aura_code = 'CRIT' AND sc.crit_amt > 0)
          OR (v_plan_aura_code = 'SD_ALL' AND sc.sd_all_amt > 0)
          OR (v_plan_aura_code = 'HEAL' AND sc.heal_amt > 0)
          OR (v_plan_aura_code = 'MP5' AND sc.mp5_amt > 0)
          OR (v_plan_aura_code = 'HP5' AND sc.hp5_amt > 0))
      ORDER BY sc.slot_no
      LIMIT 1;

      IF v_plan_slot IS NULL THEN
        SELECT slot_no
          INTO v_plan_slot
        FROM tmp_slot_available
        ORDER BY slot_no
        LIMIT 1;
      END IF;

      IF v_plan_slot IS NOT NULL THEN
        UPDATE tmp_stat_slot_plan
        SET slot_no = v_plan_slot
        WHERE aura_code = v_plan_aura_code;

        DELETE FROM tmp_slot_available WHERE slot_no = v_plan_slot;
      END IF;
    END LOOP plan_loop;
    CLOSE cur_plan;
  END;

  BEGIN
    DECLARE apply_done INT DEFAULT 0;
    DECLARE v_plan_aura_code VARCHAR(32);
    DECLARE v_plan_slot TINYINT;
    DECLARE v_plan_magnitude INT;
    DECLARE v_plan_effect_aura INT;
    DECLARE v_plan_effect_misc INT;
    DECLARE v_new_spellid INT;

    DECLARE cur_apply CURSOR FOR
      SELECT aura_code, slot_no, magnitude, effect_aura, effect_misc
      FROM tmp_stat_slot_plan
      WHERE slot_no IS NOT NULL
      ORDER BY slot_no;

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET apply_done = 1;

    OPEN cur_apply;
    apply_loop: LOOP
      FETCH cur_apply INTO v_plan_aura_code, v_plan_slot, v_plan_magnitude, v_plan_effect_aura, v_plan_effect_misc;
      IF apply_done = 1 THEN
        LEAVE apply_loop;
      END IF;

      IF IFNULL(v_plan_magnitude,0) <= 0 THEN
        ITERATE apply_loop;
      END IF;

      SET v_new_spellid := NULL;

      SELECT ID
        INTO v_new_spellid
      FROM dbc.spell_lplus
      WHERE (IFNULL(EffectAura_1,0) = v_plan_effect_aura AND IFNULL(EffectMiscValue_1,0) = v_plan_effect_misc AND IFNULL(EffectBasePoints_1,0) = v_plan_magnitude - 1)
         OR (IFNULL(EffectAura_2,0) = v_plan_effect_aura AND IFNULL(EffectMiscValue_2,0) = v_plan_effect_misc AND IFNULL(EffectBasePoints_2,0) = v_plan_magnitude - 1)
         OR (IFNULL(EffectAura_3,0) = v_plan_effect_aura AND IFNULL(EffectMiscValue_3,0) = v_plan_effect_misc AND IFNULL(EffectBasePoints_3,0) = v_plan_magnitude - 1)
      ORDER BY ID
      LIMIT 1;

      IF v_new_spellid IS NOT NULL THEN
        UPDATE tmp_spell_slots
        SET spellid = v_new_spellid,
            spelltrigger = 1,
            spellcharges = 0,
            spellppmRate = 0,
            spellcooldown = 0,
            spellcategory = 0,
            spellcategorycooldown = 0
        WHERE slot_no = v_plan_slot;
      END IF;
    END LOOP apply_loop;
    CLOSE cur_apply;
  END;

  UPDATE tmp_spell_slots s
  LEFT JOIN tmp_stat_slot_plan p ON p.slot_no = s.slot_no
  LEFT JOIN tmp_slot_tracked st ON st.slot_no = s.slot_no
  SET s.spellid = 0,
      s.spelltrigger = 0,
      s.spellcharges = 0,
      s.spellppmRate = 0,
      s.spellcooldown = 0,
      s.spellcategory = 0,
      s.spellcategorycooldown = 0
  WHERE st.slot_no IS NOT NULL
    AND p.slot_no IS NULL;

  DROP TEMPORARY TABLE IF EXISTS tmp_slot_available;
  DROP TEMPORARY TABLE IF EXISTS tmp_slot_tracked;
  DROP TEMPORARY TABLE IF EXISTS tmp_stat_slot_plan;
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_contribs;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_missing;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_fixup;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_requirements;

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
    JOIN (
      SELECT
        MAX(CASE WHEN slot_no=1 THEN spellid END) AS spid1,
        MAX(CASE WHEN slot_no=1 THEN spelltrigger END) AS sptr1,
        MAX(CASE WHEN slot_no=1 THEN spellcharges END) AS spch1,
        MAX(CASE WHEN slot_no=1 THEN spellppmRate END) AS sppr1,
        MAX(CASE WHEN slot_no=1 THEN spellcooldown END) AS spcd1,
        MAX(CASE WHEN slot_no=1 THEN spellcategory END) AS spcat1,
        MAX(CASE WHEN slot_no=1 THEN spellcategorycooldown END) AS spcatcd1,
        MAX(CASE WHEN slot_no=2 THEN spellid END) AS spid2,
        MAX(CASE WHEN slot_no=2 THEN spelltrigger END) AS sptr2,
        MAX(CASE WHEN slot_no=2 THEN spellcharges END) AS spch2,
        MAX(CASE WHEN slot_no=2 THEN spellppmRate END) AS sppr2,
        MAX(CASE WHEN slot_no=2 THEN spellcooldown END) AS spcd2,
        MAX(CASE WHEN slot_no=2 THEN spellcategory END) AS spcat2,
        MAX(CASE WHEN slot_no=2 THEN spellcategorycooldown END) AS spcatcd2,
        MAX(CASE WHEN slot_no=3 THEN spellid END) AS spid3,
        MAX(CASE WHEN slot_no=3 THEN spelltrigger END) AS sptr3,
        MAX(CASE WHEN slot_no=3 THEN spellcharges END) AS spch3,
        MAX(CASE WHEN slot_no=3 THEN spellppmRate END) AS sppr3,
        MAX(CASE WHEN slot_no=3 THEN spellcooldown END) AS spcd3,
        MAX(CASE WHEN slot_no=3 THEN spellcategory END) AS spcat3,
        MAX(CASE WHEN slot_no=3 THEN spellcategorycooldown END) AS spcatcd3,
        MAX(CASE WHEN slot_no=4 THEN spellid END) AS spid4,
        MAX(CASE WHEN slot_no=4 THEN spelltrigger END) AS sptr4,
        MAX(CASE WHEN slot_no=4 THEN spellcharges END) AS spch4,
        MAX(CASE WHEN slot_no=4 THEN spellppmRate END) AS sppr4,
        MAX(CASE WHEN slot_no=4 THEN spellcooldown END) AS spcd4,
        MAX(CASE WHEN slot_no=4 THEN spellcategory END) AS spcat4,
        MAX(CASE WHEN slot_no=4 THEN spellcategorycooldown END) AS spcatcd4,
        MAX(CASE WHEN slot_no=5 THEN spellid END) AS spid5,
        MAX(CASE WHEN slot_no=5 THEN spelltrigger END) AS sptr5,
        MAX(CASE WHEN slot_no=5 THEN spellcharges END) AS spch5,
        MAX(CASE WHEN slot_no=5 THEN spellppmRate END) AS sppr5,
        MAX(CASE WHEN slot_no=5 THEN spellcooldown END) AS spcd5,
        MAX(CASE WHEN slot_no=5 THEN spellcategory END) AS spcat5,
        MAX(CASE WHEN slot_no=5 THEN spellcategorycooldown END) AS spcatcd5
      FROM tmp_spell_slots
    ) sp ON 1=1
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
        t.ArmorDamageModifier = IFNULL(@bonus_armor_new,0),
        t.spellid_1 = IFNULL(sp.spid1,0),
        t.spelltrigger_1 = IFNULL(sp.sptr1,0),
        t.spellcharges_1 = IFNULL(sp.spch1,0),
        t.spellppmRate_1 = IFNULL(sp.sppr1,0),
        t.spellcooldown_1 = IFNULL(sp.spcd1,0),
        t.spellcategory_1 = IFNULL(sp.spcat1,0),
        t.spellcategorycooldown_1 = IFNULL(sp.spcatcd1,0),
        t.spellid_2 = IFNULL(sp.spid2,0),
        t.spelltrigger_2 = IFNULL(sp.sptr2,0),
        t.spellcharges_2 = IFNULL(sp.spch2,0),
        t.spellppmRate_2 = IFNULL(sp.sppr2,0),
        t.spellcooldown_2 = IFNULL(sp.spcd2,0),
        t.spellcategory_2 = IFNULL(sp.spcat2,0),
        t.spellcategorycooldown_2 = IFNULL(sp.spcatcd2,0),
        t.spellid_3 = IFNULL(sp.spid3,0),
        t.spelltrigger_3 = IFNULL(sp.sptr3,0),
        t.spellcharges_3 = IFNULL(sp.spch3,0),
        t.spellppmRate_3 = IFNULL(sp.sppr3,0),
        t.spellcooldown_3 = IFNULL(sp.spcd3,0),
        t.spellcategory_3 = IFNULL(sp.spcat3,0),
        t.spellcategorycooldown_3 = IFNULL(sp.spcatcd3,0),
        t.spellid_4 = IFNULL(sp.spid4,0),
        t.spelltrigger_4 = IFNULL(sp.sptr4,0),
        t.spellcharges_4 = IFNULL(sp.spch4,0),
        t.spellppmRate_4 = IFNULL(sp.sppr4,0),
        t.spellcooldown_4 = IFNULL(sp.spcd4,0),
        t.spellcategory_4 = IFNULL(sp.spcat4,0),
        t.spellcategorycooldown_4 = IFNULL(sp.spcatcd4,0),
        t.spellid_5 = IFNULL(sp.spid5,0),
        t.spelltrigger_5 = IFNULL(sp.sptr5,0),
        t.spellcharges_5 = IFNULL(sp.spch5,0),
        t.spellppmRate_5 = IFNULL(sp.sppr5,0),
        t.spellcooldown_5 = IFNULL(sp.spcd5,0),
        t.spellcategory_5 = IFNULL(sp.spcat5,0),
        t.spellcategorycooldown_5 = IFNULL(sp.spcatcd5,0)
    WHERE t.entry = p_entry;
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_slots;

  SELECT key_code,
         value_old,
         actual_value,
         desired_term,
         actual_term
  FROM tmp_stat_plan
  ORDER BY key_code;
END$$

DELIMITER ;
