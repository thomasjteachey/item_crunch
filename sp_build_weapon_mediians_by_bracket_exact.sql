CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_build_weapon_medians_by_bracket_exact`(
  IN p_quality_exact TINYINT UNSIGNED,  -- exact it.Quality (e.g., 4 = Epic)
  IN p_only_classic  TINYINT            -- 1 = require classic overlap (cm.item_template)
)
BEGIN
  /* target table */
  CREATE TABLE IF NOT EXISTS helper.weapon_median_dps_bracket (
    bracket     ENUM('1H','2H','RANGED') NOT NULL,
    quality     TINYINT UNSIGNED NOT NULL,
    ilvl        SMALLINT UNSIGNED NOT NULL,
    median_dps  DOUBLE NOT NULL,
    n           INT UNSIGNED NOT NULL,
    updated_at  DATETIME NOT NULL,
    PRIMARY KEY (bracket, quality, ilvl)
  ) ENGINE=InnoDB;

  /* source universe with bracket assignment */
  DROP TEMPORARY TABLE IF EXISTS tmp_wep_base;
  CREATE TEMPORARY TABLE tmp_wep_base AS
  SELECT
    it.entry,
    it.Quality                                   AS quality,
    it.ItemLevel                                 AS ilvl,
    it.subclass,
    it.caster,
    it.delay,
    /* DPS over both damage lines */
    (
      (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0))/2.0 +
      (COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0))/2.0
    ) / NULLIF(it.delay/1000.0,0)                AS dps,
    /* bracket: non-caster 1H; non-caster 2H plus staves; ranged guns/bows/xbows/wands */
    CASE
      WHEN it.caster = 0 AND it.subclass IN (0,4,7,15,13)
        THEN '1H'     /* Axe, Mace, Sword, Dagger, Fist */
      WHEN (it.caster = 0 AND it.subclass IN (1,5,6,8))
         OR it.subclass = 10
        THEN '2H'     /* 2H Axe, 2H Mace, Polearm, 2H Sword, Staff */
      WHEN it.subclass IN (2,3,18,19)
        THEN 'RANGED' /* Bow, Gun, Crossbow, Wand */
      ELSE NULL
    END AS bracket
  FROM lplusworld.item_template it
  /* classic overlap (optional) */
  LEFT JOIN classicmangos.item_template cm ON cm.entry = it.entry
  WHERE it.class = 2                 /* weapons */
    AND it.delay > 0
    AND (COALESCE(it.dmg_min1,0)+COALESCE(it.dmg_max1,0)+COALESCE(it.dmg_min2,0)+COALESCE(it.dmg_max2,0)) > 0
    AND it.Quality = p_quality_exact
    AND (p_only_classic = 0 OR cm.entry IS NOT NULL);

  /* exact (bracket,quality,ilvl) medians */
  DROP TEMPORARY TABLE IF EXISTS tmp_ranked;
  CREATE TEMPORARY TABLE tmp_ranked AS
  SELECT
    t.bracket, t.quality, t.ilvl, t.dps,
    ROW_NUMBER() OVER (PARTITION BY t.bracket, t.quality, t.ilvl ORDER BY t.dps) AS rn,
    COUNT(*)    OVER (PARTITION BY t.bracket, t.quality, t.ilvl)                 AS n
  FROM tmp_wep_base t
  WHERE t.bracket IS NOT NULL
    AND t.dps IS NOT NULL;

  /* replace rows for this quality */
  DELETE FROM helper.weapon_median_dps_bracket WHERE quality = p_quality_exact;

  INSERT INTO helper.weapon_median_dps_bracket (bracket, quality, ilvl, median_dps, n, updated_at)
  SELECT r.bracket, r.quality, r.ilvl,
         AVG(r.dps) AS median_dps,
         MAX(r.n)   AS n,
         NOW()
  FROM (
    SELECT bracket, quality, ilvl, dps, rn, n,
           FLOOR((n+1)/2) AS lo, CEIL((n+1)/2) AS hi
    FROM tmp_ranked
  ) r
  WHERE r.rn IN (r.lo, r.hi)
  GROUP BY r.bracket, r.quality, r.ilvl;

  /* preview */
  SELECT * FROM helper.weapon_median_dps_bracket
  WHERE quality = p_quality_exact
  ORDER BY bracket, ilvl;
END