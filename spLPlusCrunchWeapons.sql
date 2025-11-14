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

INSERT IGNORE INTO helper.tune_queue (entry, target_ilvl, mode)
SELECT DISTINCT it.entry,
       CASE
         WHEN REPLACE(it.name,'’','''') LIKE 'High Warlord''s%'
           OR REPLACE(it.name,'’','''') LIKE 'Grand Marshal''s%' THEN 75
         ELSE 73
       END AS target_ilvl,
       'crunch'
FROM lplusworld.npc_vendor v
JOIN lplusworld.item_template it ON it.entry = v.item
WHERE v.entry in (110220, 110221);


call sp_TuneTrueItemLevel_ConsumeQueue(0);
call sp_DedupeSpellsAboveEntry(82424, 1, '');
update lplusworld.item_template set itemLevel = trueItemLevel where entry in
(
select item from lplusworld.npc_vendor where entry in (110220, 110221)
)
and trueItemLevel > 0
;
END