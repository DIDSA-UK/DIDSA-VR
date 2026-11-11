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


static func revolve_request(sketch_feature_id: String, sketch_id: String, axis_line_id: String, angle: float, boss: bool, target_body_ids: Array, extra: Dictionary = {}) -> Dictionary:
	## Spins the sketch's closed profile `angle` degrees (0-360) about one of the sketch's lines. Same Boss / Cut rule as extrude. `extra` may hold
	## `thickness` (a thin wall, > 0) and `thickness_direction`: a closed profile's wall reads against its material, an open chain's (outward = away
	## from the axis, inward = toward it) against the axis.
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	if axis_line_id == "":
		return _bad("Pick the line to spin it about first.")
	if angle <= 0.0 or angle > 360.0:
		return _bad("The angle has to be more than 0 and at most 360 degrees.")
	if extra.has("thickness") and float(extra["thickness"]) <= 0.0:
		return _bad("The wall thickness has to be bigger than zero.")
	var body := {
		"sketch_feature_id": sketch_feature_id,
		"axis_ref": {"sketch_id": sketch_id, "entity_type": "line", "entity_id": axis_line_id},
		"angle": angle,
		"mode": "boss" if boss else "cut",
		"target_body_ids": target_body_ids}
	body.merge(extra)
	return _good("revolve-features", body)


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


static func vertex_ref(body_id: String, index: int) -> Dictionary:
	return {"body_id": body_id, "shape_type": "vertex", "index": index}


static func plane_ref_of(base: Dictionary) -> Dictionary:
	## The backend's PlaneRef for a pick: a reference plane ({"fixed": "XY"}), a flat face ({"face": {body_id, index}}) or a plane already made ({"plane_feature_id": id}). {} if it is none of them.
	if base.has("fixed"):
		return {"fixed_plane": str(base["fixed"])}
	if base.has("face"):
		return {"face_ref": face_ref(str(base["face"]["body_id"]), int(base["face"]["index"]))}
	if base.has("plane_feature_id"):
		return {"plane_feature_id": str(base["plane_feature_id"])}
	return {}


static func create_plane_request(base: Dictionary, offset: float) -> Dictionary:
	## A plane offset from a reference plane, a flat face or a plane already made.
	if base.is_empty():
		return _bad("Pick a face or a plane to offset from first.")
	if is_zero_approx(offset):
		return _bad("The offset can't be zero.")
	var ref := plane_ref_of(base)
	if ref.is_empty():
		return _bad("Pick a face or a plane to offset from first.")
	return _good("create-plane-features", {"plane_type": "offset_face", "face_refs": [ref], "offset": offset})


static func create_plane_typed(method: String, bases: Array, edges: Array, vertices: Array) -> Dictionary:
	## The other construction methods (Phase 7.3). `bases` are plane picks (see plane_ref_of), `edges` / `vertices` are the picked entities {body_id, index}.
	## midplane: two planes. vertex: a plane and a corner, the new plane parallel to it through the corner. edge: a straight edge and a corner, normal to the edge through the corner.
	## points: three corners.
	match method:
		"midplane":
			if bases.size() < 2:
				return _bad("Pick two planes or flat faces, parallel to each other.")
			var refs: Array = bases.map(func(b): return plane_ref_of(b))
			if refs.any(func(r): return r.is_empty()):
				return _bad("Pick two planes or flat faces, parallel to each other.")
			return _good("create-plane-features", {"plane_type": "midplane", "face_refs": refs})
		"vertex":
			if bases.is_empty() or plane_ref_of(bases[0]).is_empty():
				return _bad("Pick a plane or a flat face first.")
			if vertices.is_empty():
				return _bad("Pick the corner the plane goes through.")
			return _good("create-plane-features", {"plane_type": "parallel_to_face_through_vertex", "face_refs": [plane_ref_of(bases[0])], "vertex_ref": vertex_ref(str(vertices[0]["body_id"]), int(vertices[0]["index"]))})
		"edge":
			if edges.is_empty():
				return _bad("Pick a straight edge first.")
			if vertices.is_empty():
				return _bad("Pick the corner the plane goes through.")
			return _good("create-plane-features", {"plane_type": "normal_to_edge_through_vertex", "edge_ref": edge_ref(str(edges[0]["body_id"]), int(edges[0]["index"])), "vertex_ref": vertex_ref(str(vertices[0]["body_id"]), int(vertices[0]["index"]))})
		"points":
			if vertices.size() < 3:
				return _bad("Pick three corners (%d so far)." % vertices.size())
			return _good("create-plane-features", {"plane_type": "three_points", "point_refs": vertices.slice(0, 3).map(func(v): return {"vertex_ref": vertex_ref(str(v["body_id"]), int(v["index"]))})})
	return _bad("That way of making a plane isn't offered.")


static func loft_request(section_sketch_ids: Array, boss: bool, ruled: bool, target_body_ids: Array, wall: float = 0.0, wall_from_closed: bool = false, guide_refs: Array = []) -> Dictionary:
	## A loft through two or more sections, each the closed profile of a sketch (on its own plane). `wall` over 0 makes it a thin-walled loft:
	## `wall_from_closed` keeps the closed profiles and gives a hollow tube between them (the thin source for closed sections), otherwise the sections are open chains.
	## `guide_refs`: any number of guides that shape the surface, each an ordered chain of sketch entity refs ({sketch_id, entity_type, entity_id}); sent as
	## `guide_curves` (always, an empty list clears them on an edit). A ruled loft is straight between sections, so guides are not sent with one (the backend refuses the pair).
	if section_sketch_ids.size() < 2:
		return _bad("A loft needs at least two sections: pick a line of each of two different sketches.")
	if not boss and target_body_ids.is_empty():
		return _bad("There is nothing to cut yet.")
	for guide in guide_refs:
		if (guide as Array).is_empty():
			return _bad("A guide needs at least one curve.")
	var body := {"sections": section_sketch_ids.map(func(id): return {"sketch_feature_id": str(id)}), "mode": "boss" if boss else "cut",
		"ruled": ruled, "target_body_ids": target_body_ids, "guide_curves": [] if ruled else guide_refs}
	if wall > 0.0:
		body["thickness"] = wall
		body["thin_from_closed_profile"] = wall_from_closed
	return _good("loft-features", body)


static func helix_request(h: Dictionary, plane_ref: Dictionary) -> Dictionary:
	## One helix curve (a curve feature, not a body) standing on `plane_ref` (the backend's axis_ref: the plane's normal is the axis, its origin the start, x axis
	## the start direction; {} = the XY plane). `h`: {radius, taper ("none" | "end_radius" | "angle"), taper_value, segments (Array of {pitch, turns}), right_handed,
	## and optionally points (Array of {at, pitch}): when it is not empty the pitch is given at distances along the axis instead, varying smoothly between them}.
	## The backend takes an end radius OR a taper angle (it returns both) and segments OR pitch points, every pitch the same sign.
	if float(h["radius"]) <= 0.0:
		return _bad("The radius has to be bigger than zero.")
	var points: Array = h.get("points", [])
	if not points.is_empty():
		return _helix_points_request(h, points, plane_ref)
	var segments: Array = h["segments"]
	if segments.is_empty():
		return _bad("A helix needs at least one segment (pitch and turns).")
	var out_segments: Array = []
	for i in segments.size():
		var seg: Dictionary = segments[i]
		if is_zero_approx(float(seg["pitch"])):
			return _bad("Segment %d: the pitch can't be zero." % (i + 1))
		if float(seg["turns"]) <= 0.0:
			return _bad("Segment %d: the turns have to be more than zero." % (i + 1))
		if (float(seg["pitch"]) > 0.0) != (float((segments[0] as Dictionary)["pitch"]) > 0.0):
			return _bad("Every segment has to go the same way along the axis (the pitches' signs differ).")
		out_segments.append({"pitch": float(seg["pitch"]), "turns": float(seg["turns"])})
	var body := {"curve_type": "helix", "axis_ref": plane_ref if not plane_ref.is_empty() else {"fixed_plane": "XY"}, "radius": float(h["radius"]),
		"segments": out_segments, "right_handed": bool(h["right_handed"])}
	return _helix_taper(body, h)


static func _helix_points_request(h: Dictionary, points: Array, plane_ref: Dictionary) -> Dictionary:
	## A variable-pitch helix: the pitch at distances from the start (the first at 0, then further along each time; the last is the height).
	if points.size() < 2:
		return _bad("A varying pitch needs at least two points (the start and the end).")
	if not is_zero_approx(float((points[0] as Dictionary)["at"])):
		return _bad("The first pitch point is at the start (0 mm).")
	var out_points: Array = []
	for i in points.size():
		var point: Dictionary = points[i]
		if is_zero_approx(float(point["pitch"])):
			return _bad("Point %d: the pitch can't be zero." % (i + 1))
		if (float(point["pitch"]) > 0.0) != (float((points[0] as Dictionary)["pitch"]) > 0.0):
			return _bad("Every pitch has to go the same way along the axis (the signs differ).")
		if i > 0 and float(point["at"]) <= float((points[i - 1] as Dictionary)["at"]):
			return _bad("Point %d has to be further along than point %d." % [i + 1, i])
		out_points.append({"at": float(point["at"]), "pitch": float(point["pitch"])})
	var body := {"curve_type": "helix", "axis_ref": plane_ref if not plane_ref.is_empty() else {"fixed_plane": "XY"}, "radius": float(h["radius"]),
		"pitch_points": out_points, "right_handed": bool(h["right_handed"])}
	return _helix_taper(body, h)


static func _helix_taper(body: Dictionary, h: Dictionary) -> Dictionary:
	match str(h["taper"]):
		"end_radius":
			if float(h["taper_value"]) <= 0.0:
				return _bad("The end radius has to be bigger than zero.")
			body["end_radius"] = float(h["taper_value"])
		"angle":
			if absf(float(h["taper_value"])) >= 90.0:
				return _bad("The taper angle has to be under 90 degrees.")
			body["taper_angle_degrees"] = float(h["taper_value"])
	return _good("curve-features", body)


const SPRING_ENDS := ["closed_ground", "closed", "open"] ## the backend's SpringEnd values, in the order the tool cycles them


static func spring_request(sp: Dictionary, plane_ref: Dictionary) -> Dictionary:
	## One compression spring (a Boss: a new body) from its numbers, standing on `plane_ref` (its normal is the axis, its origin the base centre; {} = the XY plane).
	## `sp`: {mean, wire, length, coils, start_end, finish_end, right_handed}; the mean diameter is through the wire centre. The backend works the pitch out
	## from the free length and refuses a free length the coils cannot reach (it says the solid length).
	var mean := float(sp["mean"])
	var wire := float(sp["wire"])
	if wire <= 0.0 or float(sp["length"]) <= 0.0:
		return _bad("The wire diameter and the free length have to be bigger than zero.")
	if mean <= wire:
		return _bad("The mean diameter has to be bigger than the wire diameter.")
	if float(sp["coils"]) < 1.0:
		return _bad("A spring needs at least 1 active coil.")
	for key in ["start_end", "finish_end"]:
		if not SPRING_ENDS.has(str(sp[key])):
			return _bad("An end is open, closed or closed and ground.")
	var body := {"mean_diameter": mean, "wire_diameter": wire, "free_length": float(sp["length"]), "active_coils": float(sp["coils"]),
		"start_end": str(sp["start_end"]), "finish_end": str(sp["finish_end"]), "right_handed": bool(sp["right_handed"])}
	if not plane_ref.is_empty():
		body["plane_ref"] = plane_ref
	return _good("spring-features", body)


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


static func move_face_request(face_refs: Array, offset: float, direction_axis: String = "") -> Dictionary:
	## Pushes (or pulls) the picked faces of one body by `offset` mm: along each face's own normal, or (with `direction_axis` "x" / "y" / "z") along that world axis.
	if face_refs.is_empty():
		return _bad("Pick the faces to move first.")
	if is_zero_approx(offset):
		return _bad("The distance can't be zero.")
	if direction_axis != "":
		if not direction_axis in ["x", "y", "z"]:
			return _bad("A direction from a sketch line can't be set here yet; use X, Y or Z.")
		return _good("move-face-features", {"face_refs": face_refs, "direction_ref": {"fixed_axis": direction_axis}, "direction_distance": offset})
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


static func gear_request(g: Dictionary, plane_ref: Dictionary) -> Dictionary:
	## One spur gear (a Boss: a new body) built from its numbers: external or internal, straight, helical (`helix` degrees, negative the other hand) or herringbone,
	## with an optional through bore (external only). `g`: {internal, module, teeth, face, pressure_angle, helix, herringbone, bore, outer, backlash, fillet, shift (null = auto)}.
	## `plane_ref` {} = the backend's default (the part's XY plane).
	if float(g["module"]) <= 0.0:
		return _bad("The module has to be bigger than zero.")
	if int(g["teeth"]) < 3:
		return _bad("A gear needs at least 3 teeth.")
	if float(g["face"]) <= 0.0:
		return _bad("The face width has to be bigger than zero.")
	if absf(float(g["helix"])) >= 90.0:
		return _bad("The helix angle has to be under 90 degrees.")
	if bool(g["internal"]) and float(g["outer"]) <= 0.0:
		return _bad("An internal gear needs its outer diameter.")
	var internal := bool(g["internal"])
	var helix := float(g["helix"])
	var body := {
		"gear_type": "boss",
		"is_internal": internal,
		"module": float(g["module"]),
		"tooth_count": int(g["teeth"]),
		"face_width": float(g["face"]),
		"pressure_angle_degrees": float(g["pressure_angle"]),
		"backlash": float(g["backlash"]),
		"root_fillet_radius": float(g["fillet"]),
		"helix_angle_degrees": helix,
		"herringbone": bool(g["herringbone"]) and not is_zero_approx(helix),
		"bore_diameter": 0.0 if internal else float(g["bore"]),
		"target_body_ids": []}
	if internal:
		body["outer_diameter"] = float(g["outer"])
	if g["shift"] != null:
		body["profile_shift"] = float(g["shift"])
	if not plane_ref.is_empty():
		body["plane_ref"] = plane_ref
	return _good("gear-features", body)


static func rack_request(r: Dictionary, plane_ref: Dictionary) -> Dictionary:
	## One straight rack (a Boss: a new body). `r`: {module, teeth, face, pressure_angle, backlash, backing (0 = the backend's default, 2 x module)}.
	if float(r["module"]) <= 0.0:
		return _bad("The module has to be bigger than zero.")
	if int(r["teeth"]) < 1:
		return _bad("A rack needs at least one tooth.")
	if float(r["face"]) <= 0.0:
		return _bad("The face width has to be bigger than zero.")
	var body := {
		"rack_type": "boss",
		"module": float(r["module"]),
		"tooth_count": int(r["teeth"]),
		"face_width": float(r["face"]),
		"pressure_angle_degrees": float(r["pressure_angle"]),
		"backlash": float(r["backlash"]),
		"target_body_ids": []}
	if float(r["backing"]) > 0.0:
		body["backing_height"] = float(r["backing"])
	if not plane_ref.is_empty():
		body["plane_ref"] = plane_ref
	return _good("rack-features", body)


static func bevel_gear_request(b: Dictionary, plane_ref: Dictionary) -> Dictionary:
	## One straight (or spiral) bevel gear (a Boss: a new body) with an optional through bore. `b`: {module, teeth, face, cone, pressure_angle, spiral, hand, bore}.
	if float(b["module"]) <= 0.0:
		return _bad("The module has to be bigger than zero.")
	if int(b["teeth"]) < 3:
		return _bad("A gear needs at least 3 teeth.")
	if float(b["face"]) <= 0.0:
		return _bad("The face width has to be bigger than zero.")
	if float(b["cone"]) <= 0.0 or float(b["cone"]) > 90.0:
		return _bad("The pitch cone angle has to be more than 0 and at most 90 degrees.")
	if float(b["spiral"]) < 0.0 or float(b["spiral"]) >= 90.0:
		return _bad("The spiral angle has to be at least 0 and under 90 degrees.")
	var body := {
		"bevel_type": "boss",
		"module": float(b["module"]),
		"tooth_count": int(b["teeth"]),
		"face_width": float(b["face"]),
		"pitch_cone_angle_degrees": float(b["cone"]),
		"pressure_angle_degrees": float(b["pressure_angle"]),
		"spiral_angle_degrees": float(b["spiral"]),
		"spiral_hand": str(b["hand"]),
		"bore_diameter": float(b["bore"]),
		"target_body_ids": []}
	if not plane_ref.is_empty():
		body["plane_ref"] = plane_ref
	return _good("bevel-gear-features", body)


static func fillet_request(edges: Array, radius: float) -> Dictionary:
	if edges.is_empty():
		return _bad("Pick the edges to round first.")
	if radius <= 0.0:
		return _bad("The radius has to be bigger than zero.")
	return _good("fillet-features", {"edge_refs": edges, "radius": radius})


static func chamfer_request(edges: Array, distance: float, angle: float = 0.0, flip: bool = false) -> Dictionary:
	## `angle` over 0 (degrees, under 90) makes every edge a distance-and-angle chamfer (`edge_options`, keyed by each edge's index in `edge_refs`); `flip` swaps
	## which of an edge's two faces the distance is measured along. 0 is the plain symmetric chamfer.
	if edges.is_empty():
		return _bad("Pick the edges to chamfer first.")
	if distance <= 0.0:
		return _bad("The distance has to be bigger than zero.")
	if angle < 0.0 or angle >= 90.0:
		return _bad("The chamfer angle has to be more than 0 and less than 90 degrees.")
	var body := {"edge_refs": edges, "distance": distance}
	if angle > 0.0:
		var options := {}
		for i in edges.size():
			options[str(i)] = {"angle": angle, "flip": flip}
		body["edge_options"] = options
	return _good("chamfer-features", body)


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
	var route: String = "%s-features" % str(ROUTE_TYPES.get(feature_type, feature_type)).replace("_", "-") # every feature type's routes are named after it (a tool whose id is not its backend type is mapped)
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
	var warnings: Array = (json.get("warnings", []) as Array) if json is Dictionary and json.get("warnings") is Array else []
	return {"ok": true, "id": str(json.get("id", "")) if json is Dictionary else "", "error": "", "warnings": warnings}


const ROUTE_TYPES := {"helix": "curve"} ## tool id -> the backend feature type, where they differ (the Helix tool makes a curve feature)


static func _plain(error: String) -> String:
	## The backend's reason, in words a status line can carry.
	var known := {
		"non_planar_reference": "That face isn't flat.",
		"missing_reference": "An edge or face it needs isn't there any more.",
		"bore_too_large": "The bore is too big for the gear: it has to stay under 90% of the root diameter.",
		"bore_on_internal_gear": "An internal gear is a ring already and takes no bore.",
		"invalid_bore": "The bore can't be negative.",
		"delete_face_failed": "That face can't be deleted: there is nothing to heal the gap into. Delete Face removes fillets, chamfers, holes and bosses, not a plain wall.",
	}
	for key in known:
		if error.contains(key):
			return known[key]
	return error
