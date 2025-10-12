CREATE TABLE `ilvl_debug_log` (
  `id` bigint unsigned NOT NULL AUTO_INCREMENT,
  `entry` int unsigned NOT NULL,
  `step` varchar(64) NOT NULL,
  `k` varchar(64) DEFAULT NULL,
  `v_double` double DEFAULT NULL,
  `v_text` text,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `entry` (`entry`),
  KEY `step` (`step`)
) ENGINE=InnoDB AUTO_INCREMENT=80 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
