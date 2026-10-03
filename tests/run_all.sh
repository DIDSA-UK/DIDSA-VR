#!/usr/bin/env bash
# Runs the headless tests and stops at the first script/parse error.
# Usage (from the project root):  GODOT=/path/to/godot tests/run_all.sh
# Needs no GPU, headset or backend. gpu_timing.gd is separate (needs a GPU + window).
set -u
GODOT="${GODOT:-godot}"
fail=0

echo "== parse check"
for f in scripts/*.gd scripts/motion/*.gd scripts/ui/*.gd; do
  out=$("$GODOT" --headless --path . --check-only --script "res://$f" 2>&1 | grep -E "SCRIPT ERROR|Parse Error")
  if [ -n "$out" ]; then echo "FAIL $f"; echo "$out"; fail=1; fi
done

for t in steadiness_filter sensitivity two_hand_rotation grab_and_scale precise_picking undo_redo popup_keyboard tools_tab tablet_scene mesh_identity mates_tool measure_tool colour_tool section_tool section_tab laser_and_left_hand assembly_tree_window calculator_window windows_tab browser_window bug_round features_round mates_motion motion_vectors local_retraction full_keyboard windows_round laser_surface tablet_registry tool_manager side_panel_ui ui_feedback ui_sounds ui_themes passthrough panel_distance_grab tablet keyboard_handle face_highlight topology_pick design_table_logic design_table_scene sketch_session design_table_editing design_table_tree design_table_mates design_table_save mate_health new_document; do
  echo "== $t"
  out=$(timeout 300 "$GODOT" --headless --path . --script "res://tests/$t.gd" 2>&1)
  echo "$out" | grep -E "SMOKE" | cut -c1-200
  if echo "$out" | grep -qE "SCRIPT ERROR|Parse Error"; then
    echo "FAIL $t"; echo "$out" | grep -E -A2 "SCRIPT ERROR|Parse Error"; fail=1
  fi
done

[ "$fail" = 0 ] && echo "ALL RAN WITHOUT SCRIPT ERRORS (now eyeball the SMOKE values against tests/README.md)" || echo "SOME FAILED"
exit "$fail"
