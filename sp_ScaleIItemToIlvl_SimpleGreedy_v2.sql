CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleItemToIlvl_SimpleGreedy_v2`(
  IN p_entry INT UNSIGNED,
  IN p_target_ilvl INT UNSIGNED,
  IN p_apply TINYINT(1),
  IN p_scale_auras TINYINT(1),
  IN p_keep_bonus_armor TINYINT(1),
  IN p_scale_unknown_auras TINYINT(1)
)
proc: BEGIN
  /* =========================
     DECLARES (MUST BE FIRST)
     ========================= */
  DECLARE v_class          TINYINT UNSIGNED;
  DECLARE v_subclass       TINYINT UNSIGNED;
  DECLARE v_quality        TINYINT UNSIGNED;
  DECLARE v_inv            TINYINT UNSIGNED;

  DECLARE v_ilvl_cur       INT;
  DECLARE v_true_ilvl_cur  INT;
  DECLARE v_caster_flag    TINYINT(1);
  DECLARE v_delay_ms       INT;

  DECLARE v_scale_auras_f  TINYINT(1);
  DECLARE v_scale_unknown  TINYINT(1);

  DECLARE v_slotmod        DOUBLE;
  DECLARE v_a              DOUBLE;
  DECLARE v_b              DOUBLE;

  DECLARE v_isv_tgt        DOUBLE;
  DECLARE v_isv_cur_nom    DOUBLE;
  DECLARE v_itemvalue_tgt  DOUBLE;
  DECLARE v_S_target       DOUBLE;
  DECLARE v_k_doc          DOUBLE;

  DECLARE v_is_caster_weapon TINYINT(1);

  /* --- spell/heal trade buckets --- */
  DECLARE v_total_sd_cur     DOUBLE;   /* spellpower (damage+healing) aka aura 13 (magic) */
  DECLARE v_total_heal_cur   DOUBLE;   /* healing-only (auras 115/135) when no SD */
  DECLARE v_trade_sd_tgt     DOUBLE;
  DECLARE v_trade_heal_tgt   DOUBLE;

  DECLARE v_S_locked       DOUBLE;
  DECLARE v_S_other_cur    DOUBLE;
  DECLARE v_S_sd_cur       DOUBLE;
  DECLARE v_S_heal_cur     DOUBLE;

  DECLARE v_k_other        DOUBLE;
  DECLARE v_k_sd           DOUBLE;
  DECLARE v_k_heal         DOUBLE;

  DECLARE v_S_rem_other    DOUBLE;

  DECLARE v_S_components   DOUBLE;
  DECLARE v_S_spell_now    DOUBLE;
  DECLARE v_S_total_now    DOUBLE;
  DECLARE v_err_now        DOUBLE;
  DECLARE v_known_cnt      INT DEFAULT 0;
  DECLARE v_unknown_cnt    INT DEFAULT 0;

  DECLARE v_iter           INT;
  DECLARE v_dir            INT;

  DECLARE v_is_weapon_slot TINYINT(1) DEFAULT 0;
  DECLARE v_mode           VARCHAR(32) DEFAULT NULL;

  DECLARE v_median_base_armor DOUBLE DEFAULT NULL;
  DECLARE v_median_dps        DOUBLE DEFAULT NULL;
  DECLARE v_dmg_min1_cur      DOUBLE DEFAULT 0;
  DECLARE v_dmg_max1_cur      DOUBLE DEFAULT 0;
  DECLARE v_delay_cur         INT DEFAULT 0;
  DECLARE v_cur_dps           DOUBLE DEFAULT NULL;
  DECLARE v_scale_dps         DOUBLE DEFAULT NULL;

  /* post-pass caster weapon DPS clamp */
  DECLARE v_dps_delta DOUBLE DEFAULT 0.0;
  DECLARE v_dmg_delta       DOUBLE DEFAULT NULL;


  /* debug staging (avoid temp-table reopen) */
  DECLARE v_dbg_cnt BIGINT DEFAULT 0;
  DECLARE v_dbg_txt TEXT DEFAULT NULL;

  /* cursor vars for aura cloning */
  DECLARE done INT DEFAULT 0;
  DECLARE c_slot TINYINT UNSIGNED;
  DECLARE c_spell_id INT UNSIGNED;
  DECLARE c_kind VARCHAR(32);
  DECLARE c_amount INT;
  DECLARE c_target_amount INT;
  DECLARE c_locked TINYINT(1);
  DECLARE c_new_spell_id INT UNSIGNED;

  /* trigger cloning vars */
  DECLARE v_trig1 INT;
  DECLARE v_trig2 INT;
  DECLARE v_trig3 INT;
  DECLARE v_trig1_new INT;
  DECLARE v_trig2_new INT;
  DECLARE v_trig3_new INT;
  DECLARE v_desc_en TEXT;

  /* =========================
     FLAGS
     ========================= */
  SET v_scale_auras_f := CASE WHEN IFNULL(p_scale_auras,1) <> 0 THEN 1 ELSE 0 END;
  SET v_scale_unknown := CASE WHEN IFNULL(p_scale_unknown_auras,0) <> 0 THEN 1 ELSE 0 END;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'BEGIN','target_ilvl',p_target_ilvl,
          CONCAT('apply=',IFNULL(p_apply,0),
                 ', scale_auras=',v_scale_auras_f,
                 ', scale_unknown=',v_scale_unknown,
                 ', keep_bonus_armor=',IFNULL(p_keep_bonus_armor,0)));

  /* =========================
     WEIGHTS
     ========================= */
  SET @W_PRIMARY    := 230;
  SET @W_RESIST     := 230;

  SET @W_AP        := 115;
  SET @W_RAP       := 92;

  SET @W_HEAL      := 100;
  SET @W_SD_ALL    := 192;

  SET @W_HIT       := 2200;
  SET @W_SPHIT     := 2500;
  SET @W_CRIT      := 3200;
  SET @W_SPCRIT    := 2600;

  SET @W_BLOCKVALUE := 150;
  SET @W_BLOCK      := 1300;
  SET @W_PARRY      := 3600;
  SET @W_DODGE      := 2500;
  SET @W_DEFENSE    := 345;

  SET @W_WEAPON_SKILL_OTHER  := 550;
  SET @W_DAMAGE_SHIELD       := 720;

  SET @W_MP5 := 550;
  SET @W_HP5 := 550;

  SET @W_BONUSARMOR := 22;

  SET @STAT_SPELL_PEN := 25;
  SET @W_PEN_SPELL := 275;

  /* =========================
     LOAD ITEM
     ========================= */
  SELECT it.class, it.subclass, it.Quality, it.InventoryType,
         CAST(IFNULL(it.ItemLevel,0) AS SIGNED) AS cur_ilvl,
         CAST(IFNULL(it.trueItemLevel,0) AS SIGNED) AS true_ilvl,
         IFNULL(it.caster,0) AS caster_flag,
         IFNULL(it.delay,0)  AS delay_ms
  INTO v_class, v_subclass, v_quality, v_inv,
       v_ilvl_cur, v_true_ilvl_cur, v_caster_flag, v_delay_ms
  FROM lplusworld.item_template it
  WHERE it.entry = p_entry
  LIMIT 1;

  IF v_quality IS NULL THEN
    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,'ABORT','reason',NULL,'item_not_found');
    LEAVE proc;
  END IF;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'ITEM','cur_ilvl',v_ilvl_cur,
          CONCAT('itemlevel=',v_ilvl_cur,
                 ' trueItemLevel=',v_true_ilvl_cur,
                 ' inv=',v_inv,' class=',v_class,' caster=',v_caster_flag,' delay=',v_delay_ms));

  IF v_quality NOT IN (2,3,4) THEN
    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,'ABORT','reason',NULL,'unsupported_quality');
    LEAVE proc;
  END IF;

  IF p_target_ilvl IS NULL OR p_target_ilvl = 0 OR p_target_ilvl = v_ilvl_cur THEN
    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,'ABORT','reason',NULL,'no_target_or_no_change');
    LEAVE proc;
  END IF;

  /* =========================
     QUALITY CURVE
     ========================= */
  CASE v_quality
    WHEN 2 THEN SET v_a := 1.21, v_b := -9.8;   /* green */
    WHEN 3 THEN SET v_a := 1.42, v_b := -4.2;   /* blue */
    WHEN 4 THEN SET v_a := 1.64, v_b := 11.2;   /* epic */
    ELSE SET v_a := 1.21, v_b := -9.8;
  END CASE;

  /* =========================
     SLOT MOD
     ========================= */
  SET v_slotmod :=
    CASE v_inv
      WHEN 1  THEN 1.00
      WHEN 5  THEN 1.00
      WHEN 20 THEN 1.00
      WHEN 7  THEN 1.00
      WHEN 3  THEN 1.35
      WHEN 10 THEN 1.35
      WHEN 6  THEN 1.35
      WHEN 8  THEN 1.35
      WHEN 12 THEN 1.47
      WHEN 9  THEN 1.85
      WHEN 2  THEN 1.85
      WHEN 16 THEN 1.85
      WHEN 11 THEN 1.85
      WHEN 17 THEN 1.00
      WHEN 13 THEN 2.44
      WHEN 21 THEN 2.44
      WHEN 15 THEN 3.33
      WHEN 25 THEN 3.33
      WHEN 26 THEN 3.33
      WHEN 14 THEN 1.92
      WHEN 22 THEN 1.92
      WHEN 23 THEN 1.92
      ELSE 1.00
    END;

  IF v_slotmod <= 0 THEN
    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,'ABORT','reason',NULL,CONCAT('bad_slotmod inv=',v_inv));
    LEAVE proc;
  END IF;

  /* =========================
     TARGET BUDGET (S_target) + DOC RATIO (k_doc)
     ========================= */
  SET v_isv_tgt       := GREATEST(0.0, v_a * p_target_ilvl + v_b);
  SET v_itemvalue_tgt := GREATEST(0.0, v_isv_tgt / NULLIF(v_slotmod, 0.0));
  SET v_S_target      := POW(GREATEST(0.0, v_itemvalue_tgt * 100.0), 1.5);

  SET v_isv_cur_nom := GREATEST(0.0, v_a * v_ilvl_cur + v_b);
  IF v_isv_cur_nom > 0 THEN
    SET v_k_doc := v_isv_tgt / v_isv_cur_nom;
  ELSE
    SET v_k_doc := 1.0;
  END IF;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'TARGET','S_target',v_S_target,
          CONCAT('isv_tgt=',v_isv_tgt,' slotmod=',v_slotmod,' itemvalue_tgt=',v_itemvalue_tgt,' k_doc=',v_k_doc));

  /* =========================
     WEAPON DETECTION
     ========================= */
  SET v_is_weapon_slot :=
    CASE
      WHEN v_class = 2 THEN 1
      WHEN v_inv IN (13,17,21,15,25,26) THEN 1
      ELSE 0
    END;

  /* ============================================================
     tmp_stat_lines (WITH statmod)
     ============================================================ */
  DROP TEMPORARY TABLE IF EXISTS tmp_stat_lines;
  CREATE TEMPORARY TABLE tmp_stat_lines(
    line_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    src        VARCHAR(8) NOT NULL,
    slot_idx   TINYINT UNSIGNED NULL,
    kind       VARCHAR(32) NOT NULL,
    amount     DOUBLE NOT NULL,
    statmod    DOUBLE NOT NULL,
    locked     TINYINT(1) NOT NULL,
    new_amount DOUBLE NULL,
    PRIMARY KEY(line_id),
    UNIQUE KEY uq_stat_slot (src, slot_idx, kind)
  ) ENGINE=MEMORY;

  /* stat slots (1..10) */
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',1, CONCAT('STATTYPE_',it.stat_type1), GREATEST(0,it.stat_value1),
         CASE
           WHEN it.stat_type1 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type1 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type1<>0 AND it.stat_value1<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',2, CONCAT('STATTYPE_',it.stat_type2), GREATEST(0,it.stat_value2),
         CASE
           WHEN it.stat_type2 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type2 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type2<>0 AND it.stat_value2<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',3, CONCAT('STATTYPE_',it.stat_type3), GREATEST(0,it.stat_value3),
         CASE
           WHEN it.stat_type3 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type3 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type3<>0 AND it.stat_value3<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',4, CONCAT('STATTYPE_',it.stat_type4), GREATEST(0,it.stat_value4),
         CASE
           WHEN it.stat_type4 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type4 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type4<>0 AND it.stat_value4<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',5, CONCAT('STATTYPE_',it.stat_type5), GREATEST(0,it.stat_value5),
         CASE
           WHEN it.stat_type5 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type5 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type5<>0 AND it.stat_value5<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',6, CONCAT('STATTYPE_',it.stat_type6), GREATEST(0,it.stat_value6),
         CASE
           WHEN it.stat_type6 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type6 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type6<>0 AND it.stat_value6<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',7, CONCAT('STATTYPE_',it.stat_type7), GREATEST(0,it.stat_value7),
         CASE
           WHEN it.stat_type7 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type7 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type7<>0 AND it.stat_value7<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',8, CONCAT('STATTYPE_',it.stat_type8), GREATEST(0,it.stat_value8),
         CASE
           WHEN it.stat_type8 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type8 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type8<>0 AND it.stat_value8<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',9, CONCAT('STATTYPE_',it.stat_type9), GREATEST(0,it.stat_value9),
         CASE
           WHEN it.stat_type9 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type9 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type9<>0 AND it.stat_value9<>0;

  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'STAT',10, CONCAT('STATTYPE_',it.stat_type10), GREATEST(0,it.stat_value10),
         CASE
           WHEN it.stat_type10 IN (3,4,5,6,7) THEN @W_PRIMARY
           WHEN it.stat_type10 = @STAT_SPELL_PEN THEN @W_PEN_SPELL
           ELSE @W_PRIMARY
         END, 0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND it.stat_type10<>0 AND it.stat_value10<>0;

  /* bonus armor */
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'BONUS',NULL,'BONUS_ARMOR',
         GREATEST(0,IFNULL(it.ArmorDamageModifier,0)),
         @W_BONUSARMOR,
         CASE WHEN IFNULL(p_keep_bonus_armor,0)<>0 THEN 1 ELSE 0 END
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND IFNULL(it.ArmorDamageModifier,0)<>0;

  /* resists */
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'RESIST',NULL,'RES_HOLY',  GREATEST(0,IFNULL(it.holy_res,0)),  @W_RESIST,0 FROM lplusworld.item_template it WHERE it.entry=p_entry AND IFNULL(it.holy_res,0)<>0;
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'RESIST',NULL,'RES_FIRE',  GREATEST(0,IFNULL(it.fire_res,0)),  @W_RESIST,0 FROM lplusworld.item_template it WHERE it.entry=p_entry AND IFNULL(it.fire_res,0)<>0;
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'RESIST',NULL,'RES_NATURE',GREATEST(0,IFNULL(it.nature_res,0)),@W_RESIST,0 FROM lplusworld.item_template it WHERE it.entry=p_entry AND IFNULL(it.nature_res,0)<>0;
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'RESIST',NULL,'RES_FROST', GREATEST(0,IFNULL(it.frost_res,0)), @W_RESIST,0 FROM lplusworld.item_template it WHERE it.entry=p_entry AND IFNULL(it.frost_res,0)<>0;
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'RESIST',NULL,'RES_SHADOW',GREATEST(0,IFNULL(it.shadow_res,0)),@W_RESIST,0 FROM lplusworld.item_template it WHERE it.entry=p_entry AND IFNULL(it.shadow_res,0)<>0;
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'RESIST',NULL,'RES_ARCANE',GREATEST(0,IFNULL(it.arcane_res,0)),@W_RESIST,0 FROM lplusworld.item_template it WHERE it.entry=p_entry AND IFNULL(it.arcane_res,0)<>0;

  /* shield block value */
  INSERT IGNORE INTO tmp_stat_lines(src, slot_idx, kind, amount, statmod, locked)
  SELECT 'BLOCK',NULL,'BLOCK_VALUE',GREATEST(0,IFNULL(it.block,0)),@W_BLOCKVALUE,0
  FROM lplusworld.item_template it
  WHERE it.entry=p_entry AND IFNULL(it.block,0)<>0 AND v_inv IN (14,23);

  /* debug: statlines (ONE read) */
  SELECT COUNT(*),
         GROUP_CONCAT(CONCAT(kind,':',CAST(amount AS SIGNED)) ORDER BY src,slot_idx,kind SEPARATOR ', ')
  INTO v_dbg_cnt, v_dbg_txt
  FROM tmp_stat_lines;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'STATLINES','count',v_dbg_cnt,v_dbg_txt);

  /* ============================================================
     tmp_item_spells
     ============================================================ */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  CREATE TEMPORARY TABLE tmp_item_spells(
    slot          TINYINT UNSIGNED NOT NULL,
    spell_id      INT UNSIGNED NOT NULL,
    spell_trigger TINYINT UNSIGNED NOT NULL,
    amount        INT NOT NULL,
    kind          VARCHAR(32) NULL,
    statmod       DOUBLE NULL,
    locked        TINYINT(1) NOT NULL DEFAULT 0,
    target_amount INT NULL,
    PRIMARY KEY(slot, spell_id)
  ) ENGINE=MEMORY;

  /* On Use (0) + Equip (1) + Chance on Hit (2) */
  INSERT IGNORE INTO tmp_item_spells(slot, spell_id, spell_trigger, amount)
  SELECT 1, it.spellid_1, it.spelltrigger_1, (sp.EffectBasePoints_1 + 1)
  FROM lplusworld.item_template it
  JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_1
  WHERE it.entry=p_entry AND it.spelltrigger_1 IN (0,1,2) AND it.spellid_1<>0;

  INSERT IGNORE INTO tmp_item_spells(slot, spell_id, spell_trigger, amount)
  SELECT 2, it.spellid_2, it.spelltrigger_2, (sp.EffectBasePoints_1 + 1)
  FROM lplusworld.item_template it
  JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_2
  WHERE it.entry=p_entry AND it.spelltrigger_2 IN (0,1,2) AND it.spellid_2<>0;

  INSERT IGNORE INTO tmp_item_spells(slot, spell_id, spell_trigger, amount)
  SELECT 3, it.spellid_3, it.spelltrigger_3, (sp.EffectBasePoints_1 + 1)
  FROM lplusworld.item_template it
  JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_3
  WHERE it.entry=p_entry AND it.spelltrigger_3 IN (0,1,2) AND it.spellid_3<>0;

  INSERT IGNORE INTO tmp_item_spells(slot, spell_id, spell_trigger, amount)
  SELECT 4, it.spellid_4, it.spelltrigger_4, (sp.EffectBasePoints_1 + 1)
  FROM lplusworld.item_template it
  JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_4
  WHERE it.entry=p_entry AND it.spelltrigger_4 IN (0,1,2) AND it.spellid_4<>0;

  INSERT IGNORE INTO tmp_item_spells(slot, spell_id, spell_trigger, amount)
  SELECT 5, it.spellid_5, it.spelltrigger_5, (sp.EffectBasePoints_1 + 1)
  FROM lplusworld.item_template it
  JOIN dbc.spell_lplus sp ON sp.ID = it.spellid_5
  WHERE it.entry=p_entry AND it.spelltrigger_5 IN (0,1,2) AND it.spellid_5<>0;

  /* debug: auras list (ONE read) */
  SELECT COUNT(*),
         GROUP_CONCAT(CONCAT(slot,'=',spell_id) ORDER BY slot SEPARATOR ', ')
  INTO v_dbg_cnt, v_dbg_txt
  FROM tmp_item_spells;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'AURAS','spell_count',v_dbg_cnt,v_dbg_txt);

  /* ============================================================
     Aura classification
     Rule:
       - "damage and healing" (spellpower) => aura 13 with MAGIC school mask => kind='SD'
       - healing-only => auras 115/135 AND *no SD present in that spell* => kind='HEAL'
  */
  UPDATE tmp_item_spells i
  JOIN dbc.spell_lplus s ON s.ID = i.spell_id
  SET
    i.kind =
      CASE
        WHEN i.spell_trigger = 0 THEN NULL
        WHEN s.EffectAura_1 IN (52,57,71,290,308) OR s.EffectAura_2 IN (52,57,71,290,308) OR s.EffectAura_3 IN (52,57,71,290,308) THEN 'CRIT_PCT'
        WHEN s.EffectAura_1 IN (54,55,199) OR s.EffectAura_2 IN (54,55,199) OR s.EffectAura_3 IN (54,55,199) THEN 'HIT_PCT'
        WHEN s.EffectAura_1 = 49 OR s.EffectAura_2 = 49 OR s.EffectAura_3 = 49 THEN 'DODGE_PCT'
        WHEN s.EffectAura_1 = 47 OR s.EffectAura_2 = 47 OR s.EffectAura_3 = 47 THEN 'PARRY_PCT'

        /* SD (spellpower): aura 13 magic mask */
        WHEN (
             (s.EffectAura_1 = 13 AND (IFNULL(s.EffectMiscValue_1,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_1,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_1,0)=0))
          OR (s.EffectAura_2 = 13 AND (IFNULL(s.EffectMiscValue_2,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_2,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_2,0)=0))
          OR (s.EffectAura_3 = 13 AND (IFNULL(s.EffectMiscValue_3,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_3,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_3,0)=0))
        ) THEN 'SD'

        /* HEAL (healing-only): aura 115/135, but only if the spell does NOT have SD aura 13 magic */
        WHEN (
             (s.EffectAura_1 IN (115,135)) OR (s.EffectAura_2 IN (115,135)) OR (s.EffectAura_3 IN (115,135))
             )
             AND NOT (
               (s.EffectAura_1 = 13 AND (IFNULL(s.EffectMiscValue_1,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_1,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_1,0)=0))
            OR (s.EffectAura_2 = 13 AND (IFNULL(s.EffectMiscValue_2,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_2,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_2,0)=0))
            OR (s.EffectAura_3 = 13 AND (IFNULL(s.EffectMiscValue_3,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_3,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_3,0)=0))
             ) THEN 'HEAL'

        WHEN s.EffectAura_1 = 99 OR s.EffectAura_2 = 99 OR s.EffectAura_3 = 99 THEN 'AP'
        WHEN s.EffectAura_1 = 124 OR s.EffectAura_2 = 124 OR s.EffectAura_3 = 124 THEN 'RAP'
        WHEN s.EffectAura_1 = 85 OR s.EffectAura_2 = 85 OR s.EffectAura_3 = 85 THEN 'MP5'
        WHEN s.EffectAura_1 = 84 OR s.EffectAura_2 = 84 OR s.EffectAura_3 = 84 THEN 'HP5'
        WHEN s.EffectAura_1 = 15 OR s.EffectAura_2 = 15 OR s.EffectAura_3 = 15 THEN 'DAMAGE_SHIELD'
        ELSE NULL
      END,
    i.statmod =
      CASE
        WHEN i.spell_trigger = 0 THEN NULL
        WHEN (s.EffectAura_1 IN (52,57,71,290,308) OR s.EffectAura_2 IN (52,57,71,290,308) OR s.EffectAura_3 IN (52,57,71,290,308)) THEN @W_CRIT
        WHEN (s.EffectAura_1 IN (54,55,199) OR s.EffectAura_2 IN (54,55,199) OR s.EffectAura_3 IN (54,55,199)) THEN @W_HIT
        WHEN (s.EffectAura_1 = 49 OR s.EffectAura_2 = 49 OR s.EffectAura_3 = 49) THEN @W_DODGE
        WHEN (s.EffectAura_1 = 47 OR s.EffectAura_2 = 47 OR s.EffectAura_3 = 47) THEN @W_PARRY

        WHEN (
             (s.EffectAura_1 = 13 AND (IFNULL(s.EffectMiscValue_1,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_1,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_1,0)=0))
          OR (s.EffectAura_2 = 13 AND (IFNULL(s.EffectMiscValue_2,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_2,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_2,0)=0))
          OR (s.EffectAura_3 = 13 AND (IFNULL(s.EffectMiscValue_3,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_3,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_3,0)=0))
        ) THEN @W_SD_ALL

        WHEN (
             (s.EffectAura_1 IN (115,135)) OR (s.EffectAura_2 IN (115,135)) OR (s.EffectAura_3 IN (115,135))
             )
             AND NOT (
               (s.EffectAura_1 = 13 AND (IFNULL(s.EffectMiscValue_1,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_1,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_1,0)=0))
            OR (s.EffectAura_2 = 13 AND (IFNULL(s.EffectMiscValue_2,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_2,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_2,0)=0))
            OR (s.EffectAura_3 = 13 AND (IFNULL(s.EffectMiscValue_3,0) & 1)=0 AND ((IFNULL(s.EffectMiscValue_3,0) & 126)<>0 OR IFNULL(s.EffectMiscValue_3,0)=0))
             ) THEN @W_HEAL

        WHEN (s.EffectAura_1 = 99 OR s.EffectAura_2 = 99 OR s.EffectAura_3 = 99) THEN @W_AP
        WHEN (s.EffectAura_1 = 124 OR s.EffectAura_2 = 124 OR s.EffectAura_3 = 124) THEN @W_RAP
        WHEN (s.EffectAura_1 = 85 OR s.EffectAura_2 = 85 OR s.EffectAura_3 = 85) THEN @W_MP5
        WHEN (s.EffectAura_1 = 84 OR s.EffectAura_2 = 84 OR s.EffectAura_3 = 84) THEN @W_HP5
        WHEN (s.EffectAura_1 = 15 OR s.EffectAura_2 = 15 OR s.EffectAura_3 = 15) THEN @W_DAMAGE_SHIELD
        ELSE NULL
      END,
    i.locked =
      CASE
        WHEN i.spell_trigger = 0 THEN 0
        WHEN (s.EffectAura_1 IN (47,49,51,52,54,55,57,71,199,290,308)
           OR s.EffectAura_2 IN (47,49,51,52,54,55,57,71,199,290,308)
           OR s.EffectAura_3 IN (47,49,51,52,54,55,57,71,199,290,308))
          THEN 1
        ELSE 0
      END;

  /* Normalize magnitude for SD and HEAL separately:
     - SD: MAX of aura13-magic and (if present) healing auras too, so SD spells keep them in sync
     - HEAL: MAX of healing auras only (115/135)
  */
  UPDATE tmp_item_spells i
  JOIN dbc.spell_lplus s ON s.ID = i.spell_id
  SET i.amount = GREATEST(
      CASE WHEN (s.EffectAura_1=13 AND (IFNULL(s.EffectMiscValue_1,0)&1)=0 AND ((IFNULL(s.EffectMiscValue_1,0)&126)<>0 OR IFNULL(s.EffectMiscValue_1,0)=0)) THEN (IFNULL(s.EffectBasePoints_1,0)+1)
           WHEN (s.EffectAura_1 IN (115,135)) THEN (IFNULL(s.EffectBasePoints_1,0)+1)
           ELSE 0 END,
      CASE WHEN (s.EffectAura_2=13 AND (IFNULL(s.EffectMiscValue_2,0)&1)=0 AND ((IFNULL(s.EffectMiscValue_2,0)&126)<>0 OR IFNULL(s.EffectMiscValue_2,0)=0)) THEN (IFNULL(s.EffectBasePoints_2,0)+1)
           WHEN (s.EffectAura_2 IN (115,135)) THEN (IFNULL(s.EffectBasePoints_2,0)+1)
           ELSE 0 END,
      CASE WHEN (s.EffectAura_3=13 AND (IFNULL(s.EffectMiscValue_3,0)&1)=0 AND ((IFNULL(s.EffectMiscValue_3,0)&126)<>0 OR IFNULL(s.EffectMiscValue_3,0)=0)) THEN (IFNULL(s.EffectBasePoints_3,0)+1)
           WHEN (s.EffectAura_3 IN (115,135)) THEN (IFNULL(s.EffectBasePoints_3,0)+1)
           ELSE 0 END,
      i.amount
  )
  WHERE i.kind = 'SD';

  UPDATE tmp_item_spells i
  JOIN dbc.spell_lplus s ON s.ID = i.spell_id
  SET i.amount = GREATEST(
      CASE WHEN (s.EffectAura_1 IN (115,135)) THEN (IFNULL(s.EffectBasePoints_1,0)+1) ELSE 0 END,
      CASE WHEN (s.EffectAura_2 IN (115,135)) THEN (IFNULL(s.EffectBasePoints_2,0)+1) ELSE 0 END,
      CASE WHEN (s.EffectAura_3 IN (115,135)) THEN (IFNULL(s.EffectBasePoints_3,0)+1) ELSE 0 END,
      i.amount
  )
  WHERE i.kind = 'HEAL';

  /* debug: known vs unknown */
  SELECT
    SUM(CASE WHEN kind IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN kind IS NULL THEN 1 ELSE 0 END)
  INTO v_known_cnt, v_unknown_cnt
  FROM tmp_item_spells;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'AURAS_CLASSIFIED','known_count',v_known_cnt,CONCAT('unknown_count=',v_unknown_cnt));

  /* ============================================================
     CASTER TRADE (ONLY affects SD / HEAL on caster weapons, NOT DPS)
     SD target:   4.0  * (ilvl-60)
     HEAL target: 7.66 * (ilvl-60)
     ============================================================ */

  SELECT COALESCE(MAX(amount),0) INTO v_total_sd_cur
  FROM tmp_item_spells
  WHERE kind = 'SD';

  SELECT COALESCE(MAX(amount),0) INTO v_total_heal_cur
  FROM tmp_item_spells
  WHERE kind = 'HEAL';

  SET v_is_caster_weapon :=
    CASE
      WHEN v_class = 2
           AND v_is_weapon_slot = 1
           AND IFNULL(v_delay_ms,0) > 0
           AND NOT (v_inv = 26 OR v_subclass = 19) /* EXCLUDE WANDS */
           AND (IFNULL(v_caster_flag,0) = 1)
      THEN 1
      ELSE 0
    END;

  SET v_k_sd := NULL;
  SET v_k_heal := NULL;
  SET v_trade_sd_tgt := 0;
  SET v_trade_heal_tgt := 0;

  IF v_is_caster_weapon = 1 THEN
    IF v_total_sd_cur > 0 THEN
      SET v_trade_sd_tgt := 4.0 * GREATEST(p_target_ilvl - 60, 0);
      SET v_k_sd := v_trade_sd_tgt / v_total_sd_cur;
    END IF;

    IF v_total_heal_cur > 0 THEN
      SET v_trade_heal_tgt := 7.66 * GREATEST(p_target_ilvl - 60, 0);
      SET v_k_heal := v_trade_heal_tgt / v_total_heal_cur;
    END IF;
  END IF;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'CASTER_TRADE','k_sd',IFNULL(v_k_sd,-1),
          CONCAT('is_caster_weapon=',v_is_caster_weapon,' sd_cur=',v_total_sd_cur,' sd_tgt=',v_trade_sd_tgt,
                 ' | k_heal=',IFNULL(v_k_heal,-1),' heal_cur=',v_total_heal_cur,' heal_tgt=',v_trade_heal_tgt));

  /* ============================================================
     TERM SUMS
     ============================================================ */
  SELECT COALESCE(SUM(POW(GREATEST(0.0, amount * statmod), 1.5)),0.0)
  INTO v_S_locked
  FROM tmp_stat_lines
  WHERE locked=1;

  SELECT v_S_locked + COALESCE(SUM(POW(GREATEST(0.0, amount * statmod), 1.5)),0.0)
  INTO v_S_locked
  FROM tmp_item_spells
  WHERE locked=1 AND kind IS NOT NULL AND statmod IS NOT NULL;

  SELECT COALESCE(SUM(POW(GREATEST(0.0, amount * statmod), 1.5)),0.0)
  INTO v_S_sd_cur
  FROM tmp_item_spells
  WHERE kind='SD' AND statmod IS NOT NULL;

  SELECT COALESCE(SUM(POW(GREATEST(0.0, amount * statmod), 1.5)),0.0)
  INTO v_S_heal_cur
  FROM tmp_item_spells
  WHERE kind='HEAL' AND statmod IS NOT NULL;

  SELECT COALESCE(SUM(POW(GREATEST(0.0, amount * statmod), 1.5)),0.0)
  INTO v_S_other_cur
  FROM tmp_stat_lines
  WHERE locked=0;

  SELECT v_S_other_cur + COALESCE(SUM(POW(GREATEST(0.0, amount * statmod), 1.5)),0.0)
  INTO v_S_other_cur
  FROM tmp_item_spells
  WHERE kind IS NOT NULL
    AND statmod IS NOT NULL
    AND locked=0
    AND kind NOT IN ('SD','HEAL');

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'S_CUR','S_locked',v_S_locked,CONCAT('S_other=',v_S_other_cur,' S_sd=',v_S_sd_cur,' S_heal=',v_S_heal_cur,' S_target=',v_S_target));

  /* ============================================================
     SOLVE SCALE FACTORS
     ============================================================ */
  IF v_k_sd IS NULL THEN SET v_k_sd := 1.0; END IF;
  IF v_k_heal IS NULL THEN SET v_k_heal := 1.0; END IF;

  IF v_inv IN (14,22,23) OR v_is_weapon_slot = 1 THEN
    SET v_k_other := v_k_doc;

    /* if no caster-trade override, SD/HEAL follow k_other */
    IF NOT (v_is_caster_weapon = 1 AND v_total_sd_cur > 0) THEN
      SET v_k_sd := v_k_other;
    END IF;
    IF NOT (v_is_caster_weapon = 1 AND v_total_heal_cur > 0) THEN
      SET v_k_heal := v_k_other;
    END IF;

    SET v_mode := CASE
      WHEN v_is_weapon_slot = 1 THEN 'DOC_RATIO_WEAPON'
      ELSE 'DOC_RATIO_SHIELD'
    END;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,'K_SOLVED','k_other',v_k_other,CONCAT('k_sd=',v_k_sd,' k_heal=',v_k_heal,' inv=',v_inv,' mode=',v_mode));
  ELSE
    /* budget solve: reserve spell buckets separately */
    SET v_S_rem_other := v_S_target - v_S_locked
                         - (POW(GREATEST(v_k_sd,0.0),1.5)   * v_S_sd_cur)
                         - (POW(GREATEST(v_k_heal,0.0),1.5) * v_S_heal_cur);

    IF v_S_rem_other < 0 THEN SET v_S_rem_other := 0; END IF;

    IF v_S_other_cur > 0 THEN
      SET v_k_other := POW(v_S_rem_other / v_S_other_cur, 2.0/3.0);
    ELSE
      SET v_k_other := CASE
        WHEN (v_S_sd_cur + v_S_heal_cur) > 0 THEN POW(GREATEST(v_S_target - v_S_locked, 0.0) / NULLIF((v_S_sd_cur + v_S_heal_cur), 0.0), 2.0/3.0)
        WHEN v_scale_unknown = 1 AND v_unknown_cnt > 0 THEN v_k_doc
        ELSE 1.0
      END;
    END IF;

    /* for non-caster or missing buckets, SD/HEAL follow k_other */
    IF NOT (v_is_caster_weapon = 1 AND v_total_sd_cur > 0) THEN
      SET v_k_sd := v_k_other;
    END IF;
    IF NOT (v_is_caster_weapon = 1 AND v_total_heal_cur > 0) THEN
      SET v_k_heal := v_k_other;
    END IF;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,'K_SOLVED','k_other',v_k_other,CONCAT('k_sd=',v_k_sd,' k_heal=',v_k_heal,' inv=',v_inv,' mode=BUDGET'));
  END IF;

  /* ============================================================
     INITIAL NEW AMOUNTS
     ============================================================ */
  UPDATE tmp_stat_lines
  SET new_amount =
    CASE
      WHEN locked=1 THEN amount
      ELSE ROUND(amount * v_k_other)
    END;

  UPDATE tmp_item_spells
  SET target_amount =
    CASE
      WHEN kind IS NULL THEN CASE WHEN spell_trigger = 0 THEN NULL WHEN v_scale_unknown=1 THEN -1 ELSE NULL END
      WHEN locked=1 THEN amount
      WHEN kind='SD'   THEN ROUND(amount * v_k_sd)
      WHEN kind='HEAL' THEN ROUND(amount * v_k_heal)
      ELSE ROUND(amount * v_k_other)
    END;

  /* ============================================================
     GREEDY NUDGE (unchanged conceptually)
     ============================================================ */
  IF v_inv NOT IN (14,22,23) AND v_is_weapon_slot = 0 THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_components;
    CREATE TEMPORARY TABLE tmp_components(
      comp_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
      src VARCHAR(8) NOT NULL,
      stat_line_id INT UNSIGNED NULL,
      aura_slot TINYINT UNSIGNED NULL,
      aura_spell_id INT UNSIGNED NULL,
      val DOUBLE NOT NULL,
      kmod DOUBLE NOT NULL,
      PRIMARY KEY(comp_id),
      UNIQUE KEY uq_comp (src, stat_line_id, aura_slot, aura_spell_id)
    ) ENGINE=MEMORY;

    INSERT IGNORE INTO tmp_components(src, stat_line_id, val, kmod)
    SELECT 'STAT', line_id, new_amount, statmod
    FROM tmp_stat_lines
    WHERE locked=0 AND new_amount IS NOT NULL AND statmod IS NOT NULL;

    /* NOTE: do NOT include SD/HEAL in nudge pool */
    INSERT IGNORE INTO tmp_components(src, aura_slot, aura_spell_id, val, kmod)
    SELECT 'AURA', slot, spell_id, target_amount, statmod
    FROM tmp_item_spells
    WHERE kind IS NOT NULL
      AND statmod IS NOT NULL
      AND locked=0
      AND target_amount IS NOT NULL
      AND kind NOT IN ('SD','HEAL');

    SELECT COALESCE(SUM(POW(GREATEST(0.0, val*kmod),1.5)),0.0)
    INTO v_S_components
    FROM tmp_components;

    /* spell buckets already have target_amount set */
    SELECT COALESCE(SUM(POW(GREATEST(0.0, target_amount*statmod),1.5)),0.0)
    INTO v_S_spell_now
    FROM tmp_item_spells
    WHERE kind IN ('SD','HEAL') AND statmod IS NOT NULL AND target_amount IS NOT NULL;

    SET v_S_total_now := v_S_locked + v_S_components + v_S_spell_now;
    SET v_err_now := ABS(v_S_total_now - v_S_target);

    SET v_iter := 0;
    nudge_loop: WHILE v_iter < 60 DO
      SET v_iter := v_iter + 1;
      SET v_dir := CASE WHEN v_S_total_now > v_S_target THEN -1 ELSE 1 END;

      DROP TEMPORARY TABLE IF EXISTS tmp_best;
      CREATE TEMPORARY TABLE tmp_best(
        comp_id INT UNSIGNED NOT NULL,
        new_val DOUBLE NOT NULL,
        new_S DOUBLE NOT NULL,
        new_err DOUBLE NOT NULL,
        PRIMARY KEY(comp_id)
      ) ENGINE=MEMORY;

      INSERT INTO tmp_best(comp_id, new_val, new_S, new_err)
      SELECT
        c.comp_id,
        c.val + v_dir AS new_val,
        v_S_total_now
          - POW(GREATEST(0.0, c.val*c.kmod),1.5)
          + POW(GREATEST(0.0, (c.val+v_dir)*c.kmod),1.5) AS new_S,
        ABS(
          (
            v_S_total_now
            - POW(GREATEST(0.0, c.val*c.kmod),1.5)
            + POW(GREATEST(0.0, (c.val+v_dir)*c.kmod),1.5)
          ) - v_S_target
        ) AS new_err
      FROM tmp_components c
      WHERE (c.val + v_dir) >= 0
      ORDER BY new_err ASC
      LIMIT 1;

      IF (SELECT COUNT(*) FROM tmp_best) = 0 THEN
        DROP TEMPORARY TABLE IF EXISTS tmp_best;
        LEAVE nudge_loop;
      END IF;

      SELECT new_S, new_err, comp_id, new_val
      INTO @best_S, @best_err, @best_id, @best_val
      FROM tmp_best LIMIT 1;

      IF @best_err + 1e-9 >= v_err_now THEN
        DROP TEMPORARY TABLE IF EXISTS tmp_best;
        LEAVE nudge_loop;
      END IF;

      UPDATE tmp_components SET val = @best_val WHERE comp_id = @best_id;

      SET v_S_total_now := @best_S;
      SET v_err_now := @best_err;

      DROP TEMPORARY TABLE IF EXISTS tmp_best;
    END WHILE;

    UPDATE tmp_stat_lines s
    JOIN tmp_components c ON c.src='STAT' AND c.stat_line_id=s.line_id
    SET s.new_amount = c.val;

    UPDATE tmp_item_spells a
    JOIN tmp_components c ON c.src='AURA' AND c.aura_slot=a.slot AND c.aura_spell_id=a.spell_id
    SET a.target_amount = CAST(c.val AS SIGNED);

    DROP TEMPORARY TABLE IF EXISTS tmp_components;
  END IF;

  /* ============================================================
     APPLY BASE STATS / RESISTS / BLOCK / BONUS ARMOR
     Also set ItemLevel to target.
     ============================================================ */
  IF p_apply = 1 THEN
    DROP TEMPORARY TABLE IF EXISTS tmp_stat_pivot;
    CREATE TEMPORARY TABLE tmp_stat_pivot ENGINE=MEMORY AS
    SELECT
      MAX(CASE WHEN src='STAT' AND slot_idx=1  THEN new_amount END) AS stat1,
      MAX(CASE WHEN src='STAT' AND slot_idx=2  THEN new_amount END) AS stat2,
      MAX(CASE WHEN src='STAT' AND slot_idx=3  THEN new_amount END) AS stat3,
      MAX(CASE WHEN src='STAT' AND slot_idx=4  THEN new_amount END) AS stat4,
      MAX(CASE WHEN src='STAT' AND slot_idx=5  THEN new_amount END) AS stat5,
      MAX(CASE WHEN src='STAT' AND slot_idx=6  THEN new_amount END) AS stat6,
      MAX(CASE WHEN src='STAT' AND slot_idx=7  THEN new_amount END) AS stat7,
      MAX(CASE WHEN src='STAT' AND slot_idx=8  THEN new_amount END) AS stat8,
      MAX(CASE WHEN src='STAT' AND slot_idx=9  THEN new_amount END) AS stat9,
      MAX(CASE WHEN src='STAT' AND slot_idx=10 THEN new_amount END) AS stat10,

      MAX(CASE WHEN kind='RES_HOLY'   THEN new_amount END) AS res_holy,
      MAX(CASE WHEN kind='RES_FIRE'   THEN new_amount END) AS res_fire,
      MAX(CASE WHEN kind='RES_NATURE' THEN new_amount END) AS res_nature,
      MAX(CASE WHEN kind='RES_FROST'  THEN new_amount END) AS res_frost,
      MAX(CASE WHEN kind='RES_SHADOW' THEN new_amount END) AS res_shadow,
      MAX(CASE WHEN kind='RES_ARCANE' THEN new_amount END) AS res_arcane,

      MAX(CASE WHEN kind='BLOCK_VALUE' THEN new_amount END) AS block_value,
      MAX(CASE WHEN kind='BONUS_ARMOR' THEN new_amount END) AS bonus_armor
    FROM tmp_stat_lines;

    UPDATE lplusworld.item_template t
    JOIN tmp_stat_pivot p
    SET
      t.ItemLevel    = p_target_ilvl,

      t.stat_value1  = COALESCE(CAST(p.stat1  AS SIGNED), t.stat_value1),
      t.stat_value2  = COALESCE(CAST(p.stat2  AS SIGNED), t.stat_value2),
      t.stat_value3  = COALESCE(CAST(p.stat3  AS SIGNED), t.stat_value3),
      t.stat_value4  = COALESCE(CAST(p.stat4  AS SIGNED), t.stat_value4),
      t.stat_value5  = COALESCE(CAST(p.stat5  AS SIGNED), t.stat_value5),
      t.stat_value6  = COALESCE(CAST(p.stat6  AS SIGNED), t.stat_value6),
      t.stat_value7  = COALESCE(CAST(p.stat7  AS SIGNED), t.stat_value7),
      t.stat_value8  = COALESCE(CAST(p.stat8  AS SIGNED), t.stat_value8),
      t.stat_value9  = COALESCE(CAST(p.stat9  AS SIGNED), t.stat_value9),
      t.stat_value10 = COALESCE(CAST(p.stat10 AS SIGNED), t.stat_value10),

      t.holy_res   = COALESCE(CAST(p.res_holy   AS SIGNED), t.holy_res),
      t.fire_res   = COALESCE(CAST(p.res_fire   AS SIGNED), t.fire_res),
      t.nature_res = COALESCE(CAST(p.res_nature AS SIGNED), t.nature_res),
      t.frost_res  = COALESCE(CAST(p.res_frost  AS SIGNED), t.frost_res),
      t.shadow_res = COALESCE(CAST(p.res_shadow AS SIGNED), t.shadow_res),
      t.arcane_res = COALESCE(CAST(p.res_arcane AS SIGNED), t.arcane_res),

      t.block      = COALESCE(CAST(p.block_value AS SIGNED), t.block),

      t.ArmorDamageModifier =
        CASE
          WHEN IFNULL(p_keep_bonus_armor,0)<>0 THEN t.ArmorDamageModifier
          ELSE COALESCE(CAST(p.bonus_armor AS SIGNED), t.ArmorDamageModifier)
        END
    WHERE t.entry = p_entry;

    DROP TEMPORARY TABLE IF EXISTS tmp_stat_pivot;

    /* ============================================================
       WORKFLOW NORMALIZATION: SHIELD ARMOR + WAND DPS (median donors)
       - Shields: armor = median(BASE armor of donors) + this item's bonus armor
       - Wands:   scale dmg_min1/dmg_max1 so DPS matches median donor DPS (keep delay)
       NOTE: uses donors from legionnaireworld near p_target_ilvl (±3).
       ============================================================ */

    /* ---------- Shields (class=4, subclass=6, inv=14) ---------- */
    IF v_class = 4 AND v_subclass = 6 AND v_inv = 14 THEN
      SET v_median_base_armor := NULL;

            /* Count eligible donors once (ONLY_FULL_GROUP_BY safe) */
      SET v_dbg_cnt := 0;
      SELECT COUNT(*)
      INTO v_dbg_cnt
      FROM legionnaireworld.item_template d
      WHERE d.Quality       = v_quality
          AND d.class         = v_class
          AND d.subclass      = v_subclass
          AND d.InventoryType = v_inv
          AND d.entry        <> p_entry
          AND d.trueItemLevel BETWEEN (p_target_ilvl - 3) AND (p_target_ilvl + 3)
          AND (d.armor - IFNULL(d.ArmorDamageModifier, 0)) > 0;

      IF v_dbg_cnt > 0 THEN
        SELECT
          CASE
            WHEN MOD(v_dbg_cnt, 2) = 1
              THEN MAX(CASE WHEN rn = (v_dbg_cnt + 1) / 2 THEN base_armor END)
            ELSE AVG(CASE WHEN rn IN (v_dbg_cnt / 2, v_dbg_cnt / 2 + 1) THEN base_armor END)
          END
        INTO v_median_base_armor
        FROM (
          SELECT
            (d.armor - IFNULL(d.ArmorDamageModifier, 0)) AS base_armor,
            ROW_NUMBER() OVER (
              ORDER BY (d.armor - IFNULL(d.ArmorDamageModifier, 0))
            ) AS rn
          FROM legionnaireworld.item_template d
          WHERE d.Quality       = v_quality
          AND d.class         = v_class
          AND d.subclass      = v_subclass
          AND d.InventoryType = v_inv
          AND d.entry        <> p_entry
          AND d.trueItemLevel BETWEEN (p_target_ilvl - 3) AND (p_target_ilvl + 3)
          AND (d.armor - IFNULL(d.ArmorDamageModifier, 0)) > 0
        ) ranked2;
      END IF;

      IF v_median_base_armor IS NOT NULL THEN
        UPDATE lplusworld.item_template
        SET armor = CAST(v_median_base_armor AS UNSIGNED) + IFNULL(ArmorDamageModifier, 0)
        WHERE entry = p_entry;
      END IF;
    END IF;

    /* ---------- Wands (class=2, subclass=19) ---------- */
    IF v_class = 2 AND v_subclass = 19 AND v_inv IN (26,15,25) THEN
      SET v_median_dps := NULL;

            /* Count eligible donors once (ONLY_FULL_GROUP_BY safe) */
      SET v_dbg_cnt := 0;
      SELECT COUNT(*)
      INTO v_dbg_cnt
      FROM legionnaireworld.item_template d
      WHERE d.Quality       = v_quality
          AND d.class         = v_class
          AND d.subclass      = v_subclass
          AND d.InventoryType = v_inv
          AND d.entry        <> p_entry
          AND d.trueItemLevel BETWEEN (p_target_ilvl - 3) AND (p_target_ilvl + 3)
          AND d.delay > 0
          AND IFNULL(d.dmg_min1,0) > 0
          AND IFNULL(d.dmg_max1,0) >= IFNULL(d.dmg_min1,0);

      IF v_dbg_cnt > 0 THEN
        SELECT
          CASE
            WHEN MOD(v_dbg_cnt, 2) = 1
              THEN MAX(CASE WHEN rn = (v_dbg_cnt + 1) / 2 THEN dps END)
            ELSE AVG(CASE WHEN rn IN (v_dbg_cnt / 2, v_dbg_cnt / 2 + 1) THEN dps END)
          END
        INTO v_median_dps
        FROM (
          SELECT
            (((IFNULL(d.dmg_min1,0) + IFNULL(d.dmg_max1,0)) / 2.0) / NULLIF(d.delay,0)) * 1000.0 AS dps,
            ROW_NUMBER() OVER (
              ORDER BY (((IFNULL(d.dmg_min1,0) + IFNULL(d.dmg_max1,0)) / 2.0) / NULLIF(d.delay,0)) * 1000.0
            ) AS rn
          FROM legionnaireworld.item_template d
          WHERE d.Quality       = v_quality
          AND d.class         = v_class
          AND d.subclass      = v_subclass
          AND d.InventoryType = v_inv
          AND d.entry        <> p_entry
          AND d.trueItemLevel BETWEEN (p_target_ilvl - 3) AND (p_target_ilvl + 3)
          AND d.delay > 0
          AND IFNULL(d.dmg_min1,0) > 0
          AND IFNULL(d.dmg_max1,0) >= IFNULL(d.dmg_min1,0)
        ) ranked2;
      END IF;

      SELECT IFNULL(dmg_min1,0), IFNULL(dmg_max1,0), IFNULL(delay,0)
      INTO v_dmg_min1_cur, v_dmg_max1_cur, v_delay_cur
      FROM lplusworld.item_template
      WHERE entry = p_entry
      LIMIT 1;

      IF v_median_dps IS NOT NULL
         AND v_delay_cur > 0
         AND v_dmg_min1_cur > 0
         AND v_dmg_max1_cur >= v_dmg_min1_cur THEN

        SET v_cur_dps := (((v_dmg_min1_cur + v_dmg_max1_cur) / 2.0) / v_delay_cur) * 1000.0;

        IF v_cur_dps IS NOT NULL AND v_cur_dps > 0 THEN
          SET v_scale_dps := v_median_dps / v_cur_dps;

          UPDATE lplusworld.item_template
          SET dmg_min1 = CAST(ROUND(dmg_min1 * v_scale_dps) AS UNSIGNED),
              dmg_max1 = CAST(ROUND(dmg_max1 * v_scale_dps) AS UNSIGNED)
          WHERE entry = p_entry;
        END IF;
      END IF;
    END IF;

    END IF;


    /* ---------- D) Post-pass: reduce melee DPS by 2 for caster weapons (excluding wands) ----------
       This is a final correction ONLY to melee DPS output.
       It must NOT change the caster tradeoff (spell/heal targets already computed above).
       We do this by subtracting damage = (SacrificedDPS + 2) * (delay_ms/1000) from BOTH min/max to keep spread.
    */
    IF v_class = 2
       AND IFNULL(v_caster_flag,0) = 1
       AND v_subclass <> 19
       AND IFNULL(v_delay_ms,0) > 0
       AND v_inv IN (13,17,21,15,25,26) THEN

      SELECT IFNULL(dmg_min1,0), IFNULL(dmg_max1,0), IFNULL(delay,0)
      INTO v_dmg_min1_cur, v_dmg_max1_cur, v_delay_cur
      FROM lplusworld.item_template
      WHERE entry = p_entry
      LIMIT 1;

      IF v_delay_cur > 0
         AND v_dmg_max1_cur >= v_dmg_min1_cur
         AND v_dmg_max1_cur > 0 THEN

        SET v_dps_delta := GREATEST(p_target_ilvl - 60, 0) + 2.0;
        SET v_dmg_delta := v_dps_delta * v_delay_cur / 1000.0;

        UPDATE lplusworld.item_template
        SET dmg_min1 = CAST(GREATEST(1, ROUND(dmg_min1 - v_dmg_delta)) AS UNSIGNED),
            dmg_max1 = CAST(GREATEST(1, ROUND(dmg_max1 - v_dmg_delta)) AS UNSIGNED)
        WHERE entry = p_entry;

        /* guard: rounding can (rarely) flip max<min */
        UPDATE lplusworld.item_template
        SET dmg_max1 = GREATEST(dmg_max1, dmg_min1)
        WHERE entry = p_entry;

        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        VALUES (p_entry,'CASTER_DPS_POSTPASS','dps_minus',v_dps_delta,
                CONCAT('delay=',v_delay_cur,' dmg_delta=',v_dmg_delta));
      END IF;
    END IF;


  /* ============================================================
     APPLY AURAS (clone + rebind) — basepoints only
     ============================================================ */
  IF v_scale_auras_f = 1 AND p_apply = 1 THEN
    BEGIN
      DECLARE cur CURSOR FOR
        SELECT slot, spell_id, kind, amount, target_amount, locked
        FROM tmp_item_spells
        WHERE spell_id IS NOT NULL AND spell_id <> 0
          AND (
            (kind IS NULL AND v_scale_unknown = 1 AND spell_trigger <> 0)
            OR (kind IS NOT NULL AND locked = 0 AND target_amount IS NOT NULL AND target_amount <> amount)
          );

      DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

      DROP TEMPORARY TABLE IF EXISTS tmp_clone_spell_g;
      CREATE TEMPORARY TABLE tmp_clone_spell_g LIKE dbc.spell_lplus;

      DROP TEMPORARY TABLE IF EXISTS tmp_clone_trigger_g;
      CREATE TEMPORARY TABLE tmp_clone_trigger_g LIKE dbc.spell_lplus;

      SET done := 0;
      OPEN cur;
      readloop: LOOP
        FETCH cur INTO c_slot, c_spell_id, c_kind, c_amount, c_target_amount, c_locked;
        IF done = 1 THEN LEAVE readloop; END IF;

        IF c_kind IS NOT NULL AND c_locked = 1 THEN
          ITERATE readloop;
        END IF;

        CALL helper.sp_GetNextSpellId(c_new_spell_id);

        DELETE FROM tmp_clone_spell_g;
        INSERT INTO tmp_clone_spell_g
        SELECT * FROM dbc.spell_lplus WHERE ID = c_spell_id LIMIT 1;

        IF c_kind IS NULL THEN
          UPDATE tmp_clone_spell_g
          SET ID = c_new_spell_id,
              EffectBasePoints_1 = CASE WHEN Effect_1<>0 AND EffectBasePoints_1 IS NOT NULL THEN ROUND(EffectBasePoints_1 * v_k_other) ELSE EffectBasePoints_1 END,
              EffectBasePoints_2 = CASE WHEN Effect_2<>0 AND EffectBasePoints_2 IS NOT NULL THEN ROUND(EffectBasePoints_2 * v_k_other) ELSE EffectBasePoints_2 END,
              EffectBasePoints_3 = CASE WHEN Effect_3<>0 AND EffectBasePoints_3 IS NOT NULL THEN ROUND(EffectBasePoints_3 * v_k_other) ELSE EffectBasePoints_3 END;
        ELSE
          /* Known spell:
             - SD => update aura13-magic AND any healing auras present (keep in sync)
             - HEAL => update healing-only auras (115/135) ONLY
          */
          IF c_kind = 'SD' THEN
            UPDATE tmp_clone_spell_g
            SET ID = c_new_spell_id,
                EffectBasePoints_1 = CASE
                  WHEN (EffectAura_1 IN (115,135))
                       OR (EffectAura_1=13 AND (IFNULL(EffectMiscValue_1,0)&1)=0 AND ((IFNULL(EffectMiscValue_1,0)&126)<>0 OR IFNULL(EffectMiscValue_1,0)=0))
                  THEN (c_target_amount - 1)
                  ELSE EffectBasePoints_1
                END,
                EffectBasePoints_2 = CASE
                  WHEN (EffectAura_2 IN (115,135))
                       OR (EffectAura_2=13 AND (IFNULL(EffectMiscValue_2,0)&1)=0 AND ((IFNULL(EffectMiscValue_2,0)&126)<>0 OR IFNULL(EffectMiscValue_2,0)=0))
                  THEN (c_target_amount - 1)
                  ELSE EffectBasePoints_2
                END,
                EffectBasePoints_3 = CASE
                  WHEN (EffectAura_3 IN (115,135))
                       OR (EffectAura_3=13 AND (IFNULL(EffectMiscValue_3,0)&1)=0 AND ((IFNULL(EffectMiscValue_3,0)&126)<>0 OR IFNULL(EffectMiscValue_3,0)=0))
                  THEN (c_target_amount - 1)
                  ELSE EffectBasePoints_3
                END;
          ELSEIF c_kind = 'HEAL' THEN
            UPDATE tmp_clone_spell_g
            SET ID = c_new_spell_id,
                EffectBasePoints_1 = CASE WHEN (EffectAura_1 IN (115,135)) THEN (c_target_amount - 1) ELSE EffectBasePoints_1 END,
                EffectBasePoints_2 = CASE WHEN (EffectAura_2 IN (115,135)) THEN (c_target_amount - 1) ELSE EffectBasePoints_2 END,
                EffectBasePoints_3 = CASE WHEN (EffectAura_3 IN (115,135)) THEN (c_target_amount - 1) ELSE EffectBasePoints_3 END;
          ELSE
            UPDATE tmp_clone_spell_g
            SET ID = c_new_spell_id,
                EffectBasePoints_1 = (c_target_amount - 1);
          END IF;
        END IF;

        /* clone triggered spells too (basepoints only) */
        SELECT EffectTriggerSpell_1, EffectTriggerSpell_2, EffectTriggerSpell_3, Description_Lang_enUS
          INTO v_trig1, v_trig2, v_trig3, v_desc_en
        FROM tmp_clone_spell_g LIMIT 1;

        IF v_trig1 IS NOT NULL AND v_trig1 > 0 THEN
          CALL helper.sp_GetNextSpellId(v_trig1_new);
          DELETE FROM tmp_clone_trigger_g;
          INSERT INTO tmp_clone_trigger_g SELECT * FROM dbc.spell_lplus WHERE ID=v_trig1 LIMIT 1;
          UPDATE tmp_clone_trigger_g
          SET ID = v_trig1_new,
              EffectBasePoints_1 = CASE WHEN Effect_1<>0 AND EffectBasePoints_1 IS NOT NULL THEN ROUND(EffectBasePoints_1 * v_k_other) ELSE EffectBasePoints_1 END,
              EffectBasePoints_2 = CASE WHEN Effect_2<>0 AND EffectBasePoints_2 IS NOT NULL THEN ROUND(EffectBasePoints_2 * v_k_other) ELSE EffectBasePoints_2 END,
              EffectBasePoints_3 = CASE WHEN Effect_3<>0 AND EffectBasePoints_3 IS NOT NULL THEN ROUND(EffectBasePoints_3 * v_k_other) ELSE EffectBasePoints_3 END;
          INSERT INTO dbc.spell_lplus SELECT * FROM tmp_clone_trigger_g;
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig1,'s1'), CONCAT('$',v_trig1_new,'s1'));
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig1,'s2'), CONCAT('$',v_trig1_new,'s2'));
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig1,'s3'), CONCAT('$',v_trig1_new,'s3'));
          UPDATE tmp_clone_spell_g SET EffectTriggerSpell_1 = v_trig1_new, Description_Lang_enUS = v_desc_en;
        END IF;

        IF v_trig2 IS NOT NULL AND v_trig2 > 0 THEN
          CALL helper.sp_GetNextSpellId(v_trig2_new);
          DELETE FROM tmp_clone_trigger_g;
          INSERT INTO tmp_clone_trigger_g SELECT * FROM dbc.spell_lplus WHERE ID=v_trig2 LIMIT 1;
          UPDATE tmp_clone_trigger_g
          SET ID = v_trig2_new,
              EffectBasePoints_1 = CASE WHEN Effect_1<>0 AND EffectBasePoints_1 IS NOT NULL THEN ROUND(EffectBasePoints_1 * v_k_other) ELSE EffectBasePoints_1 END,
              EffectBasePoints_2 = CASE WHEN Effect_2<>0 AND EffectBasePoints_2 IS NOT NULL THEN ROUND(EffectBasePoints_2 * v_k_other) ELSE EffectBasePoints_2 END,
              EffectBasePoints_3 = CASE WHEN Effect_3<>0 AND EffectBasePoints_3 IS NOT NULL THEN ROUND(EffectBasePoints_3 * v_k_other) ELSE EffectBasePoints_3 END;
          INSERT INTO dbc.spell_lplus SELECT * FROM tmp_clone_trigger_g;
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig2,'s1'), CONCAT('$',v_trig2_new,'s1'));
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig2,'s2'), CONCAT('$',v_trig2_new,'s2'));
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig2,'s3'), CONCAT('$',v_trig2_new,'s3'));
          UPDATE tmp_clone_spell_g SET EffectTriggerSpell_2 = v_trig2_new, Description_Lang_enUS = v_desc_en;
        END IF;

        IF v_trig3 IS NOT NULL AND v_trig3 > 0 THEN
          CALL helper.sp_GetNextSpellId(v_trig3_new);
          DELETE FROM tmp_clone_trigger_g;
          INSERT INTO tmp_clone_trigger_g SELECT * FROM dbc.spell_lplus WHERE ID=v_trig3 LIMIT 1;
          UPDATE tmp_clone_trigger_g
          SET ID = v_trig3_new,
              EffectBasePoints_1 = CASE WHEN Effect_1<>0 AND EffectBasePoints_1 IS NOT NULL THEN ROUND(EffectBasePoints_1 * v_k_other) ELSE EffectBasePoints_1 END,
              EffectBasePoints_2 = CASE WHEN Effect_2<>0 AND EffectBasePoints_2 IS NOT NULL THEN ROUND(EffectBasePoints_2 * v_k_other) ELSE EffectBasePoints_2 END,
              EffectBasePoints_3 = CASE WHEN Effect_3<>0 AND EffectBasePoints_3 IS NOT NULL THEN ROUND(EffectBasePoints_3 * v_k_other) ELSE EffectBasePoints_3 END;
          INSERT INTO dbc.spell_lplus SELECT * FROM tmp_clone_trigger_g;
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig3,'s1'), CONCAT('$',v_trig3_new,'s1'));
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig3,'s2'), CONCAT('$',v_trig3_new,'s2'));
          SET v_desc_en := REPLACE(v_desc_en, CONCAT('$',v_trig3,'s3'), CONCAT('$',v_trig3_new,'s3'));
          UPDATE tmp_clone_spell_g SET EffectTriggerSpell_3 = v_trig3_new, Description_Lang_enUS = v_desc_en;
        END IF;

        INSERT INTO dbc.spell_lplus SELECT * FROM tmp_clone_spell_g;

        CASE c_slot
          WHEN 1 THEN UPDATE lplusworld.item_template SET spellid_1 = c_new_spell_id WHERE entry=p_entry;
          WHEN 2 THEN UPDATE lplusworld.item_template SET spellid_2 = c_new_spell_id WHERE entry=p_entry;
          WHEN 3 THEN UPDATE lplusworld.item_template SET spellid_3 = c_new_spell_id WHERE entry=p_entry;
          WHEN 4 THEN UPDATE lplusworld.item_template SET spellid_4 = c_new_spell_id WHERE entry=p_entry;
          WHEN 5 THEN UPDATE lplusworld.item_template SET spellid_5 = c_new_spell_id WHERE entry=p_entry;
        END CASE;

      END LOOP;
      CLOSE cur;

      DROP TEMPORARY TABLE IF EXISTS tmp_clone_trigger_g;
      DROP TEMPORARY TABLE IF EXISTS tmp_clone_spell_g;
    END;
  END IF;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,'END','ok',NULL,'done');

  DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  DROP TEMPORARY TABLE IF EXISTS tmp_stat_lines;

END proc
