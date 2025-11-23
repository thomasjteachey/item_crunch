# davidstats workspace

The `davidstats` folder holds the messy CSV notes for the custom set revamp and
helpers to normalize them into something we can feed into `item_template` and
`dbc.spell_lplus`.

## Files
- `wow ideas.csv` – raw notes for each class/spec set.
- `current-stats.txt` – current `item_template` snapshot for the custom items.
- `normalize_custom_sets.py` – turns `wow ideas.csv` into structured targets and
  a list of aura magnitudes we need available in `dbc.spell_lplus`.
- Generated outputs:
  - `custom_set_targets.csv`
  - `required_auras.csv`

## Usage
Run the normalizer whenever the notes change:

```bash
python normalize_custom_sets.py
```

- `custom_set_targets.csv` captures the per-slot stat totals as discrete
  columns. It is meant to be joined back to the item rows in
  `current-stats.txt` (by whatever mapping you prefer) so you can overwrite the
  existing stats with the new targets.
- `required_auras.csv` lists the percent-based stats (hit, crit, dodge, block
  chance, etc.) that must exist in `dbc.spell_lplus`. Seed any missing entries
  by cloning the closest spell and adjusting its `EffectBasePoints_1` to match
  the magnitude shown here.

When wiring the stats into `item_template`, remember that the DBC auras drive
percent-based effects. If an item needs a hit/crit/block aura that isn't in
`dbc.spell_lplus`, clone an existing aura spell with the same `EffectAura`
value, update its `EffectBasePoints_1` to the magnitude in `required_auras.csv`,
and point the item's `spellid_*` slot at the new spell ID.

### Seeding the required auras in-game

The CSV output is meant to be loaded into a helper table before cloning any
missing aura spells:

```sql
CREATE TABLE IF NOT EXISTS helper.davidstats_required_auras (
  stat VARCHAR(64) NOT NULL,
  magnitude_percent INT NOT NULL
);
LOAD DATA LOCAL INFILE 'required_auras.csv'
INTO TABLE helper.davidstats_required_auras
FIELDS TERMINATED BY ',' ENCLOSED BY '"'
IGNORE 1 LINES;
```

Once populated, run `sp_seed_davidstats_auras` (added alongside the other SQL
procedures) to reuse existing `dbc.spell_lplus` entries when an exact match
exists, or to clone the closest matching aura and bump its `EffectBasePoints`
to the requested magnitude. Results are logged in
`helper.davidstats_seeded_auras` so you can point the custom items at the new
spell IDs.

### Building insert statements for the gear

Use the new `sp_seed_davidstats_items.sql` helper to keep the percent-based
auras wired up while producing final `item_template` rows. When you just need
explicit INSERT lines for every staged item, run the generator and apply the
statements directly.

1. Ensure your staging data is loaded into `helper.davidstats_items` (the table
   matches `lplusworld.item_template` and also exposes `hit_pct`,
   `spell_hit_pct`, `crit_pct`, `spell_crit_pct`, `dodge_pct`, and
   `block_chance_pct` for any percent-based effects you want added). Keep any
   existing spell slots populated; empty slots will be filled with the new aura
   spells.
 2. Load `sp_seed_davidstats_auras.sql` and `sp_seed_davidstats_items.sql` into
    MySQL.
3. Call `CALL helper.sp_seed_davidstats_items();`

The procedure will:
- Insert any new aura magnitudes it finds in `helper.davidstats_items` into
  `helper.davidstats_required_auras` and then call `sp_seed_davidstats_auras`
  so every requested magnitude has a `dbc.spell_lplus` row (cloning when
  required).
- Pair each item’s aura requests with the first available zeroed
  `spellid_#` slots, reusing any existing non-zero spells you already staged.
- `REPLACE` the staged rows into `lplusworld.item_template`, ignoring the
  staging-only percent columns.

If you want standalone `INSERT` statements for every staged row, generate them
from `current-stats.txt`:

```bash
python generate_item_inserts.py
```

This writes `custom_item_inserts.sql`, which contains an `INSERT INTO
helper.davidstats_items (...) VALUES (...)` statement for each row in
`current-stats.txt`. Load the aura seeder first so any referenced `spellid_*`
values already exist in `dbc.spell_lplus`, then execute the generated file to
populate the helper table.
