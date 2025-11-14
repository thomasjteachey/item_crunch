CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_populate_weapon_medians`(
    IN p_subclass        TINYINT UNSIGNED,   -- e.g. 8 = 2H Sword
    IN p_ilvl_window     INT,                -- ±iLvl window (e.g., 2)
    IN p_quality_exact   TINYINT UNSIGNED,   -- exact item_template.Quality (e.g., 4 = Epic)
    IN p_only_classic    TINYINT,            -- 1 = require classic overlap
    IN p_exclude_caster  TINYINT,            -- 1 = exclude caster=1
    IN p_exclude_feral   TINYINT             -- 1 = exclude feral=1
)
BEGIN
    /* Ensure target table exists with QUALITY dimension */
    CREATE TABLE IF NOT EXISTS helper.weapon_median_dps_by_ilvl (
      subclass    TINYINT UNSIGNED NOT NULL,
      quality     TINYINT UNSIGNED NOT NULL,
      ilvl        SMALLINT UNSIGNED NOT NULL,
      median_dps  DOUBLE NOT NULL,
      n           INT UNSIGNED NOT NULL,
      updated_at  DATETIME NOT NULL,
      PRIMARY KEY (subclass, quality, ilvl)
    );

    /* If table exists but lacks 'quality', patch it */
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.COLUMNS
        WHERE table_schema='helper'
          AND table_name='weapon_median_dps_by_ilvl'
          AND column_name='quality'
    ) THEN
        ALTER TABLE helper.weapon_median_dps_by_ilvl
          ADD COLUMN quality TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER subclass,
          DROP PRIMARY KEY,
          ADD PRIMARY KEY (subclass, quality, ilvl);
    END IF;

    /* Source items (exact quality) */
    DROP TEMPORARY TABLE IF EXISTS tmp_items;
    CREATE TEMPORARY TABLE tmp_items AS
    SELECT it.entry, it.ItemLevel AS ilvl,
           (
             (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0))/2.0 +
             (COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0))/2.0
           ) / NULLIF(it.delay/1000.0,0) AS dps
    FROM lplusworld.item_template it
    LEFT JOIN classicmangos.item_template cm ON cm.entry = it.entry
    WHERE it.class = 2
      AND it.subclass = p_subclass
      AND it.Quality = p_quality_exact          -- << exact match
      AND it.delay > 0
      AND (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0)+COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0)) > 0
      AND (p_only_classic = 0 OR cm.entry IS NOT NULL)
      AND (p_exclude_caster = 0 OR COALESCE(it.caster,0) = 0)
      AND (p_exclude_feral  = 0 OR COALESCE(it.feral,0)  = 0);

    DROP TEMPORARY TABLE IF EXISTS tmp_anchors;
    CREATE TEMPORARY TABLE tmp_anchors AS
    SELECT DISTINCT ilvl FROM tmp_items;

    DROP TEMPORARY TABLE IF EXISTS tmp_windowed;
    CREATE TEMPORARY TABLE tmp_windowed AS
    SELECT a.ilvl, i.entry, i.dps
    FROM tmp_anchors a
    JOIN tmp_items i
      ON i.ilvl BETWEEN GREATEST(0, CAST(a.ilvl AS SIGNED)-p_ilvl_window)
                    AND (CAST(a.ilvl AS SIGNED)+p_ilvl_window);

    DROP TEMPORARY TABLE IF EXISTS tmp_ranked;
    CREATE TEMPORARY TABLE tmp_ranked AS
    SELECT ilvl, entry, dps,
           ROW_NUMBER() OVER (PARTITION BY ilvl ORDER BY dps) AS rn,
           COUNT(*)    OVER (PARTITION BY ilvl)               AS n
    FROM tmp_windowed;

    /* Replace medians for this (subclass, quality) */
    DELETE FROM helper.weapon_median_dps_by_ilvl
    WHERE subclass = p_subclass AND quality = p_quality_exact;

    INSERT INTO helper.weapon_median_dps_by_ilvl (subclass, quality, ilvl, median_dps, n, updated_at)
    SELECT p_subclass, p_quality_exact, r.ilvl, AVG(r.dps), MAX(r.n), NOW()
    FROM (
      SELECT ilvl, entry, dps, rn, n,
             FLOOR((n+1)/2) AS lo, CEIL((n+1)/2) AS hi
      FROM tmp_ranked
    ) r
    WHERE r.rn IN (r.lo, r.hi)
    GROUP BY r.ilvl;

    /* Preview */
    SELECT * FROM helper.weapon_median_dps_by_ilvl
    WHERE subclass = p_subclass AND quality = p_quality_exact
    ORDER BY ilvl;
END