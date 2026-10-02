extends Node
## Milestone 4's last assembly tool, "Measurements": laser-pick 1-2 vertex/
## edge/face entities and query DIDSA-CAD's real, stateless
## POST /parts/{part_id}/measure endpoint (app.document.measure.measure) -
## the same one the flat app's own Measure panel uses
## (client/lib/viewport3d/measurement_panel.dart), never a VR-only
## representation. Unlike Mates, this never creates or persists anything
## (that module's own docstring: "no Feature, no undo/redo entry"), so
## there is no separate create step - picking the first entity queries and
## shows a single-entity result immediately; picking a second re-queries
## for the two-entity relationship (distance, delta, and - when detected -
## axis/normal distance and parallelism) right away.
##
## Same picking substrate as mates_tool.gd (mesh_identity.gd's
## occurrence_ref_for()/subshape_ref_for_hit()) but looser validation:
## unlike a Mate, a Measure entity can be the currently-open Part's own
## root content (occurrence_id == "" - MeasureEntityRefSchema's own
## docstring), and both picks can land on the very same Occurrence or root
## content - measuring across two features of one part (a hole's spacing,
## a wall's thickness) is the common case, not the "two different parts"
## requirement Mates has. The only restriction: both picks must belong to
## the same loaded root Part, since compute_measurement (measure.py's own
## `measure()`) resolves each ref's occurrence_id as a top-level Occurrence
## of the one Part named in the URL - there is nothing to compare across
## two unrelated assemblies anyway, and this client only ever has one
## loaded at a time.

signal picks_changed()
signal result_changed()

const API_PREFIX := "/document"
const MeshIdentity := preload("res://scripts/mesh_identity.gd")

var active := false ## wrist tablet's "Measure tool" toggle
var backend_url := ""
var api_key := ""

var result: Dictionary = {} ## last MeasurementResultSchema response, or {} (no result / cleared / failed)

var _picks: Array[Dictionary] = []
var _status := ""
var _busy := false
var _owner_part_id := ""
var _measure_token := 0 ## bumped on every clear/re-measure so a slow, now-superseded request can't overwrite a newer one's result once it eventually completes - see _run_measure()'s own comment


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
	result = {}
	_status = ""
	_owner_part_id = ""
	_measure_token += 1 # invalidate any request still in flight from before this clear
	picks_changed.emit()
	result_changed.emit()


func status_text() -> String:
	if _status != "":
		return _status
	match _picks.size():
		0:
			return "Pick a vertex, edge or face to measure."
		1:
			return "Pick a second entity to compare, or view this measurement alone."
		_:
			return ""
	return ""


func picked_entities() -> Array:
	## [{part, face_index}] for face_highlight.gd, in pick order.
	var out := []
	for p in _picks:
		out.append({"part": p.get("part"), "face_index": p.get("face_index", -1)})
	return out


func picked_labels() -> Array:
	var out := []
	for p in _picks:
		out.append(p["label"])
	return out


func try_pick(part: Node3D, face_index: int) -> void:
	## Called by controller.gd's trigger handler while the tool is active.
	## Always sets status and emits picks_changed, even on rejection, so the
	## wrist tablet can show *why* a pick didn't count (mirrors mates_tool.
	## gd's own try_pick). A third pick starts a fresh measurement rather
	## than being ignored (mates_tool.gd's own cap-at-2 behaviour) - Measure
	## is meant for picking through several things in a row, not one
	## deliberate creation step.
	##
	## Deliberately does NOT bail out while _busy (a real, in-flight request
	## from a previous pick) - a quick real second pick right after the
	## first would otherwise be silently dropped waiting on a network round
	## trip that hasn't returned yet (found by an e2e run against a real
	## backend, not assumed: the two-entity case never even fired). Instead
	## _run_measure()'s own _measure_token guards against the *stale*
	## request's result landing after this newer one has already started.
	if not active:
		return
	if _picks.size() >= 2:
		clear_picks()
	var occ_ref := MeshIdentity.occurrence_ref_for(part)
	var subshape := MeshIdentity.subshape_ref_for_hit(part, face_index)
	var rejection := _validate_pick(occ_ref, subshape)
	if rejection != "":
		_status = rejection
		picks_changed.emit()
		return
	_picks.append({
		"occurrence_id": occ_ref["occurrence_id"],
		"subshape_ref": subshape,
		"label": str(part.name), # Node.name is a StringName, not a String - cast once here (mates_tool.gd's own precedent)
		"part": part, # for face_highlight.gd: the picked face stays lit
		"face_index": face_index,
	})
	_owner_part_id = occ_ref["owner_part_id"]
	_status = ""
	picks_changed.emit()
	await _run_measure()


func _validate_pick(occ_ref: Dictionary, subshape: Dictionary) -> String:
	## Pure, no network - "" means OK, else a user-facing rejection reason.
	## Deliberately does NOT reject root content (occurrence_id == "") or a
	## repeat of the first pick's own occurrence - both are valid Measure
	## targets, unlike Mates (see this script's own docstring).
	if occ_ref.is_empty():
		return "This part has no backend identity yet (not loaded from the backend)."
	if subshape.is_empty():
		return "This part has no face identity yet (not loaded from the backend)."
	if not _picks.is_empty() and occ_ref["owner_part_id"] != _owner_part_id:
		return "Both entities must belong to the same loaded assembly."
	return ""


func _run_measure() -> void:
	## A fresh token per call: if a *later* pick (and so a later call to this
	## same function) completes and bumps _measure_token before this one's
	## own request comes back, this call's result is stale - a real
	## overlapping-request race (confirmed against a real backend, not
	## assumed), not just a theoretical one - so it's discarded rather than
	## clobbering the newer, still-in-flight or already-applied result.
	## Whichever call's token is still current when it returns is the one
	## that gets to clear _busy and apply its own result.
	_measure_token += 1
	var my_token := _measure_token
	_busy = true
	var refs := []
	for p in _picks:
		refs.append({"occurrence_id": p["occurrence_id"], "subshape_ref": p["subshape_ref"]})
	var api_result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/measure" % _owner_part_id, {"refs": refs})
	if my_token != _measure_token:
		return # superseded by a later pick/clear while this request was in flight
	_busy = false
	if api_result["ok"]:
		result = api_result["json"] if api_result["json"] != null else {}
		_status = ""
	else:
		result = {}
		_status = "Couldn't measure: %s" % api_result["error"]
	result_changed.emit()


func _api_request(method: int, path: String, body_dict) -> Dictionary:
	## Same fresh-HTTPRequest-per-call pattern as mates_tool.gd/colour_tool.
	## gd's own _api_request - see either's docstring.
	var req := HTTPRequest.new()
	add_child(req)
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
	var body := "" if body_dict == null else JSON.stringify(body_dict)
	var err := req.request(backend_url + API_PREFIX + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "json": null, "error": "request failed to start (error %d)" % err}
	var result_arr: Array = await req.request_completed
	req.queue_free()
	var result_code: int = result_arr[0]
	var response_code: int = result_arr[1]
	var raw: PackedByteArray = result_arr[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": response_code, "json": null, "error": "network error (result %d)" % result_code}
	var parsed = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	var ok: bool = response_code >= 200 and response_code < 300
	return {"ok": ok, "code": response_code, "json": parsed, "error": ("" if ok else str(parsed))}
