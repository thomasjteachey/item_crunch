CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ReforgeItemBudget`(
  IN p_entry INT UNSIGNED,
  IN p_remove_csv VARCHAR(255),      -- e.g. 'SPI,RESIST,SDONE'
  IN p_targets_csv VARCHAR(255),     -- explicit targets (optional). If empty, auto uses p_auto
  IN p_mode ENUM('dump','even'),
  IN p_apply TINYINT(1),             -- 0=dry run, 1=apply
  IN p_auto ENUM('NONE','PRIMARY','AURAS','PRIMARY_AURAS','ALL') -- auto-select remaining targets
)
main: BEGIN
  /* weights */
  SET @W_PRIMARY = 230;  SET @W_RESIST  = 230;
  SET @W_AP = 115;       SET @W_RAP     = 92;
  SET @W_HEAL = 100;     SET @W_SD_ALL  = 192; SET @W_SD_ONE = 159;
  SET @W_HIT = 2200;     SET @W_SPHIT   = 2500;
  SET @W_CRIT = 3200;    SET @W_SPCRIT  = 2600;
  SET @W_BLOCK = 3200;   SET @W_PARRY   = 3200;   SET @W_DODGE = 3200;
  SET @W_MP5 = 550;      SET @W_HP5 = 550;

  /* DBC aura ids (Classic) */
  SET @AURA_AP := 99; SET @AURA_RAP := 124;
  SET @AURA_HIT := 54; SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57; SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_MELEE := 308; SET @AURA_CRIT_RANGED := 290; SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_BLOCK := 51; SET @AURA_PARRY := 47; SET @AURA_DODGE := 49;
  SET @AURA_SD := 13;  SET @MASK_SD_ALL := 126;
  SET @AURA_MP5 := 85; SET @AURA_HP5 := 83;

  /* ---- parse remove/target CSVs into temp tables ---- */
  DROP TEMPORARY TABLE IF EXISTS tmp_tokens_rm;
  CREATE TEMPORARY TABLE tmp_tokens_rm(token VARCHAR(32) PRIMARY KEY) ENGINE=Memory;
  IF p_remove_csv IS NOT NULL AND p_remove_csv <> '' THEN
    INSERT INTO tmp_tokens_rm(token)
    SELECT UPPER(TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(p_remove_csv, ',', n.n), ',', -1)))
    FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
          UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10
          UNION ALL SELECT 11 UNION ALL SELECT 12 UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL SELECT 15) n
    WHERE n.n <= 1 + LENGTH(p_remove_csv) - LENGTH(REPLACE(p_remove_csv, ',', ''));
  END IF;

  DROP TEMPORARY TABLE IF EXISTS tmp_tokens_tg;
  CREATE TEMPORARY TABLE tmp_tokens_tg(token VARCHAR(32) PRIMARY KEY) ENGINE=Memory;
  IF p_targets_csv IS NOT NULL AND p_targets_csv <> '' THEN
    INSERT INTO tmp_tokens_tg(token)
    SELECT UPPER(TRIM(SUBSTRING_INDEX(SUBSTRING_INDEX(p_targets_csv, ',', n.n), ',', -1)))
    FROM (SELECT 1 n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
          UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10) n
    WHERE n.n <= 1 + LENGTH(p_targets_csv) - LENGTH(REPLACE(p_targets_csv, ',', ''));
  END IF;

  /* ---- snapshot remove flags (single reads) ---- */
  SET @rm_AGI := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token IN ('AGI','3'));
  SET @rm_STR := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token IN ('STR','4'));
  SET @rm_INT := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token IN ('INT','5'));
  SET @rm_SPI := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token IN ('SPI','6'));
  SET @rm_STA := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token IN ('STA','7'));

  SET @rm_RESIST := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='RESIST');
  SET @rm_HOLY := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='HOLY') OR @rm_RESIST;
  SET @rm_FIRE := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='FIRE') OR @rm_RESIST;
  SET @rm_NATURE := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='NATURE') OR @rm_RESIST;
  SET @rm_FROST := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='FROST') OR @rm_RESIST;
  SET @rm_SHADOW := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='SHADOW') OR @rm_RESIST;
  SET @rm_ARCANE := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='ARCANE') OR @rm_RESIST;

  SET @rm_AP := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='AP');
  SET @rm_RAP := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='RAP');
  SET @rm_HIT := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='HIT');
  SET @rm_CRIT := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='CRIT');
  SET @rm_SPHIT := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='SPHIT');
  SET @rm_SPCRIT := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='SPCRIT');
  SET @rm_BLOCK := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='BLOCK');
  SET @rm_PARRY := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='PARRY');
  SET @rm_DODGE := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='DODGE');
  SET @rm_SDALL := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='SDALL');
  SET @rm_SDONE := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token IN ('SDONE','SDONE_ARC','SDONE_FIR','SDONE_NAT','SDONE_FRO','SDONE_SHA','SDONE_HOL'));
  SET @rm_HEAL := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='HEAL');
  SET @rm_MP5 := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='MP5');
  SET @rm_HP5 := (SELECT COUNT(*)>0 FROM tmp_tokens_rm WHERE token='HP5');

  /* ---- working copies (NO subqueries to tmp_slots in later statements) ---- */
  DROP TEMPORARY TABLE IF EXISTS tmp_slots;
  CREATE TEMPORARY TABLE tmp_slots(slot_no TINYINT PRIMARY KEY, stat_type TINYINT, stat_value INT) ENGINE=Memory;
  INSERT INTO tmp_slots
  SELECT 1,stat_type1,stat_value1 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 2,stat_type2,stat_value2 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 3,stat_type3,stat_value3 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 4,stat_type4,stat_value4 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 5,stat_type5,stat_value5 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 6,stat_type6,stat_value6 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 7,stat_type7,stat_value7 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 8,stat_type8,stat_value8 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 9,stat_type9,stat_value9 FROM lplusworld.item_template WHERE entry=p_entry UNION ALL
  SELECT 10,stat_type10,stat_value10 FROM lplusworld.item_template WHERE entry=p_entry;

  /* Cache current primaries into variables (one-time reads) */
  SET @has_AGI := IFNULL((SELECT SUM(stat_value) FROM tmp_slots WHERE stat_type=3),0);
  SET @has_STR := IFNULL((SELECT SUM(stat_value) FROM tmp_slots WHERE stat_type=4),0);
  SET @has_INT := IFNULL((SELECT SUM(stat_value) FROM tmp_slots WHERE stat_type=5),0);
  SET @has_SPI := IFNULL((SELECT SUM(stat_value) FROM tmp_slots WHERE stat_type=6),0);
  SET @has_STA := IFNULL((SELECT SUM(stat_value) FROM tmp_slots WHERE stat_type=7),0);

  /* resists -> cache */
  DROP TEMPORARY TABLE IF EXISTS tmp_res;
  CREATE TEMPORARY TABLE tmp_res AS
  SELECT entry, holy_res, fire_res, nature_res, frost_res, shadow_res, arcane_res
  FROM lplusworld.item_template WHERE entry=p_entry;

  SET @r_holy   := (SELECT holy_res   FROM tmp_res);
  SET @r_fire   := (SELECT fire_res   FROM tmp_res);
  SET @r_nature := (SELECT nature_res FROM tmp_res);
  SET @r_frost  := (SELECT frost_res  FROM tmp_res);
  SET @r_shadow := (SELECT shadow_res FROM tmp_res);
  SET @r_arcane := (SELECT arcane_res FROM tmp_res);

  /* on-equip spells -> per-spell magnitudes */
  DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
  CREATE TEMPORARY TABLE tmp_item_spells(entry INT, sid INT, PRIMARY KEY(entry,sid)) ENGINE=Memory;
  INSERT INTO tmp_item_spells
  SELECT entry,spellid_1 FROM lplusworld.item_template WHERE entry=p_entry AND spellid_1<>0 AND spelltrigger_1=1
  UNION SELECT entry,spellid_2 FROM lplusworld.item_template WHERE entry=p_entry AND spellid_2<>0 AND spelltrigger_2=1
  UNION SELECT entry,spellid_3 FROM lplusworld.item_template WHERE entry=p_entry AND spellid_3<>0 AND spelltrigger_3=1
  UNION SELECT entry,spellid_4 FROM lplusworld.item_template WHERE entry=p_entry AND spellid_4<>0 AND spelltrigger_4=1
  UNION SELECT entry,spellid_5 FROM lplusworld.item_template WHERE entry=p_entry AND spellid_5<>0 AND spelltrigger_5=1;

  DROP TEMPORARY TABLE IF EXISTS tmp_auras;
  CREATE TEMPORARY TABLE tmp_auras AS
  SELECT es.entry, es.sid,
         GREATEST(
           MAX(CASE WHEN s.EffectAura_1=@AURA_AP  THEN s.EffectBasePoints_1+1
                    WHEN s.EffectAura_2=@AURA_AP  THEN s.EffectBasePoints_2+1
                    WHEN s.EffectAura_3=@AURA_AP  THEN s.EffectBasePoints_3+1 ELSE 0 END), 0) AS ap_amt,
         GREATEST(
           MAX(CASE WHEN s.EffectAura_1=@AURA_RAP THEN s.EffectBasePoints_1+1
                    WHEN s.EffectAura_2=@AURA_RAP THEN s.EffectBasePoints_2+1
                    WHEN s.EffectAura_3=@AURA_RAP THEN s.EffectBasePoints_3+1 ELSE 0 END), 0) AS rap_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_HIT   THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_HIT   THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_HIT   THEN s.EffectBasePoints_3+1 ELSE 0 END) AS hit_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_SPHIT THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_SPHIT THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_SPHIT THEN s.EffectBasePoints_3+1 ELSE 0 END) AS sphit_amt,
         SUM(CASE WHEN s.EffectAura_1 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3 IN (@AURA_SPCRIT1,@AURA_SPCRIT2) THEN s.EffectBasePoints_3+1 ELSE 0 END) AS spcrit_amt,
         SUM(CASE WHEN s.EffectAura_1 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3 IN (@AURA_CRIT_MELEE,@AURA_CRIT_RANGED,@AURA_CRIT_GENERIC) THEN s.EffectBasePoints_3+1 ELSE 0 END) AS crit_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_BLOCK THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_BLOCK THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_BLOCK THEN s.EffectBasePoints_3+1 ELSE 0 END) AS block_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_PARRY THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_PARRY THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_PARRY THEN s.EffectBasePoints_3+1 ELSE 0 END) AS parry_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_DODGE THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_DODGE THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_DODGE THEN s.EffectBasePoints_3+1 ELSE 0 END) AS dodge_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)=@MASK_SD_ALL THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)=@MASK_SD_ALL THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)=@MASK_SD_ALL THEN s.EffectBasePoints_3+1 ELSE 0 END) AS sd_all_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>@MASK_SD_ALL THEN s.EffectBasePoints_3+1 ELSE 0 END) AS sd_one_amt,
         SUM(CASE WHEN s.EffectAura_1 IN (115,135) THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2 IN (115,135) THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3 IN (115,135) THEN s.EffectBasePoints_3+1 ELSE 0 END) AS heal_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_MP5 AND s.EffectMiscValue_1=0 THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_MP5 AND s.EffectMiscValue_2=0 THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_MP5 AND s.EffectMiscValue_3=0 THEN s.EffectBasePoints_3+1 ELSE 0 END) AS mp5_amt,
         SUM(CASE WHEN s.EffectAura_1=@AURA_HP5 THEN s.EffectBasePoints_1+1
                  WHEN s.EffectAura_2=@AURA_HP5 THEN s.EffectBasePoints_2+1
                  WHEN s.EffectAura_3=@AURA_HP5 THEN s.EffectBasePoints_3+1 ELSE 0 END) AS hp5_amt
  FROM tmp_item_spells es
  JOIN dbc.spell_lplus s ON s.ID = es.sid
  GROUP BY es.entry, es.sid;

  /* cache aura totals as variables (one-time) */
  SET @ap_amt    := IFNULL((SELECT SUM(ap_amt)    FROM tmp_auras),0);
  SET @rap_amt   := IFNULL((SELECT SUM(rap_amt)   FROM tmp_auras),0);
  SET @hit_amt   := IFNULL((SELECT SUM(hit_amt)   FROM tmp_auras),0);
  SET @sphit_amt := IFNULL((SELECT SUM(sphit_amt) FROM tmp_auras),0);
  SET @spcrit_amt:= IFNULL((SELECT SUM(spcrit_amt)FROM tmp_auras),0);
  SET @crit_amt  := IFNULL((SELECT SUM(crit_amt)  FROM tmp_auras),0);
  SET @block_amt := IFNULL((SELECT SUM(block_amt) FROM tmp_auras),0);
  SET @parry_amt := IFNULL((SELECT SUM(parry_amt) FROM tmp_auras),0);
  SET @dodge_amt := IFNULL((SELECT SUM(dodge_amt) FROM tmp_auras),0);
  SET @sd_all_amt:= IFNULL((SELECT SUM(sd_all_amt)FROM tmp_auras),0);
  SET @sd_one_amt:= IFNULL((SELECT SUM(sd_one_amt)FROM tmp_auras),0);
  SET @heal_amt  := IFNULL((SELECT SUM(heal_amt)  FROM tmp_auras),0);
  SET @mp5_amt   := IFNULL((SELECT SUM(mp5_amt)   FROM tmp_auras),0);
  SET @hp5_amt   := IFNULL((SELECT SUM(hp5_amt)   FROM tmp_auras),0);

  /* ---- compute removable budget (and zero things) ---- */
  SET @B_remove := 0.0;
  SET @B_remove := @B_remove
    + IF(@rm_AGI, POW(GREATEST(0,@has_AGI*@W_PRIMARY),1.5),0)
    + IF(@rm_STR, POW(GREATEST(0,@has_STR*@W_PRIMARY),1.5),0)
    + IF(@rm_INT, POW(GREATEST(0,@has_INT*@W_PRIMARY),1.5),0)
    + IF(@rm_SPI, POW(GREATEST(0,@has_SPI*@W_PRIMARY),1.5),0)
    + IF(@rm_STA, POW(GREATEST(0,@has_STA*@W_PRIMARY),1.5),0);

  IF @rm_AGI THEN UPDATE tmp_slots SET stat_value=0 WHERE stat_type=3; END IF;
  IF @rm_STR THEN UPDATE tmp_slots SET stat_value=0 WHERE stat_type=4; END IF;
  IF @rm_INT THEN UPDATE tmp_slots SET stat_value=0 WHERE stat_type=5; END IF;
  IF @rm_SPI THEN UPDATE tmp_slots SET stat_value=0 WHERE stat_type=6; END IF;
  IF @rm_STA THEN UPDATE tmp_slots SET stat_value=0 WHERE stat_type=7; END IF;

  SET @B_remove := @B_remove
    + IF(@rm_HOLY,   POW(GREATEST(0,@r_holy  *@W_RESIST),1.5),0)
    + IF(@rm_FIRE,   POW(GREATEST(0,@r_fire  *@W_RESIST),1.5),0)
    + IF(@rm_NATURE, POW(GREATEST(0,@r_nature*@W_RESIST),1.5),0)
    + IF(@rm_FROST,  POW(GREATEST(0,@r_frost *@W_RESIST),1.5),0)
    + IF(@rm_SHADOW, POW(GREATEST(0,@r_shadow*@W_RESIST),1.5),0)
    + IF(@rm_ARCANE, POW(GREATEST(0,@r_arcane*@W_RESIST),1.5),0);

  IF p_apply=1 THEN
    UPDATE lplusworld.item_template
      SET holy_res   = IF(@rm_HOLY,0,holy_res),
          fire_res   = IF(@rm_FIRE,0,fire_res),
          nature_res = IF(@rm_NATURE,0,nature_res),
          frost_res  = IF(@rm_FROST,0,frost_res),
          shadow_res = IF(@rm_SHADOW,0,shadow_res),
          arcane_res = IF(@rm_ARCANE,0,arcane_res)
    WHERE entry=p_entry;
  END IF;

  SET @B_remove := @B_remove
    + POW(IF(@rm_AP,    @ap_amt,0)     * @W_AP,    1.5)
    + POW(IF(@rm_RAP,   @rap_amt,0)    * @W_RAP,   1.5)
    + POW(IF(@rm_HIT,   @hit_amt,0)    * @W_HIT,   1.5)
    + POW(IF(@rm_CRIT,  @crit_amt,0)   * @W_CRIT,  1.5)
    + POW(IF(@rm_BLOCK, @block_amt,0) * @W_BLOCK, 1.5)
    + POW(IF(@rm_PARRY, @parry_amt,0) * @W_PARRY, 1.5)
    + POW(IF(@rm_DODGE, @dodge_amt,0) * @W_DODGE, 1.5)
    + POW(IF(@rm_SPHIT, @sphit_amt,0)  * @W_SPHIT, 1.5)
    + POW(IF(@rm_SPCRIT,@spcrit_amt,0) * @W_SPCRIT,1.5)
    + POW(IF(@rm_SDALL, @sd_all_amt,0) * @W_SD_ALL,1.5)
    + POW(IF(@rm_SDONE, @sd_one_amt,0) * @W_SD_ONE,1.5)
    + POW(IF(@rm_HEAL,  @heal_amt,0)   * @W_HEAL,  1.5)
    + POW(IF(@rm_MP5,   @mp5_amt,0)    * @W_MP5,   1.5)
    + POW(IF(@rm_HP5,   @hp5_amt,0)    * @W_HP5,   1.5);

  SET @removedAuraMag :=
      (IF(@rm_AP,@ap_amt,0) + IF(@rm_RAP,@rap_amt,0) + IF(@rm_HIT,@hit_amt,0) + IF(@rm_CRIT,@crit_amt,0) +
       IF(@rm_BLOCK,@block_amt,0) + IF(@rm_PARRY,@parry_amt,0) + IF(@rm_DODGE,@dodge_amt,0) +
       IF(@rm_SPHIT,@sphit_amt,0) + IF(@rm_SPCRIT,@spcrit_amt,0) + IF(@rm_SDALL,@sd_all_amt,0) +
       IF(@rm_SDONE,@sd_one_amt,0) + IF(@rm_HEAL,@heal_amt,0) + IF(@rm_MP5,@mp5_amt,0) + IF(@rm_HP5,@hp5_amt,0));

  IF @B_remove <= 0 THEN
    SELECT 'No removable budget found' AS msg, @B_remove AS budget;
    LEAVE main;
  END IF;

  /* ---- target universe and selection (no tmp_slots references) ---- */
  DROP TEMPORARY TABLE IF EXISTS tmp_target_defs;
  CREATE TEMPORARY TABLE tmp_target_defs(
    token VARCHAR(32) PRIMARY KEY, w DOUBLE, kind ENUM('PRIMARY','AURA','RESIST')
  ) ENGINE=Memory;

  INSERT INTO tmp_target_defs(token,w,kind) VALUES
    ('STR',@W_PRIMARY,'PRIMARY'),('AGI',@W_PRIMARY,'PRIMARY'),
    ('INT',@W_PRIMARY,'PRIMARY'),('SPI',@W_PRIMARY,'PRIMARY'),
    ('STA',@W_PRIMARY,'PRIMARY'),
    ('RESIST',@W_RESIST,'RESIST'),('HOLY',@W_RESIST,'RESIST'),
    ('FIRE',@W_RESIST,'RESIST'),('NATURE',@W_RESIST,'RESIST'),
    ('FROST',@W_RESIST,'RESIST'),('SHADOW',@W_RESIST,'RESIST'),
    ('ARCANE',@W_RESIST,'RESIST'),
    ('AP',@W_AP,'AURA'),('RAP',@W_RAP,'AURA'),
    ('HIT',@W_HIT,'AURA'),('CRIT',@W_CRIT,'AURA'),
    ('BLOCK',@W_BLOCK,'AURA'),('PARRY',@W_PARRY,'AURA'),('DODGE',@W_DODGE,'AURA'),
    ('SPHIT',@W_SPHIT,'AURA'),('SPCRIT',@W_SPCRIT,'AURA'),
    ('SDALL',@W_SD_ALL,'AURA'),('SDONE',@W_SD_ONE,'AURA'),
    ('HEAL',@W_HEAL,'AURA'),('MP5',@W_MP5,'AURA'),('HP5',@W_HP5,'AURA');

  DROP TEMPORARY TABLE IF EXISTS tmp_targets;
  CREATE TEMPORARY TABLE tmp_targets(token VARCHAR(32) PRIMARY KEY, w DOUBLE, kind ENUM('PRIMARY','AURA','RESIST')) ENGINE=Memory;

  IF (p_targets_csv IS NOT NULL AND p_targets_csv <> '') THEN
    INSERT INTO tmp_targets(token,w,kind)
    SELECT t.token, d.w, d.kind FROM tmp_tokens_tg t JOIN tmp_target_defs d USING(token);

  ELSEIF p_auto <> 'NONE' THEN
    /* primaries via variables (no tmp_slots reuse) */
    IF p_auto IN ('PRIMARY','PRIMARY_AURAS','ALL') THEN
      INSERT INTO tmp_targets(token,w,kind)
      SELECT 'STR', @W_PRIMARY,'PRIMARY' FROM DUAL WHERE @rm_STR=0 AND @has_STR>0
      UNION ALL SELECT 'AGI', @W_PRIMARY,'PRIMARY' FROM DUAL WHERE @rm_AGI=0 AND @has_AGI>0
      UNION ALL SELECT 'INT', @W_PRIMARY,'PRIMARY' FROM DUAL WHERE @rm_INT=0 AND @has_INT>0
      UNION ALL SELECT 'SPI', @W_PRIMARY,'PRIMARY' FROM DUAL WHERE @rm_SPI=0 AND @has_SPI>0
      UNION ALL SELECT 'STA', @W_PRIMARY,'PRIMARY' FROM DUAL WHERE @rm_STA=0 AND @has_STA>0;
    END IF;

    /* auras via cached totals */
    IF p_auto IN ('AURAS','PRIMARY_AURAS','ALL') THEN
      INSERT INTO tmp_targets(token,w,kind)
      SELECT 'AP',    @W_AP,    'AURA' FROM DUAL WHERE @rm_AP=0    AND @ap_amt    > 0
      UNION ALL SELECT 'RAP',   @W_RAP,   'AURA' FROM DUAL WHERE @rm_RAP=0   AND @rap_amt   > 0
      UNION ALL SELECT 'HIT',   @W_HIT,   'AURA' FROM DUAL WHERE @rm_HIT=0   AND @hit_amt   > 0
      UNION ALL SELECT 'CRIT',  @W_CRIT,  'AURA' FROM DUAL WHERE @rm_CRIT=0  AND @crit_amt  > 0
      UNION ALL SELECT 'BLOCK', @W_BLOCK, 'AURA' FROM DUAL WHERE @rm_BLOCK=0 AND @block_amt > 0
      UNION ALL SELECT 'PARRY', @W_PARRY, 'AURA' FROM DUAL WHERE @rm_PARRY=0 AND @parry_amt > 0
      UNION ALL SELECT 'DODGE', @W_DODGE, 'AURA' FROM DUAL WHERE @rm_DODGE=0 AND @dodge_amt > 0
      UNION ALL SELECT 'SPHIT', @W_SPHIT, 'AURA' FROM DUAL WHERE @rm_SPHIT=0 AND @sphit_amt > 0
      UNION ALL SELECT 'SPCRIT',@W_SPCRIT,'AURA' FROM DUAL WHERE @rm_SPCRIT=0 AND @spcrit_amt> 0
      UNION ALL SELECT 'SDALL', @W_SD_ALL,'AURA' FROM DUAL WHERE @rm_SDALL=0 AND @sd_all_amt> 0
      UNION ALL SELECT 'SDONE', @W_SD_ONE,'AURA' FROM DUAL WHERE @rm_SDONE=0 AND @sd_one_amt> 0
      UNION ALL SELECT 'HEAL',  @W_HEAL,  'AURA' FROM DUAL WHERE @rm_HEAL=0  AND @heal_amt  > 0
      UNION ALL SELECT 'MP5',   @W_MP5,   'AURA' FROM DUAL WHERE @rm_MP5=0   AND @mp5_amt   > 0
      UNION ALL SELECT 'HP5',   @W_HP5,   'AURA' FROM DUAL WHERE @rm_HP5=0   AND @hp5_amt   > 0
      ON DUPLICATE KEY UPDATE token=token;
    END IF;

    /* resists only when ALL */
    IF p_auto='ALL' THEN
      INSERT INTO tmp_targets(token,w,kind)
      SELECT 'HOLY',   @W_RESIST,'RESIST' FROM DUAL WHERE @rm_HOLY=0   AND @r_holy   > 0
      UNION ALL SELECT 'FIRE',   @W_RESIST,'RESIST' FROM DUAL WHERE @rm_FIRE=0   AND @r_fire   > 0
      UNION ALL SELECT 'NATURE', @W_RESIST,'RESIST' FROM DUAL WHERE @rm_NATURE=0 AND @r_nature > 0
      UNION ALL SELECT 'FROST',  @W_RESIST,'RESIST' FROM DUAL WHERE @rm_FROST=0  AND @r_frost  > 0
      UNION ALL SELECT 'SHADOW', @W_RESIST,'RESIST' FROM DUAL WHERE @rm_SHADOW=0 AND @r_shadow > 0
      UNION ALL SELECT 'ARCANE', @W_RESIST,'RESIST' FROM DUAL WHERE @rm_ARCANE=0 AND @r_arcane > 0
      ON DUPLICATE KEY UPDATE token=token;
    END IF;
  END IF;

  IF (SELECT COUNT(*) FROM tmp_targets)=0 THEN
    SELECT 'No targets detected (empty p_targets_csv and p_auto=NONE?)' AS msg;
    LEAVE main;
  END IF;

  SET @k := (SELECT COUNT(*) FROM tmp_targets);
  SET @deltaB := CASE WHEN p_mode='even' AND @k>0 THEN @B_remove/@k ELSE @B_remove END;

  /* stage aura adds */
  DROP TEMPORARY TABLE IF EXISTS tmp_add_auras;
  CREATE TEMPORARY TABLE tmp_add_auras(aura VARCHAR(16) PRIMARY KEY, magnitude DOUBLE) ENGINE=Memory;

  /* ---- distribute ---- */
  IF p_mode='dump' THEN
    SET @first_token := (SELECT token FROM tmp_targets LIMIT 1);
    SET @w := (SELECT w FROM tmp_targets WHERE token=@first_token);
    SET @kind := (SELECT kind FROM tmp_targets WHERE token=@first_token);

    IF @kind='AURA' THEN
      INSERT INTO tmp_add_auras(aura,magnitude) VALUES (@first_token, POW(@B_remove, 2.0/3.0) / @w)
      ON DUPLICATE KEY UPDATE magnitude = magnitude + VALUES(magnitude);

    ELSEIF @kind='PRIMARY' THEN
      SET @st := CASE WHEN @first_token='AGI' THEN 3 WHEN @first_token='STR' THEN 4 WHEN @first_token='INT' THEN 5
                      WHEN @first_token='SPI' THEN 6 WHEN @first_token='STA' THEN 7 END;
      /* pick cached current value */
      SET @cur := CASE @st WHEN 3 THEN @has_AGI WHEN 4 THEN @has_STR WHEN 5 THEN @has_INT WHEN 6 THEN @has_SPI WHEN 7 THEN @has_STA END;
      SET @new := POW( POW(@cur*@w,1.5) + @B_remove, 2.0/3.0) / @w;

      IF EXISTS(SELECT 1 FROM tmp_slots WHERE stat_type=@st) THEN
        UPDATE tmp_slots SET stat_value=ROUND(@new) WHERE stat_type=@st LIMIT 1;
      ELSEIF EXISTS(SELECT 1 FROM tmp_slots WHERE stat_type=0) THEN
        UPDATE tmp_slots SET stat_type=@st, stat_value=ROUND(@new) WHERE stat_type=0 LIMIT 1;
      ELSE
        UPDATE tmp_slots SET stat_type=@st, stat_value=ROUND(@new) WHERE slot_no=1;
      END IF;

    ELSE
      /* RESIST dump (default to shadow if generic) */
      SET @col := (CASE
        WHEN @first_token='HOLY'   THEN 'holy_res'
        WHEN @first_token='FIRE'   THEN 'fire_res'
        WHEN @first_token='NATURE' THEN 'nature_res'
        WHEN @first_token='FROST'  THEN 'frost_res'
        WHEN @first_token='SHADOW' THEN 'shadow_res'
        WHEN @first_token='ARCANE' THEN 'arcane_res'
        ELSE 'shadow_res' END);
      SET @v := CASE @col
                WHEN 'holy_res' THEN @r_holy WHEN 'fire_res' THEN @r_fire WHEN 'nature_res' THEN @r_nature
                WHEN 'frost_res' THEN @r_frost WHEN 'shadow_res' THEN @r_shadow WHEN 'arcane_res' THEN @r_arcane END;
      SET @new := POW( POW(@v*@W_RESIST,1.5) + @B_remove, 2.0/3.0) / @W_RESIST;
      IF p_apply=1 THEN
        SET @sql := CONCAT('UPDATE lplusworld.item_template SET ',@col,'=',ROUND(@new),' WHERE entry=',p_entry);
        PREPARE x FROM @sql; EXECUTE x; DEALLOCATE PREPARE x;
      END IF;
    END IF;

  ELSE /* even */
    /* primaries: build target rows using variables (no tmp_slots in subqueries) */
    DROP TEMPORARY TABLE IF EXISTS tmp_tprim;
    CREATE TEMPORARY TABLE tmp_tprim(token VARCHAR(32) PRIMARY KEY, w DOUBLE, st TINYINT, cur DOUBLE) ENGINE=Memory;

    INSERT INTO tmp_tprim(token,w,st,cur)
    SELECT token,w,
           CASE token WHEN 'AGI' THEN 3 WHEN 'STR' THEN 4 WHEN 'INT' THEN 5 WHEN 'SPI' THEN 6 WHEN 'STA' THEN 7 END AS st,
           CASE token WHEN 'AGI' THEN @has_AGI WHEN 'STR' THEN @has_STR WHEN 'INT' THEN @has_INT
                      WHEN 'SPI' THEN @has_SPI WHEN 'STA' THEN @has_STA END AS cur
    FROM tmp_targets WHERE kind='PRIMARY';

    UPDATE tmp_tprim SET cur = POW( POW(cur*w,1.5) + @deltaB, 2.0/3.0) / w;

    /* apply new primary values */
    UPDATE tmp_slots s JOIN tmp_tprim tp ON tp.st = s.stat_type
    SET s.stat_value = ROUND(tp.cur);

    /* place new primaries if missing by using an empty slot (or slot 1 fallback) */
    IF EXISTS(SELECT 1 FROM tmp_tprim tp WHERE NOT EXISTS(SELECT 1 FROM tmp_slots WHERE stat_type=tp.st)) THEN
      SET @empty := (SELECT slot_no FROM tmp_slots WHERE stat_type=0 LIMIT 1);
      IF @empty IS NULL THEN SET @empty := 1; END IF;
      UPDATE tmp_slots s
      JOIN (SELECT st, ROUND(cur) AS cur FROM tmp_tprim LIMIT 1) x
      SET s.stat_type = x.st, s.stat_value = x.cur
      WHERE s.slot_no=@empty;
    END IF;

    /* auras (stage only) */
    INSERT INTO tmp_add_auras(aura,magnitude)
    SELECT token, POW(@deltaB, 2.0/3.0) / w
    FROM tmp_targets WHERE kind='AURA'
    ON DUPLICATE KEY UPDATE magnitude = magnitude + VALUES(magnitude);

    /* resists (first resist target only) */
    IF EXISTS(SELECT 1 FROM tmp_targets WHERE kind='RESIST') AND p_apply=1 THEN
      SET @col := (SELECT CASE token
                   WHEN 'HOLY' THEN 'holy_res' WHEN 'FIRE' THEN 'fire_res' WHEN 'NATURE' THEN 'nature_res'
                   WHEN 'FROST' THEN 'frost_res' WHEN 'SHADOW' THEN 'shadow_res' WHEN 'ARCANE' THEN 'arcane_res'
                   ELSE 'shadow_res' END FROM tmp_targets WHERE kind='RESIST' LIMIT 1);
      SET @v := CASE @col
                WHEN 'holy_res' THEN @r_holy WHEN 'fire_res' THEN @r_fire WHEN 'nature_res' THEN @r_nature
                WHEN 'frost_res' THEN @r_frost WHEN 'shadow_res' THEN @r_shadow WHEN 'arcane_res' THEN @r_arcane END;
      SET @new := POW( POW(@v*@W_RESIST,1.5) + @deltaB, 2.0/3.0) / @W_RESIST;
      SET @sql2 := CONCAT('UPDATE lplusworld.item_template SET ',@col,'=',ROUND(@new),' WHERE entry=',p_entry);
      PREPARE y FROM @sql2; EXECUTE y; DEALLOCATE PREPARE y;
    END IF;
  END IF;

  /* ---- write primaries back if applying ---- */
  IF p_apply=1 THEN
    UPDATE lplusworld.item_template t
    JOIN (
      SELECT
        MAX(CASE WHEN slot_no=1 THEN stat_type END) AS st1,  MAX(CASE WHEN slot_no=1 THEN stat_value END) AS sv1,
        MAX(CASE WHEN slot_no=2 THEN stat_type END) AS st2,  MAX(CASE WHEN slot_no=2 THEN stat_value END) AS sv2,
        MAX(CASE WHEN slot_no=3 THEN stat_type END) AS st3,  MAX(CASE WHEN slot_no=3 THEN stat_value END) AS sv3,
        MAX(CASE WHEN slot_no=4 THEN stat_type END) AS st4,  MAX(CASE WHEN slot_no=4 THEN stat_value END) AS sv4,
        MAX(CASE WHEN slot_no=5 THEN stat_type END) AS st5,  MAX(CASE WHEN slot_no=5 THEN stat_value END) AS sv5,
        MAX(CASE WHEN slot_no=6 THEN stat_type END) AS st6,  MAX(CASE WHEN slot_no=6 THEN stat_value END) AS sv6,
        MAX(CASE WHEN slot_no=7 THEN stat_type END) AS st7,  MAX(CASE WHEN slot_no=7 THEN stat_value END) AS sv7,
        MAX(CASE WHEN slot_no=8 THEN stat_type END) AS st8,  MAX(CASE WHEN slot_no=8 THEN stat_value END) AS sv8,
        MAX(CASE WHEN slot_no=9 THEN stat_type END) AS st9,  MAX(CASE WHEN slot_no=9 THEN stat_value END) AS sv9,
        MAX(CASE WHEN slot_no=10 THEN stat_type END) AS st10,MAX(CASE WHEN slot_no=10 THEN stat_value END) AS sv10
      FROM tmp_slots
    ) x
    SET t.stat_type1=x.st1, t.stat_value1=x.sv1,
        t.stat_type2=x.st2, t.stat_value2=x.sv2,
        t.stat_type3=x.st3, t.stat_value3=x.sv3,
        t.stat_type4=x.st4, t.stat_value4=x.sv4,
        t.stat_type5=x.st5, t.stat_value5=x.sv5,
        t.stat_type6=x.st6, t.stat_value6=x.sv6,
        t.stat_type7=x.st7, t.stat_value7=x.sv7,
        t.stat_type8=x.st8, t.stat_value8=x.sv8,
        t.stat_type9=x.st9, t.stat_value9=x.sv9,
        t.stat_type10=x.st10, t.stat_value10=x.sv10
    WHERE t.entry=p_entry;
  END IF;

  /* ---- spells: only if we removed aura budget or targeted auras ---- */
  IF p_apply=1 THEN
    SET @need_spell_work := (@removedAuraMag > 0) OR EXISTS(SELECT 1 FROM tmp_targets WHERE kind='AURA');

    IF @need_spell_work THEN
      /* keep auras not removed, append staged ones using your catalog */
      SET @s1 := (SELECT spellid_1 FROM lplusworld.item_template WHERE entry=p_entry);
      SET @s2 := (SELECT spellid_2 FROM lplusworld.item_template WHERE entry=p_entry);
      SET @s3 := (SELECT spellid_3 FROM lplusworld.item_template WHERE entry=p_entry);
      SET @s4 := (SELECT spellid_4 FROM lplusworld.item_template WHERE entry=p_entry);
      SET @s5 := (SELECT spellid_5 FROM lplusworld.item_template WHERE entry=p_entry);

      DROP TEMPORARY TABLE IF EXISTS tmp_keep_ids;
      CREATE TEMPORARY TABLE tmp_keep_ids(pos TINYINT PRIMARY KEY, spellid INT UNSIGNED) ENGINE=Memory;

      INSERT INTO tmp_keep_ids(pos,spellid)
      SELECT * FROM (
        SELECT 1 pos, @s1 sid UNION ALL SELECT 2, @s2 UNION ALL SELECT 3, @s3 UNION ALL SELECT 4, @s4 UNION ALL SELECT 5, @s5
      ) k WHERE sid IS NOT NULL AND sid<>0
      AND NOT EXISTS (
        SELECT 1 FROM dbc.spell_lplus s
        WHERE s.ID = k.sid AND (
          (@rm_AP     AND @AURA_AP  IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_RAP    AND @AURA_RAP IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_HIT    AND @AURA_HIT IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_CRIT   AND (@AURA_CRIT_MELEE IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)
                        OR  @AURA_CRIT_RANGED IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)
                        OR  @AURA_CRIT_GENERIC IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3))) OR
          (@rm_BLOCK  AND @AURA_BLOCK IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_PARRY  AND @AURA_PARRY IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_DODGE  AND @AURA_DODGE IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_SPHIT  AND @AURA_SPHIT IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_SPCRIT AND (@AURA_SPCRIT1 IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)
                        OR  @AURA_SPCRIT2 IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3))) OR
          (@rm_SDALL  AND (s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)=@MASK_SD_ALL
                        OR  s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)=@MASK_SD_ALL
                        OR  s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)=@MASK_SD_ALL)) OR
          (@rm_SDONE  AND (s.EffectAura_1=@AURA_SD AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_1 & @MASK_SD_ALL)<>@MASK_SD_ALL
                        OR  s.EffectAura_2=@AURA_SD AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_2 & @MASK_SD_ALL)<>@MASK_SD_ALL
                        OR  s.EffectAura_3=@AURA_SD AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>0 AND (s.EffectMiscValue_3 & @MASK_SD_ALL)<>@MASK_SD_ALL)) OR
          (@rm_HEAL   AND (115 IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3) OR 135 IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3))) OR
          (@rm_MP5    AND @AURA_MP5 IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3)) OR
          (@rm_HP5    AND @AURA_HP5 IN (s.EffectAura_1,s.EffectAura_2,s.EffectAura_3))
        )
      );

      /* clear spell slots, re-apply kept */
      UPDATE lplusworld.item_template
      SET spellid_1=0, spellid_2=0, spellid_3=0, spellid_4=0, spellid_5=0,
          spelltrigger_1=0, spelltrigger_2=0, spelltrigger_3=0, spelltrigger_4=0, spelltrigger_5=0
      WHERE entry=p_entry;

      UPDATE lplusworld.item_template t
      JOIN (
        SELECT
          MAX(CASE WHEN pos=1 THEN spellid END) AS s1,
          MAX(CASE WHEN pos=2 THEN spellid END) AS s2,
          MAX(CASE WHEN pos=3 THEN spellid END) AS s3,
          MAX(CASE WHEN pos=4 THEN spellid END) AS s4,
          MAX(CASE WHEN pos=5 THEN spellid END) AS s5
        FROM tmp_keep_ids
      ) k
      SET t.spellid_1=IFNULL(k.s1,0), t.spelltrigger_1=IF(k.s1 IS NULL,0,1),
          t.spellid_2=IFNULL(k.s2,0), t.spelltrigger_2=IF(k.s2 IS NULL,0,1),
          t.spellid_3=IFNULL(k.s3,0), t.spelltrigger_3=IF(k.s3 IS NULL,0,1),
          t.spellid_4=IFNULL(k.s4,0), t.spelltrigger_4=IF(k.s4 IS NULL,0,1),
          t.spellid_5=IFNULL(k.s5,0), t.spelltrigger_5=IF(k.s5 IS NULL,0,1)
      WHERE t.entry=p_entry;

      /* append new auras if any were staged */
      DROP TEMPORARY TABLE IF EXISTS tmp_add_final;
      CREATE TEMPORARY TABLE tmp_add_final AS
      SELECT aura, ROUND(magnitude) AS mag FROM tmp_add_auras WHERE magnitude>0;

      IF (SELECT COUNT(*) FROM tmp_add_final) > 0 THEN
        /* compute empty slots */
        DROP TEMPORARY TABLE IF EXISTS tmp_empty_slots;
        CREATE TEMPORARY TABLE tmp_empty_slots(pos TINYINT PRIMARY KEY) ENGINE=Memory;
        INSERT INTO tmp_empty_slots(pos)
        SELECT p FROM (
          SELECT 1 AS p, (SELECT spellid_1 FROM lplusworld.item_template WHERE entry=p_entry) AS sid UNION ALL
          SELECT 2, (SELECT spellid_2 FROM lplusworld.item_template WHERE entry=p_entry) UNION ALL
          SELECT 3, (SELECT spellid_3 FROM lplusworld.item_template WHERE entry=p_entry) UNION ALL
          SELECT 4, (SELECT spellid_4 FROM lplusworld.item_template WHERE entry=p_entry) UNION ALL
          SELECT 5, (SELECT spellid_5 FROM lplusworld.item_template WHERE entry=p_entry)
        ) z WHERE z.sid IS NULL OR z.sid=0;

        DROP TEMPORARY TABLE IF EXISTS tmp_spell_assign;
        CREATE TEMPORARY TABLE tmp_spell_assign(pos TINYINT PRIMARY KEY, spellid INT UNSIGNED) ENGINE=Memory;

        INSERT INTO tmp_spell_assign(pos,spellid)
        SELECT e.pos, c.spellid
        FROM tmp_empty_slots e
        JOIN (
          SELECT f.aura, f.mag, c.spellid
          FROM tmp_add_final f
          JOIN helper.aura_spell_catalog c
            ON c.aura_code=f.aura AND c.magnitude=f.mag
          ORDER BY f.aura, f.mag
          LIMIT 5
        ) c ON 1=1
        LIMIT 5;

        UPDATE lplusworld.item_template t
        JOIN (
          SELECT
            MAX(CASE WHEN pos=1 THEN spellid END) AS s1,
            MAX(CASE WHEN pos=2 THEN spellid END) AS s2,
            MAX(CASE WHEN pos=3 THEN spellid END) AS s3,
            MAX(CASE WHEN pos=4 THEN spellid END) AS s4,
            MAX(CASE WHEN pos=5 THEN spellid END) AS s5
          FROM tmp_spell_assign
        ) x
        SET t.spellid_1=IFNULL(NULLIF(x.s1,0),t.spellid_1), t.spelltrigger_1=IFNULL(IF(x.s1 IS NULL, NULL, 1), t.spelltrigger_1),
            t.spellid_2=IFNULL(NULLIF(x.s2,0),t.spellid_2), t.spelltrigger_2=IFNULL(IF(x.s2 IS NULL, NULL, 1), t.spelltrigger_2),
            t.spellid_3=IFNULL(NULLIF(x.s3,0),t.spellid_3), t.spelltrigger_3=IFNULL(IF(x.s3 IS NULL, NULL, 1), t.spelltrigger_3),
            t.spellid_4=IFNULL(NULLIF(x.s4,0),t.spellid_4), t.spelltrigger_4=IFNULL(IF(x.s4 IS NULL, NULL, 1), t.spelltrigger_4),
            t.spellid_5=IFNULL(NULLIF(x.s5,0),t.spellid_5), t.spelltrigger_5=IFNULL(IF(x.s5 IS NULL, NULL, 1), t.spelltrigger_5)
        WHERE t.entry=p_entry;
      END IF;
    END IF;
  END IF;

  /* ---- report ---- */
  SELECT 'removed_budget' AS what, @B_remove AS value;
  SELECT 'targets' AS what, tt.* FROM tmp_targets tt;
  SELECT 'staged_new_auras' AS what, taa.* FROM tmp_add_auras taa;
  SELECT 'slots_after' AS what, ts.* FROM tmp_slots ts ORDER BY slot_no;

END main