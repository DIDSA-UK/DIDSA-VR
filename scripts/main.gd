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
@export var spawn_scale: float = 0.001 ## Backend native units are millimetres (see backend/app/document/models.py's
## Mate docstring), but glTF/Godot both treat raw coordinate values as metres.
## 0.001 converts mm -> m. If a part looks tiny/huge, check what units it was
## actually modelled in before touching this.

@onready var http_request: HTTPRequest = $HTTPRequest
@onready var assembly_root: Node3D = $AssemblyRoot
@onready var status_label: Label3D = $StatusLabel3D

var xr_interface: XRInterface
var _resolved_part_id: String = ""

# All endpoints below live under the backend's "/document" router prefix —
# see backend/app/document/router.py's `router = APIRouter(prefix="/document", ...)`.
const API_PREFIX := "/document"


func _ready() -> void:
	assembly_root.add_to_group("assembly_root")
	_load_secrets()
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("backend_url/api_key not set — create %s (see secrets.cfg.example)." % secrets_file_path)
		return
	_start_xr()
	http_request.request_completed.connect(_on_import_completed)
	_begin_import()


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

	_set_status("Downloaded %d KB, parsing glTF..." % int(body.size() / 1024.0))

	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var parse_error := gltf_document.append_from_buffer(body, "", gltf_state)
	if parse_error != OK:
		_set_status("glTF parse failed (error %d)" % parse_error)
		push_error("DIDSA VR spike: glTF parse failed: %d" % parse_error)
		return

	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		_set_status("glTF parsed but produced no scene.")
		return

	assembly_root.add_child(scene)
	assembly_root.position = spawn_position
	assembly_root.scale = Vector3.ONE * spawn_scale

	var mesh_count := 0
	for node in _all_descendants(scene):
		if node is MeshInstance3D:
			node.add_to_group("grabbable_parts")
			mesh_count += 1

	_set_status("Loaded %d part mesh(es). Grip a part to grab it." % mesh_count)


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
