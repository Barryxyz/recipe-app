#!/bin/bash
# Runs every test in the repo.
#
#   ./scripts/test.sh          everything below
#   ./scripts/test.sh fn       Edge Function and share page (Worker) tests (deno)
#   ./scripts/test.sh db       database tests only (fast, ~10 s)
#   ./scripts/test.sh ios      iOS unit tests only (simulator)
#
# Database tests run against the linked hosted Supabase project. Each one runs inside a
# transaction that is rolled back, so they leave no data behind.
# Needs: supabase CLI (logged in and linked), Xcode with an iOS simulator.

set -uo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

what=${1:-all}
failed=0

run_fn_checks() {
  command -v deno >/dev/null || { echo "  FAIL  deno is not installed"; failed=1; return; }
  if out=$(deno test --quiet supabase/functions/_shared/ 2>&1); then
    echo "  PASS  _shared unit tests"
  else
    echo "  FAIL  _shared unit tests"
    printf '%s\n' "$out" | grep -E 'error|FAILED|expected' | head -10 | sed 's/^/        /'
    failed=1
  fi
  for dir in supabase/functions/*/; do
    name=$(basename "$dir")
    [ "$name" = _shared ] && continue
    if out=$(cd "$dir" && deno check --config deno.json index.ts 2>&1); then
      echo "  PASS  $name"
    else
      echo "  FAIL  $name"
      printf '%s\n' "$out" | grep -E 'ERROR|error' | head -10 | sed 's/^/        /'
      failed=1
    fi
  done
  # The shared-recipe page Worker (F4.2) is plain JS, tested with Deno too.
  if out=$(deno test --quiet share/test 2>&1); then
    echo "  PASS  share page (Worker) tests"
  else
    echo "  FAIL  share page (Worker) tests"
    printf '%s\n' "$out" | grep -E 'error|FAILED|AssertionError' | head -10 | sed 's/^/        /'
    failed=1
  fi
}

run_db_tests() {
  for f in supabase/tests/*.sql; do
    # Shared case tables (also used by the Swift tests) are filled in here.
    sqlfile=$(mktemp)
    python3 -I - "$f" "$sqlfile" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
sql = open(src).read()
if "__EXPIRY_CASES_JSON__" in sql:
    sql = sql.replace("__EXPIRY_CASES_JSON__", open("supabase/tests/expiry_cases.json").read())
open(dst, "w").write(sql)
PY
    out=$(supabase db query --remote --yes -f "$sqlfile" 2>&1)
    rm -f "$sqlfile"
    result=$(printf '%s' "$out" | python3 -I -c '
import json, sys
t = sys.stdin.read()
try:
    # raw_decode: ignore anything printed after the JSON (e.g. the CLI update notice).
    d, _ = json.JSONDecoder().raw_decode(t[t.index("{"):])
    print(d["rows"][0]["result"])
except Exception:
    print("ERROR: " + t.strip().splitlines()[-1][:400])
')
    if [ "$result" = "PASS" ]; then
      echo "  PASS  $f"
    else
      echo "  FAIL  $f"
      echo "        $result"
      failed=1
    fi
  done
}

run_ios_tests() {
  # Always the same simulator, so only one of them takes up disk space.
  sim="iPhone 16"
  xcrun simctl list devices available | grep -q "    $sim (" || \
    sim=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')
  [ -n "$sim" ] || { echo "  FAIL  no iPhone simulator installed"; failed=1; return; }
  (cd ios && xcodegen --quiet)
  log=$(mktemp)
  if xcodebuild test -project ios/Fridge.xcodeproj -scheme Fridge \
       -destination "platform=iOS Simulator,name=$sim" \
       -derivedDataPath ios/build/dd-sim CODE_SIGNING_ALLOWED=NO >"$log" 2>&1; then
    echo "  PASS  iOS unit tests ($(grep -oE 'Executed [0-9]+ tests?' "$log" | tail -1), $sim)"
  else
    echo "  FAIL  iOS unit tests"
    grep -E 'error:|failed \(' "$log" | head -20 | sed 's/^/        /'
    failed=1
  fi
  rm -f "$log"
}

if [ "$what" = all ] || [ "$what" = fn ]; then
  echo "Edge Function type-check"
  run_fn_checks
fi
if [ "$what" = all ] || [ "$what" = db ]; then
  echo "Database tests"
  run_db_tests
fi
if [ "$what" = all ] || [ "$what" = ios ]; then
  echo "iOS tests"
  run_ios_tests
fi

[ $failed -eq 0 ] && echo "All tests passed." || echo "Some tests failed."
exit $failed
