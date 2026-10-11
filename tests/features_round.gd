extends SceneTree
## Headless checks for the travel-speed slider, grabbable single-mesh files
## (a glTF whose only scene root IS the mesh), and resizable floating windows.
## Boots main.tscn with NO backend.
## Run: "$GODOT" --headless --path . --script res://tests/features_round.gd  (see tests/README.md)

var main
var origin: XROrigin3D
var l: XRController3D
var r: XRController3D
var tab


func _all_nodes(n: Node, out: Array) -> void:
	out.append(n)
	for c in n.get_children():
		_all_nodes(c, out)


func _find_button(txt: String) -> Button:
	var nodes: Array = []
	_all_nodes(tab._viewport, nodes)
	for n in nodes:
		if n is Button and n.is_visible_in_tree() and n.text == txt:
			return n
	return null


func _aim_at_tablet_px(px: Vector2) -> void:
	var local := Vector3((px.x / tab._viewport.size.x - 0.5) * tab.panel_size.x, (0.5 - px.y / tab._viewport.size.y) * tab.panel_size.y, 0.0)
	var world: Vector3 = tab._quad.global_transform * local
	r.global_position = world + tab._quad.global_transform.basis.z * 0.4
	r.look_at(world, Vector3.UP)


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	origin = main.get_node("XROrigin3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	tab = l.get_node("WristTablet")
	for i in 4:
		await process_frame

	# --- travel speed: bottom of the range is the old fixed walking pace, and the default.
	print("SMOKE travel speed defaults to the original walking pace (1.5 m/s): ", is_equal_approx(origin.move_speed, 1.5) and origin.speed_fraction() == 0.0)
	origin.set_speed_fraction(1.0)
	print("SMOKE the top of the slider is much faster (30 m/s): ", is_equal_approx(origin.move_speed, 30.0))
	origin.set_speed_fraction(0.5)
	print("SMOKE the slider is exponential (middle = geometric mean, ~6.7 m/s): ", absf(origin.move_speed - sqrt(1.5 * 30.0)) < 0.01)
	print("SMOKE speed_fraction() inverts set_speed_fraction(): ", absf(origin.speed_fraction() - 0.5) < 0.001)
	origin.set_speed_fraction(-3.0)
	print("SMOKE out-of-range fractions clamp to the walking pace: ", is_equal_approx(origin.move_speed, 1.5))

	# --- the slider on the tablet's View > Navigate page
	tab.open_tablet()
	tab.ui.select_tool("navigate") # the tablet opens on Home; View > Navigate is two taps away
	for i in 4:
		await process_frame
	var slider: HSlider = tab.pages._speed_slider
	print("SMOKE the tablet has a Travel speed slider on View > Navigate, at the bottom by default: ", slider != null and slider.is_visible_in_tree() and slider.value == 0.0)
	print("SMOKE its label shows the current speed: ", tab.pages._speed_label.text.begins_with("Travel speed: 1.5 m/s"))
	slider.value = 1.0
	print("SMOKE moving the slider sets the walk speed: ", is_equal_approx(origin.move_speed, 30.0) and "30.0 m/s" in tab.pages._speed_label.text)
	slider.value = 0.0

	# --- dragging it with the laser (a press that starts on a slider keeps tracking the aim)
	await create_timer(0.6).timeout # the tablet ignores presses for a moment after opening
	var rect := Rect2(slider.global_position, slider.size)
	var y := rect.position.y + rect.size.y * 0.5
	_aim_at_tablet_px(Vector2(rect.position.x + rect.size.x * 0.1, y))
	for i in 4:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	for step in range(1, 9): # sweep to ~90% while holding
		_aim_at_tablet_px(Vector2(rect.position.x + rect.size.x * (0.1 + 0.1 * step), y))
		await process_frame
		await process_frame
	var mid_drag := slider.value
	r.button_released.emit("trigger_click")
	for i in 3:
		await process_frame
	print("calibration — slider value after dragging from 10% to 90%: ", snappedf(mid_drag, 0.01), " speed ", snappedf(origin.move_speed, 0.1))
	print("SMOKE holding the trigger on the slider and sweeping the laser drags it (value follows, ends high): ", mid_drag > 0.6 and origin.move_speed > 6.0)
	slider.value = 0.0

	# --- single-mesh files: a glTF whose only scene root is the mesh node
	DirAccess.make_dir_recursive_absolute("user://models")
	var solo := MeshInstance3D.new()
	solo.name = "Solo"
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 0.2
	solo.mesh = box
	root.add_child(solo)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(solo, state)
	var bytes := doc.generate_buffer(state)
	solo.queue_free()
	var f := FileAccess.open("user://models/features_solo.glb", FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()
	main.load_model_file("user://models/features_solo.glb")
	await process_frame
	var parts: Array = main.get_tree().get_nodes_in_group("grabbable_parts")
	print("SMOKE a single-mesh glTF loads as one grabbable part (not '0 part mesh(es)'): ", parts.size() == 1 and main._part_count == 1)
	if parts.size() == 1:
		var part: MeshInstance3D = parts[0]
		r.global_position = part.global_transform * part.get_aabb().get_center()
		await process_frame
		print("SMOKE ...and a grip at it finds it as the grab target: ", r._find_grab_target() == part)
		var shape_ok := false
		for c in part.get_children():
			if c is StaticBody3D:
				for cs in c.get_children():
					if cs is CollisionShape3D and cs.shape is ConcavePolygonShape3D:
						shape_ok = cs.shape.backface_collision
		print("SMOKE ...and its laser-pick collider is double-sided (third-party meshes often have flipped winding): ", shape_ok)

	# --- resizable windows
	var calc = main._calculator_window
	calc.open()
	await process_frame
	calc.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.4, -1.0))
	r.set_meta("ui_hover", false)
	var size0: Vector2 = calc.panel_size
	var px0: Vector2i = calc.viewport_size
	# aim at a spot just outside the TOP-RIGHT corner
	var out_local := Vector3(size0.x * 0.5 + 0.02, size0.y * 0.5 + 0.02, 0.0)
	var out_world: Vector3 = calc.global_transform * out_local
	r.global_position = out_world + Vector3(0, 0, 0.5)
	r.look_at(out_world, Vector3.UP)
	for i in 3:
		await process_frame
	print("SMOKE aiming just outside a corner hovers that corner (top-right): ", calc._hover_corner == 1)
	print("SMOKE ...its bracket highlights (bright, enlarged): ", calc._corner_materials[1].albedo_color == calc._corner_hot and calc._corners[1].scale.x > 1.2)
	print("SMOKE ...the others stay dim: ", calc._corner_materials[0].albedo_color == calc._corner_idle and calc._corner_materials[3].albedo_color == calc._corner_idle)
	print("SMOKE ...and the laser claims the panel (ui_hover), so the trigger isn't a part-select: ", r.get_meta("ui_hover") == true)
	var bottom_left_before: Vector3 = calc.global_transform * Vector3(-size0.x * 0.5, -size0.y * 0.5, 0.0)
	r.button_pressed.emit("trigger_click")
	await process_frame
	print("SMOKE trigger on a hovered corner starts a resize: ", calc._resize_corner == 1)
	# drag out and up by 10 cm each way
	var drag_world: Vector3 = calc.global_transform * (out_local + Vector3(0.1, 0.1, 0.0))
	r.global_position = drag_world + Vector3(0, 0, 0.5)
	r.look_at(drag_world, Vector3.UP)
	for i in 4:
		await process_frame
	var size1: Vector2 = calc.panel_size
	print("calibration — panel size ", size0, " -> ", size1, ", viewport ", px0, " -> ", calc.viewport_size)
	print("SMOKE dragging the corner out grows the window by about the drag (+0.12 each way): ", absf(size1.x - (size0.x + 0.12)) < 0.02 and absf(size1.y - (size0.y + 0.12)) < 0.02)
	var bottom_left_after: Vector3 = calc.global_transform * Vector3(-size1.x * 0.5, -size1.y * 0.5, 0.0)
	print("SMOKE the OPPOSITE (bottom-left) corner stays where it was: ", bottom_left_before.distance_to(bottom_left_after) < 0.005)
	print("SMOKE it's a true resize: the SubViewport grew with the panel at the same pixels-per-metre: ", absf(float(calc.viewport_size.x) / calc.panel_size.x - float(px0.x) / size0.x) < 4.0 and calc.viewport_size.x > px0.x and calc._viewport.size == calc.viewport_size)
	print("SMOKE the quad and drag handle follow the new size: ", (calc._quad.mesh as QuadMesh).size == calc.panel_size and absf(calc._handle.position.y + calc.panel_size.y * 0.5 + 0.02) < 0.001)
	r.button_released.emit("trigger_click")
	await process_frame
	var frozen: Vector2 = calc.panel_size
	r.global_position += Vector3(0.2, 0.2, 0)
	for i in 3:
		await process_frame
	print("SMOKE releasing ends the resize (further aim movement doesn't change it): ", calc._resize_corner == -1 and calc.panel_size == frozen)

	# limits
	calc._resize_corner = 2 # bottom-left, dragged far into the panel: must clamp to the minimum
	var far_local := Vector3(calc.panel_size.x * 0.5 - 0.01, calc.panel_size.y * 0.5 - 0.01, 0.0)
	var far_world: Vector3 = calc.global_transform * far_local
	r.global_position = far_world + Vector3(0, 0, 0.5)
	r.look_at(far_world, Vector3.UP)
	for i in 3:
		await process_frame
	print("SMOKE shrinking clamps at the minimum size: ", calc.panel_size.x >= calc.min_panel_size.x - 0.0001 and calc.panel_size.y >= calc.min_panel_size.y - 0.0001)
	calc._end_resize()

	# aiming away un-hovers; a normal content click still works after a resize
	r.global_position = Vector3(3, 3, 3)
	r.look_at(Vector3(3, 3, 2), Vector3.UP)
	for i in 3:
		await process_frame
	print("SMOKE aiming away un-highlights every corner: ", calc._hover_corner == -1 and calc._corner_materials[1].albedo_color == calc._corner_idle)
	calc.close()

	quit()
