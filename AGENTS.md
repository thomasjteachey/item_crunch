- StatMod weights from 'Item level.docx':
  - Armor: 22
  - Attack Power vs (demons, beasts, undead): 76
  - Ranged Attack Power: 92
  - Spell Healing: 100
  - Attack Power: 115
  - Blocking Value: 150
  - Spell Damage (One school): 159
  - Spell Damage (All Spells): 192
  - Magic Resist (One school): 230
  - Primary Stat (STR, AGI, STA, INT, SPI): 230
  - Defense: 345
  - Regen per 5 sec (Health or Mana): 550
  - Weapon skill (other): 550
  - Weapon skill (daggers): 720
  - Damage Shield: 720
  - % chance to Block: 1300
  - % chance to hit: 2200
  - % chance to hit with all spells: 2500
  - % chance to Dodge: 2500
  - % chance to crit with all spells: 2600
  - % chance to crit: 3200
  - % chance to Parry: 3600

- sp_ScaleItemToIlvl_SimpleGreedy(entry, target_ilvl, apply, scale_auras)
- primary stats, resistances, and (optionally) auras (excluding hit/crit percentages) start from the same shared scale factor so everything shrinks or grows together before rounding
  - hit/crit percentages stay fixed; the remaining stats shift around them so the recomputed item level still hits the requested target
- aura scaling inspects triggered item spells in dbc.spell_lplus directly and only adjusts AP/RAP/SD/HEAL/MP5/HP5 effects it can detect in those rows; spell damage entries with an empty school mask now count as "all schools" so they shrink alongside other stats. When nothing matches, the green-text auras stay fixed and the primary stats must absorb the adjustment.
  - ilvl_debug_log now records aura_source_counts, aura_missing_effect, aura_zero_magnitude, and aura_unsupported_effect rows so you can confirm why auras were left untouched.
- shared_budget_current entries in ilvl_debug_log report the current primaries/auras/resistances budget before scaling, making it obvious when the aura slice is zero.
- after resolving aura conflicts, primaries and resistances receive a shared nudge so the recomputed item level hits the request without skewing the aura mix

- before cloning anything, the scaler now checks dbc.spell_lplus for existing spells that already provide the requested aura magnitudes and reuses them when an exact match exists, only cloning when no reusable spell is available.
- the scaler clones triggered aura spells by inserting new rows into dbc.spell_lplus (without touching helper.aura_spell_catalog) so scaled magnitudes apply automatically while leaving existing rows untouched.
- cloned spell ids are written back to the item_template spell slots so the item references the fresh dbc.spell_lplus entries.
- when iterating on stored procs that rely on temporary tables, join to each temp table once per statement instead of repeating correlated subqueries so MySQL never throws "Error Code: 1137. Can't reopen table" during updates.
- absolutely never reintroduce MySQL's "Error Code: 1137. Can't reopen table" bug—stage data in helper tables before any statement would need to reference the same temp table twice.
- when fanning out spell slots, stats, or similar repeated structures, pivot through helper number tables or staged copies so each statement still references any given temp table exactly once; unions or repeated joins that "reopen" a temp table are explicitly forbidden.
- treat "Can't reopen table" as a release-blocking regression—if a query could possibly reference the same temp table twice (even via correlated subqueries or UNION chains), stop immediately and refactor with helper tables before shipping.
- before running a statement, explicitly confirm that every temporary table appears at most once in its FROM/WHERE/SELECT tree; if not, refactor via staging tables or helper number tables until the "Can't reopen table" failure mode is impossible.
- Spell penetration on Classic items comes from equip spells that use `SPELL_AURA_MOD_RESISTANCE` (aura 123); do not assume stat_type 25 rows exist, and always pull Spell Pen lines from those auras when crunching budgets.

avoid these errors when adjusting procs:
22:05:05	CREATE PROCEDURE helper.sp_ScaleItemToIlvl_SimpleGreedy(   IN p_entry INT UNSIGNED,   IN p_target_ilvl INT UNSIGNED,   IN p_apply TINYINT(1),   IN p_scale_auras TINYINT(1)        -- p_apply: 0=dry run, 1=apply changes; p_scale_auras: 0=skip aura scaling, nonzero=scale auras ) BEGIN   /* ===== constants (must match estimator’s slotmods/curves) ===== */   DROP TEMPORARY TABLE IF EXISTS tmp_slotmods_g;   CREATE TEMPORARY TABLE tmp_slotmods_g(inv TINYINT PRIMARY KEY, slotmod DOUBLE) ENGINE=Memory;   INSERT INTO tmp_slotmods_g VALUES     (1,1.00),(5,1.00),(20,1.00),(7,1.00),     (3,1.35),(10,1.35),(6,1.35),(8,1.35),     (12,1.47),     (9,1.85),(2,1.85),(16,1.85),(11,1.85),     (17,1.00),     (13,2.44),(21,2.44),     (14,1.92),(22,1.92),(23,1.92),     (15,3.33),(26,3.33),(25,3.33);    DROP TEMPORARY TABLE IF EXISTS tmp_qcurve_g;   CREATE TEMPORARY TABLE tmp_qcurve_g(quality TINYINT PRIMARY KEY, a DOUBLE, b DOUBLE) ENGINE=Memory;   INSERT INTO tmp_qcurve_g VALUES (2,1.21,-9.8),(3,1.42,-4.2),(4,1.64,11.2);    /* weight of primaries in term-space (same as estimator) */   SET @W_PRIMARY := 230.0;    /* ===== read item basics ===== */   SELECT Quality, InventoryType, CAST(trueItemLevel AS SIGNED)     INTO @q, @inv, @ilvl_cur   FROM lplusworld.item_template   WHERE entry = p_entry;    IF @q NOT IN (2,3,4) THEN     -- unsupported for this simple scaler, exit quietly     LEAVE proc_end;   END IF;    SELECT a,b INTO @a,@b FROM tmp_qcurve_g WHERE quality=@q;   SET @slotmod := IFNULL((SELECT slotmod FROM tmp_slotmods_g WHERE inv=@inv),1.00);    /* ===== compute target “sum” S_tgt from desired ilvl ===== */   SET @isv_tgt       := @a * p_target_ilvl + @b;     -- ItemSlotValue (inverse curve)   SET @itemvalue_tgt := @isv_tgt / @slotmod;   SET @S_tgt         := POW(@itemvalue_tgt * 100.0, 1.5);    /* ===== snapshot all 10 stat slots (types & values) ===== */   SELECT stat_type1,stat_value1, stat_type2,stat_value2, stat_type3,stat_value3,          stat_type4,stat_value4, stat_type5,stat_value5, stat_type6,stat_value6,          stat_type7,stat_value7, stat_type8,stat_value8, stat_type9,stat_value9,          stat_type10,stat_value10   INTO  @st1,@sv1, @st2,@sv2, @st3,@sv3,         @st4,@sv4, @st5,@sv5, @st6,@sv6,         @st7,@sv7, @st8,@sv8, @st9,@sv9,         @st10,@sv10   FROM lplusworld.item_template   WHERE entry = p_entry;    /* ===== group present primaries (3..7) and compute S_cur_p ===== */   DROP TEMPORARY TABLE IF EXISTS tmp_pcur;   CREATE TEMPORARY TABLE tmp_pcur(stat TINYINT PRIMARY KEY, v DOUBLE) ENGINE=Memory;    INSERT INTO tmp_pcur(stat,v)   SELECT s, SUM(vv) FROM (     SELECT @st1 s, @sv1 vv UNION ALL     SELECT @st2, @sv2 UNION ALL     SELECT @st3, @sv3 UNION ALL     SELECT @st4, @sv4 UNION ALL     SELECT @st5, @sv5 UNION ALL     SELECT @st6, @sv6 UNION ALL     SELECT @st7, @sv7 UNION ALL     SELECT @st8, @sv8 UNION ALL     SELECT @st9, @sv9 UNION ALL     SELECT @st10,@sv10   ) z   WHERE s IN (3,4,5,6,7) AND vv IS NOT NULL AND vv > 0   GROUP BY s;    SET @k := (SELECT COUNT(*) FROM tmp_pcur);   IF @k = 0 THEN     -- no primaries: seed with STA slot so we can scale     INSERT INTO tmp_pcur VALUES (7, 0);     SET @k := 1;   END IF;    /* S_cur from current trueItemLevel (reuse estimator’s mapping) */   SET @isv_cur       := @a * @ilvl_cur + @b;   SET @itemvalue_cur := @isv_cur / @slotmod;   SET @S_cur         := POW(@itemvalue_cur * 100.0, 1.5);    /* S_cur_p: term-sum contributed by primaries only */   SELECT IFNULL(SUM(POW(GREATEST(0, v * @W_PRIMARY), 1.5)), 0.0)     INTO @S_cur_p   FROM tmp_pcur;    /* amount primaries need to change to hit S_tgt while holding non-primaries fixed */   SET @S_fixed  := @S_cur - @S_cur_p;                -- everything except primaries   SET @delta_p  := @S_tgt - (@S_fixed + @S_cur_p);   -- change we must allocate to primaries   SET @each_p   := @delta_p / @k;                    -- even share in term-space    /* ===== compute new primary values (invert 1.5 power per stat) ===== */   DROP TEMPORARY TABLE IF EXISTS tmp_pnew;   CREATE TEMPORARY TABLE tmp_pnew(stat TINYINT PRIMARY KEY, newv INT) ENGINE=Memory;    INSERT INTO tmp_pnew(stat,newv)   SELECT stat,          ROUND(           ...	Error Code: 1308. LEAVE with no matching label: proc_end	0.000 sec
22:00:35	CALL helper.sp_TuneTrueItemLevel_ConsumeQueue(10)	Error Code: 1137. Can't reopen table: 'n1'	0.016 sec


enum AuraType : uint32
{
    SPELL_AURA_NONE                                         = 0,
    SPELL_AURA_BIND_SIGHT                                   = 1,
    SPELL_AURA_MOD_POSSESS                                  = 2,
    SPELL_AURA_PERIODIC_DAMAGE                              = 3,
    SPELL_AURA_DUMMY                                        = 4,
    SPELL_AURA_MOD_CONFUSE                                  = 5,
    SPELL_AURA_MOD_CHARM                                    = 6,
    SPELL_AURA_MOD_FEAR                                     = 7,
    SPELL_AURA_PERIODIC_HEAL                                = 8,
    SPELL_AURA_MOD_ATTACKSPEED                              = 9,
    SPELL_AURA_MOD_THREAT                                   = 10,
    SPELL_AURA_MOD_TAUNT                                    = 11,
    SPELL_AURA_MOD_STUN                                     = 12,
    SPELL_AURA_MOD_DAMAGE_DONE                              = 13,
    SPELL_AURA_MOD_DAMAGE_TAKEN                             = 14,
    SPELL_AURA_DAMAGE_SHIELD                                = 15,
    SPELL_AURA_MOD_STEALTH                                  = 16,
    SPELL_AURA_MOD_STEALTH_DETECT                           = 17,
    SPELL_AURA_MOD_INVISIBILITY                             = 18,
    SPELL_AURA_MOD_INVISIBILITY_DETECT                      = 19,
    SPELL_AURA_OBS_MOD_HEALTH                               = 20,   // 20, 21 unofficial
    SPELL_AURA_OBS_MOD_POWER                                = 21,
    SPELL_AURA_MOD_RESISTANCE                               = 22,
    SPELL_AURA_PERIODIC_TRIGGER_SPELL                       = 23,
    SPELL_AURA_PERIODIC_ENERGIZE                            = 24,
    SPELL_AURA_MOD_PACIFY                                   = 25,
    SPELL_AURA_MOD_ROOT                                     = 26,
    SPELL_AURA_MOD_SILENCE                                  = 27,
    SPELL_AURA_REFLECT_SPELLS                               = 28,
    SPELL_AURA_MOD_STAT                                     = 29,
    SPELL_AURA_MOD_SKILL                                    = 30,
    SPELL_AURA_MOD_INCREASE_SPEED                           = 31,
    SPELL_AURA_MOD_INCREASE_MOUNTED_SPEED                   = 32,
    SPELL_AURA_MOD_DECREASE_SPEED                           = 33,
    SPELL_AURA_MOD_INCREASE_HEALTH                          = 34,
    SPELL_AURA_MOD_INCREASE_ENERGY                          = 35,
    SPELL_AURA_MOD_SHAPESHIFT                               = 36,
    SPELL_AURA_EFFECT_IMMUNITY                              = 37,
    SPELL_AURA_STATE_IMMUNITY                               = 38,
    SPELL_AURA_SCHOOL_IMMUNITY                              = 39,
    SPELL_AURA_DAMAGE_IMMUNITY                              = 40,
    SPELL_AURA_DISPEL_IMMUNITY                              = 41,
    SPELL_AURA_PROC_TRIGGER_SPELL                           = 42,
    SPELL_AURA_PROC_TRIGGER_DAMAGE                          = 43,
    SPELL_AURA_TRACK_CREATURES                              = 44,
    SPELL_AURA_TRACK_RESOURCES                              = 45,
    SPELL_AURA_46                                           = 46,   // Ignore all Gear test spells
    SPELL_AURA_MOD_PARRY_PERCENT                            = 47,
    SPELL_AURA_PERIODIC_TRIGGER_SPELL_FROM_CLIENT           = 48,   // One periodic spell
    SPELL_AURA_MOD_DODGE_PERCENT                            = 49,
    SPELL_AURA_MOD_CRITICAL_HEALING_AMOUNT                  = 50,
    SPELL_AURA_MOD_BLOCK_PERCENT                            = 51,
    SPELL_AURA_MOD_WEAPON_CRIT_PERCENT                      = 52,
    SPELL_AURA_PERIODIC_LEECH                               = 53,
    SPELL_AURA_MOD_HIT_CHANCE                               = 54,
    SPELL_AURA_MOD_SPELL_HIT_CHANCE                         = 55,
    SPELL_AURA_TRANSFORM                                    = 56,
    SPELL_AURA_MOD_SPELL_CRIT_CHANCE                        = 57,
    SPELL_AURA_MOD_INCREASE_SWIM_SPEED                      = 58,
    SPELL_AURA_MOD_DAMAGE_DONE_CREATURE                     = 59,
    SPELL_AURA_MOD_PACIFY_SILENCE                           = 60,
    SPELL_AURA_MOD_SCALE                                    = 61,
    SPELL_AURA_PERIODIC_HEALTH_FUNNEL                       = 62,
    SPELL_AURA_63                                           = 63,   // old SPELL_AURA_PERIODIC_MANA_FUNNEL
    SPELL_AURA_PERIODIC_MANA_LEECH                          = 64,
    SPELL_AURA_MOD_CASTING_SPEED_NOT_STACK                  = 65,
    SPELL_AURA_FEIGN_DEATH                                  = 66,
    SPELL_AURA_MOD_DISARM                                   = 67,
    SPELL_AURA_MOD_STALKED                                  = 68,
    SPELL_AURA_SCHOOL_ABSORB                                = 69,
    SPELL_AURA_EXTRA_ATTACKS                                = 70,
    SPELL_AURA_MOD_SPELL_CRIT_CHANCE_SCHOOL                 = 71,
    SPELL_AURA_MOD_POWER_COST_SCHOOL_PCT                    = 72,
    SPELL_AURA_MOD_POWER_COST_SCHOOL                        = 73,
    SPELL_AURA_REFLECT_SPELLS_SCHOOL                        = 74,
    SPELL_AURA_MOD_LANGUAGE                                 = 75,
    SPELL_AURA_FAR_SIGHT                                    = 76,
    SPELL_AURA_MECHANIC_IMMUNITY                            = 77,
    SPELL_AURA_MOUNTED                                      = 78,
    SPELL_AURA_MOD_DAMAGE_PERCENT_DONE                      = 79,
    SPELL_AURA_MOD_PERCENT_STAT                             = 80,
    SPELL_AURA_SPLIT_DAMAGE_PCT                             = 81,
    SPELL_AURA_WATER_BREATHING                              = 82,
    SPELL_AURA_MOD_BASE_RESISTANCE                          = 83,
    SPELL_AURA_MOD_REGEN                                    = 84,
    SPELL_AURA_MOD_POWER_REGEN                              = 85,
    SPELL_AURA_CHANNEL_DEATH_ITEM                           = 86,
    SPELL_AURA_MOD_DAMAGE_PERCENT_TAKEN                     = 87,
    SPELL_AURA_MOD_HEALTH_REGEN_PERCENT                     = 88,
    SPELL_AURA_PERIODIC_DAMAGE_PERCENT                      = 89,
    SPELL_AURA_90                                           = 90,   // old SPELL_AURA_MOD_RESIST_CHANCE
    SPELL_AURA_MOD_DETECT_RANGE                             = 91,
    SPELL_AURA_PREVENTS_FLEEING                             = 92,
    SPELL_AURA_MOD_UNATTACKABLE                             = 93,
    SPELL_AURA_INTERRUPT_REGEN                              = 94,
    SPELL_AURA_GHOST                                        = 95,
    SPELL_AURA_SPELL_MAGNET                                 = 96,
    SPELL_AURA_MANA_SHIELD                                  = 97,
    SPELL_AURA_MOD_SKILL_TALENT                             = 98,
    SPELL_AURA_MOD_ATTACK_POWER                             = 99,
    SPELL_AURA_AURAS_VISIBLE                                = 100,
    SPELL_AURA_MOD_RESISTANCE_PCT                           = 101,
    SPELL_AURA_MOD_MELEE_ATTACK_POWER_VERSUS                = 102,
    SPELL_AURA_MOD_TOTAL_THREAT                             = 103,
    SPELL_AURA_WATER_WALK                                   = 104,
    SPELL_AURA_FEATHER_FALL                                 = 105,
    SPELL_AURA_HOVER                                        = 106,
    SPELL_AURA_ADD_FLAT_MODIFIER                            = 107,
    SPELL_AURA_ADD_PCT_MODIFIER                             = 108,
    SPELL_AURA_ADD_TARGET_TRIGGER                           = 109,
    SPELL_AURA_MOD_POWER_REGEN_PERCENT                      = 110,
    SPELL_AURA_ADD_CASTER_HIT_TRIGGER                       = 111,
    SPELL_AURA_OVERRIDE_CLASS_SCRIPTS                       = 112,
    SPELL_AURA_MOD_RANGED_DAMAGE_TAKEN                      = 113,
    SPELL_AURA_MOD_RANGED_DAMAGE_TAKEN_PCT                  = 114,
    SPELL_AURA_MOD_HEALING                                  = 115,
    SPELL_AURA_MOD_REGEN_DURING_COMBAT                      = 116,
    SPELL_AURA_MOD_MECHANIC_RESISTANCE                      = 117,
    SPELL_AURA_MOD_HEALING_PCT                              = 118,
    SPELL_AURA_119                                          = 119,  // old SPELL_AURA_SHARE_PET_TRACKING
    SPELL_AURA_UNTRACKABLE                                  = 120,
    SPELL_AURA_EMPATHY                                      = 121,
    SPELL_AURA_MOD_OFFHAND_DAMAGE_PCT                       = 122,
    SPELL_AURA_MOD_TARGET_RESISTANCE                        = 123,
    SPELL_AURA_MOD_RANGED_ATTACK_POWER                      = 124,
    SPELL_AURA_MOD_MELEE_DAMAGE_TAKEN                       = 125,
    SPELL_AURA_MOD_MELEE_DAMAGE_TAKEN_PCT                   = 126,
    SPELL_AURA_RANGED_ATTACK_POWER_ATTACKER_BONUS           = 127,
    SPELL_AURA_MOD_POSSESS_PET                              = 128,
    SPELL_AURA_MOD_SPEED_ALWAYS                             = 129,
    SPELL_AURA_MOD_MOUNTED_SPEED_ALWAYS                     = 130,
    SPELL_AURA_MOD_RANGED_ATTACK_POWER_VERSUS               = 131,
    SPELL_AURA_MOD_INCREASE_ENERGY_PERCENT                  = 132,
    SPELL_AURA_MOD_INCREASE_HEALTH_PERCENT                  = 133,
    SPELL_AURA_MOD_MANA_REGEN_INTERRUPT                     = 134,
    SPELL_AURA_MOD_HEALING_DONE                             = 135,
    SPELL_AURA_MOD_HEALING_DONE_PERCENT                     = 136,
    SPELL_AURA_MOD_TOTAL_STAT_PERCENTAGE                    = 137,
    SPELL_AURA_MOD_MELEE_HASTE                              = 138,
    SPELL_AURA_FORCE_REACTION                               = 139,
    SPELL_AURA_MOD_RANGED_HASTE                             = 140,
    SPELL_AURA_MOD_RANGED_AMMO_HASTE                        = 141,
    SPELL_AURA_MOD_BASE_RESISTANCE_PCT                      = 142,
    SPELL_AURA_MOD_RESISTANCE_EXCLUSIVE                     = 143,
    SPELL_AURA_SAFE_FALL                                    = 144,
    SPELL_AURA_MOD_PET_TALENT_POINTS                        = 145,
    SPELL_AURA_ALLOW_TAME_PET_TYPE                          = 146,
    SPELL_AURA_MECHANIC_IMMUNITY_MASK                       = 147,
    SPELL_AURA_RETAIN_COMBO_POINTS                          = 148,
    SPELL_AURA_REDUCE_PUSHBACK                              = 149,  //    Reduce Pushback
    SPELL_AURA_MOD_SHIELD_BLOCKVALUE_PCT                    = 150,
    SPELL_AURA_TRACK_STEALTHED                              = 151,  //    Track Stealthed
    SPELL_AURA_MOD_DETECTED_RANGE                           = 152,  //    Mod Detected Range
    SPELL_AURA_SPLIT_DAMAGE_FLAT                            = 153,  //    Split Damage Flat
    SPELL_AURA_MOD_STEALTH_LEVEL                            = 154,  //    Stealth Level Modifier
    SPELL_AURA_MOD_WATER_BREATHING                          = 155,  //    Mod Water Breathing
    SPELL_AURA_MOD_REPUTATION_GAIN                          = 156,  //    Mod Reputation Gain
    SPELL_AURA_PET_DAMAGE_MULTI                             = 157,  //    Mod Pet Damage
    SPELL_AURA_MOD_SHIELD_BLOCKVALUE                        = 158,
    SPELL_AURA_NO_PVP_CREDIT                                = 159,
    SPELL_AURA_MOD_AOE_AVOIDANCE                            = 160,
    SPELL_AURA_MOD_HEALTH_REGEN_IN_COMBAT                   = 161,
    SPELL_AURA_POWER_BURN                                   = 162,
    SPELL_AURA_MOD_CRIT_DAMAGE_BONUS                        = 163,
    SPELL_AURA_164                                          = 164,
    SPELL_AURA_MELEE_ATTACK_POWER_ATTACKER_BONUS            = 165,
    SPELL_AURA_MOD_ATTACK_POWER_PCT                         = 166,
    SPELL_AURA_MOD_RANGED_ATTACK_POWER_PCT                  = 167,
    SPELL_AURA_MOD_DAMAGE_DONE_VERSUS                       = 168,
    SPELL_AURA_MOD_CRIT_PERCENT_VERSUS                      = 169,
    SPELL_AURA_DETECT_AMORE                                 = 170,
    SPELL_AURA_MOD_SPEED_NOT_STACK                          = 171,
    SPELL_AURA_MOD_MOUNTED_SPEED_NOT_STACK                  = 172,
    SPELL_AURA_173                                          = 173,  // old SPELL_AURA_ALLOW_CHAMPION_SPELLS
    SPELL_AURA_MOD_SPELL_DAMAGE_OF_STAT_PERCENT             = 174,  // by defeult intelect, dependent from SPELL_AURA_MOD_SPELL_HEALING_OF_STAT_PERCENT
    SPELL_AURA_MOD_SPELL_HEALING_OF_STAT_PERCENT            = 175,
    SPELL_AURA_SPIRIT_OF_REDEMPTION                         = 176,
    SPELL_AURA_AOE_CHARM                                    = 177,
    SPELL_AURA_MOD_DEBUFF_RESISTANCE                        = 178,
    SPELL_AURA_MOD_ATTACKER_SPELL_CRIT_CHANCE               = 179,
    SPELL_AURA_MOD_FLAT_SPELL_DAMAGE_VERSUS                 = 180,
    SPELL_AURA_181                                          = 181,  // old SPELL_AURA_MOD_FLAT_SPELL_CRIT_DAMAGE_VERSUS - possible flat spell crit damage versus
    SPELL_AURA_MOD_RESISTANCE_OF_STAT_PERCENT               = 182,
    SPELL_AURA_MOD_CRITICAL_THREAT                          = 183,
    SPELL_AURA_MOD_ATTACKER_MELEE_HIT_CHANCE                = 184,
    SPELL_AURA_MOD_ATTACKER_RANGED_HIT_CHANCE               = 185,
    SPELL_AURA_MOD_ATTACKER_SPELL_HIT_CHANCE                = 186,
    SPELL_AURA_MOD_ATTACKER_MELEE_CRIT_CHANCE               = 187,
    SPELL_AURA_MOD_ATTACKER_RANGED_CRIT_CHANCE              = 188,
    SPELL_AURA_MOD_RATING                                   = 189,
    SPELL_AURA_MOD_FACTION_REPUTATION_GAIN                  = 190,
    SPELL_AURA_USE_NORMAL_MOVEMENT_SPEED                    = 191,
    SPELL_AURA_MOD_MELEE_RANGED_HASTE                       = 192,
    SPELL_AURA_MELEE_SLOW                                   = 193,
    SPELL_AURA_MOD_TARGET_ABSORB_SCHOOL                     = 194,
    SPELL_AURA_MOD_TARGET_ABILITY_ABSORB_SCHOOL             = 195,
    SPELL_AURA_MOD_COOLDOWN                                 = 196,  // only 24818 Noxious Breath
    SPELL_AURA_MOD_ATTACKER_SPELL_AND_WEAPON_CRIT_CHANCE    = 197,
    SPELL_AURA_198                                          = 198,  // old SPELL_AURA_MOD_ALL_WEAPON_SKILLS
    SPELL_AURA_MOD_INCREASES_SPELL_PCT_TO_HIT               = 199,
    SPELL_AURA_MOD_XP_PCT                                   = 200,
    SPELL_AURA_FLY                                          = 201,
    SPELL_AURA_IGNORE_COMBAT_RESULT                         = 202,
    SPELL_AURA_MOD_ATTACKER_MELEE_CRIT_DAMAGE               = 203,
    SPELL_AURA_MOD_ATTACKER_RANGED_CRIT_DAMAGE              = 204,
    SPELL_AURA_MOD_SCHOOL_CRIT_DMG_TAKEN                    = 205,
    SPELL_AURA_MOD_INCREASE_VEHICLE_FLIGHT_SPEED            = 206,
    SPELL_AURA_MOD_INCREASE_MOUNTED_FLIGHT_SPEED            = 207,
    SPELL_AURA_MOD_INCREASE_FLIGHT_SPEED                    = 208,
    SPELL_AURA_MOD_MOUNTED_FLIGHT_SPEED_ALWAYS              = 209,
    SPELL_AURA_MOD_VEHICLE_SPEED_ALWAYS                     = 210,
    SPELL_AURA_MOD_FLIGHT_SPEED_NOT_STACK                   = 211,
    SPELL_AURA_MOD_RANGED_ATTACK_POWER_OF_STAT_PERCENT      = 212,
    SPELL_AURA_MOD_RAGE_FROM_DAMAGE_DEALT                   = 213,
    SPELL_AURA_214                                          = 214,
    SPELL_AURA_ARENA_PREPARATION                            = 215,
    SPELL_AURA_HASTE_SPELLS                                 = 216,
    SPELL_AURA_MOD_MELEE_HASTE_2                            = 217, // NYI
    SPELL_AURA_HASTE_RANGED                                 = 218,
    SPELL_AURA_MOD_MANA_REGEN_FROM_STAT                     = 219,
    SPELL_AURA_MOD_RATING_FROM_STAT                         = 220,
    SPELL_AURA_MOD_DETAUNT                                  = 221,
    SPELL_AURA_222                                          = 222,
    SPELL_AURA_RAID_PROC_FROM_CHARGE                        = 223,
    SPELL_AURA_224                                          = 224,
    SPELL_AURA_RAID_PROC_FROM_CHARGE_WITH_VALUE             = 225,
    SPELL_AURA_PERIODIC_DUMMY                               = 226,
    SPELL_AURA_PERIODIC_TRIGGER_SPELL_WITH_VALUE            = 227,
    SPELL_AURA_DETECT_STEALTH                               = 228,
    SPELL_AURA_MOD_AOE_DAMAGE_AVOIDANCE                     = 229,
    SPELL_AURA_230                                          = 230,
    SPELL_AURA_PROC_TRIGGER_SPELL_WITH_VALUE                = 231,
    SPELL_AURA_MECHANIC_DURATION_MOD                        = 232,
    SPELL_AURA_CHANGE_MODEL_FOR_ALL_HUMANOIDS               = 233,  // client-side only
    SPELL_AURA_MECHANIC_DURATION_MOD_NOT_STACK              = 234,
    SPELL_AURA_MOD_DISPEL_RESIST                            = 235,
    SPELL_AURA_CONTROL_VEHICLE                              = 236,
    SPELL_AURA_MOD_SPELL_DAMAGE_OF_ATTACK_POWER             = 237,
    SPELL_AURA_MOD_SPELL_HEALING_OF_ATTACK_POWER            = 238,
    SPELL_AURA_MOD_SCALE_2                                  = 239,
    SPELL_AURA_MOD_EXPERTISE                                = 240,
    SPELL_AURA_FORCE_MOVE_FORWARD                           = 241,
    SPELL_AURA_MOD_SPELL_DAMAGE_FROM_HEALING                = 242,
    SPELL_AURA_MOD_FACTION                                  = 243,
    SPELL_AURA_COMPREHEND_LANGUAGE                          = 244,
    SPELL_AURA_MOD_AURA_DURATION_BY_DISPEL                  = 245,
    SPELL_AURA_MOD_AURA_DURATION_BY_DISPEL_NOT_STACK        = 246,
    SPELL_AURA_CLONE_CASTER                                 = 247,
    SPELL_AURA_MOD_COMBAT_RESULT_CHANCE                     = 248,
    SPELL_AURA_CONVERT_RUNE                                 = 249,
    SPELL_AURA_MOD_INCREASE_HEALTH_2                        = 250,
    SPELL_AURA_MOD_ENEMY_DODGE                              = 251,
    SPELL_AURA_MOD_SPEED_SLOW_ALL                           = 252,
    SPELL_AURA_MOD_BLOCK_CRIT_CHANCE                        = 253,
    SPELL_AURA_MOD_DISARM_OFFHAND                           = 254,
    SPELL_AURA_MOD_MECHANIC_DAMAGE_TAKEN_PERCENT            = 255,
    SPELL_AURA_NO_REAGENT_USE                               = 256,
    SPELL_AURA_MOD_TARGET_RESIST_BY_SPELL_CLASS             = 257,
    SPELL_AURA_258                                          = 258,
    SPELL_AURA_MOD_HOT_PCT                                  = 259,
    SPELL_AURA_SCREEN_EFFECT                                = 260,
    SPELL_AURA_PHASE                                        = 261,
    SPELL_AURA_ABILITY_IGNORE_AURASTATE                     = 262,
    SPELL_AURA_ALLOW_ONLY_ABILITY                           = 263,
    SPELL_AURA_264                                          = 264,
    SPELL_AURA_265                                          = 265,
    SPELL_AURA_266                                          = 266,
    SPELL_AURA_MOD_IMMUNE_AURA_APPLY_SCHOOL                 = 267,
    SPELL_AURA_MOD_ATTACK_POWER_OF_STAT_PERCENT = 268,
    SPELL_AURA_MOD_IGNORE_TARGET_RESIST                     = 269,
    SPELL_AURA_MOD_ABILITY_IGNORE_TARGET_RESIST             = 270,  // Possibly need swap vs 195 aura used only in 1 spell Chaos Bolt Passive
    SPELL_AURA_MOD_DAMAGE_FROM_CASTER                       = 271,
    SPELL_AURA_IGNORE_MELEE_RESET                           = 272,
    SPELL_AURA_X_RAY                                        = 273,
    SPELL_AURA_ABILITY_CONSUME_NO_AMMO                      = 274,
    SPELL_AURA_MOD_IGNORE_SHAPESHIFT                        = 275,
    SPELL_AURA_MOD_DAMAGE_DONE_FOR_MECHANIC                 = 276,  // NYI
    SPELL_AURA_MOD_MAX_AFFECTED_TARGETS                     = 277,
    SPELL_AURA_MOD_DISARM_RANGED                            = 278,
    SPELL_AURA_INITIALIZE_IMAGES                            = 279,
    SPELL_AURA_MOD_ARMOR_PENETRATION_PCT                    = 280,
    SPELL_AURA_MOD_HONOR_GAIN_PCT                           = 281,
    SPELL_AURA_MOD_BASE_HEALTH_PCT                          = 282,
    SPELL_AURA_MOD_HEALING_RECEIVED                         = 283,  // Possibly only for some spell family class spells
    SPELL_AURA_LINKED                                       = 284,
    SPELL_AURA_MOD_ATTACK_POWER_OF_ARMOR                    = 285,
    SPELL_AURA_ABILITY_PERIODIC_CRIT                        = 286,
    SPELL_AURA_DEFLECT_SPELLS                               = 287,
    SPELL_AURA_IGNORE_HIT_DIRECTION                         = 288,
    SPELL_AURA_PREVENT_DURABILITY_LOSS                      = 289,
    SPELL_AURA_MOD_CRIT_PCT                                 = 290,
    SPELL_AURA_MOD_XP_QUEST_PCT                             = 291,
    SPELL_AURA_OPEN_STABLE                                  = 292,
    SPELL_AURA_OVERRIDE_SPELLS                              = 293,
    SPELL_AURA_PREVENT_REGENERATE_POWER                     = 294,
    SPELL_AURA_295                                          = 295,
    SPELL_AURA_SET_VEHICLE_ID                               = 296,
    SPELL_AURA_BLOCK_SPELL_FAMILY                           = 297,
    SPELL_AURA_STRANGULATE                                  = 298,
    SPELL_AURA_299                                          = 299,
    SPELL_AURA_SHARE_DAMAGE_PCT                             = 300,
    SPELL_AURA_SCHOOL_HEAL_ABSORB                           = 301,
    SPELL_AURA_302                                          = 302,
    SPELL_AURA_MOD_DAMAGE_DONE_VERSUS_AURASTATE             = 303,
    SPELL_AURA_MOD_FAKE_INEBRIATE                           = 304,
    SPELL_AURA_MOD_MINIMUM_SPEED                            = 305,
    SPELL_AURA_306                                          = 306,
    SPELL_AURA_HEAL_ABSORB_TEST                             = 307,
    SPELL_AURA_MOD_CRIT_CHANCE_FOR_CASTER                   = 308,
    SPELL_AURA_309                                          = 309,
    SPELL_AURA_MOD_CREATURE_AOE_DAMAGE_AVOIDANCE            = 310,
    SPELL_AURA_311                                          = 311,
    SPELL_AURA_312                                          = 312,
    SPELL_AURA_313                                          = 313,
    SPELL_AURA_PREVENT_RESURRECTION                         = 314,
    SPELL_AURA_UNDERWATER_WALKING                           = 315,
    SPELL_AURA_PERIODIC_HASTE                               = 316,
    TOTAL_AURAS                                             = 317
};