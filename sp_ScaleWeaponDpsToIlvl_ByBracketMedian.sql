CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleWeaponDpsToIlvl_ByBracketMedian`(
  IN p_entry        INT UNSIGNED,
  IN p_target_ilvl  INT UNSIGNED,     -- if NULL -> use COALESCE(trueItemLevel, ItemLevel)
  IN p_apply        TINYINT,          -- 1=apply, 0=preview
  IN p_scale_item   TINYINT           -- nonzero = also call scaleItemLevelGreedy afterwards
)
main: BEGIN
  /* reset the weapon trade session hints so stale data never bleeds into other entries */
  SET @weapon_trade_entry := NULL;
  SET @weapon_trade_dps_current := NULL;
  SET @weapon_trade_dps_target := NULL;

  /* -------- 1) Load item & current DPS -------- */
  SELECT it.subclass, it.Quality, it.caster, it.delay,
         COALESCE(it.trueItemLevel, it.ItemLevel) AS src_ilvl,
         (
           (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0))/2.0 +
           (COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0))/2.0
         ) / NULLIF(it.delay/1000.0,0) AS cur_dps
    INTO @subclass, @q, @caster, @delay, @src_ilvl, @cur_dps
  FROM lplusworld.item_template it
  WHERE it.entry = p_entry;

  IF @delay IS NULL OR @delay = 0 OR @cur_dps IS NULL THEN
    SELECT 'skip' AS status, 'no dps' AS reason, p_entry AS entry; LEAVE main;
  END IF;

  /* coerce helper flag once up front */
  SET @scale_item := CASE WHEN IFNULL(p_scale_item,0) <> 0 THEN 1 ELSE 0 END;

  /* -------- 2) Bracket assignment --------
     - 1H: Axe(0) Mace(4) Sword(7) Dagger(15) Fist(13)
     - 2H: 2H Axe(1) 2H Mace(5) Polearm(6) 2H Sword(8) Staff(10)
     - RANGED: Bow(2) Gun(3) Crossbow(18) Wand(19)
     Exclude: Thrown(16), Fishing(20), and anything else outside these buckets */
  SET @bracket := CASE
    WHEN @subclass IN (0,4,7,15,13)      THEN '1H'
    WHEN @subclass IN (1,5,6,8,10)       THEN '2H'
    WHEN @subclass IN (2,3,18,19)        THEN 'RANGED'
    ELSE NULL
  END;

  IF @bracket IS NULL THEN
    SELECT 'skip' AS status, 'not in bracket (caster/staff/wand/etc)' AS reason, p_entry AS entry; LEAVE main;
  END IF;

  /* -------- 3) Desired iLvl -------- */
  SET @tgt_ilvl := COALESCE(p_target_ilvl, @src_ilvl);

  /* -------- 4) Get median for (bracket, quality, tgt_ilvl) with interpolation -------- */
  SET @median_source := 'exact';
  SELECT median_dps INTO @tgt_median
  FROM helper.weapon_median_dps_bracket
  WHERE bracket=@bracket AND quality=@q AND ilvl=@tgt_ilvl;

  IF @tgt_median IS NULL THEN
    /* nearest below and above */
    SET @low_ilvl := (SELECT MAX(ilvl) FROM helper.weapon_median_dps_bracket
                      WHERE bracket=@bracket AND quality=@q AND ilvl < @tgt_ilvl);
    SET @low_med  := (SELECT median_dps FROM helper.weapon_median_dps_bracket
                      WHERE bracket=@bracket AND quality=@q AND ilvl=@low_ilvl);

    SET @high_ilvl := (SELECT MIN(ilvl) FROM helper.weapon_median_dps_bracket
                       WHERE bracket=@bracket AND quality=@q AND ilvl > @tgt_ilvl);
    SET @high_med  := (SELECT median_dps FROM helper.weapon_median_dps_bracket
                       WHERE bracket=@bracket AND quality=@q AND ilvl=@high_ilvl);

    IF @low_ilvl IS NOT NULL AND @high_ilvl IS NOT NULL THEN
      /* linear interpolation between neighbors */
      SET @median_source := 'interp';
      SET @tgt_median := @low_med +
                         (@high_med - @low_med) *
                         ((@tgt_ilvl - @low_ilvl) / NULLIF(@high_ilvl - @low_ilvl,0));
    ELSEIF @low_ilvl IS NOT NULL THEN
      SET @median_source := 'nearest_low';
      SET @tgt_median := @low_med;
    ELSEIF @high_ilvl IS NOT NULL THEN
      SET @median_source := 'nearest_high';
      SET @tgt_median := @high_med;
    ELSE
      SELECT 'skip' AS status, 'no medians for bracket/quality' AS reason,
             @bracket AS bracket, @q AS quality, @tgt_ilvl AS ilvl, p_entry AS entry; LEAVE main;
    END IF;
  END IF;

  /* -------- 4b) Median for the source ilvl (needed to recover caster DPS trade) -------- */
  SET @src_median := NULL;
  SELECT median_dps INTO @src_median
  FROM helper.weapon_median_dps_bracket
  WHERE bracket=@bracket AND quality=@q AND ilvl=@src_ilvl;

  IF @src_median IS NULL THEN
    SET @src_low_ilvl := (SELECT MAX(ilvl) FROM helper.weapon_median_dps_bracket
                          WHERE bracket=@bracket AND quality=@q AND ilvl < @src_ilvl);
    SET @src_low_med  := (SELECT median_dps FROM helper.weapon_median_dps_bracket
                          WHERE bracket=@bracket AND quality=@q AND ilvl=@src_low_ilvl);

    SET @src_high_ilvl := (SELECT MIN(ilvl) FROM helper.weapon_median_dps_bracket
                           WHERE bracket=@bracket AND quality=@q AND ilvl > @src_ilvl);
    SET @src_high_med  := (SELECT median_dps FROM helper.weapon_median_dps_bracket
                           WHERE bracket=@bracket AND quality=@q AND ilvl=@src_high_ilvl);

    IF @src_low_ilvl IS NOT NULL AND @src_high_ilvl IS NOT NULL THEN
      SET @src_median := @src_low_med +
                         (@src_high_med - @src_low_med) *
                         ((@src_ilvl - @src_low_ilvl) / NULLIF(@src_high_ilvl - @src_low_ilvl,0));
    ELSEIF @src_low_ilvl IS NOT NULL THEN
      SET @src_median := @src_low_med;
    ELSEIF @src_high_ilvl IS NOT NULL THEN
      SET @src_median := @src_high_med;
    ELSE
      SET @src_median := NULL;
    END IF;
  END IF;

  IF @src_median IS NULL THEN
    /* fall back to the actual DPS so caster subtraction becomes zero instead of NULL */
    SET @src_median := @cur_dps;
  END IF;

  /* -------- 5) Caster DPS trade (Item level.docx "Weapons DPS Trade") -------- */
  SET @caster_minus_current := 0;
  SET @caster_minus_scaled := 0;
  SET @tgt_dps := @tgt_median;
  IF @caster = 1 THEN
    SET @caster_minus_current := GREATEST(@src_median - @cur_dps, 0);
    SET @minus_scale := CASE WHEN @src_median > 0 THEN @tgt_median / @src_median ELSE 1 END;
    SET @caster_minus_scaled := @caster_minus_current * @minus_scale;
    SET @tgt_dps := GREATEST(@tgt_median - @caster_minus_scaled, 0);

    /* stash the caster trade delta so the greedy scaler can add/subtract the matching budget */
    SET @weapon_trade_entry := p_entry;
    SET @weapon_trade_dps_current := @caster_minus_current;
    SET @weapon_trade_dps_target := @caster_minus_scaled;
  ELSE
    /* non-caster weapons still stamp their entry so the next scaler run can safely ignore stale rows */
    SET @weapon_trade_entry := p_entry;
    SET @weapon_trade_dps_current := 0;
    SET @weapon_trade_dps_target := 0;
  END IF;

  /* -------- 6) Monotonic rule vs iLvl direction -------- */
  IF @tgt_ilvl > @src_ilvl AND @tgt_dps < @cur_dps THEN
    SET @tgt_dps := @cur_dps;
  ELSEIF @tgt_ilvl < @src_ilvl AND @tgt_dps > @cur_dps THEN
    SET @tgt_dps := @cur_dps;
  END IF;

  /* -------- 7) Scale factor & apply (range scales linearly) -------- */
  IF @cur_dps = 0 THEN
    SELECT 'skip' AS status, 'current dps zero' AS reason, p_entry AS entry; LEAVE main;
  END IF;

  SET @r := @tgt_dps / @cur_dps;

  IF p_apply = 1 THEN
    UPDATE lplusworld.item_template
    SET dmg_min1 = ROUND(COALESCE(dmg_min1,0) * @r, 3),
        dmg_max1 = ROUND(COALESCE(dmg_max1,0) * @r, 3),
        dmg_min2 = ROUND(COALESCE(dmg_min2,0) * @r, 3),
        dmg_max2 = ROUND(COALESCE(dmg_max2,0) * @r, 3)
    WHERE entry = p_entry;
  END IF;

  /* optional cascade so the greedy scaler immediately rebalances stats/auras */
  IF @scale_item = 1 THEN
    CALL helper.sp_ScaleItemToIlvl_SimpleGreedy(p_entry, @tgt_ilvl, p_apply, 1);
  END IF;

  /* -------- 8) Result preview -------- */
  SELECT
    CASE WHEN p_apply=1 THEN 'applied' ELSE 'preview' END AS status,
    p_entry AS entry,
    @bracket AS bracket,
    @q AS quality,
    @src_ilvl AS src_ilvl,
    @tgt_ilvl AS tgt_ilvl,
    @median_source AS median_source,
    ROUND(@cur_dps,3) AS cur_dps,
    ROUND(@tgt_median,3) AS tgt_median,
    ROUND(@tgt_dps,3) AS tgt_dps,
    ROUND(@caster_minus_current,3) AS caster_minus_current,
    ROUND(@caster_minus_scaled,3) AS caster_minus_scaled,
    ROUND(@r,6) AS ratio_applied;
END