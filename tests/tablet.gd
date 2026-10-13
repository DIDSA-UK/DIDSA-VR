extends SceneTree
## Full-scene test for the wrist tablet (scripts/ui/wrist_tablet.gd): main.tscn with NO backend, a simulated right laser. Covers opening
## by shooting the wrist icon, the home tiles, hubs and tool strip, the one-active-tool rule and
## its hand badge (also with the tablet closed), the header switch, status line, the
## contextual side panel (mates list / model files / undo history) reached by a real laser
## aimed at the angled panel, Undo/Redo and the Undo long-press, Scale / Navigate / Settings
## pages, and that the laser claims ui_hover on both panels and lets go on close.
## Run: "$GODOT" --headless --path . --script res://tests/tablet.gd  (see tests/README.md)

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

func aim_only(b: Button) -> void:
	# The tablet is tilted on the wrist: place the controller along its normal and look straight at the point.
	var c: Vector2 = b.global_position + b.size * 0.5
	var lx: float = (c.x / tab.viewport_size.x - 0.5) * tab.panel_size.x
	var ly: float = (0.5 - c.y / tab.viewport_size.y) * tab.panel_size.y
	var xf: Transform3D = tab._quad.global_transform
	var p: Vector3 = xf * Vector3(lx, ly, 0.0)
	var n: Vector3 = xf.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * 0.4)
	for i in 3:
		await process_frame

func click_text(pred: Callable) -> void:
	# Re-finds the button after the aim settles: a page can reflow under the laser (the Settings
	# page's live readout changes height), so aim until the pointer really is on the button.
	for i in 4:
		var b := find_button(pred)
		tab.ui.pages_scroll.ensure_control_visible(b) # as the right thumbstick would scroll it into view
		await process_frame
		await aim_only(b)
		if b.get_global_rect().has_point(tab.surface.pointer_px):
			break
	await click_now()

func aim_and_click(b: Button) -> void:
	await aim_only(b)
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

func go_home_by_laser() -> void:
	# Back is one step up: from a tool inside a hub it lands on the hub, then Home.
	for i in 3:
		if tab.ui.selected_category_id == "":
			return
		await aim_and_click(tab.ui._back_button)

func open_category(category_id: String) -> void:
	await go_home_by_laser()
	await aim_and_click(tab.ui.home_tile(category_id))

func open_tool(category_id: String, tool_id: String) -> void:
	# Home tile -> (hub tile | strip chip), the way a person gets there.
	await open_category(category_id)
	var cat = tab.registry.category(category_id)
	if cat.hub:
		await aim_and_click(tab.ui.hub_tile(tool_id))
	elif tab.ui.selected_tool_id != tool_id:
		await aim_and_click(tab.ui.strip_button(tool_id))

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
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
	print("SMOKE the tablet is what main built: ", tab.get_script().resource_path.ends_with("wrist_tablet.gd"))

	# --- closed by default, opens only by shooting the wrist icon
	r.position = Vector3(1.0, 1.5, 1.0)
	for i in 5:
		await process_frame
	print("SMOKE the wrist watch sits back from the hand by about half its own diameter (0.031 m beyond the old spot): ", absf(tab.target_position.z - (0.122 + 0.031)) < 0.002)
	print("SMOKE staring at the wrist never opens it: ", not tab._open and not tab.visible and tab._target.visible)
	r.position = Vector3(l.position.x + 0.15, 1.5, l.position.z + tab.target_position.z)
	r.rotation_degrees = Vector3(-90, 0, 0) # straight down at the wrist icon
	for i in 3:
		await process_frame
	await click_now()
	print("SMOKE a trigger pull 15 cm off the icon doesn't open it: ", not tab._open)
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	r.rotation_degrees = Vector3(-90, 0, 0) # straight down at the wrist icon
	for i in 3:
		await process_frame
	print("SMOKE aiming at the icon: it swells and the laser is claimed: ", tab._target_hover and r.get_meta("ui_hover") == true)
	await click_now()
	print("SMOKE shooting the icon opens the tablet and hides the icon: ", tab._open and tab.visible and not tab._target.visible)
	var tilt_xf: Transform3D = tab._quad.global_transform
	var tilt_deg: float = rad_to_deg(acos(clampf(tilt_xf.basis.z.normalized().dot(Vector3.UP), -1.0, 1.0)))
	print("SMOKE the tablet is tipped ~30 degrees toward you (neutral wrist), not flat: ", absf(tilt_deg - 30.0) < 0.5, " (", tilt_deg, ")")
	print("SMOKE ...and its top edge is away from you (it faces up and back at the eye, not away): ", tilt_xf.basis.z.dot(Vector3(0, 0, 1)) > 0.45)
	var modes_before = [th.enabled, origin.enabled, l.parts_enabled]
	await click_now()
	print("SMOKE an immediate second pull is ignored (settle window): ", modes_before == [th.enabled, origin.enabled, l.parts_enabled] and not tab.surface.pressed)
	await create_timer(0.5).timeout

	# --- layout: the home screen, ten tiles in 5 x 2
	var ui = tab.ui
	print("SMOKE ten home tiles sit in a 5 x 2 grid: ", ui._home_grid.get_child_count() == 10 and ui._home_grid.columns == 5 and tab.registry.category_rows() == 2)
	print("SMOKE the tablet opens on the home screen, no tool selected: ", ui.selected_category_id == "" and ui._home_view.visible and not ui._tool_view.visible and not ui._back_button.visible)
	print("SMOKE the tiles are the categories, in order, with no windows page: ", tab.registry.categories().map(func(c): return c.id) == ["design", "assemble", "view", "inspect", "files", "tree", "calculator", "images", "browser", "settings"])
	print("SMOKE the tablet is 0.40 x 0.26 m at the same text density as before: ", tab.panel_size == Vector2(0.40, 0.26) and absf(tab.viewport_size.x / tab.panel_size.x - 2667.0) < 2.0)
	print("SMOKE no side panel for a tool with no list: ", not tab._side_open and not tab._side_pivot.visible)

	# --- laser claims the tablet
	await open_tool("view", "scale")
	print("SMOKE View is a hub: its tiles show first, Scale opens from its tile: ", ui.selected_category_id == "view" and not ui.hub_open and ui._back_button.visible)
	print("SMOKE aiming at a tablet button claims the laser (ui_hover) and shortens it: ", r.get_meta("ui_hover") == true and float(r.get_meta("ui_hit_distance")) > 0.3 and float(r.get_meta("ui_hit_distance")) < 0.7)
	print("SMOKE the Scale tile selected Scale: ", ui.selected_tool_id == "scale")
	await aim_and_click(find_button(func(b): return b.text == "2:1"))
	print("SMOKE 2:1 -> ", th.scale_text(), " | ", th.scale_text().contains("2"))
	await aim_and_click(find_button(func(b): return b.text == "Home"))
	print("SMOKE Home on a tablet with nothing loaded does nothing bad and the tablet stays open: ", tab._open and ui.selected_tool_id == "scale")

	# --- Navigate toggles
	await open_tool("view", "navigate")
	await aim_and_click(find_button(func(b): return b.text.begins_with("User movement")))
	print("SMOKE Navigate > User movement toggles locomotion off: ", origin.enabled == false)
	await aim_and_click(find_button(func(b): return b.text.begins_with("User movement")))
	print("SMOKE ...and back on: ", origin.enabled == true)

	# --- one active tool at a time
	await open_category("assemble")
	print("SMOKE opening a category shows a tool but switches NO mode tool on: ", ui.selected_category_id == "assemble" and ui.selected_tool_id == "mates" and tab.manager.active_id == "" and not r.mates_tool_active)
	print("SMOKE a category with two tools (Mates, Rooms) shows the chip strip: ", ui._strip_scroll.visible)
	ui.select_tool("rooms")
	await process_frame
	await process_frame
	print("SMOKE Assemble > Rooms builds its page: the table part's world button and the Delete-selected button: ", find_button(func(b): return b.text.begins_with("Table part, in the world") or b.text.begins_with("Put a part")) != null and find_button(func(b): return b.text.begins_with("Delete")) != null)
	ui.select_tool("mates")
	await process_frame
	await process_frame
	await aim_and_click(find_button(func(b): return b.text == "Tool: off"))
	print("SMOKE the header switch turns the Mates tool on (both hands + tool): ", tab.manager.active_id == "mates" and l.mates_tool_active and r.mates_tool_active and main._mates_tool.active)
	print("SMOKE the tool header shows 'Tool: ON': ", find_button(func(b): return b.text == "Tool: ON") != null)
	print("SMOKE the right hand shows the badge for Mates: ", tab.badge.visible and tab.badge.shown_tool_id() == "mates" and tab.badge._label.text == "Mates")
	print("SMOKE the Mates list opens the side panel (angled, beside the tablet): ", tab._side_open and tab._side_pivot.visible and tab.side_ui._title.text == "Mates")
	var tq: Transform3D = tab._quad.global_transform
	var sq: Transform3D = tab._side_quad.global_transform
	var t_right: Vector3 = tq.basis.y.normalized() # the tablet's right edge runs along its local up axis
	var s_left: Vector3 = tab._side_pivot.global_transform.basis.y.normalized() # the side panel's hinge (left) edge
	print("SMOKE the side panel's left edge is parallel to the tablet's right edge: ", t_right.dot(s_left) > 0.9999)
	var s_right: Vector3 = (sq.basis.y).normalized()
	print("SMOKE ...and its right edge is turned about 5 degrees toward you (yaw -5, no pitch, so the edges stay parallel): ", is_equal_approx(tab._side_pivot.rotation_degrees.y, -5.0) and is_equal_approx(tab._side_pivot.rotation_degrees.x, 0.0) and s_right.dot(t_right) > 0.9999)
	var side_x: Vector3 = sq.basis.x.normalized()
	var toward_user: float = rad_to_deg(asin(clampf(side_x.dot(tq.basis.z.normalized()), -1.0, 1.0)))
	print("SMOKE ...the outward turn measured against the tablet face is ~5 degrees: ", absf(toward_user - 5.0) < 0.5, " (", toward_user, ")")
	print("SMOKE the status bar shows the Mates tool's own status: ", ui.status_text().contains("Pick a face"))
	await open_tool("inspect", "measure")
	print("SMOKE Inspect has a two-chip strip (Measure, Sections): ", ui._strip_scroll.visible and ui._strip_buttons.size() == 2)
	print("SMOKE going Home and into another category leaves Mates on, and the top bar says so: ", tab.manager.active_id == "mates" and ui.chip_texts().any(func(t): return t.contains("Mates on")))
	await aim_and_click(find_button(func(b): return b.text == "Tool: off"))
	print("SMOKE switching Measure on turns Measure ON and Mates OFF: ", tab.manager.active_id == "measure" and r.measure_tool_active and not r.mates_tool_active and not main._mates_tool.active and main._measure_tool.active)
	print("SMOKE ...only one mode tool is ever on: ", [r.mates_tool_active, r.measure_tool_active, r.hide_tool_active, main._section_tool.active].count(true) == 1)
	await open_tool("view", "colours")
	print("SMOKE viewing a page tool (Colours) leaves Measure on: ", tab.manager.active_id == "measure" and ui.selected_tool_id == "colours")
	print("SMOKE ...and Colours' status line reports the selection: ", ui.status_text().contains("Selected"))
	await open_tool("inspect", "sections")
	print("SMOKE Sections is a mode tool too: it replaces Measure: ", tab.manager.active_id == "sections" and main._section_tool.active and not r.measure_tool_active)

	# --- close with a tool active: the tool and its badge survive
	var close_btn: Button = find_button(func(b): return b.theme_type_variation == &"ButtonDanger" and b.icon != null)
	await aim_and_click(close_btn)
	print("SMOKE the X closes the tablet at once (logically): nothing hovered or rendered, the wrist icon is back: ", not tab._open and tab._target.visible and tab._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED and not tab.surface.hovering)
	print("SMOKE ...with motion on the panel is still shrinking away a moment later: ", tab.visible)
	await create_timer(0.4).timeout
	print("SMOKE ...and then hidden (the stow animation finished): ", not tab.visible and tab.scale.is_equal_approx(Vector3.ONE))
	print("SMOKE closing drops the laser claim (a closed tablet can't hold the trigger): ", r.get_meta("ui_hover") == false)
	print("SMOKE closing does NOT turn the active tool off, and the badge stays: ", tab.manager.active_id == "sections" and main._section_tool.active and tab.badge.visible)
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	r.rotation_degrees = Vector3(-90, 0, 0) # straight down at the wrist icon
	for i in 3:
		await process_frame
	await click_now()
	await create_timer(0.5).timeout
	print("SMOKE shooting the icon reopens it, still on Inspect > Sections: ", tab._open and ui.selected_tool_id == "sections")
	await aim_and_click(ui.strip_button("sections"))
	print("SMOKE tapping the selected, active chip turns it OFF: ", tab.manager.active_id == "" and not main._section_tool.active and not tab.badge.visible)
	await open_tool("view", "shoot_hide")
	print("SMOKE View > Shoot hide is a mode tool in the View category (its hub tile turns it on): ", tab.manager.active_id == "shoot_hide" and l.hide_tool_active and r.hide_tool_active)
	await open_category("assemble")
	await aim_and_click(find_button(func(b): return b.text == "Tool: off"))
	print("SMOKE Mates replaces Shoot hide across categories: ", tab.manager.active_id == "mates" and not r.hide_tool_active and r.mates_tool_active)
	await aim_and_click(find_button(func(b): return b.text == "Tool: ON"))
	print("SMOKE ...and the switch again turns everything off: ", tab.manager.active_id == "" and not r.mates_tool_active and not tab.badge.visible)

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
	await open_category("files")
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
	await aim_and_click(ui._back_button)
	print("SMOKE going Home closes History: ", not ui.history_open and ui.selected_category_id == "")

	# --- Settings
	await aim_and_click(ui._settings_button)
	print("SMOKE the gear opens the Settings hub, no side panel: ", ui.selected_category_id == "settings" and ui.hub_open and not tab._side_open and ui._settings_button.button_pressed)
	await aim_and_click(ui.hub_tile("set_movement"))
	await click_text(func(b): return b.text == "Strong")
	print("SMOKE Settings > Steadiness Strong applies (whole-model and both hands): ", th.steadiness == 3)
	await open_tool("settings", "set_display")
	await click_text(func(b): return b.text == "65%")
	print("SMOKE Settings > Resolution 65% applies: ", is_equal_approx(main.get_viewport().scaling_3d_scale, 0.65))
	var Fb = load("res://scripts/ui/ui_feedback.gd")
	var sound_was: bool = main.sound_enabled()
	await open_tool("settings", "set_comfort")
	print("SMOKE Settings > Comfort has a Sound toggle (default ON): ", find_button(func(b): return b.text == "Sound: ON") != null)
	ui.pages_scroll.ensure_control_visible(find_button(func(b): return b.text.begins_with("Sound:"))) # the Comfort section sits below the fold: scroll to it, as the right thumbstick would
	await process_frame
	await click_text(func(b): return b.text.begins_with("Sound:"))
	print("SMOKE tapping it turns sound off everywhere: ", main.sound_enabled() == false and Fb.sound_enabled == false and find_button(func(b): return b.text == "Sound: off") != null)
	await click_text(func(b): return b.text.begins_with("Sound:"))
	print("SMOKE the Settings readout has a fixed height, so the page doesn't reflow under the laser: ", tab.pages._info_label.custom_minimum_size.y >= 150.0 and tab.pages._info_label.clip_text)
	print("SMOKE ...and on again: ", main.sound_enabled() == true and Fb.sound_enabled == true)
	var vol_slider: HSlider = null
	for sl in ui.sliders:
		if sl.is_visible_in_tree() and absf(sl.value - main.sound_volume()) < 0.001 and sl.max_value == 1.0 and sl.step == 0.05:
			vol_slider = sl
	print("SMOKE Settings > Comfort has a Volume slider showing the current level: ", vol_slider != null)
	vol_slider.value = 0.3
	print("SMOKE moving it sets the volume (and the label follows): ", is_equal_approx(Fb.volume, 0.3) and is_equal_approx(main.sound_volume(), 0.3) and find_button(func(b): return true) != null and tab.pages._volume_label.text == "Volume: 30%")
	vol_slider.value = 0.7
	main.set_sound_enabled(sound_was)

	# --- Settings > Appearance: themes and shader effects, re-themed live and in place
	await open_tool("settings", "set_appearance")
	var Themes = load("res://scripts/ui/ui_themes.gd")
	var navy_bg: Color = Themes.preset("Navy").bg_panel
	var dark_bg: Color = Themes.preset("Dark").bg_panel
	print("SMOKE Settings > Appearance has a Theme choice (Navy / Simple / Dark) and a Shader effects toggle: ", find_button(func(b): return b.text == "Simple") != null and find_button(func(b): return b.text == "Dark") != null and find_button(func(b): return b.text.begins_with("Shader effects")) != null)
	var pane_before: float = tab.ui.pages_scroll.scroll_vertical
	var tool_before: String = tab.ui.selected_tool_id
	var kb_node = main._keyboard
	var calc = main._calculator_window
	await click_text(func(b): return b.text == "Dark")
	await process_frame
	await process_frame
	print("SMOKE picking Dark applies it everywhere (shared theme, saved choice): ", Themes.current == "Dark" and main.ui_theme() == "Dark" and Themes.live().bg_panel == dark_bg)
	print("SMOKE the open tablet re-themed itself in place (its panel is now the Dark colour): ", (tab.ui.theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).bg_color == dark_bg)
	print("SMOKE ...and the side panel too: ", (tab.side_ui.theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).bg_color == dark_bg)
	print("SMOKE ...without rebuilding anything: same tool, still on Settings, same scroll position: ", tab.ui.selected_tool_id == tool_before and tab.ui.selected_category_id == "settings" and absf(tab.ui.pages_scroll.scroll_vertical - pane_before) < 2.0)
	print("SMOKE a floating window and the keyboard that were closed pick up the theme too: ", (calc._ui_root.theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).bg_color == dark_bg and (kb_node._ui_root.theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).bg_color == dark_bg)
	print("SMOKE the window's resize brackets and handle follow the theme's accent: ", calc._corner_hot == Themes.live().accent)
	print("SMOKE the wrist watch and the hand rings take the theme too (accent ring, panel-coloured face): ", tab._watch_ring.albedo_color.is_equal_approx(Themes.live().accent.darkened(0.1)) and r._ring_material.albedo_color.is_equal_approx(Color(Themes.live().accent.r, Themes.live().accent.g, Themes.live().accent.b, r._ring_material.albedo_color.a)) and l._ring_face_material.albedo_color.r == Themes.live().bg_panel.r)
	await click_text(func(b): return b.text == "Simple")
	await process_frame
	await process_frame
	print("SMOKE Simple applies the same way (flat: thin outline): ", Themes.current == "Simple" and (tab.ui.theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).border_width_left == 1)
	print("SMOKE the shader effects overlays are showing on the tablet, side panel, window and keyboard: ", tab.ui._fx.visible and tab.side_ui._fx.visible and calc._fx.visible and kb_node._fx.visible)
	await click_text(func(b): return b.text.begins_with("Shader effects"))
	await process_frame
	await process_frame
	print("SMOKE switching Shader effects off hides every overlay at once: ", Themes.fx_enabled == false and main.fx_enabled() == false and not tab.ui._fx.visible and not tab.side_ui._fx.visible and not calc._fx.visible and not kb_node._fx.visible)
	print("SMOKE ...and the buttons lose their glow: ", (tab.ui.theme.get_stylebox("hover", "Button") as StyleBoxFlat).shadow_size == 0)
	await click_text(func(b): return b.text.begins_with("Shader effects"))
	await process_frame
	await process_frame
	print("SMOKE ...and on again brings them all back: ", Themes.fx_enabled and tab.ui._fx.visible and calc._fx.visible and (tab.ui.theme.get_stylebox("hover", "Button") as StyleBoxFlat).shadow_size > 0)
	await click_text(func(b): return b.text == "Navy")
	await process_frame
	await process_frame
	print("SMOKE back to Navy restores the original panel colour: ", (tab.ui.theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).bg_color == navy_bg)
	print("SMOKE the renderer is told to redraw after a theme change (not left showing the old look): ", tab._viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS or tab._activity_until_ms > Time.get_ticks_msec() - 2000)
	main.set_ui_theme("Navy")
	main.set_fx_enabled(true) # leave the saved settings as we found them
	await aim_and_click(ui._settings_button)
	print("SMOKE the gear again returns Home: ", ui.selected_category_id == "" and ui._home_view.visible and not ui._settings_button.button_pressed)

	# --- idle render gating: only re-render every frame while something is happening
	r.position = Vector3(2.0, 1.5, 2.0)
	await create_timer(1.5).timeout
	print("SMOKE an idle open tablet is not re-rendered every frame: ", tab._viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS)
	await aim_only(ui.home_tile("view"))
	print("SMOKE aiming the laser at it renders every frame again: ", tab._viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
	r.position = Vector3(2.0, 1.5, 2.0)
	await create_timer(1.5).timeout
	print("SMOKE ...and it settles back to idle afterwards: ", tab._viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS)

	# --- toast: haptic cue + status pulse
	var cues := []
	ui.feedback.connect(func(e: String) -> void: cues.append(e))
	ui.toast("Couldn't do the thing", "error")
	ui.tick(0.016) # the status line takes a toast on the next tick (on Home there is no tool text for it to replace)
	print("SMOKE an error toast shows in the status bar, pulses it, and asks for an error haptic: ", ui.status_text() != "" and ui._status_panel.self_modulate != Color.WHITE and cues == ["error"])
	ui.tick(0.016)
	print("SMOKE ...the status bar says what went wrong: ", ui.status_text().contains("Couldn't do the thing"))

	# --- Reduce motion: instant open and stow
	var UiFeedback = load("res://scripts/ui/ui_feedback.gd")
	UiFeedback.reduce_motion = true
	tab.close_tablet()
	print("SMOKE with Reduce motion the tablet is hidden the instant it closes: ", not tab.visible)
	tab.open_tablet()
	print("SMOKE ...and opens at full size at once (no scale-in): ", tab.visible and tab.scale.is_equal_approx(Vector3.ONE) and tab._quad_material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED)
	UiFeedback.reduce_motion = false

	# --- stow: no stuck claim, panel no longer rendered
	tab.close_tablet()
	await process_frame
	await process_frame
	print("SMOKE a closed tablet isn't rendered (main and side viewports off): ", tab._viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED and tab._side_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED)
	quit()
