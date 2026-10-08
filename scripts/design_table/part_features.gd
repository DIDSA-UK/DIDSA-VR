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


## The *_request builders make and check one feature's create body without sending it: {ok, error, route, body}. A feature tool
## (features/feature_tool.gd) hands that to `post`, and the editor keeps it so Redo can send the same thing again.
static func _bad(message: String) -> Dictionary:
	return {"ok": false, "error": message, "route": "", "body": {}}


static func _good(route: String, body: Dictionary) -> Dictionary:
	return {"ok": true, "error": "", "route": route, "body": body}


static func extrude_request(sketch_feature_id: String, boss: bool, start_distance: float, end_distance: float, target_body_ids: Array) -> Dictionary:
	## Boss with no targets starts a new body; a cut must name the bodies it cuts.
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	if is_equal_approx(start_distance, end_distance):
		return _bad("The depth can't be zero.")
	return _good("extrude-features", {
		"sketch_feature_id": sketch_feature_id,
		"extrude_type": "boss" if boss else "cut",
		"start_distance": minf(start_distance, end_distance),
		"end_distance": maxf(start_distance, end_distance),
		"target_body_ids": target_body_ids})


static func revolve_request(sketch_feature_id: String, sketch_id: String, axis_line_id: String, angle: float, boss: bool, target_body_ids: Array) -> Dictionary:
	## Spins the sketch's closed profile `angle` degrees (0-360) about one of the sketch's lines. Same Boss / Cut rule as extrude.
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	if axis_line_id == "":
		return _bad("Pick the line to spin it about first.")
	if angle <= 0.0 or angle > 360.0:
		return _bad("The angle has to be more than 0 and at most 360 degrees.")
	return _good("revolve-features", {
		"sketch_feature_id": sketch_feature_id,
		"axis_ref": {"sketch_id": sketch_id, "entity_type": "line", "entity_id": axis_line_id},
		"angle": angle,
		"mode": "boss" if boss else "cut",
		"target_body_ids": target_body_ids})


static func shell_request(body_id: String, faces: Array, thickness: float, direction: String) -> Dictionary:
	## Hollows a solid body, opening the given faces (SubShape refs on that body) and leaving walls `thickness` thick,
	## grown "inward", "outward" or "symmetric".
	if faces.is_empty():
		return _bad("Pick the faces to open first.")
	if thickness <= 0.0:
		return _bad("The thickness has to be bigger than zero.")
	return _good("shell-features", {"body_id": body_id, "faces_to_remove": faces, "thickness": thickness, "thickness_direction": direction})


static func mirror_request(body_ids: Array, plane: Dictionary, fuse: bool) -> Dictionary:
	## Reflects every body across a plane: {fixed_plane: "XY"} or {face_ref: {body_id, shape_type, index}}.
	if body_ids.is_empty():
		return _bad("There is nothing to mirror yet.")
	return _good("mirror-features", {"source_body_ids": body_ids, "mirror_plane": plane, "merge": "fuse_into_one" if fuse else "keep_separate"})


static func fillet_request(edges: Array, radius: float) -> Dictionary:
	if edges.is_empty():
		return _bad("Pick the edges to round first.")
	if radius <= 0.0:
		return _bad("The radius has to be bigger than zero.")
	return _good("fillet-features", {"edge_refs": edges, "radius": radius})


static func chamfer_request(edges: Array, distance: float) -> Dictionary:
	if edges.is_empty():
		return _bad("Pick the edges to chamfer first.")
	if distance <= 0.0:
		return _bad("The distance has to be bigger than zero.")
	return _good("chamfer-features", {"edge_refs": edges, "distance": distance})


func post(owner_part_id: String, request: Dictionary) -> Dictionary:
	## Sends a *_request: {ok, id, error}. A request that did not pass its checks comes back as its own error, nothing is sent.
	if not bool(request["ok"]):
		return {"ok": false, "id": "", "error": str(request["error"])}
	return _result(await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/%s" % [owner_part_id, request["route"]], request["body"]))


static func face_ref(body_id: String, index: int) -> Dictionary:
	return {"body_id": body_id, "shape_type": "face", "index": index}


func extrude(owner_part_id: String, sketch_feature_id: String, boss: bool, start_distance: float, end_distance: float, target_body_ids: Array) -> Dictionary:
	## {ok, id, error}.
	return await post(owner_part_id, extrude_request(sketch_feature_id, boss, start_distance, end_distance, target_body_ids))


func revolve(owner_part_id: String, sketch_feature_id: String, sketch_id: String, axis_line_id: String, angle: float, boss: bool, target_body_ids: Array) -> Dictionary:
	return await post(owner_part_id, revolve_request(sketch_feature_id, sketch_id, axis_line_id, angle, boss, target_body_ids))


func shell(owner_part_id: String, body_id: String, faces: Array, thickness: float, direction: String) -> Dictionary:
	return await post(owner_part_id, shell_request(body_id, faces, thickness, direction))


func mirror(owner_part_id: String, body_ids: Array, plane: Dictionary, fuse: bool) -> Dictionary:
	return await post(owner_part_id, mirror_request(body_ids, plane, fuse))


func fillet(owner_part_id: String, edges: Array, radius: float) -> Dictionary:
	return await post(owner_part_id, fillet_request(edges, radius))


func chamfer(owner_part_id: String, edges: Array, distance: float) -> Dictionary:
	return await post(owner_part_id, chamfer_request(edges, distance))


func delete_feature(owner_part_id: String, feature_id: String) -> Dictionary:
	## Takes back the LAST feature (the backend only allows deleting the last one).
	return _result(await api.call(HTTPClient.METHOD_DELETE, "/document/parts/%s/features/%s" % [owner_part_id, feature_id], null))


func list_features(owner_part_id: String) -> Dictionary:
	## {ok, features: Array of the backend's feature rows in build order, error}.
	var r: Dictionary = await api.call(HTTPClient.METHOD_GET, "/document/parts/%s/features" % owner_part_id, null)
	if not r["ok"] or not (r["json"] is Array):
		return {"ok": false, "features": [], "error": _plain(str(r["error"]))}
	return {"ok": true, "features": r["json"], "error": ""}


func update_feature(owner_part_id: String, feature_type: String, feature_id: String, payload: Dictionary) -> Dictionary:
	## Changes the one number of an extrude / fillet / chamfer, or swaps a reference (a Build row's Fix: PATCH with a replacement edge or face; any feature of the
	## part, not just the last). {ok, id, error}.
	var route: String = {"extrude": "extrude-features", "revolve": "revolve-features", "shell": "shell-features", "fillet": "fillet-features", "chamfer": "chamfer-features", "mirror": "mirror-features", "create_plane": "create-plane-features"}.get(feature_type, "")
	if route == "":
		return {"ok": false, "id": "", "error": "That kind of feature can't be edited here."}
	return _result(await api.call(HTTPClient.METHOD_PATCH, "/document/parts/%s/%s/%s" % [owner_part_id, route, feature_id], payload))


func delete_cascade(owner_part_id: String, feature_id: String) -> Dictionary:
	## Deletes the feature and everything built on it (and the sketches they owned). {ok, deleted: Array of feature ids, error}.
	var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, "/document/parts/%s/features/%s/cascade" % [owner_part_id, feature_id], null)
	if not r["ok"]:
		return {"ok": false, "deleted": [], "error": _plain(str(r["error"]))}
	var json = r["json"]
	return {"ok": true, "deleted": (json.get("deleted_feature_ids", []) if json is Dictionary else []), "error": ""}


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
