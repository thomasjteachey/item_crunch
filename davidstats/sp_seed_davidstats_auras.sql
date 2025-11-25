DELIMITER //
drop procedure if exists sp_seed_davidstats_auras;//
CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_seed_davidstats_auras`()
begin
  DECLARE v_stat VARCHAR(64);
  DECLARE v_magnitude INT;
  DECLARE v_aura_id INT;
  DECLARE v_effect_index TINYINT;
  DECLARE v_desc VARCHAR(255);
  DECLARE v_existing_id INT;
  DECLARE v_template_id INT;
  DECLARE v_template_effect_index TINYINT;
  DECLARE v_next_spell_id INT;
  DECLARE v_done INT DEFAULT 0;

  /* Aura constants aligned with the scaler */
  SET @AURA_SPELL_POWER := 13;
  SET @AURA_HEALING := 76;
  SET @AURA_BLOCK_VALUE := 158;
  SET @AURA_HIT := 54;   SET @AURA_SPHIT := 55;
  SET @AURA_SPCRIT1 := 57; SET @AURA_SPCRIT2 := 71;
  SET @AURA_CRIT_GENERIC := 52;
  SET @AURA_CRIT_MELEE := 308; SET @AURA_CRIT_RANGED := 290;
  SET @AURA_BLOCK := 51; SET @AURA_DODGE := 49;
  SET @AURA_DEFENSE := 30;

  SET @DESC_SPELL_POWER := 'Increases damage and healing done by magical spells and effects by up to $s1.';
  SET @DESC_HEALING := 'Increases healing done by up to $s1.';
  SET @DESC_HIT := 'Improves your chance to hit by $s1%.';
  SET @DESC_SPHIT := 'Improves your chance to hit with spells by $s1%.';
  SET @DESC_CRIT := 'Improves your chance to get a critical strike by $s1%.';
  SET @DESC_SPCRIT := 'Improves your chance to get a critical strike with spells by $s1%.';
  SET @DESC_BLOCK_VALUE := 'Increases the block value of your shield by $s1.';
  SET @DESC_DEFENSE := 'Increases defense by $s1.';

  /* staging */
  DROP TEMPORARY TABLE IF EXISTS tmp_davidstats_required;
  CREATE TEMPORARY TABLE tmp_davidstats_required(
    stat VARCHAR(64) NOT NULL,
    magnitude INT NOT NULL,
    aura_id INT NOT NULL,
    effect_index TINYINT NOT NULL,
    aura_desc VARCHAR(255) DEFAULT NULL,
    PRIMARY KEY(stat, magnitude)
  ) ENGINE=Memory;

  INSERT INTO tmp_davidstats_required(stat, magnitude, aura_id, effect_index, aura_desc)
  SELECT DISTINCT r.stat,
                  r.magnitude_percent AS magnitude,
                  CASE
                    WHEN r.stat = 'spell_power' THEN @AURA_SPELL_POWER
                    WHEN r.stat = 'healing' THEN @AURA_HEALING
                    WHEN r.stat = 'hit_pct' THEN @AURA_HIT
                    WHEN r.stat = 'spell_hit_pct' THEN @AURA_SPHIT
                    WHEN r.stat = 'crit_pct' THEN @AURA_CRIT_GENERIC
                    WHEN r.stat = 'spell_crit_pct' THEN @AURA_SPCRIT1
                    WHEN r.stat = 'dodge_pct' THEN @AURA_DODGE
                    WHEN r.stat = 'block_chance_pct' THEN @AURA_BLOCK
                    WHEN r.stat = 'block_value' THEN @AURA_BLOCK_VALUE
                    WHEN r.stat = 'defense' THEN @AURA_DEFENSE
                    ELSE NULL
                  END AS aura_id,
                  1 AS effect_index,
                  CASE
                    WHEN r.stat = 'spell_power' THEN @DESC_SPELL_POWER
                    WHEN r.stat = 'healing' THEN @DESC_HEALING
                    WHEN r.stat = 'hit_pct' THEN @DESC_HIT
                    WHEN r.stat = 'spell_hit_pct' THEN @DESC_SPHIT
                    WHEN r.stat = 'crit_pct' THEN @DESC_CRIT
                    WHEN r.stat = 'spell_crit_pct' THEN @DESC_SPCRIT
                    WHEN r.stat = 'block_value' THEN @DESC_BLOCK_VALUE
                    WHEN r.stat = 'defense' THEN @DESC_DEFENSE
                    ELSE NULL
                  END AS aura_desc
  FROM helper.davidstats_required_auras r
  WHERE r.stat IN ('spell_power','healing','hit_pct','spell_hit_pct','crit_pct','spell_crit_pct','dodge_pct','block_chance_pct','block_value','defense');

  /* log table for visibility */
  CREATE TABLE IF NOT EXISTS helper.davidstats_seeded_auras(
    stat VARCHAR(64) NOT NULL,
    magnitude INT NOT NULL,
    aura_id INT NOT NULL,
    effect_index TINYINT NOT NULL,
    spell_id INT NOT NULL,
    status ENUM('existing','cloned') NOT NULL,
    note VARCHAR(255) DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(stat, magnitude)
  );

  /* reset log for this run */
  DELETE FROM helper.davidstats_seeded_auras;

  /* cursor over needed rows */
  BEGIN
    DECLARE cur_needed CURSOR FOR
      SELECT stat, magnitude, aura_id, effect_index, aura_desc FROM tmp_davidstats_required;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done := 1;

    SET v_next_spell_id := (SELECT IFNULL(MAX(ID), 0) FROM dbc.spell_lplus);

    OPEN cur_needed;
    read_loop: LOOP
      FETCH cur_needed INTO v_stat, v_magnitude, v_aura_id, v_effect_index, v_desc;
      IF v_done = 1 THEN
        LEAVE read_loop;
      END IF;

      /* prefer an exact existing match */
      SET v_existing_id := (
        SELECT s.ID
        FROM (
          SELECT ID,
                 CASE WHEN EffectAura_1 = v_aura_id THEN 1
                      WHEN EffectAura_2 = v_aura_id THEN 2
                      WHEN EffectAura_3 = v_aura_id THEN 3
                      ELSE NULL END AS eff_idx,
                 CASE WHEN EffectAura_1 = v_aura_id THEN EffectBasePoints_1
                      WHEN EffectAura_2 = v_aura_id THEN EffectBasePoints_2
                      ELSE EffectBasePoints_3 END AS base_points,
                 Description_Lang_enUS AS desc_en,
                 CASE WHEN EffectAura_1 = v_aura_id THEN EffectAura_1
                      WHEN EffectAura_2 = v_aura_id THEN EffectAura_2
                      ELSE EffectAura_3 END AS matched_aura
          FROM dbc.spell_lplus
        ) s
        WHERE s.matched_aura = v_aura_id
          AND (s.base_points + 1) = v_magnitude
        ORDER BY CASE WHEN v_desc IS NOT NULL AND s.desc_en = v_desc THEN 0 ELSE 1 END,
                 s.ID
        LIMIT 1
      );

      IF v_existing_id IS NOT NULL THEN
        INSERT INTO helper.davidstats_seeded_auras(stat, magnitude, aura_id, effect_index, spell_id, status, note)
        VALUES(v_stat, v_magnitude, v_aura_id, v_effect_index, v_existing_id, 'existing', NULL);
        ITERATE read_loop;
      END IF;

      /* find the closest template */
      SELECT candidate_id, candidate_eff_idx
        INTO v_template_id, v_template_effect_index
      FROM (
        SELECT s.ID AS candidate_id,
               s.eff_idx AS candidate_eff_idx,
               ABS((s.base_points + 1) - v_magnitude) AS delta,
               CASE WHEN v_desc IS NOT NULL AND s.desc_en = v_desc THEN 0 ELSE 1 END AS desc_penalty
        FROM (
          SELECT ID,
                 CASE WHEN EffectAura_1 = v_aura_id THEN 1
                      WHEN EffectAura_2 = v_aura_id THEN 2
                      WHEN EffectAura_3 = v_aura_id THEN 3
                      ELSE NULL END AS eff_idx,
                 CASE WHEN EffectAura_1 = v_aura_id THEN EffectBasePoints_1
                      WHEN EffectAura_2 = v_aura_id THEN EffectBasePoints_2
                      ELSE EffectBasePoints_3 END AS base_points,
                 Description_Lang_enUS AS desc_en,
                 CASE WHEN EffectAura_1 = v_aura_id THEN EffectAura_1
                      WHEN EffectAura_2 = v_aura_id THEN EffectAura_2
                      ELSE EffectAura_3 END AS matched_aura
          FROM dbc.spell_lplus
        ) s
        WHERE s.matched_aura = v_aura_id
        ORDER BY desc_penalty, delta, candidate_id
        LIMIT 1
      ) ranked;

      IF v_template_id IS NULL THEN
        INSERT INTO helper.davidstats_seeded_auras(stat, magnitude, aura_id, effect_index, spell_id, status, note)
        VALUES(v_stat, v_magnitude, v_aura_id, v_effect_index, 0, 'existing', 'no template found');
        ITERATE read_loop;
      END IF;

      SET v_next_spell_id := v_next_spell_id + 1;

      DROP TEMPORARY TABLE IF EXISTS tmp_spell_clone_rows;
      CREATE TEMPORARY TABLE tmp_spell_clone_rows LIKE dbc.spell_lplus;
      INSERT INTO tmp_spell_clone_rows SELECT * FROM dbc.spell_lplus WHERE ID = v_template_id;

      UPDATE tmp_spell_clone_rows
      SET ID = v_next_spell_id,
          Description_Lang_enUS = COALESCE(v_desc, Description_Lang_enUS),
          Description_Lang_enGB = COALESCE(v_desc, Description_Lang_enGB),
          EffectAura_1 = CASE WHEN v_template_effect_index = 1 THEN v_aura_id ELSE EffectAura_1 END,
          EffectAura_2 = CASE WHEN v_template_effect_index = 2 THEN v_aura_id ELSE EffectAura_2 END,
          EffectAura_3 = CASE WHEN v_template_effect_index = 3 THEN v_aura_id ELSE EffectAura_3 END,
          EffectBasePoints_1 = CASE WHEN v_template_effect_index = 1 THEN (v_magnitude - 1) ELSE EffectBasePoints_1 END,
          EffectBasePoints_2 = CASE WHEN v_template_effect_index = 2 THEN (v_magnitude - 1) ELSE EffectBasePoints_2 END,
          EffectBasePoints_3 = CASE WHEN v_template_effect_index = 3 THEN (v_magnitude - 1) ELSE EffectBasePoints_3 END;

      INSERT INTO dbc.spell_lplus SELECT * FROM tmp_spell_clone_rows;
      DROP TEMPORARY TABLE IF EXISTS tmp_spell_clone_rows;

      INSERT INTO helper.davidstats_seeded_auras(stat, magnitude, aura_id, effect_index, spell_id, status, note)
      VALUES(v_stat, v_magnitude, v_aura_id, v_effect_index, v_next_spell_id, 'cloned', CONCAT('from ', v_template_id));
    END LOOP;
    CLOSE cur_needed;
  END;
end;//
DELIMITER ;
