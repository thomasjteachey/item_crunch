DELIMITER $$

DROP PROCEDURE IF EXISTS `helper`.`sp_CopyStarterCharacterBindings`$$

CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `helper`.`sp_CopyStarterCharacterBindings`(
  IN p_target_guid INT UNSIGNED,
  IN p_source_guid INT UNSIGNED
)
proc:BEGIN
  DECLARE v_source_guid INT UNSIGNED;

  IF p_target_guid IS NULL OR p_target_guid = 0 THEN
    LEAVE proc;
  END IF;

  SET v_source_guid := IFNULL(p_source_guid, 0);
  IF v_source_guid = 0 OR v_source_guid = p_target_guid THEN
    LEAVE proc;
  END IF;

  DELETE FROM `character_action`
  WHERE guid = p_target_guid;

  INSERT INTO `character_action` (guid, spec, button, action, type)
  SELECT p_target_guid, spec, button, action, type
  FROM `character_action`
  WHERE guid = v_source_guid;

  DELETE FROM `character_spell`
  WHERE guid = p_target_guid;

  INSERT INTO `character_spell` (guid, spell, active, disabled)
  SELECT p_target_guid, spell, active, disabled
  FROM `character_spell`
  WHERE guid = v_source_guid;

  DELETE FROM `character_spell_cooldown`
  WHERE guid = p_target_guid;

  INSERT INTO `character_spell_cooldown` (guid, spell, item, time, categoryId, categoryEnd)
  SELECT p_target_guid, spell, item, time, categoryId, categoryEnd
  FROM `character_spell_cooldown`
  WHERE guid = v_source_guid;

  DELETE FROM `character_glyphs`
  WHERE guid = p_target_guid;

  INSERT INTO `character_glyphs` (guid, talentGroup, glyph1, glyph2, glyph3, glyph4, glyph5, glyph6)
  SELECT p_target_guid, talentGroup, glyph1, glyph2, glyph3, glyph4, glyph5, glyph6
  FROM `character_glyphs`
  WHERE guid = v_source_guid;

  DELETE FROM `character_talent`
  WHERE guid = p_target_guid;

  INSERT INTO `character_talent` (guid, spell, talentGroup)
  SELECT p_target_guid, spell, talentGroup
  FROM `character_talent`
  WHERE guid = v_source_guid;
END$$

DELIMITER ;
