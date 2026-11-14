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

# The project store (DIDSA-CAD project-store/, S3: server projects) is a second service. tests/e2e_cloud_store.gd needs DIDSA_STORE_URL and DIDSA_STORE_KEY; when they are not
# set, a throwaway store is started from DIDSA-CAD's checkout (CAD_DIR, default ../DIDSA-CAD; STORE_PYTHON must have its requirements.txt installed), on its own port with a
# temp root and a throwaway key, one worker, and stopped at the end. With no checkout the test prints SMOKE SKIPPED, which fails this script like a missing backend does.
STORE_PID=""
STORE_ROOT=""
cleanup_store() {
  [ -n "$STORE_PID" ] && kill "$STORE_PID" 2>/dev/null
  [ -n "$STORE_ROOT" ] && rm -rf "$STORE_ROOT"
}
trap cleanup_store EXIT
if [ -z "${DIDSA_STORE_URL:-}" ]; then
  CAD_DIR="${CAD_DIR:-$(cd .. && pwd)/DIDSA-CAD}"
  if [ -d "$CAD_DIR/project-store/app" ]; then
    STORE_PORT="${STORE_PORT:-8200}"
    STORE_KEY_VALUE="ci-store-throwaway-key"
    STORE_ROOT="$(mktemp -d)"
    (cd "$CAD_DIR/project-store" && exec env PROJECT_STORE_API_KEY="$STORE_KEY_VALUE" PROJECT_STORE_ROOT="$STORE_ROOT" \
      "${STORE_PYTHON:-python3}" -m uvicorn app.main:app --host 127.0.0.1 --port "$STORE_PORT") > logs/project-store.log 2>&1 &
    STORE_PID=$! # (the subshell execs into the server, so this is the server's own pid)
    for i in $(seq 1 30); do
      if curl -sf -o /dev/null -H "X-API-Key: $STORE_KEY_VALUE" "http://127.0.0.1:$STORE_PORT/health"; then echo "project store up after ${i}s" | tee -a "$LOG"; break; fi
      sleep 1
      [ "$i" = 30 ] && echo "project store did not come up (logs/project-store.log); e2e_cloud_store will be skipped" | tee -a "$LOG"
    done
    export DIDSA_STORE_URL="http://127.0.0.1:$STORE_PORT" DIDSA_STORE_KEY="$STORE_KEY_VALUE"
  fi
fi
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
