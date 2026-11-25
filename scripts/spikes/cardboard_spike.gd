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
##
## Stereo, two ways (the setup screen's switch). OWN (the default): two SubViewports, one camera per eye, side by side on a
## CanvasLayer, each eye barrel-distorted by a canvas shader; the frustum and the distortion are the same maths as Godot's
## MobileVRInterface (Projection::set_for_hmd and the blit's lens shader), and the head pose still comes from MobileVRInterface's
## sensor fusion (its "head" tracker drives the XRCamera3D; the eye cameras follow it). GODOT'S: `use_xr` on the main viewport with
## MobileVRInterface. On the owner's Galaxy S26 Ultra (24 Nov, Godot 4.7.2, Mobile renderer) Godot's path drew nothing to the screen
## ("Layers of our texture doesn't match view count for this framebuffer" every frame), which is why OWN exists.

const FrameStats := preload("res://scripts/spikes/frame_stats.gd")
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const ClipGlobals := preload("res://scripts/clip_globals.gd")
const ClipLook := preload("res://scripts/clip_look.gd")
const ViewModes := preload("res://scripts/view_modes.gd")
const SETTINGS_PATH := "user://cardboard_spike.cfg"
const DEMO_GLB := "res://demo/rockets/Saturn_V.glb"
const REPORT_EVERY_S := 2.0
const WARM_UP_S := 2.0 ## each step's first seconds (the switch-over hitch, shaders) are left out of its numbers
const C4_AFTER_S := 540.0 ## C3 counts as C4 (a warm phone) when it ran at least this long
const DRIFT_S := 60.0
## The barrel distortion of Godot's lens blit (servers/rendering/renderer_rd/shaders/blit.glsl), as a canvas shader on each eye.
const LENS_SHADER := """
shader_type canvas_item;
uniform float k1 = 0.215;
uniform float k2 = 0.215;
uniform float upscale = 1.5;
uniform float aspect_ratio = 1.0;
uniform vec2 eye_center = vec2(0.0);
void fragment() {
	vec2 coords = UV * 2.0 - 1.0;
	vec2 offset = coords - eye_center;
	offset.y /= aspect_ratio;
	float r2 = dot(offset, offset);
	offset *= 1.0 + k1 * r2 + k2 * r2 * r2;
	offset.y *= aspect_ratio;
	coords = (offset + eye_center) / upscale;
	if (coords.x < -1.0 || coords.y < -1.0 || coords.x > 1.0 || coords.y > 1.0) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		COLOR = vec4(texture(TEXTURE, (coords + vec2(1.0)) * 0.5).rgb, 1.0);
	}
}
"""

## The guided steps (the doc's C2 to C8). model: "light" / "heavy"; stereo; edges; section; msaa (0 off, 1 2x); oversample.
const STEPS := [
	{"id": "C2", "seconds": 20, "label": "C2 light model, stereo, edges on, section on, MSAA 2x", "model": "light", "stereo": true, "edges": true, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C3", "seconds": 600, "label": "C3 heavy model, stereo, edges on, section on, MSAA 2x (runs 10 minutes: its last lines are C4)", "model": "heavy", "stereo": true, "edges": true, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C3b", "seconds": 20, "label": "C3b heavy, edges OFF", "model": "heavy", "stereo": true, "edges": false, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C3c", "seconds": 20, "label": "C3c heavy, edges off, MSAA OFF", "model": "heavy", "stereo": true, "edges": false, "section": true, "msaa": 0, "oversample": 1.5},
	{"id": "C3d", "seconds": 20, "label": "C3d heavy, edges off, MSAA off, oversample 1.0", "model": "heavy", "stereo": true, "edges": false, "section": true, "msaa": 0, "oversample": 1.0},
	{"id": "C8", "seconds": 20, "label": "C8 magic window (mono), heavy, edges on, section on", "model": "heavy", "stereo": false, "edges": true, "section": true, "msaa": 1, "oversample": 1.5},
	{"id": "C5", "seconds": 62, "label": "C5 drift: lay the phone flat and still; it ends by itself after 60 s", "model": "light", "stereo": true, "edges": false, "section": false, "msaa": 1, "oversample": 1.5, "drift": true},
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
var _warmed := false
var auto_advance := true ## each step ends by itself after its "seconds"; a tap ends it early
var _drift_start_yaw := NAN
var _joy_logged := 0
var last_report := "" ## what the last report said (tests read it)
var results: Dictionary = {} ## step id -> its last report: shown on the setup screen after the run (a photo of it is the result)
var lens := {"iod": 6.0, "k1": 0.215, "k2": 0.215} ## MobileVRInterface's eye spacing (cm) and distortion; Godot's defaults
var own_stereo := true ## false: Godot's MobileVRInterface path (use_xr on the main viewport)
var display_width_cm := 14.5 ## MobileVRInterface's defaults, read from it when it exists
var display_to_lens_cm := 4.0
var _oversample := 1.5
var _stereo_layer: CanvasLayer
var _eyes: Array = [] ## {"viewport": SubViewport, "camera": Camera3D, "rect": TextureRect, "material": ShaderMaterial, "side": -1 / 1}


func _ready() -> void:
	ClipGlobals.ensure()
	_log("start: OpenXR initialised = %s, feature tag 'phone' = %s, OS = %s, model = %s" % [
		_openxr_initialised(), OS.has_feature("phone"), OS.get_name(), OS.get_model_name()])
	mobile_vr = XRServer.find_interface("Native mobile")
	if mobile_vr == null:
		_log("no MobileVRInterface in this build")
	else:
		display_width_cm = float(mobile_vr.get("display_width"))
		display_to_lens_cm = float(mobile_vr.get("display_to_lens"))
	world_environment.setup($DirectionalLight3D, mobile_vr, get_viewport(), ($Ground/MeshInstance3D as MeshInstance3D).mesh.material as ShaderMaterial)
	world_environment.apply_saved_scene("Mid")
	view_modes = ViewModes.new()
	view_modes.name = "ViewModes"
	add_child(view_modes)
	view_modes.setup(self, 1)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_build_eyes()
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


func make_stress(slot: String, triangles: int, parts := 300) -> void:
	## A made-up assembly of `parts` spheres (one colour each) with about `triangles` triangles in all, written to a glb and loaded
	## through load_glb_bytes like a served one: for C3 / C4 when no real assembly is heavy enough. Its load line measures the glb
	## path; the time to make it is logged separately.
	var t0 := Time.get_ticks_msec()
	parts = maxi(parts, 1)
	var rings := maxi(int(sqrt(float(triangles) / parts / 4.0)), 2) # a SphereMesh has about 4 * rings^2 triangles at radial = 2 * rings
	var side := int(ceil(pow(parts, 1.0 / 3.0)))
	var root := Node3D.new()
	root.name = "Stress"
	for i in parts:
		var sphere := SphereMesh.new()
		sphere.rings = rings
		sphere.radial_segments = rings * 2
		sphere.radius = 20.0
		sphere.height = 40.0
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.from_hsv(float(i) / parts, 0.5, 0.85)
		mesh.surface_set_material(0, mat)
		var part := MeshInstance3D.new()
		part.name = "Part%03d" % i
		part.mesh = mesh
		part.position = Vector3(i % side, (i / side) % side, i / (side * side)) * 50.0
		root.add_child(part)
		part.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var ok := doc.append_from_scene(root, state) == OK
	var bytes := doc.generate_buffer(state) if ok else PackedByteArray()
	root.free()
	if bytes.is_empty():
		_log("%s: could not make the stress model" % slot)
		return
	_log("%s: stress model made in %d ms (%d parts, %d rings each)" % [slot, Time.get_ticks_msec() - t0, parts, rings])
	load_glb_bytes(slot, bytes, "stress_%dk.glb" % (triangles / 1000))


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
	var msaa := Viewport.MSAA_2X if int(step["msaa"]) == 1 else Viewport.MSAA_DISABLED
	get_viewport().msaa_3d = msaa
	for eye in _eyes:
		(eye["viewport"] as SubViewport).msaa_3d = msaa
	_oversample = float(step["oversample"])
	if mobile_vr != null:
		mobile_vr.set("oversample", _oversample)
	_set_stereo(bool(step["stereo"]))
	stats.clear()
	_warmed = false
	_step_started_ms = Time.get_ticks_msec()
	_drift_start_yaw = NAN
	_report_left = REPORT_EVERY_S
	_log("step %s: %s | %s | %s" % [step["id"], step["label"], _stereo_summary(bool(step["stereo"])), models[step["model"]]["summary"]])


func _apply_lens() -> void:
	if mobile_vr != null:
		mobile_vr.set("iod", float(lens["iod"]))
		mobile_vr.set("k1", float(lens["k1"]))
		mobile_vr.set("k2", float(lens["k2"]))
	_layout_eyes()
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	for k in lens:
		cfg.set_value("lens", k, lens[k])
	cfg.save(SETTINGS_PATH)


func _set_stereo(on: bool) -> void:
	## MobileVRInterface is initialised either way: its sensor fusion moves the XRCamera3D (the head) for both stereo paths and for
	## magic window. Only Godot's path turns use_xr on.
	if mobile_vr != null and not mobile_vr.is_initialized() and not mobile_vr.initialize():
		_log("MobileVRInterface failed to initialise")
	var godot_path := on and not own_stereo and mobile_vr != null and mobile_vr.is_initialized()
	var own := on and own_stereo
	get_viewport().use_xr = godot_path
	get_viewport().disable_3d = own # the eyes draw the world; the main viewport only shows them
	_stereo_layer.visible = own
	for eye in _eyes:
		(eye["viewport"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS if own else SubViewport.UPDATE_DISABLED
	window_camera.current = not godot_path
	hud_label.visible = on
	if own:
		_layout_eyes()
		_follow_head()


func _stereo_summary(on: bool) -> String:
	if not on:
		return "mono (magic window)"
	if not own_stereo:
		return "stereo: Godot's MobileVRInterface"
	var size: Vector2i = (_eyes[0]["viewport"] as SubViewport).size
	return "stereo: own, 2 eyes of %dx%d, screen %dx%d" % [size.x, size.y, _screen_size().x, _screen_size().y]


# --- own stereo: two eye viewports ----------------------------------------------------------------------------------------------

func _build_eyes() -> void:
	_stereo_layer = CanvasLayer.new()
	_stereo_layer.name = "StereoLayer"
	_stereo_layer.layer = 0 # under the setup screen (layer 1)
	_stereo_layer.visible = false
	add_child(_stereo_layer)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stereo_layer.add_child(row)
	var shader := Shader.new()
	shader.code = LENS_SHADER
	for side in [-1, 1]:
		var vp := SubViewport.new()
		vp.name = "LeftEye" if side < 0 else "RightEye"
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(vp) # a child of this node, so it shares the main viewport's World3D
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_FRUSTUM
		cam.keep_aspect = Camera3D.KEEP_HEIGHT
		cam.far = 500.0
		vp.add_child(cam)
		cam.current = true
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var rect := TextureRect.new()
		rect.texture = vp.get_texture()
		rect.material = mat
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(rect)
		_eyes.append({"viewport": vp, "camera": cam, "rect": rect, "material": mat, "side": side})
	# The eyes follow the head just before the frame is drawn too, so they are never a frame behind the head tracker's pose.
	RenderingServer.frame_pre_draw.connect(func() -> void:
		if is_instance_valid(_stereo_layer) and _stereo_layer.visible:
			_follow_head())


func _screen_size() -> Vector2i:
	var size := DisplayServer.window_get_size()
	return Vector2i(maxi(size.x, 64), maxi(size.y, 64))


func _layout_eyes() -> void:
	## Each eye: half the screen times the oversample, an asymmetric frustum and the lens shader, as MobileVRInterface does them.
	if _eyes.is_empty():
		return
	var screen := _screen_size()
	var eye_size := Vector2i(maxi(int(screen.x * 0.5 * _oversample), 16), maxi(int(screen.y * _oversample), 16))
	var aspect := float(eye_size.x) / float(eye_size.y)
	var iod := float(lens["iod"])
	# Projection::set_for_hmd, per unit of near distance
	var f1 := (iod * 0.5) / display_to_lens_cm
	var f2 := ((display_width_cm - iod) * 0.5) / display_to_lens_cm
	var f3 := (display_width_cm / 4.0) / display_to_lens_cm
	var add := ((f1 + f2) * (_oversample - 1.0)) / 2.0
	f1 += add
	f2 += add
	f3 = f3 * _oversample / aspect
	for eye in _eyes:
		var vp: SubViewport = eye["viewport"]
		vp.size = eye_size
		var cam: Camera3D = eye["camera"]
		cam.near = 0.05
		var side := int(eye["side"])
		# left eye: x from -f2 to f1; right eye: from -f1 to f2
		var offset_x := (f1 - f2) * 0.5 if side < 0 else (f2 - f1) * 0.5
		cam.frustum_offset = Vector2(offset_x * cam.near, 0.0)
		cam.size = 2.0 * f3 * cam.near
		var mat: ShaderMaterial = eye["material"]
		mat.set_shader_parameter("k1", float(lens["k1"]))
		mat.set_shader_parameter("k2", float(lens["k2"]))
		mat.set_shader_parameter("upscale", _oversample)
		mat.set_shader_parameter("aspect_ratio", aspect)
		var centre := ((-iod / 2.0) + (display_width_cm / 4.0)) / (display_width_cm / 2.0)
		mat.set_shader_parameter("eye_center", Vector2(centre if side < 0 else -centre, 0.0))


func _follow_head() -> void:
	var head := xr_camera.global_transform
	for eye in _eyes:
		var x := float(eye["side"]) * float(lens["iod"]) * 0.01 * 0.5
		(eye["camera"] as Camera3D).global_transform = head * Transform3D(Basis.IDENTITY, Vector3(x, 0.0, 0.0))


func _gpu_ms() -> float:
	var total := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	if _stereo_layer != null and _stereo_layer.visible:
		for eye in _eyes:
			total += RenderingServer.viewport_get_measured_render_time_gpu((eye["viewport"] as SubViewport).get_viewport_rid())
	return total


func _cpu_ms() -> float:
	var total := RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
	if _stereo_layer != null and _stereo_layer.visible:
		for eye in _eyes:
			total += RenderingServer.viewport_get_measured_render_time_cpu((eye["viewport"] as SubViewport).get_viewport_rid())
	return total


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
	if _stereo_layer.visible:
		_follow_head() # and again just before drawing (frame_pre_draw), whichever comes after the head's pose
	var step: Dictionary = STEPS[step_index]
	var elapsed := _step_elapsed_s()
	if not _warmed and elapsed >= WARM_UP_S:
		_warmed = true
		stats.clear()
	if auto_advance and elapsed >= float(step.get("seconds", 20)):
		finish_step()
		next_step()
		return
	stats.add(delta)
	if step.get("drift", false):
		var yaw := heading()
		if is_nan(_drift_start_yaw) and Time.get_ticks_msec() - _step_started_ms > 2000:
			_drift_start_yaw = yaw
	_report_left -= delta
	if _report_left <= 0.0:
		_report_left = REPORT_EVERY_S
		report()


func heading() -> float:
	## The phone's heading about the vertical, for C5. Euler yaw is meaningless when the camera looks straight down (a phone lying
	## flat: gimbal lock, it swung 200 degrees on the owner's phone), so a flat phone uses its top edge, which is then level.
	var b := xr_camera.global_transform.basis
	var v := -b.z
	if absf(v.normalized().y) > 0.7:
		v = b.y
	return atan2(v.x, v.z)


func _step_elapsed_s() -> float:
	return (Time.get_ticks_msec() - _step_started_ms) / 1000.0


func finish_step() -> void:
	## The step's last report; C3 that ran long enough is also C4 (the same heavy scene on a warm phone).
	report()
	var step: Dictionary = STEPS[step_index]
	if step["id"] == "C3" and _step_elapsed_s() >= C4_AFTER_S:
		results["C4"] = "C4 (C3 after %d s, warm phone): %s" % [int(_step_elapsed_s()), results["C3"]]
		_log(results["C4"])


func report() -> void:
	var step: Dictionary = STEPS[step_index]
	var s := stats.summary()
	var text := "%s %s | %s | render cpu %.1f ms gpu %.1f ms | %d draw calls | %d s into the step" % [
		step["id"], "PASS-60" if FrameStats.passes_60(s) else "below-60", FrameStats.line(s),
		_cpu_ms(), _gpu_ms(),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		(Time.get_ticks_msec() - _step_started_ms) / 1000]
	if step.get("drift", false) and not is_nan(_drift_start_yaw):
		var drift := rad_to_deg(angle_difference(_drift_start_yaw, heading()))
		text += " | yaw drift %.1f deg (pass <= 5 deg at %d s)" % [drift, int(DRIFT_S)]
	stats.clear()
	results[step["id"]] = text
	_log(text)
	hud_label.text = "%s: %d of %d s (tap to skip)\n%s" % [step["id"], int(_step_elapsed_s()), int(step.get("seconds", 20)), text.replace(" | ", "\n")]


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
		finish_step()
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
	var godot_stereo := CheckButton.new()
	godot_stereo.text = "Godot's stereo (MobileVRInterface) instead of the spike's own (Godot's drew black on the S26 Ultra)"
	godot_stereo.button_pressed = not bool(cfg.get_value("stereo", "own", true))
	own_stereo = not godot_stereo.button_pressed
	godot_stereo.toggled.connect(func(on: bool) -> void:
		own_stereo = not on
		cfg.set_value("stereo", "own", own_stereo)
		cfg.save(SETTINGS_PATH))
	box.add_child(godot_stereo)
	var stress_row := HBoxContainer.new()
	box.add_child(stress_row)
	var stress_label := Label.new()
	stress_label.text = "Stress model, triangles:"
	stress_row.add_child(stress_label)
	var stress_count := LineEdit.new()
	stress_count.text = str(cfg.get_value("stress", "triangles", 600000))
	stress_count.custom_minimum_size = Vector2(220, 64)
	stress_row.add_child(stress_count)
	_button(stress_row, "Make it the heavy model (300 parts)", func() -> void:
		var n := int(stress_count.text) if stress_count.text.is_valid_int() else 600000
		cfg.set_value("stress", "triangles", n)
		cfg.save(SETTINGS_PATH)
		make_stress("heavy", n)
		_refresh_setup_text())
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
	var lines := PackedStringArray(["Steps run by themselves: 20 s each, C3 10 minutes (its end is C4), C5 a minute flat and still; the first 2 s of each are left out. A tap (the viewer's button) or gamepad A skips to the next step, B stops; gamepad D-pad tunes the lens (k1 up / down, k2 left / right). The lens values above come from your viewer's QR profile, or tune by eye."])
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
