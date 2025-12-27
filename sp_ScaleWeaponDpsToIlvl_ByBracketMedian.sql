CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleWeaponDpsToIlvl_ByBracketMedian`(
    IN p_entry      INT,
    IN p_tgt_ilvl   SMALLINT,
    IN p_apply      TINYINT,   -- 0 = dry run, 1 = write dmg back to item_template
    IN p_scale_item TINYINT    -- 0 = skip stats, 1 = call SimpleGreedy on stats
)
proc: BEGIN
    DECLARE v_class         TINYINT UNSIGNED;
    DECLARE v_subclass      TINYINT UNSIGNED;
    DECLARE v_quality       TINYINT UNSIGNED;
    DECLARE v_src_ilvl      SMALLINT UNSIGNED;
    DECLARE v_delay         INT UNSIGNED;
    DECLARE v_dmg_min1      DOUBLE;
    DECLARE v_dmg_max1      DOUBLE;
    DECLARE v_dmg_min2      DOUBLE;
    DECLARE v_dmg_max2      DOUBLE;
    DECLARE v_caster_flag   TINYINT UNSIGNED;

    DECLARE v_cur_dps       DOUBLE;
    DECLARE v_tgt_dps       DOUBLE;
    DECLARE v_scale         DOUBLE;

    DECLARE v_src_slotval   DOUBLE;
    DECLARE v_tgt_slotval   DOUBLE;
    DECLARE v_slot_ratio    DOUBLE;

    DECLARE v_trade_src_dps DOUBLE;
    DECLARE v_trade_tgt_dps DOUBLE;
    DECLARE v_phys_base_cur DOUBLE;
    DECLARE v_phys_base_tgt DOUBLE;
    DECLARE v_caster_minus_cur DOUBLE;
    DECLARE v_caster_minus_tgt DOUBLE;

    DECLARE v_bracket       VARCHAR(6);

    DECLARE v_ilvl_low      SMALLINT UNSIGNED;
    DECLARE v_ilvl_high     SMALLINT UNSIGNED;
    DECLARE v_dps_low       DOUBLE;
    DECLARE v_dps_high      DOUBLE;
    DECLARE v_tgt_median    DOUBLE;
    DECLARE v_have_median   TINYINT DEFAULT 0;

    DECLARE v_new_dmg_min1  DOUBLE;
    DECLARE v_new_dmg_max1  DOUBLE;
    DECLARE v_new_dmg_min2  DOUBLE;
    DECLARE v_new_dmg_max2  DOUBLE;

    /* basic fields + caster flag */
    SELECT `class`, `subclass`, `Quality`, `ItemLevel`, `delay`,
           `dmg_min1`, `dmg_max1`, `dmg_min2`, `dmg_max2`,
           IFNULL(`caster`,0)
      INTO v_class, v_subclass, v_quality, v_src_ilvl, v_delay,
           v_dmg_min1, v_dmg_max1, v_dmg_min2, v_dmg_max2,
           v_caster_flag
    FROM lplusworld.item_template
    WHERE entry = p_entry
    LIMIT 1;

    /* sanity */
    IF v_class IS NULL
       OR v_class <> 2
       OR v_src_ilvl IS NULL
       OR v_src_ilvl <= 0
       OR v_delay IS NULL
       OR v_delay <= 0
       OR p_tgt_ilvl IS NULL
       OR p_tgt_ilvl <= 0
       OR v_src_ilvl = p_tgt_ilvl THEN
        LEAVE proc;
    END IF;

    /* current DPS (matches estimator: dmg1+ dmg2) */
    SET v_cur_dps :=
      (
        (COALESCE(v_dmg_min1,0.0) + COALESCE(v_dmg_max1,0.0)) / 2.0 +
        (COALESCE(v_dmg_min2,0.0) + COALESCE(v_dmg_max2,0.0)) / 2.0
      ) / NULLIF(v_delay/1000.0,0);

    IF v_cur_dps IS NULL OR v_cur_dps <= 0 THEN
        LEAVE proc;
    END IF;

    /* bracket mapping must match sp_EstimateItemLevels_WeaponsFromBracketMedians */
    SET v_bracket :=
      CASE
        WHEN v_caster_flag = 1 THEN NULL
        WHEN v_subclass IN (0,4,7,15,13) THEN '1H'      /* 1H Axe/Mace/Sword, Dagger, Fist */
        WHEN v_subclass IN (1,5,6,8)     THEN '2H'      /* 2H Axe/Mace, Polearm, 2H Sword (no Staves) */
        WHEN v_subclass IN (2,3,18)      THEN 'RANGED'  /* Bow, Gun, Crossbow */
        ELSE NULL
      END;

    /* lookup target median DPS for non-caster weapons */
    IF v_bracket IS NOT NULL THEN
        /* nearest ilvl <= target */
        SELECT m.ilvl, m.median_dps
          INTO v_ilvl_low, v_dps_low
        FROM helper.weapon_median_dps_bracket m
        WHERE m.bracket = v_bracket
          AND m.quality = v_quality
          AND m.ilvl <= p_tgt_ilvl
        ORDER BY m.ilvl DESC
        LIMIT 1;

        /* nearest ilvl >= target */
        SELECT m.ilvl, m.median_dps
          INTO v_ilvl_high, v_dps_high
        FROM helper.weapon_median_dps_bracket m
        WHERE m.bracket = v_bracket
          AND m.quality = v_quality
          AND m.ilvl >= p_tgt_ilvl
        ORDER BY m.ilvl ASC
        LIMIT 1;

        IF v_ilvl_low IS NOT NULL AND v_ilvl_high IS NOT NULL THEN
            IF v_ilvl_low = v_ilvl_high THEN
                SET v_tgt_median := v_dps_low;
            ELSE
                SET v_tgt_median :=
                  v_dps_low + (v_dps_high - v_dps_low) * (p_tgt_ilvl - v_ilvl_low) / (v_ilvl_high - v_ilvl_low);
            END IF;
            SET v_have_median := 1;
        ELSEIF v_ilvl_low IS NOT NULL THEN
            SET v_tgt_median := v_dps_low;
            SET v_have_median := 1;
        ELSEIF v_ilvl_high IS NOT NULL THEN
            SET v_tgt_median := v_dps_high;
            SET v_have_median := 1;
        END IF;
    END IF;

    /* slot value curve must match helper.sp_EstimateItemLevels */
    SET v_src_slotval :=
      CASE v_quality
        WHEN 2 THEN (1.21 * v_src_ilvl - 9.8)   /* Green */
        WHEN 3 THEN (1.42 * v_src_ilvl - 4.2)   /* Blue  */
        WHEN 4 THEN (1.64 * v_src_ilvl + 11.2)  /* Epic  */
        ELSE (1.64 * v_src_ilvl + 11.2)
      END;

    SET v_tgt_slotval :=
      CASE v_quality
        WHEN 2 THEN (1.21 * p_tgt_ilvl - 9.8)
        WHEN 3 THEN (1.42 * p_tgt_ilvl - 4.2)
        WHEN 4 THEN (1.64 * p_tgt_ilvl + 11.2)
        ELSE (1.64 * p_tgt_ilvl + 11.2)
      END;
    SET v_slot_ratio  := v_tgt_slotval / NULLIF(v_src_slotval, 0);

    /* default: just ratio-scale current DPS */
    SET v_tgt_dps := v_cur_dps * v_slot_ratio;

    /* caster weapons: deterministic DPS trade model (Word doc) */
    SET v_trade_src_dps := 0.0;
    SET v_trade_tgt_dps := 0.0;
    SET v_phys_base_cur := v_cur_dps;
    SET v_phys_base_tgt := 0.0;
    SET v_caster_minus_cur := 0.0;
    SET v_caster_minus_tgt := 0.0;

    IF v_caster_flag = 1 THEN
        SET v_trade_src_dps := GREATEST(v_src_ilvl - 60, 0);
        SET v_trade_tgt_dps := GREATEST(p_tgt_ilvl - 60, 0);

        /* baseline physical budget includes traded DPS at source */
        SET v_phys_base_cur := v_cur_dps + v_trade_src_dps;

        /* scale baseline to target */
        SET v_phys_base_tgt := GREATEST(v_phys_base_cur * v_slot_ratio, 0.0);

        /* clamp trade so it never exceeds baseline */
        SET v_caster_minus_cur := v_trade_src_dps;
        SET v_caster_minus_tgt := LEAST(v_trade_tgt_dps, v_phys_base_tgt);

        /* actual weapon DPS after trade removal */
        SET v_tgt_dps := GREATEST(v_phys_base_tgt - v_caster_minus_tgt, 0.0);
    ELSE
        /* non-caster weapons: hit the median curve if we can */
        IF v_have_median = 1 THEN
            SET v_tgt_dps := v_tgt_median;
        END IF;
    END IF;

    IF v_tgt_dps IS NULL OR v_tgt_dps <= 0 THEN
        LEAVE proc;
    END IF;

    SET v_scale := v_tgt_dps / v_cur_dps;

    SET v_new_dmg_min1 := COALESCE(v_dmg_min1,0.0) * v_scale;
    SET v_new_dmg_max1 := COALESCE(v_dmg_max1,0.0) * v_scale;
    SET v_new_dmg_min2 := COALESCE(v_dmg_min2,0.0) * v_scale;
    SET v_new_dmg_max2 := COALESCE(v_dmg_max2,0.0) * v_scale;

    IF p_apply = 1 THEN
        UPDATE lplusworld.item_template
        SET dmg_min1 = ROUND(v_new_dmg_min1, 1),
            dmg_max1 = ROUND(v_new_dmg_max1, 1),
            dmg_min2 = ROUND(v_new_dmg_min2, 1),
            dmg_max2 = ROUND(v_new_dmg_max2, 1)
        WHERE entry = p_entry;
    END IF;

    /* expose caster trade so SimpleGreedy can enforce 4*(ilvl-60) SD/HEAL */
    SET @weapon_trade_entry      := p_entry;
    SET @weapon_trade_tgt_ilvl   := p_tgt_ilvl;

    IF v_caster_flag = 1 THEN
        SET @weapon_trade_dps_current := v_caster_minus_cur;
        SET @weapon_trade_dps_target  := v_caster_minus_tgt;
    ELSE
        SET @weapon_trade_dps_current := 0;
        SET @weapon_trade_dps_target  := 0;
    END IF;

    /* optional: run the greedy scaler from here */
    IF p_scale_item = 1 THEN
        CALL helper.sp_ScaleItemToIlvl_SimpleGreedy(p_entry, p_tgt_ilvl, p_apply, 1, 0);
    END IF;
END proc