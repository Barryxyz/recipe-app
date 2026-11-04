#!/bin/bash
# Runs the F1.2 scan accuracy eval (eval/scan_eval.ts) against the hosted project with a
# throwaway anonymous user, then deletes that user. Costs real money (~$0.03-0.06 per scan).
#   ./scripts/eval-scan.sh             current settings
#   ./scripts/eval-scan.sh --compare   Sonnet high/medium/low and Haiku medium on the same photos (~4x the cost)
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

run_eval() {
  SCAN_URL="$URL/functions/v1/scan-ingredients" SUPABASE_KEY="$KEY" ACCESS_TOKEN="$TOKEN" \
    deno run --allow-read --allow-write=eval/results --allow-env --allow-net --allow-run=sips eval/scan_eval.ts
}

# Cost of this user's scan calls since a timestamp, priced from real token counts.
# Prices per million tokens (input, output), first-party API, prompts under 100K tokens.
cost_since() {
  supabase db query --remote --yes "select model, count(*) as calls, sum(input_tokens) as input, sum(output_tokens) as output
     from app.ai_usage_log where user_id = '$USER_ID' and kind = 'scan' and created_at >= '$1' group by model" 2>/dev/null \
  | python3 -I -c '
import json, sys
PRICES = {"claude-sonnet-5-5": (2.00, 10.00), "claude-haiku-5-5": (0.10, 0.50), "claude-opus-5-5": (4.00, 20.00)}
t = sys.stdin.read(); rows = json.loads(t[t.index("{"):]).get("rows") or []
calls = sum(r["calls"] for r in rows)
usd = sum(r["input"] / 1e6 * PRICES.get(r["model"], (0, 0))[0] + r["output"] / 1e6 * PRICES.get(r["model"], (0, 0))[1] for r in rows)
print(f"  cost       ${usd:.4f} total, ${usd / max(calls, 1):.4f} per model call ({calls} calls)")'
}

if [ "${1:-}" != "--compare" ]; then
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_eval
  cost_since "$start"
  exit 0
fi

# --compare: the same photos under several settings, to pick the cheapest that meets the
# targets. Function secrets are changed temporarily (they apply without redeploying) and
# removed again at the end, which returns to the code defaults.
CONFIGS=("claude-sonnet-5-5 high" "claude-sonnet-5-5 medium" "claude-sonnet-5-5 low" "claude-haiku-5-5 medium")
restore() { supabase secrets unset --yes SCAN_MODEL SCAN_EFFORT >/dev/null 2>&1; cleanup; }
trap restore EXIT
for cfg in "${CONFIGS[@]}"; do
  read -r model effort <<<"$cfg"
  echo; echo "===== $model, effort $effort ====="
  supabase secrets set --yes SCAN_MODEL="$model" SCAN_EFFORT="$effort" >/dev/null
  sleep 15   # let running function instances pick up the new secrets
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_eval
  cost_since "$start"
done
