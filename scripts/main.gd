extends Node3D
## Engine-choice spike: imports a saved DIDSA-CAD assembly file straight
## into the backend's "default" session, then downloads the resulting
## GET /document/parts/{part_id}/assembly-mesh.glb node-instanced glTF and
## drops it into the world so it can be grabbed with controller.gd.
##
## Setup: drop a real assembly export (a .DIDSAprt/.didsa file whose root
## Part has occurrences on it — i.e. an assembly, not a bare part) into
## this project folder, next to project.godot, named exactly what
## native_file_path below says (default "assembly.didsa"). Its
## document.root_part_id is read automatically — no part id to hunt for
## or type in by hand. Only backend_url and api_key need editing in the
## Inspector on the "Main" node.

@export_group("Backend")
@export var backend_url: String = "" ## Loaded from secrets.cfg at runtime (see README) — don't hardcode a real
## URL/key here, this script is committed to git.
@export var api_key: String = "" ## Matches the backend's CAD_API_KEY. Also loaded from secrets.cfg.
@export var secrets_file_path: String = "res://secrets.cfg" ## Untracked (see .gitignore); holds the real
## backend_url/api_key for this machine. See secrets.cfg.example for the format.
@export var native_file_path: String = "res://assembly.didsa" ## The exported native file to import before loading.
@export var part_id_override: String = "" ## Leave blank to auto-read root_part_id from native_file_path.
@export var quality: float = 0.5 ## 0..1, same slider as the JSON endpoint.
@export var include_hidden: bool = false
@export var tier: String = "" ## "" for full quality, or "coarse".

@export_group("Placement")
@export var spawn_position: Vector3 = Vector3(0, 1.0, -1.0)
@export var local_glb_scale: float = 1.0 ## Scale for a .glb loaded from disk with the tablet's Files tab.
## A bare glb is normally in metres per the glTF spec (unlike the backend's, which is mm), so 1.0.
@export var spawn_scale: float = 0.001 ## Backend native units are millimetres (see backend/app/document/models.py's
## Mate docstring), but glTF/Godot both treat raw coordinate values as metres.
## 0.001 converts mm -> m. If a part looks tiny/huge, check what units it was
## actually modelled in before touching this.

@onready var http_request: HTTPRequest = $HTTPRequest
@onready var assembly_root: Node3D = $AssemblyRoot
@onready var status_label: Label3D = $StatusLabel3D

var xr_interface: XRInterface
var _resolved_part_id: String = ""

# Perf readout (see _process): the numbers milestone 1 exists to measure
# on-headset. Timestamps are Time.get_ticks_msec() values.
var _two_hand: Node
var _tablet: Node
var _worst_frame_ms := 0.0 ## longest frame since the readout last refreshed: steady ~22 ms = pacing/cap, spikes = hitches
var _perf_refresh_left := 0.0
var _import_started_ms := 0
var _download_started_ms := 0
var _parse_started_ms := 0
var _load_summary := ""
var _part_count := 0

# All endpoints below live under the backend's "/document" router prefix —
# see backend/app/document/router.py's `router = APIRouter(prefix="/document", ...)`.
const API_PREFIX := "/document"


func _ready() -> void:
	assembly_root.add_to_group("assembly_root")
	_add_two_hand_model()
	_add_wrist_tablet()
	_load_secrets()
	_start_xr()
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("No backend configured (see secrets.cfg.example). Turn your left wrist up and use the Files tab to load a local .glb.")
		return
	http_request.request_completed.connect(_on_import_completed)
	_begin_import()


func _add_two_hand_model() -> void:
	var two_hand := preload("res://scripts/two_hand_model.gd").new()
	two_hand.name = "TwoHandModel"
	add_child(two_hand)
	two_hand.setup(assembly_root, $XROrigin3D/LeftController, $XROrigin3D/RightController, spawn_scale)
	_two_hand = two_hand


func _add_wrist_tablet() -> void:
	var tablet := preload("res://scripts/wrist_tablet.gd").new()
	tablet.name = "WristTablet"
	tablet.setup($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, _two_hand, $XROrigin3D, self)
	_tablet = tablet


func set_measuring(on: bool) -> void:
	## GPU/CPU render timing costs a little itself, so it only runs while the tablet is open.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)


func set_shadows(on: bool) -> void:
	$DirectionalLight3D.shadow_enabled = on


func set_render_scale(multiplier: float) -> void:
	## Fraction of the headset runtime's recommended resolution (per axis). The biggest
	## lever on a GPU-bound frame: 80% is ~64% of the pixels.
	if xr_interface and xr_interface.is_initialized():
		xr_interface.set("render_target_size_multiplier", multiplier)
	else:
		get_viewport().scaling_3d_scale = multiplier


func set_msaa(level: int) -> void:
	get_viewport().msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][level]


func _process(delta: float) -> void:
	_worst_frame_ms = maxf(_worst_frame_ms, delta * 1000.0)
	# Only while the tablet is open (nobody can see the numbers otherwise), and a few
	# times a second: rewriting the label every frame would make the readout itself a
	# cost and be unreadable anyway.
	if not _tablet.is_open():
		return
	_perf_refresh_left -= delta
	if _perf_refresh_left > 0.0:
		return
	_perf_refresh_left = 0.5
	var lines := PackedStringArray()
	lines.append("%d fps  %.1f ms/frame  (worst %.1f ms)" % [Engine.get_frames_per_second(), delta * 1000.0, _worst_frame_ms])
	_worst_frame_ms = 0.0
	var viewport_rid := get_viewport().get_viewport_rid()
	lines.append("render: cpu %.1f ms, gpu %.1f ms  |  scripts %.1f ms, physics %.1f ms" % [
		RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid),
		RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	])
	if _part_count > 0:
		lines.append("%d parts  %d draw calls" % [_part_count, int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))])
	if _load_summary != "":
		lines.append(_load_summary)
	_tablet.set_info("\n".join(lines))


func _load_secrets() -> void:
	if not FileAccess.file_exists(secrets_file_path):
		return
	var config := ConfigFile.new()
	if config.load(secrets_file_path) != OK:
		push_warning("DIDSA VR spike: couldn't parse %s" % secrets_file_path)
		return
	backend_url = config.get_value("backend", "url", backend_url)
	api_key = config.get_value("backend", "api_key", api_key)


func _start_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		get_viewport().use_xr = true
		# The headset runtime sets the pace. Vsync on the desktop mirror window would make
		# every frame also wait for the monitor's refresh, which can cap a 90 Hz headset
		# at about half rate (the classic Godot XR "stuck at 45-50 fps" trap).
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		print("DIDSA VR spike: OpenXR initialised, headset active.")
	else:
		push_warning("DIDSA VR spike: OpenXR not initialised — running as a flat desktop preview. On Quest this should initialise automatically; on desktop it's expected unless a PCVR runtime (e.g. Virtual Desktop) is actively streaming to a headset right now.")
		_spawn_desktop_camera()


func _spawn_desktop_camera() -> void:
	# XRCamera3D only drives the viewport once OpenXR is actually tracking a
	# headset — without one, nothing is set as the active camera and the
	# flat preview just renders blank even though the scene loaded fine.
	# This gives the desktop-preview path something to look through,
	# roughly aimed at spawn_position.
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = spawn_position + Vector3(0.0, 0.6, 2.2)
	camera.look_at(spawn_position, Vector3.UP)
	camera.current = true


func _begin_import() -> void:
	if not FileAccess.file_exists(native_file_path):
		if part_id_override.is_empty():
			_set_status("No file at %s and no part_id_override set — nothing to load." % native_file_path)
			return
		# No native file to import: assume the part is already loaded in the
		# backend's "default" session by some other means, and go straight
		# to the mesh fetch (the old, manual-part-id behaviour).
		_resolved_part_id = part_id_override
		_download_started_ms = Time.get_ticks_msec()
		_fetch_mesh()
		return

	var file := FileAccess.open(native_file_path, FileAccess.READ)
	var raw_text := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(raw_text)
	if parsed == null or not (parsed is Dictionary):
		_set_status("Couldn't parse %s as JSON — is it a real exported .didsa/.DIDSAprt file?" % native_file_path)
		return

	var document_dict: Dictionary = parsed.get("document", {})
	var root_part_id: String = str(document_dict.get("root_part_id", ""))
	if not part_id_override.is_empty():
		root_part_id = part_id_override
	if root_part_id.is_empty():
		_set_status("File has no document.root_part_id and no part_id_override was given.")
		return
	_resolved_part_id = root_part_id

	_set_status("Importing %s (part %s) into the backend..." % [native_file_path.get_file(), _resolved_part_id])
	_import_started_ms = Time.get_ticks_msec()

	var url := "%s%s/import/native" % [backend_url, API_PREFIX]
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
	var error := http_request.request(url, headers, HTTPClient.METHOD_POST, raw_text)
	if error != OK:
		_set_status("Import request failed to start (error %d)" % error)


func _on_import_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# First completion this session is always the import call; disconnect
	# and hook up the mesh-fetch handler for the second call so the same
	# HTTPRequest node can be reused sequentially.
	http_request.request_completed.disconnect(_on_import_completed)

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_status("Import failed: HTTP %d (result %d)" % [response_code, result])
		push_error("DIDSA VR spike: /import/native failed: result=%d code=%d body=%s" % [result, response_code, body.get_string_from_utf8()])
		return

	_set_status("Imported. Fetching assembly mesh...")
	_download_started_ms = Time.get_ticks_msec()
	http_request.request_completed.connect(_on_mesh_completed)
	_fetch_mesh()


func _fetch_mesh() -> void:
	var url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [
		backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()
	]
	if tier != "":
		url += "&tier=%s" % tier
	var headers := ["X-API-Key: %s" % api_key]
	var error := http_request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		_set_status("Mesh request failed to start (error %d)" % error)


func _on_mesh_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_status("Mesh load failed: HTTP %d (result %d)" % [response_code, result])
		push_error("DIDSA VR spike: assembly-mesh.glb fetch failed: result=%d code=%d" % [result, response_code])
		return

	_parse_started_ms = Time.get_ticks_msec()
	var download_ms := _parse_started_ms - _download_started_ms
	_set_status("Downloaded %d KB, parsing glTF..." % int(body.size() / 1024.0))
	if not _show_model(body, "", spawn_scale):
		return

	var import_ms := (_download_started_ms - _import_started_ms) if _import_started_ms > 0 else 0
	_load_summary = "load: import %d ms, download %d ms (%d KB), parse %d ms" % [
		import_ms, download_ms, int(body.size() / 1024.0), Time.get_ticks_msec() - _parse_started_ms
	]
	print("DIDSA VR spike: ", _load_summary)
	_set_status("Loaded %d part mesh(es). Grip a part to grab it." % _part_count)


func list_model_files() -> PackedStringArray:
	## .glb/.gltf files the tablet's Files tab offers: res://models (next to
	## the project, for running from the editor) and user://models (which also
	## works in an exported build).
	var found := PackedStringArray()
	for dir_path in ["res://models", "user://models"]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file_name in dir.get_files():
			if file_name.get_extension().to_lower() in ["glb", "gltf"]:
				found.append(dir_path.path_join(file_name))
	return found


func load_glb_file(path: String) -> void:
	## Load a bare .glb/.gltf straight from disk — no backend round trip.
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return
	var started_ms := Time.get_ticks_msec()
	var bytes := FileAccess.get_file_as_bytes(path)
	if not _show_model(bytes, path.get_base_dir(), local_glb_scale):
		return
	_load_summary = "load: %s, %d KB, %d ms" % [path.get_file(), int(bytes.size() / 1024.0), Time.get_ticks_msec() - started_ms]
	print("DIDSA VR spike: ", _load_summary)
	_set_status("Loaded %s: %d part mesh(es)." % [path.get_file(), _part_count])


func _show_model(glb_bytes: PackedByteArray, base_path: String, scale_value: float) -> bool:
	## Parse glTF bytes and make them THE model, replacing whatever is loaded.
	## Returns false (with a status message) if it couldn't.
	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var parse_error := gltf_document.append_from_buffer(glb_bytes, base_path, gltf_state)
	if parse_error != OK:
		_set_status("glTF parse failed (error %d)" % parse_error)
		push_error("DIDSA VR spike: glTF parse failed: %d" % parse_error)
		return false

	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		_set_status("glTF parsed but produced no scene.")
		return false

	# Nothing may still hold, or have selected, a part that's about to go.
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		hand.reset_interaction()
	for old in assembly_root.get_children():
		assembly_root.remove_child(old)
		old.queue_free()

	assembly_root.add_child(scene)
	assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_value), spawn_position)
	_two_hand.set_real_life_scale(scale_value)
	_two_hand.remember_home()

	_part_count = 0
	for node in _all_descendants(scene):
		if node is MeshInstance3D:
			node.add_to_group("grabbable_parts")
			_part_count += 1
	return true


func _all_descendants(root: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child in root.get_children():
		found.append(child)
		found.append_array(_all_descendants(child))
	return found


func _set_status(text: String) -> void:
	print("DIDSA VR spike: ", text)
	if status_label:
		status_label.text = text
