DELIMITER $$

DROP PROCEDURE IF EXISTS `helper`.`sp_ScaleItemToIlvl_SimpleGreedy`$$

CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `helper`.`sp_ScaleItemToIlvl_SimpleGreedy`(
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
  SET @W_RAP     :=  92.0;
  SET @W_HEAL    := 100.0;
  SET @W_SD_ALL  := 192.0;
  SET @W_SD_ONE  := 159.0;
  SET @W_MP5     :=  550.0;
  SET @W_HP5     :=  550.0;
  SET @W_RESIST  :=  230.0;

  SET @AURA_AP := 99;    SET @AURA_RAP := 124;
  SET @AURA_SD := 13;    SET @MASK_SD_ALL := 126;
  SET @AURA_HEAL1 := 115; SET @AURA_HEAL2 := 135;
  SET @AURA_MP5 := 85;   SET @AURA_HP5 := 83;

  SET @scale_auras := CASE WHEN IFNULL(p_scale_auras, 1) <> 0 THEN 1 ELSE 0 END;

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
         holy_res, fire_res, nature_res, frost_res, shadow_res, arcane_res
  INTO  @st1,@sv1, @st2,@sv2, @st3,@sv3,
        @st4,@sv4, @st5,@sv5, @st6,@sv6,
        @st7,@sv7, @st8,@sv8, @st9,@sv9,
        @st10,@sv10,
        @res_holy,@res_fire,@res_nature,@res_frost,@res_shadow,@res_arcane
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

  /* ===== Current aura budget ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_candidates;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_auras_raw;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_totals;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_updates;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_used;

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
      aura_code VARCHAR(16) DEFAULT NULL,
      magnitude INT DEFAULT NULL,
      PRIMARY KEY(spellid, effect_index)
    ) ENGINE=Memory;

    INSERT INTO tmp_item_aura_candidates(spellid,effect_index,effect_aura,effect_misc,aura_code,magnitude)
    SELECT s.ID AS spellid,
           slots.effect_index,
           slots.effect_aura,
           slots.effect_misc,
           CASE
             WHEN slots.effect_aura = @AURA_AP THEN 'AP'
             WHEN slots.effect_aura = @AURA_RAP THEN 'RAP'
             WHEN slots.effect_aura = @AURA_SD AND (slots.effect_misc & @MASK_SD_ALL)=@MASK_SD_ALL THEN 'SDALL'
             WHEN slots.effect_aura = @AURA_SD AND (slots.effect_misc & @MASK_SD_ALL)<>0 THEN CONCAT('SDONE_', LPAD(slots.effect_misc & @MASK_SD_ALL, 3, '0'))
             WHEN slots.effect_aura IN (@AURA_HEAL1,@AURA_HEAL2) THEN 'HEAL'
             WHEN slots.effect_aura = @AURA_MP5 AND slots.effect_misc = 0 THEN 'MP5'
             WHEN slots.effect_aura = @AURA_HP5 THEN 'HP5'
             ELSE NULL
           END AS aura_code,
           CASE
             WHEN slots.effect_aura = @AURA_AP THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_RAP THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_SD AND (slots.effect_misc & @MASK_SD_ALL)<>0 THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura IN (@AURA_HEAL1,@AURA_HEAL2) THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_MP5 AND slots.effect_misc = 0 THEN GREATEST(0, slots.base_points + 1)
             WHEN slots.effect_aura = @AURA_HP5 THEN GREATEST(0, slots.base_points + 1)
             ELSE NULL
           END AS magnitude
    FROM tmp_item_spells tis
    JOIN (
      SELECT ID,
             1 AS effect_index,
             IFNULL(EffectAura_1, 0) AS effect_aura,
             IFNULL(EffectMiscValue_1, 0) AS effect_misc,
             IFNULL(EffectBasePoints_1, 0) AS base_points
      FROM dbc.spell_lplus
      UNION ALL
      SELECT ID,
             2 AS effect_index,
             IFNULL(EffectAura_2, 0) AS effect_aura,
             IFNULL(EffectMiscValue_2, 0) AS effect_misc,
             IFNULL(EffectBasePoints_2, 0) AS base_points
      FROM dbc.spell_lplus
      UNION ALL
      SELECT ID,
             3 AS effect_index,
             IFNULL(EffectAura_3, 0) AS effect_aura,
             IFNULL(EffectMiscValue_3, 0) AS effect_misc,
             IFNULL(EffectBasePoints_3, 0) AS base_points
      FROM dbc.spell_lplus
    ) AS slots ON slots.ID = tis.spellid;

    CREATE TEMPORARY TABLE tmp_item_auras_raw(
      spellid INT UNSIGNED NOT NULL,
      aura_code VARCHAR(16) NOT NULL,
      effect_index TINYINT NOT NULL,
      magnitude INT NOT NULL,
      PRIMARY KEY(spellid, effect_index, aura_code)
    ) ENGINE=Memory;

    INSERT INTO tmp_item_auras_raw(spellid,aura_code,effect_index,magnitude)
    SELECT spellid, aura_code, effect_index, magnitude
    FROM tmp_item_aura_candidates
    WHERE aura_code IS NOT NULL
      AND magnitude IS NOT NULL
      AND magnitude > 0;

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
        AND effect_aura IN (@AURA_AP, @AURA_RAP, @AURA_SD, @AURA_HEAL1, @AURA_HEAL2, @AURA_MP5, @AURA_HP5)
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
      aura_code VARCHAR(16) PRIMARY KEY,
      total_mag DOUBLE NOT NULL
    ) ENGINE=Memory;

    INSERT INTO tmp_item_aura_totals(aura_code,total_mag)
    SELECT aura_code, SUM(magnitude)
    FROM tmp_item_auras_raw
    GROUP BY aura_code;

    SET @aur_ap     := IFNULL((SELECT total_mag FROM tmp_item_aura_totals WHERE aura_code='AP'), 0.0);
    SET @aur_rap    := IFNULL((SELECT total_mag FROM tmp_item_aura_totals WHERE aura_code='RAP'), 0.0);
    SET @aur_sd_all := IFNULL((SELECT total_mag FROM tmp_item_aura_totals WHERE aura_code='SDALL'), 0.0);
    SET @aur_sd_one := IFNULL((SELECT SUM(total_mag) FROM tmp_item_aura_totals WHERE aura_code LIKE 'SDONE%'), 0.0);
    SET @aur_heal_raw := IFNULL((SELECT total_mag FROM tmp_item_aura_totals WHERE aura_code='HEAL'), 0.0);
    SET @aur_mp5    := IFNULL((SELECT total_mag FROM tmp_item_aura_totals WHERE aura_code='MP5'), 0.0);
    SET @aur_hp5    := IFNULL((SELECT total_mag FROM tmp_item_aura_totals WHERE aura_code='HP5'), 0.0);

    SET @aur_heal := CASE WHEN @aur_sd_all > 0 AND @aur_heal_raw = @aur_sd_all THEN 0 ELSE @aur_heal_raw END;

    SET @S_cur_a :=
        POW(GREATEST(0, @aur_ap     * @W_AP),     1.5)
      + POW(GREATEST(0, @aur_rap    * @W_RAP),    1.5)
      + POW(GREATEST(0, @aur_sd_all * @W_SD_ALL), 1.5)
      + POW(GREATEST(0, @aur_sd_one * @W_SD_ONE), 1.5)
      + POW(GREATEST(0, @aur_heal   * @W_HEAL),   1.5)
      + POW(GREATEST(0, @aur_mp5    * @W_MP5),    1.5)
      + POW(GREATEST(0, @aur_hp5    * @W_HP5),    1.5);

    CREATE TEMPORARY TABLE tmp_aura_updates(
      spellid INT UNSIGNED NOT NULL,
      effect_index TINYINT NOT NULL,
      aura_code VARCHAR(16) NOT NULL,
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

  SET @S_other := @S_cur - @S_cur_p - @S_cur_a - @S_cur_res;

  INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
  VALUES (p_entry, 'shared_budget_current', 'primaries', @S_cur_p,
          CONCAT('auras=', @S_cur_a, ',resists=', @S_cur_res, ',other=', @S_other)),
         (p_entry, 'shared_budget_current', 'auras', @S_cur_a,
          CONCAT('primaries=', @S_cur_p, ',resists=', @S_cur_res, ',other=', @S_other)),
         (p_entry, 'shared_budget_current', 'resists', @S_cur_res,
          CONCAT('primaries=', @S_cur_p, ',auras=', @S_cur_a, ',other=', @S_other));
  SET @S_target_shared := GREATEST(0.0, @S_tgt - @S_other);
  IF (@S_cur_p + @S_cur_a + @S_cur_res) > 0 THEN
    SET @ratio_shared := @S_target_shared / (@S_cur_p + @S_cur_a + @S_cur_res);
  ELSE
    SET @ratio_shared := 0.0;
  END IF;
  SET @ratio_shared := GREATEST(0.0, @ratio_shared);

  IF (@S_cur_p + @S_cur_a + @S_cur_res) > 0 THEN
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
  SET @S_after_shared := @S_cur_p + @S_cur_a + @S_cur_res;
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

    IF @scale_auras = 1 THEN
      DELETE FROM tmp_aura_updates;
      DELETE FROM tmp_aura_used;
      SET @aura_scale := @shared_scale;
      SET @aura_direction := CASE WHEN @aura_scale >= 1 THEN 1 ELSE -1 END;
      SET @prev_aura_code := '';
      SET @prev_aura_mag := 0;
      SET @aura_rank := 0;

      INSERT INTO tmp_aura_updates(spellid,effect_index,aura_code,old_magnitude,desired_magnitude,new_magnitude,aura_rank)
      SELECT z.spellid,
             z.effect_index,
             z.aura_code,
             z.magnitude AS old_magnitude,
             z.planned_magnitude,
             z.planned_magnitude,
             z.aura_rank
      FROM (
        SELECT x.spellid,
               x.effect_index,
               x.aura_code,
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
                 r.magnitude,
                 GREATEST(0, ROUND(r.magnitude * @aura_scale)) AS desired_mag
          FROM tmp_item_auras_raw r
        ) AS x
        ORDER BY x.aura_code,
                 CASE WHEN @aura_direction >= 1 THEN x.magnitude ELSE -x.magnitude END,
                 x.effect_index
      ) AS z;

      SET @aur_plan_ap := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='AP'), 0.0);
      SET @aur_plan_rap := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='RAP'), 0.0);
      SET @aur_plan_sd_all := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='SDALL'), 0.0);
      SET @aur_plan_sd_one := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code LIKE 'SDONE%'), 0.0);
      SET @aur_plan_heal_raw := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='HEAL'), 0.0);
      SET @aur_plan_mp5 := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='MP5'), 0.0);
      SET @aur_plan_hp5 := IFNULL((SELECT SUM(desired_magnitude) FROM tmp_aura_updates WHERE aura_code='HP5'), 0.0);

      SET @aur_plan_heal := CASE WHEN @aur_plan_sd_all > 0 AND @aur_plan_heal_raw = @aur_plan_sd_all THEN 0 ELSE @aur_plan_heal_raw END;

      SET @S_final_a :=
          POW(GREATEST(0, @aur_plan_ap     * @W_AP),     1.5)
        + POW(GREATEST(0, @aur_plan_rap    * @W_RAP),    1.5)
        + POW(GREATEST(0, @aur_plan_sd_all * @W_SD_ALL), 1.5)
        + POW(GREATEST(0, @aur_plan_sd_one * @W_SD_ONE), 1.5)
        + POW(GREATEST(0, @aur_plan_heal   * @W_HEAL),   1.5)
        + POW(GREATEST(0, @aur_plan_mp5    * @W_MP5),    1.5)
        + POW(GREATEST(0, @aur_plan_hp5    * @W_HP5),    1.5);
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

    SET @S_after_shared := @S_final_res + @S_final_a + @S_final_p;

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

      INSERT INTO tmp_aura_updates(spellid,effect_index,aura_code,old_magnitude,desired_magnitude,new_magnitude,aura_rank)
      SELECT z.spellid,
             z.effect_index,
             z.aura_code,
             z.magnitude AS old_magnitude,
             z.planned_magnitude,
             z.planned_magnitude,
             z.aura_rank
      FROM (
        SELECT x.spellid,
               x.effect_index,
               x.aura_code,
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
                 r.magnitude,
                 GREATEST(0, ROUND(r.magnitude * @aura_scale)) AS desired_mag
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

      SET @aur_new_ap := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code='AP'), 0.0);
      SET @aur_new_rap := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code='RAP'), 0.0);
      SET @aur_new_sd_all := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code='SDALL'), 0.0);
      SET @aur_new_sd_one := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code LIKE 'SDONE%'), 0.0);
      SET @aur_new_heal_raw := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code='HEAL'), 0.0);
      SET @aur_new_mp5 := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code='MP5'), 0.0);
      SET @aur_new_hp5 := IFNULL((SELECT SUM(new_magnitude) FROM tmp_aura_updates WHERE aura_code='HP5'), 0.0);

      SET @aur_new_heal := CASE WHEN @aur_new_sd_all > 0 AND @aur_new_heal_raw = @aur_new_sd_all THEN 0 ELSE @aur_new_heal_raw END;

      SET @S_final_a :=
          POW(GREATEST(0, @aur_new_ap     * @W_AP),     1.5)
        + POW(GREATEST(0, @aur_new_rap    * @W_RAP),    1.5)
        + POW(GREATEST(0, @aur_new_sd_all * @W_SD_ALL), 1.5)
        + POW(GREATEST(0, @aur_new_sd_one * @W_SD_ONE), 1.5)
        + POW(GREATEST(0, @aur_new_heal   * @W_HEAL),   1.5)
        + POW(GREATEST(0, @aur_new_mp5    * @W_MP5),    1.5)
        + POW(GREATEST(0, @aur_new_hp5    * @W_HP5),    1.5);
    ELSE
      SET @S_final_a := 0.0;
      SET @aur_new_ap := 0.0;
      SET @aur_new_rap := 0.0;
      SET @aur_new_sd_all := 0.0;
      SET @aur_new_sd_one := 0.0;
      SET @aur_new_heal := 0.0;
      SET @aur_new_mp5 := 0.0;
      SET @aur_new_hp5 := 0.0;
    END IF;

    SET @S_final_shared := @S_final_res + @S_final_a + @S_final_p;

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
         (p_entry, 'resist_update_plan', 'arcane', @res_arcane_new, CONCAT('old=', @res_arcane));

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
        t.arcane_res   = @res_arcane_new
    WHERE t.entry = p_entry;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry, 'resist_final', 'holy',   @res_holy_new,   CONCAT('old=', @res_holy)),
           (p_entry, 'resist_final', 'fire',   @res_fire_new,   CONCAT('old=', @res_fire)),
           (p_entry, 'resist_final', 'nature', @res_nature_new, CONCAT('old=', @res_nature)),
           (p_entry, 'resist_final', 'frost',  @res_frost_new,  CONCAT('old=', @res_frost)),
           (p_entry, 'resist_final', 'shadow', @res_shadow_new, CONCAT('old=', @res_shadow)),
           (p_entry, 'resist_final', 'arcane', @res_arcane_new, CONCAT('old=', @res_arcane));

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

        SET @pending_aura_changes := (SELECT COUNT(*) FROM tmp_aura_updates WHERE new_magnitude <> old_magnitude);

        IF @pending_aura_changes > 0 THEN
          DROP TEMPORARY TABLE IF EXISTS tmp_aura_spell_clones;
          CREATE TEMPORARY TABLE tmp_aura_spell_clones(
            old_spellid INT UNSIGNED PRIMARY KEY,
            new_spellid INT UNSIGNED NOT NULL
          ) ENGINE=Memory;

          SET @next_spell_id := (SELECT IFNULL(MAX(ID), 0) FROM dbc.spell_lplus);

          INSERT INTO tmp_aura_spell_clones(old_spellid,new_spellid)
          SELECT DISTINCT u.spellid,
                 (@next_spell_id := @next_spell_id + 1)
          FROM tmp_aura_updates u
          WHERE u.new_magnitude <> u.old_magnitude
          ORDER BY u.spellid;

          UPDATE tmp_aura_updates u
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = u.spellid
          SET u.new_spellid = sc.new_spellid;

          DROP TEMPORARY TABLE IF EXISTS tmp_spell_clone_rows;
          CREATE TEMPORARY TABLE tmp_spell_clone_rows LIKE dbc.spell_lplus;

          INSERT INTO tmp_spell_clone_rows
          SELECT s.*
          FROM dbc.spell_lplus s
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = s.ID;

          UPDATE tmp_spell_clone_rows t
          LEFT JOIN (
            SELECT spellid,
                   MAX(CASE WHEN effect_index=1 THEN new_magnitude - 1 END) AS bp1,
                   MAX(CASE WHEN effect_index=2 THEN new_magnitude - 1 END) AS bp2,
                   MAX(CASE WHEN effect_index=3 THEN new_magnitude - 1 END) AS bp3
            FROM tmp_aura_updates
            WHERE new_magnitude <> old_magnitude
            GROUP BY spellid
          ) upd ON upd.spellid = t.ID
          SET t.EffectBasePoints_1 = CASE WHEN upd.bp1 IS NOT NULL THEN upd.bp1 ELSE t.EffectBasePoints_1 END,
              t.EffectBasePoints_2 = CASE WHEN upd.bp2 IS NOT NULL THEN upd.bp2 ELSE t.EffectBasePoints_2 END,
              t.EffectBasePoints_3 = CASE WHEN upd.bp3 IS NOT NULL THEN upd.bp3 ELSE t.EffectBasePoints_3 END;

          UPDATE tmp_spell_clone_rows t
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.ID
          SET t.ID = sc.new_spellid;

          INSERT INTO dbc.spell_lplus
          SELECT * FROM tmp_spell_clone_rows;

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

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.spellid_1
          SET t.spellid_1 = sc.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.spellid_2
          SET t.spellid_2 = sc.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.spellid_3
          SET t.spellid_3 = sc.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.spellid_4
          SET t.spellid_4 = sc.new_spellid
          WHERE t.entry = p_entry;

          UPDATE lplusworld.item_template t
          JOIN tmp_aura_spell_clones sc ON sc.old_spellid = t.spellid_5
          SET t.spellid_5 = sc.new_spellid
          WHERE t.entry = p_entry;

          INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
          SELECT p_entry,
                 'aura_spell_swap',
                 CONCAT('slot', slots.slot_no),
                 sc.new_spellid,
                 CONCAT('old_spell=', sc.old_spellid)
          FROM (
            SELECT 1 AS slot_no, spellid_1 AS spellid, spelltrigger_1 AS trig FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 2, spellid_2, spelltrigger_2 FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 3, spellid_3, spelltrigger_3 FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 4, spellid_4, spelltrigger_4 FROM lplusworld.item_template WHERE entry = p_entry
            UNION ALL SELECT 5, spellid_5, spelltrigger_5 FROM lplusworld.item_template WHERE entry = p_entry
          ) AS slots
          JOIN tmp_aura_spell_clones sc ON sc.new_spellid = slots.spellid
          WHERE slots.trig = 1;

          DROP TEMPORARY TABLE IF EXISTS tmp_spell_clone_rows;
          DROP TEMPORARY TABLE IF EXISTS tmp_aura_spell_clones;
        END IF;

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

  SELECT p_entry AS entry,
         @ilvl_cur AS ilvl_before,
         p_target_ilvl AS target_ilvl,
         (SELECT CAST(trueItemLevel AS SIGNED) FROM lplusworld.item_template WHERE entry=p_entry) AS ilvl_after;
END proc$$

DELIMITER ;
