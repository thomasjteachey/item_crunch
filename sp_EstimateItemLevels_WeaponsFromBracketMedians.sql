CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_EstimateItemLevels_WeaponsFromBracketMedians`()
BEGIN
  /* 1) Eligible weapons + DPS + bracket */
  DROP TEMPORARY TABLE IF EXISTS tmp_weps;
  CREATE TEMPORARY TABLE tmp_weps AS
  SELECT
    it.entry,
    it.Quality AS quality,
    it.subclass,
    CASE
      WHEN COALESCE(it.caster,0) = 1 THEN NULL
      WHEN it.subclass IN (0,4,7,15,13) THEN '1H'      /* 1H Axe/Mace/Sword, Dagger, Fist */
      WHEN it.subclass IN (1,5,6,8)     THEN '2H'      /* 2H Axe/Mace, Polearm, 2H Sword (no Staves) */
      WHEN it.subclass IN (2,3,18)      THEN 'RANGED'  /* Bow, Gun, Crossbow */
      ELSE NULL
    END AS bracket,
    (
      (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0))/2.0 +
      (COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0))/2.0
    ) / NULLIF(it.delay/1000.0,0) AS cur_dps
  FROM lplusworld.item_template it
  WHERE it.class = 2
    AND it.delay > 0
    AND (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0)+COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0)) > 0;

  DELETE FROM tmp_weps WHERE bracket IS NULL OR cur_dps IS NULL;

  /* 2) nearest-below by DPS */
  DROP TEMPORARY TABLE IF EXISTS tmp_below;
  CREATE TEMPORARY TABLE tmp_below AS
  WITH c AS (
    SELECT w.entry,
           CAST(m.ilvl AS SIGNED)            AS ilvl_low,
           m.median_dps                      AS dps_low,
           ROW_NUMBER() OVER (
             PARTITION BY w.entry
             ORDER BY m.median_dps DESC, m.ilvl DESC
           ) AS rn
    FROM tmp_weps w
    JOIN helper.weapon_median_dps_bracket m
      ON m.bracket=w.bracket AND m.quality=w.quality
     AND m.median_dps <= w.cur_dps
  )
  SELECT entry, ilvl_low, dps_low FROM c WHERE rn=1;

  /* 3) nearest-above by DPS */
  DROP TEMPORARY TABLE IF EXISTS tmp_above;
  CREATE TEMPORARY TABLE tmp_above AS
  WITH c AS (
    SELECT w.entry,
           CAST(m.ilvl AS SIGNED)            AS ilvl_high,
           m.median_dps                      AS dps_high,
           ROW_NUMBER() OVER (
             PARTITION BY w.entry
             ORDER BY m.median_dps ASC, m.ilvl ASC
           ) AS rn
    FROM tmp_weps w
    JOIN helper.weapon_median_dps_bracket m
      ON m.bracket=w.bracket AND m.quality=w.quality
     AND m.median_dps >= w.cur_dps
  )
  SELECT entry, ilvl_high, dps_high FROM c WHERE rn=1;

  /* 4) interpolate / nearest */
  DROP TEMPORARY TABLE IF EXISTS tmp_est;
  CREATE TEMPORARY TABLE tmp_est AS
  SELECT
    w.entry, w.cur_dps, w.quality, w.bracket,
    b.ilvl_low,  b.dps_low,
    a.ilvl_high, a.dps_high,
    CASE
      WHEN a.dps_high IS NOT NULL AND b.dps_low IS NOT NULL AND a.dps_high <> b.dps_low
        THEN CAST(b.ilvl_low AS DECIMAL(10,6))
           + (w.cur_dps - b.dps_low)
             * (CAST(a.ilvl_high AS DECIMAL(10,6)) - CAST(b.ilvl_low AS DECIMAL(10,6)))
             / (a.dps_high - b.dps_low)
      WHEN a.dps_high IS NOT NULL AND b.dps_low IS NOT NULL
        THEN (CAST(a.ilvl_high AS DECIMAL(10,6)) + CAST(b.ilvl_low AS DECIMAL(10,6)))/2.0
      WHEN b.dps_low  IS NOT NULL THEN CAST(b.ilvl_low  AS DECIMAL(10,6))
      WHEN a.dps_high IS NOT NULL THEN CAST(a.ilvl_high AS DECIMAL(10,6))
      ELSE NULL
    END AS est_ilvl
  FROM tmp_weps w
  LEFT JOIN tmp_below b ON b.entry = w.entry
  LEFT JOIN tmp_above a ON a.entry = w.entry;

  /* 5) write back */
  UPDATE lplusworld.item_template it
  JOIN tmp_est e ON e.entry = it.entry
  SET it.trueItemLevel = ROUND(e.est_ilvl)
  WHERE e.est_ilvl IS NOT NULL;

  /* 6) summary */
  SELECT COUNT(*) AS items_seen,
         SUM(e.est_ilvl IS NOT NULL) AS items_estimated,
         SUM(e.est_ilvl IS NULL)     AS items_skipped
  FROM tmp_est e;
END