#!/bin/bash
# Runs the F1.2 scan accuracy eval (eval/scan_eval.ts) against the hosted project with a
# throwaway anonymous user, then deletes that user. Costs real money (~$0.03-0.06 per scan).
#   ./scripts/eval-scan.sh
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f eval/labels.json ] || { echo "Create eval/labels.json first (see eval/labels.example.json)."; exit 1; }

URL=$(grep -E '^SUPABASE_URL' ios/Config/Dev.xcconfig | sed -E 's/.*= *//; s#\$\(\)##')
KEY=$(grep -E '^SUPABASE_KEY' ios/Config/Dev.xcconfig | sed -E 's/.*= *//')
TOKEN=$(curl -s -X POST "$URL/auth/v1/signup" -H "apikey: $KEY" -H 'Content-Type: application/json' -d '{}' \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
USER_ID=$(curl -s "$URL/auth/v1/user" -H "apikey: $KEY" -H "Authorization: Bearer $TOKEN" \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')
sql() { supabase db query --remote --yes "$1" >/dev/null 2>&1; }
cleanup() {
  hid=$(supabase db query --remote --yes "select household_id from app.users where id = '$USER_ID'" 2>/dev/null \
    | python3 -I -c 'import json,sys; t=sys.stdin.read(); r=json.loads(t[t.index("{"):]).get("rows") or []; print(r[0]["household_id"] if r else "")')
  sql "delete from auth.users where id = '$USER_ID'"
  [ -n "$hid" ] && sql "delete from app.households where id = '$hid'"
}
trap cleanup EXIT

SCAN_URL="$URL/functions/v1/scan-ingredients" SUPABASE_KEY="$KEY" ACCESS_TOKEN="$TOKEN" \
  deno run --allow-read --allow-write=eval/results --allow-env --allow-net --allow-run=sips eval/scan_eval.ts
