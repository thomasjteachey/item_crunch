DELIMITER //
drop procedure if exists sp_ScaleItemToIlvl_SimpleGreedy;

CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleItemToIlvl_SimpleGreedy`(
  IN p_entry INT UNSIGNED,
  IN p_target_ilvl INT UNSIGNED,
  IN p_apply TINYINT(1),        -- 0=dry run, 1=apply changes
  IN p_scale_auras TINYINT(1)   -- 0=skip aura scaling, nonzero=scale auras
)
proc: BEGIN
  /* slotmods / curves */
  DROP TEMPORARY TABLE IF EXISTS tmp_slotmods_g;
  CREATE TEMPORARY TABLE tmp_slotmods_g(inv TINYINT PRIMARY KEY, slotmod DOUBLE) ENGINE=Memory;
  INSERT INTO tmp_slotmods_g VALUES
    (1,1.00),(5,1.00),(20,1.00),(7,1.00),
    (3,1.35),(10,1.35),(6,1.35),(8,1.35),
    (12,1.47),
    (9,1.85),(2,1.85),(16,1.85),(11,1.85),
    (17,1.00),
    (13,2.44),(21,2.44),
    (14,1.92),(22,1.92),(23,1.92),
    (15,3.33),(26,3.33),(25,3.33);

  DROP TEMPORARY TABLE IF EXISTS tmp_qcurve_g;
  CREATE TEMPORARY TABLE tmp_qcurve_g(quality TINYINT PRIMARY KEY, a DOUBLE, b DOUBLE) ENGINE=Memory;
  INSERT INTO tmp_qcurve_g VALUES (2,1.21,-9.8),(3,1.42,-4.2),(4,1.64,11.2);

  SET @W_PRIMARY := 230.0;
  SET @W_AP      := 115.0;
  SET @W_AP_VERSUS :=  76.0;
  SET @W_RAP     :=  92.0;
  SET @W_HEAL    := 100.0;
  SET @W_SD_ALL  := 192.0;
  SET @W_SD_ONE  := 159.0;
  SET @W_HIT     := 2200.0;
  SET @W_SPHIT   := 2500.0;
  SET @W_CRIT    := 3200.0;
  SET @W_SPCRIT  := 2600.0;
  SET @W_BLOCKVALUE := 150.0;
  SET @W_BLOCK   := 1300.0;
  SET @W_PARRY   := 3600.0;
  SET @W_DODGE   := 2500.0;
  SET @W_DEFENSE := 345.0;
  SET @W_WEAPON_SKILL_OTHER := 550.0;
  SET @W_WEAPON_SKILL_DAGGER := 720.0;
  SET @W_DAMAGE_SHIELD := 720.0;
  SET @W_MP5     :=  550.0;
  SET @W_HP5     :=  550.0;
  SET @W_RESIST  :=  230.0;
  SET @W_BONUSARMOR :=   22.0;
  SET @WEAPON_DPS_TRADE_SD := 4.0;   -- Item level.docx "Weapons DPS Trade" (spell dmg+healing)

  SET @AURA_AP := 99;    SET @AURA_RAP := 124;
  SET @AURA_AP_VERSUS := 102; SET @AURA_RAP_VERSUS := 131;
  SET @AURA_HIT := 54;   SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57; SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_CRIT_MELEE := 308; SET @AURA_CRIT_RANGED := 290;
  SET @AURA_BLOCKVALUE := 158; SET @AURA_BLOCKVALUE_PCT := 150;
  SET @AURA_BLOCK := 51; SET @AURA_PARRY := 47; SET @AURA_DODGE := 49;
  SET @AURA_DAMAGE_SHIELD := 15;
  SET @AURA_MOD_SKILL := 30; SET @AURA_MOD_SKILL_TALENT := 98;
  SET @AURA_SD := 13;    SET @MASK_SD_ALL := 126;
  SET @AURA_HEAL1 := 115; SET @AURA_HEAL2 := 135;
  SET @AURA_MP5 := 85;   SET @AURA_HP5 := 83;

  SET @SKILL_DEFENSE := 95;
  SET @SKILL_DAGGERS := 173;

  SET @DESC_HIT := 'Improves your chance to hit by $s1%.';
  SET @DESC_SPHIT := 'Improves your chance to hit with spells by $s1%.';
  SET @DESC_CRIT := 'Improves your chance to get a critical strike by $s1%.';
  SET @DESC_SPCRIT := 'Improves your chance to get a critical strike with spells by $s1%.';

  SET @ATTR_PASSIVE := 0x00000040;

  SET @scale_auras := CASE WHEN IFNULL(p_scale_auras, 1) <> 0 THEN 1 ELSE 0 END;

  /* optional weapon DPS trade delta (populated when the weapon scaler runs beforehand) */
  SET @trade_dps_current := 0.0;
  SET @trade_dps_target := 0.0;
  SET @trade_statvalue_current := 0.0;
  SET @trade_statvalue_target := 0.0;
  SET @trade_budget_current := 0.0;
  SET @trade_budget_target := 0.0;
  SET @trade_budget_delta := 0.0;
  IF @weapon_trade_entry IS NOT NULL AND @weapon_trade_entry = p_entry THEN
    SET @trade_dps_current := IFNULL(@weapon_trade_dps_current, 0.0);
    SET @trade_dps_target := IFNULL(@weapon_trade_dps_target, 0.0);
    SET @weapon_trade_entry := NULL;
    SET @weapon_trade_dps_delta := NULL;
    SET @weapon_trade_dps_target := NULL;
    SET @weapon_trade_dps_current := NULL;
  END IF;
  SET @trade_statvalue_current := @trade_dps_current * @WEAPON_DPS_TRADE_SD;
  SET @trade_statvalue_target := @trade_dps_target * @WEAPON_DPS_TRADE_SD;
  IF @trade_statvalue_current <> 0 THEN
    SET @trade_budget_current := POW(GREATEST(0, @trade_statvalue_current * @W_SD_ALL), 1.5);
  END IF;
  IF @trade_statvalue_target <> 0 THEN
    SET @trade_budget_target := POW(GREATEST(0, @trade_statvalue_target * @W_SD_ALL), 1.5);
  END IF;
  SET @trade_budget_delta := @trade_budget_target - @trade_budget_current;

  /* basics */
  SELECT Quality, InventoryType, CAST(IFNULL(trueItemLevel,0) AS SIGNED)
    INTO @q, @inv, @ilvl_cur
  FROM lplusworld.item_template
  WHERE entry = p_entry;

  IF @q NOT IN (2,3,4) THEN LEAVE proc; END IF;

  SELECT a,b INTO @a,@b FROM tmp_qcurve_g WHERE quality=@q;
  SET @slotmod := IFNULL((SELECT slotmod FROM tmp_slotmods_g WHERE inv=@inv),1.00);

  /* ---- SAFE helpers (clamped) ---- */
  SET @ISV_cur  := GREATEST(0.0, @a * @ilvl_cur      + @b);
  SET @ISV_tgt  := GREATEST(0.0, @a * p_target_ilvl  + @b);

  SET @itemvalue_cur := GREATEST(0.0, @ISV_cur / NULLIF(@slotmod,0));
  SET @itemvalue_tgt := GREATEST(0.0, @ISV_tgt / NULLIF(@slotmod,0));

  /* clamp base to avoid overflow, then POW */
  SET @base_cur := GREATEST(0.0, @itemvalue_cur * 100.0);
  SET @base_tgt := GREATEST(0.0, @itemvalue_tgt * 100.0);

  SET @S_cur := POW(@base_cur, 1.5);
  SET @S_tgt := POW(@base_tgt, 1.5);

  /* snapshot 10 slots */
  SELECT stat_type1,stat_value1, stat_type2,stat_value2, stat_type3,stat_value3,
         stat_type4,stat_value4, stat_type5,stat_value5, stat_type6,stat_value6,
         stat_type7,stat_value7, stat_type8,stat_value8, stat_type9,stat_value9,
         stat_type10,stat_value10,
         holy_res, fire_res, nature_res, frost_res, shadow_res, arcane_res,
         ArmorDamageModifier
  INTO  @st1,@sv1, @st2,@sv2, @st3,@sv3,
        @st4,@sv4, @st5,@sv5, @st6,@sv6,
        @st7,@sv7, @st8,@sv8, @st9,@sv9,
        @st10,@sv10,
        @res_holy,@res_fire,@res_nature,@res_frost,@res_shadow,@res_arcane,
        @bonus_armor
  FROM lplusworld.item_template
  WHERE entry = p_entry;

  /* current primaries grouped */
  DROP TEMPORARY TABLE IF EXISTS tmp_pcur;
  CREATE TEMPORARY TABLE tmp_pcur(stat TINYINT PRIMARY KEY, v DOUBLE) ENGINE=Memory;

  INSERT INTO tmp_pcur(stat,v)
  SELECT s, SUM(vv) FROM (
    SELECT @st1 s, @sv1 vv UNION ALL
    SELECT @st2, @sv2 UNION ALL
    SELECT @st3, @sv3 UNION ALL
    SELECT @st4, @sv4 UNION ALL
    SELECT @st5, @sv5 UNION ALL
    SELECT @st6, @sv6 UNION ALL
    SELECT @st7, @sv7 UNION ALL
    SELECT @st8, @sv8 UNION ALL
    SELECT @st9, @sv9 UNION ALL
    SELECT @st10,@sv10
  ) z
  WHERE s IN (3,4,5,6,7) AND vv IS NOT NULL AND vv > 0
  GROUP BY s;

  SET @k := (SELECT COUNT(*) FROM tmp_pcur);
  IF @k = 0 THEN
    INSERT INTO tmp_pcur VALUES (7, 0); -- seed STA
    SET @k := 1;
  END IF;

  /* S_cur_p for primaries only */
  SELECT IFNULL(SUM(POW(GREATEST(0, v * @W_PRIMARY), 1.5)), 0.0)
    INTO @S_cur_p
  FROM tmp_pcur;

  /* resistance budget */
  SET @res_holy := IFNULL(@res_holy, 0);
  SET @res_fire := IFNULL(@res_fire, 0);
  SET @res_nature := IFNULL(@res_nature, 0);
  SET @res_frost := IFNULL(@res_frost, 0);
  SET @res_shadow := IFNULL(@res_shadow, 0);
  SET @res_arcane := IFNULL(@res_arcane, 0);

  SET @S_cur_res :=
        POW(GREATEST(0, @res_holy   * @W_RESIST), 1.5)
      + POW(GREATEST(0, @res_fire   * @W_RESIST), 1.5)
      + POW(GREATEST(0, @res_nature * @W_RESIST), 1.5)
      + POW(GREATEST(0, @res_frost  * @W_RESIST), 1.5)
      + POW(GREATEST(0, @res_shadow * @W_RESIST), 1.5)
      + POW(GREATEST(0, @res_arcane * @W_RESIST), 1.5);

  SET @res_holy_new := @res_holy;
  SET @res_fire_new := @res_fire;
  SET @res_nature_new := @res_nature;
  SET @res_frost_new := @res_frost;
  SET @res_shadow_new := @res_shadow;
  SET @res_arcane_new := @res_arcane;
  SET @resist_scale := 1.0;

  /* bonus armor budget */
  SET @bonus_armor := IFNULL(@bonus_armor, 0.0);
  SET @S_cur_bonus := POW(GREATEST(0, @bonus_armor * @W_BONUSARMOR), 1.5);
  SET @bonus_armor_new := @bonus_armor;

  /* ===== Current aura budget ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_candidates;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_auras_raw;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_totals;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_updates;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_used;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_library;

  SET @S_cur_a := 0.0;
  SET @aura_scale := 1.0;

  IF @scale_auras = 1 THEN
    CREATE TEMPORARY TABLE tmp_item_spells(spellid INT UNSIGNED PRIMARY KEY) ENGINE=Memory;

    INSERT INTO tmp_item_spells(spellid)
    SELECT spellid_1 FROM lplusworld.item_template WHERE entry=p_entry AND spelltrigger_1=1 AND spellid_1<>0
    UNION DISTINCT
    SELECT spellid_2 FROM lplusworld.item_template WHERE entry=p_entry AND spelltrigger_2=1 AND spellid_2<>0
    UNION DISTINCT
    SELECT spellid_3 FROM lplusworld.item_template WHERE entry=p_entry AND spelltrigger_3=1 AND spellid_3<>0
    UNION DISTINCT
    SELECT spellid_4 FROM lplusworld.item_template WHERE entry=p_entry AND spelltrigger_4=1 AND spellid_4<>0
    UNION DISTINCT
    SELECT spellid_5 FROM lplusworld.item_template WHERE entry=p_entry AND spelltrigger_5=1 AND spellid_5<>0;

    CREATE TEMPORARY TABLE tmp_item_aura_candidates(
      spellid INT UNSIGNED NOT NULL,
      effect_index TINYINT NOT NULL,
      effect_aura INT NOT NULL,
      effect_misc INT NOT NULL,
      effect_desc VARCHAR(255) NOT NULL,
      aura_code VARCHAR(16) DEFAULT NULL,
      magnitude INT DEFAULT NULL,
      PRIMARY KEY(spellid, effect_index)
    ) ENGINE=Memory;

    INSERT INTO tmp_item_aura_candidates(spellid,effect_index,effect_aura,effect_misc,effect_desc,aura_code,magnitude)
    SELECT slots.`ID` AS spellid,
           slots.effect_index,
           slots.effect_aura,
           slots.effect_misc,
           slots.effect_desc,
           CASE
             WHEN slots.effect_aura = @AURA_AP THEN 'AP'
             WHEN slots.effect_aura = @AURA_RAP THEN 'RAP'
             WHEN slots.effect_aura IN (@AURA_AP_VERSUS, @AURA_RAP_VERSUS) THEN 'APVERSUS'
             WHEN slots.effect_aura = @AURA_SD AND slots.effect_misc = 0 THEN 'SDALL'
             WHEN slots.effect_aura = @AURA_SD AND (slots.effect_misc & @MASK_SD_ALL)=@MASK_SD_ALL THEN 'SDALL'
             WHEN slots.effect_aura = @AURA_SD AND (slots.effect_misc & @MASK_SD_ALL)<>0 THEN CONCAT('SDONE_', LPAD(slots.effect_misc & @MASK_SD_ALL, 3, '0'))
             WHEN slots.effect_aura IN (@AURA_HEAL1,@AURA_HEAL2) THEN 'HEAL'
             WHEN slots.effect_aura = @AURA_MP5 AND slots.effect_misc = 0 THEN 'MP5'
             WHEN slots.effect_aura = @AURA_HP5 THEN 'HP5'
             WHEN slots.effect_aura = @AURA_HIT AND slots.effect_desc = @DESC_HIT THEN 'HIT'
             WHEN slots.effect_aura = @AURA_SPHIT AND slots.effect_desc = @DESC_SPHIT THEN 'SPHIT'
             WHEN slots.effect_aura IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND slots.effect_desc = @DESC_SPCRIT THEN 'SPCRIT'
             WHEN slots.effect_aura IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND slots.effect_desc = @DESC_CRIT THEN 'CRIT'
             WHEN slots.effect_aura IN (@AURA_BLOCKVALUE, @AURA_BLOCKVALUE_PCT) THEN 'BLOCKVALUE'
             WHEN slots.effect_aura = @AURA_BLOCK THEN 'BLOCK'
             WHEN slots.effect_aura = @AURA_PARRY THEN 'PARRY'
             WHEN slots.effect_aura = @AURA_DODGE THEN 'DODGE'
             WHEN slots.effect_aura = @AURA_DAMAGE_SHIELD THEN 'DMGSHIELD'
             WHEN slots.effect_aura IN (@AURA_MOD_SKILL, @AURA_MOD_SKILL_TALENT) THEN
               CASE
                 WHEN slots.effect_misc = @SKILL_DEFENSE THEN 'DEFENSE'
                 WHEN slots.effect_misc = @SKILL_DAGGERS THEN 'WSKILL_DAGGER'
                 WHEN slots.effect_misc IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475) THEN 'WSKILL'
                 ELSE NULL
               END
             ELSE NULL
           END AS aura_code,
           CASE
             WHEN slots.effect_aura = @AURA_AP THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_RAP THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_AP_VERSUS, @AURA_RAP_VERSUS) THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_SD AND slots.effect_misc = 0 THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_SD AND (slots.effect_misc & @MASK_SD_ALL)<>0 THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_HEAL1,@AURA_HEAL2) THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_MP5 AND slots.effect_misc = 0 THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_HP5 THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_HIT AND slots.effect_desc = @DESC_HIT THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_SPHIT AND slots.effect_desc = @DESC_SPHIT THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND slots.effect_desc = @DESC_SPCRIT THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND slots.effect_desc = @DESC_CRIT THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_BLOCKVALUE, @AURA_BLOCKVALUE_PCT) THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_BLOCK THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_PARRY THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_DODGE THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_DAMAGE_SHIELD THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_MOD_SKILL, @AURA_MOD_SKILL_TALENT) THEN
               CASE
                 WHEN slots.effect_misc IN (@SKILL_DEFENSE, @SKILL_DAGGERS, 43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475)
                   THEN GREATEST(0, slots.base_points + 1)
                 ELSE NULL
               END
             ELSE NULL
           END AS magnitude
    FROM tmp_item_spells tis
    JOIN (
  SELECT `ID`,
         1 AS effect_index,
         IFNULL(EffectAura_1, 0)  AS effect_aura,
         IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) AS effect_misc,
         IFNULL(Description_Lang_enUS, '') AS effect_desc,
         IFNULL(EffectBasePoints_1, 0) AS base_points
  FROM dbc.spell_lplus
  UNION ALL
  SELECT `ID`,
         2 AS effect_index,
         IFNULL(EffectAura_2, 0)  AS effect_aura,
         IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) AS effect_misc,
         IFNULL(Description_Lang_enUS, '') AS effect_desc,
         IFNULL(EffectBasePoints_2, 0) AS base_points
  FROM dbc.spell_lplus
  UNION ALL
  SELECT `ID`,
         3 AS effect_index,
         IFNULL(EffectAura_3, 0)  AS effect_aura,
         IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) AS effect_misc,
         IFNULL(Description_Lang_enUS, '') AS effect_desc,
         IFNULL(EffectBasePoints_3, 0) AS base_points
  FROM dbc.spell_lplus
) AS slots ON slots.`ID` = tis.spellid;

    CREATE TEMPORARY TABLE tmp_item_auras_raw(
      spellid INT UNSIGNED NOT NULL,
      aura_code VARCHAR(16) NOT NULL,
      effect_index TINYINT NOT NULL,
      effect_aura INT NOT NULL,
      effect_misc INT NOT NULL,
      magnitude INT NOT NULL,
      PRIMARY KEY(spellid, effect_index, aura_code)
    ) ENGINE=Memory;

    INSERT INTO tmp_item_auras_raw(spellid,aura_code,effect_index,effect_aura,effect_misc,magnitude)
    SELECT spellid, aura_code, effect_index, effect_aura, effect_misc, magnitude
    FROM tmp_item_aura_candidates
    WHERE aura_code IS NOT NULL
      AND magnitude IS NOT NULL
      AND magnitude > 0;

    CREATE TEMPORARY TABLE tmp_aura_library(
      spellid INT UNSIGNED NOT NULL,
      effect_index TINYINT NOT NULL,
      aura_code VARCHAR(16) NOT NULL,
      effect_misc INT NOT NULL,
      magnitude INT NOT NULL,
      PRIMARY KEY(spellid, effect_index, aura_code, effect_misc)
    ) ENGINE=Memory;

    INSERT INTO tmp_aura_library(spellid,effect_index,aura_code,effect_misc,magnitude)
    SELECT slots.`ID`,
           slots.effect_index,
           slots.aura_code,
           slots.effect_misc,
           slots.magnitude
    FROM (
      SELECT `ID`,
             1 AS effect_index,
             CASE
               WHEN IFNULL(EffectAura_1, 0) = @AURA_AP THEN 'AP'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_RAP THEN 'RAP'
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_AP_VERSUS, @AURA_RAP_VERSUS) THEN 'APVERSUS'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_SD AND IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) = 0 THEN 'SDALL'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_SD AND (IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) & @MASK_SD_ALL)=@MASK_SD_ALL THEN 'SDALL'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_SD AND (IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) & @MASK_SD_ALL)<>0 THEN CONCAT('SDONE_', LPAD(IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) & @MASK_SD_ALL, 3, '0'))
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_HEAL1,@AURA_HEAL2) THEN 'HEAL'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_MP5 AND IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) = 0 THEN 'MP5'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_HP5 THEN 'HP5'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_HIT AND IFNULL(Description_Lang_enUS, '') = @DESC_HIT THEN 'HIT'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_SPHIT AND IFNULL(Description_Lang_enUS, '') = @DESC_SPHIT THEN 'SPHIT'
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND IFNULL(Description_Lang_enUS, '') = @DESC_SPCRIT THEN 'SPCRIT'
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND IFNULL(Description_Lang_enUS, '') = @DESC_CRIT THEN 'CRIT'
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_BLOCKVALUE, @AURA_BLOCKVALUE_PCT) THEN 'BLOCKVALUE'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_BLOCK THEN 'BLOCK'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_PARRY THEN 'PARRY'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_DODGE THEN 'DODGE'
               WHEN IFNULL(EffectAura_1, 0) = @AURA_DAMAGE_SHIELD THEN 'DMGSHIELD'
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_MOD_SKILL, @AURA_MOD_SKILL_TALENT) THEN
                 CASE
                   WHEN IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) = @SKILL_DEFENSE THEN 'DEFENSE'
                   WHEN IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) = @SKILL_DAGGERS THEN 'WSKILL_DAGGER'
                   WHEN IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475) THEN 'WSKILL'
                   ELSE NULL
                 END
               ELSE NULL
             END AS aura_code,
             IFNULL(EffectMiscValue_1, IFNULL(EffectMiscValueB_1, 0)) AS effect_misc,
             CASE
               WHEN IFNULL(EffectAura_1, 0) = @AURA_HIT AND IFNULL(Description_Lang_enUS, '') <> @DESC_HIT THEN 0
               WHEN IFNULL(EffectAura_1, 0) = @AURA_SPHIT AND IFNULL(Description_Lang_enUS, '') <> @DESC_SPHIT THEN 0
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND IFNULL(Description_Lang_enUS, '') <> @DESC_SPCRIT THEN 0
               WHEN IFNULL(EffectAura_1, 0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND IFNULL(Description_Lang_enUS, '') <> @DESC_CRIT THEN 0
               ELSE GREATEST(0, IFNULL(EffectBasePoints_1, 0) + 1)
             END AS magnitude
      FROM dbc.spell_lplus
      WHERE (Attributes & @ATTR_PASSIVE) <> 0
      UNION ALL
      SELECT `ID`,
             2 AS effect_index,
             CASE
               WHEN IFNULL(EffectAura_2, 0) = @AURA_AP THEN 'AP'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_RAP THEN 'RAP'
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_AP_VERSUS, @AURA_RAP_VERSUS) THEN 'APVERSUS'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_SD AND IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) = 0 THEN 'SDALL'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_SD AND (IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) & @MASK_SD_ALL)=@MASK_SD_ALL THEN 'SDALL'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_SD AND (IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) & @MASK_SD_ALL)<>0 THEN CONCAT('SDONE_', LPAD(IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) & @MASK_SD_ALL, 3, '0'))
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_HEAL1,@AURA_HEAL2) THEN 'HEAL'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_MP5 AND IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) = 0 THEN 'MP5'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_HP5 THEN 'HP5'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_HIT AND IFNULL(Description_Lang_enUS, '') = @DESC_HIT THEN 'HIT'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_SPHIT AND IFNULL(Description_Lang_enUS, '') = @DESC_SPHIT THEN 'SPHIT'
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND IFNULL(Description_Lang_enUS, '') = @DESC_SPCRIT THEN 'SPCRIT'
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND IFNULL(Description_Lang_enUS, '') = @DESC_CRIT THEN 'CRIT'
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_BLOCKVALUE, @AURA_BLOCKVALUE_PCT) THEN 'BLOCKVALUE'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_BLOCK THEN 'BLOCK'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_PARRY THEN 'PARRY'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_DODGE THEN 'DODGE'
               WHEN IFNULL(EffectAura_2, 0) = @AURA_DAMAGE_SHIELD THEN 'DMGSHIELD'
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_MOD_SKILL, @AURA_MOD_SKILL_TALENT) THEN
                 CASE
                   WHEN IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) = @SKILL_DEFENSE THEN 'DEFENSE'
                   WHEN IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) = @SKILL_DAGGERS THEN 'WSKILL_DAGGER'
                   WHEN IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475) THEN 'WSKILL'
                   ELSE NULL
                 END
               ELSE NULL
             END AS aura_code,
             IFNULL(EffectMiscValue_2, IFNULL(EffectMiscValueB_2, 0)) AS effect_misc,
             CASE
               WHEN IFNULL(EffectAura_2, 0) = @AURA_HIT AND IFNULL(Description_Lang_enUS, '') <> @DESC_HIT THEN 0
               WHEN IFNULL(EffectAura_2, 0) = @AURA_SPHIT AND IFNULL(Description_Lang_enUS, '') <> @DESC_SPHIT THEN 0
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND IFNULL(Description_Lang_enUS, '') <> @DESC_SPCRIT THEN 0
               WHEN IFNULL(EffectAura_2, 0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND IFNULL(Description_Lang_enUS, '') <> @DESC_CRIT THEN 0
               ELSE GREATEST(0, IFNULL(EffectBasePoints_2, 0) + 1)
             END AS magnitude
      FROM dbc.spell_lplus
      WHERE (Attributes & @ATTR_PASSIVE) <> 0
      UNION ALL
      SELECT `ID`,
             3 AS effect_index,
             CASE
               WHEN IFNULL(EffectAura_3, 0) = @AURA_AP THEN 'AP'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_RAP THEN 'RAP'
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_AP_VERSUS, @AURA_RAP_VERSUS) THEN 'APVERSUS'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_SD AND IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) = 0 THEN 'SDALL'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_SD AND (IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) & @MASK_SD_ALL)=@MASK_SD_ALL THEN 'SDALL'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_SD AND (IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) & @MASK_SD_ALL)<>0 THEN CONCAT('SDONE_', LPAD(IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) & @MASK_SD_ALL, 3, '0'))
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_HEAL1,@AURA_HEAL2) THEN 'HEAL'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_MP5 AND IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) = 0 THEN 'MP5'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_HP5 THEN 'HP5'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_HIT AND IFNULL(Description_Lang_enUS, '') = @DESC_HIT THEN 'HIT'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_SPHIT AND IFNULL(Description_Lang_enUS, '') = @DESC_SPHIT THEN 'SPHIT'
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND IFNULL(Description_Lang_enUS, '') = @DESC_SPCRIT THEN 'SPCRIT'
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND IFNULL(Description_Lang_enUS, '') = @DESC_CRIT THEN 'CRIT'
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_BLOCKVALUE, @AURA_BLOCKVALUE_PCT) THEN 'BLOCKVALUE'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_BLOCK THEN 'BLOCK'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_PARRY THEN 'PARRY'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_DODGE THEN 'DODGE'
               WHEN IFNULL(EffectAura_3, 0) = @AURA_DAMAGE_SHIELD THEN 'DMGSHIELD'
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_MOD_SKILL, @AURA_MOD_SKILL_TALENT) THEN
                 CASE
                   WHEN IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) = @SKILL_DEFENSE THEN 'DEFENSE'
                   WHEN IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) = @SKILL_DAGGERS THEN 'WSKILL_DAGGER'
                   WHEN IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475) THEN 'WSKILL'
                   ELSE NULL
                 END
               ELSE NULL
             END AS aura_code,
             IFNULL(EffectMiscValue_3, IFNULL(EffectMiscValueB_3, 0)) AS effect_misc,
             CASE
               WHEN IFNULL(EffectAura_3, 0) = @AURA_HIT AND IFNULL(Description_Lang_enUS, '') <> @DESC_HIT THEN 0
               WHEN IFNULL(EffectAura_3, 0) = @AURA_SPHIT AND IFNULL(Description_Lang_enUS, '') <> @DESC_SPHIT THEN 0
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_SPCRIT1, @AURA_SPCRIT2) AND IFNULL(Description_Lang_enUS, '') <> @DESC_SPCRIT THEN 0
               WHEN IFNULL(EffectAura_3, 0) IN (@AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED) AND IFNULL(Description_Lang_enUS, '') <> @DESC_CRIT THEN 0
               ELSE GREATEST(0, IFNULL(EffectBasePoints_3, 0) + 1)
             END AS magnitude
      FROM dbc.spell_lplus
      WHERE (Attributes & @ATTR_PASSIVE) <> 0
    ) AS slots
    WHERE slots.aura_code IS NOT NULL
      AND slots.magnitude > 0;

    SET @item_spell_count := (SELECT COUNT(*) FROM tmp_item_spells);
    SET @aura_candidate_rows := (
      SELECT COUNT(*)
      FROM tmp_item_aura_candidates
      WHERE aura_code IS NOT NULL
    );
    SET @aura_row_count := (SELECT COUNT(*) FROM tmp_item_auras_raw);
    SET @zero_mag_rows := (
      SELECT COUNT(*)
      FROM tmp_item_aura_candidates
      WHERE aura_code IS NOT NULL
        AND IFNULL(magnitude, 0) = 0
    );
    SET @unsupported_effects := (
      SELECT COUNT(*)
      FROM tmp_item_aura_candidates
      WHERE aura_code IS NULL
        AND effect_aura IN (
              @AURA_AP, @AURA_RAP,
              @AURA_AP_VERSUS, @AURA_RAP_VERSUS,
              @AURA_SD,
              @AURA_HEAL1, @AURA_HEAL2,
              @AURA_MP5, @AURA_HP5,
              @AURA_HIT, @AURA_SPHIT,
              @AURA_SPCRIT1, @AURA_SPCRIT2,
              @AURA_CRIT_GENERIC, @AURA_CRIT_MELEE, @AURA_CRIT_RANGED,
              @AURA_BLOCK, @AURA_PARRY, @AURA_DODGE,
              @AURA_DAMAGE_SHIELD,
              @AURA_MOD_SKILL, @AURA_MOD_SKILL_TALENT)
    );

    IF @item_spell_count > 0 THEN
      INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
      VALUES (
        p_entry,
        'aura_source_counts',
        'spells',
        @item_spell_count,
        CONCAT('candidates=', @aura_candidate_rows, ',recognized_rows=', @aura_row_count, ',zero_rows=', @zero_mag_rows)
      );

      IF @aura_candidate_rows = 0 THEN
        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        VALUES (
          p_entry,
          'aura_missing_effect',
          'spells',
          @item_spell_count,
          'item spells have no supported AP/RAP/SD/HEAL/MP5/HP5 effects'
        );
      ELSEIF @aura_row_count = 0 THEN
        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        VALUES (
          p_entry,
          'aura_zero_magnitude',
          'spells',
          @item_spell_count,
          'supported effects resolved to zero magnitude'
        );
      END IF;

      IF @unsupported_effects > 0 THEN
        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        VALUES (
          p_entry,
          'aura_unsupported_effect',
          'slots',
          @unsupported_effects,
          'effect aura matched but mask/misc configuration was unsupported'
        );
      END IF;
    END IF;

    CREATE TEMPORARY TABLE tmp_item_aura_totals(
      spellid INT UNSIGNED PRIMARY KEY,
      ap DOUBLE NOT NULL,
      rap DOUBLE NOT NULL,
      ap_versus DOUBLE NOT NULL,
      sd_all DOUBLE NOT NULL,
      sd_one DOUBLE NOT NULL,
      heal DOUBLE NOT NULL,
      mp5 DOUBLE NOT NULL,
      hp5 DOUBLE NOT NULL,
      hit DOUBLE NOT NULL,
      sphit DOUBLE NOT NULL,
      spcrit DOUBLE NOT NULL,
      crit DOUBLE NOT NULL,
      defense DOUBLE NOT NULL,
      weapon_skill DOUBLE NOT NULL,
      weapon_skill_dagger DOUBLE NOT NULL,
      blockvalue DOUBLE NOT NULL,
      damage_shield DOUBLE NOT NULL,
      block DOUBLE NOT NULL,
      parry DOUBLE NOT NULL,
      dodge DOUBLE NOT NULL
    ) ENGINE=Memory;

    INSERT INTO tmp_item_aura_totals(spellid, ap, rap, ap_versus, sd_all, sd_one, heal, mp5, hp5, hit, sphit, spcrit, crit, defense, weapon_skill, weapon_skill_dagger, blockvalue, damage_shield, block, parry, dodge)
    SELECT sums.spellid,
           CASE
             WHEN sums.ap_sum > 0 AND sums.rap_sum > 0 THEN GREATEST(sums.ap_sum, sums.rap_sum)
             ELSE sums.ap_sum
           END AS ap,
           CASE
             WHEN sums.ap_sum > 0 AND sums.rap_sum > 0 THEN 0
             ELSE sums.rap_sum
           END AS rap,
           sums.ap_versus_sum,
           sums.sd_all_sum,
           sums.sd_one_sum,
           CASE
             WHEN sums.sd_all_sum > 0 AND sums.heal_sum > 0 THEN 0
             ELSE sums.heal_sum
           END AS heal,
           sums.mp5_sum,
           sums.hp5_sum,
           sums.hit_sum,
           sums.sphit_sum,
           sums.spcrit_sum,
           sums.crit_sum,
           sums.defense_sum,
           sums.weapon_skill_sum,
           sums.weapon_skill_dagger_sum,
           sums.blockvalue_sum,
           sums.damage_shield_sum,
           sums.block_sum,
           sums.parry_sum,
           sums.dodge_sum
    FROM (
      SELECT spellid,
             SUM(CASE WHEN aura_code='AP' THEN magnitude ELSE 0 END) AS ap_sum,
             SUM(CASE WHEN aura_code='RAP' THEN magnitude ELSE 0 END) AS rap_sum,
             SUM(CASE WHEN aura_code='APVERSUS' THEN magnitude ELSE 0 END) AS ap_versus_sum,
             SUM(CASE WHEN aura_code='SDALL' THEN magnitude ELSE 0 END) AS sd_all_sum,
             SUM(CASE WHEN aura_code LIKE 'SDONE%' THEN magnitude ELSE 0 END) AS sd_one_sum,
             SUM(CASE WHEN aura_code='HEAL' THEN magnitude ELSE 0 END) AS heal_sum,
             SUM(CASE WHEN aura_code='MP5' THEN magnitude ELSE 0 END) AS mp5_sum,
             SUM(CASE WHEN aura_code='HP5' THEN magnitude ELSE 0 END) AS hp5_sum,
             SUM(CASE WHEN aura_code='HIT' THEN magnitude ELSE 0 END) AS hit_sum,
             SUM(CASE WHEN aura_code='SPHIT' THEN magnitude ELSE 0 END) AS sphit_sum,
             SUM(CASE WHEN aura_code='SPCRIT' THEN magnitude ELSE 0 END) AS spcrit_sum,
             SUM(CASE WHEN aura_code='CRIT' THEN magnitude ELSE 0 END) AS crit_sum,
             SUM(CASE WHEN aura_code='DEFENSE' THEN magnitude ELSE 0 END) AS defense_sum,
             SUM(CASE WHEN aura_code='WSKILL' THEN magnitude ELSE 0 END) AS weapon_skill_sum,
             SUM(CASE WHEN aura_code='WSKILL_DAGGER' THEN magnitude ELSE 0 END) AS weapon_skill_dagger_sum,
             SUM(CASE WHEN aura_code='BLOCKVALUE' THEN magnitude ELSE 0 END) AS blockvalue_sum,
             SUM(CASE WHEN aura_code='DMGSHIELD' THEN magnitude ELSE 0 END) AS damage_shield_sum,
             SUM(CASE WHEN aura_code='BLOCK' THEN magnitude ELSE 0 END) AS block_sum,
             SUM(CASE WHEN aura_code='PARRY' THEN magnitude ELSE 0 END) AS parry_sum,
             SUM(CASE WHEN aura_code='DODGE' THEN magnitude ELSE 0 END) AS dodge_sum
      FROM tmp_item_auras_raw
      GROUP BY spellid
    ) AS sums;

    SELECT
      IFNULL(SUM(ap), 0.0),
      IFNULL(SUM(rap), 0.0),
      IFNULL(SUM(ap_versus), 0.0),
      IFNULL(SUM(sd_all), 0.0),
      IFNULL(SUM(sd_one), 0.0),
      IFNULL(SUM(heal), 0.0),
      IFNULL(SUM(mp5), 0.0),
      IFNULL(SUM(hp5), 0.0),
      IFNULL(SUM(hit), 0.0),
      IFNULL(SUM(sphit), 0.0),
      IFNULL(SUM(spcrit), 0.0),
      IFNULL(SUM(crit), 0.0),
      IFNULL(SUM(defense), 0.0),
      IFNULL(SUM(weapon_skill), 0.0),
      IFNULL(SUM(weapon_skill_dagger), 0.0),
      IFNULL(SUM(blockvalue), 0.0),
      IFNULL(SUM(damage_shield), 0.0),
      IFNULL(SUM(block), 0.0),
      IFNULL(SUM(parry), 0.0),
      IFNULL(SUM(dodge), 0.0)
    INTO @aur_ap, @aur_rap, @aur_apversus, @aur_sd_all, @aur_sd_one, @aur_heal, @aur_mp5, @aur_hp5,
         @aur_hit, @aur_sphit, @aur_spcrit, @aur_crit, @aur_defense, @aur_wskill, @aur_wskill_dagger,
         @aur_blockvalue, @aur_dmgshield, @aur_block, @aur_parry, @aur_dodge
    FROM tmp_item_aura_totals;

    SET @S_cur_a :=
        POW(GREATEST(0, @aur_ap     * @W_AP),     1.5)
      + POW(GREATEST(0, @aur_rap    * @W_RAP),    1.5)
      + POW(GREATEST(0, @aur_apversus * @W_AP_VERSUS), 1.5)
      + POW(GREATEST(0, @aur_sd_all * @W_SD_ALL), 1.5)
      + POW(GREATEST(0, @aur_sd_one * @W_SD_ONE), 1.5)
      + POW(GREATEST(0, @aur_heal   * @W_HEAL),   1.5)
      + POW(GREATEST(0, @aur_mp5    * @W_MP5),    1.5)
      + POW(GREATEST(0, @aur_hp5    * @W_HP5),    1.5)
      + POW(GREATEST(0, @aur_hit    * @W_HIT),    1.5)
      + POW(GREATEST(0, @aur_sphit  * @W_SPHIT),  1.5)
      + POW(GREATEST(0, @aur_spcrit * @W_SPCRIT), 1.5)
      + POW(GREATEST(0, @aur_crit   * @W_CRIT),   1.5)
      + POW(GREATEST(0, @aur_defense * @W_DEFENSE), 1.5)
      + POW(GREATEST(0, @aur_wskill * @W_WEAPON_SKILL_OTHER), 1.5)
      + POW(GREATEST(0, @aur_wskill_dagger * @W_WEAPON_SKILL_DAGGER), 1.5)
      + POW(GREATEST(0, @aur_blockvalue * @W_BLOCKVALUE), 1.5)
      + POW(GREATEST(0, @aur_dmgshield * @W_DAMAGE_SHIELD), 1.5)
      + POW(GREATEST(0, @aur_block  * @W_BLOCK),  1.5)
      + POW(GREATEST(0, @aur_parry  * @W_PARRY),  1.5)
      + POW(GREATEST(0, @aur_dodge  * @W_DODGE),  1.5);

    CREATE TEMPORARY TABLE tmp_aura_updates(
      spellid INT UNSIGNED NOT NULL,
      effect_index TINYINT NOT NULL,
      aura_code VARCHAR(16) NOT NULL,
      effect_aura INT NOT NULL,
      effect_misc INT NOT NULL,
      old_magnitude INT NOT NULL,
      desired_magnitude INT NOT NULL,
      new_magnitude INT NOT NULL,
      aura_rank INT NOT NULL,
      processed TINYINT(1) NOT NULL DEFAULT 0,
      new_spellid INT UNSIGNED DEFAULT NULL,
      PRIMARY KEY(spellid, effect_index, aura_code)
    ) ENGINE=Memory;

    CREATE TEMPORARY TABLE tmp_aura_used(
      aura_code VARCHAR(16) NOT NULL,
      magnitude INT NOT NULL,
      PRIMARY KEY(aura_code, magnitude)
    ) ENGINE=Memory;
  END IF;

  SET @S_other := @S_cur - @S_cur_p - @S_cur_a - @S_cur_res - @S_cur_bonus;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry, 'shared_budget_current', 'primaries', @S_cur_p,
          CONCAT('auras=', @S_cur_a, ',resists=', @S_cur_res, ',bonus=', @S_cur_bonus, ',other=', @S_other)),
         (p_entry, 'shared_budget_current', 'auras', @S_cur_a,
          CONCAT('primaries=', @S_cur_p, ',resists=', @S_cur_res, ',bonus=', @S_cur_bonus, ',other=', @S_other)),
         (p_entry, 'shared_budget_current', 'resists', @S_cur_res,
          CONCAT('primaries=', @S_cur_p, ',auras=', @S_cur_a, ',bonus=', @S_cur_bonus, ',other=', @S_other)),
         (p_entry, 'shared_budget_current', 'bonus_armor', @S_cur_bonus,
          CONCAT('primaries=', @S_cur_p, ',auras=', @S_cur_a, ',resists=', @S_cur_res, ',other=', @S_other));
  SET @S_target_shared := GREATEST(0.0, @S_tgt - @S_other + @trade_budget_delta);
  IF (@S_cur_p + @S_cur_a + @S_cur_res + @S_cur_bonus) > 0 THEN
    SET @ratio_shared := @S_target_shared / (@S_cur_p + @S_cur_a + @S_cur_res + @S_cur_bonus);
  ELSE
    SET @ratio_shared := 0.0;
  END IF;
  SET @ratio_shared := GREATEST(0.0, @ratio_shared);

  IF (@S_cur_p + @S_cur_a + @S_cur_res + @S_cur_bonus) > 0 THEN
    SET @shared_scale := CASE
      WHEN @ratio_shared = 0 THEN 0
      ELSE POW(@ratio_shared, 2.0/3.0)
    END;
  ELSE
    SET @shared_scale := 1.0;
  END IF;
  SET @shared_scale := GREATEST(0.0, @shared_scale);

  SET @scale_iteration := 0;
  SET @S_final_res := @S_cur_res;
  SET @S_final_a := @S_cur_a;
  SET @S_final_p := @S_cur_p;
  SET @S_final_bonus := @S_cur_bonus;
  SET @S_after_shared := @S_cur_p + @S_cur_a + @S_cur_res + @S_cur_bonus;
  SET @scale_adjust := 1.0;
  SET @ratio_adjust := 1.0;

  shared_scale_loop: LOOP
    SET @scale_iteration := @scale_iteration + 1;

    IF @S_cur_res > 0 THEN
      SET @res_holy_new := LEAST(255, ROUND(GREATEST(0, @res_holy * @shared_scale)));
      SET @res_fire_new := LEAST(255, ROUND(GREATEST(0, @res_fire * @shared_scale)));
      SET @res_nature_new := LEAST(255, ROUND(GREATEST(0, @res_nature * @shared_scale)));
      SET @res_frost_new := LEAST(255, ROUND(GREATEST(0, @res_frost * @shared_scale)));
      SET @res_shadow_new := LEAST(255, ROUND(GREATEST(0, @res_shadow * @shared_scale)));
      SET @res_arcane_new := LEAST(255, ROUND(GREATEST(0, @res_arcane * @shared_scale)));

      SET @S_final_res :=
            POW(GREATEST(0, @res_holy_new   * @W_RESIST), 1.5)
          + POW(GREATEST(0, @res_fire_new   * @W_RESIST), 1.5)
          + POW(GREATEST(0, @res_nature_new * @W_RESIST), 1.5)
          + POW(GREATEST(0, @res_frost_new  * @W_RESIST), 1.5)
          + POW(GREATEST(0, @res_shadow_new * @W_RESIST), 1.5)
          + POW(GREATEST(0, @res_arcane_new * @W_RESIST), 1.5);
    ELSE
      SET @res_holy_new := @res_holy;
      SET @res_fire_new := @res_fire;
      SET @res_nature_new := @res_nature;
      SET @res_frost_new := @res_frost;
      SET @res_shadow_new := @res_shadow;
      SET @res_arcane_new := @res_arcane;
      SET @S_final_res := 0.0;
    END IF;

    SET @bonus_armor_new := ROUND(GREATEST(0, @bonus_armor * @shared_scale));
    SET @S_final_bonus := POW(GREATEST(0, @bonus_armor_new * @W_BONUSARMOR), 1.5);

    IF @scale_auras = 1 THEN
      DELETE FROM tmp_aura_updates;
      DELETE FROM tmp_aura_used;
      SET @aura_scale := @shared_scale;
      SET @aura_direction := CASE WHEN @aura_scale >= 1 THEN 1 ELSE -1 END;
      SET @prev_aura_code := '';
      SET @prev_aura_mag := 0;
      SET @aura_rank := 0;

      INSERT INTO tmp_aura_updates(spellid,effect_index,aura_code,effect_aura,effect_misc,old_magnitude,desired_magnitude,new_magnitude,aura_rank)
      SELECT z.spellid,
             z.effect_index,
             z.aura_code,
             z.effect_aura,
             z.effect_misc,
             z.magnitude AS old_magnitude,
             z.planned_magnitude,
             z.planned_magnitude,
             z.aura_rank
      FROM (
        SELECT x.spellid,
               x.effect_index,
               x.aura_code,
               x.effect_aura,
               x.effect_misc,
               x.magnitude,
               (@aura_rank := IF(@prev_aura_code = x.aura_code, @aura_rank + 1, 1)) AS aura_rank,
               (@prev_aura_mag := IF(
                 @prev_aura_code = x.aura_code,
                 IF(
                   @aura_direction >= 1,
                   IF(x.desired_mag <= @prev_aura_mag, @prev_aura_mag + 1, x.desired_mag),
                   IF(x.desired_mag >= @prev_aura_mag, GREATEST(0, @prev_aura_mag - 1), x.desired_mag)
                 ),
                 x.desired_mag
               )) AS planned_magnitude,
               (@prev_aura_code := x.aura_code) AS assign_prev_code
        FROM (
           SELECT r.spellid,
                  r.effect_index,
                  r.aura_code,
                  r.effect_aura,
                  r.effect_misc,
                  r.magnitude,
                 CASE
                  WHEN r.aura_code IN ('HIT','SPHIT','SPCRIT','CRIT','BLOCK','PARRY','DODGE','APVERSUS','DEFENSE','WSKILL','WSKILL_DAGGER','DMGSHIELD') THEN r.magnitude
                   ELSE GREATEST(0, ROUND(r.magnitude * @aura_scale))
                 END AS desired_mag
          FROM tmp_item_auras_raw r
        ) AS x
        ORDER BY x.aura_code,
                 CASE WHEN @aura_direction >= 1 THEN x.magnitude ELSE -x.magnitude END,
                 x.effect_index
      ) AS z;

      SET @aur_plan_ap := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='AP'), 0.0);
      SET @aur_plan_rap := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='RAP'), 0.0);
      SET @aur_plan_apversus := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='APVERSUS'), 0.0);
      SET @aur_plan_sd_all := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='SDALL'), 0.0);
      SET @aur_plan_sd_one := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code LIKE 'SDONE%'), 0.0);
      SET @aur_plan_heal_raw := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='HEAL'), 0.0);
      SET @aur_plan_mp5 := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='MP5'), 0.0);
      SET @aur_plan_hp5 := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='HP5'), 0.0);
      SET @aur_plan_hit := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='HIT'), 0.0);
      SET @aur_plan_sphit := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='SPHIT'), 0.0);
      SET @aur_plan_spcrit := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='SPCRIT'), 0.0);
      SET @aur_plan_crit := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='CRIT'), 0.0);
      SET @aur_plan_defense := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='DEFENSE'), 0.0);
      SET @aur_plan_wskill := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='WSKILL'), 0.0);
      SET @aur_plan_wskill_dagger := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='WSKILL_DAGGER'), 0.0);
      SET @aur_plan_blockvalue := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='BLOCKVALUE'), 0.0);
      SET @aur_plan_dmgshield := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='DMGSHIELD'), 0.0);
      SET @aur_plan_block := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='BLOCK'), 0.0);
      SET @aur_plan_parry := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='PARRY'), 0.0);
      SET @aur_plan_dodge := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='DODGE'), 0.0);

      SET @aur_plan_heal := CASE WHEN @aur_plan_sd_all > 0 AND @aur_plan_heal_raw = @aur_plan_sd_all THEN 0 ELSE @aur_plan_heal_raw END;

      SET @S_final_a :=
          POW(GREATEST(0, @aur_plan_ap     * @W_AP),     1.5)
        + POW(GREATEST(0, @aur_plan_rap    * @W_RAP),    1.5)
        + POW(GREATEST(0, @aur_plan_apversus * @W_AP_VERSUS), 1.5)
        + POW(GREATEST(0, @aur_plan_sd_all * @W_SD_ALL), 1.5)
        + POW(GREATEST(0, @aur_plan_sd_one * @W_SD_ONE), 1.5)
        + POW(GREATEST(0, @aur_plan_heal   * @W_HEAL),   1.5)
        + POW(GREATEST(0, @aur_plan_mp5    * @W_MP5),    1.5)
        + POW(GREATEST(0, @aur_plan_hp5    * @W_HP5),    1.5)
        + POW(GREATEST(0, @aur_plan_hit    * @W_HIT),    1.5)
        + POW(GREATEST(0, @aur_plan_sphit  * @W_SPHIT),  1.5)
        + POW(GREATEST(0, @aur_plan_spcrit * @W_SPCRIT), 1.5)
        + POW(GREATEST(0, @aur_plan_crit   * @W_CRIT),   1.5)
        + POW(GREATEST(0, @aur_plan_defense * @W_DEFENSE), 1.5)
        + POW(GREATEST(0, @aur_plan_wskill * @W_WEAPON_SKILL_OTHER), 1.5)
        + POW(GREATEST(0, @aur_plan_wskill_dagger * @W_WEAPON_SKILL_DAGGER), 1.5)
        + POW(GREATEST(0, @aur_plan_blockvalue * @W_BLOCKVALUE), 1.5)
        + POW(GREATEST(0, @aur_plan_dmgshield * @W_DAMAGE_SHIELD), 1.5)
        + POW(GREATEST(0, @aur_plan_block  * @W_BLOCK),  1.5)
        + POW(GREATEST(0, @aur_plan_parry  * @W_PARRY),  1.5)
        + POW(GREATEST(0, @aur_plan_dodge  * @W_DODGE),  1.5);
    ELSE
      SET @S_final_a := 0.0;
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_pnew;
    CREATE TEMPORARY TABLE tmp_pnew(stat TINYINT PRIMARY KEY, newv INT) ENGINE=Memory;
    INSERT INTO tmp_pnew(stat,newv)
    SELECT stat,
           ROUND(GREATEST(0.0, v * @shared_scale))
    FROM tmp_pcur;

    SELECT IFNULL(SUM(POW(GREATEST(0, newv * @W_PRIMARY), 1.5)), 0.0)
      INTO @S_final_p
    FROM tmp_pnew;

    SET @S_after_shared := @S_final_res + @S_final_a + @S_final_p + @S_final_bonus;

    IF @S_after_shared = 0 THEN
      LEAVE shared_scale_loop;
    END IF;

    IF @S_target_shared = 0 THEN
      SET @ratio_adjust := 0.0;
    ELSE
      SET @ratio_adjust := GREATEST(0.0, @S_target_shared / @S_after_shared);
    END IF;

    SET @scale_adjust := CASE
      WHEN @ratio_adjust = 0 THEN 0
      ELSE POW(@ratio_adjust, 2.0/3.0)
    END;

    IF ABS(@scale_adjust - 1.0) <= 0.0001 OR @scale_iteration >= 6 THEN
      LEAVE shared_scale_loop;
    END IF;

    SET @shared_scale := @shared_scale * @scale_adjust;
  END LOOP shared_scale_loop;

  SET @final_scale := GREATEST(0.0, @shared_scale);
  SET @scale_iteration_final := 0;

  final_scale_loop: LOOP
    SET @scale_iteration_final := @scale_iteration_final + 1;

    SET @res_holy_new := LEAST(255, ROUND(GREATEST(0, @res_holy * @final_scale)));
    SET @res_fire_new := LEAST(255, ROUND(GREATEST(0, @res_fire * @final_scale)));
    SET @res_nature_new := LEAST(255, ROUND(GREATEST(0, @res_nature * @final_scale)));
    SET @res_frost_new := LEAST(255, ROUND(GREATEST(0, @res_frost * @final_scale)));
    SET @res_shadow_new := LEAST(255, ROUND(GREATEST(0, @res_shadow * @final_scale)));
    SET @res_arcane_new := LEAST(255, ROUND(GREATEST(0, @res_arcane * @final_scale)));

    SET @S_final_res :=
          POW(GREATEST(0, @res_holy_new   * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_fire_new   * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_nature_new * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_frost_new  * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_shadow_new * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_arcane_new * @W_RESIST), 1.5);

    SET @bonus_armor_new := ROUND(GREATEST(0, @bonus_armor * @final_scale));
    SET @S_final_bonus := POW(GREATEST(0, @bonus_armor_new * @W_BONUSARMOR), 1.5);

    DROP TEMPORARY TABLE IF EXISTS tmp_pnew;
    CREATE TEMPORARY TABLE tmp_pnew(stat TINYINT PRIMARY KEY, newv INT) ENGINE=Memory;
    INSERT INTO tmp_pnew(stat,newv)
    SELECT stat,
           ROUND(GREATEST(0.0, v * @final_scale))
    FROM tmp_pcur;

    SELECT IFNULL(SUM(POW(GREATEST(0, newv * @W_PRIMARY), 1.5)), 0.0)
      INTO @S_final_p
    FROM tmp_pnew;

    IF @scale_auras = 1 THEN
      DELETE FROM tmp_aura_updates;
      DELETE FROM tmp_aura_used;

      SET @aura_scale := @final_scale;
      SET @aura_direction := CASE WHEN @aura_scale >= 1 THEN 1 ELSE -1 END;
      SET @prev_aura_code := '';
      SET @prev_aura_mag := 0;
      SET @aura_rank := 0;

      INSERT INTO tmp_aura_updates(spellid,effect_index,aura_code,effect_aura,effect_misc,old_magnitude,desired_magnitude,new_magnitude,aura_rank)
      SELECT z.spellid,
             z.effect_index,
             z.aura_code,
             z.effect_aura,
             z.effect_misc,
             z.magnitude AS old_magnitude,
             z.planned_magnitude,
             z.planned_magnitude,
             z.aura_rank
      FROM (
        SELECT x.spellid,
               x.effect_index,
               x.aura_code,
               x.effect_aura,
               x.effect_misc,
               x.magnitude,
               (@aura_rank := IF(@prev_aura_code = x.aura_code, @aura_rank + 1, 1)) AS aura_rank,
               (@prev_aura_mag := IF(
                 @prev_aura_code = x.aura_code,
                 IF(
                   @aura_direction >= 1,
                   IF(x.desired_mag <= @prev_aura_mag, @prev_aura_mag + 1, x.desired_mag),
                   IF(x.desired_mag >= @prev_aura_mag, GREATEST(0, @prev_aura_mag - 1), x.desired_mag)
                 ),
                 x.desired_mag
               )) AS planned_magnitude,
               (@prev_aura_code := x.aura_code) AS assign_prev_code
        FROM (
           SELECT r.spellid,
                  r.effect_index,
                  r.aura_code,
                  r.effect_aura,
                  r.effect_misc,
                  r.magnitude,
                 CASE
                  WHEN r.aura_code IN ('HIT','SPHIT','SPCRIT','CRIT','BLOCK','PARRY','DODGE','APVERSUS','DEFENSE','WSKILL','WSKILL_DAGGER','DMGSHIELD') THEN r.magnitude
                   ELSE GREATEST(0, ROUND(r.magnitude * @aura_scale))
                 END AS desired_mag
          FROM tmp_item_auras_raw r
        ) AS x
        ORDER BY x.aura_code,
                 CASE WHEN @aura_direction >= 1 THEN x.magnitude ELSE -x.magnitude END,
                 x.effect_index
      ) AS z;

      SET @pending_aura_rows := (SELECT COUNT(*) FROM tmp_aura_updates);

      WHILE @pending_aura_rows > 0 DO
        SELECT u.spellid,
               u.effect_index,
               u.aura_code,
               u.desired_magnitude,
               u.aura_rank
          INTO @cur_aura_spell,
               @cur_aura_effect,
               @cur_aura_code,
               @cur_desired_mag,
               @cur_aura_rank
        FROM tmp_aura_updates u
        WHERE u.processed = 0
        ORDER BY u.aura_code, u.aura_rank
        LIMIT 1;

        SET @candidate_mag := @cur_desired_mag;
        SET @direction_pref := CASE WHEN @aura_direction >= 1 THEN 1 ELSE -1 END;
        SET @offset_down := 0;
        SET @offset_up := 1;
        SET @attempts := 0;

        adjust_loop_final: WHILE 1 DO
          IF NOT EXISTS (
               SELECT 1 FROM tmp_aura_used tu
                WHERE tu.aura_code = @cur_aura_code
                  AND tu.magnitude = @candidate_mag
             )
             AND NOT EXISTS (
               SELECT 1 FROM tmp_aura_updates u2
                WHERE u2.aura_code = @cur_aura_code
                  AND u2.new_magnitude = @candidate_mag
                  AND u2.processed = 1
             ) THEN
            LEAVE adjust_loop_final;
          END IF;

          IF @direction_pref >= 1 THEN
            SET @candidate_mag := @cur_desired_mag + @offset_up;
            SET @offset_up := @offset_up + 1;
          ELSE
            IF @offset_down < @cur_desired_mag THEN
              SET @offset_down := @offset_down + 1;
              SET @candidate_mag := @cur_desired_mag - @offset_down;
            ELSE
              SET @candidate_mag := @cur_desired_mag + @offset_up;
              SET @offset_up := @offset_up + 1;
            END IF;
          END IF;

          SET @attempts := @attempts + 1;
          IF @attempts > 10000 THEN
            LEAVE adjust_loop_final;
          END IF;
        END WHILE adjust_loop_final;

        UPDATE tmp_aura_updates
        SET new_magnitude = @candidate_mag,
            processed = 1
        WHERE spellid = @cur_aura_spell
          AND effect_index = @cur_aura_effect
          AND aura_code = @cur_aura_code;

        INSERT IGNORE INTO tmp_aura_used(aura_code, magnitude)
        VALUES (@cur_aura_code, @candidate_mag);

        SET @pending_aura_rows := @pending_aura_rows - 1;
      END WHILE;

      SELECT
        IFNULL(SUM(final_ap), 0.0),
        IFNULL(SUM(final_rap), 0.0),
        IFNULL(SUM(final_sd_all), 0.0),
        IFNULL(SUM(final_sd_one), 0.0),
        IFNULL(SUM(final_ap_versus), 0.0),
        IFNULL(SUM(final_heal), 0.0),
        IFNULL(SUM(final_mp5), 0.0),
        IFNULL(SUM(final_hp5), 0.0),
        IFNULL(SUM(final_hit), 0.0),
        IFNULL(SUM(final_sphit), 0.0),
        IFNULL(SUM(final_spcrit), 0.0),
        IFNULL(SUM(final_crit), 0.0),
        IFNULL(SUM(final_defense), 0.0),
        IFNULL(SUM(final_weapon_skill), 0.0),
        IFNULL(SUM(final_weapon_skill_dagger), 0.0),
        IFNULL(SUM(final_blockvalue), 0.0),
        IFNULL(SUM(final_damage_shield), 0.0),
        IFNULL(SUM(final_block), 0.0),
        IFNULL(SUM(final_parry), 0.0),
        IFNULL(SUM(final_dodge), 0.0)
      INTO @aur_new_ap, @aur_new_rap, @aur_new_sd_all, @aur_new_sd_one, @aur_new_apversus, @aur_new_heal, @aur_new_mp5, @aur_new_hp5,
           @aur_new_hit, @aur_new_sphit, @aur_new_spcrit, @aur_new_crit, @aur_new_defense, @aur_new_wskill, @aur_new_wskill_dagger,
           @aur_new_blockvalue, @aur_new_dmgshield, @aur_new_block, @aur_new_parry, @aur_new_dodge
      FROM (
        SELECT sums.spellid,
               CASE
                 WHEN sums.ap_sum > 0 AND sums.rap_sum > 0 THEN GREATEST(sums.ap_sum, sums.rap_sum)
                 ELSE sums.ap_sum
               END AS final_ap,
               CASE
                 WHEN sums.ap_sum > 0 AND sums.rap_sum > 0 THEN 0
                 ELSE sums.rap_sum
               END AS final_rap,
               sums.sd_all_sum AS final_sd_all,
               sums.sd_one_sum AS final_sd_one,
               sums.ap_versus_sum AS final_ap_versus,
               CASE
                 WHEN sums.sd_all_sum > 0 AND sums.heal_sum > 0 THEN 0
                 ELSE sums.heal_sum
               END AS final_heal,
               sums.mp5_sum AS final_mp5,
               sums.hp5_sum AS final_hp5,
               sums.hit_sum AS final_hit,
               sums.sphit_sum AS final_sphit,
               sums.spcrit_sum AS final_spcrit,
               sums.crit_sum AS final_crit,
               sums.defense_sum AS final_defense,
               sums.weapon_skill_sum AS final_weapon_skill,
               sums.weapon_skill_dagger_sum AS final_weapon_skill_dagger,
               sums.blockvalue_sum AS final_blockvalue,
               sums.damage_shield_sum AS final_damage_shield,
               sums.block_sum AS final_block,
               sums.parry_sum AS final_parry,
               sums.dodge_sum AS final_dodge
        FROM (
          SELECT spellid,
                 SUM(CASE WHEN aura_code='AP' THEN new_magnitude ELSE 0 END) AS ap_sum,
                 SUM(CASE WHEN aura_code='RAP' THEN new_magnitude ELSE 0 END) AS rap_sum,
                 SUM(CASE WHEN aura_code='APVERSUS' THEN new_magnitude ELSE 0 END) AS ap_versus_sum,
                 SUM(CASE WHEN aura_code='SDALL' THEN new_magnitude ELSE 0 END) AS sd_all_sum,
                 SUM(CASE WHEN aura_code LIKE 'SDONE%' THEN new_magnitude ELSE 0 END) AS sd_one_sum,
                 SUM(CASE WHEN aura_code='HEAL' THEN new_magnitude ELSE 0 END) AS heal_sum,
                 SUM(CASE WHEN aura_code='MP5' THEN new_magnitude ELSE 0 END) AS mp5_sum,
                 SUM(CASE WHEN aura_code='HP5' THEN new_magnitude ELSE 0 END) AS hp5_sum,
                 SUM(CASE WHEN aura_code='HIT' THEN new_magnitude ELSE 0 END) AS hit_sum,
                 SUM(CASE WHEN aura_code='SPHIT' THEN new_magnitude ELSE 0 END) AS sphit_sum,
                 SUM(CASE WHEN aura_code='SPCRIT' THEN new_magnitude ELSE 0 END) AS spcrit_sum,
                 SUM(CASE WHEN aura_code='CRIT' THEN new_magnitude ELSE 0 END) AS crit_sum,
                 SUM(CASE WHEN aura_code='DEFENSE' THEN new_magnitude ELSE 0 END) AS defense_sum,
                 SUM(CASE WHEN aura_code='WSKILL' THEN new_magnitude ELSE 0 END) AS weapon_skill_sum,
                 SUM(CASE WHEN aura_code='WSKILL_DAGGER' THEN new_magnitude ELSE 0 END) AS weapon_skill_dagger_sum,
                 SUM(CASE WHEN aura_code='BLOCKVALUE' THEN new_magnitude ELSE 0 END) AS blockvalue_sum,
                 SUM(CASE WHEN aura_code='DMGSHIELD' THEN new_magnitude ELSE 0 END) AS damage_shield_sum,
                 SUM(CASE WHEN aura_code='BLOCK' THEN new_magnitude ELSE 0 END) AS block_sum,
                 SUM(CASE WHEN aura_code='PARRY' THEN new_magnitude ELSE 0 END) AS parry_sum,
                 SUM(CASE WHEN aura_code='DODGE' THEN new_magnitude ELSE 0 END) AS dodge_sum
          FROM tmp_aura_updates
          GROUP BY spellid
        ) AS sums
      ) AS final;

      SET @S_final_a :=
          POW(GREATEST(0, @aur_new_ap     * @W_AP),     1.5)
        + POW(GREATEST(0, @aur_new_rap    * @W_RAP),    1.5)
        + POW(GREATEST(0, @aur_new_apversus * @W_AP_VERSUS), 1.5)
        + POW(GREATEST(0, @aur_new_sd_all * @W_SD_ALL), 1.5)
        + POW(GREATEST(0, @aur_new_sd_one * @W_SD_ONE), 1.5)
        + POW(GREATEST(0, @aur_new_heal   * @W_HEAL),   1.5)
        + POW(GREATEST(0, @aur_new_mp5    * @W_MP5),    1.5)
        + POW(GREATEST(0, @aur_new_hp5    * @W_HP5),    1.5)
        + POW(GREATEST(0, @aur_new_hit    * @W_HIT),    1.5)
        + POW(GREATEST(0, @aur_new_sphit  * @W_SPHIT),  1.5)
        + POW(GREATEST(0, @aur_new_spcrit * @W_SPCRIT), 1.5)
        + POW(GREATEST(0, @aur_new_crit   * @W_CRIT),   1.5)
        + POW(GREATEST(0, @aur_new_defense * @W_DEFENSE), 1.5)
        + POW(GREATEST(0, @aur_new_wskill * @W_WEAPON_SKILL_OTHER), 1.5)
        + POW(GREATEST(0, @aur_new_wskill_dagger * @W_WEAPON_SKILL_DAGGER), 1.5)
        + POW(GREATEST(0, @aur_new_blockvalue * @W_BLOCKVALUE), 1.5)
        + POW(GREATEST(0, @aur_new_dmgshield * @W_DAMAGE_SHIELD), 1.5)
        + POW(GREATEST(0, @aur_new_block  * @W_BLOCK),  1.5)
        + POW(GREATEST(0, @aur_new_parry  * @W_PARRY),  1.5)
        + POW(GREATEST(0, @aur_new_dodge  * @W_DODGE),  1.5);
    ELSE
      SET @S_final_a := 0.0;
      SET @aur_new_ap := 0.0;
      SET @aur_new_rap := 0.0;
      SET @aur_new_sd_all := 0.0;
      SET @aur_new_sd_one := 0.0;
      SET @aur_new_apversus := 0.0;
      SET @aur_new_heal := 0.0;
      SET @aur_new_mp5 := 0.0;
      SET @aur_new_hp5 := 0.0;
      SET @aur_new_hit := 0.0;
      SET @aur_new_sphit := 0.0;
      SET @aur_new_spcrit := 0.0;
      SET @aur_new_crit := 0.0;
      SET @aur_new_defense := 0.0;
      SET @aur_new_wskill := 0.0;
      SET @aur_new_wskill_dagger := 0.0;
      SET @aur_new_blockvalue := 0.0;
      SET @aur_new_dmgshield := 0.0;
      SET @aur_new_block := 0.0;
      SET @aur_new_parry := 0.0;
      SET @aur_new_dodge := 0.0;
    END IF;

    SET @S_final_shared := @S_final_res + @S_final_a + @S_final_p + @S_final_bonus;

    SET @ratio_adjust := 1.0;
    SET @scale_adjust := 1.0;

    IF @S_final_shared = 0 THEN
      LEAVE final_scale_loop;
    END IF;

    SET @ratio_adjust := GREATEST(0.0, @S_target_shared / @S_final_shared);

    SET @scale_adjust := CASE
      WHEN @ratio_adjust = 0 THEN 0
      ELSE POW(@ratio_adjust, 2.0/3.0)
    END;

    IF ABS(@scale_adjust - 1.0) <= 0.0001 OR @scale_iteration_final >= 6 THEN
      LEAVE final_scale_loop;
    END IF;

    SET @final_scale := GREATEST(0.0, @final_scale * @scale_adjust);
  END LOOP final_scale_loop;

  SET @resist_scale := @final_scale;
  SET @aura_scale := CASE WHEN @scale_auras = 1 THEN @final_scale ELSE 1.0 END;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,
          'shared_scale_plan',
          'base_scale',
          @shared_scale,
          CONCAT('ratio=', @ratio_shared, ',iterations=', @scale_iteration, ',target_S=', @S_target_shared, ',post_loop_S=', @S_after_shared));

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry,
          'shared_scale_final',
          'final_scale',
          @final_scale,
          CONCAT('iterations=', @scale_iteration_final, ',ratio_adjust=', @ratio_adjust, ',final_S=', @S_final_shared, ',target_S=', @S_target_shared));

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry, 'resist_update_plan', 'holy',   @res_holy_new,   CONCAT('old=', @res_holy)),
         (p_entry, 'resist_update_plan', 'fire',   @res_fire_new,   CONCAT('old=', @res_fire)),
         (p_entry, 'resist_update_plan', 'nature', @res_nature_new, CONCAT('old=', @res_nature)),
         (p_entry, 'resist_update_plan', 'frost',  @res_frost_new,  CONCAT('old=', @res_frost)),
         (p_entry, 'resist_update_plan', 'shadow', @res_shadow_new, CONCAT('old=', @res_shadow)),
         (p_entry, 'resist_update_plan', 'arcane', @res_arcane_new, CONCAT('old=', @res_arcane)),
         (p_entry, 'bonus_armor_update_plan', 'bonus_armor', @bonus_armor_new, CONCAT('old=', @bonus_armor));

  IF @scale_auras = 1 THEN
    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    SELECT p_entry,
           'aura_update_adjust',
           CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
           u.new_magnitude,
           CONCAT('desired=', u.desired_magnitude, ',spell=', u.spellid)
    FROM tmp_aura_updates u
    WHERE u.new_magnitude <> u.desired_magnitude;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    SELECT p_entry,
           'aura_update_plan_final',
           CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
           u.new_magnitude,
           CONCAT('spell=', u.spellid, ',effect=', u.effect_index, ',old=', u.old_magnitude)
    FROM tmp_aura_updates u;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    SELECT p_entry,
           'aura_update_dup_rank_final',
           d.aura_code,
           d.new_magnitude,
           CONCAT('rows=', d.cnt)
    FROM (
      SELECT aura_code, new_magnitude, COUNT(*) AS cnt
      FROM tmp_aura_updates
      GROUP BY aura_code, new_magnitude
      HAVING COUNT(*) > 1
    ) AS d;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,
            'aura_scale_plan',
            'base_scale',
            @aura_scale,
            CONCAT('plan_S=', @S_final_a, ',target_shared=', @S_target_shared));

    DROP TEMPORARY TABLE IF EXISTS tmp_aura_used;
    DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_candidates;
  END IF;

  /* stage slots, single JOIN (avoids “reopen table” issues) */
  DROP TEMPORARY TABLE IF EXISTS tmp_slots_cur;
  CREATE TEMPORARY TABLE tmp_slots_cur(slot_no TINYINT PRIMARY KEY, stat_type TINYINT, stat_value INT) ENGINE=Memory;
  INSERT INTO tmp_slots_cur VALUES
    (1,@st1,@sv1),(2,@st2,@sv2),(3,@st3,@sv3),(4,@st4,@sv4),(5,@st5,@sv5),
    (6,@st6,@sv6),(7,@st7,@sv7),(8,@st8,@sv8),(9,@st9,@sv9),(10,@st10,@sv10);

  UPDATE tmp_slots_cur s
  LEFT JOIN tmp_pnew n ON n.stat = s.stat_type
  SET s.stat_value = IFNULL(n.newv, s.stat_value);

  DROP TEMPORARY TABLE IF EXISTS tmp_pivot_vals;
  CREATE TEMPORARY TABLE tmp_pivot_vals
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
  FROM tmp_slots_cur;

  IF p_apply = 1 THEN
    UPDATE lplusworld.item_template t
    JOIN tmp_pivot_vals p ON 1=1
    SET t.stat_value1  = p.sv1,
        t.stat_value2  = p.sv2,
        t.stat_value3  = p.sv3,
        t.stat_value4  = p.sv4,
        t.stat_value5  = p.sv5,
        t.stat_value6  = p.sv6,
        t.stat_value7  = p.sv7,
        t.stat_value8  = p.sv8,
        t.stat_value9  = p.sv9,
        t.stat_value10 = p.sv10,
        t.holy_res     = @res_holy_new,
        t.fire_res     = @res_fire_new,
        t.nature_res   = @res_nature_new,
        t.frost_res    = @res_frost_new,
        t.shadow_res   = @res_shadow_new,
        t.arcane_res   = @res_arcane_new,
        t.armorDamageModifier = @bonus_armor_new
    WHERE t.entry = p_entry;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry, 'resist_final', 'holy',   @res_holy_new,   CONCAT('old=', @res_holy)),
           (p_entry, 'resist_final', 'fire',   @res_fire_new,   CONCAT('old=', @res_fire)),
           (p_entry, 'resist_final', 'nature', @res_nature_new, CONCAT('old=', @res_nature)),
           (p_entry, 'resist_final', 'frost',  @res_frost_new,  CONCAT('old=', @res_frost)),
           (p_entry, 'resist_final', 'shadow', @res_shadow_new, CONCAT('old=', @res_shadow)),
           (p_entry, 'resist_final', 'arcane', @res_arcane_new, CONCAT('old=', @res_arcane)),
           (p_entry, 'bonus_armor_final', 'bonus_armor', @bonus_armor_new, CONCAT('old=', @bonus_armor));

    IF @scale_auras = 1 THEN
        SET @pending_aura_rows := (SELECT COUNT(*) FROM tmp_aura_updates);
        IF @pending_aura_rows > 0 THEN
          INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
          SELECT p_entry,
                 'aura_apply_plan',
                 CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
                 u.new_magnitude,
                 CONCAT('spell=', u.spellid)
          FROM tmp_aura_updates u;

          DROP TEMPORARY TABLE IF EXISTS tmp_aura_spell_swaps;
          CREATE TEMPORARY TABLE tmp_aura_spell_swaps(
            old_spellid INT UNSIGNED PRIMARY KEY,
            new_spellid INT UNSIGNED NOT NULL
          ) ENGINE=Memory;

          SET @pending_aura_changes := (SELECT COUNT(*) FROM tmp_aura_updates WHERE new_magnitude <> old_magnitude);

          IF @pending_aura_changes > 0 THEN
            DROP TEMPORARY TABLE IF EXISTS tmp_aura_existing_match;
            CREATE TEMPORARY TABLE tmp_aura_existing_match(
              spellid INT UNSIGNED PRIMARY KEY,
              reuse_spellid INT UNSIGNED NOT NULL
            ) ENGINE=Memory;

            DROP TEMPORARY TABLE IF EXISTS tmp_aura_match_counts;
            CREATE TEMPORARY TABLE tmp_aura_match_counts(
              orig_spellid INT UNSIGNED NOT NULL,
              candidate_spellid INT UNSIGNED NOT NULL,
              match_count INT NOT NULL,
              PRIMARY KEY(orig_spellid, candidate_spellid)
            ) ENGINE=Memory;

            INSERT INTO tmp_aura_match_counts(orig_spellid,candidate_spellid,match_count)
            SELECT u.spellid,
                   c.spellid,
                   COUNT(*) AS match_count
            FROM tmp_aura_updates u
            JOIN tmp_aura_library c
              ON c.aura_code = u.aura_code
             AND c.magnitude = u.new_magnitude
             AND c.effect_misc = u.effect_misc
            GROUP BY u.spellid, c.spellid;

            DROP TEMPORARY TABLE IF EXISTS tmp_aura_desired_counts;
            CREATE TEMPORARY TABLE tmp_aura_desired_counts(
              spellid INT UNSIGNED PRIMARY KEY,
              desired_count INT NOT NULL
            ) ENGINE=Memory;

            INSERT INTO tmp_aura_desired_counts(spellid,desired_count)
            SELECT spellid, COUNT(*) AS desired_count
            FROM tmp_aura_updates
            GROUP BY spellid;

            DROP TEMPORARY TABLE IF EXISTS tmp_aura_changed_spells;
            CREATE TEMPORARY TABLE tmp_aura_changed_spells(
              spellid INT UNSIGNED PRIMARY KEY
            ) ENGINE=Memory;

            INSERT INTO tmp_aura_changed_spells(spellid)
            SELECT DISTINCT spellid
            FROM tmp_aura_updates
            WHERE new_magnitude <> old_magnitude;

            DROP TEMPORARY TABLE IF EXISTS tmp_aura_library_counts;
            CREATE TEMPORARY TABLE tmp_aura_library_counts(
              spellid INT UNSIGNED PRIMARY KEY,
              library_count INT NOT NULL
            ) ENGINE=Memory;

            INSERT INTO tmp_aura_library_counts(spellid,library_count)
            SELECT spellid, COUNT(*) AS library_count
            FROM tmp_aura_library
            GROUP BY spellid;

            INSERT INTO tmp_aura_existing_match(spellid,reuse_spellid)
            SELECT matches.orig_spellid,
                   MIN(matches.candidate_spellid) AS reuse_spellid
            FROM tmp_aura_match_counts matches
            JOIN tmp_aura_desired_counts desired
              ON desired.spellid = matches.orig_spellid
            JOIN tmp_aura_library_counts lib
              ON lib.spellid = matches.candidate_spellid
            JOIN tmp_aura_changed_spells changed
              ON changed.spellid = matches.orig_spellid
            WHERE matches.match_count = desired.desired_count
              AND lib.library_count = desired.desired_count
            GROUP BY matches.orig_spellid;

            DROP TEMPORARY TABLE IF EXISTS tmp_aura_match_counts;
            DROP TEMPORARY TABLE IF EXISTS tmp_aura_desired_counts;
            DROP TEMPORARY TABLE IF EXISTS tmp_aura_library_counts;
            DROP TEMPORARY TABLE IF EXISTS tmp_aura_changed_spells;

            SET @reuse_rows := (SELECT COUNT(*) FROM tmp_aura_existing_match);
            IF @reuse_rows > 0 THEN
              UPDATE tmp_aura_updates u
              JOIN tmp_aura_existing_match m ON m.spellid = u.spellid
              SET u.new_spellid = m.reuse_spellid
              WHERE u.new_magnitude <> u.old_magnitude;

              INSERT IGNORE INTO tmp_aura_spell_swaps(old_spellid, new_spellid)
              SELECT m.spellid, m.reuse_spellid
              FROM tmp_aura_existing_match m;

              INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
              SELECT p_entry,
                     'aura_spell_reuse',
                     CAST(m.spellid AS CHAR),
                     m.reuse_spellid,
                     GROUP_CONCAT(CONCAT(u.aura_code, '=', u.new_magnitude)
                                  ORDER BY u.aura_code, u.effect_index SEPARATOR ';')
              FROM tmp_aura_existing_match m
              JOIN tmp_aura_updates u ON u.spellid = m.spellid
              GROUP BY m.spellid, m.reuse_spellid;
            END IF;

            SET @pending_aura_clone_changes := (
              SELECT COUNT(DISTINCT spellid)
              FROM tmp_aura_updates
              WHERE new_magnitude <> old_magnitude
                AND new_spellid IS NULL
            );

            IF @pending_aura_clone_changes > 0 THEN
              DROP TEMPORARY TABLE IF EXISTS tmp_aura_spell_clones;
              CREATE TEMPORARY TABLE tmp_aura_spell_clones(
                old_spellid INT UNSIGNED PRIMARY KEY,
                new_spellid INT UNSIGNED NOT NULL
              ) ENGINE=Memory;

              SET @next_spell_id := (SELECT IFNULL(MAX(ID), 0) FROM dbc.spell_lplus);

              INSERT INTO tmp_aura_spell_clones(old_spellid,new_spellid)
              SELECT d.spellid,
                     (@next_spell_id := @next_spell_id + 1)
              FROM (
                SELECT DISTINCT u.spellid
                FROM tmp_aura_updates u
                WHERE u.new_magnitude <> u.old_magnitude
                  AND u.new_spellid IS NULL
              ) AS d
              ORDER BY d.spellid;

              UPDATE tmp_aura_updates u
              JOIN tmp_aura_spell_clones sc ON sc.old_spellid = u.spellid
              SET u.new_spellid = sc.new_spellid
              WHERE u.new_spellid IS NULL;

              DROP TEMPORARY TABLE IF EXISTS tmp_spell_clone_rows;
              CREATE TEMPORARY TABLE tmp_spell_clone_rows LIKE dbc.spell_lplus;

              INSERT INTO tmp_spell_clone_rows
              SELECT s.*
              FROM dbc.spell_lplus s
              JOIN tmp_aura_spell_clones sc ON sc.old_spellid = s.`ID`;

              UPDATE tmp_spell_clone_rows t
              LEFT JOIN (
                SELECT u.spellid,
                       MAX(CASE WHEN u.effect_index=1 THEN u.new_magnitude - 1 END) AS bp1,
                       MAX(CASE WHEN u.effect_index=2 THEN u.new_magnitude - 1 END) AS bp2,
                       MAX(CASE WHEN u.effect_index=3 THEN u.new_magnitude - 1 END) AS bp3
                FROM tmp_aura_updates u
                JOIN tmp_aura_spell_clones sc ON sc.old_spellid = u.spellid
                GROUP BY u.spellid
              ) upd ON upd.spellid = t.`ID`
              SET t.EffectBasePoints_1 = CASE WHEN upd.bp1 IS NOT NULL THEN upd.bp1 ELSE t.EffectBasePoints_1 END,
                  t.EffectBasePoints_2 = CASE WHEN upd.bp2 IS NOT NULL THEN upd.bp2 ELSE t.EffectBasePoints_2 END,
                  t.EffectBasePoints_3 = CASE WHEN upd.bp3 IS NOT NULL THEN upd.bp3 ELSE t.EffectBasePoints_3 END;

              UPDATE tmp_spell_clone_rows t
              JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.`ID`
              SET t.ID = sc.new_spellid;

              INSERT INTO dbc.spell_lplus
              SELECT * FROM tmp_spell_clone_rows;

              INSERT IGNORE INTO tmp_aura_spell_swaps(old_spellid, new_spellid)
              SELECT sc.old_spellid, sc.new_spellid
              FROM tmp_aura_spell_clones sc;

              INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
              SELECT p_entry,
                     'aura_spell_clone',
                     CAST(sc.old_spellid AS CHAR),
                     sc.new_spellid,
                     GROUP_CONCAT(CONCAT('e', u.effect_index, '=', u.new_magnitude)
                                  ORDER BY u.effect_index SEPARATOR ';')
              FROM tmp_aura_spell_clones sc
              LEFT JOIN tmp_aura_updates u ON u.spellid = sc.old_spellid
              GROUP BY sc.old_spellid, sc.new_spellid;

              DROP TEMPORARY TABLE IF EXISTS tmp_spell_clone_rows;
              DROP TEMPORARY TABLE IF EXISTS tmp_aura_spell_clones;
            END IF;

            DROP TEMPORARY TABLE IF EXISTS tmp_aura_existing_match;
          END IF;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_swaps sw ON sw.old_spellid = t.spellid_1
          SET t.spellid_1 = sw.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_swaps sw ON sw.old_spellid = t.spellid_2
          SET t.spellid_2 = sw.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_swaps sw ON sw.old_spellid = t.spellid_3
          SET t.spellid_3 = sw.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_swaps sw ON sw.old_spellid = t.spellid_4
          SET t.spellid_4 = sw.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_swaps sw ON sw.old_spellid = t.spellid_5
          SET t.spellid_5 = sw.new_spellid
          WHERE t.entry = p_entry;

          INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
          SELECT p_entry,
                 'aura_spell_swap',
                 CONCAT('slot', slots.slot_no),
                 sw.new_spellid,
                 CONCAT('old_spell=', sw.old_spellid)
          FROM (
            SELECT 1 AS slot_no, spellid_1 AS spellid, spelltrigger_1 AS trig FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 2, spellid_2, spelltrigger_2 FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 3, spellid_3, spelltrigger_3 FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 4, spellid_4, spelltrigger_4 FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 5, spellid_5, spelltrigger_5 FROM lplusworld.item_template WHERE entry = p_entry
          ) AS slots
          JOIN tmp_aura_spell_swaps sw ON sw.new_spellid = slots.spellid
          WHERE slots.trig = 1;

          DROP TEMPORARY TABLE IF EXISTS tmp_aura_spell_swaps;

          INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
          SELECT p_entry,
                 'aura_applied',
                 CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
                 u.new_magnitude,
                 CONCAT('spell=', IFNULL(u.new_spellid, u.spellid),
                        ',effect=', u.effect_index,
                        ',old_mag=', u.old_magnitude)
          FROM tmp_aura_updates u;
        END IF;
    END IF;

    CALL helper.sp_EstimateItemLevels();
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_aura_library;

/*
  SELECT p_entry AS entry,
          @ilvl_cur AS ilvl_before,
          p_target_ilvl AS target_ilvl,
          (SELECT CAST(trueItemLevel AS SIGNED) FROM lplusworld.item_template WHERE entry=p_entry) AS ilvl_after;
		  */
END proc