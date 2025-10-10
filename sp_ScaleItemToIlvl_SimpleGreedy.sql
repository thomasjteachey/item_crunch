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
  DROP TEMPORARY TABLE IF EXISTS tmp_item_auras_raw;
  DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_totals;
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_updates;

  SET @S_cur_a := 0.0;
  SET @aura_ratio := 0.0;
  SET @aura_scale := 1.0;
  SET @resist_ratio := 0.0;

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

    CREATE TEMPORARY TABLE tmp_item_auras_raw(
      spellid INT UNSIGNED NOT NULL,
      aura_code VARCHAR(16) NOT NULL,
      effect_index TINYINT NOT NULL,
      magnitude INT NOT NULL,
      PRIMARY KEY(spellid, effect_index, aura_code)
    ) ENGINE=Memory;

    INSERT INTO tmp_item_auras_raw(spellid,aura_code,effect_index,magnitude)
    SELECT q.spellid, q.aura_code, q.effect_index, q.magnitude
    FROM (
      SELECT ac.spellid,
             ac.aura_code,
             CASE
               WHEN ac.aura_code='AP' AND s.EffectAura_1=@AURA_AP AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code='AP' AND s.EffectAura_2=@AURA_AP AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code='AP' AND s.EffectAura_3=@AURA_AP AND s.EffectBasePoints_3+1=ac.magnitude THEN 3

               WHEN ac.aura_code='RAP' AND s.EffectAura_1=@AURA_RAP AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code='RAP' AND s.EffectAura_2=@AURA_RAP AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code='RAP' AND s.EffectAura_3=@AURA_RAP AND s.EffectBasePoints_3+1=ac.magnitude THEN 3

               WHEN ac.aura_code='SDALL' AND s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)=@MASK_SD_ALL AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code='SDALL' AND s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)=@MASK_SD_ALL AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code='SDALL' AND s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)=@MASK_SD_ALL AND s.EffectBasePoints_3+1=ac.magnitude THEN 3

               WHEN ac.aura_code LIKE 'SDONE%' AND s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>@MASK_SD_ALL AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code LIKE 'SDONE%' AND s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>@MASK_SD_ALL AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code LIKE 'SDONE%' AND s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>@MASK_SD_ALL AND s.EffectBasePoints_3+1=ac.magnitude THEN 3

               WHEN ac.aura_code='HEAL' AND s.EffectAura_1 IN (@AURA_HEAL1,@AURA_HEAL2) AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code='HEAL' AND s.EffectAura_2 IN (@AURA_HEAL1,@AURA_HEAL2) AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code='HEAL' AND s.EffectAura_3 IN (@AURA_HEAL1,@AURA_HEAL2) AND s.EffectBasePoints_3+1=ac.magnitude THEN 3

               WHEN ac.aura_code='MP5' AND s.EffectAura_1=@AURA_MP5 AND s.EffectMiscValue_1=0 AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code='MP5' AND s.EffectAura_2=@AURA_MP5 AND s.EffectMiscValue_2=0 AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code='MP5' AND s.EffectAura_3=@AURA_MP5 AND s.EffectMiscValue_3=0 AND s.EffectBasePoints_3+1=ac.magnitude THEN 3

               WHEN ac.aura_code='HP5' AND s.EffectAura_1=@AURA_HP5 AND s.EffectBasePoints_1+1=ac.magnitude THEN 1
               WHEN ac.aura_code='HP5' AND s.EffectAura_2=@AURA_HP5 AND s.EffectBasePoints_2+1=ac.magnitude THEN 2
               WHEN ac.aura_code='HP5' AND s.EffectAura_3=@AURA_HP5 AND s.EffectBasePoints_3+1=ac.magnitude THEN 3
               ELSE 0
             END AS effect_index,
             ac.magnitude
      FROM helper.aura_spell_catalog ac
      JOIN tmp_item_spells tis ON tis.spellid = ac.spellid
      JOIN dbc.spell_lplus s ON s.ID = ac.spellid
      WHERE ac.aura_code IN ('AP','RAP','SDALL','HEAL','MP5','HP5')
         OR ac.aura_code LIKE 'SDONE%'
    ) q
    WHERE q.effect_index BETWEEN 1 AND 3;

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
      PRIMARY KEY(spellid, effect_index, aura_code)
    ) ENGINE=Memory;
  END IF;

  SET @S_other := @S_cur - @S_cur_p - @S_cur_a - @S_cur_res;
  SET @S_target_shared := GREATEST(0.0, @S_tgt - @S_other);
  IF (@S_cur_p + @S_cur_a + @S_cur_res) > 0 THEN
    SET @ratio_shared := @S_target_shared / (@S_cur_p + @S_cur_a + @S_cur_res);
  ELSE
    SET @ratio_shared := 0.0;
  END IF;
  SET @ratio_shared := GREATEST(0.0, @ratio_shared);

  SET @S_target_p_est := @S_cur_p * @ratio_shared;
  SET @S_target_a := @S_cur_a * @ratio_shared;
  SET @S_target_res := @S_cur_res * @ratio_shared;

  SET @S_final_res := @S_cur_res;
  SET @S_final_a := @S_cur_a;

  IF @S_cur_res > 0 THEN
    SET @resist_ratio := GREATEST(0.0, @S_target_res / @S_cur_res);
    SET @resist_scale := CASE
      WHEN @resist_ratio = 0 THEN 0
      ELSE POW(@resist_ratio, 2.0/3.0)
    END;

    SET @res_holy_new := LEAST(255, ROUND(GREATEST(0, @res_holy * @resist_scale)));
    SET @res_fire_new := LEAST(255, ROUND(GREATEST(0, @res_fire * @resist_scale)));
    SET @res_nature_new := LEAST(255, ROUND(GREATEST(0, @res_nature * @resist_scale)));
    SET @res_frost_new := LEAST(255, ROUND(GREATEST(0, @res_frost * @resist_scale)));
    SET @res_shadow_new := LEAST(255, ROUND(GREATEST(0, @res_shadow * @resist_scale)));
    SET @res_arcane_new := LEAST(255, ROUND(GREATEST(0, @res_arcane * @resist_scale)));

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,
            'resist_scale_plan',
            'ratio',
            @resist_scale,
            CONCAT('ratio=', @resist_ratio, ',cur=', @S_cur_res, ',tgt=', @S_target_res));

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry, 'resist_update_plan', 'holy',   @res_holy_new,   CONCAT('old=', @res_holy)),
           (p_entry, 'resist_update_plan', 'fire',   @res_fire_new,   CONCAT('old=', @res_fire)),
           (p_entry, 'resist_update_plan', 'nature', @res_nature_new, CONCAT('old=', @res_nature)),
           (p_entry, 'resist_update_plan', 'frost',  @res_frost_new,  CONCAT('old=', @res_frost)),
           (p_entry, 'resist_update_plan', 'shadow', @res_shadow_new, CONCAT('old=', @res_shadow)),
           (p_entry, 'resist_update_plan', 'arcane', @res_arcane_new, CONCAT('old=', @res_arcane));
    SET @S_final_res :=
          POW(GREATEST(0, @res_holy_new   * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_fire_new   * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_nature_new * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_frost_new  * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_shadow_new * @W_RESIST), 1.5)
        + POW(GREATEST(0, @res_arcane_new * @W_RESIST), 1.5);
  ELSE
    SET @resist_ratio := 0.0;
    SET @resist_scale := 1.0;
    SET @S_final_res := 0.0;
  END IF;

  IF @scale_auras = 1 THEN
    IF @S_cur_a > 0 THEN
      SET @aura_ratio := GREATEST(0.0, @S_target_a / @S_cur_a);
      SET @aura_scale := CASE
        WHEN @aura_ratio = 0 THEN 0
        ELSE POW(@aura_ratio, 2.0/3.0)
      END;
    ELSE
      SET @aura_scale := 1.0;
    END IF;

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
               GREATEST(0,
                 CASE
                   WHEN @S_cur_a = 0 THEN r.magnitude
                   ELSE ROUND(r.magnitude * @aura_scale)
                 END
               ) AS desired_mag
        FROM tmp_item_auras_raw r
      ) AS x
      ORDER BY x.aura_code,
               CASE WHEN @aura_direction >= 1 THEN x.magnitude ELSE -x.magnitude END,
               x.effect_index
    ) AS z;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    VALUES (p_entry,
            'aura_scale_plan',
            'ratio_dir',
            @aura_scale,
            CONCAT('ratio=', @aura_ratio, ',dir=', @aura_direction, ',cur=', @S_cur_a, ',tgt=', @S_target_a));

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    SELECT p_entry,
           'aura_update_plan',
           CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
           u.desired_magnitude,
           CONCAT('spell=', u.spellid, ',effect=', u.effect_index, ',old=', u.old_magnitude)
    FROM tmp_aura_updates u;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    SELECT p_entry,
           'aura_update_dup_rank',
           d.aura_code,
           d.desired_magnitude,
           CONCAT('rows=', d.cnt)
    FROM (
      SELECT aura_code, desired_magnitude, COUNT(*) AS cnt
      FROM tmp_aura_updates
      GROUP BY aura_code, desired_magnitude
      HAVING COUNT(*) > 1
    ) AS d;

    INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
    SELECT p_entry,
           'aura_update_conflict_initial',
           CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
           u.desired_magnitude,
           CONCAT('existing_spell=', ac2.spellid)
    FROM tmp_aura_updates u
    JOIN helper.aura_spell_catalog ac2
      ON ac2.aura_code = u.aura_code
     AND ac2.magnitude = u.desired_magnitude
     AND ac2.spellid <> u.spellid;

    CREATE TEMPORARY TABLE tmp_aura_used(
      aura_code VARCHAR(16) NOT NULL,
      magnitude INT NOT NULL,
      PRIMARY KEY(aura_code, magnitude)
    ) ENGINE=Memory;

    INSERT INTO tmp_aura_used(aura_code, magnitude)
    SELECT ac.aura_code,
           ac.magnitude
    FROM helper.aura_spell_catalog ac
    LEFT JOIN tmp_aura_updates u
      ON u.aura_code = ac.aura_code
     AND u.spellid = ac.spellid
    WHERE u.spellid IS NULL;

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

      adjust_loop: WHILE 1 DO
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
          LEAVE adjust_loop;
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
          LEAVE adjust_loop;
        END IF;
      END WHILE;

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
    SELECT p_entry,
           'aura_update_conflict',
           CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
           u.new_magnitude,
           CONCAT('existing_spell=', ac2.spellid)
    FROM tmp_aura_updates u
    JOIN helper.aura_spell_catalog ac2
      ON ac2.aura_code = u.aura_code
     AND ac2.magnitude = u.new_magnitude
     AND ac2.spellid <> u.spellid;

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

    DROP TEMPORARY TABLE IF EXISTS tmp_aura_used;
  END IF;

  SET @S_target_p_final := GREATEST(0.0, @S_target_shared - @S_final_res - @S_final_a);
  SET @delta_p := @S_target_p_final - @S_cur_p;
  SET @each_p  := CASE WHEN @k>0 THEN @delta_p / @k ELSE 0 END;

  /* new primary values */
  DROP TEMPORARY TABLE IF EXISTS tmp_pnew;
  CREATE TEMPORARY TABLE tmp_pnew(stat TINYINT PRIMARY KEY, newv INT) ENGINE=Memory;
  INSERT INTO tmp_pnew(stat,newv)
  SELECT stat,
         ROUND( POW( GREATEST(0.0, POW(v * @W_PRIMARY, 1.5) + @each_p), 2.0/3.0 ) / @W_PRIMARY )
  FROM tmp_pcur;

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
      IF EXISTS (SELECT 1 FROM tmp_aura_updates) THEN
        -- use an entry-scoped high sentinel so staging never collides with real magnitudes
        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        SELECT p_entry,
               'aura_shift_stage',
               CONCAT(u.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
               2000000000 + ((p_entry & 1048575) * 128) + u.aura_rank,
               CONCAT('spell=', u.spellid)
        FROM tmp_aura_updates u;

        UPDATE helper.aura_spell_catalog ac
        JOIN tmp_aura_updates u ON u.spellid = ac.spellid AND ac.aura_code = u.aura_code
        SET ac.magnitude = 2000000000 + ((p_entry & 1048575) * 128) + u.aura_rank;

        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        SELECT p_entry,
               'aura_shifted',
               CONCAT(ac.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
               ac.magnitude,
               CONCAT('spell=', ac.spellid)
        FROM helper.aura_spell_catalog ac
        JOIN tmp_aura_updates u ON u.spellid = ac.spellid AND ac.aura_code = u.aura_code;

        UPDATE helper.aura_spell_catalog ac
        JOIN tmp_aura_updates u ON u.spellid = ac.spellid AND ac.aura_code = u.aura_code
        SET ac.magnitude = u.new_magnitude;

        INSERT INTO helper.ilvl_debug_log(entry, step, k, v_double, v_text)
        SELECT p_entry,
               'aura_final',
               CONCAT(ac.aura_code, '#', LPAD(u.aura_rank, 3, '0')),
               ac.magnitude,
               CONCAT('spell=', ac.spellid)
        FROM helper.aura_spell_catalog ac
        JOIN tmp_aura_updates u ON u.spellid = ac.spellid AND ac.aura_code = u.aura_code;

        UPDATE dbc.spell_lplus s
        JOIN tmp_aura_updates u ON u.spellid = s.ID AND u.effect_index = 1
        SET s.EffectBasePoints_1 = GREATEST(-1, CAST(u.new_magnitude AS SIGNED) - 1);

        UPDATE dbc.spell_lplus s
        JOIN tmp_aura_updates u ON u.spellid = s.ID AND u.effect_index = 2
        SET s.EffectBasePoints_2 = GREATEST(-1, CAST(u.new_magnitude AS SIGNED) - 1);

        UPDATE dbc.spell_lplus s
        JOIN tmp_aura_updates u ON u.spellid = s.ID AND u.effect_index = 3
        SET s.EffectBasePoints_3 = GREATEST(-1, CAST(u.new_magnitude AS SIGNED) - 1);
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
