CREATE DEFINER=`brokilodeluxe`@`%` PROCEDURE `spLPlusCrunchWeapons`()
BEGIN
delete from lplusworld.item_template where entry in
(
select item from lplusworld.npc_vendor where entry in (110220, 110221)
);

insert into lplusworld.item_template
select * from legionnaireworld.item_template
where entry in
(
select item from lplusworld.npc_vendor where entry in (110220, 110221)
);

delete from helper.tune_queue;

INSERT IGNORE INTO helper.tune_queue (entry, target_ilvl, mode, apply_change)
SELECT DISTINCT it.entry,
       CASE
         WHEN REPLACE(it.name,'’','''') LIKE 'High Warlord''s%'
           OR REPLACE(it.name,'’','''') LIKE 'Grand Marshal''s%' THEN 73
         ELSE 72
       END AS target_ilvl,
       'crunch',
       1
FROM lplusworld.npc_vendor v
JOIN lplusworld.item_template it ON it.entry = v.item
JOIN legionnaireworld.item_template lit ON lit.entry = it.entry
WHERE v.entry in (110220, 110221)
  AND IFNULL(lit.ItemLevel,0) > 71;


call helper.sp_TuneTrueItemLevel_ConsumeQueue(0);
call helper.sp_DedupeSpellsAboveEntry(82424, 1, '');
UPDATE lplusworld.item_template it
JOIN helper.tune_queue q ON q.entry = it.entry AND q.status='done'
SET it.itemLevel = q.target_ilvl
WHERE it.entry IN (SELECT item FROM lplusworld.npc_vendor WHERE entry IN (110220,110221));

END