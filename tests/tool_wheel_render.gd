extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as tests/tablet_render.gd and tests/dock_panels_render.gd):
##   WHEEL_RENDER_DIR=/tmp/wheel xvfb-run -a "$GODOT" --path . --script res://tests/tool_wheel_render.gd
## Picture-only (a human reads the PNGs; not run by ci_render.sh). Walks the Constraint flow in the real scene with the box-and-cylinder
## fixture and no backend, saving NN_name.png at each step from the player's own eye (the XR camera's pose, so the prompt that hangs in
## front of the camera is in the picture): the root ring, Constraint hovered, the first and second pick prompts, the Constraint ring with
## Create greyed, the Type sub-wheel, Create ready, and the result of pressing Create (no backend, so it reports why it could not).
## The mate's blue ghost preview needs the backend and is not drawn here. The chord signal and release handler are called directly
## (headless / Xvfb has no real grip). GL-compatibility software render, not a headset view: a layout check.

const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var _main: Node
var _r: XRController3D
var _cam: XRCamera3D
var _eye: Camera3D
var _wheel
var _flows
var _dir := ""
var _anchor := Vector3(0.22, 1.55, -0.75)
var _saved := 0


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_main = load("res://scenes/main.tscn").instantiate()
	_main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(_main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = _main.get_node("XROrigin3D")
	_cam = origin.get_node("XRCamera3D")
	_cam.position = Vector3(0, 1.6, 0)
	_r = origin.get_node("RightController")
	origin.get_node("LeftController").position = Vector3(-0.4, 1.0, -0.4)
	_r.position = _anchor
	_main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	_wheel = _main.get_node("ToolWheel")
	_flows = _main.get_node("WheelFlows")
	_eye = Camera3D.new()
	_eye.fov = 75.0
	_main.add_child(_eye)
	_eye.make_current()
	for i in 4:
		await process_frame
	_dir = OS.get_environment("WHEEL_RENDER_DIR")
	var manager = _main._tablet.manager
	var mates = _main._mates_tool

	await _open()
	await _shot("01_root_ring")
	await _move(Vector2(0.0, 0.12))
	await _shot("02_root_constraint_hovered")
	_release()
	print("SMOKE Constraint switched Mates on: ", manager.is_active("mates"))
	await _shot("03_prompt_pick_first")

	var parts := _parts()
	mates.try_pick(parts[0], 0, {})
	await _shot("04_prompt_pick_second")

	await _open()
	await _move(Vector2(0.0, 0.12)) # Create, greyed with one pick
	await _shot("05_constraint_ring_create_greyed")
	await _move(Vector2(0.0, -0.12) * 0.0 + Vector2(sin(PI), cos(PI)) * 0.24) # towards Type, opens its ring
	_anchor = _r.global_position
	await _move(Vector2(sin(TAU / 5.0), cos(TAU / 5.0)) * 0.12) # Concentric
	await _shot("06_type_subwheel_concentric_hovered")
	_release()
	_anchor = Vector3(0.22, 1.55, -0.75)
	_r.global_position = _anchor
	print("SMOKE releasing on Concentric set the type: ", mates.mate_type == "concentric")

	mates.try_pick(parts[1], 0, {})
	print("SMOKE two picks are in: ", mates.picked_labels().size() == 2, " status: ", mates.status_text())
	await _shot("07_prompt_ready_to_create")
	await _open()
	await _move(Vector2(0.0, 0.12))
	await _shot("08_constraint_ring_create_ready")
	_release()
	for i in 20:
		await process_frame
	await _shot("09_prompt_after_create_no_backend")
	# The same ring in each theme (and with shader effects off): Navy, Simple and Dark differ in colour, corner radius, outline and glow.
	var UiThemes = load("res://scripts/ui/ui_themes.gd")
	manager.deactivate()
	var n := 10
	for theme_name in ["Navy", "Simple", "Dark"]:
		UiThemes.apply(theme_name)
		await _open()
		await _move(Vector2(0.0, 0.12))
		await _shot("%d_theme_%s" % [n, theme_name.to_lower()])
		await _move(Vector2.ZERO) # let go at the centre: cancel, so the next theme starts from the same root ring
		_release()
		n += 1
	UiThemes.set_fx(false)
	await _open()
	await _move(Vector2(0.0, 0.12))
	await _shot("%d_theme_dark_effects_off" % n)
	await _move(Vector2.ZERO)
	_release()
	UiThemes.set_fx(true)
	UiThemes.apply("Navy")
	print("SMOKE %d pictures saved" % _saved)
	quit()


func _parts() -> Array:
	var out := []
	for p in get_nodes_in_group("grabbable_parts"):
		out.append(p)
	out.sort_custom(func(a: Node, b: Node) -> bool: return str(a.name) < str(b.name))
	return out


func _open() -> void:
	_anchor = Vector3(0.22, 1.55, -0.75)
	_r.global_position = _anchor
	_r.wheel_chord_started.emit()
	await process_frame


func _move(offset: Vector2) -> void:
	_r.global_position = _anchor + _wheel._right * offset.x + Vector3.UP * offset.y
	for i in 3:
		await process_frame


func _release() -> void:
	_wheel._on_released("trigger_click")
	_wheel._on_released("grip_click")


func _shot(shot_name: String) -> void:
	for i in 3:
		await process_frame
	_eye.global_transform = _cam.global_transform
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var lit := false
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).get_luminance() > 0.02:
				lit = true
	print("SMOKE %s is not blank: " % shot_name, lit)
	if _dir != "":
		DirAccess.make_dir_recursive_absolute(_dir)
		img.save_png("%s/%s.png" % [_dir, shot_name])
		_saved += 1
