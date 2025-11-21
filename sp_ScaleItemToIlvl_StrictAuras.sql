CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleItemToIlvl_StrictAuras`(
  IN p_entry INT UNSIGNED,
  IN p_target_ilvl INT UNSIGNED,
  IN p_apply TINYINT(1),        -- 0=dry run, 1=apply changes
  IN p_scale_auras TINYINT(1),  -- 0=skip aura scaling, nonzero=scale auras
  IN p_keep_bonus_armor TINYINT(1) -- nonzero keeps bonus armor fixed
)
proc: BEGIN
  DECLARE v_prev_defer_estimate TINYINT(1);
  DECLARE v_after INT;

  /* defer default estimator while we juggle strict budget rules */
  SET v_prev_defer_estimate := @ilvl_defer_estimate;
  SET @ilvl_defer_estimate := 1;

  /* pin unknown auras and caster weapons to the advertised ilvl before scaling */
  CALL helper.sp_EstimateItemLevels_StrictAuras();

  /* baseline greedy scale with the requested aura handling */
  CALL helper.sp_ScaleItemToIlvl_SimpleGreedy(p_entry, p_target_ilvl, p_apply, p_scale_auras, p_keep_bonus_armor);

  /* recompute true ilvl with strict assumptions */
  CALL helper.sp_EstimateItemLevels_StrictAuras();

  /* if we still miss the target by more than 1 ilvl, nudge once */
  IF p_apply = 1 THEN
    SELECT CAST(IFNULL(it.trueItemLevel, it.ItemLevel) AS SIGNED)
      INTO v_after
    FROM lplusworld.item_template it
    WHERE it.entry = p_entry;

    SET @delta := v_after - p_target_ilvl;
    IF ABS(@delta) > 1 THEN
      SET @nudge_target := p_target_ilvl - SIGN(@delta);
      CALL helper.sp_ScaleItemToIlvl_SimpleGreedy(p_entry, @nudge_target, p_apply, p_scale_auras, p_keep_bonus_armor);
      CALL helper.sp_EstimateItemLevels_StrictAuras();
    END IF;
  END IF;

  SET @ilvl_defer_estimate := v_prev_defer_estimate;
END
