#!/usr/bin/env python3
"""F2.2 live acceptance tests for generate-recipes, against the hosted project.

Makes about 6 real recipe calls (Haiku, a few cents in total; more if the fallback runs).
Not part of test.sh because it costs money.

    python3 -I scripts/test-recipes.py

Creates a throwaway anonymous user with allergies to milk, peanuts and soy and a pantry full of
temptations (cheddar, milk, peanut butter, soy sauce), then checks every returned recipe:
no allergens (by catalog tag and by name), real pantry references, no expired item, amounts
within what's on hand, times, steps and macros present. Deletes the user at the end.
Needs: supabase CLI (logged in, linked), anonymous sign-ins on, generate-recipes deployed.
"""
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
cfg = (ROOT / "ios/Config/Dev.xcconfig").read_text()
URL = re.search(r"^SUPABASE_URL\s*=\s*(.+)$", cfg, re.M).group(1).replace("$()", "").strip()
KEY = re.search(r"^SUPABASE_KEY\s*=\s*(.+)$", cfg, re.M).group(1).strip()
FN = f"{URL}/functions/v1/generate-recipes"

ALLERGENS = ["milk", "peanuts", "soy"]
# Words that would betray one of those allergens in an ingredient name.
BANNED = re.compile(r"\b(milk|cheese|cheddar|butter|cream|yogh?urt|parmesan|ghee|whey|peanuts?|satay|soy|soya|tofu|"
                    r"edamame|miso|tamari)\b", re.I)
PLANT = re.compile(r"\b(coconut|almond|oat|rice) milk\b|\bbutter ?beans?\b|\bbutternut\b", re.I)

failed = False


def check(ok, label):
    global failed
    print(f"  {'PASS' if ok else 'FAIL'}  {label}")
    failed |= not ok


def http(method, url, body=None, token=None, headers=None):
    h = {"apikey": KEY, "Content-Type": "application/json", **(headers or {})}
    if token:
        h["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, method=method, headers=h,
                                 data=None if body is None else json.dumps(body).encode())
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
    d = json.loads(out[out.index("{"):])
    return d.get("rows") or []


def rest(method, path, token, body=None):
    return http(method, f"{URL}/rest/v1/{path}", body, token,
                {"Content-Profile": "app", "Accept-Profile": "app", "Prefer": "return=representation"})


_, auth = http("POST", f"{URL}/auth/v1/signup", {})
TOKEN = auth["access_token"]
USER = auth["user"]["id"]
print(f"Recipe tests (test user {USER[:8]}…)")

try:
    rest("PATCH", f"user_prefs?user_id=eq.{USER}", TOKEN, {"allergens": ALLERGENS})
    soon = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 86400))
    gone = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 86400))
    cols = ["ingredient_id", "display_name", "quantity", "unit", "location", "source", "is_staple",
            "expiry_overridden", "expires_at"]
    rows = [
        (52, "chicken breast", 500, "g", "fridge", False, False, None),
        (67, "white rice", 1000, "g", "pantry", False, False, None),
        (22, "broccoli", 300, "g", "fridge", False, False, None),
        (38, "eggs", 6, "each", "fridge", False, False, None),
        (41, "cheddar cheese", 200, "g", "fridge", False, False, None),
        (39, "milk", 1000, "ml", "fridge", False, False, None),
        (96, "peanut butter", 340, "g", "pantry", False, False, None),
        (24, "spinach", 150, "g", "fridge", False, True, soon),        # expiring tomorrow
        (100, "canned tomatoes", 800, "g", "pantry", False, False, None),
        (11, "onion", 2, "each", "pantry", False, False, None),
        (54, "ground beef", 400, "g", "fridge", False, True, gone),     # expired: must not be used
        (85, "olive oil", None, "ml", "pantry", True, True, None),
        (77, "salt", None, "g", "pantry", True, True, None),
        (78, "black pepper", None, "g", "pantry", True, True, None),
        (13, "garlic", None, "each", "pantry", True, True, None),
        (89, "soy sauce", None, "ml", "pantry", True, True, None),
    ]
    payload = [dict(zip(cols, (i, n, q, u, loc, "manual", st, ov, exp))) for i, n, q, u, loc, st, ov, exp in rows]
    code, items = rest("POST", "pantry_items?columns=" + ",".join(cols), TOKEN, payload)
    assert code == 201, items
    by_id = {it["id"]: it for it in items}
    expired_id = next(it["id"] for it in items if it["display_name"] == "ground beef")
    tags = {r["id"]: r["allergens"] for r in sql("select id, allergens from catalog.ingredients")}

    # 1. No sign-in -> 401; usage check
    code, _ = http("POST", FN, {})
    check(code == 401, "no sign-in -> 401")
    code, body = http("POST", FN, {"check": True}, TOKEN)
    check(code == 200 and body["usage"]["today"] == 0 and body["usage"]["daily_limit"] > 0,
          f"usage check -> {code} {body.get('usage') if isinstance(body, dict) else body}")

    def generate(**opts):
        req = {"servings": 2, "max_minutes": 45, "meal": "dinner", "cuisine": None, "prefer_expiring": True,
               "only_on_hand": False, "exclude_pantry_item_ids": [], **opts}
        t = time.time()
        code, body = http("POST", FN, req, TOKEN)
        return code, body, time.time() - t, req

    def problems(rec, req):
        out = []
        if not rec["steps"] or not rec["ingredients"]:
            out.append("no steps/ingredients")
        if req["max_minutes"] and rec["prep_min"] + rec["cook_min"] > req["max_minutes"] + 5:
            out.append("too long")
        m = rec.get("macros_per_serving") or {}
        if not isinstance(m.get("kcal"), (int, float)):
            out.append("no macros")
        missing = 0
        for ing in rec["ingredients"]:
            name = ing["name"]
            if ing["ingredient_id"] is not None and set(tags.get(ing["ingredient_id"], [])) & set(ALLERGENS):
                out.append(f"allergen tag: {name}")
            if BANNED.search(PLANT.sub("", name)):
                out.append(f"allergen name: {name}")
            pid = ing["pantry_item_id"]
            if pid:
                if pid not in by_id:
                    out.append(f"unknown pantry item: {name}")
                elif pid == expired_id:
                    out.append(f"expired item used: {name}")
                else:
                    have = by_id[pid]
                    if have["quantity"] is not None and ing["quantity"] is not None and ing["unit"] == have["unit"] \
                            and ing["quantity"] > float(have["quantity"]) * 1.1:
                        out.append(f"too much {name}")
            if ing["kind"] == "missing" and not ing["is_optional"]:
                missing += 1
        if missing > (0 if req["only_on_hand"] else 3):
            out.append(f"{missing} missing")
        return out

    # 2. Five normal requests: no allergens etc. in any recipe
    total, times, bad, fallbacks = 0, [], [], 0
    for i, cuisine in enumerate([None, "italian", "mexican", "indian", None]):
        code, body, secs, req = generate(cuisine=cuisine, max_minutes=[45, 30, None, 60, 30][i])
        times.append(secs)
        if code != 200:
            bad.append(f"request {i + 1}: {code} {str(body)[:200]}")
            continue
        fallbacks += sum(1 for a in body["attempts"][1:])
        for rec in body["recipes"]:
            total += 1
            for p in problems(rec, req):
                bad.append(f"{rec['title']}: {p}")
        print(f"        {len(body['recipes'])} recipes in {secs:.1f}s ({body['attempts'][-1]['model']})"
              f"{' note: ' + body['note'] if body.get('note') else ''}: " +
              "; ".join(f"{r['title']} [{r['prep_min'] + r['cook_min']} min, "
                        f"{round(r['macros_per_serving']['kcal'] / 10) * 10} kcal"
                        f"{', ≈' if r['macros_per_serving']['estimated'] else ''}"
                        f"{', uses ' + ', '.join(r['uses_expiring']) if r['uses_expiring'] else ''}]"
                        for r in body["recipes"]))
    check(not bad and total >= 5, f"{total} recipes from 5 requests: no allergens, real pantry refs, no expired item, "
                                  f"amounts on hand, times, steps, macros" + ("" if not bad else f" -> {bad[:5]}"))
    check(fallbacks <= 1, f"fallback used {fallbacks} time(s) in 5 requests")

    # 3. Only what I have -> no missing ingredients
    code, body, secs, req = generate(only_on_hand=True)
    times.append(secs)
    missing = [i["name"] for r in (body.get("recipes", []) if code == 200 else []) for i in r["ingredients"]
               if i["kind"] == "missing"]
    check(code == 200 and not missing,
          f"only what I have -> {len(body.get('recipes', [])) if code == 200 else code} recipes, no missing "
          f"ingredients{'' if not missing else f' (found {missing})'}")

    # 4. Excluding items -> they're not used
    chicken = next(it["id"] for it in items if it["display_name"] == "chicken breast")
    code, body, secs, req = generate(exclude_pantry_item_ids=[chicken])
    times.append(secs)
    used = [i["name"] for r in (body.get("recipes", []) if code == 200 else []) for i in r["ingredients"]
            if i["pantry_item_id"] == chicken]
    check(code == 200 and not used, f"excluded chicken -> not used{'' if not used else f' (found {used})'}")

    # 5. Usage: one 'recipes' row per request
    n = sql(f"select count(*) as n from app.ai_usage_log where user_id = '{USER}' and kind = 'recipes'")[0]["n"]
    check(n == 7, f"{n} 'recipes' usage rows for 7 requests")
    times.sort()
    print(f"        time per request: median {times[len(times) // 2]:.1f}s, max {times[-1]:.1f}s")
finally:
    hid = sql(f"select household_id from app.users where id = '{USER}'")
    sql(f"delete from auth.users where id = '{USER}'")
    if hid and hid[0]["household_id"]:
        sql(f"delete from app.households where id = '{hid[0]['household_id']}'")

print("All recipe tests passed." if not failed else "Some recipe tests failed.")
sys.exit(1 if failed else 0)
