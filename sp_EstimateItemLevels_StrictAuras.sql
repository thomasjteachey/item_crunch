CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_EstimateItemLevels_StrictAuras`()
BEGIN
  /* baseline: reuse the existing estimator so we do not regress known behavior */
  CALL helper.sp_EstimateItemLevels();

  /* helper table for any unknown aura budget we infer from Blizzard's advertised ilvl */
  CREATE TABLE IF NOT EXISTS helper.ilvl_unknown_aura_budget (
    entry INT UNSIGNED NOT NULL,
    spellid INT UNSIGNED NOT NULL,
    assumed_ilvl_share DOUBLE NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(entry, spellid)
  ) ENGINE=InnoDB;

  /* constants shared with the scaler so we can identify recognized auras */
  SET @AURA_AP := 99;    SET @AURA_RAP := 124;
  SET @AURA_AP_VERSUS := 102; SET @AURA_RAP_VERSUS := 131;
  SET @AURA_HIT := 54;   SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57; SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_CRIT_MELEE := 308; SET @AURA_CRIT_RANGED := 290;
  SET @AURA_SPELL_PEN := 275;
  SET @AURA_BLOCKVALUE := 158; SET @AURA_BLOCKVALUE_PCT := 150;
  SET @AURA_BLOCK := 51; SET @AURA_PARRY := 47; SET @AURA_DODGE := 49;
  SET @AURA_DAMAGE_SHIELD := 15;
  SET @AURA_MOD_SKILL := 30; SET @AURA_MOD_SKILL_TALENT := 98;
  SET @AURA_SD := 13;    SET @MASK_SD_ALL := 126;
  SET @AURA_HEAL1 := 115; SET @AURA_HEAL2 := 135;
  SET @AURA_MP5 := 85;   SET @AURA_HP5 := 83;

  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells_unknown;
  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells_known;

  /* snapshot all equip spells */
  CREATE TEMPORARY TABLE tmp_equip_spells_unknown(
    entry INT UNSIGNED NOT NULL,
    spellid INT UNSIGNED NOT NULL,
    PRIMARY KEY(entry, spellid)
  ) ENGINE=Memory;

  INSERT INTO tmp_equip_spells_unknown(entry, spellid)
  SELECT entry, spellid_1 FROM lplusworld.item_template WHERE spellid_1<>0 AND spelltrigger_1=1
  UNION DISTINCT
  SELECT entry, spellid_2 FROM lplusworld.item_template WHERE spellid_2<>0 AND spelltrigger_2=1
  UNION DISTINCT
  SELECT entry, spellid_3 FROM lplusworld.item_template WHERE spellid_3<>0 AND spelltrigger_3=1
  UNION DISTINCT
  SELECT entry, spellid_4 FROM lplusworld.item_template WHERE spellid_4<>0 AND spelltrigger_4=1
  UNION DISTINCT
  SELECT entry, spellid_5 FROM lplusworld.item_template WHERE spellid_5<>0 AND spelltrigger_5=1;

  /* detect equip spells we already understand */
  CREATE TEMPORARY TABLE tmp_equip_spells_known(
    entry INT UNSIGNED NOT NULL,
    spellid INT UNSIGNED NOT NULL,
    PRIMARY KEY(entry, spellid)
  ) ENGINE=Memory;

  INSERT INTO tmp_equip_spells_known(entry, spellid)
  SELECT DISTINCT unk.entry, unk.spellid
  FROM tmp_equip_spells_unknown unk
  JOIN dbc.spell_lplus s ON s.`ID` = unk.spellid
  WHERE
        IFNULL(s.EffectAura_1,0) IN (@AURA_AP,@AURA_RAP,@AURA_AP_VERSUS,@AURA_RAP_VERSUS,
                                     @AURA_HIT,@AURA_SPHIT,@AURA_SPCRIT1,@AURA_SPCRIT2,
                                     @AURA_CRIT_GENERIC,@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,
                                     @AURA_BLOCKVALUE,@AURA_BLOCKVALUE_PCT,@AURA_BLOCK,@AURA_PARRY,
                                     @AURA_DODGE,@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT,@AURA_SD,
                                     @AURA_HEAL1,@AURA_HEAL2,@AURA_MP5,@AURA_HP5,@AURA_SPELL_PEN,
                                     @AURA_DAMAGE_SHIELD)
     OR  IFNULL(s.EffectAura_2,0) IN (@AURA_AP,@AURA_RAP,@AURA_AP_VERSUS,@AURA_RAP_VERSUS,
                                     @AURA_HIT,@AURA_SPHIT,@AURA_SPCRIT1,@AURA_SPCRIT2,
                                     @AURA_CRIT_GENERIC,@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,
                                     @AURA_BLOCKVALUE,@AURA_BLOCKVALUE_PCT,@AURA_BLOCK,@AURA_PARRY,
                                     @AURA_DODGE,@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT,@AURA_SD,
                                     @AURA_HEAL1,@AURA_HEAL2,@AURA_MP5,@AURA_HP5,@AURA_SPELL_PEN,
                                     @AURA_DAMAGE_SHIELD)
     OR  IFNULL(s.EffectAura_3,0) IN (@AURA_AP,@AURA_RAP,@AURA_AP_VERSUS,@AURA_RAP_VERSUS,
                                     @AURA_HIT,@AURA_SPHIT,@AURA_SPCRIT1,@AURA_SPCRIT2,
                                     @AURA_CRIT_GENERIC,@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,
                                     @AURA_BLOCKVALUE,@AURA_BLOCKVALUE_PCT,@AURA_BLOCK,@AURA_PARRY,
                                     @AURA_DODGE,@AURA_MOD_SKILL,@AURA_MOD_SKILL_TALENT,@AURA_SD,
                                     @AURA_HEAL1,@AURA_HEAL2,@AURA_MP5,@AURA_HP5,@AURA_SPELL_PEN,
                                     @AURA_DAMAGE_SHIELD)
     OR ((IFNULL(s.EffectAura_1,0)=@AURA_SD AND (IFNULL(s.EffectMiscValue_1, IFNULL(s.EffectMiscValueB_1,0)) & @MASK_SD_ALL)<>0)
      OR (IFNULL(s.EffectAura_2,0)=@AURA_SD AND (IFNULL(s.EffectMiscValue_2, IFNULL(s.EffectMiscValueB_2,0)) & @MASK_SD_ALL)<>0)
      OR (IFNULL(s.EffectAura_3,0)=@AURA_SD AND (IFNULL(s.EffectMiscValue_3, IFNULL(s.EffectMiscValueB_3,0)) & @MASK_SD_ALL)<>0));

  /* unknown equip spells = all equips minus the ones we recognize */
  DELETE FROM tmp_equip_spells_unknown
  WHERE (entry, spellid) IN (SELECT entry, spellid FROM tmp_equip_spells_known);

  /* record the implied budget per unknown aura so scaling can leave them alone */
  DROP TEMPORARY TABLE IF EXISTS tmp_unknown_counts;
  CREATE TEMPORARY TABLE tmp_unknown_counts(
    entry INT UNSIGNED PRIMARY KEY,
    cnt INT UNSIGNED NOT NULL
  ) ENGINE=Memory;

  INSERT INTO tmp_unknown_counts(entry, cnt)
  SELECT entry, COUNT(*) AS cnt
  FROM tmp_equip_spells_unknown
  GROUP BY entry;

  DELETE FROM helper.ilvl_unknown_aura_budget;
  INSERT INTO helper.ilvl_unknown_aura_budget(entry, spellid, assumed_ilvl_share)
  SELECT unk.entry, unk.spellid,
         CASE WHEN cnt.cnt > 0
              THEN GREATEST(CAST(it.ItemLevel AS SIGNED) - CAST(IFNULL(it.trueItemLevel, it.ItemLevel) AS SIGNED), 0) / cnt.cnt
              ELSE 0 END AS assumed_ilvl_share
  FROM tmp_equip_spells_unknown unk
  JOIN tmp_unknown_counts cnt ON cnt.entry = unk.entry
  JOIN lplusworld.item_template it ON it.entry = unk.entry;

  /* for items with unknown auras, pin true ilvl to Blizzard's advertised value */
  UPDATE lplusworld.item_template t
  JOIN tmp_unknown_counts unk ON unk.entry = t.entry
  SET t.trueItemLevel = t.ItemLevel;

  /* caster weapons: advertise the caster-friendly ilvl instead of letting the old estimator overshoot */
  UPDATE lplusworld.item_template t
  SET t.trueItemLevel = t.ItemLevel
  WHERE t.class = 2
    AND IFNULL(t.caster,0) = 1
    AND IFNULL(t.delay,0) > 0;

  DROP TEMPORARY TABLE IF EXISTS tmp_unknown_counts;
  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells_unknown;
  DROP TEMPORARY TABLE IF EXISTS tmp_equip_spells_known;
END
