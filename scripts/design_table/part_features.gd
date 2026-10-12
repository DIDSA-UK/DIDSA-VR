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


static func extrude_request(sketch_feature_id: String, boss: bool, start_distance: float, end_distance: float, target_body_ids: Array, extra: Dictionary = {}) -> Dictionary:
	## Boss with no targets starts a new body; a cut must name the bodies it cuts. `extra` carries the optional thin wall (`thickness`, `thickness_direction`)
	## or draft (`draft_angle`, `draft_outward`); the backend refuses both together, and a draft on a sketch of more than one profile.
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	if is_equal_approx(start_distance, end_distance):
		return _bad("The depth can't be zero.")
	if extra.has("thickness") and extra.has("draft_angle"):
		return _bad("A thin wall and a draft can't be combined. Turn one off.")
	if extra.has("thickness") and float(extra["thickness"]) <= 0.0:
		return _bad("The wall thickness has to be more than zero.")
	if extra.has("draft_angle") and (float(extra["draft_angle"]) <= 0.0 or float(extra["draft_angle"]) >= 90.0):
		return _bad("The draft angle has to be more than 0 and less than 90 degrees.")
	var body := {
		"sketch_feature_id": sketch_feature_id,
		"extrude_type": "boss" if boss else "cut",
		"start_distance": minf(start_distance, end_distance),
		"end_distance": maxf(start_distance, end_distance),
		"target_body_ids": target_body_ids}
	body.merge(extra)
	return _good("extrude-features", body)


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


static func create_plane_request(base: Dictionary, offset: float) -> Dictionary:
	## A plane offset from a reference plane ({"fixed": "XY"}), a flat face ({"face": {body_id, index}}) or a plane already made ({"plane_feature_id": id}).
	if base.is_empty():
		return _bad("Pick a face or a plane to offset from first.")
	if is_zero_approx(offset):
		return _bad("The offset can't be zero.")
	var ref := {}
	if base.has("fixed"):
		ref = {"fixed_plane": str(base["fixed"])}
	elif base.has("face"):
		ref = {"face_ref": face_ref(str(base["face"]["body_id"]), int(base["face"]["index"]))}
	elif base.has("plane_feature_id"):
		ref = {"plane_feature_id": str(base["plane_feature_id"])}
	else:
		return _bad("Pick a face or a plane to offset from first.")
	return _good("create-plane-features", {"plane_type": "offset_face", "face_refs": [ref], "offset": offset})


static func loft_request(section_sketch_ids: Array, boss: bool, ruled: bool, target_body_ids: Array) -> Dictionary:
	## A loft through two or more sections, each the closed profile of a sketch (on its own plane).
	if section_sketch_ids.size() < 2:
		return _bad("A loft needs at least two sections: pick a line of each of two different sketches.")
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	return _good("loft-features", {"sections": section_sketch_ids.map(func(id): return {"sketch_feature_id": str(id)}), "mode": "boss" if boss else "cut",
		"ruled": ruled, "target_body_ids": target_body_ids})


static func sweep_request(sketch_feature_id: String, path_refs: Array, boss: bool, target_body_ids: Array) -> Dictionary:
	## The closed profile of a sketch swept along an ordered chain of lines / arcs of other sketches.
	if sketch_feature_id == "":
		return _bad("Draw the profile in a sketch first.")
	if path_refs.is_empty():
		return _bad("Pick the lines of the path first.")
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	return _good("sweep-features", {"sketch_feature_id": sketch_feature_id, "path_refs": path_refs, "mode": "boss" if boss else "cut", "target_body_ids": target_body_ids})


static func boolean_request(operation: String, target_ids: Array, tool_ids: Array, consume: bool) -> Dictionary:
	if target_ids.is_empty():
		return _bad("Pick the body to change first.")
	if tool_ids.is_empty():
		return _bad("Pick the body to %s it with." % ("cut" if operation == "subtract" else "intersect"))
	for id in tool_ids:
		if target_ids.has(id):
			return _bad("A body can't be both the target and the tool.")
	return _good("boolean-features", {"operation": operation, "target_body_ids": target_ids, "tool_body_ids": tool_ids, "consume_tool_bodies": consume})


static func merge_request(body_ids: Array) -> Dictionary:
	if body_ids.size() < 2:
		return _bad("Pick at least two bodies to merge.")
	return _good("merge-features", {"body_ids": body_ids})


static func split_request(target_body_id: String, plane_ref: Dictionary) -> Dictionary:
	## Divides a body in two along a plane ({fixed_plane} | {face_ref} | {plane_feature_id}).
	if target_body_id == "":
		return _bad("Pick the body to split first.")
	if plane_ref.is_empty():
		return _bad("Pick the plane or flat face to split along.")
	return _good("split-features", {"target_body_id": target_body_id, "tool": {"plane_ref": plane_ref}})


static func move_face_request(face_refs: Array, offset: float) -> Dictionary:
	## Pushes (or pulls) the picked faces of one body along their normals by `offset` mm.
	if face_refs.is_empty():
		return _bad("Pick the faces to move first.")
	if is_zero_approx(offset):
		return _bad("The distance can't be zero.")
	return _good("move-face-features", {"face_refs": face_refs, "offset_distance": offset})


static func delete_face_request(face_refs: Array) -> Dictionary:
	if face_refs.is_empty():
		return _bad("Pick the faces to delete first.")
	return _good("delete-face-features", {"face_refs": face_refs})


static func move_body_request(body_id: String, delta: Array, make_copy: bool) -> Dictionary:
	if body_id == "":
		return _bad("Pick the body to move first.")
	if is_zero_approx(float(delta[0])) and is_zero_approx(float(delta[1])) and is_zero_approx(float(delta[2])):
		return _bad("Move it by something: set X, Y or Z.")
	return _good("move-body-features", {"body_id": body_id, "delta": [float(delta[0]), float(delta[1]), float(delta[2])], "make_copy": make_copy})


static func scale_body_request(body_id: String, factor: float) -> Dictionary:
	if body_id == "":
		return _bad("Pick the body to scale first.")
	if factor <= 0.0:
		return _bad("The factor has to be bigger than zero.")
	return _good("scale-body-features", {"body_id": body_id, "factor": factor})


static func delete_body_request(body_ids: Array) -> Dictionary:
	if body_ids.is_empty():
		return _bad("Pick the bodies to delete first.")
	return _good("delete-body-features", {"body_ids": body_ids})


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
	var route: String = "%s-features" % feature_type.replace("_", "-") # every feature type's routes are named after it
	if feature_type == "":
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
		"delete_face_failed": "That face can't be deleted: there is nothing to heal the gap into. Delete Face removes fillets, chamfers, holes and bosses, not a plain wall.",
	}
	for key in known:
		if error.contains(key):
			return known[key]
	return error
