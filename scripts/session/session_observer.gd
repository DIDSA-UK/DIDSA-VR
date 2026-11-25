extends Node
## An OBSERVER's half of a live session: shows what the presenter shows (DIDSA-CAD docs/live-sessions-scope.md, sections 4.3, 4.7, 4.8 and 5).
##   - the model: a backend document is fetched as the presenter's assembly-mesh.glb with the VIEW TOKEN only (never the CAD key, never a document session), and a refetch sends
##     If-None-Match with the last ETag (a 304 changes nothing); a demo model is loaded from the same path in the APK. A 401 means the token is no good: the hub's current one
##     is read again by resuming (an observer has no message to ask the presenter with), and the fetch is tried once more.
##   - the stream: poses (smoothed, one interval behind, by the hub's `at`), visibility, the section plane, the model's place and scale, the status line, `doc_changed` (queued while a
##     fetch is running; the newest revision wins; only the parts named are refetched unless `all`), `model` (another model), and the snapshot of a late joiner or a resume.
## An observer never edits: the tools are off (main.gd `apply_session_role`) and nothing here sends anything but presence.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const Http := preload("res://scripts/session/session_http.gd")
const Publisher := preload("res://scripts/session/session_publisher.gd")

const POSE_DELAY_MS := 35.0 ## poses are shown one pose interval (30 Hz) behind the newest
const SNAP_GAP_MS := 500.0 ## two samples further apart than this: no tween, snap
const TOKEN_WAIT_S := 8.0
const STATE_KINDS: Array[String] = ["poses", "visibility", "section", "place", "status", "scene", "gather", "model", "doc_changed"]

signal model_ready()
signal model_failed(text: String)
signal status_changed(text: String)

var main: Node
var client: Node
var http: Node
var own_view: Node ## session_own_view.gd (P4): what this person has changed in their own view, which the presenter's messages must not undo
var remote_section_on := false ## the section tool is showing the PRESENTER's cut (a cut the tool shows with this false is this person's own)
var active := false
var model_source: Dictionary = {}
var title := ""
var loaded_rev := 0
var status_text := ""
var fetch_count := 0 ## glb requests made (a test reads it)
var not_modified_count := 0
var last_error := ""
var requests: Array = [] ## [{url, headers}] of every glb request this observer made (tests check that no X-API-Key went out)

var _unit_mm := 1.0
var _scene_root: Node3D
var _nodes: Dictionary = {} ## key -> MeshInstance3D
var _tracks: Dictionary = {} ## key -> {a: {at, xf}, b: {at, xf}} (xf in the glb's units)
var _latest: Dictionary = {} ## key -> the last Transform3D received (re-applied after a refetch)
var _applied_seq: Dictionary = {}
var _offset_ms := 0.0
var _have_offset := false
var _etags: Dictionary = {} ## request url -> ETag
var _busy := false
var _queue_all := false
var _queue_parts: Dictionary = {}
var _queue_rev := 0
var _hidden: Array = []
var _presenter_hidden: Dictionary = {} ## key -> true: what the presenter's list last said (so a new list is applied as CHANGES: what this person hid or showed stays)
var _initial: Dictionary = {} ## key -> the part's pose in the glb as loaded (where Reset puts a part the presenter never moved)
var _section: Dictionary = {"on": false}
var _loading := false ## a model is being fetched and put in: state that arrives meanwhile has no nodes to go to (and the load resets the place), so it is held and replayed
var _held_messages: Array = []
var _place := Transform3D.IDENTITY ## the presenter's latest place (re-applied after a refetch, which restarts the model at its default)
var _have_place := false


func start(p_main: Node, p_client: Node, p_http: Node, p_own_view: Node = null) -> void:
	main = p_main
	client = p_client
	http = p_http
	own_view = p_own_view
	remote_section_on = false
	_presenter_hidden = {}
	_initial = {}
	active = true
	last_error = ""
	_etags.clear()
	requests.clear()
	_applied_seq.clear()
	_tracks.clear()
	_latest.clear()
	_held_messages.clear()
	_have_place = false
	if not client.message_received.is_connected(_on_message):
		client.message_received.connect(_on_message)
		client.welcomed.connect(_on_welcomed)
		client.presenter_resumed.connect(_on_presenter_resumed)
	_load_from_snapshot(client.snapshot)


func stop() -> void:
	active = false
	if client != null and client.message_received.is_connected(_on_message):
		client.message_received.disconnect(_on_message)
		client.welcomed.disconnect(_on_welcomed)
		client.presenter_resumed.disconnect(_on_presenter_resumed)
	_tracks.clear()
	_latest.clear()
	_nodes.clear()
	_initial.clear()
	_presenter_hidden = {}
	remote_section_on = false
	_scene_root = null
	model_source = {}
	loaded_rev = 0


# --- The model ------------------------------------------------------------------------------------------------------------------

func _on_welcomed(_welcome: Dictionary, resumed: bool) -> void:
	if not resumed or not active:
		return
	var snapshot: Dictionary = client.snapshot
	var model = snapshot.get("model")
	if model is Dictionary and _model_differs(model):
		_load_from_snapshot(snapshot) # the presenter opened something else while this connection was down
		return
	_apply_snapshot(snapshot, false) # (a resume: what this person changed in their own view is kept)
	if int(snapshot.get("rev", 0) if snapshot.get("rev") != null else 0) > loaded_rev:
		_queue_doc(int(snapshot["rev"]), [], true)


func _on_presenter_resumed() -> void:
	## The presenter's new connection numbers its messages from 1 again: what was applied under the old numbers must not make the new ones look old.
	_applied_seq.clear()


func _model_differs(model: Dictionary) -> bool:
	return str(model.get("kind", "")) != str(model_source.get("kind", "")) or str(model.get("root_part_id", "")) != str(model_source.get("root_part_id", "")) or str(model.get("path", "")) != str(model_source.get("path", ""))


func _load_from_snapshot(snapshot: Dictionary) -> void:
	var model = snapshot.get("model")
	if not (model is Dictionary) or (model as Dictionary).is_empty():
		_fail("The presenter has not opened a model yet.")
		return
	title = str((model as Dictionary).get("title", ""))
	_loading = true
	var shown := await _show(model)
	if shown and active:
		_apply_snapshot(snapshot)
		var rev = snapshot.get("rev")
		loaded_rev = int(rev) if rev != null else int((model as Dictionary).get("rev", 0))
	_loading = false
	_replay_held()
	if shown and active:
		model_ready.emit()


func _show(model: Dictionary) -> bool:
	## Loads `model` as THE model here. True when it is on show.
	model_source = model.duplicate()
	var kind := str(model.get("kind", ""))
	if kind == "demo":
		var path := str(model.get("path", ""))
		if not path.begins_with("res://demo/") or not FileAccess.file_exists(path):
			return _fail("This version of the app does not have the demo model the presenter opened (%s)." % path.get_file())
		_unit_mm = 1000.0
		if not main.session_show_demo(path):
			return _fail("That demo model could not be read.")
	elif kind == "backend":
		var fetched := await _fetch_glb(str(model.get("root_part_id", "")), model)
		if not fetched["ok"]:
			return _fail(str(fetched["error"]))
		if not bool(fetched["changed"]):
			return _fail("The server answered 304 to a first load.")
		_unit_mm = 1.0
		if not main.session_show_model(fetched["bytes"]):
			return _fail("The presenter's model could not be read.")
	else:
		return _fail("The presenter is showing something this version does not know how to show.")
	_index()
	return true


func _index() -> void:
	_nodes.clear()
	_initial.clear()
	_scene_root = main.session_scene_root()
	if _scene_root == null:
		return
	var inverse := _scene_root.global_transform.affine_inverse()
	for node in main.session_world_parts():
		var key := Publisher.part_key(node, _scene_root)
		_nodes[key] = node
		_initial[key] = inverse * (node as Node3D).global_transform
	if own_view != null:
		own_view.on_model_indexed()


func _fail(text: String) -> bool:
	last_error = text
	main.say(text)
	model_failed.emit(text)
	return false


# --- Fetching the glb -----------------------------------------------------------------------------------------------------------

func glb_url(part_id: String, model: Dictionary) -> String:
	var url := "%s/document/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=false" % [client.backend_url.rstrip("/"), part_id, str(model.get("quality", 0.5))]
	var tier := str(model.get("tier", "full"))
	if tier != "" and tier != "full":
		url += "&tier=%s" % tier
	return url


func _fetch_glb(part_id: String, model: Dictionary) -> Dictionary:
	## {ok, changed, bytes, error}: the part's assembly-mesh.glb with X-View-Token only. If-None-Match with the ETag of the last answer for the same request. 401: read the hub's
	## current token (by resuming) and try again once.
	if client.backend_url == "" or client.view_token == "":
		return {"ok": false, "changed": false, "bytes": PackedByteArray(), "error": "The session did not give a way to fetch the model."}
	var url := glb_url(part_id, model)
	for attempt in 2:
		var token: String = client.view_token
		var headers: Array = ["X-View-Token: %s" % token]
		if _etags.has(url):
			headers.append("If-None-Match: %s" % _etags[url])
		requests.append({"url": url, "headers": headers.duplicate()})
		fetch_count += 1
		var response: Dictionary = await http.call_http(HTTPClient.METHOD_GET, url, headers)
		var code := int(response.get("code", 0))
		if int(response.get("result", 0)) != HTTPRequest.RESULT_SUCCESS or code == 0:
			return {"ok": false, "changed": false, "bytes": PackedByteArray(), "error": "Could not reach the server to fetch the model."}
		if code == 304:
			not_modified_count += 1
			return {"ok": true, "changed": false, "bytes": PackedByteArray(), "error": ""}
		if code == 200:
			var etag := _etag_of(response.get("headers", []))
			if etag != "":
				_etags[url] = etag
			return {"ok": true, "changed": true, "bytes": response["body"], "error": ""}
		if code == 401 and attempt == 0:
			if await _token_replaced(token):
				continue
		if code == 401:
			return {"ok": false, "changed": false, "bytes": PackedByteArray(), "error": "The presenter's link to the model has expired or was ended. Ask them to share again."}
		if code == 404:
			return {"ok": false, "changed": false, "bytes": PackedByteArray(), "error": "The presenter's server does not have that part any more."}
		return {"ok": false, "changed": false, "bytes": PackedByteArray(), "error": "The server answered %d: %s" % [code, Http.detail_of(response)]}
	return {"ok": false, "changed": false, "bytes": PackedByteArray(), "error": "Could not fetch the model."}


func _token_replaced(old_token: String) -> bool:
	## The token failed. A newer one may have arrived already; if not, resume to read the hub's current one. True when there is a different token to try.
	if client.view_token != old_token:
		return true
	if not client.force_resume():
		return false
	var waited := 0.0
	while client.state != client.State.LIVE and client.state != client.State.CLOSED and waited < TOKEN_WAIT_S:
		await get_tree().process_frame
		waited += get_process_delta_time()
	return client.state == client.State.LIVE and client.view_token != old_token


static func _etag_of(headers) -> String:
	for header in headers:
		var text := str(header)
		var colon := text.find(":")
		if colon > 0 and text.substr(0, colon).strip_edges().to_lower() == "etag":
			return text.substr(colon + 1).strip_edges()
	return ""


# --- The stream -----------------------------------------------------------------------------------------------------------------

func _replay_held() -> void:
	## What arrived while the model was loading, in order (each still goes through the seq check).
	var held := _held_messages.duplicate()
	_held_messages.clear()
	for message in held:
		_on_message(message)


func _on_message(message: Dictionary) -> void:
	if not active:
		return
	if _loading:
		_held_messages.append(message)
		return
	var kind := str(message.get("t", ""))
	if kind in STATE_KINDS and message.has("seq"):
		if int(message["seq"]) <= int(_applied_seq.get(kind, 0)):
			return # older than one already applied
		_applied_seq[kind] = int(message["seq"])
	match kind:
		"poses":
			_on_poses(message)
		"visibility":
			_hidden = message.get("hidden", [])
			_apply_visibility(false)
		"section":
			_section = message
			_apply_section()
		"place":
			_apply_place(message.get("xf", []))
		"status":
			_apply_status(message)
		"doc_changed":
			_queue_doc(int(message.get("rev", 0)), message.get("parts", []), bool(message.get("all", false)))
		"model":
			_on_model(message)


func _apply_snapshot(snapshot: Dictionary, full: bool = true) -> void:
	var place = snapshot.get("place")
	if place is Dictionary:
		_apply_place((place as Dictionary).get("xf", []))
	var visibility = snapshot.get("visibility")
	_hidden = (visibility as Dictionary).get("hidden", []) if visibility is Dictionary else []
	_apply_visibility(full)
	var section = snapshot.get("section")
	_section = section if section is Dictionary else {"on": false}
	_apply_section()
	var status = snapshot.get("status")
	if status is Dictionary:
		_apply_status(status)
	_tracks.clear()
	var at := 0.0
	for item in snapshot.get("poses", []):
		_set_pose(str(item.get("path", "")), item.get("xf", []), at, true)
	for kind in ["poses", "visibility", "section", "place", "status"]:
		var held = snapshot.get(kind) if kind != "poses" else null
		if held is Dictionary and (held as Dictionary).has("seq"):
			_applied_seq[kind] = maxi(int(_applied_seq.get(kind, 0)), int(held["seq"]))


func _on_poses(message: Dictionary) -> void:
	var at := float(message.get("at", 0))
	var local_now := float(Time.get_ticks_msec())
	var sample := at - local_now
	if not _have_offset or absf(sample - _offset_ms) > 2000.0:
		_offset_ms = sample
		_have_offset = true
	else:
		_offset_ms = lerpf(_offset_ms, sample, 0.1)
	for item in message.get("items", []):
		_set_pose(str(item.get("path", "")), item.get("xf", []), at, bool(message.get("full", false))) # (a full table follows a load or a refetch: no tween)


func _set_pose(key: String, xf_array, at: float, snap: bool) -> void:
	var xf = Protocol.xf_from_array(xf_array, _unit_mm)
	if xf == null:
		return
	_latest[key] = xf
	var node: Node3D = _nodes.get(key)
	if node == null or not is_instance_valid(node):
		return
	if snap or not _tracks.has(key):
		_tracks[key] = {"b": {"at": at, "xf": xf}}
		_place_node(node, xf)
		return
	var track: Dictionary = _tracks[key]
	track["a"] = track["b"]
	track["b"] = {"at": at, "xf": xf}


func _place_node(node: Node3D, xf: Transform3D) -> void:
	if own_view != null and own_view.is_pulled(node):
		return # this person's hand has this part: the presenter's pose for it is kept (_latest) and shown again after Reset my view
	if _scene_root != null and is_instance_valid(_scene_root):
		node.global_transform = _scene_root.global_transform * xf


func _process(_delta: float) -> void:
	## Shows each moving part where it was one pose interval ago, between the last two poses received.
	if not active or _tracks.is_empty() or _scene_root == null or not is_instance_valid(_scene_root):
		return
	var render_at := float(Time.get_ticks_msec()) + _offset_ms - POSE_DELAY_MS
	for key in _tracks:
		var track: Dictionary = _tracks[key]
		if not track.has("a"):
			continue
		var node: Node3D = _nodes.get(key)
		if node == null or not is_instance_valid(node):
			continue
		_place_node(node, interpolated(track, render_at))
		if render_at >= float(track["b"]["at"]):
			track.erase("a") # arrived: nothing more to do for this part until the next pose


static func interpolated(track: Dictionary, render_at: float) -> Transform3D:
	## The pose to show at `render_at` (hub time, ms) between the track's last two samples. Past the newest: the newest. Before the older: the older. A gap over 500 ms:
	## no tween. A mirrored basis cannot be slerped: its origin is blended and its basis is the newer one.
	var a: Dictionary = track["a"]
	var b: Dictionary = track["b"]
	var xa: Transform3D = a["xf"]
	var xb: Transform3D = b["xf"]
	var span := float(b["at"]) - float(a["at"])
	if span <= 0.0 or span > SNAP_GAP_MS or render_at >= float(b["at"]):
		return xb
	if render_at <= float(a["at"]):
		return xa
	var t := (render_at - float(a["at"])) / span
	var origin := xa.origin.lerp(xb.origin, t)
	if xa.basis.determinant() <= 0.0 or xb.basis.determinant() <= 0.0:
		return Transform3D(xb.basis, origin)
	var scale_a := xa.basis.get_scale()
	var scale_b := xb.basis.get_scale()
	var rotation := xa.basis.get_rotation_quaternion().slerp(xb.basis.get_rotation_quaternion(), t)
	return Transform3D(Basis(rotation).scaled(scale_a.lerp(scale_b, t)), origin)


func _apply_visibility(full: bool = true) -> void:
	## The presenter's hide list. Applied whole (`full`: a load, a refetch, Reset my view) or as CHANGES since the last list, so a part this person hid, isolated or showed on their own stays
	## as they left it until the presenter changes that very part.
	var hidden := {}
	for key in _hidden:
		hidden[str(key)] = true
	for key in _nodes:
		var node: Node3D = _nodes[key]
		if is_instance_valid(node) and (full or hidden.has(key) != _presenter_hidden.has(key)):
			node.visible = not hidden.has(key)
	_presenter_hidden = hidden


func own_visibility_changes() -> int:
	## How many parts this person shows or hides differently from the presenter.
	var n := 0
	for key in _nodes:
		var node: Node3D = _nodes[key]
		if is_instance_valid(node) and node.visible == _presenter_hidden.has(key):
			n += 1
	return n


func restore_poses(nodes: Array = []) -> void:
	## Puts parts at the presenter's pose for them (or where the file put them, if the presenter never moved one): all of them, or just `nodes`. The caller has already let go of them
	## (session_own_view.gd forgets a part it pulled before this).
	_tracks.clear()
	for key in _nodes:
		var node: Node3D = _nodes[key]
		if is_instance_valid(node) and (nodes.is_empty() or nodes.has(node)):
			var xf: Variant = _latest.get(key, _initial.get(key))
			if xf != null:
				_place_node(node, xf)


func reset_to_presenter() -> void:
	## Reset my view: every part hidden or shown as the presenter has it, at the presenter's pose for it (or where the file put it, if the presenter never moved it), the cut theirs.
	_apply_visibility(true)
	restore_poses()
	if own_view != null and own_view.own_section_active():
		main.session_apply_section(false, Vector3.ZERO, Vector3.UP)
		remote_section_on = false
	_apply_section()


func _apply_section() -> void:
	if _scene_root == null:
		return
	if own_view != null and own_view.own_section_active():
		return # this person has a cut of their own on: the presenter's is held back (it is kept in _section) until Reset my view
	if not bool(_section.get("on", false)):
		remote_section_on = false
		main.session_apply_section(false, Vector3.ZERO, Vector3.UP)
		return
	var point: Array = _section.get("point", [0, 0, 0])
	var normal: Array = _section.get("normal", [0, 1, 0])
	if not Protocol.is_numbers(point, 3) or not Protocol.is_numbers(normal, 3):
		return
	var world_point := _scene_root.global_transform * (Vector3(point[0], point[1], point[2]) / _unit_mm)
	var world_normal := (_scene_root.global_transform.basis * Vector3(normal[0], normal[1], normal[2])).normalized()
	remote_section_on = true
	main.session_apply_section(true, world_point, world_normal)


func _apply_place(xf_array) -> void:
	var xf = Protocol.xf_from_array(xf_array)
	if xf != null:
		_place = xf
		_have_place = true
		main.session_apply_place(xf)


func _apply_status(status: Dictionary) -> void:
	var who := str(client.presenter().get("name", "The presenter"))
	var detail := str(status.get("detail", ""))
	var line := ""
	match str(status.get("activity", "model")):
		"design_table":
			line = "%s is at the design table%s" % [who, ": " + detail if detail != "" else ""]
		"room":
			line = "%s is working in an Assembly Room%s" % [who, ": " + detail if detail != "" else ""]
		"files":
			line = "%s: %s" % [who, detail if detail != "" else "opening a file"]
		"idle":
			line = "%s is away from the model" % who
		_:
			line = ""
	status_text = line
	status_changed.emit(line)


func _on_model(message: Dictionary) -> void:
	var source = message.get("source")
	if not (source is Dictionary):
		return
	var model: Dictionary = (source as Dictionary).duplicate()
	model["title"] = str(message.get("title", ""))
	_tracks.clear()
	_latest.clear()
	_etags.clear()
	_loading = true
	var shown := await _show(model)
	if shown:
		title = str(model["title"])
		loaded_rev = int(message.get("rev", model.get("rev", 0)))
		if _have_place:
			main.session_apply_place(_place)
		_apply_visibility()
		_apply_section()
	_loading = false
	_replay_held()
	if shown:
		model_ready.emit()


# --- A changed document ---------------------------------------------------------------------------------------------------------

func _queue_doc(rev: int, parts: Array, all: bool) -> void:
	if rev <= loaded_rev and rev != 0:
		return # nothing newer than what is shown
	for pid in parts:
		_queue_parts[str(pid)] = true
	_queue_all = _queue_all or all
	_queue_rev = maxi(_queue_rev, rev)
	if not _busy:
		_drain()


func _drain() -> void:
	## One refetch at a time; a doc_changed that arrives meanwhile is merged (the newest revision wins) and handled when this one is done.
	_busy = true
	while active and (_queue_all or not _queue_parts.is_empty()):
		var rev := _queue_rev
		var parts := _queue_parts.keys()
		var all := _queue_all
		_queue_parts = {}
		_queue_all = false
		var done := true
		if all:
			done = await _refetch_all()
		else:
			done = await _refetch_parts(parts)
		if done and active:
			loaded_rev = maxi(loaded_rev, rev) # (a dropped refetch, the session ended or another model meanwhile, shows nothing of this revision: it must not make the next events look old)
	_busy = false


func _refetch_all() -> bool:
	## True when the answer belonged to the document shown (whatever came of it); false when it was dropped (the session ended, or another model came in).
	var source := model_source # (a re-read of the model on show; _show() replaces model_source for another one, which then is another document)
	var fetched := await _fetch_glb(str(model_source.get("root_part_id", "")), model_source)
	if not active or _model_differs(source):
		return false # (the session ended, or another model came in while this was fetched: these bytes are the old document's, nothing of them is shown, indexed or placed)
	if not fetched["ok"]:
		_fail(str(fetched["error"]))
		return true
	if not bool(fetched["changed"]):
		return true # a 304: the same revision as the one shown
	if not main.session_show_model(fetched["bytes"], true): # (the same document, re-read: the viewer's Find words stay)
		_fail("The presenter's changed model could not be read.")
		return true
	if _have_place:
		main.session_apply_place(_place) # (the document changed; where the presenter put it did not, and it may have moved meanwhile)
	_index()
	_apply_visibility()
	_apply_section()
	_tracks.clear()
	for key in _latest:
		var node: Node3D = _nodes.get(key)
		if node != null and is_instance_valid(node):
			_place_node(node, _latest[key]) # the newest poses received: the presenter's full table follows its own reload
	return true


func _refetch_parts(parts: Array) -> bool:
	## As _refetch_all: false when the answer was dropped, because the session ended or another model came in while it was fetched (B8.1).
	var source := model_source
	for pid in parts:
		var fetched := await _fetch_glb(str(pid), source)
		if not active or _model_differs(source):
			return false
		if not fetched["ok"]:
			_fail(str(fetched["error"]))
			return true
		if not bool(fetched["changed"]):
			continue
		var nodes: Array = []
		for node in _nodes.values():
			if is_instance_valid(node) and str(node.get_meta("owner_part_id", "")) == str(pid):
				nodes.append(node)
		if not nodes.is_empty():
			main.swap_part_mesh(nodes, fetched["bytes"])
	return true
