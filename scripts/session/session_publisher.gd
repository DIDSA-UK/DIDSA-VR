extends Node
## The PRESENTER's half of a live session: turns what the world does into the messages the hub relays to observers (DIDSA-CAD docs/live-sessions-scope.md, section 4.3).
## It watches; it never changes the world. What it sends, and what it watches:
##   poses        every part of the model, in model space (mm): a FULL table after a load, a refetch and a resume, then only what moved. A hot set (a held part, a part that just
##                moved, a mates glide, a sync) is read at 30 Hz; every part is read at 5 Hz to catch whatever nothing announced (undo, a scene, a group, a glide). Cheap when still.
##   visibility   the full list of parts the presenter has hidden (hide, isolate, a scene), not counting what a room or the design table hid for their own reasons
##   section      the presenter's one clip plane, in model space
##   place        the model's place and scale (assembly_root's transform, metres): the shared place, decision LS-6
##   status       what they are doing: the model, the design table (and the part), a room
##   doc_changed  the backend document changed: the revision from X-Document-Revision (document_revision.gd), the parts whose mesh was swapped or `all`
##   model        another model was opened while hosting
## The hooks the audit names (docs/main-gd-split-audit.md, section 4): controller.gd's grab and _sync_pose and the mates glide call `on_parts_moving` (the "session_listeners"
## group); main.gd's swap_part_mesh / reload_world_model / _show_model emit `session_doc_changed` / `session_model_changed`; the section tool, the model's place and the design
## table's state are read.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const DocumentRevision := preload("res://scripts/session/document_revision.gd")
const BackendSession := preload("res://scripts/backend_session.gd")

const HOT_HZ := 30.0
const SCAN_HZ := 5.0
const STATE_HZ := 5.0
const HOT_SECONDS := 1.5
const MAX_MESSAGE_BYTES := 48000 ## the hub refuses a message over 64 KB: a big pose table goes in several
const DOC_DEBOUNCE_S := 0.25 ## swaps and reloads that come together are one doc_changed
const MODEL_DEBOUNCE_S := 0.3 ## after a load: the load's own bookkeeping (a demo's path, the root id) settles first
const BIG_MODEL := 3000 ## parts: the full scan slows to 2 Hz

var main: Node
var client: Node
var http: Node
var source: Dictionary = {}
var shareable := true ## the model on show can be shared (a backend document or a demo)
var sent: Dictionary = {} ## counts by message type, for tests and the monolith
var last_rev_sent := 0

var _active := false
var _unit_mm := 1.0
var _scene_root: Node3D
var _nodes: Dictionary = {} ## key -> MeshInstance3D
var _keys: Dictionary = {} ## node instance id -> key
var _last_xf: Dictionary = {} ## key -> the Transform3D last sent
var _hot: Dictionary = {} ## key -> msec it last moved
var _last_hidden: Array = []
var _last_section: Dictionary = {}
var _last_place: Array = []
var _last_status: Dictionary = {}
var _acc_hot := 0.0
var _acc_scan := 0.0
var _acc_state := 0.0
var _pending_parts: Dictionary = {}
var _pending_all := false
var _pending_doc_at := -1.0
var _pending_model_at := -1.0
var _clock := 0.0
var _flushing := false


func start(p_main: Node, p_client: Node, p_source: Dictionary, p_http: Node = null) -> void:
	main = p_main
	client = p_client
	http = p_http
	source = p_source
	_active = true
	shareable = true
	last_rev_sent = int(source.get("rev", 0))
	sent.clear()
	add_to_group("session_listeners")
	if not client.welcomed.is_connected(_on_welcomed):
		client.welcomed.connect(_on_welcomed)
	if not main.session_doc_changed.is_connected(_on_doc_changed):
		main.session_doc_changed.connect(_on_doc_changed)
		main.session_model_changed.connect(_on_model_changed)
	publish_all()


func stop() -> void:
	_active = false
	remove_from_group("session_listeners")
	if main != null and main.session_doc_changed.is_connected(_on_doc_changed):
		main.session_doc_changed.disconnect(_on_doc_changed)
		main.session_model_changed.disconnect(_on_model_changed)
	if client != null and client.welcomed.is_connected(_on_welcomed):
		client.welcomed.disconnect(_on_welcomed)


# --- Hooks ----------------------------------------------------------------------------------------------------------------------

func on_parts_moving(nodes: Array) -> void:
	## A grab, a glide or a pose sync began: these parts are read at the fast rate for the next moments (called through the "session_listeners" group).
	var now := Time.get_ticks_msec()
	for node in nodes:
		var key = _keys.get((node as Object).get_instance_id()) if is_instance_valid(node) else null
		if key != null:
			_hot[key] = now


func _on_welcomed(_welcome: Dictionary, resumed: bool) -> void:
	if resumed:
		publish_all() # back after a drop: the full state again (the scope: a resumed connection sends the full pose table)


func _on_doc_changed(parts: Array, all: bool) -> void:
	if not _active or not shareable:
		return
	for pid in parts:
		_pending_parts[str(pid)] = true
	_pending_all = _pending_all or all
	if _pending_doc_at < 0.0:
		_pending_doc_at = _clock


func _on_model_changed(reloading: bool) -> void:
	if not _active or reloading:
		return # (a reload of the same document is a doc_changed: the caller says so after it)
	_pending_model_at = _clock


# --- Sending everything ---------------------------------------------------------------------------------------------------------

func publish_all() -> void:
	## The presenter's whole state: place, section, visibility, status, then the full pose table.
	if not _active or not client.is_live():
		return
	_index()
	if not shareable:
		return
	_last_place = []
	_last_section = {}
	_last_status = {}
	_last_hidden = []
	_send_place(true)
	_send_section(true)
	_send_visibility(true)
	_send_status(true)
	_send_full_poses()


func _index() -> void:
	## Which nodes are the model's parts and what each is called on the wire (the glb's instance_path; for a glb without one, its path from the scene root).
	_nodes.clear()
	_keys.clear()
	_last_xf.clear()
	_hot.clear()
	var current: Dictionary = main.session_current_source()
	shareable = not current.is_empty()
	if not shareable:
		return
	source = current
	_scene_root = main.session_scene_root()
	_unit_mm = 1000.0 if source.get("kind", "") == "demo" else 1.0 # a demo glb is in metres, the wire is millimetres
	if _scene_root == null:
		return
	for node in main.session_world_parts():
		var key := part_key(node, _scene_root)
		if _nodes.has(key):
			continue
		_nodes[key] = node
		_keys[node.get_instance_id()] = key


static func part_key(node: Node, scene_root: Node) -> String:
	## What a part is called on the wire: the glb's `instance_path` (unique per placed instance, pattern copies included), else its path below the scene root.
	if node.has_meta("instance_path"):
		return str(node.get_meta("instance_path"))
	return str(scene_root.get_path_to(node)) if scene_root != null else node.name


func model_xf(node: Node3D) -> Transform3D:
	## The part's transform relative to the glb root, in the glb's own units.
	return _scene_root.global_transform.affine_inverse() * node.global_transform


# --- The clock ------------------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active or main == null or not client.is_live():
		return
	_clock += delta
	if _pending_model_at >= 0.0 and _clock - _pending_model_at >= MODEL_DEBOUNCE_S:
		_pending_model_at = -1.0
		_send_model()
	if _pending_doc_at >= 0.0 and _clock - _pending_doc_at >= DOC_DEBOUNCE_S and not _flushing:
		_flush_doc_changed()
	if not shareable or _scene_root == null or not is_instance_valid(_scene_root):
		return
	for hand in main.session_hands():
		var held = hand.get("held_node")
		if held != null and is_instance_valid(held):
			on_parts_moving([held])
		var selected = hand.get("selected_node")
		if selected != null and is_instance_valid(selected):
			on_parts_moving([selected]) # (the stick and A / B turn and push the laser-selected part)
	_acc_hot += delta
	_acc_scan += delta
	_acc_state += delta
	if _acc_hot >= 1.0 / HOT_HZ:
		_acc_hot = 0.0
		if not _hot.is_empty():
			_poll(_hot.keys())
	var scan_every := 1.0 / (SCAN_HZ if _nodes.size() < BIG_MODEL else 2.0)
	if _acc_scan >= scan_every:
		_acc_scan = 0.0
		_poll(_nodes.keys())
		_send_visibility(false)
	if _acc_state >= 1.0 / STATE_HZ:
		_acc_state = 0.0
		_send_place(false)
		_send_section(false)
		_send_status(false)


func _poll(keys: Array) -> void:
	var changed: Array = []
	var now := Time.get_ticks_msec()
	for key in keys:
		var node: Node3D = _nodes.get(key)
		if node == null or not is_instance_valid(node):
			continue
		var xf := model_xf(node)
		if not _last_xf.has(key) or not xf.is_equal_approx(_last_xf[key]):
			_last_xf[key] = xf
			_hot[key] = now
			changed.append({"path": key, "xf": Protocol.xf_to_array(xf, _unit_mm)})
	for key in _hot.keys():
		if now - int(_hot[key]) > HOT_SECONDS * 1000.0:
			_hot.erase(key)
	_send_pose_items(changed, false)


func _send_full_poses() -> void:
	var items: Array = []
	for key in _nodes:
		var node: Node3D = _nodes[key]
		if is_instance_valid(node):
			var xf := model_xf(node)
			_last_xf[key] = xf
			items.append({"path": key, "xf": Protocol.xf_to_array(xf, _unit_mm)})
	_send_pose_items(items, true)


func _send_pose_items(items: Array, full: bool) -> void:
	## One message, or several when the table is big (each under the hub's 64 KB): the first is `full` (it replaces the table), the rest add to it.
	if items.is_empty() and not full:
		return
	var chunk: Array = []
	var bytes := 0
	var first := true
	for item in items:
		var size := JSON.stringify(item).length() + 1
		if bytes + size > MAX_MESSAGE_BYTES and not chunk.is_empty():
			_send("poses", {"full": full and first, "items": chunk})
			first = false
			chunk = []
			bytes = 0
		chunk.append(item)
		bytes += size
	_send("poses", {"full": full and first, "items": chunk})


func _send_visibility(force: bool) -> void:
	var excluded: Array = main.session_hidden_exclusions()
	var hidden: Array = []
	for key in _nodes:
		var node: Node3D = _nodes[key]
		if is_instance_valid(node) and not node.visible and not excluded.has(node):
			hidden.append(key)
	hidden.sort()
	if force or hidden != _last_hidden:
		_last_hidden = hidden
		_send("visibility", {"hidden": hidden})


func _send_place(force: bool) -> void:
	var root: Node3D = main.assembly_root
	var xf := Protocol.place_to_array(root.transform)
	if force or not _same_numbers(xf, _last_place, 1e-6):
		_last_place = xf
		_send("place", {"xf": xf})


func _send_section(force: bool) -> void:
	var plane: Dictionary = main.session_section_plane() # {on, origin (world), normal (world)}
	var message := {"on": false}
	if bool(plane["on"]) and _scene_root != null:
		var inverse := _scene_root.global_transform.affine_inverse()
		var point := (inverse * (plane["origin"] as Vector3)) * _unit_mm
		var normal := (inverse.basis * (plane["normal"] as Vector3)).normalized()
		message = {"on": true, "point": [snappedf(point.x, 0.01), snappedf(point.y, 0.01), snappedf(point.z, 0.01)],
			"normal": [snappedf(normal.x, 1e-4), snappedf(normal.y, 1e-4), snappedf(normal.z, 1e-4)]}
	if force or JSON.stringify(message) != JSON.stringify(_last_section):
		_last_section = message
		_send("section", message)


func _send_status(force: bool) -> void:
	var status: Dictionary = main.session_activity()
	if force or JSON.stringify(status) != JSON.stringify(_last_status):
		_last_status = status
		_send("status", status)


func _send_model() -> void:
	## Another model was opened while hosting.
	var current: Dictionary = main.session_current_source()
	if current.is_empty():
		shareable = false
		_send("status", {"activity": "files", "detail": "Showing a file that cannot be shared"})
		return
	DocumentRevision.latest = maxi(DocumentRevision.latest, 0)
	current["rev"] = maxi(DocumentRevision.latest, int(current.get("rev", 0)))
	var title: String = str(main.session.model.get("title", ""))
	_send("model", {"source": current, "title": title, "rev": int(current.get("rev", 0))})
	source = current
	publish_all()


func _flush_doc_changed() -> void:
	## The document changed: the revision (read off the presenter's own responses, or asked for once), then one doc_changed for everything that came together.
	_flushing = true
	var parts := _pending_parts.keys()
	var all := _pending_all
	_pending_parts = {}
	_pending_all = false
	_pending_doc_at = -1.0
	var rev := await current_revision()
	var message := {"rev": rev}
	if all:
		message["all"] = true
	else:
		message["parts"] = parts
	last_rev_sent = maxi(last_rev_sent, rev)
	if client.is_live():
		_send("doc_changed", message)
		if all:
			_index() # (the model was rebuilt: the new nodes)
			_send_full_poses() # the full table after a refetch: observers apply it after their own
			_send_visibility(true)
	_flushing = false


func current_revision() -> int:
	## The latest X-Document-Revision seen; when nothing newer than the last one sent was seen, one cheap probe (a GET that answers 404 and still carries the header).
	if DocumentRevision.latest > last_rev_sent:
		return DocumentRevision.latest
	if http == null or not main.has_backend():
		return maxi(DocumentRevision.latest, last_rev_sent)
	var response: Dictionary = await http.call_http(HTTPClient.METHOD_GET, "%s/document/view-state" % main.backend_url.rstrip("/"), BackendSession.headers(main.api_key))
	DocumentRevision.note(response.get("headers", []))
	return maxi(DocumentRevision.latest, last_rev_sent)


func _send(kind: String, fields: Dictionary) -> void:
	var message := {"t": kind}
	message.merge(fields)
	if client.send_state(message):
		sent[kind] = int(sent.get(kind, 0)) + 1


func _same_numbers(a: Array, b: Array, tolerance: float) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(float(a[i]) - float(b[i])) > tolerance:
			return false
	return true
