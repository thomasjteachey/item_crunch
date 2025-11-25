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
  ADD COLUMN block_chance_pct  TINYINT UNSIGNED NOT NULL DEFAULT 0 AFTER dodge_pct$$

DROP PROCEDURE IF EXISTS helper.sp_seed_davidstats_items$$
CREATE PROCEDURE helper.sp_seed_davidstats_items()
BEGIN
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
  ) aura
  ON DUPLICATE KEY UPDATE magnitude_percent = aura.magnitude_percent;

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
  ) i
  JOIN helper.davidstats_seeded_auras a
    ON a.stat = i.stat AND a.magnitude = i.magnitude_percent;

  -- Rank aura requests per item
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_rn;
  CREATE TEMPORARY TABLE tmp_aura_rn AS
  SELECT entry, spellid, ROW_NUMBER() OVER (PARTITION BY entry ORDER BY ordinal, stat) AS rn
  FROM tmp_item_auras;

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

  -- Recount the primary stats so the StatsCount column stays in sync with any staged changes
  UPDATE helper.davidstats_items
  SET StatsCount =
    (stat_type1  <> 0 AND stat_value1  <> 0) +
    (stat_type2  <> 0 AND stat_value2  <> 0) +
    (stat_type3  <> 0 AND stat_value3  <> 0) +
    (stat_type4  <> 0 AND stat_value4  <> 0) +
    (stat_type5  <> 0 AND stat_value5  <> 0) +
    (stat_type6  <> 0 AND stat_value6  <> 0) +
    (stat_type7  <> 0 AND stat_value7  <> 0) +
    (stat_type8  <> 0 AND stat_value8  <> 0) +
    (stat_type9  <> 0 AND stat_value9  <> 0) +
    (stat_type10 <> 0 AND stat_value10 <> 0);

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
