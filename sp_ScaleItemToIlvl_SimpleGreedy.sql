CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `sp_ScaleItemToIlvl_SimpleGreedy`(
  IN p_entry INT UNSIGNED,
  IN p_target_ilvl INT UNSIGNED,
  IN p_apply TINYINT(1)        -- 0=dry run, 1=apply changes
)
proc: BEGIN
  /* slotmods / curves */
  DROP TEMPORARY TABLE IF EXISTS tmp_slotmods_g;
  CREATE TEMPORARY TABLE tmp_slotmods_g(inv TINYINT PRIMARY KEY, slotmod DOUBLE) ENGINE=Memory;
  INSERT INTO tmp_slotmods_g VALUES
    (1,1.00),(5,1.00),(20,1.00),(7,1.00),
    (3,1.35),(10,1.35),(6,1.35),(8,1.35),
    (12,1.47),
    (9,1.85),(2,1.85),(16,1.85),(11,1.85),
    (17,1.00),
    (13,2.44),(21,2.44),
    (14,1.92),(22,1.92),(23,1.92),
    (15,3.33),(26,3.33),(25,3.33);

  DROP TEMPORARY TABLE IF EXISTS tmp_qcurve_g;
  CREATE TEMPORARY TABLE tmp_qcurve_g(quality TINYINT PRIMARY KEY, a DOUBLE, b DOUBLE) ENGINE=Memory;
  INSERT INTO tmp_qcurve_g VALUES (2,1.21,-9.8),(3,1.42,-4.2),(4,1.64,11.2);

  SET @W_PRIMARY := 230.0;

  /* basics */
  SELECT Quality, InventoryType, CAST(IFNULL(trueItemLevel,0) AS SIGNED)
    INTO @q, @inv, @ilvl_cur
  FROM lplusworld.item_template
  WHERE entry = p_entry;

  IF @q NOT IN (2,3,4) THEN LEAVE proc; END IF;

  SELECT a,b INTO @a,@b FROM tmp_qcurve_g WHERE quality=@q;
  SET @slotmod := IFNULL((SELECT slotmod FROM tmp_slotmods_g WHERE inv=@inv),1.00);

  /* ---- SAFE helpers (clamped) ---- */
  SET @ISV_cur  := GREATEST(0.0, @a * @ilvl_cur      + @b);
  SET @ISV_tgt  := GREATEST(0.0, @a * p_target_ilvl  + @b);

  SET @itemvalue_cur := GREATEST(0.0, @ISV_cur / NULLIF(@slotmod,0));
  SET @itemvalue_tgt := GREATEST(0.0, @ISV_tgt / NULLIF(@slotmod,0));

  /* clamp base to avoid overflow, then POW */
  SET @base_cur := GREATEST(0.0, @itemvalue_cur * 100.0);
  SET @base_tgt := GREATEST(0.0, @itemvalue_tgt * 100.0);

  SET @S_cur := POW(@base_cur, 1.5);
  SET @S_tgt := POW(@base_tgt, 1.5);

  /* snapshot 10 slots */
  SELECT stat_type1,stat_value1, stat_type2,stat_value2, stat_type3,stat_value3,
         stat_type4,stat_value4, stat_type5,stat_value5, stat_type6,stat_value6,
         stat_type7,stat_value7, stat_type8,stat_value8, stat_type9,stat_value9,
         stat_type10,stat_value10
  INTO  @st1,@sv1, @st2,@sv2, @st3,@sv3,
        @st4,@sv4, @st5,@sv5, @st6,@sv6,
        @st7,@sv7, @st8,@sv8, @st9,@sv9,
        @st10,@sv10
  FROM lplusworld.item_template
  WHERE entry = p_entry;

  /* current primaries grouped */
  DROP TEMPORARY TABLE IF EXISTS tmp_pcur;
  CREATE TEMPORARY TABLE tmp_pcur(stat TINYINT PRIMARY KEY, v DOUBLE) ENGINE=Memory;

  INSERT INTO tmp_pcur(stat,v)
  SELECT s, SUM(vv) FROM (
    SELECT @st1 s, @sv1 vv UNION ALL
    SELECT @st2, @sv2 UNION ALL
    SELECT @st3, @sv3 UNION ALL
    SELECT @st4, @sv4 UNION ALL
    SELECT @st5, @sv5 UNION ALL
    SELECT @st6, @sv6 UNION ALL
    SELECT @st7, @sv7 UNION ALL
    SELECT @st8, @sv8 UNION ALL
    SELECT @st9, @sv9 UNION ALL
    SELECT @st10,@sv10
  ) z
  WHERE s IN (3,4,5,6,7) AND vv IS NOT NULL AND vv > 0
  GROUP BY s;

  SET @k := (SELECT COUNT(*) FROM tmp_pcur);
  IF @k = 0 THEN
    INSERT INTO tmp_pcur VALUES (7, 0); -- seed STA
    SET @k := 1;
  END IF;

  /* S_cur_p for primaries only */
  SELECT IFNULL(SUM(POW(GREATEST(0, v * @W_PRIMARY), 1.5)), 0.0)
    INTO @S_cur_p
  FROM tmp_pcur;

  /* delta for primaries */
  SET @S_fixed := @S_cur - @S_cur_p;
  SET @delta_p := @S_tgt - (@S_fixed + @S_cur_p);
  SET @each_p  := @delta_p / @k;

  /* new primary values */
  DROP TEMPORARY TABLE IF EXISTS tmp_pnew;
  CREATE TEMPORARY TABLE tmp_pnew(stat TINYINT PRIMARY KEY, newv INT) ENGINE=Memory;
  INSERT INTO tmp_pnew(stat,newv)
  SELECT stat,
         ROUND( POW( GREATEST(0.0, POW(v * @W_PRIMARY, 1.5) + @each_p), 2.0/3.0 ) / @W_PRIMARY )
  FROM tmp_pcur;

  /* stage slots, single JOIN (avoids “reopen table” issues) */
  DROP TEMPORARY TABLE IF EXISTS tmp_slots_cur;
  CREATE TEMPORARY TABLE tmp_slots_cur(slot_no TINYINT PRIMARY KEY, stat_type TINYINT, stat_value INT) ENGINE=Memory;
  INSERT INTO tmp_slots_cur VALUES
    (1,@st1,@sv1),(2,@st2,@sv2),(3,@st3,@sv3),(4,@st4,@sv4),(5,@st5,@sv5),
    (6,@st6,@sv6),(7,@st7,@sv7),(8,@st8,@sv8),(9,@st9,@sv9),(10,@st10,@sv10);

  UPDATE tmp_slots_cur s
  LEFT JOIN tmp_pnew n ON n.stat = s.stat_type
  SET s.stat_value = IFNULL(n.newv, s.stat_value);

  DROP TEMPORARY TABLE IF EXISTS tmp_pivot_vals;
  CREATE TEMPORARY TABLE tmp_pivot_vals
  SELECT
    MAX(CASE WHEN slot_no=1 THEN stat_type END) AS st1,
    MAX(CASE WHEN slot_no=1 THEN stat_value END) AS sv1,
    MAX(CASE WHEN slot_no=2 THEN stat_type END) AS st2,
    MAX(CASE WHEN slot_no=2 THEN stat_value END) AS sv2,
    MAX(CASE WHEN slot_no=3 THEN stat_type END) AS st3,
    MAX(CASE WHEN slot_no=3 THEN stat_value END) AS sv3,
    MAX(CASE WHEN slot_no=4 THEN stat_type END) AS st4,
    MAX(CASE WHEN slot_no=4 THEN stat_value END) AS sv4,
    MAX(CASE WHEN slot_no=5 THEN stat_type END) AS st5,
    MAX(CASE WHEN slot_no=5 THEN stat_value END) AS sv5,
    MAX(CASE WHEN slot_no=6 THEN stat_type END) AS st6,
    MAX(CASE WHEN slot_no=6 THEN stat_value END) AS sv6,
    MAX(CASE WHEN slot_no=7 THEN stat_type END) AS st7,
    MAX(CASE WHEN slot_no=7 THEN stat_value END) AS sv7,
    MAX(CASE WHEN slot_no=8 THEN stat_type END) AS st8,
    MAX(CASE WHEN slot_no=8 THEN stat_value END) AS sv8,
    MAX(CASE WHEN slot_no=9 THEN stat_type END) AS st9,
    MAX(CASE WHEN slot_no=9 THEN stat_value END) AS sv9,
    MAX(CASE WHEN slot_no=10 THEN stat_type END) AS st10,
    MAX(CASE WHEN slot_no=10 THEN stat_value END) AS sv10
  FROM tmp_slots_cur;

  IF p_apply = 1 THEN
    UPDATE lplusworld.item_template t
    JOIN tmp_pivot_vals p ON 1=1
    SET t.stat_value1  = p.sv1,
        t.stat_value2  = p.sv2,
        t.stat_value3  = p.sv3,
        t.stat_value4  = p.sv4,
        t.stat_value5  = p.sv5,
        t.stat_value6  = p.sv6,
        t.stat_value7  = p.sv7,
        t.stat_value8  = p.sv8,
        t.stat_value9  = p.sv9,
        t.stat_value10 = p.sv10
    WHERE t.entry = p_entry;

    CALL helper.sp_EstimateItemLevels();
  END IF;

  SELECT p_entry AS entry,
         @ilvl_cur AS ilvl_before,
         p_target_ilvl AS target_ilvl,
         (SELECT CAST(trueItemLevel AS SIGNED) FROM lplusworld.item_template WHERE entry=p_entry) AS ilvl_after;
END proc