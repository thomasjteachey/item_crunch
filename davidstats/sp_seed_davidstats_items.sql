-- Seed davidstats gear into lplusworld.item_template while wiring required aura spells
-- Percent auras are looked up in dbc.spell_lplus (cloned via helper.sp_seed_davidstats_auras when missing)
DELIMITER $$

DROP TABLE IF EXISTS helper.davidstats_items$$
CREATE TABLE helper.davidstats_items LIKE lplusworld.item_template$$

ALTER TABLE helper.davidstats_items
  ADD COLUMN hit_pct           TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER trueItemLevel,
  ADD COLUMN spell_hit_pct     TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER hit_pct,
  ADD COLUMN crit_pct          TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER spell_hit_pct,
  ADD COLUMN spell_crit_pct    TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER crit_pct,
  ADD COLUMN dodge_pct         TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER spell_crit_pct,
  ADD COLUMN block_chance_pct  TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER dodge_pct,
  ADD COLUMN stamina           SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER block_chance_pct,
  ADD COLUMN agility           SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER stamina,
  ADD COLUMN strength          SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER agility,
  ADD COLUMN intellect         SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER strength,
  ADD COLUMN spirit            SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER intellect,
  ADD COLUMN bonus_armor       SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER spirit,
  ADD COLUMN attack_power      SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER bonus_armor,
  ADD COLUMN ranged_attack_power SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER attack_power,
  ADD COLUMN spell_power       SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER ranged_attack_power,
  ADD COLUMN healing           SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER spell_power,
  ADD COLUMN mp5               SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER healing,
  ADD COLUMN defense           SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER mp5,
  ADD COLUMN block_value       SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER defense,
  ADD COLUMN spell_penetration SMALLINT UNSIGNED NOT NULL DEFAULT 0 AFTER block_value,
  ADD UNIQUE KEY uq_davidstats_identity (name)$$

CREATE TABLE IF NOT EXISTS helper.davidstats_custom_set_targets (
  class VARCHAR(64) NOT NULL,
  archetype VARCHAR(64) NOT NULL,
  slot VARCHAR(64) NOT NULL,
  stamina SMALLINT UNSIGNED DEFAULT NULL,
  agility SMALLINT UNSIGNED DEFAULT NULL,
  strength SMALLINT UNSIGNED DEFAULT NULL,
  intellect SMALLINT UNSIGNED DEFAULT NULL,
  spirit SMALLINT UNSIGNED DEFAULT NULL,
  bonus_armor SMALLINT UNSIGNED DEFAULT NULL,
  attack_power SMALLINT UNSIGNED DEFAULT NULL,
  ranged_attack_power SMALLINT UNSIGNED DEFAULT NULL,
  spell_power SMALLINT UNSIGNED DEFAULT NULL,
  healing SMALLINT UNSIGNED DEFAULT NULL,
  mp5 SMALLINT UNSIGNED DEFAULT NULL,
  defense SMALLINT UNSIGNED DEFAULT NULL,
  block_value SMALLINT UNSIGNED DEFAULT NULL,
  block_chance_pct SMALLINT UNSIGNED DEFAULT NULL,
  hit_pct SMALLINT UNSIGNED DEFAULT NULL,
  spell_hit_pct SMALLINT UNSIGNED DEFAULT NULL,
  crit_pct SMALLINT UNSIGNED DEFAULT NULL,
  spell_crit_pct SMALLINT UNSIGNED DEFAULT NULL,
  dodge_pct SMALLINT UNSIGNED DEFAULT NULL,
  spell_penetration SMALLINT UNSIGNED DEFAULT NULL
)$$

DROP PROCEDURE IF EXISTS helper.sp_seed_davidstats_items$$
CREATE PROCEDURE helper.sp_seed_davidstats_items()
BEGIN
  -- Assign entry IDs for any slots that are missing from the staging table
  DROP TEMPORARY TABLE IF EXISTS tmp_new_targets;
  CREATE TEMPORARY TABLE tmp_new_targets AS
  SELECT
    COALESCE((SELECT MAX(entry) FROM helper.davidstats_items), 99999)
      + ROW_NUMBER() OVER (ORDER BY t.class, t.archetype, t.slot) AS entry,
    CONCAT(t.slot, ' - ', t.class, ' ', t.archetype) AS name,
    CASE LOWER(t.slot)
      WHEN 'helm' THEN 1
      WHEN 'neck' THEN 2
      WHEN 'shoulders' THEN 3
      WHEN 'back' THEN 16
      WHEN 'chest' THEN 5
      WHEN 'waist' THEN 6
      WHEN 'legs' THEN 7
      WHEN 'feet' THEN 8
      WHEN 'wrist' THEN 9
      WHEN 'hands' THEN 10
      WHEN 'ring 1' THEN 11
      WHEN 'ring 2' THEN 11
      ELSE 0
    END AS inv_type,
    t.*
  FROM helper.davidstats_custom_set_targets t
  WHERE NOT EXISTS (
    SELECT 1 FROM helper.davidstats_items i
    WHERE i.name = CONCAT(t.slot, ' - ', t.class, ' ', t.archetype)
  );

  INSERT IGNORE INTO helper.davidstats_items (
    entry,
    name,
    AllowableClass,
    AllowableRace,
    InventoryType,
    Quality,
    Flags,
    FlagsExtra,
    BuyCount,
    BuyPrice,
    SellPrice,
    ItemLevel,
    RequiredLevel,
    stackable,
    StatsCount,
    armor,
    hit_pct,
    spell_hit_pct,
    crit_pct,
    spell_crit_pct,
    dodge_pct,
    block_chance_pct,
    stamina,
    agility,
    strength,
    intellect,
    spirit,
    bonus_armor,
    attack_power,
    ranged_attack_power,
    spell_power,
    healing,
    mp5,
    defense,
    block_value,
    spell_penetration
  )
  SELECT
    entry,
    name,
    -1 AS AllowableClass,
    -1 AS AllowableRace,
    inv_type AS InventoryType,
    4 AS Quality,
    0 AS Flags,
    0 AS FlagsExtra,
    1 AS BuyCount,
    0 AS BuyPrice,
    0 AS SellPrice,
    0 AS ItemLevel,
    0 AS RequiredLevel,
    1 AS stackable,
    0 AS StatsCount,
    COALESCE(bonus_armor, 0) AS armor,
    COALESCE(hit_pct, 0),
    COALESCE(spell_hit_pct, 0),
    COALESCE(crit_pct, 0),
    COALESCE(spell_crit_pct, 0),
    COALESCE(dodge_pct, 0),
    COALESCE(block_chance_pct, 0),
    COALESCE(stamina, 0),
    COALESCE(agility, 0),
    COALESCE(strength, 0),
    COALESCE(intellect, 0),
    COALESCE(spirit, 0),
    COALESCE(bonus_armor, 0),
    COALESCE(attack_power, 0),
    COALESCE(ranged_attack_power, 0),
    COALESCE(spell_power, 0),
    COALESCE(healing, 0),
    COALESCE(mp5, 0),
    COALESCE(defense, 0),
    COALESCE(block_value, 0),
    COALESCE(spell_penetration, 0)
  FROM tmp_new_targets;

  -- Map requested stat columns into stat_type#/stat_value# slots for the new targets
  DROP TEMPORARY TABLE IF EXISTS tmp_new_stats;
  CREATE TEMPORARY TABLE tmp_new_stats AS
  SELECT entry,
         ROW_NUMBER() OVER (PARTITION BY entry ORDER BY stat_order) AS rn,
         stat_type,
         stat_value
  FROM (
    SELECT t.entry,
           m.stat_order,
           m.stat_type,
           CASE m.column_name
             WHEN 'stamina'            THEN t.stamina
             WHEN 'agility'            THEN t.agility
             WHEN 'strength'           THEN t.strength
             WHEN 'intellect'          THEN t.intellect
             WHEN 'spirit'             THEN t.spirit
              WHEN 'attack_power'       THEN t.attack_power
              WHEN 'ranged_attack_power' THEN t.ranged_attack_power
              WHEN 'mp5'                THEN t.mp5
             WHEN 'spell_penetration'  THEN t.spell_penetration
           END AS stat_value
    FROM tmp_new_targets t
    JOIN (
      SELECT 1  AS stat_order, 7  AS stat_type, 'stamina'             AS column_name UNION ALL
      SELECT 2  AS stat_order, 3  AS stat_type, 'agility'             AS column_name UNION ALL
      SELECT 3  AS stat_order, 4  AS stat_type, 'strength'            AS column_name UNION ALL
      SELECT 4  AS stat_order, 5  AS stat_type, 'intellect'           AS column_name UNION ALL
      SELECT 5  AS stat_order, 6  AS stat_type, 'spirit'              AS column_name UNION ALL
      SELECT 6  AS stat_order, 38 AS stat_type, 'attack_power'        AS column_name UNION ALL
      SELECT 7  AS stat_order, 39 AS stat_type, 'ranged_attack_power' AS column_name UNION ALL
      SELECT 8  AS stat_order, 43 AS stat_type, 'mp5'                 AS column_name UNION ALL
      SELECT 9  AS stat_order, 42 AS stat_type, 'spell_penetration'   AS column_name
    ) m ON TRUE
  ) s
  WHERE COALESCE(stat_value, 0) > 0;

  UPDATE helper.davidstats_items i
  JOIN (SELECT entry, COUNT(*) AS cnt FROM tmp_new_stats GROUP BY entry) s
    ON i.entry = s.entry
   AND EXISTS (SELECT 1 FROM tmp_new_targets t WHERE t.entry = i.entry)
  SET i.StatsCount = s.cnt;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 1
  SET i.stat_type1 = s.stat_type, i.stat_value1 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 2
  SET i.stat_type2 = s.stat_type, i.stat_value2 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 3
  SET i.stat_type3 = s.stat_type, i.stat_value3 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 4
  SET i.stat_type4 = s.stat_type, i.stat_value4 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 5
  SET i.stat_type5 = s.stat_type, i.stat_value5 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 6
  SET i.stat_type6 = s.stat_type, i.stat_value6 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 7
  SET i.stat_type7 = s.stat_type, i.stat_value7 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 8
  SET i.stat_type8 = s.stat_type, i.stat_value8 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 9
  SET i.stat_type9 = s.stat_type, i.stat_value9 = s.stat_value;

  UPDATE helper.davidstats_items i
  JOIN tmp_new_stats s ON i.entry = s.entry AND s.rn = 10
  SET i.stat_type10 = s.stat_type, i.stat_value10 = s.stat_value;

  -- Capture any new aura magnitudes from the staging rows so they exist before we assign spells
  INSERT IGNORE INTO helper.davidstats_required_auras (stat, magnitude_percent)
  SELECT stat, magnitude_percent
  FROM (
    SELECT 'hit_pct' stat, hit_pct magnitude_percent FROM helper.davidstats_items WHERE hit_pct > 0
    UNION ALL
    SELECT 'spell_hit_pct', spell_hit_pct FROM helper.davidstats_items WHERE spell_hit_pct > 0
    UNION ALL
    SELECT 'crit_pct', crit_pct FROM helper.davidstats_items WHERE crit_pct > 0
    UNION ALL
    SELECT 'spell_crit_pct', spell_crit_pct FROM helper.davidstats_items WHERE spell_crit_pct > 0
    UNION ALL
    SELECT 'dodge_pct', dodge_pct FROM helper.davidstats_items WHERE dodge_pct > 0
    UNION ALL
    SELECT 'block_chance_pct', block_chance_pct FROM helper.davidstats_items WHERE block_chance_pct > 0
    UNION ALL
    SELECT 'healing', healing FROM helper.davidstats_items WHERE healing > 0
    UNION ALL
    SELECT 'spell_power', spell_power FROM helper.davidstats_items WHERE spell_power > 0
    UNION ALL
    SELECT 'block_value', block_value FROM helper.davidstats_items WHERE block_value > 0
    UNION ALL
    SELECT 'defense', defense FROM helper.davidstats_items WHERE defense > 0
  ) aura
  ON DUPLICATE KEY UPDATE magnitude_percent = VALUES(magnitude_percent);

  -- Ensure the aura spells exist (reuses exact matches or clones the closest)
  CALL helper.sp_seed_davidstats_auras();

  DROP TEMPORARY TABLE IF EXISTS tmp_num5;
  CREATE TEMPORARY TABLE tmp_num5(n TINYINT PRIMARY KEY) ENGINE=Memory;
  INSERT INTO tmp_num5 VALUES (1),(2),(3),(4),(5);

  -- Flatten requested aura spells per item in a deterministic order
  DROP TEMPORARY TABLE IF EXISTS tmp_item_auras;
  CREATE TEMPORARY TABLE tmp_item_auras AS
  SELECT i.entry, i.stat, i.magnitude_percent, a.spell_id AS spellid, i.ordinal
  FROM (
    SELECT entry, 'hit_pct' stat, hit_pct magnitude_percent, 1 AS ordinal FROM helper.davidstats_items WHERE hit_pct > 0
    UNION ALL
    SELECT entry, 'spell_hit_pct', spell_hit_pct, 2 FROM helper.davidstats_items WHERE spell_hit_pct > 0
    UNION ALL
    SELECT entry, 'crit_pct', crit_pct, 3 FROM helper.davidstats_items WHERE crit_pct > 0
    UNION ALL
    SELECT entry, 'spell_crit_pct', spell_crit_pct, 4 FROM helper.davidstats_items WHERE spell_crit_pct > 0
    UNION ALL
    SELECT entry, 'dodge_pct', dodge_pct, 5 FROM helper.davidstats_items WHERE dodge_pct > 0
    UNION ALL
    SELECT entry, 'block_chance_pct', block_chance_pct, 6 FROM helper.davidstats_items WHERE block_chance_pct > 0
    UNION ALL
    SELECT entry, 'block_value', block_value, 7 FROM helper.davidstats_items WHERE block_value > 0
    UNION ALL
    SELECT entry, 'defense', defense, 8 FROM helper.davidstats_items WHERE defense > 0
    UNION ALL
    SELECT entry, 'healing', healing, 9 FROM helper.davidstats_items WHERE healing > 0
    UNION ALL
    SELECT entry, 'spell_power', spell_power, 10 FROM helper.davidstats_items WHERE spell_power > 0
  ) i
  JOIN helper.davidstats_seeded_auras a
    ON a.stat = i.stat AND a.magnitude = i.magnitude_percent;

  -- Remove duplicate spell IDs per item so each spell is stamped at most once
  DROP TEMPORARY TABLE IF EXISTS tmp_unique_item_auras;
  CREATE TEMPORARY TABLE tmp_unique_item_auras AS
  SELECT entry, spellid, MIN(ordinal) AS ordinal, MIN(stat) AS stat
  FROM tmp_item_auras
  GROUP BY entry, spellid;

  -- Rank aura requests per item
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_rn;
  CREATE TEMPORARY TABLE tmp_aura_rn AS
  SELECT entry, spellid, ROW_NUMBER() OVER (PARTITION BY entry ORDER BY ordinal, stat) AS rn
  FROM tmp_unique_item_auras;

  -- Identify open spell slots (zeroed) on each staged item and rank them
  DROP TEMPORARY TABLE IF EXISTS tmp_free_slots;
  CREATE TEMPORARY TABLE tmp_free_slots AS
  SELECT entry, slot, ROW_NUMBER() OVER (PARTITION BY entry ORDER BY slot) AS rn
  FROM (
    SELECT i.entry, n.n AS slot,
           CASE n.n
             WHEN 1 THEN i.spellid_1
             WHEN 2 THEN i.spellid_2
             WHEN 3 THEN i.spellid_3
             WHEN 4 THEN i.spellid_4
             WHEN 5 THEN i.spellid_5
           END AS spellid
    FROM helper.davidstats_items i
    JOIN tmp_num5 n
  ) z
  WHERE z.spellid = 0;

  -- Pair aura requests to free slots in order
  DROP TEMPORARY TABLE IF EXISTS tmp_slot_assign;
  CREATE TEMPORARY TABLE tmp_slot_assign AS
  SELECT a.entry, f.slot, a.spellid
  FROM tmp_aura_rn a
  JOIN tmp_free_slots f
    ON a.entry = f.entry AND a.rn = f.rn;

  -- Stamp the chosen aura spells into the staged items
  UPDATE helper.davidstats_items i
  JOIN tmp_slot_assign a ON i.entry = a.entry AND a.slot = 1
  SET i.spellid_1 = a.spellid;

  UPDATE helper.davidstats_items i
  JOIN tmp_slot_assign a ON i.entry = a.entry AND a.slot = 2
  SET i.spellid_2 = a.spellid;

  UPDATE helper.davidstats_items i
  JOIN tmp_slot_assign a ON i.entry = a.entry AND a.slot = 3
  SET i.spellid_3 = a.spellid;

  UPDATE helper.davidstats_items i
  JOIN tmp_slot_assign a ON i.entry = a.entry AND a.slot = 4
  SET i.spellid_4 = a.spellid;

  UPDATE helper.davidstats_items i
  JOIN tmp_slot_assign a ON i.entry = a.entry AND a.slot = 5
  SET i.spellid_5 = a.spellid;

  -- Move the staged rows into the live item_template, ignoring the staging-only aura columns
  REPLACE INTO lplusworld.item_template (
    entry,class,subclass,SoundOverrideSubclass,name,displayid,Quality,Flags,FlagsExtra,BuyCount,BuyPrice,SellPrice,InventoryType,
    AllowableClass,AllowableRace,ItemLevel,RequiredLevel,RequiredSkill,RequiredSkillRank,requiredspell,requiredhonorrank,
    RequiredCityRank,RequiredReputationFaction,RequiredReputationRank,maxcount,stackable,ContainerSlots,StatsCount,
    stat_type1,stat_value1,stat_type2,stat_value2,stat_type3,stat_value3,stat_type4,stat_value4,stat_type5,stat_value5,
    stat_type6,stat_value6,stat_type7,stat_value7,stat_type8,stat_value8,stat_type9,stat_value9,stat_type10,stat_value10,
    ScalingStatDistribution,ScalingStatValue,dmg_min1,dmg_max1,dmg_type1,dmg_min2,dmg_max2,dmg_type2,armor,holy_res,fire_res,
    nature_res,frost_res,shadow_res,arcane_res,delay,ammo_type,RangedModRange,
    spellid_1,spelltrigger_1,spellcharges_1,spellppmRate_1,spellcooldown_1,spellcategory_1,spellcategorycooldown_1,
    spellid_2,spelltrigger_2,spellcharges_2,spellppmRate_2,spellcooldown_2,spellcategory_2,spellcategorycooldown_2,
    spellid_3,spelltrigger_3,spellcharges_3,spellppmRate_3,spellcooldown_3,spellcategory_3,spellcategorycooldown_3,
    spellid_4,spelltrigger_4,spellcharges_4,spellppmRate_4,spellcooldown_4,spellcategory_4,spellcategorycooldown_4,
    spellid_5,spelltrigger_5,spellcharges_5,spellppmRate_5,spellcooldown_5,spellcategory_5,spellcategorycooldown_5,
    bonding,description,PageText,LanguageID,PageMaterial,startquest,lockid,Material,sheath,RandomProperty,RandomSuffix,block,
    itemset,MaxDurability,area,Map,BagFamily,TotemCategory,socketColor_1,socketContent_1,socketColor_2,socketContent_2,
    socketColor_3,socketContent_3,socketBonus,GemProperties,RequiredDisenchantSkill,ArmorDamageModifier,duration,
    ItemLimitCategory,HolidayId,scriptName,DisenchantID,FoodType,minMoneyLoot,maxMoneyLoot,flagsCustom,VerifiedBuild,
    caster,feral,hunter,chanceonhit,healer,trueItemLevel
  )
  SELECT
    entry,class,subclass,SoundOverrideSubclass,name,displayid,Quality,Flags,FlagsExtra,BuyCount,BuyPrice,SellPrice,InventoryType,
    AllowableClass,AllowableRace,ItemLevel,RequiredLevel,RequiredSkill,RequiredSkillRank,requiredspell,requiredhonorrank,
    RequiredCityRank,RequiredReputationFaction,RequiredReputationRank,maxcount,stackable,ContainerSlots,StatsCount,
    stat_type1,stat_value1,stat_type2,stat_value2,stat_type3,stat_value3,stat_type4,stat_value4,stat_type5,stat_value5,
    stat_type6,stat_value6,stat_type7,stat_value7,stat_type8,stat_value8,stat_type9,stat_value9,stat_type10,stat_value10,
    ScalingStatDistribution,ScalingStatValue,dmg_min1,dmg_max1,dmg_type1,dmg_min2,dmg_max2,dmg_type2,armor,holy_res,fire_res,
    nature_res,frost_res,shadow_res,arcane_res,delay,ammo_type,RangedModRange,
    spellid_1,spelltrigger_1,spellcharges_1,spellppmRate_1,spellcooldown_1,spellcategory_1,spellcategorycooldown_1,
    spellid_2,spelltrigger_2,spellcharges_2,spellppmRate_2,spellcooldown_2,spellcategory_2,spellcategorycooldown_2,
    spellid_3,spelltrigger_3,spellcharges_3,spellppmRate_3,spellcooldown_3,spellcategory_3,spellcategorycooldown_3,
    spellid_4,spelltrigger_4,spellcharges_4,spellppmRate_4,spellcooldown_4,spellcategory_4,spellcategorycooldown_4,
    spellid_5,spelltrigger_5,spellcharges_5,spellppmRate_5,spellcooldown_5,spellcategory_5,spellcategorycooldown_5,
    bonding,description,PageText,LanguageID,PageMaterial,startquest,lockid,Material,sheath,RandomProperty,RandomSuffix,block,
    itemset,MaxDurability,area,Map,BagFamily,TotemCategory,socketColor_1,socketContent_1,socketColor_2,socketContent_2,
    socketColor_3,socketContent_3,socketBonus,GemProperties,RequiredDisenchantSkill,ArmorDamageModifier,duration,
    ItemLimitCategory,HolidayId,scriptName,DisenchantID,FoodType,minMoneyLoot,maxMoneyLoot,flagsCustom,VerifiedBuild,
    caster,feral,hunter,chanceonhit,healer,trueItemLevel
  FROM helper.davidstats_items;
END$$

DELIMITER ;
