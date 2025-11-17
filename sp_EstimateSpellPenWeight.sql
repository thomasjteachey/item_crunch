CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_EstimateSpellPenWeight`()
BEGIN
  /* ===== Known Stat Weights (match Item level.docx) ===== */
  SET @W_PRIMARY    := 230;   -- STR/AGI/STA/INT/SPI (stat_type 3..7)
  SET @W_ARMOR      := 0;     -- base armor excluded
  SET @W_BONUSARMOR := 22;    -- ArmorDamageModifier "bonus armor"
  SET @W_RESIST     := 230;   -- per-school resists

  SET @W_AP      := 115;      -- Attack Power (AP) only
  SET @W_AP_VERSUS := 76;     -- Attack Power vs creature types
  SET @W_RAP     := 92;       -- Ranged Attack Power (RAP) only
  SET @W_HEAL    := 100;      -- +Healing (not paired with +damage)
  SET @W_SD_ALL  := 192;      -- Spell Power (+damage&healing all schools)
  SET @W_SD_ONE  := 159;      -- +Damage one school
  SET @W_HIT     := 2200;     -- Melee/Ranged Hit %
  SET @W_SPHIT   := 2500;     -- Spell Hit %
  SET @W_CRIT    := 3200;     -- Melee/Ranged Crit %
  SET @W_SPCRIT  := 2600;     -- Spell Crit %
  SET @W_BLOCKVALUE := 150;   -- Block Value
  SET @W_BLOCK   := 1300;     -- Block Chance %
  SET @W_PARRY   := 3600;     -- Parry Chance %
  SET @W_DODGE   := 2500;     -- Dodge Chance %
  SET @W_DEFENSE := 345;      -- Defense skill
  SET @W_WEAPON_SKILL_OTHER := 550;   -- Weapon skill (non-dagger)
  SET @W_WEAPON_SKILL_DAGGER := 720;  -- Weapon skill (dagger)
  SET @W_DAMAGE_SHIELD := 720;        -- Damage shield
  SET @W_MP5     := 550;      -- Mana per 5s
  SET @W_HP5     := 550;      -- Health per 5s
  SET @WEAPON_DPS_TRADE_SD := 4.0;    -- caster weapon spell power trade budget

  /* ===== DBC Aura constants ===== */
  SET @AURA_AP := 99;    SET @AURA_RAP := 124;
  SET @AURA_AP_VERSUS := 102; SET @AURA_RAP_VERSUS := 131;
  SET @AURA_HIT := 54;   SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57; SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_MELEE := 308; SET @AURA_CRIT_RANGED := 290; SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_BLOCKVALUE := 158; SET @AURA_BLOCKVALUE_PCT := 150;
  SET @AURA_BLOCK := 51; SET @AURA_PARRY := 47; SET @AURA_DODGE := 49;
  SET @AURA_DAMAGE_SHIELD := 15;
  SET @AURA_MOD_SKILL := 30; SET @AURA_MOD_SKILL_TALENT := 98;
  SET @AURA_SD := 13;    SET @MASK_SD_ALL := 126;
  SET @AURA_HEAL1 := 115; SET @AURA_HEAL2 := 135;
  SET @AURA_MP5 := 85;   SET @AURA_HP5 := 83;
  SET @AURA_SPELL_PEN := 123;

  SET @SKILL_DEFENSE := 95;
  SET @SKILL_DAGGERS := 173;

  SET @STAT_SPELL_PEN := 25;  -- ITEM_MOD_SPELL_PENETRATION

  /* ===== Collect Classic spell penetration items ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_entries;
  CREATE TEMPORARY TABLE tmp_spell_pen_entries(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    quality TINYINT UNSIGNED NOT NULL,
    inventory_type TINYINT UNSIGNED NOT NULL,
    slot_mod DOUBLE NOT NULL,
    ilvl INT UNSIGNED NOT NULL,
    item_slot_value DOUBLE NOT NULL,
    target_term_sum DOUBLE NOT NULL,
    spell_pen_points DOUBLE NOT NULL,
    spell_pen_pow DOUBLE NOT NULL,
    spell_pen_count INT NOT NULL
  ) ENGINE=Memory;

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_entry_source;
  CREATE TEMPORARY TABLE tmp_spell_pen_entry_source(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    quality TINYINT UNSIGNED NOT NULL,
    inventory_type TINYINT UNSIGNED NOT NULL,
    slot_mod DOUBLE NOT NULL,
    ilvl INT UNSIGNED NOT NULL,
    item_slot_value DOUBLE NOT NULL,
    target_term_sum DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_entry_source(entry, quality, inventory_type, slot_mod, ilvl,
                                         item_slot_value, target_term_sum)
  SELECT it.entry,
         it.Quality AS quality,
         it.InventoryType AS inventory_type,
         GREATEST(0.0001,
           CASE it.InventoryType
             WHEN 1  THEN 1.00 WHEN 5  THEN 1.00 WHEN 20 THEN 1.00 WHEN 7  THEN 1.00
             WHEN 3  THEN 1.35 WHEN 10 THEN 1.35 WHEN 6  THEN 1.35 WHEN 8  THEN 1.35
             WHEN 12 THEN 1.47
             WHEN 9  THEN 1.85 WHEN 2  THEN 1.85 WHEN 16 THEN 1.85 WHEN 11 THEN 1.85
             WHEN 17 THEN 1.00
             WHEN 13 THEN 2.44 WHEN 21 THEN 2.44
             WHEN 14 THEN 1.92 WHEN 22 THEN 1.92 WHEN 23 THEN 1.92
             WHEN 15 THEN 3.33 WHEN 26 THEN 3.33 WHEN 25 THEN 3.33
             ELSE 1.00
           END
         ) AS slot_mod,
         GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) AS ilvl,
         GREATEST(0,
           CASE it.Quality
             WHEN 3 THEN (1.42 * GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) - 4.2)
             WHEN 4 THEN (1.64 * GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) + 11.2)
             ELSE (1.21 * GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) - 9.8)
           END
         ) AS item_slot_value,
        POW(
          GREATEST(
            0,
            (
              GREATEST(0,
                CASE it.Quality
                  WHEN 3 THEN (1.42 * GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) - 4.2)
                  WHEN 4 THEN (1.64 * GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) + 11.2)
                  ELSE (1.21 * GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) - 9.8)
                END
              ) / GREATEST(0.0001,
                CASE it.InventoryType
                  WHEN 1  THEN 1.00 WHEN 5  THEN 1.00 WHEN 20 THEN 1.00 WHEN 7  THEN 1.00
                  WHEN 3  THEN 1.35 WHEN 10 THEN 1.35 WHEN 6  THEN 1.35 WHEN 8  THEN 1.35
                  WHEN 12 THEN 1.47
                  WHEN 9  THEN 1.85 WHEN 2  THEN 1.85 WHEN 16 THEN 1.85 WHEN 11 THEN 1.85
                  WHEN 17 THEN 1.00
                  WHEN 13 THEN 2.44 WHEN 21 THEN 2.44
                  WHEN 14 THEN 1.92 WHEN 22 THEN 1.92 WHEN 23 THEN 1.92
                  WHEN 15 THEN 3.33 WHEN 26 THEN 3.33 WHEN 25 THEN 3.33
                  ELSE 1.00
                END
              ) * 100
            )
          )
        , 1.5) AS target_term_sum
  FROM lplusworld.item_template it
  JOIN classicmangos.item_template cm ON cm.entry = it.entry
  WHERE it.InventoryType <> 12
    AND it.Quality = 4
    AND COALESCE(it.RequiredLevel, 0) IN (0, 60);

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_stat_slots;
  CREATE TEMPORARY TABLE tmp_spell_pen_stat_slots(
    slot_id TINYINT UNSIGNED NOT NULL PRIMARY KEY
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_stat_slots(slot_id)
  VALUES (1),(2),(3),(4),(5),(6),(7),(8),(9),(10);

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_item_spell_slots;
  CREATE TEMPORARY TABLE tmp_spell_pen_item_spell_slots(
    slot_id TINYINT UNSIGNED NOT NULL PRIMARY KEY
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_item_spell_slots(slot_id)
  VALUES (1),(2),(3),(4),(5);

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_effect_slots;
  CREATE TEMPORARY TABLE tmp_spell_pen_effect_slots(
    effect_index TINYINT UNSIGNED NOT NULL PRIMARY KEY
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_effect_slots(effect_index)
  VALUES (1),(2),(3);

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_equip_spells;
  CREATE TEMPORARY TABLE tmp_spell_pen_equip_spells(
    entry INT UNSIGNED NOT NULL,
    sid   INT UNSIGNED NOT NULL,
    PRIMARY KEY(entry, sid)
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_equip_spells(entry, sid)
  SELECT DISTINCT src.entry,
         CASE slots.slot_id
           WHEN 1 THEN it.spellid_1
           WHEN 2 THEN it.spellid_2
           WHEN 3 THEN it.spellid_3
           WHEN 4 THEN it.spellid_4
           ELSE it.spellid_5
         END AS sid
  FROM tmp_spell_pen_entry_source src
  JOIN lplusworld.item_template it ON it.entry = src.entry
  JOIN tmp_spell_pen_item_spell_slots slots ON TRUE
  WHERE CASE slots.slot_id
          WHEN 1 THEN it.spellid_1
          WHEN 2 THEN it.spellid_2
          WHEN 3 THEN it.spellid_3
          WHEN 4 THEN it.spellid_4
          ELSE it.spellid_5
        END <> 0
    AND CASE slots.slot_id
          WHEN 1 THEN it.spelltrigger_1
          WHEN 2 THEN it.spelltrigger_2
          WHEN 3 THEN it.spelltrigger_3
          WHEN 4 THEN it.spelltrigger_4
          ELSE it.spelltrigger_5
        END = 1;

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_lines;
  CREATE TEMPORARY TABLE tmp_spell_pen_lines(
    entry INT UNSIGNED NOT NULL,
    amount DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_lines(entry, amount)
  SELECT raw.entry, raw.amount
  FROM (
    SELECT it.entry,
           CASE slots.slot_id
             WHEN 1  THEN CASE WHEN it.stat_type1=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value1) ELSE 0 END
             WHEN 2  THEN CASE WHEN it.stat_type2=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value2) ELSE 0 END
             WHEN 3  THEN CASE WHEN it.stat_type3=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value3) ELSE 0 END
             WHEN 4  THEN CASE WHEN it.stat_type4=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value4) ELSE 0 END
             WHEN 5  THEN CASE WHEN it.stat_type5=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value5) ELSE 0 END
             WHEN 6  THEN CASE WHEN it.stat_type6=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value6) ELSE 0 END
             WHEN 7  THEN CASE WHEN it.stat_type7=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value7) ELSE 0 END
             WHEN 8  THEN CASE WHEN it.stat_type8=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value8) ELSE 0 END
             WHEN 9  THEN CASE WHEN it.stat_type9=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value9) ELSE 0 END
             ELSE        CASE WHEN it.stat_type10=@STAT_SPELL_PEN THEN GREATEST(0, it.stat_value10) ELSE 0 END
           END AS amount
    FROM lplusworld.item_template it
    JOIN tmp_spell_pen_entry_source src ON src.entry = it.entry
    JOIN tmp_spell_pen_stat_slots slots ON TRUE
  ) raw
  WHERE raw.amount > 0;

  INSERT INTO tmp_spell_pen_lines(entry, amount)
  SELECT raw.entry, raw.amount
  FROM (
    SELECT es.entry,
           CASE eff.effect_index
             WHEN 1 THEN CASE WHEN s.EffectAura_1=@AURA_SPELL_PEN THEN GREATEST(0, -(s.EffectBasePoints_1+1)) ELSE 0 END
             WHEN 2 THEN CASE WHEN s.EffectAura_2=@AURA_SPELL_PEN THEN GREATEST(0, -(s.EffectBasePoints_2+1)) ELSE 0 END
             ELSE        CASE WHEN s.EffectAura_3=@AURA_SPELL_PEN THEN GREATEST(0, -(s.EffectBasePoints_3+1)) ELSE 0 END
           END AS amount
    FROM tmp_spell_pen_equip_spells es
    JOIN dbc.spell_lplus s ON s.ID = es.sid
    JOIN tmp_spell_pen_effect_slots eff ON TRUE
  ) raw
  WHERE raw.amount > 0;

  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_line_summary;
  CREATE TEMPORARY TABLE tmp_spell_pen_line_summary(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    spell_pen_points DOUBLE NOT NULL,
    spell_pen_pow DOUBLE NOT NULL,
    spell_pen_count INT NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_line_summary(entry, spell_pen_points, spell_pen_pow, spell_pen_count)
  SELECT l.entry,
         SUM(l.amount) AS spell_pen_points,
         SUM(POW(l.amount, 1.5)) AS spell_pen_pow,
         COUNT(*) AS spell_pen_count
  FROM tmp_spell_pen_lines l
  GROUP BY l.entry;

  INSERT INTO tmp_spell_pen_entries(entry, quality, inventory_type, slot_mod, ilvl,
                                    item_slot_value, target_term_sum,
                                    spell_pen_points, spell_pen_pow, spell_pen_count)
  SELECT src.entry,
         src.quality,
         src.inventory_type,
         src.slot_mod,
         src.ilvl,
         src.item_slot_value,
         src.target_term_sum * src.slot_mod AS target_term_sum,
         agg.spell_pen_points,
         agg.spell_pen_pow,
         agg.spell_pen_count
  FROM tmp_spell_pen_entry_source src
  JOIN tmp_spell_pen_line_summary agg ON agg.entry = src.entry
  WHERE agg.spell_pen_pow > 0
    AND src.target_term_sum > 0;

  /* ===== Base stat terms for these entries ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_base_terms;
  CREATE TEMPORARY TABLE tmp_spell_pen_base_terms(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    term_sum DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_base_terms(entry, term_sum)
  SELECT it.entry,
         POW(GREATEST(0, CASE WHEN it.stat_type1  IN (3,4,5,6,7) THEN it.stat_value1  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type2  IN (3,4,5,6,7) THEN it.stat_value2  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type3  IN (3,4,5,6,7) THEN it.stat_value3  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type4  IN (3,4,5,6,7) THEN it.stat_value4  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type5  IN (3,4,5,6,7) THEN it.stat_value5  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type6  IN (3,4,5,6,7) THEN it.stat_value6  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type7  IN (3,4,5,6,7) THEN it.stat_value7  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type8  IN (3,4,5,6,7) THEN it.stat_value8  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type9  IN (3,4,5,6,7) THEN it.stat_value9  * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, CASE WHEN it.stat_type10 IN (3,4,5,6,7) THEN it.stat_value10 * @W_PRIMARY ELSE 0 END), 1.5) +
         POW(GREATEST(0, IFNULL(it.armor,0) * @W_ARMOR), 1.5) +
         POW(GREATEST(0, IFNULL(it.armorDamageModifier,0) * @W_BONUSARMOR), 1.5) +
         POW(GREATEST(0, IFNULL(it.holy_res,0)   * @W_RESIST), 1.5) +
         POW(GREATEST(0, IFNULL(it.fire_res,0)   * @W_RESIST), 1.5) +
         POW(GREATEST(0, IFNULL(it.nature_res,0) * @W_RESIST), 1.5) +
         POW(GREATEST(0, IFNULL(it.frost_res,0)  * @W_RESIST), 1.5) +
         POW(GREATEST(0, IFNULL(it.shadow_res,0) * @W_RESIST), 1.5) +
         POW(GREATEST(0, IFNULL(it.arcane_res,0) * @W_RESIST), 1.5)
  FROM lplusworld.item_template it
  JOIN tmp_spell_pen_entries e ON e.entry = it.entry;

  /* ===== Weapon DPS trade (caster weapons) ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_weapon_trade;
  CREATE TEMPORARY TABLE tmp_spell_pen_weapon_trade(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    term_sum DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_weapon_trade(entry, term_sum)
  SELECT it.entry,
         POW(
           GREATEST(
             0,
             (GREATEST(COALESCE(it.trueItemLevel, it.ItemLevel), 0) - 60)
             * @WEAPON_DPS_TRADE_SD * @W_SD_ALL
           ),
           1.5
         )
  FROM lplusworld.item_template it
  JOIN tmp_spell_pen_entries e ON e.entry = it.entry
  WHERE it.class = 2
    AND IFNULL(it.caster,0) = 1
    AND IFNULL(it.delay,0) > 0
    AND it.Quality IN (2,3,4);

  /* ===== Flatten DBC auras for spell-pen entries ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_aura_flat;
  CREATE TEMPORARY TABLE tmp_spell_pen_aura_flat(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    ap_amt      DOUBLE NOT NULL DEFAULT 0,
    rap_amt     DOUBLE NOT NULL DEFAULT 0,
    apversus_amt DOUBLE NOT NULL DEFAULT 0,
    hit_amt     DOUBLE NOT NULL DEFAULT 0,
    sphit_amt   DOUBLE NOT NULL DEFAULT 0,
    spcrit_amt  DOUBLE NOT NULL DEFAULT 0,
    crit_amt    DOUBLE NOT NULL DEFAULT 0,
    blockvalue_amt DOUBLE NOT NULL DEFAULT 0,
    block_amt   DOUBLE NOT NULL DEFAULT 0,
    parry_amt   DOUBLE NOT NULL DEFAULT 0,
    dodge_amt   DOUBLE NOT NULL DEFAULT 0,
    defense_amt DOUBLE NOT NULL DEFAULT 0,
    weapon_skill_amt DOUBLE NOT NULL DEFAULT 0,
    weapon_skill_dagger_amt DOUBLE NOT NULL DEFAULT 0,
    damage_shield_amt DOUBLE NOT NULL DEFAULT 0,
    sd_all_amt  DOUBLE NOT NULL DEFAULT 0,
    sd_one_amt  DOUBLE NOT NULL DEFAULT 0,
    heal_amt    DOUBLE NOT NULL DEFAULT 0,
    mp5_amt     DOUBLE NOT NULL DEFAULT 0,
    hp5_amt     DOUBLE NOT NULL DEFAULT 0
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_aura_flat(entry, ap_amt, rap_amt, apversus_amt, hit_amt, sphit_amt, spcrit_amt,
                                      crit_amt, blockvalue_amt, block_amt, parry_amt, dodge_amt,
                                      defense_amt, weapon_skill_amt, weapon_skill_dagger_amt, damage_shield_amt,
                                      sd_all_amt, sd_one_amt, heal_amt, mp5_amt, hp5_amt)
  SELECT sc.entry,
         SUM(sc.ap_amt),
         SUM(sc.rap_amt),
         SUM(sc.apversus_amt),
         SUM(sc.hit_amt),
         SUM(sc.sphit_amt),
         SUM(sc.spcrit_amt),
         SUM(sc.crit_amt),
         SUM(sc.blockvalue_amt),
         SUM(sc.block_amt),
         SUM(sc.parry_amt),
         SUM(sc.dodge_amt),
         SUM(sc.defense_amt),
         SUM(sc.weapon_skill_amt),
         SUM(sc.weapon_skill_dagger_amt),
         SUM(sc.damage_shield_amt),
         SUM(sc.sd_all_amt),
         SUM(sc.sd_one_amt),
         SUM(sc.heal_amt),
         SUM(sc.mp5_amt),
         SUM(sc.hp5_amt)
  FROM (
    SELECT raw.entry, raw.sid,
           CASE
             WHEN raw.ap_raw > 0 AND raw.rap_raw > 0 THEN GREATEST(raw.ap_raw, raw.rap_raw)
             ELSE raw.ap_raw
           END AS ap_amt,
           CASE
             WHEN raw.ap_raw > 0 AND raw.rap_raw > 0 THEN 0
             ELSE raw.rap_raw
           END AS rap_amt,
           raw.apversus_raw AS apversus_amt,
           raw.hit_amt,
           raw.sphit_amt,
           raw.spcrit_amt,
           raw.crit_amt,
           raw.blockvalue_raw AS blockvalue_amt,
           raw.block_raw AS block_amt,
           raw.parry_raw AS parry_amt,
           raw.dodge_raw AS dodge_amt,
           raw.defense_raw AS defense_amt,
           raw.weapon_skill_raw AS weapon_skill_amt,
           raw.weapon_skill_dagger_raw AS weapon_skill_dagger_amt,
           raw.damage_shield_raw AS damage_shield_amt,
           raw.sd_all_amt,
           raw.sd_one_amt,
           CASE
             WHEN raw.sd_all_amt > 0 AND raw.heal_amt > 0 THEN 0
             ELSE raw.heal_amt
           END AS heal_amt,
           raw.mp5_amt,
           raw.hp5_amt
    FROM (
      SELECT es.entry, es.sid,
        (CASE
           WHEN s.EffectAura_1=@AURA_AP  THEN (s.EffectBasePoints_1+1)
           WHEN s.EffectAura_2=@AURA_AP  THEN (s.EffectBasePoints_2+1)
           WHEN s.EffectAura_3=@AURA_AP  THEN (s.EffectBasePoints_3+1)
           ELSE 0 END) AS ap_raw,
        (CASE
           WHEN s.EffectAura_1=@AURA_RAP THEN (s.EffectBasePoints_1+1)
           WHEN s.EffectAura_2=@AURA_RAP THEN (s.EffectBasePoints_2+1)
           WHEN s.EffectAura_3=@AURA_RAP THEN (s.EffectBasePoints_3+1)
           ELSE 0 END) AS rap_raw,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_AP_VERSUS,@AURA_RAP_VERSUS) THEN GREATEST(0, s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_AP_VERSUS,@AURA_RAP_VERSUS) THEN GREATEST(0, s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_AP_VERSUS,@AURA_RAP_VERSUS) THEN GREATEST(0, s.EffectBasePoints_3+1) ELSE 0 END)) AS apversus_raw,
        ((CASE WHEN s.EffectAura_1=@AURA_HIT THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_HIT THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_HIT THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS hit_amt,
        ((CASE WHEN s.EffectAura_1=@AURA_SPHIT THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_SPHIT THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_SPHIT THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS sphit_amt,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS spcrit_amt,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS crit_amt,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_BLOCKVALUE,@AURA_BLOCKVALUE_PCT) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_BLOCKVALUE,@AURA_BLOCKVALUE_PCT) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_BLOCKVALUE,@AURA_BLOCKVALUE_PCT) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS blockvalue_raw,
        ((CASE WHEN s.EffectAura_1=@AURA_BLOCK THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_BLOCK THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_BLOCK THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS block_raw,
        ((CASE WHEN s.EffectAura_1=@AURA_PARRY THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_PARRY THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_PARRY THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS parry_raw,
        ((CASE WHEN s.EffectAura_1=@AURA_DODGE THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_DODGE THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_DODGE THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS dodge_raw,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_1, IFNULL(s.EffectMiscValueB_1,0)) = @SKILL_DEFENSE
               THEN GREATEST(0, s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_2, IFNULL(s.EffectMiscValueB_2,0)) = @SKILL_DEFENSE
               THEN GREATEST(0, s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_3, IFNULL(s.EffectMiscValueB_3,0)) = @SKILL_DEFENSE
               THEN GREATEST(0, s.EffectBasePoints_3+1) ELSE 0 END)) AS defense_raw,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_1, IFNULL(s.EffectMiscValueB_1,0)) = @SKILL_DAGGERS
               THEN GREATEST(0, s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_2, IFNULL(s.EffectMiscValueB_2,0)) = @SKILL_DAGGERS
               THEN GREATEST(0, s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_3, IFNULL(s.EffectMiscValueB_3,0)) = @SKILL_DAGGERS
               THEN GREATEST(0, s.EffectBasePoints_3+1) ELSE 0 END)) AS weapon_skill_dagger_raw,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_1, IFNULL(s.EffectMiscValueB_1,0)) IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475)
                 AND IFNULL(s.EffectMiscValue_1, IFNULL(s.EffectMiscValueB_1,0)) <> @SKILL_DAGGERS
                 AND IFNULL(s.EffectMiscValue_1, IFNULL(s.EffectMiscValueB_1,0)) <> @SKILL_DEFENSE
               THEN GREATEST(0, s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_2, IFNULL(s.EffectMiscValueB_2,0)) IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475)
                 AND IFNULL(s.EffectMiscValue_2, IFNULL(s.EffectMiscValueB_2,0)) <> @SKILL_DAGGERS
                 AND IFNULL(s.EffectMiscValue_2, IFNULL(s.EffectMiscValueB_2,0)) <> @SKILL_DEFENSE
               THEN GREATEST(0, s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT)
                 AND IFNULL(s.EffectMiscValue_3, IFNULL(s.EffectMiscValueB_3,0)) IN (43,44,45,46,54,55,136,160,162,172,176,226,228,229,473,475)
                 AND IFNULL(s.EffectMiscValue_3, IFNULL(s.EffectMiscValueB_3,0)) <> @SKILL_DAGGERS
                 AND IFNULL(s.EffectMiscValue_3, IFNULL(s.EffectMiscValueB_3,0)) <> @SKILL_DEFENSE
               THEN GREATEST(0, s.EffectBasePoints_3+1) ELSE 0 END)) AS weapon_skill_raw,
        ((CASE WHEN s.EffectAura_1=@AURA_DAMAGE_SHIELD THEN GREATEST(0, s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_DAMAGE_SHIELD THEN GREATEST(0, s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_DAMAGE_SHIELD THEN GREATEST(0, s.EffectBasePoints_3+1) ELSE 0 END)) AS damage_shield_raw,
        ((CASE WHEN s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)=@MASK_SD_ALL THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)=@MASK_SD_ALL THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)=@MASK_SD_ALL THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS sd_all_amt,
        ((CASE WHEN s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS sd_one_amt,
        ((CASE WHEN s.EffectAura_1 IN (@AURA_HEAL1,@AURA_HEAL2) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_HEAL1,@AURA_HEAL2) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_HEAL1,@AURA_HEAL2) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS heal_amt,
        ((CASE WHEN s.EffectAura_1=@AURA_MP5 AND s.EffectMiscValue_1=0 THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_MP5 AND s.EffectMiscValue_2=0 THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_MP5 AND s.EffectMiscValue_3=0 THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS mp5_amt,
        ((CASE WHEN s.EffectAura_1=@AURA_HP5 THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_HP5 THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_HP5 THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS hp5_amt
      FROM tmp_spell_pen_equip_spells es
      JOIN tmp_spell_pen_entries e ON e.entry = es.entry
      JOIN dbc.spell_lplus s ON s.ID = es.sid
    ) raw
  ) sc
  GROUP BY sc.entry;

  /* ===== Convert auras into term sums ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_aura_terms;
  CREATE TEMPORARY TABLE tmp_spell_pen_aura_terms(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    term_sum DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_aura_terms(entry, term_sum)
  SELECT f.entry,
         POW(GREATEST(0, f.ap_amt     * @W_AP),     1.5) +
         POW(GREATEST(0, f.rap_amt    * @W_RAP),    1.5) +
         POW(GREATEST(0, f.apversus_amt * @W_AP_VERSUS), 1.5) +
         POW(GREATEST(0, f.hit_amt    * @W_HIT),    1.5) +
         POW(GREATEST(0, f.sphit_amt  * @W_SPHIT),  1.5) +
         POW(GREATEST(0, f.spcrit_amt * @W_SPCRIT), 1.5) +
         POW(GREATEST(0, f.crit_amt   * @W_CRIT),   1.5) +
         POW(GREATEST(0, f.blockvalue_amt * @W_BLOCKVALUE), 1.5) +
         POW(GREATEST(0, f.block_amt  * @W_BLOCK),  1.5) +
         POW(GREATEST(0, f.parry_amt  * @W_PARRY),  1.5) +
         POW(GREATEST(0, f.dodge_amt  * @W_DODGE),  1.5) +
         POW(GREATEST(0, f.defense_amt * @W_DEFENSE), 1.5) +
         POW(GREATEST(0, f.weapon_skill_amt * @W_WEAPON_SKILL_OTHER), 1.5) +
         POW(GREATEST(0, f.weapon_skill_dagger_amt * @W_WEAPON_SKILL_DAGGER), 1.5) +
         POW(GREATEST(0, f.damage_shield_amt * @W_DAMAGE_SHIELD), 1.5) +
         POW(GREATEST(0, f.sd_all_amt * @W_SD_ALL), 1.5) +
         POW(GREATEST(0, f.sd_one_amt * @W_SD_ONE), 1.5) +
         POW(GREATEST(0, f.heal_amt * @W_HEAL), 1.5) +
         POW(GREATEST(0, f.mp5_amt    * @W_MP5),    1.5) +
         POW(GREATEST(0, f.hp5_amt    * @W_HP5),    1.5)
  FROM tmp_spell_pen_aura_flat f;

  /* ===== Combine known term sums and infer residual ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_spell_pen_budget;
  CREATE TEMPORARY TABLE tmp_spell_pen_budget(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    target_term_sum DOUBLE NOT NULL,
    known_term_sum DOUBLE NOT NULL,
    spell_pen_term_sum DOUBLE NOT NULL,
    spell_pen_pow DOUBLE NOT NULL,
    spell_pen_points DOUBLE NOT NULL,
    spell_pen_count INT NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_spell_pen_budget(entry, target_term_sum, known_term_sum, spell_pen_term_sum,
                                   spell_pen_pow, spell_pen_points, spell_pen_count)
  SELECT e.entry,
         e.target_term_sum,
         (IFNULL(b.term_sum,0) + IFNULL(a.term_sum,0) + IFNULL(w.term_sum,0)) AS known_term_sum,
         GREATEST(0, e.target_term_sum - (IFNULL(b.term_sum,0) + IFNULL(a.term_sum,0) + IFNULL(w.term_sum,0))) AS spell_pen_term_sum,
         e.spell_pen_pow,
         e.spell_pen_points,
         e.spell_pen_count
  FROM tmp_spell_pen_entries e
  LEFT JOIN tmp_spell_pen_base_terms b ON b.entry = e.entry
  LEFT JOIN tmp_spell_pen_aura_terms a ON a.entry = e.entry
  LEFT JOIN tmp_spell_pen_weapon_trade w ON w.entry = e.entry;

  /* ===== Summary ===== */
  SELECT
    COUNT(*) AS n_items,
    SUM(spell_pen_count) AS spell_pen_lines,
    SUM(spell_pen_points) AS total_spell_pen_points,
    SUM(spell_pen_pow) AS total_spell_pen_pow,
    SUM(spell_pen_term_sum) AS total_spell_pen_term_sum,
    CASE
      WHEN SUM(spell_pen_pow) > 0 AND SUM(spell_pen_term_sum) > 0 THEN
        POW(SUM(spell_pen_term_sum) / SUM(spell_pen_pow), 2.0/3.0)
      ELSE NULL
    END AS inferred_spell_pen_weight
  FROM tmp_spell_pen_budget;

  /* ===== Detailed per-item breakdown ===== */
  SELECT b.entry, it.name, it.Quality, it.InventoryType,
         CAST(COALESCE(it.trueItemLevel, it.ItemLevel) AS SIGNED) AS ilvl,
         b.spell_pen_points,
         b.spell_pen_term_sum,
         b.known_term_sum,
         b.target_term_sum
  FROM tmp_spell_pen_budget b
  JOIN lplusworld.item_template it ON it.entry = b.entry
  ORDER BY b.spell_pen_term_sum DESC;
END
