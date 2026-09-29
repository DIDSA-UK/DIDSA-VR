extends Node3D
## Engine-choice spike: imports a saved DIDSA-CAD assembly file straight
## into the backend's "default" session, then downloads the resulting
## GET /document/parts/{part_id}/assembly-mesh.glb node-instanced glTF and
## drops it into the world so it can be grabbed with controller.gd.
##
## Setup: drop a real assembly export (a .DIDSAprt/.didsa file whose root
## Part has occurrences on it — i.e. an assembly, not a bare single part)
## into this project folder, next to project.godot, named exactly what
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
@export var relay_url: String = "" ## Loaded from secrets.cfg's [browser_relay] section - the Browser window's
## own separate service (DIDSA-CAD repo, browser-relay/), not the CAD backend above.
@export var relay_api_key: String = "" ## Matches the relay's BROWSER_RELAY_API_KEY.
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
var _load_busy := false ## true while an Open/Add/import (or the startup import) is mid-flight — see _claim_load()
var status_text: String = "" ## what _set_status() last said — console-only now (see that function): no floating 3D text in the scene, per John's own real-headset feedback that it was distracting. Kept as a plain string (not just a print) so tests/e2e_*.gd can still poll it to know when a load finished.

var xr_interface: XRInterface
var _resolved_part_id: String = ""
var command_stack := preload("res://scripts/command_stack.gd").new() ## shared undo/redo history — see command_stack.gd
var _settings := preload("res://scripts/app_settings.gd").new() ## project folder + last-picked scene — see app_settings.gd
@onready var _world_environment: WorldEnvironment = $WorldEnvironment ## Light/Dark/Mid/Passthrough — see environment_manager.gd
const MeshIdentity := preload("res://scripts/mesh_identity.gd") ## occurrence/face identity tagging for mates/measure — see mesh_identity.gd

# Perf readout (see _process): the numbers milestone 1 exists to measure
# on-headset. Timestamps are Time.get_ticks_msec() values.
var _two_hand: Node
var _tablet: Node
var _keyboard: Node
var _mates_tool: Node
var _measure_tool: Node
var _colour_tool: Node
var _section_tool: Node
var _assembly_tree_window: Node
var _calculator_window: Node
var _image_viewer_window: Node
var _browser_window: Node
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
	_settings.load_from_disk()
	assembly_root.add_to_group("assembly_root")
	_add_two_hand_model()
	_add_mates_tool()
	_add_measure_tool()
	_add_colour_tool()
	_add_section_tool()
	_add_assembly_tree_window()
	_add_calculator_window()
	_add_image_viewer_window()
	_add_browser_window()
	_add_wrist_tablet()
	_add_popup_keyboard()
	$XROrigin3D/LeftController.command_stack = command_stack
	$XROrigin3D/RightController.command_stack = command_stack
	$XROrigin3D/LeftController.mates_tool = _mates_tool
	$XROrigin3D/RightController.mates_tool = _mates_tool
	$XROrigin3D/LeftController.measure_tool = _measure_tool
	$XROrigin3D/RightController.measure_tool = _measure_tool
	$XROrigin3D/LeftController.section_tool = _section_tool
	$XROrigin3D/RightController.section_tool = _section_tool
	$XROrigin3D/LeftController.laser_select_enabled = false # real-headset feedback: left trigger-select blocked left-hand locomotion (controller.gd's is_manipulating()) — grip-grab stays on both hands, left laser is freed up for a later tool (context menu, multi-select — not decided yet)
	$XROrigin3D/RightController.button_pressed.connect(_on_right_stick_click)
	_load_secrets()
	_mates_tool.configure_backend(backend_url, api_key)
	_measure_tool.configure_backend(backend_url, api_key)
	_colour_tool.configure_backend(backend_url, api_key)
	_assembly_tree_window.configure_backend(backend_url, api_key)
	_browser_window.configure_relay(relay_url, relay_api_key)
	_start_xr()
	_world_environment.setup($DirectionalLight3D, xr_interface, get_viewport(), $Ground/MeshInstance3D.mesh.material as ShaderMaterial)
	_world_environment.set_scene(_settings.last_scene)
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("No backend configured (see secrets.cfg.example). Turn your left wrist up and use the Files tab to load a local .glb.")
		return
	http_request.request_completed.connect(_on_import_completed)
	_begin_import()


func _add_two_hand_model() -> void:
	var two_hand := preload("res://scripts/two_hand_model.gd").new()
	two_hand.name = "TwoHandModel"
	add_child(two_hand)
	two_hand.setup(assembly_root, $XROrigin3D/LeftController, $XROrigin3D/RightController, spawn_scale, command_stack)
	_two_hand = two_hand


func _add_mates_tool() -> void:
	var mates := preload("res://scripts/mates_tool.gd").new()
	mates.name = "MatesTool"
	add_child(mates)
	mates.setup(command_stack)
	_mates_tool = mates


func _add_measure_tool() -> void:
	var measure := preload("res://scripts/measure_tool.gd").new()
	measure.name = "MeasureTool"
	add_child(measure)
	_measure_tool = measure


func _add_colour_tool() -> void:
	var colours := preload("res://scripts/colour_tool.gd").new()
	colours.name = "ColourTool"
	add_child(colours)
	_colour_tool = colours


func _add_section_tool() -> void:
	var sections := preload("res://scripts/section_tool.gd").new()
	sections.name = "SectionTool"
	add_child(sections)
	sections.setup(command_stack)
	_section_tool = sections


func _add_assembly_tree_window() -> void:
	## Milestone 3: the vision brief's interactive assembly tree — browse
	## and select occurrences without laser-pointing at their geometry
	## first. See assembly_tree_window.gd's own docstring.
	var window := preload("res://scripts/assembly_tree_window.gd").new()
	window.name = "AssemblyTreeWindow"
	add_child(window)
	window.setup_tree($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, self)
	_assembly_tree_window = window


func _add_calculator_window() -> void:
	## Milestone 3's Calculator window — see calculator_window.gd's own docstring.
	var window := preload("res://scripts/calculator_window.gd").new()
	window.name = "CalculatorWindow"
	add_child(window)
	window.setup_calculator($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_calculator_window = window


func _add_image_viewer_window() -> void:
	## Milestone 3's Image Viewer window — see image_viewer_window.gd's own docstring.
	var window := preload("res://scripts/image_viewer_window.gd").new()
	window.name = "ImageViewerWindow"
	add_child(window)
	window.setup_image_viewer($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_image_viewer_window = window


func _add_browser_window() -> void:
	## Milestone 3's Browser window (and, via Chrome's own built-in PDF
	## viewer, its PDF reader too) - see browser_window.gd's own docstring.
	var window := preload("res://scripts/browser_window.gd").new()
	window.name = "BrowserWindow"
	add_child(window)
	window.setup_browser($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_browser_window = window


func _add_wrist_tablet() -> void:
	var tablet := preload("res://scripts/wrist_tablet.gd").new()
	tablet.name = "WristTablet"
	tablet.setup($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, _two_hand, $XROrigin3D, self, command_stack, _mates_tool, _colour_tool, _section_tool, _measure_tool, _assembly_tree_window, _calculator_window, _image_viewer_window, _browser_window)
	_tablet = tablet


func _add_popup_keyboard() -> void:
	## The vision brief's popup keyboard, reserved on the right thumbstick
	## click since the wrist tablet was built. First real use: typing an
	## exact scale multiple (see _on_right_stick_click below).
	var keyboard := preload("res://scripts/popup_keyboard.gd").new()
	keyboard.name = "PopupKeyboard"
	add_child(keyboard)
	keyboard.setup($XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_keyboard = keyboard


func _on_right_stick_click(action_name: String) -> void:
	if action_name != "primary_click":
		return
	if _keyboard.is_open():
		_keyboard.close()
		return
	_keyboard.open_for(_trim_number(_two_hand.current_multiple()), _on_scale_typed)


func _on_scale_typed(text: String) -> void:
	var value := text.to_float()
	if value > 0.0:
		_two_hand.set_preset(value)


func open_keyboard_for(initial_text: String, on_confirm: Callable) -> void:
	## Lets the wrist tablet's Mates tab reuse the same popup keyboard the
	## Scale tab's exact-value entry does (_on_right_stick_click above) —
	## only one thing needs it open at a time anyway.
	if _keyboard.is_open():
		_keyboard.close()
	_keyboard.open_for(initial_text, on_confirm)


func current_root_part_id() -> String:
	## The loaded assembly's own root Part id — every top-level Occurrence's
	## own owner_part_id (see mesh_identity.gd) matches this, so it's what
	## the Mates tab's "Enforce all"/mate-list refresh (and the Assembly Tree
	## window's own root fetch) operate on. Empty if nothing backend-backed
	## is loaded yet (a bare local .glb, say).
	return _resolved_part_id


# --- Tools tab (wrist_tablet.gd): hide/show all, reverse visibility, isolate.
# Shoot-to-hide itself is per-hand (controller.gd's hide_tool_active/_try_shoot_hide);
# these are the whole-assembly operations, so they live here alongside
# list_model_files()/load_glb_file() — the other model-wide API the tablet calls into.

func hide_all_parts() -> void:
	_set_all_visibility(false, "hide all")


func show_all_parts() -> void:
	_set_all_visibility(true, "show all")


func reverse_visibility() -> void:
	var parts := get_tree().get_nodes_in_group("grabbable_parts")
	if parts.is_empty():
		return
	var before := {}
	for p in parts:
		before[p] = p.visible
	for p in parts:
		p.visible = not p.visible
	_push_visibility_command("reverse visibility", before)


func isolate_selected() -> void:
	var target := current_selected_part()
	if target == null:
		return
	var parts := get_tree().get_nodes_in_group("grabbable_parts")
	var before := {}
	for p in parts:
		before[p] = p.visible
	for p in parts:
		p.visible = (p == target)
	_push_visibility_command("isolate %s" % target.name, before)


func current_selected_part() -> Node3D:
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		if hand.selected_node != null:
			return hand.selected_node
	return null


func select_part_by_occurrence_id(occurrence_id: String) -> bool:
	## The Assembly Tree window's tap-to-select (assembly_tree_window.gd):
	## finds the currently loaded mesh tagged (mesh_identity.gd) with this
	## occurrence id and selects it the same way laser-select would, via
	## RightController's select_external(). Returns false if nothing loaded
	## right now carries that id — e.g. the row is an intermediate sub-
	## assembly with no rendered geometry of its own (assembly-mesh.glb has
	## one node per placed *leaf* instance only — see mesh_identity.gd's own
	## docstring), or the occurrence is hidden.
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if node.has_meta("occurrence_id") and node.get_meta("occurrence_id") == occurrence_id and node.visible:
			$XROrigin3D/RightController.select_external(node, node.global_position)
			return true
	return false


func _set_all_visibility(vis: bool, label: String) -> void:
	var parts := get_tree().get_nodes_in_group("grabbable_parts")
	if parts.is_empty():
		return
	var before := {}
	var changed := false
	for p in parts:
		before[p] = p.visible
		if p.visible != vis:
			changed = true
	if not changed:
		return # nothing to undo if it was already all hidden/shown
	for p in parts:
		p.visible = vis
	_push_visibility_command(label, before)


func _push_visibility_command(label: String, before: Dictionary) -> void:
	var after := {}
	for p in before:
		after[p] = p.visible
	var undo_fn := func() -> void:
		for p in before:
			if is_instance_valid(p):
				p.visible = before[p]
	var redo_fn := func() -> void:
		for p in after:
			if is_instance_valid(p):
				p.visible = after[p]
	command_stack.push(label, undo_fn, redo_fn)


func _trim_number(x: float) -> String:
	return ("%.3f" % x).rstrip("0").rstrip(".")


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


# --- Environment (View > Environment tab): Light/Dark/Mid rendered presets
# plus Passthrough (OpenXR mixed reality) — see environment_manager.gd.

func available_scenes() -> Array[String]:
	return _world_environment.SCENES


func current_scene() -> String:
	return _world_environment.current_scene


func set_scene(scene_name: String) -> void:
	_world_environment.set_scene(scene_name)
	_settings.set_last_scene(scene_name)


func is_passthrough_supported() -> bool:
	return _world_environment.is_passthrough_supported()


# --- Settings page: the project folder the Files tab scans, on top of the
# built-in res://models and user://models.

func project_folder() -> String:
	return _settings.project_folder


func set_project_folder(path: String) -> void:
	_settings.set_project_folder(path)


func _process(delta: float) -> void:
	_worst_frame_ms = maxf(_worst_frame_ms, delta * 1000.0)
	if _section_tool.active: # no-ops internally when inactive, but skip the group lookup entirely when there's nothing to do
		_section_tool.reconcile(get_tree().get_nodes_in_group("grabbable_parts"))
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
	relay_url = config.get_value("browser_relay", "url", relay_url)
	relay_api_key = config.get_value("browser_relay", "api_key", relay_api_key)


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
		_load_busy = true # released by _on_mesh_completed()
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
	_load_busy = true # released by _on_import_completed() (on failure) or _on_mesh_completed()
	var error := http_request.request(url, headers, HTTPClient.METHOD_POST, raw_text)
	if error != OK:
		_load_busy = false
		_set_status("Import request failed to start (error %d)" % error)


func _on_import_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# First completion this session is always the import call; disconnect
	# and hook up the mesh-fetch handler for the second call so the same
	# HTTPRequest node can be reused sequentially.
	http_request.request_completed.disconnect(_on_import_completed)

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_load_busy = false
		_set_status("Import failed: %s" % _http_error_text(response_code, result, body))
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
	_load_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_status("Mesh load failed: %s" % _http_error_text(response_code, result, body))
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


## source_format string for each extension the backend's ImportSourceFormat
## enum accepts (backend/app/document/models.py) — "step"/"stl"/"obj" go
## through the backend's importer; glb/gltf load straight into Godot with no
## backend round trip at all (see load_glb_file()).
const _BACKEND_IMPORT_FORMATS := {"step": "step", "stp": "step", "stl": "stl", "obj": "obj"}
const _NATIVE_FORMATS := ["didsa", "didsaprt"] ## a plain JSON native save/export, either extension (see README) — same file, no format difference.

func list_model_files() -> PackedStringArray:
	## Model files the tablet's Files tab offers: res://models (next to the
	## project, for running from the editor), user://models (which also
	## works in an exported build), and the Settings page's own project
	## folder if one's been set (an arbitrary absolute path — e.g. a shared
	## network mount — DirAccess.open() isn't limited to res://user://).
	## .glb/.gltf load locally; .step/.stp/.stl/.obj need a configured
	## backend (see load_model_file()); .didsa/.DIDSAprt also need one
	## (open_native_file()/add_component_file()).
	var found := PackedStringArray()
	var extensions := ["glb", "gltf"] + _NATIVE_FORMATS + _BACKEND_IMPORT_FORMATS.keys()
	var dirs := ["res://models", "user://models"]
	if not _settings.project_folder.is_empty():
		dirs.append(_settings.project_folder)
	for dir_path in dirs:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file_name in dir.get_files():
			if file_name.get_extension().to_lower() in extensions:
				found.append(dir_path.path_join(file_name))
	return found


func load_model_file(path: String) -> void:
	## Dispatches on extension: a bare .glb/.gltf loads straight from disk;
	## .didsa/.DIDSAprt is a full-replace open of a different native file at
	## runtime (open_native_file()); .step/.stp/.stl/.obj need the backend's
	## /import-features (it's the only thing that can decode them into
	## geometry Godot can render).
	var ext := path.get_extension().to_lower()
	if ext in ["glb", "gltf"]:
		load_glb_file(path)
	elif ext in _NATIVE_FORMATS:
		open_native_file(path)
	elif ext in _BACKEND_IMPORT_FORMATS:
		_import_external_file(path, _BACKEND_IMPORT_FORMATS[ext])
	else:
		_set_status("Don't know how to load %s (extension .%s)" % [path.get_file(), ext])


var _native_root_id_cache: Dictionary = {} ## path -> {"mtime": int, "id": String}

func native_file_root_part_id(path: String) -> String:
	## The root Part id a native .didsa/.DIDSAprt file would load as (its
	## document.root_part_id, else its first Part — the backend's own fallback),
	## or "" if unreadable. Quiet (no status message): the Files tab uses it to
	## hide "Add" on the file that IS the loaded root, since the backend rejects
	## that with 422 "Cannot insert a Part into itself". Cached per file mtime.
	var mtime := FileAccess.get_modified_time(path)
	var cached = _native_root_id_cache.get(path)
	if cached != null and cached["mtime"] == mtime:
		return cached["id"]
	var found := ""
	if not FileAccess.file_exists(path):
		return found
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary and parsed.get("document") is Dictionary:
		var document: Dictionary = parsed["document"]
		found = str(document.get("root_part_id", ""))
		if found.is_empty() and document.get("parts") is Array and not (document["parts"] as Array).is_empty():
			var first = document["parts"][0]
			if first is Dictionary:
				found = str(first.get("id", ""))
	_native_root_id_cache[path] = {"mtime": mtime, "id": found}
	return found


func _read_native_json(path: String) -> Variant:
	## Shared by open_native_file()/add_component_file(): reads and JSON-
	## parses a local native file, or null (having already set the status)
	## if it can't. Same parse this scene already does for native_file_path
	## at startup (_begin_import()), factored out so both new runtime paths
	## share it instead of duplicating the read-and-parse boilerplate.
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	var raw_text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(raw_text)
	if parsed == null or not (parsed is Dictionary):
		_set_status("Couldn't parse %s as JSON — is it a real exported .didsa/.DIDSAprt file?" % path.get_file())
		return null
	return parsed


func open_native_file(path: String) -> void:
	if not _claim_load("Open"):
		return
	await _open_native_file_impl(path)
	_load_busy = false


func _open_native_file_impl(path: String) -> void:
	## Files tab "Open": a full-replace load of a different native .didsa/
	## .DIDSAprt file at runtime — mirrors _begin_import()'s startup flow
	## (import, then fetch+render), just callable at any time and from an
	## arbitrary path/root_part_id instead of the fixed native_file_path
	## this scene started with. Closes the first half of the "no in-VR way
	## to open a different native file" gap — see docs/status.md's "Real-
	## headset testing round 2" (mates blocker). The other half is
	## add_component_file() below, for adding rather than replacing.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("Open needs a backend (see secrets.cfg.example).")
		return
	var parsed = _read_native_json(path)
	if parsed == null:
		return
	var document_dict: Dictionary = parsed.get("document", {})
	var root_part_id: String = str(document_dict.get("root_part_id", ""))
	if root_part_id.is_empty():
		_set_status("%s has no document.root_part_id — can't tell which Part to load." % path.get_file())
		return

	var req := HTTPRequest.new() # a separate node from http_request, which is spoken for by the startup import chain
	add_child(req)
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
	_set_status("Importing %s (part %s)..." % [path.get_file(), root_part_id])
	req.request("%s%s/import/native" % [backend_url, API_PREFIX], headers, HTTPClient.METHOD_POST, JSON.stringify(parsed))
	var import_result: Array = await req.request_completed
	if _parse_import_response(import_result, "import %s" % path.get_file(), req) == null:
		return

	_resolved_part_id = root_part_id
	_set_status("Imported. Fetching assembly mesh...")
	var mesh_url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [
		backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()
	]
	if tier != "":
		mesh_url += "&tier=%s" % tier
	var mesh_result: Array = await _get_mesh_result(req, mesh_url)
	req.queue_free()
	var mesh_result_code: int = mesh_result[0]
	var mesh_response_code: int = mesh_result[1]
	var mesh_body: PackedByteArray = mesh_result[3]
	if mesh_result_code != HTTPRequest.RESULT_SUCCESS or mesh_response_code != 200:
		_set_status("Mesh load for %s failed: %s" % [path.get_file(), _http_error_text(mesh_response_code, mesh_result_code, mesh_body)])
		return
	if not _show_model(mesh_body, "", spawn_scale):
		return
	_set_status("Opened %s: %d part mesh(es)." % [path.get_file(), _part_count])


func add_component_file(path: String) -> void:
	if not _claim_load("Add"):
		return
	await _add_component_file_impl(path)
	_load_busy = false


func _add_component_file_impl(path: String) -> void:
	## Files tab "Add": merges a second native file's own Part into the
	## *currently loaded* assembly's root Part as a new Occurrence, via the
	## backend's POST /parts/{root_id}/add-component
	## (backend/app/document/add_component.py, ported from the Flutter
	## client's own add_component.dart) — unlike open_native_file() above,
	## this does NOT replace the loaded scene; it adds to the live session
	## and re-fetches the assembly mesh to show the result. Needs a
	## currently backend-loaded assembly (current_root_part_id() non-empty)
	## — there's nothing to add an Occurrence onto otherwise. This is what
	## finally gives the Mates tool real Occurrences to test against on a
	## single-Part test file — see docs/status.md's "Real-headset testing
	## round 2" for the blocker this closes.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("Add needs a backend (see secrets.cfg.example).")
		return
	if _resolved_part_id.is_empty():
		_set_status("Load a backend-hosted assembly first — nothing to add %s onto." % path.get_file())
		return
	var parsed = _read_native_json(path)
	if parsed == null:
		return

	var req := HTTPRequest.new()
	add_child(req)
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
	_set_status("Adding %s to the assembly..." % path.get_file())
	req.request(
		"%s%s/parts/%s/add-component" % [backend_url, API_PREFIX, _resolved_part_id], headers,
		HTTPClient.METHOD_POST, JSON.stringify({"component": parsed})
	)
	var add_result: Array = await req.request_completed
	if _parse_import_response(add_result, "add %s to the assembly" % path.get_file(), req) == null:
		return

	_set_status("Added. Refreshing assembly mesh...")
	var mesh_url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [
		backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()
	]
	if tier != "":
		mesh_url += "&tier=%s" % tier
	var mesh_result: Array = await _get_mesh_result(req, mesh_url)
	req.queue_free()
	var mesh_result_code: int = mesh_result[0]
	var mesh_response_code: int = mesh_result[1]
	var mesh_body: PackedByteArray = mesh_result[3]
	if mesh_result_code != HTTPRequest.RESULT_SUCCESS or mesh_response_code != 200:
		_set_status("Mesh refresh after adding %s failed: %s" % [path.get_file(), _http_error_text(mesh_response_code, mesh_result_code, mesh_body)])
		return
	if not _show_model(mesh_body, "", spawn_scale):
		return
	_set_status("Added %s. %d part mesh(es) now in the assembly." % [path.get_file(), _part_count])


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


func _import_external_file(path: String, source_format: String) -> void:
	if not _claim_load("the import"):
		return
	await _import_external_file_impl(path, source_format)
	_load_busy = false


func _import_external_file_impl(path: String, source_format: String) -> void:
	## STEP/STL/OBJ, milestone 1's last "done when" item: the backend has no
	## bare "view this file" endpoint for these, so this creates a fresh Part
	## (POST /parts), imports the file into it as a fixed Body
	## (POST /parts/{id}/import-features), then fetches and renders it the
	## same way as any other backend part (GET .../assembly-mesh.glb) —
	## mirrors _begin_import()/_fetch_mesh()'s two-step flow, just starting
	## from a local file instead of a native document, and with a "create
	## part" step first since there's no existing part to import into.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("%s needs a backend (see secrets.cfg.example) — STEP/STL/OBJ can't be read without one." % path.get_file())
		return
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return

	var started_ms := Time.get_ticks_msec()
	_set_status("Reading %s..." % path.get_file())
	var bytes := FileAccess.get_file_as_bytes(path)
	var data_b64 := Marshalls.raw_to_base64(bytes)

	var req := HTTPRequest.new() # a separate node from http_request, which is spoken for by the startup import chain
	add_child(req)
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]

	_set_status("Creating a part for %s..." % path.get_file())
	req.request(backend_url + API_PREFIX + "/parts", headers, HTTPClient.METHOD_POST, JSON.stringify({"name": path.get_file().get_basename()}))
	var create_result: Array = await req.request_completed
	var part_json = _parse_import_response(create_result, "create a part for %s" % path.get_file(), req)
	if part_json == null:
		return
	var new_part_id: String = part_json.get("id", "")
	if new_part_id.is_empty():
		_set_status("Create-part response for %s had no id." % path.get_file())
		req.queue_free()
		return
	_resolved_part_id = new_part_id # so a later Files-tab "Add" has something to add onto, same as a native open

	_set_status("Importing %s (part %s)..." % [path.get_file(), new_part_id])
	req.request(
		backend_url + API_PREFIX + "/parts/%s/import-features" % new_part_id, headers, HTTPClient.METHOD_POST,
		JSON.stringify({"source_format": source_format, "data_base64": data_b64})
	)
	var import_result: Array = await req.request_completed
	if _parse_import_response(import_result, "import %s into part %s" % [path.get_file(), new_part_id], req) == null:
		return

	_set_status("Imported. Fetching mesh...")
	var mesh_url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=false" % [backend_url, API_PREFIX, new_part_id, str(quality)]
	var mesh_result: Array = await _get_mesh_result(req, mesh_url)
	req.queue_free()
	var mesh_result_code: int = mesh_result[0]
	var mesh_response_code: int = mesh_result[1]
	var mesh_body: PackedByteArray = mesh_result[3]
	if mesh_result_code != HTTPRequest.RESULT_SUCCESS or mesh_response_code != 200:
		_set_status("Mesh fetch for %s failed: %s" % [path.get_file(), _http_error_text(mesh_response_code, mesh_result_code, mesh_body)])
		return

	_set_status("Downloaded %d KB, parsing glTF..." % int(mesh_body.size() / 1024.0))
	if not _show_model(mesh_body, "", spawn_scale): # backend units are mm regardless of the source format — spawn_scale, not local_glb_scale
		return
	_load_summary = "load: %s (%s, via backend), %d KB, %d ms" % [path.get_file(), source_format, int(mesh_body.size() / 1024.0), Time.get_ticks_msec() - started_ms]
	print("DIDSA VR spike: ", _load_summary)
	_set_status("Loaded %s: %d part mesh(es)." % [path.get_file(), _part_count])


func _http_error_text(response_code: int, result_code: int, body: PackedByteArray) -> String:
	## "HTTP 422 (result 0): Cannot insert a Part into itself" — the backend's
	## own FastAPI `detail` is what says WHY, and the tablet's Files status
	## label is the only place it can be read from inside a headset.
	var text := "HTTP %d (result %d)" % [response_code, result_code]
	if body.size() > 0:
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary and parsed.has("detail"):
			var detail = parsed["detail"]
			text += ": %s" % (detail if detail is String else JSON.stringify(detail))
	return text


func _get_mesh_result(req: HTTPRequest, url: String) -> Array:
	## GETs an assembly-mesh.glb, retrying ONCE after a 5xx (the backend keeps a
	## single global in-memory Document, so a request that overlaps another
	## client's import/add can 500 transiently). The failing body is logged so
	## a repeat is diagnosable from the console.
	var result: Array = []
	for attempt in 2:
		req.request(url, ["X-API-Key: %s" % api_key], HTTPClient.METHOD_GET)
		result = await req.request_completed
		if attempt == 0 and result[0] == HTTPRequest.RESULT_SUCCESS and int(result[1]) >= 500:
			push_error("DIDSA VR: assembly-mesh.glb fetch got HTTP %d, retrying once: %s" % [result[1], (result[3] as PackedByteArray).get_string_from_utf8().left(300)])
			await get_tree().create_timer(0.6).timeout
			continue
		break
	return result


func _claim_load(what: String) -> bool:
	## Open / Add / STEP-import each replace or mutate the backend's ONE global
	## Document across several awaited round trips, and each was an un-guarded
	## coroutine — a second tap (or a tap while the startup import was still in
	## flight) interleaved with the first and could 500 it or leave the session
	## in a state the client no longer matched (real-headset report: HTTP 500,
	## fixed by restarting). One at a time.
	if _load_busy:
		_set_status("Busy: still working on the previous file — try %s again in a moment." % what)
		return false
	_load_busy = true
	return true


func _parse_import_response(result: Array, step_description: String, req: HTTPRequest):
	## Common HTTP-result/JSON-parse checking for _import_external_file()'s
	## three sequential calls. Returns the parsed JSON Dictionary on success,
	## or null (having already set the status and freed req) on any failure.
	var result_code: int = result[0]
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 201):
		_set_status("Couldn't %s: %s" % [step_description, _http_error_text(response_code, result_code, body)])
		push_error("DIDSA VR spike: %s failed: result=%d code=%d body=%s" % [step_description, result_code, response_code, body.get_string_from_utf8()])
		req.queue_free()
		return null
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary):
		_set_status("Couldn't parse the response for: %s" % step_description)
		req.queue_free()
		return null
	return parsed


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
	MeshIdentity.tag_scene(gltf_state, scene) # occurrence/face identity for the mates/measure tools - see mesh_identity.gd

	# Nothing may still hold, or have selected, a part that's about to go —
	# and the undo/redo history can't point at nodes that are about to be freed.
	command_stack.clear()
	_mates_tool.clear_picks()
	_section_tool.reset() # drops its stale per-part tracking before they're freed below; the gizmo/active state stay put — see that script's own reset() docstring
	_assembly_tree_window.mark_stale() # the Occurrence tree it's shown is about to point at parts that no longer exist — see that script's own mark_stale()
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
			node.create_trimesh_collision() # so controller.gd's laser-select can ray-test real geometry
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
	status_text = text
