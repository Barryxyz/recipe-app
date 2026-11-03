#!/bin/bash
# F0.5 acceptance tests for the AI functions, against the hosted project.
# Makes a few real model calls (well under $0.01) and temporarily changes function secrets,
# restoring them at the end. Not part of test.sh because it costs money.
#
#   ./scripts/test-ai.sh
#
# Needs: supabase CLI (logged in, linked), anonymous sign-ins enabled, ai-test deployed.

set -uo pipefail
cd "$(dirname "$0")/.."

URL=$(grep -E '^SUPABASE_URL' ios/Config/Dev.xcconfig | sed -E 's/.*= *//; s#\$\(\)##')
KEY=$(grep -E '^SUPABASE_KEY' ios/Config/Dev.xcconfig | sed -E 's/.*= *//')
FN="$URL/functions/v1/ai-test"
failed=0

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; failed=1; }
json() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {'d': d}))" "$1"; }
sql() { supabase db query --remote --yes "$1" 2>/dev/null | python3 -I -c '
import json, sys
t = sys.stdin.read(); d = json.loads(t[t.index("{"):]); rows = d.get("rows") or []
print(list(rows[0].values())[0] if rows else "")'; }
secrets() { supabase secrets set --yes "$@" >/dev/null 2>&1 || supabase secrets set "$@" >/dev/null; }
call() { curl -s -o /tmp/ai-test.$$ -w '%{http_code}' -X POST "$FN" -H "apikey: $KEY" "$@"; }
body() { cat /tmp/ai-test.$$; }

# A throwaway anonymous user, deleted at the end. Its usage rows stay (user_id -> null).
TOKEN=$(curl -s -X POST "$URL/auth/v1/signup" -H "apikey: $KEY" -H 'Content-Type: application/json' -d '{}' | json 'd["access_token"]')
USER_ID=$(curl -s "$URL/auth/v1/user" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" | json 'd["id"]')
[ -n "$USER_ID" ] || { echo "Could not sign in anonymously (are anonymous sign-ins on?)"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')
usage_rows() { sql "select count(*) from app.ai_usage_log where user_id = '$USER_ID'"; }
cleanup() {
  secrets AI_ENABLED=true
  supabase secrets unset --yes RECIPE_MODEL >/dev/null 2>&1
  # Deleting the auth user cascades to app.users; the household has to go separately.
  hid=$(sql "select household_id from app.users where id = '$USER_ID'")
  sql "delete from auth.users where id = '$USER_ID'" >/dev/null
  [ -n "$hid" ] && sql "delete from app.households where id = '$hid'" >/dev/null
  rm -f /tmp/ai-test.$$
}
trap cleanup EXIT
echo "AI function tests (test user ${USER_ID:0:8}…)"

# 1. No user -> 401
code=$(call -H 'Content-Type: application/json' -d '{}')
[ "$code" = 401 ] && pass "no sign-in -> 401" || fail "no sign-in -> expected 401, got $code"

# 2. Toy schema -> typed data + one usage row
before=$(usage_rows)
code=$(call "${AUTH[@]}" -d '{}')
after=$(usage_rows)
if [ "$code" = 200 ] && [ "$(body | json 'len(d["attempts"])')" = 1 ] && [ "$(body | json 'type(d["data"]["kcal_per_100g"]).__name__ in ("int","float")')" = True ] && [ $((after - before)) = 1 ]; then
  pass "toy call -> typed data, 1 usage row ($(body | json 'd["data"]["name"]'), $(body | json 'd["model"]'))"
else
  fail "toy call -> code $code, rows +$((after - before)): $(body | head -c 300)"
fi

# 3. Forced validation failure -> exactly one fallback call, both logged
before=$(usage_rows)
code=$(call "${AUTH[@]}" -d '{"force_validation_failure": true}')
after=$(usage_rows)
attempts=$(body | json '[(a["model"], a["ok"]) for a in d["attempts"]]' 2>/dev/null)
if [ "$code" = 200 ] && [ "$(body | json 'len(d["attempts"])')" = 2 ] && [ "$(body | json 'd["attempts"][0]["ok"] is False and d["attempts"][1]["ok"] is True')" = True ] && [ $((after - before)) = 2 ]; then
  pass "forced failure -> 1 fallback, 2 usage rows $attempts"
else
  fail "forced failure -> code $code, rows +$((after - before)), attempts $attempts"
fi

# 4. Body over 10 MB -> 413
big=$(mktemp); head -c 11000000 /dev/zero | tr '\0' 'a' > "$big"
code=$(call "${AUTH[@]}" --data-binary @"$big"); rm -f "$big"
[ "$code" = 413 ] && pass "11 MB body -> 413" || fail "11 MB body -> expected 413, got $code"

# 5. RECIPE_MODEL change takes effect without redeploying
secrets RECIPE_MODEL=claude-sonnet-5-5
model=""
for _ in 1 2 3 4 5 6; do
  sleep 5
  code=$(call "${AUTH[@]}" -d '{}')
  model=$(body | json 'd.get("model","")' 2>/dev/null)
  [ "$model" = claude-sonnet-5-5 ] && break
done
[ "$model" = claude-sonnet-5-5 ] && pass "RECIPE_MODEL change applied without redeploy" || fail "RECIPE_MODEL change not applied (model: $model)"
supabase secrets unset --yes RECIPE_MODEL >/dev/null 2>&1

# 6. Kill switch
secrets AI_ENABLED=false
code=""
for _ in 1 2 3 4 5 6; do
  sleep 5
  code=$(call "${AUTH[@]}" -d '{}')
  [ "$code" = 503 ] && break
done
if [ "$code" = 503 ] && [ "$(body | json 'd["error"]["code"]')" = ai_disabled ]; then
  pass "AI_ENABLED=false -> 503 ai_disabled"
else
  fail "AI_ENABLED=false -> expected 503, got $code"
fi
secrets AI_ENABLED=true

[ $failed -eq 0 ] && echo "All AI tests passed." || echo "Some AI tests failed."
exit $failed
