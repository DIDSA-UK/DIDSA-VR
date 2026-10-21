#!/usr/bin/env bash
# Runs the real-backend e2e tests listed in tests/e2e_ci_list.txt against the backend named in ./secrets.cfg and checks
# their SMOKE lines (`SMOKE SKIPPED` counts as a failure here: it means the backend was not reached).
# Usage (from the project root, backend up, secrets.cfg written):  GODOT=/path/to/godot tests/ci_e2e.sh
# Output: logs/<test>.log per test and e2e.log (the combined, checked log).
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
LOG="${RUN_LOG:-e2e.log}"
export DIDSA_SETTINGS_PATH="user://settings_test.cfg"
export DIDSA_RECENT_PATH="user://recent_test.cfg"
export DIDSA_SERVERS_PATH="user://servers_test.cfg" # the servers list: a test run never reads or writes the real one
export DIDSA_NO_LANDING=1 # main.gd starts without the landing: the old start-up import (the e2e tests rely on it)
mkdir -p logs
: > "$LOG"
fail=0
while read -r t; do
  case "$t" in ''|\#*) continue;; esac
  echo "== $t" | tee -a "$LOG"
  timeout 120 "$GODOT" --headless --path . --script "res://tests/$t.gd" > "logs/$t.log" 2>&1
  rc=$?
  grep -E "SMOKE" "logs/$t.log" | cut -c1-200 | tee -a "$LOG"
  if [ "$rc" = 124 ]; then echo "FAIL $t (timed out after 120 s)" | tee -a "$LOG"; fail=1; fi
  if grep -qE "SCRIPT ERROR|Parse Error" "logs/$t.log"; then
    echo "FAIL $t" | tee -a "$LOG"; grep -E -A2 "SCRIPT ERROR|Parse Error" "logs/$t.log" | tee -a "$LOG"; fail=1
  fi
done < tests/e2e_ci_list.txt
python3 -I tests/check_smoke.py "$LOG" --baseline tests/expected_false_e2e.txt --fail-on-skipped
check=$?
[ "$fail" = 0 ] && [ "$check" = 0 ]
