#!/usr/bin/env python3
"""
Normalize the free-form "wow ideas.csv" notes into structured rows and
surface any aura magnitudes we need to seed in dbc.spell_lplus.

Outputs two files in the davidstats folder:
- custom_set_targets.csv: structured per-slot stat targets
- required_auras.csv: unique aura magnitudes (hit/crit/etc) and who needs them
"""
from __future__ import annotations

import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

# Patterns to extract numeric stats from the free-form notes
STAT_PATTERNS = {
    "stamina": re.compile(r"(\d+)\s*stm", re.IGNORECASE),
    "agility": re.compile(r"(\d+)\s*agi", re.IGNORECASE),
    "strength": re.compile(r"(\d+)\s*str", re.IGNORECASE),
    "intellect": re.compile(r"(\d+)\s*int", re.IGNORECASE),
    "spirit": re.compile(r"(\d+)\s*spr", re.IGNORECASE),
    "bonus_armor": re.compile(r"(\d+)\s*bonus\s*armor", re.IGNORECASE),
    "attack_power": re.compile(r"(\d+)\s*(?:atk pwr|attack power)", re.IGNORECASE),
    "ranged_attack_power": re.compile(r"(\d+)\s*(?:rng atk pwr|ranged attack power)", re.IGNORECASE),
    "spell_power": re.compile(r"(\d+)\s*(?:spl dmg|spell dmg|spell damage)", re.IGNORECASE),
    "healing": re.compile(r"(\d+)\s*healin[g]?", re.IGNORECASE),
    "mp5": re.compile(r"(\d+)\s*mp5", re.IGNORECASE),
    "defense": re.compile(r"(\d+)\s*dfns", re.IGNORECASE),
    "block_value": re.compile(r"(\d+)\s*block(?!\s*chance)", re.IGNORECASE),
    "block_chance_pct": re.compile(r"(\d+)%\s*block\s*chance", re.IGNORECASE),
    "block_pct": re.compile(r"(\d+)%\s*block(?!\s*chance)", re.IGNORECASE),
    "hit_pct": re.compile(r"(\d+)%\s*hit", re.IGNORECASE),
    "spell_hit_pct": re.compile(r"(\d+)%\s*spl\s*hit", re.IGNORECASE),
    "crit_pct": re.compile(r"(\d+)%\s*crit", re.IGNORECASE),
    "spell_crit_pct": re.compile(r"(\d+)%\s*spl\s*crit", re.IGNORECASE),
    "dodge_pct": re.compile(r"(\d+)%\s*dodge", re.IGNORECASE),
    "spell_penetration": re.compile(r"(\d+)\s*(?:spl\s*piercing|spell\s*pen)", re.IGNORECASE),
}

AURA_FIELDS = {
    "hit_pct",
    "spell_hit_pct",
    "crit_pct",
    "spell_crit_pct",
    "dodge_pct",
    "block_chance_pct",
    "block_pct",
}

OUTPUT_COLUMNS = [
    "class",
    "archetype",
    "slot",
    "stamina",
    "agility",
    "strength",
    "intellect",
    "spirit",
    "bonus_armor",
    "attack_power",
    "ranged_attack_power",
    "spell_power",
    "healing",
    "mp5",
    "defense",
    "block_value",
    "block_pct",
    "block_chance_pct",
    "hit_pct",
    "spell_hit_pct",
    "crit_pct",
    "spell_crit_pct",
    "dodge_pct",
    "spell_penetration",
]


def parse_stats(stat_blob: str) -> Dict[str, int]:
    stats: Dict[str, int] = {}
    for key, pattern in STAT_PATTERNS.items():
        matches = pattern.findall(stat_blob)
        if not matches:
            continue
        # If multiple values appear (e.g., two different block chunks) keep the sum
        stats[key] = sum(int(m) for m in matches)
    return stats


def iter_slot_rows(rows: Iterable[List[str]]) -> Iterable[Tuple[str, str, str, Dict[str, int]]]:
    current_class = ""
    current_archetype = ""
    slot_re = re.compile(r"^(?P<slot>[^:]+):\s*(?P<stats>.+)$")
    for row in rows:
        if row and row[0].strip():
            current_class = row[0].strip()
        if len(row) > 2 and row[2].strip():
            current_archetype = row[2].strip()
        for cell in row:
            cell = cell.strip()
            if ":" not in cell:
                continue
            match = slot_re.match(cell)
            if not match:
                continue
            slot = match.group("slot").strip()
            stats = parse_stats(match.group("stats"))
            yield current_class, current_archetype, slot, stats


def write_targets(rows: Iterable[Tuple[str, str, str, Dict[str, int]]], out_path: Path) -> List[Dict[str, str]]:
    records: List[Dict[str, str]] = []
    for cls, arch, slot, stats in rows:
        record = {col: "" for col in OUTPUT_COLUMNS}
        record.update({"class": cls, "archetype": arch, "slot": slot})
        for key, value in stats.items():
            record[key] = str(value)
        records.append(record)

    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        writer.writerows(records)
    return records


def collect_auras(records: List[Dict[str, str]]) -> List[Dict[str, str]]:
    needed: Dict[Tuple[str, int], List[str]] = defaultdict(list)
    for record in records:
        label = " ".join(part for part in (record["class"], record["archetype"], record["slot"]) if part)
        for field in AURA_FIELDS:
            if not record.get(field):
                continue
            needed[(field, int(record[field]))].append(label)

    aura_rows: List[Dict[str, str]] = []
    for (stat, magnitude), consumers in sorted(needed.items(), key=lambda x: (x[0][0], x[0][1])):
        aura_rows.append(
            {
                "stat": stat,
                "magnitude_percent": str(magnitude),
                "needed_by": "; ".join(consumers),
            }
        )
    return aura_rows


def write_auras(aura_rows: List[Dict[str, str]], out_path: Path) -> None:
    if not aura_rows:
        out_path.write_text("stat,magnitude_percent,needed_by\n")
        return
    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["stat", "magnitude_percent", "needed_by"])
        writer.writeheader()
        writer.writerows(aura_rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ideas",
        type=Path,
        default=Path(__file__).with_name("wow ideas.csv"),
        help="Path to the messy CSV (defaults to davidstats/wow ideas.csv).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).with_name("custom_set_targets.csv"),
        help="Where to write the normalized targets CSV.",
    )
    parser.add_argument(
        "--auras-output",
        type=Path,
        default=Path(__file__).with_name("required_auras.csv"),
        help="Where to write the derived aura needs (hit/crit/etc).",
    )
    args = parser.parse_args()

    with args.ideas.open(newline="") as f:
        reader = csv.reader(f)
        rows = list(reader)

    slot_rows = list(iter_slot_rows(rows))
    targets = write_targets(slot_rows, args.output)
    aura_rows = collect_auras(targets)
    write_auras(aura_rows, args.auras_output)


if __name__ == "__main__":
    main()
