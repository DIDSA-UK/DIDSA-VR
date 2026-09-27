extends SceneTree
## Full-scene test: instantiates main.tscn (with NO backend) and drives the wrist tablet with a simulated right laser: bullseye open/close and false positives, Files tab loading a generated .glb, Fit/Home/presets, Modes toggles, Steadiness, Perf tab levers, one-hand drag.
## Run: "$GODOT" --headless --path . --script res://tests/tablet_scene.gd  (see tests/README.md)

var main
var tab
var l: XRController3D
var r: XRController3D

func find_button(pred: Callable) -> Button:
	var stack: Array = [tab._viewport]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack.append_array(n.get_children())
	return null

func aim_and_click(b: Button) -> void:
	var c: Vector2 = b.global_position + b.size * 0.5
	var lx: float = (c.x / tab.viewport_size.x - 0.5) * tab.panel_size.x
	var ly: float = (0.5 - c.y / tab.viewport_size.y) * tab.panel_size.y
	r.position = Vector3(l.position.x + tab.mount_position.x + lx, 1.5, l.position.z + tab.mount_position.z - ly)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"   # no backend => no network
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
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
	print("SMOKE status: ", main.status_text)

	# --- false positives: staring at the wrist (camera looking straight down at it, laser elsewhere) must NOT open it
	r.position = Vector3(1.0, 1.5, 1.0)
	for i in 5:
		await process_frame
	print("SMOKE looking at wrist, no shot -> tablet open=", tab._open, " visible=", tab.visible, " bullseye visible=", tab._target.visible)
	# laser sweeping across the tablet's area while closed must not click anything either
	r.position = Vector3(l.position.x + 0.15, 1.5, l.position.z + tab.target_position.z)   # 15 cm to the side of the bullseye
	for i in 3:
		await process_frame
	print("SMOKE 15cm off the bullseye: hover=", tab._target_hover, " ui_hover meta=", r.get_meta("ui_hover"))
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click")
	print("SMOKE trigger 15cm off the bullseye -> open=", tab._open)
	# shoot the bullseye
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await process_frame
	print("SMOKE aiming at bullseye: hover=", tab._target_hover, " ui_hover meta=", r.get_meta("ui_hover"))
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click"); await process_frame
	print("SMOKE after shooting bullseye -> open=", tab._open, " visible=", tab.visible, " bullseye visible=", tab._target.visible)
	# a quick second pull right after opening must be ignored (laser is still resting where the bullseye was)
	var modes_before = [th.enabled, origin.enabled, l.parts_enabled]
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click"); await process_frame
	print("SMOKE immediate second pull ignored: ", modes_before == [th.enabled, origin.enabled, l.parts_enabled], " (pressed=", tab._pressed, ")")
	await create_timer(0.5).timeout

	# make a real .glb in user://models and list/load it
	var scene := Node3D.new()
	var mi := MeshInstance3D.new(); mi.mesh = BoxMesh.new(); mi.name = "Box"; scene.add_child(mi)
	var gd := GLTFDocument.new(); var gs := GLTFState.new()
	gd.append_from_scene(scene, gs)
	DirAccess.make_dir_recursive_absolute("user://models")
	gd.write_to_filesystem(gs, "user://models/smoke_test.glb")
	print("SMOKE listed: ", main.list_model_files())

	# Files tab via the tablet
	await aim_and_click(find_button(func(b): return b.text == "Files"))
	var fb := find_button(func(b): return b.text == "smoke_test.glb")
	print("SMOKE files tab shows the file: ", fb != null)
	await aim_and_click(fb)
	print("SMOKE parts=", main._part_count, " ", th.scale_text(), " status=", main.status_text)

	# reload same file again (replaces the model, no dangling refs)
	await aim_and_click(find_button(func(b): return b.text == "smoke_test.glb"))
	print("SMOKE reloaded: parts=", main._part_count, " children=", main.assembly_root.get_child_count())

	# Fit and Home on the Scale tab
	await aim_and_click(find_button(func(b): return b.text == "Scale"))
	await aim_and_click(find_button(func(b): return b.text == "Fit to view"))
	var box: AABB = th._model_bounds()
	print("SMOKE after Fit: centre=", box.get_center(), " diag/2=", box.size.length() * 0.5, " ", th.scale_text())
	await aim_and_click(find_button(func(b): return b.text == "Home"))
	print("SMOKE after Home: origin=", main.assembly_root.global_position, " ", th.scale_text())
	await aim_and_click(find_button(func(b): return b.text == "2:1"))
	print("SMOKE 2:1 -> ", th.scale_text())

	# one-hand drag (hand grip can't be faked headless, call the routine directly)
	var before: Vector3 = main.assembly_root.global_position
	th._update_one_hand(l, l.global_position)               # baseline
	l.position += Vector3(0.3, 0.0, -0.2)
	th._update_one_hand(l, l.global_position)
	var moved: Vector3 = main.assembly_root.global_position - before
	print("SMOKE one-hand drag: hand moved (0.3,0,-0.2), model moved ", moved, " = x", snappedf(moved.length() / Vector3(0.3, 0, -0.2).length(), 0.01), " (gain grows with model size; 1.0 for a small model)")
	l.position = Vector3(0, 1.0, 0)

	# Modes tab
	await aim_and_click(find_button(func(b): return b.text == "Modes"))
	await aim_and_click(find_button(func(b): return b.text.begins_with("User movement")))
	print("SMOKE  after user-movement click: locomotion=", origin.enabled)
	await aim_and_click(find_button(func(b): return b.text.begins_with("Model movement")))
	print("SMOKE  after model-movement click: model=", th.enabled)
	await aim_and_click(find_button(func(b): return b.text.begins_with("Part manipulation")))
	print("SMOKE  after part-manipulation click: parts=", l.parts_enabled, "/", r.parts_enabled)
	print("SMOKE modes: locomotion=", origin.enabled, " model=", th.enabled, " parts=", l.parts_enabled, "/", r.parts_enabled)

	# steadiness row (Modes tab is showing): pick "Strong"
	print("SMOKE steadiness default: ", th.STEADINESS_NAMES[th.steadiness])
	await aim_and_click(find_button(func(b): return b.text == "Strong"))
	print("SMOKE steadiness after clicking Strong: ", th.STEADINESS_NAMES[th.steadiness], " cutoff=", th._left_filter.min_cutoff)
	# perf tab
	await aim_and_click(find_button(func(b): return b.text == "Perf"))
	await create_timer(0.7).timeout
	print("SMOKE perf tab text: ", tab._info_label.text.replace("
", " / "))
	var light: DirectionalLight3D = main.get_node("DirectionalLight3D")
	print("SMOKE shadows before: ", light.shadow_enabled)
	await aim_and_click(find_button(func(b): return b.text.begins_with("Shadows")))
	print("SMOKE shadows after click: ", light.shadow_enabled)
	await aim_and_click(find_button(func(b): return b.text == "80%"))
	print("SMOKE resolution 80% -> scaling_3d_scale=", main.get_viewport().scaling_3d_scale)
	await aim_and_click(find_button(func(b): return b.text == "Off"))
	print("SMOKE MSAA Off -> ", main.get_viewport().msaa_3d, " (0 = disabled)")
	print("SMOKE tablet panel rendering while open: ", tab._viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
	await aim_and_click(find_button(func(b): return b.text == "X"))
	print("SMOKE tablet panel rendering after close: ", tab._viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS)
	await process_frame
	print("SMOKE after pressing X -> open=", tab._open, " visible=", tab.visible, " bullseye visible=", tab._target.visible)

	# --- real-headset regression: a real trigger squeeze takes real time,
	# during which a real hand drifts a little even when "aiming steadily" —
	# _send_click() used to read the LIVE pointer position for both the down
	# and up events, so the "up" landed wherever the drifted aim ended up,
	# not where the button was at press-time. Godot's own Button only counts
	# a click when down and up land on the SAME control, so this silently
	# dropped every real click while hover still looked completely normal
	# throughout — exactly why aim_and_click()'s own press+release-in-place
	# pattern above never caught it. Reproduce the drift deliberately here.
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click"); await process_frame
	await create_timer(0.5).timeout # open_settle_seconds
	var scale_tab := find_button(func(b): return b.text == "Scale")
	var c: Vector2 = scale_tab.global_position + scale_tab.size * 0.5
	var lx: float = (c.x / tab.viewport_size.x - 0.5) * tab.panel_size.x
	var ly: float = (0.5 - c.y / tab.viewport_size.y) * tab.panel_size.y
	r.position = Vector3(l.position.x + tab.mount_position.x + lx, 1.5, l.position.z + tab.mount_position.z - ly)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click") # DOWN while aimed squarely at "Scale"
	await process_frame
	r.position.x += 0.05 # drift sideways mid-press — a real hand rarely holds a laser aim perfectly still for the ~100-300ms a trigger squeeze takes
	for i in 3:
		await process_frame # _update_pointer() keeps tracking the drifted aim every frame, same as it would on a real headset
	r.button_released.emit("trigger_click") # UP now aimed somewhere else entirely
	await process_frame
	print("SMOKE a click still registers despite the hand drifting mid-press: ", tab._pages["Scale"].visible)

	DirAccess.remove_absolute("user://models/smoke_test.glb")
	quit()
