#!/usr/bin/env bash
# CI entry point: runs the headless suite, then checks every SMOKE line against tests/expected_false.txt.
# run_all.sh stays the local entry point (it only fails on script/parse errors); this also fails on a `false` assertion.
# Usage (from the project root):  GODOT=/path/to/godot tests/ci.sh      Output: run.log (override with RUN_LOG=...)
set -u
cd "$(dirname "$0")/.."
LOG="${RUN_LOG:-run.log}"
set -o pipefail
# The log keeps whole lines (check_smoke.py reads every character); only the console copy is cut to 200 characters.
tests/run_all.sh 2>&1 | tee "$LOG" | cut -c1-200
suite=${PIPESTATUS[0]}
python3 -I tests/check_smoke.py "$LOG" --baseline tests/expected_false.txt --no-smoke tests/no_smoke.txt
check=$?
echo "run_all exit $suite, check_smoke exit $check"
[ "$suite" = 0 ] && [ "$check" = 0 ]
