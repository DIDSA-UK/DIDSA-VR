extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe):
##   WHEEL_RENDER_DIR=/tmp/wheel_hint xvfb-run -a "$GODOT" --path . --script res://tests/wheel_hint_render.gd
## Does the right wrist's hint panel (wrist_hint.gd) cover the tool wheel now that the ring opens centred on the hand? In the real scene
## (box-and-cylinder fixture, no backend) the ring is opened at the hand and the hand is moved onto each wedge in turn. Each step is
## rendered twice from the player's eye, with the panel and without; the pixels that differ are what the panel covers. Each wedge's
## outline is projected to the screen, so the report says how much of the HOVERED wedge (the one being chosen) and of the other wedges
## the panel hides, for two hand poses: the controller level, and pitched down 35 degrees (how a hand usually sits while reaching).
## Prints a table and SMOKE lines; with WHEEL_RENDER_DIR set it also saves the with-panel pictures. GL software render, not a headset.

const Math := preload("res://scripts/ui/tool_wheel_math.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const HAND_FROM_EYE := Vector3(0.18, -0.40, -0.50) ## where the hand is when the chord opens the ring, from the eye: arm's length ahead, chest height
var ANCHOR := Vector3.ZERO
const STRIDE := 2 ## sample every 2nd pixel

var _main: Node
var _r: XRController3D
var _cam: XRCamera3D
var _eye: Camera3D
var _wheel
var _flows
var _dir := ""


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 960))
	_main = load("res://scenes/main.tscn").instantiate()
	_main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(_main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = _main.get_node("XROrigin3D")
	_cam = origin.get_node("XRCamera3D")
	_cam.position = Vector3(0, 1.6, 0)
	ANCHOR = _cam.global_position + HAND_FROM_EYE
	_r = origin.get_node("RightController")
	origin.get_node("LeftController").position = Vector3(-0.4, 1.0, -0.4)
	_main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	_wheel = _main.get_node("ToolWheel")
	_flows = _main.get_node("WheelFlows")
	_eye = Camera3D.new()
	_eye.fov = 90.0 # roughly a headset's field of view
	_main.add_child(_eye)
	_eye.make_current()
	for i in 4:
		await process_frame
	_dir = OS.get_environment("WHEEL_RENDER_DIR")
	if _dir != "":
		DirAccess.make_dir_recursive_absolute(_dir)

	var worst_hovered := 0.0
	for pose in [{"name": "level", "pitch": 0.0}, {"name": "pitched", "pitch": -35.0}]:
		var basis := Basis(Vector3.RIGHT, deg_to_rad(pose["pitch"]))
		await _open(basis)
		var count: int = _wheel.current_entries().size()
		print("POSE %s: %d wedges, ring scale %.3f, outer radius drawn %.3f m" % [pose["name"], count, _wheel.drawn_scale(), Math.OUTER_RADIUS * _wheel.drawn_scale()])
		print("  wedge (label)           hovered-covered  others-covered(worst wedge)")
		for i in count:
			var dir := Math.centre_direction(i, count)
			await _move(basis, dir * Math.CONTENT_RADIUS * _wheel.drawn_scale())
			if _wheel.hovered_index() != i:
				print("  wedge %d not hovered (got %d)" % [i, _wheel.hovered_index()])
			var with_panel := await _shot()
			var hint: Node3D = _flows.hint_panel()
			var was := hint.visible
			hint.visible = false
			var without := await _shot()
			hint.visible = was
			var cover := _coverage(with_panel, without, count)
			var label := str(_wheel.current_entries()[i].get("label", "?"))
			var others := 0.0
			var others_at := -1
			for j in count:
				if j != i and cover[j] > others:
					others = cover[j]
					others_at = j
			print("  %d %-20s %6.1f %%          %5.1f %% (wedge %d)" % [i, label, cover[i] * 100.0, others * 100.0, others_at])
			worst_hovered = maxf(worst_hovered, cover[i])
			if _dir != "":
				var centre := Vector2i(_eye.unproject_position(ANCHOR) * Vector2(with_panel.get_size()) / root.get_visible_rect().size)
				var crop := Rect2i(centre - Vector2i(300, 260), Vector2i(600, 560)).intersection(Rect2i(Vector2i.ZERO, with_panel.get_size()))
				with_panel.get_region(crop).save_png("%s/%s_%02d_%s.png" % [_dir, pose["name"], i, label.to_lower().replace(" ", "_")])
		_release()
	print("SMOKE the wrist panel hides at most 10%% of the wedge being chosen (worst %.1f%%): %s" % [worst_hovered * 100.0, str(worst_hovered <= 0.10)])
	quit()


func _open(basis: Basis) -> void:
	_r.global_transform = Transform3D(basis, ANCHOR)
	_r.wheel_chord_started.emit()
	for i in 3:
		await process_frame


func _move(basis: Basis, offset: Vector2) -> void:
	_r.global_transform = Transform3D(basis, ANCHOR + _wheel._right * offset.x + _wheel._up * offset.y)
	for i in 4:
		await process_frame


func _release() -> void:
	_r.global_transform = Transform3D(Basis(), ANCHOR)
	_wheel._process(0.0)
	_wheel._on_released("trigger_click")
	_wheel._on_released("grip_click")


func _shot() -> Image:
	for i in 2:
		await process_frame
	_eye.global_transform = _cam.global_transform
	_eye.look_at(ANCHOR) # the user looks at the ring (it opened at the hand) while choosing
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _coverage(a: Image, b: Image, count: int) -> Array:
	## Per wedge: the fraction of its on-screen pixels that differ between the two pictures (the panel is in front of it there).
	var polys: Array = []
	var boxes: Array = []
	var scale := Vector2(a.get_size()) / root.get_visible_rect().size
	for i in count:
		var screen := PackedVector2Array()
		for p in Math.wedge_outline(i, count):
			screen.append(_eye.unproject_position(_wheel.global_transform * Vector3(p.x, p.y, 0.0)) * scale)
		polys.append(screen)
		var r := Rect2(screen[0], Vector2.ZERO)
		for q in screen:
			r = r.expand(q)
		boxes.append(r)
	var out: Array = []
	for i in count:
		var inside := 0
		var covered := 0
		var r: Rect2 = boxes[i]
		for y in range(maxi(0, int(r.position.y)), mini(a.get_height(), int(r.end.y)), STRIDE):
			for x in range(maxi(0, int(r.position.x)), mini(a.get_width(), int(r.end.x)), STRIDE):
				if not Geometry2D.is_point_in_polygon(Vector2(x, y), polys[i]):
					continue
				inside += 1
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.06:
					covered += 1
		out.append(float(covered) / float(maxi(inside, 1)))
	return out
