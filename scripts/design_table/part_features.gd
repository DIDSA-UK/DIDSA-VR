extends RefCounted
## The feature calls the design table makes on the part being edited: Extrude (boss or cut), Fillet, Chamfer and taking the
## last one back. Thin on purpose: DIDSA-CAD does the modelling, VR only asks (docs/vision-brief.md: "the VR version should
## call the same modelling backend rather than reimplement it"). Every call goes through `api`, a Callable (method, path,
## body) -> Dictionary {ok, code, json, error}, the same as sketch_session.gd, so tests give it a fake.
##
## Validation is mostly lazy on the backend: a feature is stored at once and its geometry is computed on the next mesh
## request, so a bad reference only shows up there as a 422. refresh checks are the editor's job.

var api: Callable


func _init(p_api: Callable = Callable()) -> void:
	api = p_api


static func edge_ref(body_id: String, index: int) -> Dictionary:
	return {"body_id": body_id, "shape_type": "edge", "index": index}


func extrude(owner_part_id: String, sketch_feature_id: String, boss: bool, start_distance: float, end_distance: float, target_body_ids: Array) -> Dictionary:
	## {ok, id, error}. Boss with no targets starts a new body; a cut must name the bodies it cuts.
	if not boss and target_body_ids.is_empty():
		return {"ok": false, "id": "", "error": "There is nothing to cut yet."}
	if is_equal_approx(start_distance, end_distance):
		return {"ok": false, "id": "", "error": "The depth can't be zero."}
	var r: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/extrude-features" % owner_part_id, {
		"sketch_feature_id": sketch_feature_id,
		"extrude_type": "boss" if boss else "cut",
		"start_distance": minf(start_distance, end_distance),
		"end_distance": maxf(start_distance, end_distance),
		"target_body_ids": target_body_ids})
	return _result(r)


func fillet(owner_part_id: String, edges: Array, radius: float) -> Dictionary:
	if edges.is_empty():
		return {"ok": false, "id": "", "error": "Pick the edges to round first."}
	if radius <= 0.0:
		return {"ok": false, "id": "", "error": "The radius has to be bigger than zero."}
	return _result(await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/fillet-features" % owner_part_id, {"edge_refs": edges, "radius": radius}))


func chamfer(owner_part_id: String, edges: Array, distance: float) -> Dictionary:
	if edges.is_empty():
		return {"ok": false, "id": "", "error": "Pick the edges to chamfer first."}
	if distance <= 0.0:
		return {"ok": false, "id": "", "error": "The distance has to be bigger than zero."}
	return _result(await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/chamfer-features" % owner_part_id, {"edge_refs": edges, "distance": distance}))


func delete_feature(owner_part_id: String, feature_id: String) -> Dictionary:
	## Takes back the LAST feature (the backend only allows deleting the last one).
	return _result(await api.call(HTTPClient.METHOD_DELETE, "/document/parts/%s/features/%s" % [owner_part_id, feature_id], null))


func _result(r: Dictionary) -> Dictionary:
	if not r["ok"]:
		return {"ok": false, "id": "", "error": _plain(str(r["error"]))}
	var json = r["json"]
	return {"ok": true, "id": str(json.get("id", "")) if json is Dictionary else "", "error": ""}


static func _plain(error: String) -> String:
	## The backend's reason, in words a status line can carry.
	var known := {
		"non_planar_reference": "That face isn't flat.",
		"missing_reference": "An edge or face it needs isn't there any more.",
	}
	for key in known:
		if error.contains(key):
			return known[key]
	return error
