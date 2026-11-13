#!/usr/bin/env bash
# Runs the headless tests and stops at the first script/parse error.
# Usage (from the project root):  GODOT=/path/to/godot tests/run_all.sh
# Needs no GPU, headset or backend. gpu_timing.gd is separate (needs a GPU + window).
set -u
GODOT="${GODOT:-godot}"
fail=0
# Tests that change settings (a resized table is remembered, the view mode, the theme...) write to their own file, never the real one, and each
# run starts from defaults. (Running a single test by hand without this variable uses the real settings file.)
export DIDSA_SETTINGS_PATH="user://settings_test.cfg"
export DIDSA_RECENT_PATH="user://recent_test.cfg" # the landing's last-file memory: a test run never touches the real one
export DIDSA_SERVERS_PATH="user://servers_test.cfg" # the servers list: a test run never reads or writes the real one
export DIDSA_NO_LANDING=1 # main.gd starts without the landing (the old start-up behaviour); tests/landing.gd turns it on for itself
reset_settings() { rm -f "$HOME/.local/share/godot/app_userdata/DIDSA Design Tools VR/settings_test.cfg" "$HOME/Library/Application Support/Godot/app_userdata/DIDSA Design Tools VR/settings_test.cfg" "$HOME/.local/share/godot/app_userdata/DIDSA VR/settings_test.cfg" "$HOME/Library/Application Support/Godot/app_userdata/DIDSA VR/settings_test.cfg" "$HOME/.local/share/godot/app_userdata/DIDSA VR Spike/settings_test.cfg" "$HOME/Library/Application Support/Godot/app_userdata/DIDSA VR Spike/settings_test.cfg" 2>/dev/null; } # "DIDSA VR Spike" and "DIDSA VR" are the pre-rename folders
reset_settings

echo "== parse check"
for f in scripts/*.gd scripts/motion/*.gd scripts/ui/*.gd scripts/appearance/*.gd scripts/landing/*.gd; do
  out=$("$GODOT" --headless --path . --check-only --script "res://$f" 2>&1 | grep -E "SCRIPT ERROR|Parse Error")
  if [ -n "$out" ]; then echo "FAIL $f"; echo "$out"; fail=1; fi
done

for t in landing landing_unsaved graphics_overrides qr_reticle tips_reel servers server_probe pairing_payload pairing_flow qr_scanner scan_page android_config width_mate gear_mates limit_mates limit_mates_v8 drive_tool steadiness_filter sensitivity two_hand_rotation grab_and_scale carry_while_walking precise_picking undo_redo popup_keyboard tools_tab tablet_scene mesh_identity mates_tool measure_tool appearance_vectors appearance_tool appearance_page appearance_glb appearance_gun clip_look scene_vectors scenes_tool scenes_ui stress_appearance_scenes stress_moved_files section_tool section_tab laser_and_left_hand assembly_tree_window calculator_window windows_tab browser_window bug_round features_round mates_motion motion_vectors local_retraction full_keyboard windows_round laser_surface tablet_registry tool_manager tool_wheel_math tool_wheel measure_dimensions native_compose file_lookup_vectors moved_files side_panel_ui ui_feedback ui_sounds ui_themes passthrough panel_distance_grab table_laser_grab tablet keyboard_handle face_highlight topology_pick design_table_logic design_table_feature_tools design_table_gears design_table_props_panel design_table_new_sketch design_table_body_pick design_table_sketch_picks design_table_preview design_table_redo design_table_create_plane design_table_loft_sweep design_table_loft_guides design_table_helix design_table_spring design_table_body_features design_table_small_options design_table_plane_types sketch_methods design_table_trim_offset design_table_modify design_table_curves design_table_ellipse_reference design_table_scene sketch_session design_table_editing design_table_references design_table_references_more design_table_reference_robustness design_table_fix_references design_table_tree design_table_mates design_table_save mate_health new_document design_table_build_tree design_table_visibility design_table_visibility_drawer design_table_visibility_rest design_table_visibility_tree design_table_visibility_auto design_table_sketch_seed design_table_sketch_seed_revolve design_table_sketch_seed_more design_table_sketch_seed_targets design_table_tint design_table_visibility_glyphs view_modes work_loss table_handling sketch_clip room_clip room_manager room_interaction room_edit room_drop room_laser_placement room_walls room_handles nested_mates pattern_followers pattern_copy_pose pattern_follow_live mates_sandbox room_console room_minimise group_select keyboard_dock occurrence_tree_model occurrence_tree_actions mates_relax_fix project_save mates_preview_note mates_suggested_type room_preview table_preview project_folder empty_start mate_highlight sketch_sheet_front design_table_sketch_select design_table_selection_actions design_table_selection_drawer sketch_origin design_table_sketch_origin design_table_revolve_thin design_table_sketch_frame; do
  echo "== $t"
  reset_settings # every test starts from default settings (one test's remembered table size must not shape the next)
  out=$(timeout 300 "$GODOT" --headless --path . --script "res://tests/$t.gd" 2>&1)
  echo "$out" | grep -E "SMOKE" | cut -c1-200
  if echo "$out" | grep -qE "SCRIPT ERROR|Parse Error"; then
    echo "FAIL $t"; echo "$out" | grep -E -A2 "SCRIPT ERROR|Parse Error"; fail=1
  fi
done

[ "$fail" = 0 ] && echo "ALL RAN WITHOUT SCRIPT ERRORS (now eyeball the SMOKE values against tests/README.md)" || echo "SOME FAILED"
exit "$fail"
