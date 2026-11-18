extends Node3D
## P0 Cardboard spike (docs/live-sessions-spikes.md, "Spike C"): the phone observer's camera and render budget, measured on the owner's
## phone. Not part of the app: `scenes/spikes/cardboard_spike.tscn` is exported as the main scene of a separate "phone" preset, and
## main.tscn never loads it.
##
## What it does: a setup screen (magic window, touch) loads one or two assembly glbs (from a URL the owner serves from the PC, or a demo
## rocket shipped in the APK) through the same GLTFDocument + mesh_identity.gd path main.gd uses, with collision optional, then a
## guided run of test steps in Godot's built-in MobileVRInterface (side-by-side stereo, lens distortion, gyro orientation). A screen tap
## (the viewer's button) or gamepad A moves to the next step; every 2 s it logs one `DIDSA VR: cardboard:` line (adb logcat) and shows the
## same text in front of the eyes. It reuses the app's viewing core only: environment_manager.gd, view_modes.gd, clip_look.gd and the
## clip globals, mesh_identity.gd.

const FrameStats := preload("res://scripts/spikes/frame_stats.gd")
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const ClipGlobals := preload("res://scripts/clip_globals.gd")
const ClipLook := preload("res://scripts/clip_look.gd")
const ViewModes := preload("res://scripts/view_modes.gd")
const SETTINGS_PATH := "user://cardboard_spike.cfg"
const DEMO_GLB := "res://demo/rockets/Saturn_V.glb"
const REPORT_EVERY_S := 2.0
const DRIFT_S := 60.0

## The guided steps (the doc's C2 to C8). model: "light" / "heavy"; stereo; edges; section; msaa (0 off, 1 2x); oversample.
const STEPS := [
	{"id": "C2", "label": "C2 light model, stereo, edges on, section on, MSAA 2x", "model": "light", "stereo": true, "edges": true, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C3", "label": "C3 heavy model, stereo, edges on, section on, MSAA 2x (leave it 10 minutes for C4)", "model": "heavy", "stereo": true, "edges": true, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C3b", "label": "C3b heavy, edges OFF", "model": "heavy", "stereo": true, "edges": false, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C3c", "label": "C3c heavy, edges off, MSAA OFF", "model": "heavy", "stereo": true, "edges": false, "section": true, "msaa": 0, "oversample": 1.5},
	{"id": "C3d", "label": "C3d heavy, edges off, MSAA off, oversample 1.0", "model": "heavy", "stereo": true, "edges": false, "section": true, "msaa": 0, "oversample": 1.0},
	{"id": "C8", "label": "C8 magic window (mono), heavy, edges on, section on", "model": "heavy", "stereo": false, "edges": true, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C5", "label": "C5 drift: lay the phone flat and still for 60 s", "model": "light", "stereo": true, "edges": false, "section": false, "msaa": 1, "oversample": 1.5, "drift": true},
]

@onready var assembly_root: Node3D = $AssemblyRoot
@onready var xr_camera: XRCamera3D = $XROrigin3D/XRCamera3D
@onready var window_camera: Camera3D = $WindowCamera
@onready var world_environment: WorldEnvironment = $WorldEnvironment
@onready var hud_label: Label3D = $XROrigin3D/XRCamera3D/Hud
@onready var setup_ui: Control = $SetupLayer/Setup

var mobile_vr: XRInterface
var view_modes: Node
var stats := FrameStats.new()
var step_index := -1
var models: Dictionary = {} ## "light" / "heavy" -> {"scene": Node3D, "summary": String}
var build_collision := false
var _report_left := REPORT_EVERY_S
var _step_started_ms := 0
var _drift_start_yaw := NAN
var _joy_logged := 0
var last_report := "" ## what the last report said (tests read it)
var results: Dictionary = {} ## step id -> its last report: shown on the setup screen after the run (a photo of it is the result)
var lens := {"iod": 6.0, "k1": 0.215, "k2": 0.215} ## MobileVRInterface's eye spacing (cm) and distortion; Godot's defaults


func _ready() -> void:
	ClipGlobals.ensure()
	_log("start: OpenXR initialised = %s, feature tag 'phone' = %s, OS = %s, model = %s" % [
		_openxr_initialised(), OS.has_feature("phone"), OS.get_name(), OS.get_model_name()])
	mobile_vr = XRServer.find_interface("Native mobile")
	if mobile_vr == null:
		_log("no MobileVRInterface in this build")
	world_environment.setup($DirectionalLight3D, mobile_vr, get_viewport(), ($Ground/MeshInstance3D as MeshInstance3D).mesh.material as ShaderMaterial)
	world_environment.apply_saved_scene("Mid")
	view_modes = ViewModes.new()
	view_modes.name = "ViewModes"
	add_child(view_modes)
	view_modes.setup(self, 1)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_build_setup_ui()


func _openxr_initialised() -> bool:
	var openxr := XRServer.find_interface("OpenXR")
	return openxr != null and openxr.is_initialized()


# --- loading ----------------------------------------------------------------------------------------------------------------------

func load_glb_bytes(slot: String, bytes: PackedByteArray, source: String) -> bool:
	## Parses a glb the way main.gd's _show_model does, timing each stage, and keeps it as the `slot` model.
	var t0 := Time.get_ticks_usec()
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(bytes, "", state) != OK:
		_log("%s: glTF parse failed (%s)" % [slot, source])
		return false
	var t1 := Time.get_ticks_usec()
	var scene := doc.generate_scene(state)
	if scene == null:
		_log("%s: no scene in %s" % [slot, source])
		return false
	var t2 := Time.get_ticks_usec()
	MeshIdentity.tag_scene(state, scene)
	var parts := 0
	var triangles := 0
	var candidates: Array[Node] = [scene]
	candidates.append_array(scene.find_children("*", "MeshInstance3D", true, false))
	for node in candidates:
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			parts += 1
			node.add_to_group("grabbable_parts")
			var mesh := (node as MeshInstance3D).mesh
			for s in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(s)
				var idx = arrays[Mesh.ARRAY_INDEX]
				triangles += (idx.size() if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	var t3 := Time.get_ticks_usec()
	if build_collision:
		for node in candidates:
			if node is MeshInstance3D:
				node.create_trimesh_collision()
	var t4 := Time.get_ticks_usec()
	if models.has(slot):
		(models[slot]["scene"] as Node).queue_free()
	var summary := "%s: %s, %d KB, %d parts, %d triangles; parse %d ms, scene %d ms, tag %d ms, collision %s, total %d ms" % [
		slot, source.get_file(), bytes.size() / 1024, parts, triangles, (t1 - t0) / 1000, (t2 - t1) / 1000, (t3 - t2) / 1000,
		("%d ms" % ((t4 - t3) / 1000)) if build_collision else "off", (t4 - t0) / 1000]
	models[slot] = {"scene": scene, "summary": summary}
	_log("load " + summary)
	return true


func _load_url(slot: String, url: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.download_chunk_size = 1 << 20
	if req.request(url) != OK:
		_log("%s: could not start a request to %s" % [slot, url])
		req.queue_free()
		return
	var result: Array = await req.request_completed
	req.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		_log("%s: download failed from %s (result %d, HTTP %d)" % [slot, url, result[0], result[1]])
		return
	load_glb_bytes(slot, result[3], url)
	_refresh_setup_text()


func load_demo(slot: String) -> void:
	load_glb_bytes(slot, FileAccess.get_file_as_bytes(DEMO_GLB), DEMO_GLB)


# --- the run ----------------------------------------------------------------------------------------------------------------------

func start_run() -> void:
	if not models.has("light"):
		load_demo("light")
	if not models.has("heavy"):
		_log("no heavy model loaded: the heavy steps use the light one")
		models["heavy"] = models["light"]
	setup_ui.visible = false
	step_index = -1
	results.clear()
	_apply_lens()
	next_step()


func next_step() -> void:
	step_index += 1
	if step_index >= STEPS.size():
		_log("run finished: back to the setup screen")
		_set_stereo(false)
		setup_ui.visible = true
		step_index = -1
		_refresh_setup_text()
		return
	apply_step(STEPS[step_index])


func apply_step(step: Dictionary) -> void:
	for child in assembly_root.get_children():
		assembly_root.remove_child(child)
	var scene: Node3D = models[step["model"]]["scene"]
	assembly_root.add_child(scene)
	_fit_in_front(scene)
	view_modes.set_mode(1 if step["edges"] else 0)
	view_modes.apply_all()
	_set_section(step["section"], scene)
	get_viewport().msaa_3d = Viewport.MSAA_2X if int(step["msaa"]) == 1 else Viewport.MSAA_DISABLED
	if mobile_vr != null:
		mobile_vr.set("oversample", float(step["oversample"]))
	_set_stereo(bool(step["stereo"]))
	stats.clear()
	_step_started_ms = Time.get_ticks_msec()
	_drift_start_yaw = NAN
	_report_left = REPORT_EVERY_S
	_log("step %s: %s | %s" % [step["id"], step["label"], models[step["model"]]["summary"]])


func _apply_lens() -> void:
	if mobile_vr != null:
		mobile_vr.set("iod", float(lens["iod"]))
		mobile_vr.set("k1", float(lens["k1"]))
		mobile_vr.set("k2", float(lens["k2"]))
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	for k in lens:
		cfg.set_value("lens", k, lens[k])
	cfg.save(SETTINGS_PATH)


func _set_stereo(on: bool) -> void:
	if mobile_vr == null:
		window_camera.current = true
		return
	if not mobile_vr.is_initialized():
		if not mobile_vr.initialize():
			_log("MobileVRInterface failed to initialise")
			window_camera.current = true
			return
	get_viewport().use_xr = on
	window_camera.current = not on
	hud_label.visible = on


func _set_section(on: bool, scene: Node3D) -> void:
	if on:
		var nodes: Array = scene.find_children("*", "MeshInstance3D", true, false)
		if scene is MeshInstance3D:
			nodes.append(scene)
		for node in nodes:
			var part := node as MeshInstance3D
			if ClipLook.per_surface(part):
				if not ClipLook.surfaces_wrapped(part):
					ClipLook.wrap_surfaces(part)
			elif not ClipLook.is_clip(part.material_override):
				part.material_override = ClipLook.clip_for(part.material_override, part)
		var box := _bounds(scene)
		RenderingServer.global_shader_parameter_set("section_plane_origin", box.get_center())
		RenderingServer.global_shader_parameter_set("section_plane_normal", Vector3.RIGHT)
	RenderingServer.global_shader_parameter_set("section_enabled", on)


func _fit_in_front(scene: Node3D) -> void:
	## The model about 1.2 m tall, 1.5 m in front of a seated viewer (glb units are mm for a backend glb, m for a demo).
	assembly_root.transform = Transform3D.IDENTITY
	var box := _bounds(scene)
	var size := maxf(box.get_longest_axis_size(), 0.001)
	var s := 1.2 / size
	assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * s), Vector3(0, 1.1, -1.5) - box.get_center() * s)


func _bounds(scene: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var nodes: Array = scene.find_children("*", "VisualInstance3D", true, false)
	if scene is VisualInstance3D:
		nodes.append(scene)
	for node in nodes:
		var vi := node as VisualInstance3D
		var local: AABB = vi.get_aabb()
		var rel: Transform3D = scene.global_transform.affine_inverse() * vi.global_transform if scene.is_inside_tree() else _relative(scene, vi)
		var b: AABB = rel * local
		box = b if first else box.merge(b)
		first = false
	return box


func _relative(root: Node3D, node: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


func _process(delta: float) -> void:
	if step_index < 0:
		return
	if window_camera.current and mobile_vr != null and mobile_vr.is_initialized():
		window_camera.global_transform = xr_camera.global_transform # magic window: the phone is a window you turn
	stats.add(delta)
	var step: Dictionary = STEPS[step_index]
	if step.get("drift", false):
		var yaw := xr_camera.global_transform.basis.get_euler().y
		if is_nan(_drift_start_yaw) and Time.get_ticks_msec() - _step_started_ms > 2000:
			_drift_start_yaw = yaw
	_report_left -= delta
	if _report_left <= 0.0:
		_report_left = REPORT_EVERY_S
		report()


func report() -> void:
	var step: Dictionary = STEPS[step_index]
	var s := stats.summary()
	var rid := get_viewport().get_viewport_rid()
	var text := "%s %s | %s | render cpu %.1f ms gpu %.1f ms | %d draw calls | %d s into the step" % [
		step["id"], "PASS-60" if FrameStats.passes_60(s) else "below-60", FrameStats.line(s),
		RenderingServer.viewport_get_measured_render_time_cpu(rid), RenderingServer.viewport_get_measured_render_time_gpu(rid),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		(Time.get_ticks_msec() - _step_started_ms) / 1000]
	if step.get("drift", false) and not is_nan(_drift_start_yaw):
		var drift := rad_to_deg(angle_difference(_drift_start_yaw, xr_camera.global_transform.basis.get_euler().y))
		text += " | yaw drift %.1f deg (pass <= 5 deg at %d s)" % [drift, int(DRIFT_S)]
	stats.clear()
	results[step["id"]] = text
	_log(text)
	hud_label.text = text.replace(" | ", "\n")


# --- input ------------------------------------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if _joy_logged < 40 and (event is InputEventJoypadButton or absf((event as InputEventJoypadMotion).axis_value) > 0.5):
			_joy_logged += 1
			_log("gamepad '%s' (device %d): %s" % [Input.get_joy_name(event.device), event.device, event.as_text()])
	if step_index < 0:
		return
	if event is InputEventJoypadButton and event.pressed:
		var b := (event as InputEventJoypadButton).button_index
		var change := {JOY_BUTTON_DPAD_UP: ["k1", 0.01], JOY_BUTTON_DPAD_DOWN: ["k1", -0.01], JOY_BUTTON_DPAD_RIGHT: ["k2", 0.01], JOY_BUTTON_DPAD_LEFT: ["k2", -0.01]}
		if change.has(b):
			lens[change[b][0]] = snappedf(lens[change[b][0]] + change[b][1], 0.001)
			_apply_lens()
			_log("lens tuned on the gamepad: k1 %.3f, k2 %.3f, iod %.2f cm" % [lens["k1"], lens["k2"], lens["iod"]])
			return
	var tap: bool = event is InputEventScreenTouch and event.pressed and (event as InputEventScreenTouch).index == 0
	var a_button: bool = event is InputEventJoypadButton and event.pressed and (event as InputEventJoypadButton).button_index == JOY_BUTTON_A
	var key: bool = event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_SPACE
	if tap or a_button or key:
		report()
		next_step()
	var b_button: bool = event is InputEventJoypadButton and event.pressed and (event as InputEventJoypadButton).button_index == JOY_BUTTON_B
	if b_button:
		step_index = STEPS.size()
		next_step()


# --- the setup screen -------------------------------------------------------------------------------------------------------------

var _url_light: LineEdit
var _url_heavy: LineEdit
var _setup_text: Label


func _build_setup_ui() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 24)
	box.add_theme_constant_override("separation", 12)
	setup_ui.add_child(box)
	var title := Label.new()
	title.text = "DIDSA Cardboard spike (P0). Serve the glbs from the PC: python3 -m http.server 8080 in their folder."
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)
	_url_light = _row(box, "Light model URL (the gear train glb):", str(cfg.get_value("urls", "light", "http://192.168.1.10:8080/gear_train.glb")))
	_url_heavy = _row(box, "Heavy model URL (your heaviest assembly):", str(cfg.get_value("urls", "heavy", "http://192.168.1.10:8080/heavy.glb")))
	for k in lens:
		lens[k] = float(cfg.get_value("lens", k, lens[k]))
	var lens_row := HBoxContainer.new()
	box.add_child(lens_row)
	for k in ["iod", "k1", "k2"]:
		var l := Label.new()
		l.text = {"iod": "Eye spacing (cm)", "k1": "  Lens k1", "k2": "  Lens k2"}[k]
		lens_row.add_child(l)
		var e := LineEdit.new()
		e.text = str(lens[k])
		e.custom_minimum_size = Vector2(140, 64)
		e.text_changed.connect(func(t: String) -> void:
			if t.is_valid_float():
				lens[k] = float(t))
		lens_row.add_child(e)
	var collision := CheckButton.new()
	collision.text = "Build collision on load (laser picking; C7 measures its cost)"
	collision.toggled.connect(func(on: bool) -> void: build_collision = on)
	box.add_child(collision)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	_button(buttons, "Load both", func() -> void:
		cfg.set_value("urls", "light", _url_light.text)
		cfg.set_value("urls", "heavy", _url_heavy.text)
		cfg.save(SETTINGS_PATH)
		_load_url("light", _url_light.text.strip_edges())
		_load_url("heavy", _url_heavy.text.strip_edges()))
	_button(buttons, "Use the demo rocket", func() -> void:
		load_demo("light")
		_refresh_setup_text())
	_button(buttons, "Start the run (put the phone in the viewer)", start_run)
	_setup_text = Label.new()
	_setup_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_setup_text)
	_refresh_setup_text()


func _row(parent: Control, label: String, value: String) -> LineEdit:
	var l := Label.new()
	l.text = label
	parent.add_child(l)
	var edit := LineEdit.new()
	edit.text = value
	edit.custom_minimum_size = Vector2(0, 64)
	parent.add_child(edit)
	return edit


func _button(parent: Control, label: String, action: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 80)
	b.pressed.connect(action)
	parent.add_child(b)


func _refresh_setup_text() -> void:
	if _setup_text == null:
		return
	var lines := PackedStringArray(["Steps: tap the screen (the viewer's button) or gamepad A for the next step, B to stop; gamepad D-pad tunes the lens (k1 up / down, k2 left / right). The lens values above come from your viewer's QR profile, or tune by eye."])
	for slot in ["light", "heavy"]:
		lines.append(models[slot]["summary"] if models.has(slot) else "%s: not loaded" % slot)
	if not results.is_empty():
		lines.append("RESULTS of the last run (take a photo of this screen, or copy the log: adb logcat -s godot | grep cardboard:):")
		for id in results:
			lines.append(str(results[id]))
		lines.append("lens: eye spacing %.2f cm, k1 %.3f, k2 %.3f" % [lens["iod"], lens["k1"], lens["k2"]])
	_setup_text.text = "\n".join(lines)


func _log(text: String) -> void:
	last_report = text
	print("DIDSA VR: cardboard: ", text)
