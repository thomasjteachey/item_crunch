-- Emit INSERT statements for every staged davidstats item without using external scripts
DELIMITER $$

CREATE TABLE IF NOT EXISTS helper.davidstats_item_inserts (
  entry INT UNSIGNED NOT NULL PRIMARY KEY,
  insert_stmt TEXT NOT NULL
)$$

DROP PROCEDURE IF EXISTS helper.sp_dump_davidstats_item_inserts$$
CREATE PROCEDURE helper.sp_dump_davidstats_item_inserts()
BEGIN
  DECLARE v_col_list TEXT;
  DECLARE v_value_expr TEXT;
  DECLARE v_sql LONGTEXT;

  /* Build the column list from the helper table so new staging columns are included automatically. */
  SELECT GROUP_CONCAT(CONCAT('`', COLUMN_NAME, '`') ORDER BY ORDINAL_POSITION SEPARATOR ', ')
    INTO v_col_list
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = 'helper'
    AND TABLE_NAME = 'davidstats_items';

  /* Build an expression that will CONCAT each value with safe quoting. */
  SELECT GROUP_CONCAT(
           CONCAT('COALESCE(QUOTE(`', COLUMN_NAME, '`),''NULL'')')
           ORDER BY ORDINAL_POSITION SEPARATOR ", ' , ', "
         )
    INTO v_value_expr
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = 'helper'
    AND TABLE_NAME = 'davidstats_items';

  IF v_col_list IS NULL OR v_value_expr IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'helper.davidstats_items must exist before dumping inserts';
  END IF;

  DELETE FROM helper.davidstats_item_inserts;

  SET v_sql = CONCAT(
    'INSERT INTO helper.davidstats_item_inserts(entry, insert_stmt) ',
    'SELECT entry, CONCAT(''INSERT INTO helper.davidstats_items (', v_col_list, ') VALUES ('', ',
           v_value_expr, ', '' );'') ',
    'FROM helper.davidstats_items'
  );

  PREPARE stmt FROM v_sql;
  EXECUTE stmt;
  DEALLOCATE PREPARE stmt;
END$$

DELIMITER ;
