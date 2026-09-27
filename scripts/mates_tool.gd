extends Node
## The vision brief's "Mates workflow": start the tool, laser-target faces on
## two different parts, pick a mate type from the wrist tablet, type any
## value on the popup keyboard. Built as a thin client to DIDSA-CAD's real
## Mate endpoints (POST/GET/DELETE .../mates, POST .../occurrences/{id}/solve)
## — never a VR-only mate representation — so a mate authored here is
## immediately readable/editable in the flat app and vice versa (vision
## brief's 27 Sep cross-compatibility note; see docs/status.md).
##
## Scope for this pass: FACE-only picking (a raycast against a filled
## triangle mesh naturally resolves to a face — edge picking needs either a
## separate wireframe pickable or a nearest-boundary-edge heuristic on top of
## this, not built yet). Also restricted to top-level Occurrences of the
## loaded root Part: the backend only lets a Mate reference a top-level
## Occurrence of its own owning Part anyway (see MateEntityRef's own
## docstring in DIDSA-CAD), and this also happens to be exactly the case
## where a solved Mate's own local-to-parent transform IS the flattened,
## world-relative-to-root transform baked into that instance's Godot node
## (assembly-mesh.glb has no intermediate parenting at all — see
## _apply_solved_transform below).
##
## "Relax all mates" / "Enforce all mates" (vision brief's Assembly tools):
## there is no bulk-solve endpoint server-side, and this client never
## auto-solves during a drag (out of scope per the vision brief's own "Drag
## latency" open decision). So: `relaxed` just suspends the one auto-solve
## this tool WOULD otherwise do right after create_mate (mirroring the flat
## app's own create_mate -> solve_for_occurrence pairing, see that
## endpoint's docstring for why — "a freshly-authored Mate visibly snaps its
## target into place immediately"), letting a user place several mates
## before solving; "Enforce all" solves every occurrence any of this Part's
## own Mates reference, looping solve_for_occurrence since there's no bulk
## endpoint.

signal picks_changed()
signal mates_changed()

const API_PREFIX := "/document"
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const MATE_TYPES: Array[String] = ["coincident", "concentric", "parallel", "distance", "angle"]

var active := false ## wrist tablet's "Mates tool" toggle
var backend_url := ""
var api_key := ""
var command_stack = null ## set via setup(); shared undo/redo history

var mate_type := "coincident"
var mate_value := 0.0
var mate_flipped := false
var mate_allow_rotation := true
var relaxed := false

var mates: Array = [] ## last-fetched list for _current_owner_part_id, for the tablet's list UI

var _picks: Array[Dictionary] = []
var _status := ""
var _busy := false
var _current_owner_part_id := ""


func setup(stack) -> void:
	command_stack = stack


func configure_backend(url: String, key: String) -> void:
	backend_url = url
	api_key = key


func is_busy() -> bool:
	return _busy


func set_active(on: bool) -> void:
	active = on
	if not on:
		clear_picks()


func clear_picks() -> void:
	_picks.clear()
	_status = ""
	picks_changed.emit()


func status_text() -> String:
	if _status != "":
		return _status
	match _picks.size():
		0:
			return "Pick a face on the first part."
		1:
			return "Pick a face on the second part."
		_:
			return "Ready — choose a mate type and Create."
	return ""


func picked_labels() -> Array:
	var out := []
	for p in _picks:
		out.append(p["label"])
	return out


func try_pick(part: Node3D, face_index: int) -> void:
	## Called by controller.gd's trigger handler while the tool is active.
	## Always sets status and emits picks_changed, even on rejection, so the
	## wrist tablet can show *why* a pick didn't count.
	if not active or _picks.size() >= 2:
		return
	var occ_ref := MeshIdentity.occurrence_ref_for(part)
	var subshape := MeshIdentity.subshape_ref_for_hit(part, face_index)
	var rejection := _validate_pick(occ_ref, subshape)
	if rejection != "":
		_status = rejection
		picks_changed.emit()
		return
	_picks.append({
		"owner_part_id": occ_ref["owner_part_id"],
		"occurrence_id": occ_ref["occurrence_id"],
		"subshape_ref": subshape,
		"label": str(part.name), # Node.name is a StringName, not a String - cast once here so later == comparisons (tests, UI) behave
	})
	_status = ""
	picks_changed.emit()


func _validate_pick(occ_ref: Dictionary, subshape: Dictionary) -> String:
	## Pure, no network — "" means OK, else a user-facing rejection reason.
	if occ_ref.is_empty():
		return "This part has no backend identity yet (not loaded from the backend)."
	if occ_ref.get("occurrence_id", "") == "":
		return "Can't mate the assembly's own root content — pick a placed part."
	if subshape.is_empty():
		return "This part has no face identity yet (not loaded from the backend)."
	if not _picks.is_empty():
		var first: Dictionary = _picks[0]
		if first["owner_part_id"] != occ_ref["owner_part_id"]:
			return "Both parts must belong to the same assembly."
		if first["occurrence_id"] == occ_ref["occurrence_id"]:
			return "Pick two different parts, not the same one twice."
	return ""


func can_create() -> bool:
	return _picks.size() == 2 and not _busy


func build_create_payload() -> Dictionary:
	## Pure — the exact POST /parts/{owner_part_id}/mates body MateCreate
	## expects (DIDSA-CAD's app.document.schemas.MateCreate).
	var references := []
	for p in _picks:
		references.append({"occurrence_id": p["occurrence_id"], "subshape_ref": p["subshape_ref"]})
	var payload := {
		"type": mate_type, "references": references,
		"flipped": mate_flipped, "allow_rotation": mate_allow_rotation,
	}
	if mate_type in ["distance", "angle"]:
		payload["value"] = mate_value
	return payload


func create_mate() -> Dictionary:
	## Returns {"ok":, "error":}. By convention the 2nd pick is the driven
	## occurrence solve_for_occurrence snaps into place afterward (unless
	## `relaxed`) — matching the flat app's own create-then-solve pairing.
	if not can_create():
		return {"ok": false, "error": "Pick two entities first."}
	var owner_part_id: String = _picks[0]["owner_part_id"]
	var driven_occurrence_id: String = _picks[1]["occurrence_id"]
	_busy = true
	var result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/mates" % owner_part_id, build_create_payload())
	_busy = false
	if not result["ok"]:
		return {"ok": false, "error": result["error"]}
	clear_picks()
	if relaxed:
		await refresh_mates(owner_part_id)
	else:
		await solve_occurrence(owner_part_id, driven_occurrence_id)
	return {"ok": true, "error": ""}


func refresh_mates(owner_part_id: String) -> void:
	_current_owner_part_id = owner_part_id
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/mates" % owner_part_id, null)
	if result["ok"]:
		mates = result["json"]
	mates_changed.emit()


func delete_mate(owner_part_id: String, mate_id: String) -> bool:
	_busy = true
	var result := await _api_request(HTTPClient.METHOD_DELETE, "/parts/%s/mates/%s" % [owner_part_id, mate_id], null)
	_busy = false
	await refresh_mates(owner_part_id)
	return result["ok"]


func solve_occurrence(owner_part_id: String, occurrence_id: String) -> Dictionary:
	## Solves occurrence_id's Mates server-side and applies the result to
	## whichever loaded Godot part carries that identity.
	_busy = true
	var result := await _api_request(
		HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/solve" % [owner_part_id, occurrence_id], null
	)
	_busy = false
	if not result["ok"]:
		await refresh_mates(owner_part_id)
		return {"ok": false, "error": result["error"]}
	var transform_json: Dictionary = result["json"].get("transform", {})
	var part := _find_loaded_part(owner_part_id, occurrence_id)
	if part != null and not transform_json.is_empty():
		_apply_solved_transform(part, transform_json)
	await refresh_mates(owner_part_id)
	return {"ok": true, "error": ""}


func enforce_all(owner_part_id: String) -> void:
	## Solves every occurrence any of this Part's own Mates reference.
	await refresh_mates(owner_part_id)
	var occurrence_ids := {}
	for mate in mates:
		for ref in mate.get("references", []):
			occurrence_ids[ref["occurrence_id"]] = true
	for occ_id in occurrence_ids:
		await solve_occurrence(owner_part_id, occ_id)


func set_relaxed(on: bool) -> void:
	relaxed = on


func _find_loaded_part(owner_part_id: String, occurrence_id: String) -> Node3D:
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		var ref := MeshIdentity.occurrence_ref_for(node)
		if ref.get("owner_part_id", "") == owner_part_id and ref.get("occurrence_id", "") == occurrence_id:
			return node
	return null


func _apply_solved_transform(part: Node3D, transform_json: Dictionary) -> void:
	## Applies a solved RigidTransformResponse to `part`'s LOCAL transform
	## (relative to assembly_root) — valid because assembly-mesh.glb
	## flattens every instance's full world-relative-to-root transform onto
	## its own node with no intermediate parenting (mesh_export.py's
	## encode_assembly_glb), and because this tool only ever mates top-level
	## Occurrences (_validate_pick), so "local to its owning Part" and "the
	## instance's own baked node transform" are the same thing. Positions
	## stay in the backend's raw mm units, UNSCALED — assembly_root's own
	## basis already carries the mm->m (and any current scale-view multiple)
	## factor for its whole subtree, exactly like every other part's
	## position already does (see main.gd's _show_model()); multiplying by
	## spawn_scale here would double-apply it.
	var before := part.global_transform
	var t: Array = transform_json.get("translation", [0.0, 0.0, 0.0])
	var axis: Array = transform_json.get("rotation_axis", [0.0, 0.0, 1.0])
	var angle_degrees: float = transform_json.get("rotation_angle_degrees", 0.0)
	var axis_vec := Vector3(axis[0], axis[1], axis[2])
	if axis_vec.length() < 0.0001:
		axis_vec = Vector3.UP
	part.position = Vector3(t[0], t[1], t[2])
	part.basis = Basis(axis_vec.normalized(), deg_to_rad(angle_degrees))
	if command_stack:
		var after := part.global_transform
		if not before.is_equal_approx(after):
			command_stack.push("solve %s" % part.name,
				func() -> void: part.global_transform = before,
				func() -> void: part.global_transform = after)


func _api_request(method: int, path: String, body_dict) -> Dictionary:
	## Returns {"ok":, "code":, "json":, "error":}. A fresh HTTPRequest per
	## call (mirroring main.gd's _import_external_file's own await-per-step
	## pattern) rather than one shared node, so overlapping calls (e.g. a
	## list refresh while a solve is in flight) never collide.
	var req := HTTPRequest.new()
	add_child(req)
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
	var body := "" if body_dict == null else JSON.stringify(body_dict)
	var err := req.request(backend_url + API_PREFIX + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "json": null, "error": "request failed to start (error %d)" % err}
	var result: Array = await req.request_completed
	req.queue_free()
	var result_code: int = result[0]
	var response_code: int = result[1]
	var raw: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": response_code, "json": null, "error": "network error (result %d)" % result_code}
	var parsed = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	var ok: bool = response_code >= 200 and response_code < 300
	return {"ok": ok, "code": response_code, "json": parsed, "error": ("" if ok else str(parsed))}
