#!/usr/bin/env python3
"""F2.2 recipe quality eval, against the hosted project.

Makes 15 real recipe calls (5 pantries x 3 option sets; Haiku, plus Sonnet when the fallback
runs): roughly $0.05-0.50 in total. Not part of test.sh because it costs money.

    python3 -I scripts/eval-recipes.py

For each request it records recipes, latency, whether the fallback ran and the note. It reports
the fallback rate and latency (median, p90), then writes the first recipe of every request
(15 recipes) to a rating sheet for hand rating 1-5 (target: average >= 4, fallback < 15%).
Pantry 5 is the "odd pantry" (ketchup, strawberries, frozen cod, almond milk, tortilla chips):
a pass is no forced combination; fewer recipes with a sensible note is fine.

Writes eval/results/recipes-<timestamp>.json and .md. Uses a throwaway anonymous user, deleted
at the end. Needs: supabase CLI (logged in, linked), anonymous sign-ins on.
"""
import json
import re
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
cfg = (ROOT / "ios/Config/Dev.xcconfig").read_text()
URL = re.search(r"^SUPABASE_URL\s*=\s*(.+)$", cfg, re.M).group(1).replace("$()", "").strip()
KEY = re.search(r"^SUPABASE_KEY\s*=\s*(.+)$", cfg, re.M).group(1).strip()
FN = f"{URL}/functions/v1/generate-recipes"
OUT = ROOT / "eval/results"

STAPLES = [("salt", None, "g"), ("black pepper", None, "g"), ("olive oil", None, "ml"), ("garlic", None, "each")]
# (catalog name, quantity, unit, location, days until expiry or None for the default)
PANTRIES = {
    "weeknight": [("chicken thigh", 600, "g", "fridge", 2), ("white rice", 1000, "g", "pantry", None),
                  ("broccoli", 300, "g", "fridge", 3), ("onion", 2, "each", "pantry", None),
                  ("egg", 6, "each", "fridge", None), ("carrot", 3, "each", "fridge", None),
                  ("soy sauce", None, "ml", "pantry", None)],
    "veggie": [("canned chickpeas", 800, "g", "pantry", None), ("canned tomatoes", 800, "g", "pantry", None),
               ("spinach", 200, "g", "fridge", 1), ("feta", 200, "g", "fridge", 5), ("pasta", 500, "g", "pantry", None),
               ("lemon", 2, "each", "fridge", None), ("zucchini", 2, "each", "fridge", 3)],
    "breakfast": [("egg", 12, "each", "fridge", None), ("bread", 500, "g", "pantry", 2), ("milk", 1000, "ml", "fridge", 2),
                  ("butter", 250, "g", "fridge", None), ("banana", 3, "each", "pantry", 1),
                  ("rolled oats", 500, "g", "pantry", None), ("greek yogurt", 500, "g", "fridge", None)],
    "seafood": [("salmon", 400, "g", "fridge", 1), ("potato", 1000, "g", "pantry", None),
                ("green beans", 300, "g", "fridge", 3), ("lemon", 1, "each", "fridge", None),
                ("dill", 30, "g", "fridge", 2), ("plain yogurt", 300, "g", "fridge", None)],
    "odd": [("ketchup", 500, "ml", "fridge", None), ("strawberries", 250, "g", "fridge", 2),
            ("cod", 400, "g", "freezer", None), ("almond milk", 1000, "ml", "fridge", None),
            ("tortilla chips", 200, "g", "pantry", None)],
}
BASE = {"servings": 2, "max_minutes": 45, "meal": "dinner", "cuisine": None, "prefer_expiring": True,
        "only_on_hand": False, "exclude_pantry_item_ids": []}
OPTION_SETS = {
    "weeknight": [{}, {"max_minutes": 30, "cuisine": "chinese"}, {"only_on_hand": True, "meal": "lunch", "max_minutes": None}],
    "veggie": [{}, {"cuisine": "italian", "max_minutes": 30}, {"only_on_hand": True, "meal": "lunch", "max_minutes": None}],
    "breakfast": [{"meal": "breakfast", "max_minutes": 20}, {"meal": "snack", "max_minutes": None},
                  {"only_on_hand": True, "meal": "breakfast", "max_minutes": 30}],
    "seafood": [{}, {"cuisine": "mediterranean"}, {"only_on_hand": True, "max_minutes": 30}],
    "odd": [{}, {"only_on_hand": True}, {"cuisine": "mexican", "meal": "any", "max_minutes": None}],
}


def http(method, url, body=None, token=None, headers=None):
    h = {"apikey": KEY, "Content-Type": "application/json", **(headers or {})}
    if token:
        h["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, method=method, headers=h, data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")


def sql(q):
    out = subprocess.run(["supabase", "db", "query", "--remote", "--yes", q], capture_output=True, text=True,
                         cwd=ROOT).stdout
    d, _ = json.JSONDecoder().raw_decode(out[out.index("{"):])
    return d.get("rows") or []


def rest(method, path, token, body=None):
    return http(method, f"{URL}/rest/v1/{path}", body, token,
                {"Content-Profile": "app", "Accept-Profile": "app", "Prefer": "return=representation"})


def iso(days):
    return time.strftime("%Y-%m-%dT23:59:59Z", time.gmtime(time.time() + days * 86400))


names = sorted({n for p in PANTRIES.values() for n, *_ in p} | {n for n, *_ in STAPLES})
ids = {r["name"]: r["id"] for r in sql("select id, name from catalog.ingredients where name in (" +
                                         ", ".join("'" + n.replace("'", "''") + "'" for n in names) + ")")}
missing = [n for n in names if n not in ids]
assert not missing, f"not in the catalog: {missing}"

_, auth = http("POST", f"{URL}/auth/v1/signup", {})
TOKEN, USER = auth["access_token"], auth["user"]["id"]
print(f"Recipe quality eval (test user {USER[:8]}…), 15 requests")
results = []
try:
    cols = ["ingredient_id", "display_name", "quantity", "unit", "location", "source", "is_staple",
            "expiry_overridden", "expires_at"]
    for pname, items in PANTRIES.items():
        rest("DELETE", "pantry_items?id=not.is.null", TOKEN)
        rows = [dict(zip(cols, (ids[n], n, None, u, "pantry", "manual", True, True, None))) for n, _, u in STAPLES]
        rows += [dict(zip(cols, (ids[n], n, q, u, loc, "manual", False, d is not None, iso(d) if d is not None else None)))
                 for n, q, u, loc, d in items]
        code, made = rest("POST", "pantry_items?columns=" + ",".join(cols), TOKEN, rows)
        assert code == 201, made
        last_titles = []
        for i, opts in enumerate(OPTION_SETS[pname]):
            # Like the app: the previous ideas' titles go along, so new requests suggest other dishes.
            req = {**BASE, **opts, **({"avoid_titles": last_titles} if last_titles else {})}
            t = time.time()
            code, body = http("POST", FN, req, TOKEN)
            secs = time.time() - t
            ok = code == 200
            rec = {"pantry": pname, "options": opts, "status": code, "seconds": round(secs, 1),
                   "recipes": body.get("recipes", []) if ok else [], "note": body.get("note") if ok else None,
                   "limited_by": body.get("limited_by") if ok else None,
                   "attempts": body.get("attempts") if ok else None, "error": None if ok else str(body)[:300]}
            results.append(rec)
            if rec["recipes"]:
                last_titles = [x["title"] for x in rec["recipes"]]
            fb = ok and len(body.get("attempts") or []) > 1
            print(f"  {pname:9} #{i + 1}  {code}  {secs:5.1f}s  {len(rec['recipes'])} recipes"
                  f"{'  FALLBACK' if fb else ''}{'  note: ' + rec['note'] if rec['note'] else ''}")
            for r in rec["recipes"]:
                print(f"      - {r['title']} ({r['prep_min'] + r['cook_min']} min)")
finally:
    hid = sql(f"select household_id from app.users where id = '{USER}'")
    sql(f"delete from auth.users where id = '{USER}'")
    if hid and hid[0]["household_id"]:
        sql(f"delete from app.households where id = '{hid[0]['household_id']}'")

ok = [r for r in results if r["status"] == 200]
times = sorted(r["seconds"] for r in ok)
fallbacks = sum(1 for r in ok if len(r["attempts"] or []) > 1)
p90 = times[min(len(times) - 1, int(0.9 * len(times)))] if times else None
print(f"\n{len(ok)}/{len(results)} requests ok, {sum(len(r['recipes']) for r in ok)} recipes, "
      f"fallback {fallbacks}/{len(ok)} ({100 * fallbacks / max(len(ok), 1):.0f}%), "
      f"latency median {statistics.median(times) if times else 0:.1f}s, p90 {p90}s, max {times[-1] if times else 0}s")

OUT.mkdir(parents=True, exist_ok=True)
stamp = time.strftime("%Y%m%d-%H%M%S")
(OUT / f"recipes-{stamp}.json").write_text(json.dumps(results, indent=1))

# Rating sheet: the first recipe of each request (or the note when there were none).
lines = [f"# Recipe quality eval {stamp}", "", "Rate each recipe 1-5 (would you cook it? does it make sense with this pantry?).", ""]
n = 0
for r in results:
    n += 1
    label = f"{r['pantry']} / {json.dumps(r['options']) if r['options'] else 'defaults'}"
    if not r["recipes"]:
        lines += [f"## {n}. ({label}) no recipes", "", f"Note: {r['note'] or r['error']}", ""]
        continue
    rec = r["recipes"][0]
    lines += [f"## {n}. {rec['title']}  ({label})", "", rec["description"], "",
              f"{rec['servings']} servings · prep {rec['prep_min']} min · cook {rec['cook_min']} min · "
              f"{round(rec['macros_per_serving']['kcal'])} kcal/serving", ""]
    for ing in rec["ingredients"]:
        q = f"{ing['quantity']:g} {ing['unit'] or ''}".strip() if ing["quantity"] is not None else "some"
        lines.append(f"- {q} {ing['name']}{' (' + ing['note'] + ')' if ing.get('note') else ''}"
                     f"{' [missing]' if ing['kind'] == 'missing' else ''}{' [optional]' if ing['is_optional'] else ''}")
    lines.append("")
    lines += [f"{i + 1}. {s}" for i, s in enumerate(rec["steps"])]
    if r["note"]:
        lines += ["", f"Note: {r['note']}"]
    lines.append("")
(OUT / f"recipes-{stamp}.md").write_text("\n".join(lines))
print(f"Wrote eval/results/recipes-{stamp}.json and .md")
