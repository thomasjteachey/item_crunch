CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleItemToIlvl_SimpleGreedy_v2`(
  IN p_entry INT UNSIGNED,
  IN p_target_ilvl INT UNSIGNED,
  IN p_apply TINYINT(1),            -- 0=dry run, 1=apply changes
  IN p_scale_auras TINYINT(1),      -- 0=skip aura scaling, nonzero=scale auras
  IN p_keep_bonus_armor TINYINT(1), -- currently ignored, base armor always scales
  IN p_scale_unknown_auras TINYINT(1) -- nonzero = also scale weird/unknown auras
)
proc: BEGIN
  /* ========================
     DECLARES (must be first)
     ======================== */
  DECLARE v_class          TINYINT UNSIGNED;
  DECLARE v_subclass       TINYINT UNSIGNED;
  DECLARE v_quality        TINYINT UNSIGNED;
  DECLARE v_inv            TINYINT UNSIGNED;
  DECLARE v_ilvl_cur       INT;
  DECLARE v_caster_flag    TINYINT(1);
  DECLARE v_delay_ms       INT;

  DECLARE v_slotmod        DOUBLE;
  DECLARE v_a              DOUBLE;
  DECLARE v_b              DOUBLE;
  DECLARE v_ISV_cur        DOUBLE;
  DECLARE v_ISV_tgt        DOUBLE;
  DECLARE v_itemvalue_cur  DOUBLE;
  DECLARE v_itemvalue_tgt  DOUBLE;
  DECLARE v_ratio          DOUBLE;

  DECLARE v_is_caster_weapon TINYINT(1);
  DECLARE v_trade_sp_tgt     DOUBLE;
  DECLARE v_total_sp_cur     DOUBLE;
  DECLARE v_total_sp_tgt     DOUBLE;
  DECLARE v_sp_ratio         DOUBLE;

  DECLARE v_prev_defer_estimate TINYINT(1);
  DECLARE v_cur_ilvl            INT;
  DECLARE v_nudge_target        INT;
  DECLARE v_delta               INT;
  DECLARE v_nudge_pass          TINYINT UNSIGNED;

  
  DECLARE v_prev_delta          INT;
  DECLARE v_stall_count         TINYINT UNSIGNED;
  DECLARE v_added_to_queue      TINYINT UNSIGNED;
DECLARE v_scale_auras      TINYINT(1);
  DECLARE v_keep_bonus_armor TINYINT(1);
  DECLARE v_scale_unknown    TINYINT(1);

  DECLARE done              INT DEFAULT 0;
  DECLARE c_slot            TINYINT;
  DECLARE c_spell_id        INT;
  DECLARE c_kind            VARCHAR(16);
  DECLARE c_amount          INT;
  DECLARE c_target_amount   INT;
  DECLARE c_new_spell_id    INT;

  -- trigger spell cloning
  DECLARE v_trig1 INT;
  DECLARE v_trig2 INT;
  DECLARE v_trig3 INT;
  DECLARE v_trig1_new INT;
  DECLARE v_trig2_new INT;
  DECLARE v_trig3_new INT;
  DECLARE v_desc_en VARCHAR(255);

  DECLARE cur CURSOR FOR
    SELECT slot, spell_id, kind, amount, target_amount
    FROM tmp_item_spells
    WHERE
      (kind IS NULL AND v_scale_unknown = 1)
      OR (kind IS NOT NULL AND target_amount IS NOT NULL AND target_amount <> amount);

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  /* ========================
     CONFIG FLAGS
     ======================== */
  SET v_scale_auras      := CASE WHEN IFNULL(p_scale_auras, 1) <> 0 THEN 1 ELSE 0 END;
  SET v_keep_bonus_armor := CASE WHEN IFNULL(p_keep_bonus_armor, 0) <> 0 THEN 1 ELSE 0 END;
  SET v_scale_unknown    := CASE WHEN IFNULL(p_scale_unknown_auras, 0) <> 0 THEN 1 ELSE 0 END;

  /* ========================
     LOAD ITEM BASICS
     ======================== */
  SELECT class, subclass, Quality, InventoryType,
         CAST(IFNULL(trueItemLevel, ItemLevel) AS SIGNED) AS cur_ilvl,
         IFNULL(caster, 0) AS caster_flag,
         IFNULL(delay, 0)  AS delay_ms
  INTO v_class, v_subclass, v_quality, v_inv,
       v_ilvl_cur, v_caster_flag, v_delay_ms
  FROM lplusworld.item_template
  WHERE entry = p_entry;

  IF v_quality IS NULL THEN
    LEAVE proc;
  END IF;

  IF v_quality NOT IN (2,3,4,5,6) THEN
    LEAVE proc;
  END IF;

  IF p_target_ilvl IS NULL OR p_target_ilvl = 0 OR p_target_ilvl = v_ilvl_cur THEN
    LEAVE proc;
  END IF;

  /* ========================
     SLOT MOD & Q-CURVE
     ======================== */

  CASE v_quality
    WHEN 0 THEN SET v_a := 0.50, v_b :=  3.8;
    WHEN 1 THEN SET v_a := 0.80, v_b :=  3.8;
    WHEN 2 THEN SET v_a := 1.24, v_b :=  4.2;
    WHEN 3 THEN SET v_a := 1.49, v_b :=  9.3;
    WHEN 4 THEN SET v_a := 1.64, v_b := 11.2;
    WHEN 5 THEN SET v_a := 1.74, v_b := 24.0;
    WHEN 6 THEN SET v_a := 1.74, v_b := 24.0;
    ELSE
      SET v_a := 1.64, v_b := 11.2;
  END CASE;

  SET v_slotmod :=
    CASE v_inv
      WHEN 1  THEN 1.00
      WHEN 5  THEN 1.00
      WHEN 7  THEN 1.00
      WHEN 20 THEN 1.00
      WHEN 3  THEN 0.79
      WHEN 9  THEN 0.79
      WHEN 16 THEN 0.79
      WHEN 21 THEN 0.79
      WHEN 10 THEN 0.59
      WHEN 6  THEN 0.59
      WHEN 8  THEN 0.59
      WHEN 23 THEN 0.59
      WHEN 2  THEN 0.49
      WHEN 19 THEN 0.49
      WHEN 11 THEN 0.39
      WHEN 12 THEN 0.29
      ELSE 1.00
    END;

  IF v_slotmod = 0 THEN
    LEAVE proc;
  END IF;

  SET v_ISV_cur       := GREATEST(0.0, v_a * v_ilvl_cur    + v_b);
  SET v_ISV_tgt       := GREATEST(0.0, v_a * p_target_ilvl + v_b);
  SET v_itemvalue_cur := GREATEST(0.0, v_ISV_cur / NULLIF(v_slotmod, 0.0));
  SET v_itemvalue_tgt := GREATEST(0.0, v_ISV_tgt / NULLIF(v_slotmod, 0.0));

  IF v_itemvalue_cur <= 0.0 THEN
    LEAVE proc;
  END IF;

  SET v_ratio := v_itemvalue_tgt / v_itemvalue_cur;

  IF v_ratio <= 0 THEN
    LEAVE proc;
  END IF;

  /* ========================
     SCALE ITEM STATS + ARMOR/BLOCK
     ======================== */

  IF p_apply = 1 THEN
    UPDATE lplusworld.item_template t
    SET
      armor = CASE
                WHEN t.armor > 0
                  THEN ROUND(t.armor * v_ratio)
                ELSE t.armor
              END,
      block = CASE
                WHEN t.block > 0
                     AND v_class = 4
                     AND v_inv IN (14, 23)
                  THEN ROUND(t.block * v_ratio)
                ELSE t.block
              END,
      stat_value1  = CASE WHEN stat_type1  <> 0 THEN ROUND(stat_value1  * v_ratio) ELSE stat_value1  END,
      stat_value2  = CASE WHEN stat_type2  <> 0 THEN ROUND(stat_value2  * v_ratio) ELSE stat_value2  END,
      stat_value3  = CASE WHEN stat_type3  <> 0 THEN ROUND(stat_value3  * v_ratio) ELSE stat_value3  END,
      stat_value4  = CASE WHEN stat_type4  <> 0 THEN ROUND(stat_value4  * v_ratio) ELSE stat_value4  END,
      stat_value5  = CASE WHEN stat_type5  <> 0 THEN ROUND(stat_value5  * v_ratio) ELSE stat_value5  END,
      stat_value6  = CASE WHEN stat_type6  <> 0 THEN ROUND(stat_value6  * v_ratio) ELSE stat_value6  END,
      stat_value7  = CASE WHEN stat_type7  <> 0 THEN ROUND(stat_value7  * v_ratio) ELSE stat_value7  END,
      stat_value8  = CASE WHEN stat_type8  <> 0 THEN ROUND(stat_value8  * v_ratio) ELSE stat_value8  END,
      stat_value9  = CASE WHEN stat_type9  <> 0 THEN ROUND(stat_value9  * v_ratio) ELSE stat_value9  END,
      stat_value10 = CASE WHEN stat_type10 <> 0 THEN ROUND(stat_value10 * v_ratio) ELSE stat_value10 END
    WHERE t.entry = p_entry;
  END IF;

  /* ========================
     SCALE AURAS (ON-EQUIP SPELLS)
     ======================== */

  IF v_scale_auras = 1 THEN
    /* Classic-like description strings */
    SET @DESC_AP        := '+$s1 Attack Power.';
    SET @DESC_RAP       := '+$s1 ranged Attack Power.';
    SET @DESC_SD        := 'Increases damage and healing done by magical spells and effects by up to $s1.';
    SET @DESC_HEAL      := 'Increases healing done by magical spells and effects by up to $s1.';
    SET @DESC_MP5       := 'Restores $s1 mana per 5 sec.';
    SET @DESC_HP5       := 'Restores $s1 health every 5 sec.';
    SET @DESC_PEN_SPELL := 'Decreases the magical resistances of your spell targets by $s1.';
    SET @DESC_HIT       := 'Improves your chance to hit by $s1%.';
    SET @DESC_SPHIT     := 'Improves your chance to hit with spells by $s1%.';
    SET @DESC_CRIT      := 'Improves your chance to get a critical strike by $s1%.';
    SET @DESC_SPCRIT    := 'Improves your chance to get a critical strike with spells by $s1%.';

    SET @DESC_BLOCK_VALUE := 'Increases the block value of your shield by $s1.';
    SET @DESC_DODGE_PCT   := 'Increases your chance to dodge an attack by $s1%.';
    SET @DESC_PARRY_PCT   := 'Increases your chance to parry an attack by $s1%.';
    SET @DESC_BLOCK_PCT   := 'Increases your chance to block attacks with a shield by $s1%.';
    SET @DESC_DEFENSE     := 'Increased Defense +$s1.';
    SET @DESC_WEAPON_SKILL_SAD := 'Increases your skill with Swords, Axes and Daggers by $s1.';
    SET @DESC_FERAL_AP    := 'Increases attack power by $s1 in Cat, Bear, Dire Bear, and Moonkin forms only.';

    /* collect item spells + their amounts */
    DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
    CREATE TEMPORARY TABLE tmp_item_spells(
      slot          TINYINT UNSIGNED NOT NULL,
      spell_id      INT UNSIGNED NOT NULL,
      desc_en       VARCHAR(255),
      amount        INT NOT NULL,
      kind          VARCHAR(16) NULL,
      target_amount INT NULL,
      new_spell_id  INT NULL,
      PRIMARY KEY(slot, spell_id)
    ) ENGINE=MEMORY;

    INSERT INTO tmp_item_spells(slot, spell_id, desc_en, amount)
    SELECT 1, it.spellid_1, CAST(sp.Description_Lang_enUS AS CHAR(255)), sp.EffectBasePoints_1 + 1
      FROM lplusworld.item_template it
      JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_1
     WHERE it.entry = p_entry AND it.spellid_1 <> 0
    UNION ALL
    SELECT 2, it.spellid_2, CAST(sp.Description_Lang_enUS AS CHAR(255)), sp.EffectBasePoints_1 + 1
      FROM lplusworld.item_template it
      JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_2
     WHERE it.entry = p_entry AND it.spellid_2 <> 0
    UNION ALL
    SELECT 3, it.spellid_3, CAST(sp.Description_Lang_enUS AS CHAR(255)), sp.EffectBasePoints_1 + 1
      FROM lplusworld.item_template it
      JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_3
     WHERE it.entry = p_entry AND it.spellid_3 <> 0
    UNION ALL
    SELECT 4, it.spellid_4, CAST(sp.Description_Lang_enUS AS CHAR(255)), sp.EffectBasePoints_1 + 1
      FROM lplusworld.item_template it
      JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_4
     WHERE it.entry = p_entry AND it.spellid_4 <> 0
    UNION ALL
    SELECT 5, it.spellid_5, CAST(sp.Description_Lang_enUS AS CHAR(255)), sp.EffectBasePoints_1 + 1
      FROM lplusworld.item_template it
      JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_5
     WHERE it.entry = p_entry AND it.spellid_5 <> 0;

    /* classify auras by description */
    UPDATE tmp_item_spells
    SET kind = CASE
      WHEN desc_en = @DESC_AP        THEN 'AP'
      WHEN desc_en = @DESC_RAP       THEN 'RAP'
      WHEN desc_en = @DESC_SD        THEN 'SD'
      WHEN desc_en = @DESC_HEAL      THEN 'HEAL'
      WHEN desc_en = @DESC_MP5       THEN 'MP5'
      WHEN desc_en = @DESC_HP5       THEN 'HP5'
      WHEN desc_en = @DESC_PEN_SPELL THEN 'PEN_SPELL'
      WHEN desc_en = @DESC_HIT       THEN 'HIT'
      WHEN desc_en = @DESC_SPHIT     THEN 'SPHIT'
      WHEN desc_en = @DESC_CRIT      THEN 'CRIT'
      WHEN desc_en = @DESC_SPCRIT    THEN 'SPCRIT'
      WHEN desc_en = @DESC_BLOCK_VALUE THEN 'BLOCK_VALUE'
      WHEN desc_en = @DESC_DODGE_PCT   THEN 'DODGE_CHANCE'
      WHEN desc_en = @DESC_PARRY_PCT   THEN 'PARRY_CHANCE'
      WHEN desc_en = @DESC_BLOCK_PCT   THEN 'BLOCK_CHANCE'
      WHEN desc_en = @DESC_DEFENSE     THEN 'DEFENSE'
      WHEN desc_en = @DESC_WEAPON_SKILL_SAD THEN 'WEAPON_SKILL'
      WHEN desc_en = @DESC_FERAL_AP    THEN 'FAP'
      ELSE NULL
    END;

    /* caster weapon detection */
    SET v_is_caster_weapon :=
      CASE
        WHEN v_class = 2 AND IFNULL(v_caster_flag,0) = 1 AND IFNULL(v_delay_ms,0) > 0
          THEN 1
        ELSE 0
      END;

    /* total current SP/HEAL on this item */
    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_sp_cur
      FROM tmp_item_spells
     WHERE kind IN ('SD','HEAL');

    /* weapon DPS trade for caster weapons */
    IF v_is_caster_weapon = 1 THEN
      SET v_trade_sp_tgt := 4.0 * GREATEST(p_target_ilvl - 60, 0);
      IF v_total_sp_cur > 0 THEN
        SET v_total_sp_tgt := v_trade_sp_tgt;
        SET v_sp_ratio     := v_total_sp_tgt / v_total_sp_cur;
      ELSE
        SET v_total_sp_tgt := 0.0;
        SET v_sp_ratio     := v_ratio;
      END IF;
    ELSE
      SET v_trade_sp_tgt := 0.0;
      SET v_total_sp_tgt := v_total_sp_cur * v_ratio;
      IF v_total_sp_cur > 0 THEN
        SET v_sp_ratio := v_total_sp_tgt / v_total_sp_cur;
      ELSE
        SET v_sp_ratio := v_ratio;
      END IF;
    END IF;

    /* target_amount:
       - SD/HEAL use v_sp_ratio
       - known kinds use v_ratio
       - unknown kinds only if v_scale_unknown = 1 (sentinel -1)
    */
    UPDATE tmp_item_spells
    SET target_amount = CASE
      WHEN kind IN ('SD','HEAL') THEN ROUND(amount * v_sp_ratio)
      WHEN kind IS NOT NULL      THEN ROUND(amount * v_ratio)
      WHEN v_scale_unknown = 1   THEN -1  -- weird / proc auras
      ELSE NULL
    END;

    /* ========================
       CLONE / REBIND SPELLS
       ======================== */

    DROP TEMPORARY TABLE IF EXISTS tmp_clone_spell_g;
    CREATE TEMPORARY TABLE tmp_clone_spell_g LIKE dbc.spell_lplus;

    DROP TEMPORARY TABLE IF EXISTS tmp_clone_trigger_g;
    CREATE TEMPORARY TABLE tmp_clone_trigger_g LIKE dbc.spell_lplus;

    IF p_apply = 1 THEN
      SET done := 0;
      OPEN cur;
      readloop: LOOP
        FETCH cur INTO c_slot, c_spell_id, c_kind, c_amount, c_target_amount;
        IF done = 1 THEN
          LEAVE readloop;
        END IF;

        IF c_kind IS NOT NULL AND (c_target_amount IS NULL OR c_target_amount = c_amount) THEN
          ITERATE readloop;
        END IF;

        /* new ID for aura */
        CALL helper.sp_GetNextSpellId(c_new_spell_id);

        DELETE FROM tmp_clone_spell_g;
        INSERT INTO tmp_clone_spell_g
        SELECT * FROM dbc.spell_lplus
         WHERE ID = c_spell_id
         LIMIT 1;

        /* === per-kind handling === */
        IF c_kind = 'SD' THEN
          UPDATE tmp_clone_spell_g
          SET ID = c_new_spell_id,
              EffectBasePoints_1 = c_target_amount - 1,
              EffectBasePoints_2 = CASE
                                     WHEN EffectAura_2 IN (115,135)
                                       THEN c_target_amount - 1
                                     ELSE EffectBasePoints_2
                                   END,
              EffectBasePoints_3 = CASE
                                     WHEN EffectAura_3 IN (115,135)
                                       THEN c_target_amount - 1
                                     ELSE EffectBasePoints_3
                                   END;

        ELSEIF c_kind IN ('AP','RAP') THEN
          UPDATE tmp_clone_spell_g
          SET ID = c_new_spell_id,
              EffectBasePoints_1 = c_target_amount - 1,
              EffectBasePoints_2 = CASE
                                     WHEN EffectAura_2 IN (99,124,102,131)
                                       THEN c_target_amount - 1
                                     ELSE EffectBasePoints_2
                                   END,
              EffectBasePoints_3 = CASE
                                     WHEN EffectAura_3 IN (99,124,102,131)
                                       THEN c_target_amount - 1
                                     ELSE EffectBasePoints_3
                                   END;

        ELSEIF c_kind IS NULL AND v_scale_unknown = 1 THEN
          /* Weird green / proc auras: scale basepoints and clone trigger spells */
          UPDATE tmp_clone_spell_g
          SET ID = c_new_spell_id,
              EffectBasePoints_1 = CASE
                                     WHEN Effect_1 <> 0 AND EffectBasePoints_1 IS NOT NULL
                                       THEN ROUND(EffectBasePoints_1 * v_ratio)
                                     ELSE EffectBasePoints_1
                                   END,
              EffectBasePoints_2 = CASE
                                     WHEN Effect_2 <> 0 AND EffectBasePoints_2 IS NOT NULL
                                       THEN ROUND(EffectBasePoints_2 * v_ratio)
                                     ELSE EffectBasePoints_2
                                   END,
              EffectBasePoints_3 = CASE
                                     WHEN Effect_3 <> 0 AND EffectBasePoints_3 IS NOT NULL
                                       THEN ROUND(EffectBasePoints_3 * v_ratio)
                                     ELSE EffectBasePoints_3
                                   END;

          SELECT EffectTriggerSpell_1, EffectTriggerSpell_2, EffectTriggerSpell_3,
                 Description_Lang_enUS
            INTO v_trig1, v_trig2, v_trig3, v_desc_en
            FROM tmp_clone_spell_g
           LIMIT 1;

          /* clone + scale each trigger spell, rewrite description tokens */

          IF v_trig1 IS NOT NULL AND v_trig1 > 0 THEN
            CALL helper.sp_GetNextSpellId(v_trig1_new);
            DELETE FROM tmp_clone_trigger_g;
            INSERT INTO tmp_clone_trigger_g
            SELECT * FROM dbc.spell_lplus WHERE ID = v_trig1 LIMIT 1;

            UPDATE tmp_clone_trigger_g
            SET ID = v_trig1_new,
                EffectBasePoints_1 = CASE
                                       WHEN Effect_1 <> 0 AND EffectBasePoints_1 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_1 * v_ratio)
                                       ELSE EffectBasePoints_1
                                     END,
                EffectBasePoints_2 = CASE
                                       WHEN Effect_2 <> 0 AND EffectBasePoints_2 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_2 * v_ratio)
                                       ELSE EffectBasePoints_2
                                     END,
                EffectBasePoints_3 = CASE
                                       WHEN Effect_3 <> 0 AND EffectBasePoints_3 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_3 * v_ratio)
                                       ELSE EffectBasePoints_3
                                     END;

            INSERT INTO dbc.spell_lplus
            SELECT * FROM tmp_clone_trigger_g;

            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig1, 's1'),
                                     CONCAT('$', v_trig1_new, 's1'));
            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig1, 's2'),
                                     CONCAT('$', v_trig1_new, 's2'));
            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig1, 's3'),
                                     CONCAT('$', v_trig1_new, 's3'));

            UPDATE tmp_clone_spell_g
            SET EffectTriggerSpell_1 = v_trig1_new,
                Description_Lang_enUS = v_desc_en;
          END IF;

          IF v_trig2 IS NOT NULL AND v_trig2 > 0 THEN
            CALL helper.sp_GetNextSpellId(v_trig2_new);
            DELETE FROM tmp_clone_trigger_g;
            INSERT INTO tmp_clone_trigger_g
            SELECT * FROM dbc.spell_lplus WHERE ID = v_trig2 LIMIT 1;

            UPDATE tmp_clone_trigger_g
            SET ID = v_trig2_new,
                EffectBasePoints_1 = CASE
                                       WHEN Effect_1 <> 0 AND EffectBasePoints_1 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_1 * v_ratio)
                                       ELSE EffectBasePoints_1
                                     END,
                EffectBasePoints_2 = CASE
                                       WHEN Effect_2 <> 0 AND EffectBasePoints_2 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_2 * v_ratio)
                                       ELSE EffectBasePoints_2
                                     END,
                EffectBasePoints_3 = CASE
                                       WHEN Effect_3 <> 0 AND EffectBasePoints_3 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_3 * v_ratio)
                                       ELSE EffectBasePoints_3
                                     END;

            INSERT INTO dbc.spell_lplus
            SELECT * FROM tmp_clone_trigger_g;

            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig2, 's1'),
                                     CONCAT('$', v_trig2_new, 's1'));
            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig2, 's2'),
                                     CONCAT('$', v_trig2_new, 's2'));
            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig2, 's3'),
                                     CONCAT('$', v_trig2_new, 's3'));

            UPDATE tmp_clone_spell_g
            SET EffectTriggerSpell_2 = v_trig2_new,
                Description_Lang_enUS = v_desc_en;
          END IF;

          IF v_trig3 IS NOT NULL AND v_trig3 > 0 THEN
            CALL helper.sp_GetNextSpellId(v_trig3_new);
            DELETE FROM tmp_clone_trigger_g;
            INSERT INTO tmp_clone_trigger_g
            SELECT * FROM dbc.spell_lplus WHERE ID = v_trig3 LIMIT 1;

            UPDATE tmp_clone_trigger_g
            SET ID = v_trig3_new,
                EffectBasePoints_1 = CASE
                                       WHEN Effect_3 <> 0 AND EffectBasePoints_1 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_1 * v_ratio)
                                       ELSE EffectBasePoints_1
                                     END,
                EffectBasePoints_2 = CASE
                                       WHEN Effect_2 <> 0 AND EffectBasePoints_2 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_2 * v_ratio)
                                       ELSE EffectBasePoints_2
                                     END,
                EffectBasePoints_3 = CASE
                                       WHEN Effect_3 <> 0 AND EffectBasePoints_3 IS NOT NULL
                                         THEN ROUND(EffectBasePoints_3 * v_ratio)
                                       ELSE EffectBasePoints_3
                                     END;

            INSERT INTO dbc.spell_lplus
            SELECT * FROM tmp_clone_trigger_g;

            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig3, 's1'),
                                     CONCAT('$', v_trig3_new, 's1'));
            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig3, 's2'),
                                     CONCAT('$', v_trig3_new, 's2'));
            SET v_desc_en := REPLACE(v_desc_en,
                                     CONCAT('$', v_trig3, 's3'),
                                     CONCAT('$', v_trig3_new, 's3'));

            UPDATE tmp_clone_spell_g
            SET EffectTriggerSpell_3 = v_trig3_new,
                Description_Lang_enUS = v_desc_en;
          END IF;

        ELSE
          /* simple single-effect auras: set effect 1 to target */
          UPDATE tmp_clone_spell_g
          SET ID = c_new_spell_id,
              EffectBasePoints_1 = c_target_amount - 1;
        END IF;

        INSERT INTO dbc.spell_lplus
        SELECT * FROM tmp_clone_spell_g;

        /* wire item to new spell by slot */
        CASE c_slot
          WHEN 1 THEN
            UPDATE lplusworld.item_template
               SET spellid_1 = c_new_spell_id
             WHERE entry = p_entry;
          WHEN 2 THEN
            UPDATE lplusworld.item_template
               SET spellid_2 = c_new_spell_id
             WHERE entry = p_entry;
          WHEN 3 THEN
            UPDATE lplusworld.item_template
               SET spellid_3 = c_new_spell_id
             WHERE entry = p_entry;
          WHEN 4 THEN
            UPDATE lplusworld.item_template
               SET spellid_4 = c_new_spell_id
             WHERE entry = p_entry;
          WHEN 5 THEN
            UPDATE lplusworld.item_template
               SET spellid_5 = c_new_spell_id
             WHERE entry = p_entry;
        END CASE;
      END LOOP;
      CLOSE cur;
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_clone_trigger_g;
    DROP TEMPORARY TABLE IF EXISTS tmp_clone_spell_g;
    DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  END IF; -- v_scale_auras

  /* ========================
     ITEMLEVEL ESTIMATE (IF NOT DEFERRED)
     ======================== */
  IF p_apply = 1 AND IFNULL(@ilvl_defer_estimate, 0) = 0 THEN
    SET v_prev_defer_estimate := @ilvl_defer_estimate;
    SET @ilvl_defer_estimate := 1;

    SET v_nudge_pass   := 0;
    
  SET v_prev_delta := NULL;
  SET v_stall_count := 0;  SET v_added_to_queue := 0;
  SET v_nudge_target := p_target_ilvl;

    nudge: LOOP
    /* Ensure this item gets re-estimated even if sp_EstimateItemLevels is queue-driven */
    IF v_added_to_queue = 0 THEN
      IF (SELECT COUNT(*) FROM helper.tune_queue WHERE entry = p_entry) = 0 THEN
        INSERT INTO helper.tune_queue (entry, target_ilvl, mode, apply_change)
        VALUES (p_entry, p_target_ilvl, 'NUDGE', 0);
        SET v_added_to_queue := 1;
      END IF;
    END IF;

    CALL helper.sp_EstimateItemLevels();
SELECT CAST(IFNULL(it.trueItemLevel, it.ItemLevel) AS SIGNED)
        INTO v_cur_ilvl
        FROM lplusworld.item_template it
       WHERE it.entry = p_entry;

      SET v_delta := v_cur_ilvl - p_target_ilvl;

      
    /* Stall detection: if delta isn't changing, stop nudging */
    IF v_prev_delta IS NOT NULL AND v_delta = v_prev_delta THEN
      SET v_stall_count := v_stall_count + 1;
    ELSE
      SET v_stall_count := 0;
END IF;
    SET v_prev_delta := v_delta;
    IF v_stall_count >= 2 THEN
      LEAVE nudge;
    END IF;
IF v_delta = 0 THEN
        LEAVE nudge;
      END IF;

      SET v_nudge_pass := v_nudge_pass + 1;
      IF v_nudge_pass > 25 THEN LEAVE nudge; END IF;

      SET v_nudge_target := GREATEST(1, p_target_ilvl - v_delta);

      CALL helper.sp_ScaleItemToIlvl_SimpleGreedy_v2(
        p_entry,
        v_nudge_target,
        p_apply,
        v_scale_auras,
        v_keep_bonus_armor,
        v_scale_unknown
      );
    END LOOP;
  /* Cleanup: remove our temporary queue entry (if we added one) */
  IF v_added_to_queue = 1 THEN
    DELETE FROM helper.tune_queue
    WHERE entry = p_entry
      AND mode = 'NUDGE'
      AND apply_change = 0;
  END IF;

  SET @ilvl_defer_estimate := v_prev_defer_estimate;
CALL helper.sp_EstimateItemLevels();
  END IF;

END proc