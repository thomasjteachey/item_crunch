CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_EstimateItemLevels`()
BEGIN
  /* ===== Weights (must match anything that scales/reforges) ===== */
  SET @W_PRIMARY    := 230;   -- STR/AGI/STA/INT/SPI (stat_type 3..7)
  SET @W_ARMOR      := 0;     -- base armor excluded
  SET @W_BONUSARMOR := 22;    -- ArmorDamageModifier “bonus armor” (Classic budget)
  SET @W_RESIST     := 230;   -- per-school resists (holy/fire/nature/frost/shadow/arcane)

  SET @W_AP      := 115;      -- Attack Power (AP) only
  SET @W_RAP     := 92;       -- Ranged Attack Power (RAP) only
  SET @W_HEAL    := 100;      -- +Healing (only when NOT a dmg+healing SP line)
  SET @W_SD_ALL  := 192;      -- Spell Power (+damage&healing all schools)
  SET @W_SD_ONE  := 159;      -- +Damage one school
  SET @W_HIT     := 2200;     -- Melee/Ranged Hit %
  SET @W_SPHIT   := 2500;     -- Spell Hit %
  SET @W_CRIT    := 3200;     -- Melee/Ranged Crit %
  SET @W_SPCRIT  := 2600;     -- Spell Crit %
  SET @W_MP5     := 550;      -- Mana per 5s
  SET @W_HP5     := 550;      -- Health per 5s (same budget per your rule)
  SET @W_BLOCKVALUE := 150;   -- Blocking Value (shield or stat)
  SET @W_BLOCKPCT   := 1300;  -- % chance to Block

  /* ===== DBC Auras (Classic) ===== */
  SET @AURA_AP := 99;    SET @AURA_RAP := 124;
  SET @AURA_HIT := 54;   SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57; SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_MELEE := 308; SET @AURA_CRIT_RANGED := 290; SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_SD := 13;    SET @MASK_SD_ALL := 126;  -- all six schools bitmask
  SET @AURA_HEAL1 := 115; SET @AURA_HEAL2 := 135;  -- +Healing
  SET @AURA_MP5 := 85;   -- Misc=0 => mana regen
  SET @AURA_HP5 := 83;   -- health regen per 5

  /* ===== Base terms (from item_template) ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_base_terms;
  CREATE TEMPORARY TABLE tmp_item_base_terms(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    term_sum DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_item_base_terms(entry, term_sum)
  SELECT it.entry,
         /* 10 primary stat slots (3..7) */
           POW(GREATEST(0, CASE WHEN it.stat_type1  IN (3,4,5,6,7) THEN it.stat_value1  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type2  IN (3,4,5,6,7) THEN it.stat_value2  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type3  IN (3,4,5,6,7) THEN it.stat_value3  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type4  IN (3,4,5,6,7) THEN it.stat_value4  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type5  IN (3,4,5,6,7) THEN it.stat_value5  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type6  IN (3,4,5,6,7) THEN it.stat_value6  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type7  IN (3,4,5,6,7) THEN it.stat_value7  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type8  IN (3,4,5,6,7) THEN it.stat_value8  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type9  IN (3,4,5,6,7) THEN it.stat_value9  * @W_PRIMARY ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type10 IN (3,4,5,6,7) THEN it.stat_value10 * @W_PRIMARY ELSE 0 END), 1.5)

         /* block value stats (ITEM_MOD_BLOCK_VALUE = 48) */
         + POW(GREATEST(0, CASE WHEN it.stat_type1  = 48 THEN it.stat_value1  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type2  = 48 THEN it.stat_value2  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type3  = 48 THEN it.stat_value3  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type4  = 48 THEN it.stat_value4  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type5  = 48 THEN it.stat_value5  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type6  = 48 THEN it.stat_value6  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type7  = 48 THEN it.stat_value7  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type8  = 48 THEN it.stat_value8  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type9  = 48 THEN it.stat_value9  * @W_BLOCKVALUE ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type10 = 48 THEN it.stat_value10 * @W_BLOCKVALUE ELSE 0 END), 1.5)

         /* block percentage stats (ITEM_MOD_BLOCK_RATING = 15) */
         + POW(GREATEST(0, CASE WHEN it.stat_type1  = 15 THEN it.stat_value1  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type2  = 15 THEN it.stat_value2  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type3  = 15 THEN it.stat_value3  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type4  = 15 THEN it.stat_value4  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type5  = 15 THEN it.stat_value5  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type6  = 15 THEN it.stat_value6  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type7  = 15 THEN it.stat_value7  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type8  = 15 THEN it.stat_value8  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type9  = 15 THEN it.stat_value9  * @W_BLOCKPCT ELSE 0 END), 1.5)
         + POW(GREATEST(0, CASE WHEN it.stat_type10 = 15 THEN it.stat_value10 * @W_BLOCKPCT ELSE 0 END), 1.5)

         /* regular armor excluded */
         + POW(GREATEST(0, IFNULL(it.armor,0) * @W_ARMOR), 1.5)

         /* BONUS ARMOR (ArmorDamageModifier) */
         + POW(GREATEST(0, IFNULL(it.armorDamageModifier,0) * @W_BONUSARMOR), 1.5)

         /* per-school resists */
         + POW(GREATEST(0, IFNULL(it.holy_res,0)   * @W_RESIST), 1.5)
         + POW(GREATEST(0, IFNULL(it.fire_res,0)   * @W_RESIST), 1.5)
         + POW(GREATEST(0, IFNULL(it.nature_res,0) * @W_RESIST), 1.5)
         + POW(GREATEST(0, IFNULL(it.frost_res,0)  * @W_RESIST), 1.5)
         + POW(GREATEST(0, IFNULL(it.shadow_res,0) * @W_RESIST), 1.5)
         + POW(GREATEST(0, IFNULL(it.arcane_res,0) * @W_RESIST), 1.5)
         + POW(GREATEST(0, IFNULL(it.block,0)       * @W_BLOCKVALUE), 1.5)
  FROM lplusworld.item_template it;

  /* ===== On-equip spells (distinct equips only) ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells;
  CREATE TEMPORARY TABLE tmp_equip_spells(
    entry INT UNSIGNED NOT NULL,
    sid   INT UNSIGNED NOT NULL,
    PRIMARY KEY(entry, sid)
  ) ENGINE=Memory;

  INSERT INTO tmp_equip_spells(entry, sid)
  SELECT entry, spellid_1 FROM lplusworld.item_template WHERE spellid_1<>0 AND spelltrigger_1=1
  UNION DISTINCT
  SELECT entry, spellid_2 FROM lplusworld.item_template WHERE spellid_2<>0 AND spelltrigger_2=1
  UNION DISTINCT
  SELECT entry, spellid_3 FROM lplusworld.item_template WHERE spellid_3<>0 AND spelltrigger_3=1
  UNION DISTINCT
  SELECT entry, spellid_4 FROM lplusworld.item_template WHERE spellid_4<>0 AND spelltrigger_4=1
  UNION DISTINCT
  SELECT entry, spellid_5 FROM lplusworld.item_template WHERE spellid_5<>0 AND spelltrigger_5=1;

  /* ===== Flatten DBC auras per item (DO NOT collapse AP/RAP) ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_aura_flat;
  CREATE TEMPORARY TABLE tmp_aura_flat(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    ap_amt      DOUBLE NOT NULL DEFAULT 0,
    rap_amt     DOUBLE NOT NULL DEFAULT 0,
    hit_amt     DOUBLE NOT NULL DEFAULT 0,
    sphit_amt   DOUBLE NOT NULL DEFAULT 0,
    spcrit_amt  DOUBLE NOT NULL DEFAULT 0,
    crit_amt    DOUBLE NOT NULL DEFAULT 0,
    sd_all_amt  DOUBLE NOT NULL DEFAULT 0,
    sd_one_amt  DOUBLE NOT NULL DEFAULT 0,
    heal_amt    DOUBLE NOT NULL DEFAULT 0,
    mp5_amt     DOUBLE NOT NULL DEFAULT 0,
    hp5_amt     DOUBLE NOT NULL DEFAULT 0
  ) ENGINE=Memory;

  /* Per-spell -> per-item sums */
  INSERT INTO tmp_aura_flat(entry, ap_amt, rap_amt, hit_amt, sphit_amt, spcrit_amt,
                            crit_amt, sd_all_amt, sd_one_amt, heal_amt, mp5_amt, hp5_amt)
  SELECT sc.entry,
         SUM(sc.ap_amt),
         SUM(sc.rap_amt),
         SUM(sc.hit_amt),
         SUM(sc.sphit_amt),
         SUM(sc.spcrit_amt),
         SUM(sc.crit_amt),
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
           raw.hit_amt,
           raw.sphit_amt,
           raw.spcrit_amt,
           raw.crit_amt,
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

        /* AP and RAP as separate lines (no collapsing) */
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

        /* %-stats etc (sum if repeated inside spell) */
        ((CASE WHEN s.EffectAura_1=@AURA_HIT   THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_HIT   THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_HIT   THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS hit_amt,

        ((CASE WHEN s.EffectAura_1=@AURA_SPHIT THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_SPHIT THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_SPHIT THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS sphit_amt,

        ((CASE WHEN s.EffectAura_1 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS spcrit_amt,

        ((CASE WHEN s.EffectAura_1 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS crit_amt,

        /* Spell Power (all schools) vs single-school damage */
        ((CASE WHEN s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)=@MASK_SD_ALL THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)=@MASK_SD_ALL THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)=@MASK_SD_ALL THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS sd_all_amt,

        ((CASE WHEN s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS sd_one_amt,

        /* +Healing (Classic separate) */
        ((CASE WHEN s.EffectAura_1 IN (@AURA_HEAL1,@AURA_HEAL2) THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2 IN (@AURA_HEAL1,@AURA_HEAL2) THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3 IN (@AURA_HEAL1,@AURA_HEAL2) THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS heal_amt,

        /* Regen */
        ((CASE WHEN s.EffectAura_1=@AURA_MP5 AND s.EffectMiscValue_1=0 THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_MP5 AND s.EffectMiscValue_2=0 THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_MP5 AND s.EffectMiscValue_3=0 THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS mp5_amt,

        ((CASE WHEN s.EffectAura_1=@AURA_HP5 THEN (s.EffectBasePoints_1+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_2=@AURA_HP5 THEN (s.EffectBasePoints_2+1) ELSE 0 END) +
         (CASE WHEN s.EffectAura_3=@AURA_HP5 THEN (s.EffectBasePoints_3+1) ELSE 0 END)) AS hp5_amt

      FROM tmp_equip_spells es
      JOIN dbc.spell_lplus s ON s.ID = es.sid
    ) raw
  ) sc
  GROUP BY sc.entry;

  /* ===== Convert flattened auras -> powered term_sum with refined classification ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_aura_terms;
  CREATE TEMPORARY TABLE tmp_item_aura_terms(
    entry INT UNSIGNED NOT NULL PRIMARY KEY,
    term_sum DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_item_aura_terms(entry, term_sum)
  SELECT f.entry,
         POW(GREATEST(0, f.ap_amt     * @W_AP),     1.5) +
         POW(GREATEST(0, f.rap_amt    * @W_RAP),    1.5) +
         POW(GREATEST(0, f.hit_amt    * @W_HIT),    1.5) +
         POW(GREATEST(0, f.sphit_amt  * @W_SPHIT),  1.5) +
         POW(GREATEST(0, f.spcrit_amt * @W_SPCRIT), 1.5) +
         POW(GREATEST(0, f.crit_amt   * @W_CRIT),   1.5) +
         POW(GREATEST(0, f.sd_all_amt * @W_SD_ALL), 1.5) +
         POW(GREATEST(0, f.sd_one_amt * @W_SD_ONE), 1.5) +
         POW(GREATEST(0, f.heal_amt * @W_HEAL), 1.5) +
         POW(GREATEST(0, f.mp5_amt    * @W_MP5),    1.5) +
         POW(GREATEST(0, f.hp5_amt    * @W_HP5),    1.5)
  FROM tmp_aura_flat f;

  /* ===== ItemValue from (base_terms + aura_terms) ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_values;
  CREATE TEMPORARY TABLE tmp_item_values(
    entry INT UNSIGNED PRIMARY KEY,
    ItemValue DOUBLE NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_item_values(entry, ItemValue)
  SELECT b.entry,
         (POW(GREATEST(0, b.term_sum + IFNULL(a.term_sum,0)), 2.0/3.0) / 100.0) AS ItemValue
  FROM tmp_item_base_terms b
  LEFT JOIN tmp_item_aura_terms a ON a.entry = b.entry;

  /* ===== Slot modifier => ItemSlotValue & carry Quality ===== */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_slot_values;
  CREATE TEMPORARY TABLE tmp_item_slot_values(
    entry INT UNSIGNED PRIMARY KEY,
    ItemSlotValue DOUBLE NOT NULL,
    Quality TINYINT UNSIGNED NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_item_slot_values(entry, ItemSlotValue, Quality)
  SELECT it.entry,
         iv.ItemValue *
         (CASE it.InventoryType
            WHEN 1  THEN 1.00 /* Head */
            WHEN 5  THEN 1.00 /* Chest */
            WHEN 20 THEN 1.00 /* Robe */
            WHEN 7  THEN 1.00 /* Legs */

            WHEN 3  THEN 1.35 /* Shoulder */
            WHEN 10 THEN 1.35 /* Hands */
            WHEN 6  THEN 1.35 /* Waist */
            WHEN 8  THEN 1.35 /* Feet */

            WHEN 12 THEN 1.47 /* Trinket */

            WHEN 9  THEN 1.85 /* Wrist */
            WHEN 2  THEN 1.85 /* Neck */
            WHEN 16 THEN 1.85 /* Cloak */
            WHEN 11 THEN 1.85 /* Finger */

            WHEN 17 THEN 1.00 /* Two-Hand */
            WHEN 13 THEN 2.44 /* One-Hand */
            WHEN 21 THEN 2.44 /* Main Hand */

            WHEN 14 THEN 1.92 /* Shield */
            WHEN 22 THEN 1.92 /* Off Hand */
            WHEN 23 THEN 1.92 /* Held In Off-Hand */

            WHEN 15 THEN 3.33 /* Ranged */
            WHEN 26 THEN 3.33 /* Ranged Right */
            WHEN 25 THEN 3.33 /* Thrown */
            ELSE 1.00
          END),
         it.Quality
  FROM lplusworld.item_template it
  JOIN tmp_item_values iv ON iv.entry = it.entry;

  /* ===== Map to true ilvl via quality curves & write ===== */
  UPDATE lplusworld.item_template t
  JOIN tmp_item_slot_values sv ON sv.entry = t.entry
  SET t.trueItemLevel = ROUND(
        CASE CAST(sv.Quality AS UNSIGNED)
          WHEN 2 THEN (sv.ItemSlotValue + 9.8)  / 1.21  /* Green */
          WHEN 3 THEN (sv.ItemSlotValue + 4.2)  / 1.42  /* Blue  */
          WHEN 4 THEN (sv.ItemSlotValue - 11.2) / 1.64  /* Epic  */
          ELSE (sv.ItemSlotValue + 9.8) / 1.21
        END
      );
END