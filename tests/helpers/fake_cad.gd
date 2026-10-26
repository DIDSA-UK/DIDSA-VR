extends RefCounted
## A small FAKE of the DIDSA-CAD backend's part-editing routes, shared by the design table's tests: it speaks the real routes'
## shapes (sketch points / lines / rectangles / circles / arcs / polygons / constraints / solve-and-refresh / export, planes,
## sketch features, extrude / fillet / chamfer, occurrences) closely enough that the exact call sequences can be pinned
## without a server. It also looks like cad_api.gd (is_configured / request / fetch_bytes), so it can stand in for the
## table's api object. The real thing is tests/e2e_design_table.gd.
##
## Knobs: `fail` (a path fragment whose POSTs fail with a 422), `converge`, `occurrences` (owner id -> rows for GET
## .../occurrences), `plane_for` (Callable(body) -> the plane a create-plane call answers with), `mesh_bytes`.

var calls: Array = [] ## ["POST /path", body]
var points := {}
var entities: Array = [] ## export-shaped dicts
var cons := {}
var n := 0
var fail := "" ## a path fragment whose POST should fail with a 422
var converge := true
var occurrences := {}
var plane_for: Callable = Callable()
var mesh_bytes := PackedByteArray()
var mesh_ok := true
var configured := true
var created_parts: Array = [] ## {id, name} for each POST /document/parts
var feature_warnings: Array = [] ## the non-blocking notes a feature POST / PATCH answers with (the real backend: a loft guide bent to meet a section)
var track_rows := false ## opt-in: a POST of a feature adds its row to feature_rows (the request body merged in) and a DELETE of it takes the row away, like the real backend
var feature_rows := {} ## part id -> the rows GET .../features answers with (and PATCH / cascade DELETE change)
var origin := false ## whether GET .../sketches/{id} (which creates the sketch's origin point, as the real backend does, lazily) is routed
var origin_id := ""
var ref_points := {} ## "body:vertex index" -> the pinned point POST .../convert-entities/vertex made for it (idempotent, like the real route)
var vertex_positions := {} ## "body:vertex index" -> where that vertex lands in the sketch (default (index, 0))
var edge_circles := {} ## "body:edge index" -> {c: Vector2, r: float, full: bool}: the circular edges (coplanar with the sketch) POST .../convert-entities/edge turns into a circle / arc
var circle_made := {} ## "body:edge index" -> the circle / arc id that route made (idempotent per edge, like the real route since the references overhaul: a second call answers with the one already made)
var edge_ellipses := {} ## "body:edge index" -> {c: Vector2, a: float, b: float}: the full elliptical edges POST .../convert-entities/edge turns into a pinned ellipse (idempotent per edge)
var ellipse_made := {}
var reference_rows = null ## what GET .../external-references answers with (an Array), or null for "no such route"
var reattached: Array = [] ## [point id, body, vertex / edge index] of each POST .../reattach
var confirmed: Array = [] ## point ids of each POST .../confirm
var pinned := {} ## point ids the backend reports as is_locked
var sketch_plane: Variant = null ## what GET .../sketches/{id} says the plane is ("XY" for a reference plane, null for one made on a face)
var reference_ids := {} ## id -> true: what a convert route asked to be a reference helper made (points and shapes), as the real backend's Sketch.reference_ids
var edge_vertices_for: Callable = Callable() ## Callable(body id, edge index) -> [vertex index a, vertex index b]: the two corners of a STRAIGHT edge, for POST .../convert-entities/edge on one
var face_lines := {} ## "body:face index" -> [vertex index a, vertex index b]: a flat face seen edge-on, for POST .../convert-entities/face
var face_axes := {} ## "body:face index" -> Vector2: where a round face's axis is, for POST .../convert-entities/face
var reference_dimensions := {} ## id -> {id, kind, refs: [{type, id}]}: the reference (driven) dimensions POST .../reference-dimensions made (value computed on read, like the real backend)
var face_made := {} ## "body:face index" -> the answer that route gave (idempotent per face, like the real one)
var coarse_bodies: Array = [] ## what POST .../coarse-preview answers with: [{body_id, source, mesh: {vertices, normals, triangle_indices, ...}}]
var split_trim_fails := false ## POST .../split-trim answers 422 (the client then falls back to trim)
var trim_fails := false ## POST .../trim (and a circle / arc trim) answers 422
var view_filters := true ## whether the (fake) backend's OpenAPI lists the glb's hidden / rollback parameters
var filtered_mesh_bytes := PackedByteArray() ## what a glb fetch WITH hidden_feature_ids / rollback_excluded_feature_ids answers


func is_configured() -> bool:
	return configured


func request(method: int, path: String, body = null) -> Dictionary:
	return handle(method, path, body)


func supports_view_filters() -> bool:
	calls.append(["GET /openapi.json", null])
	return view_filters


func fetch_bytes(path: String) -> Dictionary:
	calls.append(["GET " + path, null])
	var filtered := path.contains("hidden_feature_ids") or path.contains("rollback_excluded_feature_ids")
	return {"ok": mesh_ok, "code": 200, "json": null, "bytes": filtered_mesh_bytes if filtered else mesh_bytes, "error": ""}


func next_id(prefix: String) -> String:
	n += 1
	return "%s%d" % [prefix, n]


func handle(method: int, path: String, body) -> Dictionary:
	var verb: String = {HTTPClient.METHOD_POST: "POST", HTTPClient.METHOD_GET: "GET", HTTPClient.METHOD_DELETE: "DELETE", HTTPClient.METHOD_PATCH: "PATCH"}[method]
	calls.append([verb + " " + path, body])
	if fail != "" and path.contains(fail) and (verb == "POST" or verb == "PATCH"):
		return {"ok": false, "code": 422, "json": {"detail": "nope"}, "error": "nope"}
	if verb == "GET" and path.ends_with("/features"):
		var listed: Array = feature_rows.get(path.get_slice("/", 3), [])
		return _ok(listed.duplicate(true) if track_rows else listed) # (the real backend answers with a fresh list: a tracking fake must not hand out the one it appends to)
	if verb == "POST" and path.contains("/sketch/sketches/") and (path.ends_with("/split-trim") or path.ends_with("/trim") or path.ends_with("/offset")):
		var kind := "circle" if path.contains("/circles/") else ("arc" if path.contains("/arcs/") else "line")
		if path.ends_with("/offset"):
			return _ok({kind: {"id": next_id("off")}})
		if path.ends_with("/split-trim") and split_trim_fails:
			return {"ok": false, "code": 422, "json": {"detail": "no crossings"}, "error": "no crossings"}
		if trim_fails:
			return {"ok": false, "code": 422, "json": {"detail": "no crossings"}, "error": "no crossings"}
		return _ok({"line1": {"id": "t1"}, "line2": {"id": "t2"}, "line": {"id": "t1"}, "arc": {"id": "t1"}})
	if verb == "POST" and path.contains("/sketch/sketches/") and (path.ends_with("/ellipses") or path.ends_with("/ellipse-arcs") or path.ends_with("/splines") or path.ends_with("/texts")):
		return _ok({"id": next_id("crv")})
	if verb == "GET" and path.contains("/sketch/sketches/") and path.ends_with("/preview") and path.contains("/texts/"):
		return _ok({"contours": [{"outer": [[0, 0], [5, 0], [5, 8], [0, 8]], "holes": []}]})
	if verb == "PATCH" and path.contains("/sketch/sketches/") and (path.contains("/ellipses/") or path.contains("/ellipse-arcs/") or path.contains("/splines/") or path.contains("/texts/")):
		return _ok({"id": path.get_file()})
	if verb == "POST" and path.contains("/coarse-preview"):
		return _ok(coarse_bodies)
	if verb == "POST" and path == "/document/gear/preview" and body is Dictionary: # the standard-tooth circles of a gear (zero profile shift)
		var m := float(body["module"])
		var z := float(body["tooth_count"])
		var sign := -1.0 if str(body["gear_kind"]) == "internal" else 1.0
		return _ok({"gear_kind": body["gear_kind"], "pitch_radius": m * z / 2.0, "addendum_radius": m * (z + 2.0 * sign) / 2.0, "dedendum_radius": m * (z - 2.5 * sign) / 2.0, "warnings": []})
	if verb == "PATCH" and path.contains("-features/"):
		var rows: Array = feature_rows.get(path.get_slice("/", 3), [])
		for row in rows:
			if row["id"] == path.get_file():
				for key in body:
					row[key] = body[key]
				# a replacement reference is re-measured by the real backend and its lost / moved flags go (backend/tests/test_reference_reattach_features.py)
				if body.has("edge_refs") or body.has("faces_to_remove") or body.has("mirror_plane") or body.has("face_refs") or body.has("edge_ref"):
					row["lost_references"] = []
					row["moved_references"] = []
					row["has_lost_reference"] = false
		return _ok({"id": path.get_file(), "warnings": feature_warnings})
	if verb == "DELETE" and path.ends_with("/cascade"):
		var owner := path.get_slice("/", 3)
		var rows: Array = feature_rows.get(owner, [])
		var BuildTree = load("res://scripts/design_table/build_tree.gd")
		var victim: String = path.get_slice("/", 5)
		var gone: Array = BuildTree.dependents(rows, victim)
		gone.append(victim)
		feature_rows[owner] = rows.filter(func(r): return not gone.has(r["id"]))
		return _ok({"deleted_feature_ids": gone, "deleted_sketch_ids": []})
	if verb == "POST" and path == "/document/new":
		occurrences.clear()
		created_parts.clear()
		return {"ok": true, "code": 201, "json": {"document_id": "doc1", "part_ids": []}, "error": ""}
	if verb == "POST" and path == "/document/parts":
		var part_id := next_id("part")
		created_parts.append({"id": part_id, "name": body["name"]})
		return {"ok": true, "code": 201, "json": {"id": part_id, "name": body["name"]}, "error": ""}
	if verb == "POST" and path.ends_with("/occurrences"):
		var owner := path.get_slice("/", 3)
		var rows: Array = occurrences.get(owner, [])
		rows.append({"id": body["id"], "resolved_part_id": body.get("resolved_part_id"), "name_override": body.get("name_override"), "transform": body.get("transform")})
		occurrences[owner] = rows
		return {"ok": true, "code": 201, "json": body, "error": ""}
	if verb == "DELETE" and path.contains("/occurrences/"):
		var owner := path.get_slice("/", 3)
		occurrences[owner] = (occurrences.get(owner, []) as Array).filter(func(o): return o["id"] != path.get_file())
		return {"ok": true, "code": 204, "json": null, "error": ""}
	if verb == "GET" and path.ends_with("/occurrences"):
		return _ok(occurrences.get(path.get_slice("/", 3), []))
	if verb == "POST" and path.ends_with("-features") and not path.ends_with("/create-plane-features"):
		var made := next_id("feat")
		if track_rows:
			var row: Dictionary = (body as Dictionary).duplicate(true) if body is Dictionary else {}
			row["id"] = made
			row["type"] = path.get_file().trim_suffix("-features").replace("-", "_")
			var owner_rows: Array = feature_rows.get(path.get_slice("/", 3), [])
			owner_rows.append(row)
			feature_rows[path.get_slice("/", 3)] = owner_rows
		return _ok({"id": made, "warnings": feature_warnings})
	if verb == "DELETE" and path.contains("/features/"):
		if track_rows:
			var owner_id := path.get_slice("/", 3)
			feature_rows[owner_id] = (feature_rows.get(owner_id, []) as Array).filter(func(r): return r["id"] != path.get_file())
		return _ok(null)
	if verb == "PATCH" and path.contains("/mates/"):
		return _ok({})
	if verb == "PATCH" and path.begins_with("/document/parts/") and path.count("/") == 3:
		return _ok({"id": path.get_file(), "name": body.get("name", "")})
	if verb == "POST" and path.ends_with("/mates"):
		return _ok({"id": next_id("mate")})
	if path.ends_with("/create-plane-features"):
		if plane_for.is_valid():
			var answer: Dictionary = plane_for.call(body)
			answer["id"] = "plane1"
			return _ok(answer)
		return _ok({"id": "plane1", "origin": [0, 0, 10], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]})
	if verb == "GET" and path.contains("/sketch/sketches/") and path.count("/") == 3:
		if not origin:
			return {"ok": false, "code": 404, "json": null, "error": "no such route"}
		if origin_id == "":
			origin_id = next_id("pt")
			points[origin_id] = Vector2.ZERO
		return _ok({"id": path.get_file(), "plane": sketch_plane, "origin_point_id": origin_id, "flip": false, "rotation_quarter_turns": 0})
	if path.ends_with("/features/sketch"):
		return _ok({"id": "feat1", "sketch_id": "sk1", "plane_feature_id": body.get("plane_feature_id")})
	if path.ends_with("/convert-entities/edge") and verb == "POST" and edge_ellipses.has("%s:%d" % [body["body_id"], int(body["edge_index"])]):
		var ellipse_key := "%s:%d" % [body["body_id"], int(body["edge_index"])]
		if not ellipse_made.has(ellipse_key):
			var spec: Dictionary = edge_ellipses[ellipse_key]
			var cid := next_id("pt")
			var mid := next_id("pt")
			var nid := next_id("pt")
			points[cid] = spec["c"]
			points[mid] = spec["c"] + Vector2(spec["a"], 0)
			points[nid] = spec["c"] + Vector2(0, spec["b"])
			for pid in [cid, mid, nid]:
				pinned[pid] = true
				if bool(body.get("reference", false)):
					reference_ids[pid] = true
			var eid := next_id("el")
			entities.append({"type": "ellipse", "id": eid, "center_point_id": cid, "major_point_id": mid, "minor_point_id": nid, "major_constraint_id": "", "minor_constraint_id": "", "construction": true})
			if bool(body.get("reference", false)):
				reference_ids[eid] = true
			ellipse_made[ellipse_key] = {"id": eid, "center_point_id": cid, "major_point_id": mid, "minor_point_id": nid}
		var made: Dictionary = ellipse_made[ellipse_key]
		var cpt: Dictionary = {"id": made["center_point_id"], "x": points[made["center_point_id"]].x, "y": points[made["center_point_id"]].y, "is_locked": true}
		return _ok({"ellipse": {"id": made["id"], "is_reference": reference_ids.has(made["id"])}, "start_point": cpt, "end_point": cpt, "center_point": cpt})
	if path.ends_with("/convert-entities/edge") and verb == "POST":
		var ekey := "%s:%d" % [body["body_id"], int(body["edge_index"])]
		var as_reference := bool(body.get("reference", false))
		if not edge_circles.has(ekey):
			if not edge_vertices_for.is_valid():
				return {"ok": false, "code": 422, "json": {"detail": "no such edge"}, "error": "no such edge"}
			var ends: Array = edge_vertices_for.call(str(body["body_id"]), int(body["edge_index"]))
			var chord_a := _vertex_point(str(body["body_id"]), int(ends[0]), as_reference)
			var chord_b := _vertex_point(str(body["body_id"]), int(ends[1]), as_reference)
			var chord := ""
			for existing in entities:
				if existing["type"] == "line" and [existing["start_point_id"], existing["end_point_id"]].has(chord_a) and [existing["start_point_id"], existing["end_point_id"]].has(chord_b):
					chord = existing["id"]
			if chord == "":
				chord = next_id("ln")
				entities.append({"type": "line", "id": chord, "start_point_id": chord_a, "end_point_id": chord_b, "construction": bool(body.get("construction", false))})
				if as_reference:
					reference_ids[chord] = true
			return {"ok": true, "code": 201, "json": {"line": {"id": chord, "start_point_id": chord_a, "end_point_id": chord_b, "construction": bool(body.get("construction", false)), "is_reference": reference_ids.has(chord)}, "start_point": _point_json(chord_a), "end_point": _point_json(chord_b)}, "error": ""}
		var shape: Dictionary = edge_circles[ekey]
		if circle_made.has(ekey):
			for existing in entities:
				if existing["id"] == circle_made[ekey]:
					var old_centre: String = existing["center_point_id"]
					var old_resp := {"id": old_centre, "x": points[old_centre].x, "y": points[old_centre].y, "is_locked": true}
					if existing["type"] == "circle":
						return {"ok": true, "code": 201, "json": {"circle": {"id": existing["id"], "center_point_id": old_centre, "radius_point_id": existing["radius_point_id"], "radius": shape["r"]}, "start_point": old_resp, "end_point": old_resp, "center_point": old_resp}, "error": ""}
					var old_start: String = existing["start_point_id"]
					var old_end: String = existing["end_point_id"]
					return {"ok": true, "code": 201, "json": {"arc": {"id": existing["id"], "center_point_id": old_centre, "start_point_id": old_start, "end_point_id": old_end}, "start_point": {"id": old_start, "x": points[old_start].x, "y": points[old_start].y, "is_locked": true}, "end_point": {"id": old_end, "x": points[old_end].x, "y": points[old_end].y, "is_locked": true}, "center_point": old_resp}, "error": ""}
		var centre_id := next_id("pt")
		var rim_id := next_id("pt")
		points[centre_id] = shape["c"]
		points[rim_id] = (shape["c"] as Vector2) + Vector2(float(shape["r"]), 0.0)
		pinned[centre_id] = true
		pinned[rim_id] = true
		ref_points["%s:c%d" % [body["body_id"], int(body["edge_index"])]] = centre_id
		var shape_id := next_id("ci" if bool(shape["full"]) else "ar")
		if bool(body.get("reference", false)):
			reference_ids[shape_id] = true
			reference_ids[centre_id] = true
			reference_ids[rim_id] = true
		var radius_k := next_id("k")
		# (the real route drops the provisional radius constraint of a converted shape, every point of which is pinned: it would only be redundant; the id stays on the entity)
		var centre_resp := {"id": centre_id, "x": points[centre_id].x, "y": points[centre_id].y, "is_locked": true}
		if bool(shape["full"]):
			entities.append({"type": "circle", "id": shape_id, "center_point_id": centre_id, "radius_point_id": rim_id, "radius_constraint_id": radius_k, "construction": bool(body.get("construction", false))})
			circle_made[ekey] = shape_id
			return {"ok": true, "code": 201, "json": {"circle": {"id": shape_id, "center_point_id": centre_id, "radius_point_id": rim_id, "radius": shape["r"]}, "start_point": centre_resp, "end_point": centre_resp, "center_point": centre_resp}, "error": ""}
		var end_id := next_id("pt")
		points[end_id] = (shape["c"] as Vector2) + Vector2(0.0, float(shape["r"]))
		pinned[end_id] = true
		entities.append({"type": "arc", "id": shape_id, "center_point_id": centre_id, "start_point_id": rim_id, "end_point_id": end_id, "radius_constraint_id": radius_k, "construction": bool(body.get("construction", false))})
		circle_made[ekey] = shape_id
		return {"ok": true, "code": 201, "json": {"arc": {"id": shape_id, "center_point_id": centre_id, "start_point_id": rim_id, "end_point_id": end_id}, "start_point": {"id": rim_id, "x": points[rim_id].x, "y": points[rim_id].y, "is_locked": true}, "end_point": {"id": end_id, "x": points[end_id].x, "y": points[end_id].y, "is_locked": true}, "center_point": centre_resp}, "error": ""}
	if verb == "GET" and path.ends_with("/external-references"):
		if reference_rows == null:
			return {"ok": false, "code": 404, "json": null, "error": "no such route"}
		return _ok(reference_rows)
	if verb == "POST" and path.contains("/external-references/") and path.ends_with("/reattach"):
		reattached.append([path.get_slice("/", path.count("/") - 1), body.get("body_id", ""), body.get("vertex_index", body.get("edge_index", -1))])
		return _ok({"id": path.get_slice("/", path.count("/") - 1), "x": 0.0, "y": 0.0, "is_locked": true})
	if verb == "POST" and path.contains("/external-references/") and path.ends_with("/confirm"):
		confirmed.append(path.get_slice("/", path.count("/") - 1))
		return _ok({"id": path.get_slice("/", path.count("/") - 1), "x": 0.0, "y": 0.0, "is_locked": true})
	if path.ends_with("/convert-entities/vertex") and verb == "POST":
		var vid := _vertex_point(str(body["body_id"]), int(body["vertex_index"]), bool(body.get("reference", false)))
		return _ok(_point_json(vid))
	if path.ends_with("/convert-entities/face") and verb == "POST":
		var fkey := "%s:%d" % [body["body_id"], int(body["face_index"])]
		var as_ref := bool(body.get("reference", false))
		if face_made.has(fkey):
			return _ok(face_made[fkey])
		if face_axes.has(fkey):
			var axis_id := next_id("pt")
			points[axis_id] = face_axes[fkey]
			pinned[axis_id] = true
			if as_ref:
				reference_ids[axis_id] = true
			face_made[fkey] = {"kind": "centre", "center_point": _point_json(axis_id)}
			return _ok(face_made[fkey])
		if face_lines.has(fkey):
			var fa := _vertex_point(str(body["body_id"]), int(face_lines[fkey][0]), as_ref)
			var fb := _vertex_point(str(body["body_id"]), int(face_lines[fkey][1]), as_ref)
			var fline := next_id("ln")
			entities.append({"type": "line", "id": fline, "start_point_id": fa, "end_point_id": fb, "construction": true})
			if as_ref:
				reference_ids[fline] = true
			face_made[fkey] = {"kind": "line", "line": {"id": fline, "start_point_id": fa, "end_point_id": fb, "construction": true, "is_reference": as_ref}, "start_point": _point_json(fa), "end_point": _point_json(fb)}
			return _ok(face_made[fkey])
		return {"ok": false, "code": 422, "json": {"detail": {"type": "face_not_perpendicular"}}, "error": "face_not_perpendicular"}
	if path.ends_with("/points") and verb == "POST":
		var id := next_id("pt")
		points[id] = Vector2(body["x"], body["y"])
		return _ok({"id": id, "x": body["x"], "y": body["y"], "is_locked": false})
	if path.contains("/reference-dimensions/") and verb == "DELETE":
		reference_dimensions.erase(path.get_file())
		_prune_reference_helpers()
		return _ok({})
	if verb == "DELETE":
		var tail: String = path.get_file()
		points.erase(tail)
		for e in entities:
			if e["id"] == tail and e["type"] == "rectangle": # the real backend takes a rectangle's lines with it
				var corners: Array = e["corner_point_ids"]
				entities = entities.filter(func(x): return not (x["type"] == "line" and x["start_point_id"] in corners and x["end_point_id"] in corners))
				break
		entities = entities.filter(func(e): return e["id"] != tail)
		cons.erase(tail)
		_prune_reference_helpers()
		return _ok({"pruned_point_ids": []})
	if path.ends_with("/lines"):
		var id := next_id("ln")
		entities.append({"type": "line", "id": id, "start_point_id": body["start_point_id"], "end_point_id": body["end_point_id"], "construction": bool(body.get("construction", false))})
		return _ok({"id": id})
	if path.ends_with("/rectangles"):
		var id := next_id("rc")
		var c: Array = body["corner_point_ids"]
		for i in 4:
			entities.append({"type": "line", "id": next_id("ln"), "start_point_id": c[i], "end_point_id": c[(i + 1) % 4], "construction": false})
		entities.append({"type": "rectangle", "id": id, "corner_point_ids": c})
		return _ok({"id": id})
	if path.ends_with("/circles"):
		var id := next_id("ci")
		var k := next_id("k")
		cons[k] = {"type": "distance", "id": k, "point_a_id": body["center_point_id"], "point_b_id": body["radius_point_id"], "distance": 1.0, "orientation": "linear", "provisional": true}
		entities.append({"type": "circle", "id": id, "center_point_id": body["center_point_id"], "radius_point_id": body["radius_point_id"], "radius_constraint_id": k})
		return _ok({"id": id})
	if path.ends_with("/arcs"):
		var id := next_id("ar")
		var end_id: String = body.get("end_point_id", "")
		if end_id == "":
			end_id = next_id("pt")
			points[end_id] = Vector2(1, 1)
		var k := next_id("k")
		entities.append({"type": "arc", "id": id, "center_point_id": body["center_point_id"], "start_point_id": body["start_point_id"], "end_point_id": end_id, "radius_constraint_id": k})
		return _ok({"id": id})
	if path.ends_with("/slots"):
		var id := next_id("sl")
		entities.append({"type": "slot", "id": id, "center1_point_id": body["center1_point_id"], "center2_point_id": body["center2_point_id"], "radius": body["radius"]})
		return _ok({"id": id})
	if path.ends_with("/polygons"):
		var id := next_id("pg")
		entities.append({"type": "polygon", "id": id, "center_point_id": body["center_point_id"], "vertex_point_ids": [body["first_vertex_point_id"]]})
		return _ok({"id": id})
	if path.ends_with("/constraints") and verb == "POST":
		var id := next_id("k")
		var c: Dictionary = body.duplicate()
		c["id"] = id
		cons[id] = c
		return _ok(c)
	if verb == "PATCH" and (path.contains("/lines/") or path.contains("/circles/") or path.contains("/arcs/")):
		for e in entities:
			if e["id"] == path.get_file():
				e["construction"] = bool(body.get("construction", e.get("construction", false)))
		return _ok({"id": path.get_file()})
	if path.contains("/constraints/") and verb == "PATCH":
		var k: String = path.get_file()
		cons[k]["distance"] = body["value"]
		cons[k]["provisional"] = false
		return _ok({"converged": converge})
	if path.ends_with("/solve-and-refresh"):
		var plist: Array = []
		for id in points:
			plist.append({"id": id, "x": points[id].x, "y": points[id].y, "is_locked": pinned.has(id), "is_reference": reference_ids.has(id)})
		var has_loop := entities.any(func(e): return e["type"] in ["rectangle", "circle", "polygon", "slot"])
		return _ok({"solve": {"converged": converge, "dof": 2}, "points": plist, "constraints": cons.values(), "profile": {"status": "closed_loop" if has_loop else "no_loop"}, "reference_dimensions": _reference_dimension_rows()})
	if path.ends_with("/export"):
		return _ok({"entities": entities, "reference_ids": reference_ids.keys(), "reference_dimensions": _reference_dimension_rows()})
	if path.ends_with("/reference-dimensions") and verb == "POST":
		for existing in reference_dimensions.values():
			if existing["kind"] == body["kind"] and existing["refs"] == body["refs"]:
				return _ok(_reference_dimension_row(existing))
		var rid := next_id("rd")
		reference_dimensions[rid] = {"id": rid, "kind": body["kind"], "refs": (body["refs"] as Array).duplicate(true)}
		return {"ok": true, "code": 201, "json": _reference_dimension_row(reference_dimensions[rid]), "error": ""}
	return {"ok": false, "code": 404, "json": null, "error": "unrouted " + path}

func _reference_dimension_rows() -> Array:
	return reference_dimensions.values().map(func(d): return _reference_dimension_row(d))


func _reference_dimension_row(d: Dictionary) -> Dictionary:
	## {id, kind, refs, value}: the value as the real backend computes it from where the points are now.
	var out: Dictionary = d.duplicate(true)
	out["value"] = _reference_dimension_value(d)
	return out


func _reference_dimension_value(d: Dictionary) -> Variant:
	var refs: Array = d["refs"]
	var types: Array = refs.map(func(r): return r["type"])
	var ids: Array = refs.map(func(r): return r["id"])
	match str(d["kind"]):
		"radius", "diameter":
			for e in entities:
				if e["id"] == ids[0] and points.has(e["center_point_id"]):
					var far: String = e.get("radius_point_id", e.get("start_point_id", ""))
					var r: float = (points[e["center_point_id"]] as Vector2).distance_to(points[far])
					return r if d["kind"] == "radius" else r * 2.0
			return null
		"distance", "horizontal", "vertical":
			var a: Vector2
			var b: Vector2
			if types == ["point", "point"] and points.has(ids[0]) and points.has(ids[1]):
				a = points[ids[0]]
				b = points[ids[1]]
			elif types == ["line"]:
				for e in entities:
					if e["id"] == ids[0]:
						a = points[e["start_point_id"]]
						b = points[e["end_point_id"]]
			elif types.has("point") and types.has("line"):
				var p: Vector2 = points[ids[types.find("point")]]
				for e in entities:
					if e["id"] == ids[types.find("line")]:
						return (Geometry2D.get_closest_point_to_segment(p, points[e["start_point_id"]], points[e["end_point_id"]])).distance_to(p) # (the real one is to the infinite line; the fake's lines are used within their length)
				return null
			else:
				return null
			return {"distance": a.distance_to(b), "horizontal": absf(b.x - a.x), "vertical": absf(b.y - a.y)}[str(d["kind"])]
	return 0.0


func _vertex_point(body_id: String, index: int, as_reference: bool) -> String:
	## The pinned point for a body vertex (idempotent, like the real route); flagged as a helper only when it is made for the first time and asked for as one.
	var vkey := "%s:%d" % [body_id, index]
	if not ref_points.has(vkey):
		var rid := next_id("pt")
		points[rid] = vertex_positions.get(vkey, Vector2(float(index), 0.0))
		ref_points[vkey] = rid
		pinned[rid] = true
		if as_reference:
			reference_ids[rid] = true
	elif not as_reference:
		reference_ids.erase(ref_points[vkey]) # an ordinary convert takes a helper over as real geometry
	return ref_points[vkey]


func _point_json(id: String) -> Dictionary:
	return {"id": id, "x": points[id].x, "y": points[id].y, "is_locked": pinned.has(id), "is_reference": reference_ids.has(id)}


func _prune_reference_helpers() -> void:
	## The real backend's Sketch.prune_unused_reference_helpers, coarsely: a flagged shape whose points no constraint and no unflagged shape uses goes, then the flagged points nothing holds.
	var changed := true
	while changed:
		changed = false
		for e in entities.duplicate():
			if not reference_ids.has(e["id"]) or not (e["type"] in ["line", "circle", "arc"]):
				continue
			var own: Array = [e.get("start_point_id", ""), e.get("end_point_id", ""), e.get("center_point_id", ""), e.get("radius_point_id", "")]
			var used := false
			for rd in reference_dimensions.values():
				for r in rd["refs"]:
					if own.has(str(r["id"])) or str(r["id"]) == e["id"]:
						used = true
			for k in cons.values():
				for key in ["point_id", "point_a_id", "point_b_id", "line_id", "start_point_id"]:
					if own.has(str(k.get(key, "x"))) or str(k.get(key, "")) == e["id"]:
						used = true
			for other in entities:
				if other["id"] != e["id"] and not reference_ids.has(other["id"]):
					for key in ["start_point_id", "end_point_id", "center_point_id", "radius_point_id"]:
						if own.has(str(other.get(key, "x"))):
							used = true
			if not used:
				entities = entities.filter(func(x): return x["id"] != e["id"])
				reference_ids.erase(e["id"])
				changed = true
		for id in points.keys():
			if not reference_ids.has(id):
				continue
			var held := false
			for rd in reference_dimensions.values():
				for r in rd["refs"]:
					if str(r["id"]) == id:
						held = true
			for e in entities:
				for key in ["start_point_id", "end_point_id", "center_point_id", "radius_point_id"]:
					if str(e.get(key, "x")) == id:
						held = true
			for k in cons.values():
				for key in ["point_id", "point_a_id", "point_b_id"]:
					if str(k.get(key, "x")) == id:
						held = true
			if not held:
				points.erase(id)
				reference_ids.erase(id)
				changed = true


func _ok(json) -> Dictionary:
	return {"ok": true, "code": 200, "json": json, "error": ""}

func paths() -> Array:
	return calls.map(func(c): return c[0])

func count(fragment: String) -> int:
	return paths().filter(func(p): return p.contains(fragment)).size()


