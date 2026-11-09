#!/bin/bash
# F2.3 acceptance tests for recompute-macros, against the hosted project.
# Makes one real nutrition-estimate call (Haiku, well under $0.01). Not part of test.sh
# because it costs money.
#
#   ./scripts/test-macros.sh
#
# Needs: supabase CLI (logged in, linked), anonymous sign-ins on, recompute-macros deployed.

set -uo pipefail
cd "$(dirname "$0")/.."

URL=$(grep -E '^SUPABASE_URL' ios/Config/Dev.xcconfig | sed -E 's/.*= *//; s#\$\(\)##')
KEY=$(grep -E '^SUPABASE_KEY' ios/Config/Dev.xcconfig | sed -E 's/.*= *//')
FN="$URL/functions/v1/recompute-macros"
TMP=$(mktemp)
failed=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; failed=1; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
sql() { supabase db query --remote --yes "$1" 2>/dev/null | python3 -I -c '
import json, sys
t = sys.stdin.read(); d = json.loads(t[t.index("{"):]); rows = d.get("rows") or []
print(list(rows[0].values())[0] if rows else "")'; }

TOKEN=$(curl -s -X POST "$URL/auth/v1/signup" -H "apikey: $KEY" -H 'Content-Type: application/json' -d '{}' | json 'd["access_token"]')
USER_ID=$(curl -s "$URL/auth/v1/user" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" | json 'd["id"]')
[ -n "$USER_ID" ] || { echo "Could not sign in anonymously (are anonymous sign-ins on?)"; exit 1; }
H=(-H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
rest() { # rest METHOD path [json]
  curl -s -X "$1" "$URL/rest/v1/$2" "${H[@]}" -H 'Content-Profile: app' -H 'Accept-Profile: app' \
    -H 'Prefer: return=representation' ${3:+-d "$3"}; }
recompute() { curl -s -o "$TMP" -w '%{http_code}' -X POST "$FN" "${H[@]}" -d "{\"recipe_id\":\"$1\"}"; }
estimates() { sql "select count(*) from app.ai_usage_log where user_id = '$USER_ID' and kind = 'estimate'"; }
cleanup() {
  hid=$(sql "select household_id from app.users where id = '$USER_ID'")
  sql "delete from auth.users where id = '$USER_ID'" >/dev/null
  [ -n "$hid" ] && sql "delete from app.households where id = '$hid'" >/dev/null
  rm -f "$TMP"
}
trap cleanup EXIT
echo "Macros tests (test user ${USER_ID:0:8}…)"

# A recipe: 200 g chicken breast + 100 g white rice + 2 tbsp of a custom item with no
# nutrition yet + "Basmati Rice" as free text (optional, so not counted). Serves 2.
CUSTOM=$(rest POST ingredients_private '{"name":"gochujang"}' | json 'd[0]["id"]')
RECIPE=$(rest POST recipes '{"title":"Macro test","servings":2,"source":"manual"}' | json 'd[0]["id"]')
rest POST recipe_ingredients "[
  {\"recipe_id\":\"$RECIPE\",\"position\":0,\"ingredient_id\":52,\"name\":\"chicken breast\",\"quantity\":200,\"unit\":\"g\"},
  {\"recipe_id\":\"$RECIPE\",\"position\":1,\"ingredient_id\":67,\"name\":\"white rice\",\"quantity\":100,\"unit\":\"g\"},
  {\"recipe_id\":\"$RECIPE\",\"position\":2,\"ingredient_id\":$CUSTOM,\"name\":\"gochujang\",\"quantity\":2,\"unit\":\"tbsp\"},
  {\"recipe_id\":\"$RECIPE\",\"position\":3,\"name\":\"Basmati Rice\",\"quantity\":1,\"unit\":\"cup\",\"is_optional\":true}
]" >/dev/null

# 1. No sign-in -> 401
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$FN" -H "apikey: $KEY" -d '{}')
[ "$code" = 401 ] && pass "no sign-in -> 401" || fail "no sign-in -> expected 401, got $code"

# 2. Someone else's / unknown recipe -> 404
code=$(recompute 00000000-0000-4000-8000-000000000000)
[ "$code" = 404 ] && pass "unknown recipe -> 404" || fail "unknown recipe -> expected 404, got $code"

# 3. First recompute: one estimate call, stored on the custom item, values saved on the recipe
code=$(recompute "$RECIPE")
kcal1=$(json 'd["macros_total"]["kcal"]' < "$TMP" 2>/dev/null)
stored=$(sql "select (macros_total->>'kcal')::numeric from app.recipes where id = '$RECIPE'")
est=$(estimates)
saved=$(sql "select nutrients_per_100g is not null from app.ingredients_private where id = $CUSTOM")
base=$(python3 -I -c "print(605 + 0)")  # chicken 240 + rice 365, before the custom item
if [ "$code" = 200 ] && [ "$est" = 1 ] && [ "$saved" = true ] && python3 -I -c "
k=float('$kcal1'); s=float('$stored'); assert abs(k-s) < 0.01 and $base < k < $base + 300" 2>/dev/null; then
  pass "first recompute -> 1 estimate call, saved (total $(printf '%.0f' "$kcal1") kcal, $(json 'd["macros_total"]["estimated"]' < "$TMP"))"
else
  fail "first recompute -> code $code, estimates $est, saved $saved, kcal $kcal1, stored $stored: $(head -c 300 "$TMP")"
fi

# 4. Second recompute: the stored estimate is used, no new call
recompute "$RECIPE" >/dev/null
[ "$(estimates)" = 1 ] && pass "second recompute -> no new estimate call" || fail "second recompute -> $(estimates) estimate calls"

# 5. Edit: 200 g -> 400 g chicken adds 240 kcal (and 120 per serving)
rest PATCH "recipe_ingredients?recipe_id=eq.$RECIPE&position=eq.0" '{"quantity":400}' >/dev/null
code=$(recompute "$RECIPE")
stored=$(sql "select (macros_total->>'kcal')::numeric || ' ' || (macros_per_serving->>'kcal')::numeric from app.recipes where id = '$RECIPE'")
if [ "$code" = 200 ] && python3 -I -c "
t, p = map(float, '$stored'.split()); assert abs(t - float('$kcal1') - 240) < 0.01 and abs(p - t/2) < 0.01" 2>/dev/null; then
  pass "after an edit the stored values update (+240 kcal total)"
else
  fail "after edit -> code $code, stored $stored (before $kcal1)"
fi

[ $failed -eq 0 ] && echo "All macros tests passed." || echo "Some macros tests failed."
exit $failed
