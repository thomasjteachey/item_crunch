-- Emit INSERT statements for every staged davidstats item without using external scripts
DELIMITER $$

CREATE TABLE IF NOT EXISTS helper.davidstats_item_inserts (
  entry INT UNSIGNED NOT NULL PRIMARY KEY,
  insert_stmt TEXT NOT NULL
)$$

DROP PROCEDURE IF EXISTS helper.sp_dump_davidstats_item_inserts$$
CREATE PROCEDURE helper.sp_dump_davidstats_item_inserts()
BEGIN
  -- All DECLAREs at top (MySQL quirk)
  DECLARE v_col_list   LONGTEXT;
  DECLARE v_value_expr LONGTEXT;
  DECLARE v_sql        LONGTEXT;
  DECLARE v_old_group_concat_max_len BIGINT UNSIGNED;

  -- Bump GROUP_CONCAT limit so our column/value expressions don't get cut
  SELECT @@group_concat_max_len INTO v_old_group_concat_max_len;
  SET SESSION group_concat_max_len = 65535;  -- raise as needed (can go much higher)

  /* Build the column list from the helper table so new staging columns are included automatically. */
  SELECT GROUP_CONCAT(CONCAT('`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', ')
    INTO v_col_list
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = 'helper'
    AND TABLE_NAME   = 'davidstats_items';

  /* Build an expression that will CONCAT each value with safe quoting. */
  SELECT GROUP_CONCAT(
           CONCAT('COALESCE(QUOTE(`', COLUMN_NAME, '`),''NULL'')')
           ORDER BY ORDINAL_POSITION SEPARATOR ", ', ', "
         )
    INTO v_value_expr
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = 'helper'
    AND TABLE_NAME   = 'davidstats_items';

  IF v_col_list IS NULL OR v_value_expr IS NULL THEN
    -- Restore setting before bailing
    SET SESSION group_concat_max_len = v_old_group_concat_max_len;

    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'helper.davidstats_items must exist before dumping inserts';
  END IF;

  DELETE FROM helper.davidstats_item_inserts;

  /* Build dynamic SQL that emits one INSERT ... VALUES(...) string per davidstats_items row. */
  SET v_sql = CONCAT(
    'INSERT INTO helper.davidstats_item_inserts(entry, insert_stmt) ',
    'SELECT entry, CONCAT(''INSERT INTO helper.davidstats_items (',
      v_col_list,
    ') VALUES ('', ',
      v_value_expr,
    ', '');'') ',
    'FROM helper.davidstats_items'
  );

  -- PREPARE must use a user variable, not a local variable.
  SET @v_sql = v_sql;
  PREPARE stmt FROM @v_sql;
  EXECUTE stmt;
  DEALLOCATE PREPARE stmt;

  -- Restore previous GROUP_CONCAT limit
  SET SESSION group_concat_max_len = v_old_group_concat_max_len;
END$$

DELIMITER ;
