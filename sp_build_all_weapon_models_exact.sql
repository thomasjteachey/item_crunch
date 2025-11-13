CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_build_all_weapon_models_exact`(
    IN p_quality_exact   TINYINT,   -- exact it.Quality (e.g., 4 = Epic)
    IN p_ilvl_window     INT,       -- ±iLvl window (e.g., 2)
    IN p_only_classic    TINYINT,   -- 1 = require Classic overlap
    IN p_exclude_caster  TINYINT,   -- 1 = exclude caster=1
    IN p_exclude_feral   TINYINT,   -- 1 = exclude feral=1
    IN p_k_mad           DOUBLE,    -- <=0 disables MAD
    IN p_weight_by_n     TINYINT,   -- 1 = weight linear fit by 'n'
    IN p_pref_thresh     DOUBLE,    -- advantage to prefer quadratic
    IN p_clear_mode      TINYINT    -- 0=no clear, 1=clear this quality, 2=truncate all
)
BEGIN
    /* DECLAREs first */
    DECLARE v_subclass TINYINT UNSIGNED;
    DECLARE done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT t.subclass FROM tmp_all_subclasses t ORDER BY t.subclass;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    /* optional clearing */
    IF p_clear_mode = 2 THEN
        TRUNCATE TABLE helper.weapon_median_dps_by_ilvl;
        TRUNCATE TABLE helper.weapon_dps_ilvl_linear_fit;
        TRUNCATE TABLE helper.weapon_dps_ilvl_quadratic_fit;
        TRUNCATE TABLE helper.weapon_dps_ilvl_model_selected;
    ELSEIF p_clear_mode = 1 THEN
        DELETE FROM helper.weapon_median_dps_by_ilvl          WHERE quality = p_quality_exact;
        DELETE FROM helper.weapon_dps_ilvl_linear_fit         WHERE quality = p_quality_exact;
        DELETE FROM helper.weapon_dps_ilvl_quadratic_fit      WHERE quality = p_quality_exact;
        DELETE FROM helper.weapon_dps_ilvl_model_selected     WHERE quality = p_quality_exact;
    END IF;

    /* discover subclasses for this EXACT quality under filters */
    DROP TEMPORARY TABLE IF EXISTS tmp_all_subclasses;
    CREATE TEMPORARY TABLE tmp_all_subclasses AS
    SELECT DISTINCT it.subclass
    FROM lplusworld.item_template it
    LEFT JOIN classicmangos.item_template cm ON cm.entry = it.entry
    WHERE it.class = 2
      AND it.delay > 0
      AND (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0)+COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0)) > 0
      AND it.Quality = p_quality_exact
      AND (p_only_classic = 0 OR cm.entry IS NOT NULL)
      AND (p_exclude_caster = 0 OR COALESCE(it.caster,0) = 0)
      AND (p_exclude_feral  = 0 OR COALESCE(it.feral,0)  = 0);

    /* loop subclasses -> medians -> fits (exact quality) */
    OPEN cur;
      readloop: LOOP
        FETCH cur INTO v_subclass;
        IF done = 1 THEN LEAVE readloop; END IF;

        CALL helper.sp_populate_weapon_medians(
          v_subclass, p_ilvl_window, p_quality_exact,
          p_only_classic, p_exclude_caster, p_exclude_feral
        );

        IF (SELECT COUNT(*) FROM helper.weapon_median_dps_by_ilvl
            WHERE subclass=v_subclass AND quality=p_quality_exact) > 0 THEN
          CALL helper.sp_fit_weapon_ilvl_model(
            v_subclass, p_quality_exact, p_k_mad, p_weight_by_n, p_pref_thresh
          );
        END IF;
      END LOOP;
    CLOSE cur;

    /* summary */
    SELECT ms.subclass, ms.quality, ms.chosen_model, ms.r2,
           ms.x_min, ms.x_max, ms.n_points, ms.updated_at
    FROM helper.weapon_dps_ilvl_model_selected ms
    JOIN tmp_all_subclasses t ON t.subclass = ms.subclass
    WHERE ms.quality = p_quality_exact
    ORDER BY ms.subclass;
END