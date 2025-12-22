DELIMITER $$
CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleItemToIlvl_SimpleGreedy`(
  IN p_entry INT UNSIGNED,
  IN p_target_ilvl INT UNSIGNED,
  IN p_apply TINYINT(1),        -- 0=dry run, 1=apply changes
  IN p_scale_auras TINYINT(1),  -- 0=skip aura scaling, nonzero=scale auras
  IN p_keep_bonus_armor TINYINT(1) -- nonzero keeps bonus armor fixed
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

  DECLARE v_scale_auras      TINYINT(1);
  DECLARE v_keep_bonus_armor TINYINT(1);

  DECLARE done              INT DEFAULT 0;
  DECLARE c_slot            TINYINT;
  DECLARE c_spell_id        INT;
  DECLARE c_kind            VARCHAR(16);
  DECLARE c_amount          INT;
  DECLARE c_target_amount   INT;
  DECLARE c_new_spell_id    INT;

  DECLARE cur CURSOR FOR
    SELECT slot, spell_id, kind, amount, target_amount
    FROM tmp_item_spells
    WHERE kind IS NOT NULL
      AND target_amount IS NOT NULL
      AND target_amount <> amount;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  /* ========================
     CONFIG FLAGS
     ======================== */
  SET v_scale_auras      := CASE WHEN IFNULL(p_scale_auras, 1) <> 0 THEN 1 ELSE 0 END;
  SET v_keep_bonus_armor := CASE WHEN IFNULL(p_keep_bonus_armor, 0) <> 0 THEN 1 ELSE 0 END;

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

  /* only scale uncommon+ items; tweak if you want */
  IF v_quality NOT IN (2,3,4,5,6) THEN
    LEAVE proc;
  END IF;

  /* if target ilvl == current, nothing to do */
  IF p_target_ilvl IS NULL OR p_target_ilvl = 0 OR p_target_ilvl = v_ilvl_cur THEN
    LEAVE proc;
  END IF;

  /* ========================
     SLOT MOD & Q-CURVE
     ======================== */

  /* quality -> (a,b) from your doc */
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

  /* InventoryType -> slotmod (same values you used before) */
  SET v_slotmod :=
    CASE v_inv
      WHEN 1  THEN 1.00  -- head
      WHEN 5  THEN 1.00  -- chest
      WHEN 7  THEN 1.00  -- legs
      WHEN 20 THEN 1.00  -- chest (robes)
      WHEN 3  THEN 0.79  -- shoulders
      WHEN 9  THEN 0.79  -- wrist
      WHEN 16 THEN 0.79  -- back
      WHEN 21 THEN 0.79  -- main hand?
      WHEN 10 THEN 0.59  -- hands
      WHEN 6  THEN 0.59  -- waist
      WHEN 8  THEN 0.59  -- feet
      WHEN 23 THEN 0.59  -- off hand?
      WHEN 2  THEN 0.49  -- neck
      WHEN 19 THEN 0.49  -- tabard
      WHEN 11 THEN 0.39  -- finger
      WHEN 12 THEN 0.29  -- trinket
      ELSE 1.00
    END;

  IF v_slotmod = 0 THEN
    LEAVE proc;
  END IF;

  /* ISV & itemvalue */
  SET v_ISV_cur       := GREATEST(0.0, v_a * v_ilvl_cur      + v_b);
  SET v_ISV_tgt       := GREATEST(0.0, v_a * p_target_ilvl   + v_b);
  SET v_itemvalue_cur := GREATEST(0.0, v_ISV_cur / NULLIF(v_slotmod, 0.0));
  SET v_itemvalue_tgt := GREATEST(0.0, v_ISV_tgt / NULLIF(v_slotmod, 0.0));

  IF v_itemvalue_cur <= 0.0 THEN
    LEAVE proc;
  END IF;

  SET v_ratio := v_itemvalue_tgt / v_itemvalue_cur;

  /* if ratio is degenerate, just bail */
  IF v_ratio <= 0 THEN
    LEAVE proc;
  END IF;

  /* ========================
     SCALE ITEM STATS
     ======================== */

  IF p_apply = 1 THEN
    /* naive: scale all non-zero stat values by ratio.
       if you want to protect bonus armor, add a CASE on stat_typeX. */
    UPDATE lplusworld.item_template t
    SET
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
    WHERE entry = p_entry;
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
    SET @DESC_PEN_ARMOR := 'Increases your armor penetration rating by $s1.';
    SET @DESC_PEN_SPELL := 'Increases your spell penetration by $s1.';
    SET @DESC_HIT       := 'Improves your chance to hit by $s1%.';
    SET @DESC_SPHIT     := 'Improves your chance to hit with spells by $s1%.';
    SET @DESC_CRIT      := 'Improves your chance to get a critical strike by $s1%.';
    SET @DESC_SPCRIT    := 'Improves your chance to get a critical strike with spells by $s1%.';

    /* collect item spells + their amounts (assume $s1 uses EffectBasePoints_1) */
    DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
    CREATE TEMPORARY TABLE tmp_item_spells(
      slot          TINYINT UNSIGNED NOT NULL,
      spell_id      INT UNSIGNED NOT NULL,
      desc_en       VARCHAR(255),   -- FIX: no TEXT/BLOB in MEMORY
      amount        INT NOT NULL,
      kind          VARCHAR(16) NULL,
      target_amount INT NULL,
      new_spell_id  INT NULL,
      PRIMARY KEY(slot, spell_id)
    ) ENGINE=Memory;

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
      WHEN desc_en = @DESC_PEN_ARMOR THEN 'PEN_ARMOR'
      WHEN desc_en = @DESC_PEN_SPELL THEN 'PEN_SPELL'
      WHEN desc_en = @DESC_HIT       THEN 'HIT'
      WHEN desc_en = @DESC_SPHIT     THEN 'SPHIT'
      WHEN desc_en = @DESC_CRIT      THEN 'CRIT'
      WHEN desc_en = @DESC_SPCRIT    THEN 'SPCRIT'
      ELSE NULL
    END;

    /* caster weapon detection (2H caster or ranged caster) */
    SET v_is_caster_weapon :=
      CASE
        WHEN v_class = 2 AND IFNULL(v_caster_flag,0) = 1 AND IFNULL(v_delay_ms,0) > 0
          THEN 1
        ELSE 0
      END;

    /* total current SP/HEAL on this item (based on description) */
    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_sp_cur
    FROM tmp_item_spells
    WHERE kind IN ('SD','HEAL');

    /* target SP from trade for caster weapons:
       SacrificedDPS = ilvl - 60
       SpellPower = 4 * SacrificedDPS
    */
    IF v_is_caster_weapon = 1 THEN
      SET v_trade_sp_tgt := 4.0 * GREATEST(p_target_ilvl - 60, 0);
      IF v_total_sp_cur > 0 THEN
        SET v_total_sp_tgt := v_trade_sp_tgt;
        SET v_sp_ratio     := v_total_sp_tgt / v_total_sp_cur;
      ELSE
        SET v_total_sp_tgt := 0.0;
        SET v_sp_ratio     := v_ratio; -- fallback
      END IF;
    ELSE
      /* non-caster: just scale SP/HEAL with same ratio */
      SET v_trade_sp_tgt := 0.0;
      SET v_total_sp_tgt := v_total_sp_cur * v_ratio;
      IF v_total_sp_cur > 0 THEN
        SET v_sp_ratio := v_total_sp_tgt / v_total_sp_cur;
      ELSE
        SET v_sp_ratio := v_ratio;
      END IF;
    END IF;

    /* base target_amount for each aura */
    UPDATE tmp_item_spells
    SET target_amount = CASE
      WHEN kind IN ('SD','HEAL') THEN ROUND(amount * v_sp_ratio)
      WHEN kind IS NOT NULL      THEN ROUND(amount * v_ratio)
      ELSE NULL
    END;

    /* ========================
       CLONE / REBIND SPELLS
       ======================== */

    /* temp clone table for spells */
    DROP TEMPORARY TABLE IF EXISTS tmp_clone_spell_g;
    CREATE TEMPORARY TABLE tmp_clone_spell_g LIKE dbc.spell_lplus;

    IF p_apply = 1 THEN
      SET done := 0;
      OPEN cur;
      readloop: LOOP
        FETCH cur INTO c_slot, c_spell_id, c_kind, c_amount, c_target_amount;
        IF done = 1 THEN
          LEAVE readloop;
        END IF;

        /* nothing to do if we somehow got here with equal amount */
        IF c_target_amount = c_amount OR c_target_amount IS NULL OR c_target_amount <= 0 THEN
          ITERATE readloop;
        END IF;

        /* allocate new spell ID */
        SELECT MAX(ID) + 1
        INTO c_new_spell_id
        FROM dbc.spell_lplus;
        DELETE FROM tmp_clone_spell_g;
        INSERT INTO tmp_clone_spell_g
        SELECT * FROM dbc.spell_lplus
        WHERE ID = c_spell_id
        LIMIT 1;

        /* Multi-effect handling:
           - SD  : damage + healing (auras 13/115/135)
           - AP/RAP: melee + ranged AP (auras 99/124, and vs-type 102/131)
           - everything else: only effect 1 is scaled
        */
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
          -- “Attack Power” spells: AP + RAP on same spell
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

        ELSE
          -- single-effect auras: just scale effect 1
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

    DROP TEMPORARY TABLE IF EXISTS tmp_clone_spell_g;
    DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  END IF; -- scale_auras

  /* ========================
     ITEMLEVEL ESTIMATE (IF NOT DEFERRED)
     ======================== */
  IF p_apply = 1 THEN
    IF IFNULL(@ilvl_defer_estimate, 0) = 0 THEN
      CALL helper.sp_EstimateItemLevels();
    END IF;
  END IF;

END proc$$
DELIMITER ;
