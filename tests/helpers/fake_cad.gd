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
var feature_rows := {} ## part id -> the rows GET .../features answers with (and PATCH / cascade DELETE change)
var origin := false ## whether GET .../sketches/{id} (which creates the sketch's origin point, as the real backend does, lazily) is routed
var origin_id := ""
var ref_points := {} ## "body:vertex index" -> the pinned point POST .../convert-entities/vertex made for it (idempotent, like the real route)
var vertex_positions := {} ## "body:vertex index" -> where that vertex lands in the sketch (default (index, 0))
var edge_circles := {} ## "body:edge index" -> {c: Vector2, r: float, full: bool}: the circular edges (coplanar with the sketch) POST .../convert-entities/edge turns into a circle / arc
var circle_made := {} ## "body:edge index" -> the circle / arc id that route made (idempotent per edge, like the real route since the references overhaul: a second call answers with the one already made)
var reference_rows = null ## what GET .../external-references answers with (an Array), or null for "no such route"
var reattached: Array = [] ## [point id, body, vertex / edge index] of each POST .../reattach
var confirmed: Array = [] ## point ids of each POST .../confirm
var pinned := {} ## point ids the backend reports as is_locked
var sketch_plane: Variant = null ## what GET .../sketches/{id} says the plane is ("XY" for a reference plane, null for one made on a face)
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
	if fail != "" and path.contains(fail) and verb == "POST":
		return {"ok": false, "code": 422, "json": {"detail": "nope"}, "error": "nope"}
	if verb == "GET" and path.ends_with("/features"):
		return _ok(feature_rows.get(path.get_slice("/", 3), []))
	if verb == "PATCH" and (path.contains("/extrude-features/") or path.contains("/revolve-features/") or path.contains("/fillet-features/") or path.contains("/chamfer-features/")):
		var rows: Array = feature_rows.get(path.get_slice("/", 3), [])
		for row in rows:
			if row["id"] == path.get_file():
				for key in body:
					row[key] = body[key]
		return _ok({"id": path.get_file()})
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
	if verb == "POST" and (path.ends_with("/extrude-features") or path.ends_with("/revolve-features") or path.ends_with("/shell-features") or path.ends_with("/mirror-features") or path.ends_with("/fillet-features") or path.ends_with("/chamfer-features")):
		return _ok({"id": next_id("feat")})
	if verb == "DELETE" and path.contains("/features/"):
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
	if path.ends_with("/convert-entities/edge") and verb == "POST":
		var ekey := "%s:%d" % [body["body_id"], int(body["edge_index"])]
		if not edge_circles.has(ekey):
			var chord_a := next_id("pt")
			var chord_b := next_id("pt")
			points[chord_a] = Vector2.ZERO
			points[chord_b] = Vector2(10, 0)
			pinned[chord_a] = true
			pinned[chord_b] = true
			var chord := next_id("ln")
			entities.append({"type": "line", "id": chord, "start_point_id": chord_a, "end_point_id": chord_b, "construction": bool(body.get("construction", false))})
			return {"ok": true, "code": 201, "json": {"line": {"id": chord}, "start_point": {"id": chord_a, "x": 0.0, "y": 0.0, "is_locked": true}, "end_point": {"id": chord_b, "x": 10.0, "y": 0.0, "is_locked": true}}, "error": ""}
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
		var vkey := "%s:%d" % [body["body_id"], int(body["vertex_index"])]
		if not ref_points.has(vkey):
			var rid := next_id("pt")
			points[rid] = vertex_positions.get(vkey, Vector2(float(body["vertex_index"]), 0.0))
			ref_points[vkey] = rid
			pinned[rid] = true
		return _ok({"id": ref_points[vkey], "x": points[ref_points[vkey]].x, "y": points[ref_points[vkey]].y, "is_locked": true})
	if path.ends_with("/points") and verb == "POST":
		var id := next_id("pt")
		points[id] = Vector2(body["x"], body["y"])
		return _ok({"id": id, "x": body["x"], "y": body["y"], "is_locked": false})
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
			plist.append({"id": id, "x": points[id].x, "y": points[id].y, "is_locked": pinned.has(id)})
		var has_loop := entities.any(func(e): return e["type"] in ["rectangle", "circle", "polygon", "slot"])
		return _ok({"solve": {"converged": converge, "dof": 2}, "points": plist, "constraints": cons.values(), "profile": {"status": "closed_loop" if has_loop else "no_loop"}})
	if path.ends_with("/export"):
		return _ok({"entities": entities})
	return {"ok": false, "code": 404, "json": null, "error": "unrouted " + path}

func _ok(json) -> Dictionary:
	return {"ok": true, "code": 200, "json": json, "error": ""}

func paths() -> Array:
	return calls.map(func(c): return c[0])

func count(fragment: String) -> int:
	return paths().filter(func(p): return p.contains(fragment)).size()


