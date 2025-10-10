CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_TuneTrueItemLevel_ConsumeQueue`(
  IN p_limit INT UNSIGNED   -- 0/NULL = all queued rows
)
BEGIN
  /* ===== DECLARES (must be first) ===== */
  DECLARE v_entry   INT UNSIGNED;
  DECLARE v_target  INT UNSIGNED;
  DECLARE v_apply   TINYINT(1);
  DECLARE done      INT DEFAULT 0;

  /* cursor over a temp table we'll create before OPEN */
  DECLARE cur CURSOR FOR
    SELECT entry, target_ilvl, apply_change
    FROM tmp_work
    ORDER BY entry;

  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  /* ===== minimal log table (ok after DECLAREs) ===== */
  CREATE TABLE IF NOT EXISTS helper.tune_ilvl_log (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    entry INT UNSIGNED NOT NULL,
    action ENUM('RUN','ERROR') NOT NULL,
    ilvl_before INT NULL,
    ilvl_after  INT NULL,
    target_ilvl INT NULL,
    note VARCHAR(255) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
  ) ENGINE=InnoDB;

  /* snapshot worklist to avoid racing live queue */
  DROP TEMPORARY TABLE IF EXISTS tmp_work;
  CREATE TEMPORARY TABLE tmp_work(
    entry INT UNSIGNED PRIMARY KEY,
    target_ilvl INT UNSIGNED NOT NULL,
    apply_change TINYINT(1) NOT NULL
  ) ENGINE=Memory;

  IF p_limit IS NULL OR p_limit = 0 THEN
    INSERT INTO tmp_work(entry,target_ilvl,apply_change)
    SELECT entry, target_ilvl, apply_change
    FROM helper.tune_queue
    WHERE status='queued';
  ELSE
    INSERT INTO tmp_work(entry,target_ilvl,apply_change)
    SELECT entry, target_ilvl, apply_change
    FROM helper.tune_queue
    WHERE status='queued'
    ORDER BY entry
    LIMIT p_limit;
  END IF;

  /* ===== iterate ===== */
  OPEN cur;
  readloop: LOOP
    FETCH cur INTO v_entry, v_target, v_apply;
    IF done = 1 THEN LEAVE readloop; END IF;

    /* mark processing */
    UPDATE helper.tune_queue
      SET status='processing', note=NULL
    WHERE entry=v_entry AND status='queued';

    /* snapshot before */
    SELECT CAST(trueItemLevel AS SIGNED)
      INTO @before
    FROM lplusworld.item_template
    WHERE entry=v_entry;

    /* scale via the simple greedy scaler (applies if v_apply=1) */
    CALL helper.sp_ScaleItemToIlvl_SimpleGreedy(v_entry, v_target, v_apply);

    /* estimator already called inside scaler when apply=1, but safe to ensure */
    IF v_apply = 1 THEN CALL helper.sp_EstimateItemLevels(); END IF;

    /* snapshot after */
    SELECT CAST(trueItemLevel AS SIGNED)
      INTO @after
    FROM lplusworld.item_template
    WHERE entry=v_entry;

    /* finish */
    UPDATE helper.tune_queue
      SET status='done', note=NULL
    WHERE entry=v_entry;

    INSERT INTO helper.tune_ilvl_log(entry,action,ilvl_before,ilvl_after,target_ilvl,note)
    VALUES (v_entry,'RUN',@before,@after,v_target,CONCAT('apply=',v_apply));
  END LOOP;
  CLOSE cur;

  /* summary */
  SELECT status, COUNT(*) AS cnt
  FROM helper.tune_queue
  WHERE status IN ('queued','processing','done','error')
  GROUP BY status;
END