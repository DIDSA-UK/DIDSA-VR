#!/usr/bin/env bash
# The assert-based render tests, which need a real (software) GL context: run under Xvfb + Mesa, not --headless, because
# the dummy renderer cannot execute shaders (shaders/clip_common.gdshaderinc is only really exercised here).
# Output goes through the same SMOKE checker as the headless suite (no false is expected in any of these).
# Usage (from the project root):  GODOT=/path/to/godot tests/ci_render.sh      Output: render.log (override with RUN_LOG=...)
# The picture-only render tests (sketch_clip_picture, *_render writing PNGs for a human) are not run here.
set -u
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
LOG="${RUN_LOG:-render.log}"
export DIDSA_SETTINGS_PATH="user://settings_test.cfg"
export DIDSA_RECENT_PATH="user://recent_test.cfg"
export DIDSA_SERVERS_PATH="user://servers_test.cfg" # the servers list: a test run never reads or writes the real one
export DIDSA_NO_LANDING=1 # main.gd starts without the landing: the old start-up import (the e2e tests rely on it)
: > "$LOG"
fail=0
for t in sketch_clip_render section_render section_render_transformed highlight_clip_render room_clip_render room_render room_walls_render room_preview_render wheel_hint_render appearance_render appearance_clip_render landing_render empty_start_render thumbnail_render session_vignette_render; do
  echo "== $t" | tee -a "$LOG"
  out=$(timeout 300 xvfb-run -a "$GODOT" --path . --script "res://tests/$t.gd" 2>&1)
  echo "$out" | grep -E "SMOKE" | cut -c1-200 | tee -a "$LOG"
  if echo "$out" | grep -qE "SCRIPT ERROR|Parse Error"; then
    echo "FAIL $t" | tee -a "$LOG"; echo "$out" | grep -E -A2 "SCRIPT ERROR|Parse Error" | tee -a "$LOG"; fail=1
  fi
done
python3 -I tests/check_smoke.py "$LOG"
check=$?
[ "$fail" = 0 ] && [ "$check" = 0 ]
