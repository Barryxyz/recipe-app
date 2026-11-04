#!/usr/bin/env python3
"""Builds the prototype catalog seed (F0.4).

Reads the hand-edited catalog_items.csv, looks up each item's USDA SR Legacy entry by
its exact description, and writes:
  - catalog_seed.csv   the reviewed source of truth: items plus fdc_id and nutrients per 100 g
  - load_catalog.sql   an idempotent upsert of catalog_seed.csv into catalog.*

Usage:
  1. Download and unzip USDA FoodData Central "SR Legacy" (CSV):
     https://fdc.nal.usda.gov/download-datasets  ->  FoodData_Central_sr_legacy_food_csv_2018-04.zip
  2. python3 -I supabase/seed/build_catalog_seed.py <path to the unzipped SR Legacy folder>
  3. Review catalog_seed.csv, then load it:
     supabase db query --remote -f supabase/seed/load_catalog.sql

Data: USDA FoodData Central, SR Legacy (public domain).
"""
import csv
import difflib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ITEMS = HERE / "catalog_items.csv"
SEED = HERE / "catalog_seed.csv"
SQL = HERE / "load_catalog.sql"

# FDC nutrient ids -> our columns (per 100 g).
NUTRIENTS = {
    "1008": "kcal",       # Energy, KCAL
    "1003": "protein_g",
    "1005": "carbs_g",    # Carbohydrate, by difference
    "1004": "fat_g",      # Total lipid (fat)
    "1079": "fiber_g",    # Fiber, total dietary
    "2000": "sugar_g",    # Sugars, total including NLEA
    "1093": "sodium_mg",  # Sodium, Na
}
NUTRIENT_COLS = list(NUTRIENTS.values())

ITEM_COLS = [
    "id", "name", "aliases", "category", "default_unit", "grams_per_unit", "density_g_per_ml",
    "shelf_life_fridge_days", "shelf_life_freezer_days", "shelf_life_pantry_days",
    "is_common_staple", "allergens",
]
ALLERGENS = {"milk", "egg", "fish", "shellfish", "tree nuts", "peanuts", "wheat", "soy", "sesame", "gluten"}
UNITS = {"g", "ml", "each"}


def find_csv(root: Path, name: str) -> Path:
    hits = list(root.rglob(name))
    if not hits:
        sys.exit(f"{name} not found under {root}")
    return hits[0]


FDP_SUFFIX = " (Includes foods for USDA's Food Distribution Program)"


def load_usda(root: Path):
    foods = {}
    with open(find_csv(root, "food.csv"), newline="") as f:
        for row in csv.DictReader(f):
            if row["data_type"] == "sr_legacy_food":
                foods[row["description"]] = row["fdc_id"]
                # Also match without USDA's distribution-program suffix.
                if row["description"].endswith(FDP_SUFFIX):
                    foods.setdefault(row["description"][: -len(FDP_SUFFIX)], row["fdc_id"])
    wanted = set(foods.values())
    nutrients = {}
    with open(find_csv(root, "food_nutrient.csv"), newline="") as f:
        for row in csv.DictReader(f):
            col = NUTRIENTS.get(row["nutrient_id"])
            if col and row["fdc_id"] in wanted:
                nutrients.setdefault(row["fdc_id"], {})[col] = row["amount"]
    return foods, nutrients


def validate(item, errors):
    where = f"id {item['id']} ({item['name']})"
    if item["default_unit"] not in UNITS:
        errors.append(f"{where}: default_unit must be one of {sorted(UNITS)}")
    if item["default_unit"] == "each" and not item["grams_per_unit"]:
        errors.append(f"{where}: unit 'each' needs grams_per_unit")
    if not item["shelf_life_fridge_days"]:
        errors.append(f"{where}: missing fridge shelf life")
    bad = set(filter(None, item["allergens"].split(";"))) - ALLERGENS
    if bad:
        errors.append(f"{where}: unknown allergens {sorted(bad)}")
    if item["is_common_staple"] not in ("true", "false"):
        errors.append(f"{where}: is_common_staple must be true or false")


def sql_text(v):
    return "null" if v in ("", None) else "'" + v.replace("'", "''") + "'"


def sql_num(v):
    return "null" if v in ("", None) else str(float(v)).rstrip("0").rstrip(".") if "." in v else v


def sql_array(v):
    parts = [p.strip() for p in v.split(";") if p.strip()]
    return "'{}'::text[]" if not parts else "array[" + ", ".join(sql_text(p) for p in parts) + "]"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    foods, nutrients = load_usda(Path(sys.argv[1]))

    with open(ITEMS, newline="") as f:
        items = list(csv.DictReader(f))

    errors, rows, ids, names = [], [], set(), set()
    for item in items:
        validate(item, errors)
        if item["id"] in ids or item["name"] in names:
            errors.append(f"duplicate id or name: {item['id']} {item['name']}")
        ids.add(item["id"]); names.add(item["name"])

        desc = item["usda_description"]
        fdc_id = foods.get(desc)
        if not fdc_id:
            close = difflib.get_close_matches(desc, foods.keys(), n=3, cutoff=0.5)
            errors.append(f"id {item['id']} ({item['name']}): no USDA entry '{desc}'. Close: {close}")
            continue
        n = nutrients.get(fdc_id, {})
        for col in ("kcal", "protein_g", "carbs_g", "fat_g"):
            if col not in n:
                errors.append(f"id {item['id']} ({item['name']}): USDA entry has no {col}")
        rows.append({**{c: item[c] for c in ITEM_COLS}, "fdc_id": fdc_id, "usda_description": desc,
                     **{c: n.get(c, "") for c in NUTRIENT_COLS}})

    # A search term must lead to one item: no alias may equal another item's name or alias.
    owner = {}
    for item in items:
        for term in [item["name"]] + [a for a in item["aliases"].split(";") if a]:
            key = term.strip().lower()
            if key in owner and owner[key] != item["id"]:
                errors.append(f"'{term}' is used by id {owner[key]} and id {item['id']}")
            owner.setdefault(key, item["id"])

    if errors:
        print("\n".join(errors), file=sys.stderr)
        sys.exit(1)

    cols = ITEM_COLS + ["fdc_id", "usda_description"] + NUTRIENT_COLS
    with open(SEED, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    ing_values, nut_values = [], []
    for r in rows:
        ing_values.append("  (" + ", ".join([
            r["id"], sql_text(r["name"]), sql_array(r["aliases"]), sql_text(r["category"]), r["fdc_id"],
            sql_text(r["default_unit"]), sql_num(r["grams_per_unit"]), sql_num(r["density_g_per_ml"]),
            sql_num(r["shelf_life_fridge_days"]), sql_num(r["shelf_life_freezer_days"]),
            sql_num(r["shelf_life_pantry_days"]), r["is_common_staple"], sql_array(r["allergens"]),
        ]) + ")")
        nut_values.append("  (" + ", ".join([r["id"]] + [sql_num(r[c]) for c in NUTRIENT_COLS]) + ")")

    sep = ",\n"
    ing_sql, nut_sql = sep.join(ing_values), sep.join(nut_values)
    SQL.write_text(f"""-- GENERATED by build_catalog_seed.py from catalog_seed.csv. Do not edit by hand.
-- Idempotent: safe to run again after editing the CSV; rows are matched by id.
-- Data: USDA FoodData Central, SR Legacy (public domain).
begin;

insert into catalog.ingredients
  (id, name, aliases, category, fdc_id, default_unit, grams_per_unit, density_g_per_ml,
   shelf_life_fridge_days, shelf_life_freezer_days, shelf_life_pantry_days, is_common_staple, allergens)
overriding system value
values
{ing_sql}
on conflict (id) do update set
  name = excluded.name, aliases = excluded.aliases, category = excluded.category, fdc_id = excluded.fdc_id,
  default_unit = excluded.default_unit, grams_per_unit = excluded.grams_per_unit,
  density_g_per_ml = excluded.density_g_per_ml,
  shelf_life_fridge_days = excluded.shelf_life_fridge_days,
  shelf_life_freezer_days = excluded.shelf_life_freezer_days,
  shelf_life_pantry_days = excluded.shelf_life_pantry_days,
  is_common_staple = excluded.is_common_staple, allergens = excluded.allergens;

insert into catalog.ingredient_nutrients
  (ingredient_id, {", ".join(NUTRIENT_COLS)})
values
{nut_sql}
on conflict (ingredient_id) do update set
  {", ".join(f"{c} = excluded.{c}" for c in NUTRIENT_COLS)};

-- Keep the identity sequence ahead of the hand-assigned ids.
select setval(pg_get_serial_sequence('catalog.ingredients', 'id'),
              greatest((select max(id) from catalog.ingredients), 1));

commit;

select count(*) as ingredients,
       (select count(*) from catalog.ingredient_nutrients) as with_nutrients
from catalog.ingredients;
""")
    print(f"Wrote {len(rows)} items to {SEED.name} and {SQL.name}")


if __name__ == "__main__":
    main()
