CREATE TABLE `aura_spell_catalog` (
  `aura_code` enum('AP','RAP','HIT','CRIT','BLOCK','PARRY','DODGE','SPHIT','SPCRIT','SDALL','SDONE','SDONE_HOL','SDONE_FIR','SDONE_NAT','SDONE_FRO','SDONE_SHA','SDONE_ARC','HEAL','MP5','HP5') NOT NULL,
  `magnitude` int NOT NULL,
  `spellid` int unsigned NOT NULL,
  PRIMARY KEY (`aura_code`,`magnitude`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
