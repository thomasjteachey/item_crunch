DELIMITER $$
CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleWeaponDpsToIlvl_ByBracketMedian`(
    IN p_entry      INT,
    IN p_tgt_ilvl   SMALLINT,
    IN p_apply      TINYINT,   -- 0 = dry run, 1 = write dmg back to item_template
    IN p_scale_item TINYINT    -- 0 = skip stats, 1 = call SimpleGreedy on stats
)
proc: BEGIN
    DECLARE v_class         TINYINT UNSIGNED;
    DECLARE v_quality       TINYINT UNSIGNED;
    DECLARE v_src_ilvl      SMALLINT UNSIGNED;
    DECLARE v_delay         INT UNSIGNED;
    DECLARE v_dmg_min1      FLOAT;
    DECLARE v_dmg_max1      FLOAT;
    DECLARE v_caster_flag   TINYINT UNSIGNED;

    DECLARE v_cur_dps       DOUBLE;
    DECLARE v_phys_dps_cur  DOUBLE;
    DECLARE v_phys_dps_tgt  DOUBLE;
    DECLARE v_trade_src_dps DOUBLE;
    DECLARE v_trade_tgt_dps DOUBLE;
    DECLARE v_caster_minus_cur DOUBLE;
    DECLARE v_caster_minus_tgt DOUBLE;
    DECLARE v_tgt_dps       DOUBLE;

    DECLARE v_src_slotval   DOUBLE;
    DECLARE v_tgt_slotval   DOUBLE;
    DECLARE v_slot_ratio    DOUBLE;

    DECLARE v_new_dmg_min1  DOUBLE;
    DECLARE v_new_dmg_max1  DOUBLE;

    /* basic fields + caster flag */
    SELECT `class`, `Quality`, `ItemLevel`, `delay`, `dmg_min1`, `dmg_max1`, IFNULL(`caster`,0)
      INTO v_class, v_quality, v_src_ilvl, v_delay, v_dmg_min1, v_dmg_max1, v_caster_flag
    FROM lplusworld.item_template
    WHERE entry = p_entry
    LIMIT 1;

    /* sanity: weapons only, valid ilvl and delay, and actually changing */
    IF v_class IS NULL
       OR v_class <> 2
       OR v_src_ilvl IS NULL
       OR v_src_ilvl <= 0
       OR v_src_ilvl = p_tgt_ilvl
       OR v_delay IS NULL
       OR v_delay <= 0 THEN
        LEAVE proc;
    END IF;

    /* tooltip DPS */
    SET v_cur_dps := ((IFNULL(v_dmg_min1,0.0) + IFNULL(v_dmg_max1,0.0)) / 2.0)
                     * 1000.0 / v_delay;

    IF v_cur_dps <= 0 THEN
        LEAVE proc;
    END IF;

    /* slot curve – epic 2H from Word doc: ISV = 1.64*ilvl + 11.2 */
    SET v_src_slotval := 1.64 * v_src_ilvl + 11.2;
    SET v_tgt_slotval := 1.64 * p_tgt_ilvl + 11.2;
    SET v_slot_ratio  := v_tgt_slotval / v_src_slotval;

    SET v_phys_dps_cur     := v_cur_dps;
    SET v_trade_src_dps    := 0.0;
    SET v_trade_tgt_dps    := 0.0;
    SET v_caster_minus_cur := 0.0;
    SET v_caster_minus_tgt := 0.0;

    /* caster weapons use DPS trade from the Word doc */
    IF v_caster_flag = 1 THEN
        SET v_trade_src_dps := GREATEST(v_src_ilvl - 60, 0);
        SET v_trade_tgt_dps := GREATEST(p_tgt_ilvl - 60, 0);

        /* current physical baseline = current DPS + traded DPS */
        SET v_phys_dps_cur := v_phys_dps_cur + v_trade_src_dps;
    END IF;

    /* physical DPS at target ilvl */
    SET v_phys_dps_tgt := GREATEST(v_phys_dps_cur * v_slot_ratio, 0.0);

    IF v_caster_flag = 1 THEN
        /* clamp trade so it never exceeds baseline */
        SET v_caster_minus_cur := LEAST(v_trade_src_dps, v_phys_dps_cur);
        SET v_caster_minus_tgt := LEAST(v_trade_tgt_dps, v_phys_dps_tgt);

        /* final caster DPS = baseline − target trade */
        SET v_tgt_dps := GREATEST(v_phys_dps_tgt - v_caster_minus_tgt, 0.0);
    ELSE
        /* physical weapons just follow baseline */
        SET v_tgt_dps := v_phys_dps_tgt;
    END IF;

    IF v_tgt_dps <= 0 THEN
        LEAVE proc;
    END IF;

    /* scale dmg_min/dmg_max by DPS ratio */
    SET v_new_dmg_min1 := v_dmg_min1 * (v_tgt_dps / v_cur_dps);
    SET v_new_dmg_max1 := v_dmg_max1 * (v_tgt_dps / v_cur_dps);

    IF p_apply = 1 THEN
        UPDATE lplusworld.item_template
        SET dmg_min1 = ROUND(v_new_dmg_min1, 1),
            dmg_max1 = ROUND(v_new_dmg_max1, 1)
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
END proc$$
DELIMITER ;
