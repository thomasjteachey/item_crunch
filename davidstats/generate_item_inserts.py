import csv
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ITEM_TEMPLATE_SQL = REPO_ROOT / "item_template.sql"
CURRENT_STATS = Path(__file__).resolve().parent / "current-stats.txt"
OUTPUT_SQL = Path(__file__).resolve().parent / "custom_item_inserts.sql"


def load_columns():
    cols = []
    with ITEM_TEMPLATE_SQL.open() as f:
        for line in f:
            line = line.strip()
            if line.startswith("`"):
                cols.append(line.split("`")[1])
            elif line.startswith("PRIMARY KEY"):
                break
    return cols


def format_value(raw: str) -> str:
    escaped = raw.replace("'", "''")
    return f"'{escaped}'"


def main():
    columns = load_columns()
    rows = []
    with CURRENT_STATS.open() as f:
        reader = csv.reader(f, skipinitialspace=True, quotechar="'", escapechar="\\")
        for row in reader:
            if not row:
                continue
            if len(row) != len(columns):
                raise ValueError(f"Column mismatch: expected {len(columns)}, got {len(row)}")
            rows.append(row)

    header = (
        "-- Insert statements for the davidstats custom set items\n"
        "-- Generated from current-stats.txt; load helper.sp_seed_davidstats_auras first so any aura spellids are valid.\n"
    )

    col_list = ",".join(columns)
    lines = [header]
    for row in rows:
        values = ",".join(format_value(v) for v in row)
        lines.append(f"INSERT INTO helper.davidstats_items ({col_list}) VALUES ({values});")

    OUTPUT_SQL.write_text("\n".join(lines))


if __name__ == "__main__":
    main()
