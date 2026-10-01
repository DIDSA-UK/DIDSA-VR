extends SceneTree
## Full-scene test for the REDESIGNED tablet (scripts/ui/wrist_tablet_v2.gd, enabled with
## main.use_new_tablet): main.tscn with NO backend, a simulated right laser. Covers opening
## by shooting the wrist icon, the category grid and tool rail, the one-active-tool rule and
## its hand badge (also with the tablet closed), the header switch, status line, the
## contextual side panel (mates list / model files / undo history) reached by a real laser
## aimed at the angled panel, Undo/Redo and the Undo long-press, Scale / Navigate / Settings
## pages, and that the laser claims ui_hover on both panels and lets go on close.
## Run: "$GODOT" --headless --path . --script res://tests/tablet_v2.gd  (see tests/README.md)

var main
var tab
var l: XRController3D
var r: XRController3D
var origin: XROrigin3D

func find_in(vp: Node, pred: Callable) -> Button:
	var stack: Array = [vp]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack.append_array(n.get_children())
	return null

func find_button(pred: Callable) -> Button:
	return find_in(tab._viewport, pred)

func click_now() -> void:
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame

func aim_and_click(b: Button) -> void:
	var c: Vector2 = b.global_position + b.size * 0.5
	var lx: float = (c.x / tab.viewport_size.x - 0.5) * tab.panel_size.x
	var ly: float = (0.5 - c.y / tab.viewport_size.y) * tab.panel_size.y
	r.position = Vector3(l.position.x + tab.mount_position.x + lx, 1.5, l.position.z + tab.mount_position.z - ly)
	r.rotation_degrees = Vector3(-90, 0, 0)
	for i in 3:
		await process_frame
	await click_now()

func aim_side_and_click(b: Button) -> void:
	# The side panel is tilted: place the controller along its normal and look straight at the point.
	var c: Vector2 = b.global_position + b.size * 0.5
	var px: Vector2 = Vector2(tab._side_viewport.size)
	var lx: float = (c.x / px.x - 0.5) * tab.side_width
	var ly: float = (0.5 - c.y / px.y) * tab.panel_size.y
	var xf: Transform3D = tab._side_quad.global_transform
	var p: Vector3 = xf * Vector3(lx, ly, 0.0)
	var n: Vector3 = xf.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * 0.4)
	for i in 3:
		await process_frame
	await click_now()

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.use_new_tablet = true
	root.add_child(main)
	await process_frame
	origin = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	l.position = Vector3(0, 1.0, 0)
	cam.position = Vector3(0, 1.6, 0.07); cam.rotation_degrees.x = -90
	r.rotation_degrees.x = -90
	tab = l.get_node("WristTablet")
	var th = main._two_hand
	for i in 4:
		await process_frame
	print("SMOKE the new tablet is what main built: ", tab.get_script().resource_path.ends_with("wrist_tablet_v2.gd"))

	# --- closed by default, opens only by shooting the wrist icon
	r.position = Vector3(1.0, 1.5, 1.0)
	for i in 5:
		await process_frame
	print("SMOKE staring at the wrist never opens it: ", not tab._open and not tab.visible and tab._target.visible)
	r.position = Vector3(l.position.x + 0.15, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await process_frame
	await click_now()
	print("SMOKE a trigger pull 15 cm off the icon doesn't open it: ", not tab._open)
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await process_frame
	print("SMOKE aiming at the icon: it swells and the laser is claimed: ", tab._target_hover and r.get_meta("ui_hover") == true)
	await click_now()
	print("SMOKE shooting the icon opens the tablet and hides the icon: ", tab._open and tab.visible and not tab._target.visible)
	var modes_before = [th.enabled, origin.enabled, l.parts_enabled]
	await click_now()
	print("SMOKE an immediate second pull is ignored (settle window): ", modes_before == [th.enabled, origin.enabled, l.parts_enabled] and not tab.surface.pressed)
	await create_timer(0.5).timeout

	# --- layout: 4 categories, one row; View selected with its first tool
	var ui = tab.ui
	print("SMOKE four categories sit in ONE row (no empty slots drawn): ", ui._cat_grid.get_child_count() == 4 and ui._cat_grid.columns == 4 and tab.registry.category_rows() == 1)
	print("SMOKE View > Navigate is showing first: ", ui.selected_category_id == "view" and ui.selected_tool_id == "navigate")
	print("SMOKE the tablet is 0.40 x 0.26 m at the same text density as before: ", tab.panel_size == Vector2(0.40, 0.26) and absf(tab.viewport_size.x / tab.panel_size.x - 2667.0) < 2.0)
	print("SMOKE no side panel for a tool with no list: ", not tab._side_open and not tab._side_pivot.visible)

	# --- laser claims the tablet
	await aim_and_click(find_button(func(b): return b.text == "Scale"))
	print("SMOKE aiming at a tablet button claims the laser (ui_hover) and shortens it: ", r.get_meta("ui_hover") == true and float(r.get_meta("ui_hit_distance")) > 0.3 and float(r.get_meta("ui_hit_distance")) < 0.7)
	print("SMOKE the Scale rail button selected Scale: ", ui.selected_tool_id == "scale")
	await aim_and_click(find_button(func(b): return b.text == "2:1"))
	print("SMOKE 2:1 -> ", th.scale_text(), " | ", th.scale_text().contains("2"))
	await aim_and_click(find_button(func(b): return b.text == "Home"))
	print("SMOKE Home on a tablet with nothing loaded does nothing bad and the tablet stays open: ", tab._open and ui.selected_tool_id == "scale")

	# --- Navigate toggles
	await aim_and_click(find_button(func(b): return b.text == "Navigate"))
	await aim_and_click(find_button(func(b): return b.text.begins_with("User movement")))
	print("SMOKE Navigate > User movement toggles locomotion off: ", origin.enabled == false)
	await aim_and_click(find_button(func(b): return b.text.begins_with("User movement")))
	print("SMOKE ...and back on: ", origin.enabled == true)

	# --- one active tool at a time
	await aim_and_click(find_button(func(b): return b.text == "Assembly"))
	print("SMOKE switching category shows a tool but switches NO mode tool on: ", ui.selected_category_id == "assembly" and tab.manager.active_id == "" and not r.mates_tool_active)
	await aim_and_click(find_button(func(b): return b.text == "Mates"))
	print("SMOKE tapping Mates on the rail turns the Mates tool on (both hands + tool): ", tab.manager.active_id == "mates" and l.mates_tool_active and r.mates_tool_active and main._mates_tool.active)
	print("SMOKE the tool header shows 'Tool: ON': ", find_button(func(b): return b.text == "Tool: ON") != null)
	print("SMOKE the right hand shows the badge for Mates: ", tab.badge.visible and tab.badge.shown_tool_id() == "mates" and tab.badge._label.text == "Mates")
	print("SMOKE the Mates list opens the side panel (angled, beside the tablet): ", tab._side_open and tab._side_pivot.visible and tab.side_ui._title.text == "Mates")
	print("SMOKE the side panel tilts up toward you (not flat with the tablet): ", absf(tab._side_pivot.rotation_degrees.y) > 1.0 and absf(tab._side_pivot.rotation_degrees.x) > 1.0)
	print("SMOKE the status bar shows the Mates tool's own status: ", ui.status_text().contains("Pick a face"))
	await aim_and_click(find_button(func(b): return b.text == "Measure"))
	print("SMOKE tapping Measure turns Measure ON and Mates OFF: ", tab.manager.active_id == "measure" and r.measure_tool_active and not r.mates_tool_active and not main._mates_tool.active and main._measure_tool.active)
	print("SMOKE ...only one mode tool is ever on: ", [r.mates_tool_active, r.measure_tool_active, r.hide_tool_active, main._section_tool.active].count(true) == 1)
	await aim_and_click(find_button(func(b): return b.text == "Colours"))
	print("SMOKE viewing a page tool (Colours) leaves Measure on: ", tab.manager.active_id == "measure" and ui.selected_tool_id == "colours")
	print("SMOKE ...and Colours' status line reports the selection: ", ui.status_text().contains("Selected"))
	await aim_and_click(find_button(func(b): return b.text == "Sections"))
	print("SMOKE Sections is a mode tool too: it replaces Measure: ", tab.manager.active_id == "sections" and main._section_tool.active and not r.measure_tool_active)

	# --- close with a tool active: the tool and its badge survive
	var close_btn: Button = find_button(func(b): return b.theme_type_variation == &"ButtonDanger" and b.icon != null)
	await aim_and_click(close_btn)
	print("SMOKE the X closes (stows) the tablet: ", not tab._open and not tab.visible and tab._target.visible)
	print("SMOKE closing drops the laser claim (a closed tablet can't hold the trigger): ", r.get_meta("ui_hover") == false)
	print("SMOKE closing does NOT turn the active tool off, and the badge stays: ", tab.manager.active_id == "sections" and main._section_tool.active and tab.badge.visible)
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await process_frame
	await click_now()
	await create_timer(0.5).timeout
	print("SMOKE shooting the icon reopens it, still on Assembly > Sections: ", tab._open and ui.selected_tool_id == "sections")
	await aim_and_click(find_button(func(b): return b.text == "Sections"))
	print("SMOKE tapping the selected, active tool turns it OFF: ", tab.manager.active_id == "" and not main._section_tool.active and not tab.badge.visible)
	await aim_and_click(find_button(func(b): return b.text == "View"))
	await aim_and_click(find_button(func(b): return b.text == "Shoot hide"))
	print("SMOKE View > Shoot hide is a mode tool in the View category: ", tab.manager.active_id == "shoot_hide" and l.hide_tool_active and r.hide_tool_active)
	await aim_and_click(find_button(func(b): return b.text == "Assembly"))
	await aim_and_click(find_button(func(b): return b.text == "Mates"))
	print("SMOKE Mates replaces Shoot hide across categories: ", tab.manager.active_id == "mates" and not r.hide_tool_active and r.mates_tool_active)
	await aim_and_click(find_button(func(b): return b.text == "Mates"))
	print("SMOKE ...and tapping it again switches everything off: ", tab.manager.active_id == "" and not r.mates_tool_active and not tab.badge.visible)

	# --- help card
	await aim_and_click(find_button(func(b): return b.icon != null and b.custom_minimum_size == Vector2(52, 52)))
	print("SMOKE the ? button opens a help card for the tool: ", ui.help_open and ui._help_card.visible)

	# --- Files: list in the side panel, reached by aiming the laser at the angled panel
	var scene := Node3D.new()
	var mi := MeshInstance3D.new(); mi.mesh = BoxMesh.new(); mi.name = "Box"; scene.add_child(mi)
	var gd := GLTFDocument.new(); var gs := GLTFState.new()
	gd.append_from_scene(scene, gs)
	DirAccess.make_dir_recursive_absolute("user://models")
	gd.write_to_filesystem(gs, "user://models/v2_test.glb")
	await aim_and_click(find_button(func(b): return b.text == "Files"))
	for i in 3:
		await process_frame
	print("SMOKE Files shows the model list in the side panel: ", tab._side_open and tab.side_ui._title.text == "Models" and tab.side_ui.row_count() >= 1)
	var open_btn: Button = find_in(tab._side_viewport, func(b): return b.text == "Open")
	print("SMOKE the side panel has an Open button per file: ", open_btn != null)
	await aim_side_and_click(open_btn)
	print("SMOKE a laser aimed at the ANGLED side panel presses its button (loads the model): ", main._part_count >= 1)
	print("SMOKE the side panel claims the laser too: ", r.get_meta("ui_hover") == true)

	# --- Undo / Redo / History
	main.command_stack.clear()
	main.command_stack.push("test move", func() -> void: pass, func() -> void: pass)
	await process_frame
	await process_frame
	print("SMOKE Undo enables when there is something to undo: ", not ui._undo_button.disabled and ui._redo_button.disabled)
	await aim_and_click(ui._undo_button)
	print("SMOKE Undo undoes it and Redo enables: ", ui._undo_button.disabled and not ui._redo_button.disabled)
	ui._undo_button.button_down.emit()
	ui._undo_down_ms = Time.get_ticks_msec() - 800
	ui.tick(0.016)
	var stack_before: int = main.command_stack.redo_labels().size()
	ui._undo_button.button_up.emit()
	ui._undo_button.pressed.emit()
	await process_frame
	print("SMOKE a long press on Undo opens History and does NOT also undo: ", ui.history_open and tab._side_open and main.command_stack.redo_labels().size() == stack_before)
	print("SMOKE History lists what Redo would bring back: ", tab.side_ui._title.text == "History" and tab.side_ui.row_count() == 1)
	await aim_and_click(find_button(func(b): return b.text == "View"))
	print("SMOKE picking a category closes History: ", not ui.history_open)

	# --- Settings
	await aim_and_click(ui._settings_button)
	print("SMOKE Settings opens in the pane, rail hidden, no side panel: ", ui.settings_open and not ui._rail_scroll.visible and not tab._side_open)
	await aim_and_click(find_button(func(b): return b.text == "Strong"))
	print("SMOKE Settings > Steadiness Strong applies (whole-model and both hands): ", th.steadiness == 3)
	await aim_and_click(find_button(func(b): return b.text == "65%"))
	print("SMOKE Settings > Resolution 65% applies: ", is_equal_approx(main.get_viewport().scaling_3d_scale, 0.65))
	await aim_and_click(ui._settings_button)
	print("SMOKE the Settings button again returns to the tools: ", not ui.settings_open and ui._rail_scroll.visible)

	# --- stow: no stuck claim, panel no longer rendered
	tab.close_tablet()
	await process_frame
	await process_frame
	print("SMOKE a closed tablet isn't rendered (main and side viewports off): ", tab._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED and tab._side_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED)
	quit()
