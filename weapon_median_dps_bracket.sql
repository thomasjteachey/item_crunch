CREATE TABLE `weapon_median_dps_bracket` (
  `bracket` enum('1H','2H','RANGED') NOT NULL,
  `quality` tinyint unsigned NOT NULL,
  `ilvl` smallint unsigned NOT NULL,
  `median_dps` double NOT NULL,
  `n` int unsigned NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`bracket`,`quality`,`ilvl`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
