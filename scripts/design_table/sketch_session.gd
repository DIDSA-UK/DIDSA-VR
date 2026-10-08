extends RefCounted
## One open sketch on the design table: the backend sketch it lives on, a local copy of what the backend
## last said is in it, and the logic that turns taps on the sketch sheet into backend calls.
##
## No scene tree, no HTTP node: every call goes through `api`, a Callable (method: int, path: String, body) ->
## Dictionary {ok, code, json, error}, a coroutine. The real one is cad_api.gd's request(), which keeps calls
## strictly in order; tests pass a fake. Positions are the SKETCH SHEET's own millimetres (u, v), the same
## numbers the backend stores — scripts/design_table/sketch_math.gd turns them into the part's frame.
##
## The flow mirrors DIDSA-CAD's flat sketcher (client/lib/sketch/sketch_controller.dart), which the backend
## was built for:
##   * points are made first, then the entity that uses them (the backend never merges coincident points);
##   * a constraint does not solve — every change ends with ONE solve-and-refresh (points, constraints and
##     the closed-profile check in a single answer) plus an export when the entity set changed;
##   * the solved points are the truth. The first real length dimension rescales the whole sketch about its
##     first point, so nothing drawn is assumed to stay where it was tapped;
##   * a circle's, arc's or polygon's size is a "provisional" constraint until a value is PATCHed in, so a
##     typed radius is a PATCH of that constraint, not a new one;
##   * undo is the inverse call (delete what the last action made), as in the flat app, which has no redo.
##
## Tools (table_tools.gd ids): drawing tools take TAPS_NEEDED taps; constraint tools and Dimension take
## picked entities. The editor feeds taps in with tap() and entity picks with select().

signal changed ## the local model was refreshed from the backend
signal status(text: String) ## something worth telling the user (progress, a refusal, an error)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")

const SKETCH := "/sketch/sketches/"
const SELECT := "select" ## the tool that picks entities for the contextual menu (no limit on how many)
const TAPS_NEEDED := {"line": 2, "rectangle": 2, "circle": 2, "arc": 3, "polygon": 2, "point": 1, "slot": 3}
const SELECT_NEEDED := {"horizontal": 1, "vertical": 1, "parallel": 2, "perpendicular": 2, "coincident": 2}
const PARALLEL_COS := 0.9998 ## two lines closer than ~1.1 degrees to parallel are measured as a distance, not an angle
const AXIS_SNAP_DEGREES := 4.0 ## a line within this of horizontal / vertical is made exactly so

var api: Callable
var owner_part_id := ""
var feature_id := "" ## the sketch FEATURE (what an extrude names)
var sketch_id := ""
var plane_feature_id := ""
var plane: Dictionary = {} ## {origin, x, y, n} in the part's frame, mm
var revision := 0 ## counts solves: 1 right after opening, more once anything changed (the editor refreshes the part when a sketch is left with edits)
var origin_id := "" ## the sketch's real origin point (0, 0): fixed by the backend, snappable, constrainable, never deleted ("" on a backend that doesn't say)

var tool := ""
var pending: Array = [] ## taps so far for the current tool: [{uv, id}]
var polygon_sides := 6
var busy := false

var points := {} ## id -> Vector2 (sheet mm)
var point_locked := {} ## id -> bool
var lines := {} ## id -> {a, b, construction}
var circles := {} ## id -> {c, p, k, construction} (centre point, radius point, radius constraint id)
var arcs := {} ## id -> {c, s, e, k, construction}
var shapes := {} ## rectangle / polygon id -> {kind, point_ids}
var constraints := {} ## id -> the backend's constraint dictionary
var profile_status := ""
var dof := -1
var converged := true

var references_ok := false ## the part's own vertices and edges may be used as references (set by the editor: the topology it shows is the one the backend resolves against)
var selection: Array = [] ## picked entities for the constraint / dimension tools: [{kind, id}]
var ghosts: Array = [] ## dimension candidates for the current selection (see _build_ghosts)

var _ref_points := {} ## "body:vertex index" -> the pinned point made for it; "body:c<edge index>" -> the pinned centre of that circular edge
var reference_rows: Array = [] ## the backend's health of this sketch's references (GET .../external-references): [{point_id, body_id, kind, vertex_index, status, reason, candidates}]
var driven: Array = [] ## reference-only (driven) dimensions the user kept between pinned things: [{id, selection: [{kind, id}], key}]. They measure, they never drive: kept here, not on the backend
var _driven_n := 0
var _undo: Array = [] ## [{label, calls: [[method, path]]}]


func _init(p_api: Callable = Callable()) -> void:
	api = p_api


# --- Opening ---------------------------------------------------------------------------

func open_sketch(spec: Dictionary) -> bool:
	## spec: {"fixed": "XY"|"XZ"|"YZ"} for a reference plane, {"face": {body_id, index}} for a planar
	## face of the part (a plane is made on it first, exactly like the flat app's "New Sketch on Face"),
	## or {"plane_feature_id": id, "plane": basis} for an existing plane feature.
	if owner_part_id.is_empty():
		status.emit("No part to sketch on.")
		return false
	busy = true
	var feature_body := {}
	if spec.has("fixed"):
		plane = SketchMath.fixed_basis(str(spec["fixed"]))
		if plane.is_empty():
			busy = false
			status.emit("Unknown plane %s." % str(spec["fixed"]))
			return false
		feature_body = {"plane": str(spec["fixed"])}
	elif spec.has("face"):
		var face: Dictionary = spec["face"]
		var made: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/create-plane-features" % owner_part_id, {
			"plane_type": "offset_face",
			"face_refs": [{"face_ref": {"body_id": str(face["body_id"]), "shape_type": "face", "index": int(face["index"])}}],
			"offset": 0.0})
		if not made["ok"]:
			busy = false
			status.emit("Couldn't make a plane on that face: %s" % str(made["error"]))
			return false
		plane = SketchMath.basis_from_plane_response(made["json"])
		plane_feature_id = str(made["json"].get("id", ""))
		if plane.is_empty() or plane_feature_id.is_empty():
			busy = false
			status.emit("The backend couldn't resolve a plane on that face.")
			return false
		feature_body = {"plane_feature_id": plane_feature_id}
	elif spec.has("plane_feature_id"):
		plane_feature_id = str(spec["plane_feature_id"])
		plane = spec.get("plane", {})
		if plane.is_empty():
			busy = false
			return false
		feature_body = {"plane_feature_id": plane_feature_id}
	else:
		busy = false
		return false
	var sketch: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/features/sketch" % owner_part_id, feature_body)
	if not sketch["ok"]:
		busy = false
		status.emit("Couldn't open a sketch: %s" % str(sketch["error"]))
		return false
	sketch_id = str(sketch["json"]["sketch_id"])
	feature_id = str(sketch["json"]["id"])
	_undo.clear()
	# The backend makes the sketch's origin point lazily, the first time the sketch itself is read: read it, so the origin is a real point
	# (snappable, constrainable, the end of a dimension) like in the flat app.
	var described: Dictionary = await api.call(HTTPClient.METHOD_GET, SKETCH + sketch_id, null)
	if described["ok"] and described["json"] is Dictionary:
		origin_id = str((described["json"] as Dictionary).get("origin_point_id", ""))
	var refreshed := await refresh(true)
	await load_references()
	busy = false
	return refreshed


func reopen(sketch_feature: Dictionary, p_plane: Dictionary) -> bool:
	## Opens a sketch the part ALREADY has (a row of the Build tree) instead of making a new one: `sketch_feature` is the backend's feature
	## row ({id, sketch_id, plane_feature_id}), `p_plane` the plane's basis in the part's frame. Reads its points and entities, nothing is made.
	if owner_part_id.is_empty() or str(sketch_feature.get("sketch_id", "")).is_empty() or p_plane.is_empty():
		status.emit("That sketch can't be opened here.")
		return false
	busy = true
	plane = p_plane
	sketch_id = str(sketch_feature["sketch_id"])
	feature_id = str(sketch_feature.get("id", ""))
	var on_plane = sketch_feature.get("plane_feature_id")
	plane_feature_id = str(on_plane) if on_plane != null else ""
	_undo.clear()
	var described: Dictionary = await api.call(HTTPClient.METHOD_GET, SKETCH + sketch_id, null)
	if described["ok"] and described["json"] is Dictionary:
		origin_id = str((described["json"] as Dictionary).get("origin_point_id", ""))
	var refreshed := await refresh(true)
	await load_references()
	busy = false
	return refreshed


func is_origin(point_id: String) -> bool:
	return origin_id != "" and point_id == origin_id


func is_open() -> bool:
	return not sketch_id.is_empty()


# --- Reading the backend's answer --------------------------------------------------------

func refresh(with_entities: bool = true) -> bool:
	## ONE solve-and-refresh (points, constraints, profile), plus an export when entities changed.
	var state: Dictionary = await api.call(HTTPClient.METHOD_POST, SKETCH + sketch_id + "/solve-and-refresh", null)
	if not state["ok"]:
		status.emit("Couldn't solve the sketch: %s" % str(state["error"]))
		return false
	_ingest_state(state["json"])
	if with_entities:
		var exported: Dictionary = await api.call(HTTPClient.METHOD_GET, SKETCH + sketch_id + "/export", null)
		if exported["ok"]:
			_ingest_entities(exported["json"])
	changed.emit()
	return true


func _ingest_state(json: Dictionary) -> void:
	revision += 1
	points.clear()
	point_locked.clear()
	for p in json.get("points", []):
		points[str(p["id"])] = Vector2(float(p["x"]), float(p["y"]))
		point_locked[str(p["id"])] = bool(p.get("is_locked", false))
	constraints.clear()
	for c in json.get("constraints", []):
		constraints[str(c["id"])] = c
	var solve: Dictionary = json.get("solve", {})
	dof = int(solve.get("dof", -1))
	converged = bool(solve.get("converged", true))
	profile_status = str(json.get("profile", {}).get("status", ""))


func _ingest_entities(json: Dictionary) -> void:
	lines.clear()
	circles.clear()
	arcs.clear()
	shapes.clear()
	for e in json.get("entities", []):
		var id := str(e.get("id", ""))
		match str(e.get("type", "")):
			"line":
				lines[id] = {"a": str(e["start_point_id"]), "b": str(e["end_point_id"]), "construction": bool(e.get("construction", false))}
			"circle":
				circles[id] = {"c": str(e["center_point_id"]), "p": str(e["radius_point_id"]), "k": str(e.get("radius_constraint_id", "")), "construction": bool(e.get("construction", false))}
			"arc":
				arcs[id] = {"c": str(e["center_point_id"]), "s": str(e["start_point_id"]), "e": str(e["end_point_id"]), "k": str(e.get("radius_constraint_id", "")), "construction": bool(e.get("construction", false))}
			"rectangle":
				shapes[id] = {"kind": "rectangle", "point_ids": e.get("corner_point_ids", [])}
			"polygon":
				shapes[id] = {"kind": "polygon", "point_ids": e.get("vertex_point_ids", []), "radial_line_ids": e.get("radial_line_ids", [])}
			"slot":
				shapes[id] = {"kind": "slot", "point_ids": [str(e.get("center1_point_id", "")), str(e.get("center2_point_id", ""))]}


func profile_ok() -> bool:
	## True if the sketch holds a closed profile an extrude can use.
	return profile_status == "closed_loop" or profile_status == "multiple_loops"


func entity_count() -> int:
	return lines.size() + circles.size() + arcs.size()


# --- Tools -----------------------------------------------------------------------------

func set_tool(tool_id: String) -> void:
	tool = tool_id
	pending.clear()
	selection.clear()
	ghosts.clear()


func taps_needed() -> int:
	return int(TAPS_NEEDED.get(tool, 0))


func finish_chain() -> void:
	## Ends a run of lines: the next tap starts afresh.
	pending.clear()


func tap(pick: Dictionary) -> Dictionary:
	## One laser tap on the sheet, for the current drawing tool. pick = {uv: Vector2, id?: existing point id,
	## infer?: "horizontal"|"vertical" for a line end}. Returns {ok, done, message}; `done` when it made something.
	if busy or not TAPS_NEEDED.has(tool):
		return {"ok": false, "done": false, "message": ""}
	pending.append(pick)
	if pending.size() < taps_needed():
		return {"ok": true, "done": false, "message": ""}
	busy = true
	var taps := pending.duplicate()
	pending.clear()
	var result: Dictionary
	match tool:
		"point": result = await _make_point(taps)
		"line": result = await _make_line(taps)
		"rectangle": result = await _make_rectangle(taps)
		"circle": result = await _make_circle(taps)
		"arc": result = await _make_arc(taps)
		"polygon": result = await _make_polygon(taps)
		"slot": result = await _make_slot(taps)
		_: result = {"ok": false, "message": ""}
	busy = false
	if not result["ok"] and str(result["message"]) != "":
		status.emit(str(result["message"]))
	return {"ok": bool(result["ok"]), "done": bool(result["ok"]), "message": str(result["message"])}


func _post(path: String, body) -> Dictionary:
	return await api.call(HTTPClient.METHOD_POST, path, body)


func _point(pick: Dictionary, created: Array) -> String:
	## The id of a pick's point: the existing one it snapped to, the pinned reference point of a part vertex it snapped to (made now, if it is
	## the first time), else a new one at its position.
	if str(pick.get("id", "")) != "":
		return str(pick["id"])
	if pick.get("ref") is Dictionary:
		if str((pick["ref"] as Dictionary).get("kind", "")) in ["edge_midpoint", "edge_point"]:
			return await _point_on_reference(pick, created)
		var made := await ensure_reference(pick["ref"])
		return str(made["id"]) if made["ok"] else ""
	var uv: Vector2 = pick["uv"]
	var r := await _post(SKETCH + sketch_id + "/points", {"x": uv.x, "y": uv.y})
	if not r["ok"]:
		return ""
	created.append(str(r["json"]["id"]))
	return str(r["json"]["id"])


func _cleanup(created: Array) -> void:
	for id in created:
		await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/points/" + str(id), null)


func _finish(label: String, calls: Array, with_entities: bool = true) -> Dictionary:
	_undo.append({"label": label, "calls": calls})
	await refresh(with_entities)
	return {"ok": true, "message": ""}


func _make_point(taps: Array) -> Dictionary:
	var created: Array = []
	var id := await _point(taps[0], created)
	if id == "":
		return {"ok": false, "message": "Couldn't place the point."}
	return await _finish("point", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/points/" + id]], false)


func _make_line(taps: Array) -> Dictionary:
	var created: Array = []
	var a := await _point(taps[0], created)
	var b := await _point(taps[1], created)
	if a == "" or b == "" or a == b:
		await _cleanup(created)
		return {"ok": false, "message": "A line needs two different points."}
	var r := await _post(SKETCH + sketch_id + "/lines", {"start_point_id": a, "end_point_id": b})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the line: %s" % str(r["error"])}
	var line_id := str(r["json"]["id"])
	var calls: Array = [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/lines/" + line_id]]
	var infer := str(taps[1].get("infer", ""))
	if infer == "horizontal" or infer == "vertical":
		var c := await _post(SKETCH + sketch_id + "/constraints", {"type": infer, "line_id": line_id})
		if c["ok"]:
			calls.push_front([HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(c["json"]["id"])])
	pending = [{"uv": taps[1]["uv"], "id": b}] # the end is the next line's start
	return await _finish("line", calls)


func _make_rectangle(taps: Array) -> Dictionary:
	var created: Array = []
	var p1: Vector2 = taps[0]["uv"]
	var p3: Vector2 = taps[1]["uv"]
	if absf(p1.x - p3.x) < 0.01 or absf(p1.y - p3.y) < 0.01:
		return {"ok": false, "message": "Pick two opposite corners that aren't in line."}
	var corners := [
		taps[0],
		{"uv": Vector2(p3.x, p1.y)},
		taps[1],
		{"uv": Vector2(p1.x, p3.y)},
	]
	var ids: Array = []
	for corner in corners:
		var id := await _point(corner, created)
		if id == "":
			await _cleanup(created)
			return {"ok": false, "message": "Couldn't place the corners."}
		ids.append(id)
	var r := await _post(SKETCH + sketch_id + "/rectangles", {"corner_point_ids": ids})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the rectangle: %s" % str(r["error"])}
	return await _finish("rectangle", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/rectangles/" + str(r["json"]["id"])]])


func _make_circle(taps: Array) -> Dictionary:
	var created: Array = []
	var c := await _point(taps[0], created)
	var rim := await _point(taps[1], created)
	if c == "" or rim == "" or c == rim:
		await _cleanup(created)
		return {"ok": false, "message": "A circle needs a centre and a different point on it."}
	var r := await _post(SKETCH + sketch_id + "/circles", {"center_point_id": c, "radius_point_id": rim})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the circle: %s" % str(r["error"])}
	return await _finish("circle", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/circles/" + str(r["json"]["id"])]])


func _make_arc(taps: Array) -> Dictionary:
	var created: Array = []
	var c := await _point(taps[0], created)
	var s := await _point(taps[1], created)
	if c == "" or s == "" or c == s:
		await _cleanup(created)
		return {"ok": false, "message": "An arc needs a centre and a different start point."}
	var body := {"center_point_id": c, "start_point_id": s}
	var end_pick: Dictionary = taps[2]
	if str(end_pick.get("id", "")) != "":
		body["end_point_id"] = str(end_pick["id"])
	else:
		# The end sits on the arc's own circle: take its direction from the centre and let the backend place it.
		var centre: Vector2 = points.get(c, taps[0]["uv"])
		var d: Vector2 = (end_pick["uv"] as Vector2) - centre
		if d.length() < 0.01:
			await _cleanup(created)
			return {"ok": false, "message": "Pick an end away from the centre."}
		body["end_angle"] = atan2(d.y, d.x)
	var r := await _post(SKETCH + sketch_id + "/arcs", body)
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the arc: %s" % str(r["error"])}
	return await _finish("arc", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/arcs/" + str(r["json"]["id"])]])


func _make_slot(taps: Array) -> Dictionary:
	## Two end centres and a third pick whose distance from the line between them is the slot's half width.
	var created: Array = []
	var a := await _point(taps[0], created)
	var b := await _point(taps[1], created)
	if a == "" or b == "" or a == b:
		await _cleanup(created)
		return {"ok": false, "message": "A slot needs two different end centres."}
	var pa: Vector2 = points.get(a, taps[0]["uv"])
	var pb: Vector2 = points.get(b, taps[1]["uv"])
	var width := (taps[2]["uv"] as Vector2).distance_to(Geometry2D.get_closest_point_to_segment(taps[2]["uv"], pa, pb))
	if width < 0.01:
		await _cleanup(created)
		return {"ok": false, "message": "Pick the third point away from the line between the centres: that sets the width."}
	var r := await _post(SKETCH + sketch_id + "/slots", {"center1_point_id": a, "center2_point_id": b, "radius": width})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the slot: %s" % str(r["error"])}
	return await _finish("slot", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/slots/" + str(r["json"]["id"])]])


func _make_polygon(taps: Array) -> Dictionary:
	var created: Array = []
	var c := await _point(taps[0], created)
	var v := await _point(taps[1], created)
	if c == "" or v == "" or c == v:
		await _cleanup(created)
		return {"ok": false, "message": "A polygon needs a centre and a different first corner."}
	var r := await _post(SKETCH + sketch_id + "/polygons", {"center_point_id": c, "first_vertex_point_id": v, "sides": polygon_sides})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the polygon: %s" % str(r["error"])}
	return await _finish("polygon", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/polygons/" + str(r["json"]["id"])]])


# --- Finding things under the laser -------------------------------------------------------

# --- The part's own geometry as references ----------------------------------------------------

func ensure_reference(ref: Dictionary) -> Dictionary:
	## Makes a part vertex or straight edge usable in this sketch and returns {ok, id, message}: a vertex becomes a pinned point that follows the
	## part (the backend re-resolves it whenever the part changes, and flags the sketch if it can't), an edge becomes a pinned construction line
	## between two such points. Idempotent: asking again for the same vertex gives the same point, and an edge whose two points are already joined
	## by a line gives that line. Nothing for the user to convert, fix or mark as construction.
	if not references_ok:
		return {"ok": false, "id": "", "message": "This sketch can't use the part's own geometry (the part shown isn't the one the backend sketches on)."}
	match str(ref.get("kind", "")):
		"vertex":
			return await _ensure_vertex(str(ref["body"]), int(ref["index"]))
		"edge":
			var a := await _ensure_vertex(str(ref["body"]), int(ref["a_vertex"]))
			if not a["ok"]:
				return a
			var b := await _ensure_vertex(str(ref["body"]), int(ref["b_vertex"]))
			if not b["ok"]:
				return b
			for id in lines:
				var l: Dictionary = lines[id]
				if (l["a"] == a["id"] and l["b"] == b["id"]) or (l["a"] == b["id"] and l["b"] == a["id"]):
					return {"ok": true, "id": id, "message": ""}
			var made := await _post(SKETCH + sketch_id + "/lines", {"start_point_id": a["id"], "end_point_id": b["id"], "construction": true})
			if not made["ok"]:
				return {"ok": false, "id": "", "message": "Couldn't use that edge: %s" % str(made["error"])}
			lines[str(made["json"]["id"])] = {"a": a["id"], "b": b["id"], "construction": true}
			changed.emit()
			return {"ok": true, "id": str(made["json"]["id"]), "message": ""}
		"circle_centre":
			var on_circle := await _ensure_circle(str(ref["body"]), int(ref["index"]))
			if not on_circle["ok"]:
				return on_circle
			return {"ok": true, "id": on_circle["centre"], "message": ""}
		"circle_edge":
			return await _ensure_circle(str(ref["body"]), int(ref["index"]))
	return {"ok": false, "id": "", "message": ""}


func _ensure_circle(body: String, edge_index: int) -> Dictionary:
	## A circular edge of the part in the sketch plane (a hole's or boss's rim, or an arc of one) as a pinned construction circle / arc in the sketch, and its
	## centre as a pinned point: convert-entities/edge does both (the centre is a live reference of kind "circle_centre", so it follows the hole when the part
	## changes and is flagged when the hole is gone). The route is idempotent per edge (a second call answers with the circle already there), so asking again
	## is the way to find it; it is only read back when the circle is not yet in this session's picture. {ok, id (the circle / arc), kind, centre (its centre point), message}.
	var key := "%s:c%d" % [body, edge_index]
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/edge" % [owner_part_id, feature_id], {"body_id": body, "edge_index": edge_index, "construction": true})
	if not made["ok"]:
		return {"ok": false, "id": "", "message": "Couldn't use that round edge of the part: %s" % str(made["error"])}
	var json: Dictionary = made["json"]
	var kind := "circle" if json.get("circle") is Dictionary else ("arc" if json.get("arc") is Dictionary else "")
	if kind == "":
		if json.get("line") is Dictionary: # not round in this sketch's plane after all: the backend made its chord, which nobody asked for
			await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/lines/" + str(json["line"]["id"]), null)
			await refresh(true)
		return {"ok": false, "id": "", "message": "That edge isn't a circle in the sketch's plane, so it can't be used here."}
	var centre := str((json[kind] as Dictionary)["center_point_id"])
	_ref_points[key] = centre
	var shape_id := str((json[kind] as Dictionary)["id"])
	if not circles.has(shape_id) and not arcs.has(shape_id):
		await refresh(true) # the circle's own points and the circle itself come in with the next read
	return {"ok": true, "id": shape_id, "kind": kind, "centre": centre, "message": ""}


func _point_on_reference(pick: Dictionary, created: Array) -> String:
	## The point a snap to the middle of, or somewhere along, an edge of the part means: the edge is made a pinned construction line (or circle), and a
	## NEW point is made on it and held there: at its middle by an at-midpoint constraint, or where you aimed by a point-on-line / point-on-circle one.
	## The midpoint's point is reused if the edge already has one. "" if it could not be made.
	var ref: Dictionary = pick["ref"]
	var host := await ensure_reference(ref["edge"])
	if not host["ok"]:
		status.emit(str(host["message"]))
		return ""
	var host_id := str(host["id"])
	var on_circle: bool = str((ref["edge"] as Dictionary).get("kind", "")) == "circle_edge"
	var target: Vector2 = pick["uv"]
	var constraint := {}
	if str(ref["kind"]) == "edge_midpoint":
		for cid in constraints:
			var c: Dictionary = constraints[cid]
			if str(c.get("type", "")) == "at_midpoint" and str(c.get("line_id", "")) == host_id and points.has(str(c.get("point_id", ""))):
				return str(c["point_id"])
		var l: Dictionary = lines.get(host_id, {})
		if not points.has(str(l.get("a", ""))) or not points.has(str(l.get("b", ""))):
			return ""
		target = (points[l["a"]] + points[l["b"]]) * 0.5
		constraint = {"type": "at_midpoint", "line_id": host_id}
	elif on_circle:
		constraint = {"type": "point_on_circle", "circle_or_arc_id": host_id}
	else:
		constraint = {"type": "point_on_line", "line_id": host_id}
	var r := await _post(SKETCH + sketch_id + "/points", {"x": target.x, "y": target.y})
	if not r["ok"]:
		return ""
	var id := str(r["json"]["id"])
	created.append(id)
	constraint["point_id"] = id
	var held := await _post(SKETCH + sketch_id + "/constraints", constraint)
	if not held["ok"]:
		status.emit("Couldn't hold that point on the part's edge: %s" % str(held["error"]))
		return "" # the caller's cleanup takes the point back out
	await refresh(false)
	if not converged:
		# The solver would not accept it together with the rest of the sketch (the backend's at-midpoint is the one it distrusts most: it reports "not
		# converged" in a sketch that already has a redundancy, such as a converted hole): take it back out rather than leave a broken sketch.
		await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(held["json"]["id"]), null)
		await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/points/" + id, null)
		created.erase(id)
		await refresh(false)
		status.emit("The solver can't hold a point there together with the rest of this sketch, so it wasn't added. Try another spot on the edge.")
		return ""
	points[id] = points.get(id, target)
	return id


func reference_status(point_id: String) -> String:
	## What state the backend says a pinned point's reference is in: "ok", "followed" (re-found at a new index, informational), "potentially_moved" (bound on
	## weaker evidence: confirm it or re-pick) or "lost" (never rebound silently). "ok" for a point that is not a reference.
	for row in reference_rows:
		if str(row.get("point_id", "")) == point_id:
			return str(row.get("status", "ok"))
	return "ok"


func flagged_references() -> Array:
	## The reference rows that need the user: lost ones first, then the potentially moved.
	var lost: Array = []
	var moved: Array = []
	for row in reference_rows:
		match str(row.get("status", "ok")):
			"lost":
				lost.append(row)
			"potentially_moved":
				moved.append(row)
	return lost + moved


func reference_warning() -> String:
	## One line for the status area, "" when every reference is fine.
	var lost := 0
	var moved := 0
	for row in flagged_references():
		if str(row["status"]) == "lost":
			lost += 1
		else:
			moved += 1
	if lost == 0 and moved == 0:
		return ""
	var parts: Array = []
	if lost > 0:
		parts.append("%d lost" % lost)
	if moved > 0:
		parts.append("%d may have moved" % moved)
	return "Reference to the part: %s. Select, with nothing picked, offers Fix." % ", ".join(parts)


func reattach(point_id: String, ref: Dictionary) -> Dictionary:
	## Points a flagged reference point at the corner (ref {kind: "vertex", body, index}) or hole (ref {kind: "circle_centre", body, index}) the user picked as
	## its replacement: everything built on the point (lines, dimensions, constraints) stays on it, only what it follows changes. {ok, message}.
	var body := {"body_id": str(ref["body"])}
	match str(ref.get("kind", "")):
		"vertex":
			body["vertex_index"] = int(ref["index"])
		"circle_centre":
			body["edge_index"] = int(ref["index"])
		_:
			return {"ok": false, "message": "Pick a corner of the part (or the centre of a hole) to follow."}
	var wants_centre := false
	for row in reference_rows:
		if str(row.get("point_id", "")) == point_id:
			wants_centre = str(row.get("kind", "vertex")) == "circle_centre"
	if wants_centre != (str(ref["kind"]) == "circle_centre"):
		return {"ok": false, "message": "That point follows the centre of a hole, so pick a hole's centre." if wants_centre else "That point follows a corner of the part, so pick a corner."}
	busy = true
	var r := await _post("/document/parts/%s/features/sketch/%s/external-references/%s/reattach" % [owner_part_id, feature_id, point_id], body)
	if not r["ok"]:
		busy = false
		var message := "Couldn't re-attach it: %s" % str(r["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	_ref_points.clear()
	await refresh(true)
	await load_references()
	busy = false
	changed.emit()
	return {"ok": true, "message": ""}


func confirm_reference(point_id: String) -> Dictionary:
	## "Yes, this is the right corner": a potentially moved reference stops being flagged.
	busy = true
	var r := await _post("/document/parts/%s/features/sketch/%s/external-references/%s/confirm" % [owner_part_id, feature_id, point_id], {})
	if not r["ok"]:
		busy = false
		var message := "Couldn't keep it: %s" % str(r["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	await load_references()
	busy = false
	changed.emit()
	return {"ok": true, "message": ""}


func load_references() -> void:
	## Reads which of this sketch's points are the part's own corners and hole centres (the backend's list of external references), so a reopened sketch
	## reuses them instead of making a second copy, and what state each is in (reference_rows: ok / followed / potentially_moved / lost). Quietly nothing
	## on a backend without the route.
	reference_rows = []
	if owner_part_id.is_empty() or feature_id.is_empty():
		return
	var r: Dictionary = await api.call(HTTPClient.METHOD_GET, "/document/parts/%s/features/sketch/%s/external-references" % [owner_part_id, feature_id], null)
	if not r["ok"] or not (r["json"] is Array):
		return
	reference_rows = r["json"]
	for row in reference_rows:
		var point_id := str(row.get("point_id", ""))
		if str(row.get("kind", "vertex")) == "circle_centre":
			var key := "%s:c%d" % [str(row.get("body_id", "")), int(row.get("vertex_index", -1))]
			_ref_points[key] = point_id
		else:
			_ref_points["%s:%d" % [str(row.get("body_id", "")), int(row.get("vertex_index", -1))]] = point_id


func _ensure_vertex(body: String, index: int) -> Dictionary:
	var key := "%s:%d" % [body, index]
	if _ref_points.has(key) and points.has(_ref_points[key]):
		return {"ok": true, "id": _ref_points[key], "message": ""}
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/vertex" % [owner_part_id, feature_id], {"body_id": body, "vertex_index": index})
	if not made["ok"]:
		return {"ok": false, "id": "", "message": "Couldn't use that corner of the part: %s" % str(made["error"])}
	var id := str(made["json"]["id"])
	points[id] = Vector2(float(made["json"]["x"]), float(made["json"]["y"]))
	point_locked[id] = true
	_ref_points[key] = id
	changed.emit()
	return {"ok": true, "id": id, "message": ""}


func nearest_point(uv: Vector2, radius: float) -> String:
	## The id of the existing point nearest `uv` within `radius`, or "". The sketch's own construction points
	## (a rectangle's centre) count: they're real points.
	var best := ""
	var best_d := radius
	for id in points:
		var d := uv.distance_to(points[id])
		if d <= best_d:
			best_d = d
			best = id
	return best


func nearest_entity(uv: Vector2, radius: float, kinds: Array = ["point", "line", "circle", "arc"]) -> Dictionary:
	## The nearest thing to a sheet position: {kind, id, distance} or {}. A point beats a line it's on.
	var best := {}
	var best_d := radius
	if "point" in kinds:
		for id in points:
			var d := uv.distance_to(points[id])
			if d <= best_d:
				best_d = d
				best = {"kind": "point", "id": id, "distance": d}
	var point_hit := not best.is_empty()
	if "line" in kinds and not point_hit:
		for id in lines:
			var l: Dictionary = lines[id]
			if not points.has(l["a"]) or not points.has(l["b"]):
				continue
			var d := uv.distance_to(Geometry2D.get_closest_point_to_segment(uv, points[l["a"]], points[l["b"]]))
			if d <= best_d:
				best_d = d
				best = {"kind": "line", "id": id, "distance": d}
	if "circle" in kinds and not point_hit:
		for id in circles:
			var c: Dictionary = circles[id]
			if not points.has(c["c"]) or not points.has(c["p"]):
				continue
			var d := absf(uv.distance_to(points[c["c"]]) - points[c["c"]].distance_to(points[c["p"]]))
			if d <= best_d:
				best_d = d
				best = {"kind": "circle", "id": id, "distance": d}
	if "arc" in kinds and not point_hit:
		for id in arcs:
			var a: Dictionary = arcs[id]
			if not points.has(a["c"]) or not points.has(a["s"]) or not points.has(a["e"]):
				continue
			var d := _distance_to_arc(uv, points[a["c"]], points[a["s"]], points[a["e"]])
			if d <= best_d:
				best_d = d
				best = {"kind": "arc", "id": id, "distance": d}
	return best


static func _distance_to_arc(uv: Vector2, c: Vector2, s: Vector2, e: Vector2) -> float:
	## The backend's arcs sweep counter-clockwise from start to end.
	var r := c.distance_to(s)
	var angle := fposmod((uv - c).angle(), TAU)
	var a0 := fposmod((s - c).angle(), TAU)
	var a1 := fposmod((e - c).angle(), TAU)
	var sweep := fposmod(a1 - a0, TAU)
	var along := fposmod(angle - a0, TAU)
	if along <= sweep:
		return absf(uv.distance_to(c) - r)
	return minf(uv.distance_to(s), uv.distance_to(e))


# --- Constraint tools --------------------------------------------------------------------

func select(entity: Dictionary) -> Dictionary:
	## One laser pick of an entity for a constraint tool or Dimension. Returns {ok, done, message}. A pick of the PART's own vertex or edge
	## (entity.ref, no id yet) is first made a pinned reference point or line, the way the flat app's "use edge" does, and then is just an entity.
	if busy or entity.is_empty():
		return {"ok": false, "done": false, "message": ""}
	if entity.get("ref") is Dictionary and str(entity.get("id", "")) == "":
		busy = true
		var made := await ensure_reference(entity["ref"])
		busy = false
		if not made["ok"]:
			status.emit(str(made["message"]))
			return {"ok": false, "done": false, "message": str(made["message"])}
		entity = {"kind": str(made.get("kind", entity["kind"])), "id": str(made["id"])}
	if tool == "dimension":
		return _select_for_dimension(entity)
	if tool == SELECT:
		toggle_select(entity)
		return {"ok": true, "done": false, "message": ""}
	if not SELECT_NEEDED.has(tool):
		return {"ok": false, "done": false, "message": ""}
	var need := _selection_ok(entity)
	if need != "":
		return {"ok": false, "done": false, "message": need}
	selection.append({"kind": str(entity["kind"]), "id": str(entity["id"])})
	if selection.size() < int(SELECT_NEEDED[tool]):
		changed.emit()
		return {"ok": true, "done": false, "message": ""}
	busy = true
	var picked := selection.duplicate()
	selection.clear()
	var result := await _apply_constraint(tool, picked)
	busy = false
	if not result["ok"] and str(result["message"]) != "":
		status.emit(str(result["message"]))
	return {"ok": bool(result["ok"]), "done": bool(result["ok"]), "message": str(result["message"])}


func _selection_ok(entity: Dictionary) -> String:
	## "" if this pick suits the tool; else why not.
	var kind := str(entity["kind"])
	match tool:
		"horizontal", "vertical":
			return "" if kind == "line" else "Pick a line."
		"parallel", "perpendicular":
			return "" if kind == "line" else "Pick a line."
		"coincident":
			if selection.is_empty():
				return "" if kind in ["point", "line", "circle", "arc"] else "Pick a point."
			var first := str(selection[0]["kind"])
			if first == "point":
				return "" if kind in ["point", "line", "circle", "arc"] else "Pick a point, line or circle."
			return "" if kind == "point" else "Pick a point to put on it."
	return ""


func _apply_constraint(tool_id: String, picked: Array) -> Dictionary:
	var body := {}
	match tool_id:
		"horizontal", "vertical":
			body = {"type": tool_id, "line_id": picked[0]["id"]}
		"parallel", "perpendicular":
			if picked[0]["id"] == picked[1]["id"]:
				return {"ok": false, "message": "Pick two different lines."}
			body = {"type": tool_id, "line1_id": picked[0]["id"], "line2_id": picked[1]["id"]}
		"coincident":
			var a: Dictionary = picked[0]
			var b: Dictionary = picked[1]
			if a["kind"] != "point":
				var t := a
				a = b
				b = t
			if b["kind"] == "point":
				if a["id"] == b["id"]:
					return {"ok": false, "message": "Pick two different points."}
				body = {"type": "coincident", "point_a_id": a["id"], "point_b_id": b["id"]}
			elif b["kind"] == "line":
				body = {"type": "point_on_line", "point_id": a["id"], "line_id": b["id"]}
			else:
				body = {"type": "point_on_circle", "point_id": a["id"], "circle_or_arc_id": b["id"]}
	var r := await _post(SKETCH + sketch_id + "/constraints", body)
	if not r["ok"]:
		return {"ok": false, "message": "Couldn't add that constraint: %s" % str(r["error"])}
	var calls: Array = [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(r["json"]["id"])]]
	await _finish(tool_id, calls, false)
	if not converged:
		# It can't be satisfied together with the rest: take it straight back out rather than leave a broken sketch.
		await undo()
		return {"ok": false, "message": "That conflicts with the other constraints, so it wasn't added."}
	return {"ok": true, "message": ""}



# --- The Select tool: any number of entities, and a menu of what applies to them ---------------------------------

func is_selected(entity: Dictionary) -> bool:
	for e in selection:
		if str(e["kind"]) == str(entity["kind"]) and str(e["id"]) == str(entity["id"]):
			return true
	return false


func toggle_select(entity: Dictionary) -> void:
	## One pick with the Select tool: adds the entity, or takes it out again if it was already selected. The dimension candidates
	## (a line's length, two points' distance...) are recomputed for what is now selected.
	if busy or entity.is_empty():
		return
	var e := {"kind": str(entity["kind"]), "id": str(entity["id"])}
	var at := -1
	for i in selection.size():
		if str(selection[i]["kind"]) == e["kind"] and str(selection[i]["id"]) == e["id"]:
			at = i
	if at >= 0:
		selection.remove_at(at)
	else:
		selection.append(e)
	ghosts = _build_ghosts() if selection.size() <= 2 else []
	changed.emit()


func menu() -> Array:
	## The contextual menu for the current selection (sketch_selection.gd).
	return SketchSelection.options(selection, self, ghosts)


func apply_menu(option_id: String) -> Dictionary:
	## Does one menu option on the current selection. Returns {ok, message}.
	if busy or selection.is_empty():
		return {"ok": false, "message": ""}
	match option_id:
		"clear":
			clear_selection()
			return {"ok": true, "message": ""}
		"delete":
			return await delete_selection()
		"construction":
			return await toggle_construction()
		"fix":
			return await _constrain_selection("fix", _fix_bodies())
	var bodies := _bodies_for(option_id)
	if bodies.is_empty():
		return {"ok": false, "message": "That doesn't fit what is selected."}
	return await _constrain_selection(option_id, bodies)


func _constrain_selection(label: String, bodies: Array) -> Dictionary:
	busy = true
	var calls: Array = []
	for body in bodies:
		var r := await _post(SKETCH + sketch_id + "/constraints", body)
		if not r["ok"]:
			for entry in calls: # take back the ones already made: a half-applied menu choice is worse than none
				await api.call(int(entry[0]), str(entry[1]), null)
			busy = false
			var message := "Couldn't add that constraint: %s" % str(r["error"])
			status.emit(message)
			return {"ok": false, "message": message}
		calls.append([HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(r["json"]["id"])])
	selection.clear()
	ghosts.clear()
	await _finish(label, calls, false)
	busy = false
	if not converged:
		await undo()
		var conflict := "That conflicts with the other constraints, so it wasn't added."
		status.emit(conflict)
		return {"ok": false, "message": conflict}
	return {"ok": true, "message": ""}


func _ids_of(kind: String) -> Array:
	return selection.filter(func(e): return str(e["kind"]) == kind).map(func(e): return str(e["id"]))


func _curve_ids() -> Array:
	return selection.filter(func(e): return str(e["kind"]) in ["circle", "arc"]).map(func(e): return str(e["id"]))


func _bodies_for(option_id: String) -> Array:
	## The constraint request bodies one menu option makes for the selection (chained from the first entity for 3 or more).
	var lines_sel := _ids_of("line")
	var points_sel := _ids_of("point")
	var curves := _curve_ids()
	match option_id:
		"horizontal", "vertical":
			return lines_sel.map(func(id): return {"type": option_id, "line_id": id})
		"parallel", "perpendicular", "equal_length", "collinear":
			return _chain(lines_sel, func(a, b): return {"type": option_id, "line1_id": a, "line2_id": b})
		"concentric", "equal_radius":
			return _chain(curves, func(a, b): return {"type": option_id, "entity1_id": a, "entity2_id": b})
		"coincident":
			if points_sel.size() == 2 and points_sel[0] != points_sel[1]:
				return [{"type": "coincident", "point_a_id": points_sel[0], "point_b_id": points_sel[1]}]
		"point_on_line":
			if points_sel.size() == 1 and lines_sel.size() == 1:
				return [{"type": "point_on_line", "point_id": points_sel[0], "line_id": lines_sel[0]}]
		"at_midpoint":
			if points_sel.size() == 1 and lines_sel.size() == 1:
				return [{"type": "at_midpoint", "point_id": points_sel[0], "line_id": lines_sel[0]}]
		"point_on_curve":
			if points_sel.size() == 1 and curves.size() == 1:
				return [{"type": "point_on_circle", "point_id": points_sel[0], "circle_or_arc_id": curves[0]}]
		"tangent":
			if lines_sel.size() == 1 and curves.size() == 1:
				return [{"type": "tangent", "circle_or_arc_id": curves[0], "line_id": lines_sel[0]}]
			if curves.size() == 2 and arcs.has(curves[0]) and arcs.has(curves[1]):
				var shared := SketchSelection.shared_end(arcs[curves[0]], arcs[curves[1]])
				if shared != "":
					return [{"type": "curve_tangent", "entity1_id": curves[0], "entity2_id": curves[1], "shared_point_id": shared}]
	return []


func _chain(ids: Array, make: Callable) -> Array:
	var out: Array = []
	for i in range(1, ids.size()):
		if ids[0] != ids[i]:
			out.append(make.call(ids[0], ids[i]))
	return out


func _fix_bodies() -> Array:
	return selection.map(func(e): return {"type": "fixed", "entity_id": str(e["id"])})


func delete_selection() -> Dictionary:
	## Deletes the selected lines, circles, arcs and points (never the origin). The backend prunes the points nothing uses any more.
	## There is no undo for it, as in the flat app's Delete: take care with the picks.
	if busy:
		return {"ok": false, "message": ""}
	var paths: Array = []
	for e in selection:
		var id := str(e["id"])
		match str(e["kind"]):
			"line":
				paths.append(SKETCH + sketch_id + "/lines/" + id)
			"circle":
				paths.append(SKETCH + sketch_id + "/circles/" + id)
			"arc":
				paths.append(SKETCH + sketch_id + "/arcs/" + id)
	for e in selection: # points last: deleting a line may already have taken one
		if str(e["kind"]) == "point" and not is_origin(str(e["id"])):
			paths.append(SKETCH + sketch_id + "/points/" + str(e["id"]))
	if paths.is_empty():
		return {"ok": false, "message": "The origin can't be deleted."}
	busy = true
	var failed := ""
	for path in paths:
		var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, path, null)
		if not r["ok"]:
			failed = str(r["error"])
	selection.clear()
	ghosts.clear()
	var refreshed := await refresh(true)
	busy = false
	if failed != "":
		var message := "Couldn't delete everything: %s" % failed
		status.emit(message)
		return {"ok": false, "message": message}
	return {"ok": refreshed, "message": ""}


func toggle_construction() -> Dictionary:
	## Makes the selected lines, circles and arcs construction geometry (guides that are never part of the profile), or solid again
	## if they all already are construction. Undoable.
	if busy:
		return {"ok": false, "message": ""}
	var make_solid := SketchSelection.all_construction(selection, self)
	var calls: Array = []
	var requests: Array = []
	for e in selection:
		var id := str(e["id"])
		var path := ""
		var was := false
		match str(e["kind"]):
			"line":
				path = SKETCH + sketch_id + "/lines/" + id
				was = bool(lines.get(id, {}).get("construction", false))
			"circle":
				path = SKETCH + sketch_id + "/circles/" + id
				was = bool(circles.get(id, {}).get("construction", false))
			"arc":
				path = SKETCH + sketch_id + "/arcs/" + id
				was = bool(arcs.get(id, {}).get("construction", false))
		if path != "":
			requests.append([path, not make_solid])
			calls.append([HTTPClient.METHOD_PATCH, path, {"construction": was}])
	if requests.is_empty():
		return {"ok": false, "message": "Pick a line, circle or arc."}
	busy = true
	for r in requests:
		var answer: Dictionary = await api.call(HTTPClient.METHOD_PATCH, str(r[0]), {"construction": bool(r[1])})
		if not answer["ok"]:
			busy = false
			var message := "Couldn't change that: %s" % str(answer["error"])
			status.emit(message)
			return {"ok": false, "message": message}
	selection.clear()
	ghosts.clear()
	await _finish("construction", calls, true)
	busy = false
	return {"ok": true, "message": ""}


# --- Dimension ---------------------------------------------------------------------------

func _select_for_dimension(entity: Dictionary) -> Dictionary:
	var kind := str(entity["kind"])
	if selection.size() >= 2:
		selection.clear()
	if kind == "circle" or kind == "arc":
		selection.clear() # a round thing is dimensioned on its own
	elif not selection.is_empty() and str(selection[0]["kind"]) in ["circle", "arc"]:
		selection.clear()
	selection.append({"kind": kind, "id": str(entity["id"])})
	ghosts = _build_ghosts()
	changed.emit()
	return {"ok": true, "done": false, "message": ""}


func clear_selection() -> void:
	selection.clear()
	ghosts.clear()
	changed.emit()


func _line_points(id: String) -> Array:
	var l: Dictionary = lines.get(id, {})
	return [l.get("a", ""), l.get("b", "")]


func _build_ghosts() -> Array:
	return _ghosts_for(selection)


func _ghosts_for(picked: Array) -> Array:
	## What `picked` can be dimensioned as, the way the flat app offers it: one line -> its length;
	## one circle / arc -> radius and diameter; two points -> linear, horizontal and vertical distance; a point and
	## a line -> their distance; two lines -> a distance if parallel, else an angle. Each: {key, label, unit,
	## value, uv (where the label floats), apply: {patch_id?, create?, factor}}. When everything picked is already pinned (pieces of the part, the origin,
	## or Fixed) nothing a dimension could say would move anything, so each candidate is a DRIVEN (reference-only) one: `driven` true, it only measures,
	## and keeping it (keep_driven) adds no constraint.
	var out: Array = _ghosts_raw(picked)
	if not out.is_empty() and _all_pinned(picked):
		for g in out:
			g["driven"] = true
			g["label"] = "Reference " + str(g["label"]).to_lower()
	return out


func _ghosts_raw(picked: Array) -> Array:
	var out: Array = []
	if picked.is_empty():
		return out
	var first: Dictionary = picked[0]
	if picked.size() == 1:
		match first["kind"]:
			"line":
				var pts := _line_points(first["id"])
				if points.has(pts[0]) and points.has(pts[1]):
					var d: float = points[pts[0]].distance_to(points[pts[1]])
					out.append(_ghost("length", "Length", "mm", d, (points[pts[0]] + points[pts[1]]) * 0.5,
						_distance_apply(pts[0], pts[1], "linear"), {"kind": "linear", "a": points[pts[0]], "b": points[pts[1]]}))
			"circle", "arc":
				var c: Dictionary = circles.get(first["id"], arcs.get(first["id"], {}))
				var rim: String = c.get("p", c.get("s", ""))
				if points.has(c.get("c", "")) and points.has(rim) and str(c.get("k", "")) != "":
					var r: float = points[c["c"]].distance_to(points[rim])
					out.append(_ghost("radius", "Radius", "mm", r, points[c["c"]] + Vector2(r * 0.5, 0), {"patch_id": c["k"], "factor": 1.0}, circle_spec("radius", str(first["id"]))))
					out.append(_ghost("diameter", "Diameter", "mm", r * 2.0, points[c["c"]] + Vector2(-r * 0.5, 0), {"patch_id": c["k"], "factor": 0.5}, circle_spec("diameter", str(first["id"]))))
		return out
	var second: Dictionary = picked[1]
	if first["kind"] == "point" and second["kind"] == "point":
		var a: String = first["id"]
		var b: String = second["id"]
		if a != b and points.has(a) and points.has(b):
			var pa: Vector2 = points[a]
			var pb: Vector2 = points[b]
			out.append(_ghost("linear", "Distance", "mm", pa.distance_to(pb), (pa + pb) * 0.5, _distance_apply(a, b, "linear"), {"kind": "linear", "a": pa, "b": pb}))
			out.append(_ghost("horizontal", "Horizontal", "mm", absf(pb.x - pa.x), Vector2((pa.x + pb.x) * 0.5, minf(pa.y, pb.y)), _distance_apply(a, b, "horizontal"), {"kind": "horizontal", "a": pa, "b": pb}))
			out.append(_ghost("vertical", "Vertical", "mm", absf(pb.y - pa.y), Vector2(minf(pa.x, pb.x), (pa.y + pb.y) * 0.5), _distance_apply(a, b, "vertical"), {"kind": "vertical", "a": pa, "b": pb}))
	elif first["kind"] == "line" and second["kind"] == "line" and first["id"] != second["id"]:
		var l1 := _line_points(first["id"])
		var l2 := _line_points(second["id"])
		if points.has(l1[0]) and points.has(l1[1]) and points.has(l2[0]) and points.has(l2[1]):
			var d1: Vector2 = (points[l1[1]] - points[l1[0]]).normalized()
			var d2: Vector2 = (points[l2[1]] - points[l2[0]]).normalized()
			var mid: Vector2 = (points[l1[0]] + points[l1[1]] + points[l2[0]] + points[l2[1]]) * 0.25
			if absf(d1.dot(d2)) >= PARALLEL_COS:
				var dist: float = absf((points[l2[0]] - points[l1[0]]).cross(d1))
				out.append(_ghost("line_distance", "Distance", "mm", dist, mid, {"create": {"type": "line_distance", "line1_id": first["id"], "line2_id": second["id"]}, "factor": 1.0, "value_key": "distance"}, perp_spec(str(l1[0]), str(second["id"]))))
			else:
				var ang := rad_to_deg(acos(clampf(d1.dot(d2), -1.0, 1.0)))
				out.append(_ghost("angle", "Angle", "deg", ang, mid, {"create": {"type": "angle", "line1_id": first["id"], "line2_id": second["id"]}, "factor": 1.0, "value_key": "angle_degrees"}, angle_spec(str(first["id"]), str(second["id"]))))
	elif (first["kind"] == "point" and second["kind"] == "line") or (first["kind"] == "line" and second["kind"] == "point"):
		var pt: String = first["id"] if first["kind"] == "point" else second["id"]
		var ln: String = first["id"] if first["kind"] == "line" else second["id"]
		var lp := _line_points(ln)
		if points.has(pt) and points.has(lp[0]) and points.has(lp[1]):
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(points[pt], points[lp[0]], points[lp[1]])
			var dist2: float = points[pt].distance_to(closest)
			out.append(_ghost("point_line", "Distance", "mm", dist2, (points[pt] + closest) * 0.5, {"create": {"type": "point_line_distance", "point_id": pt, "line_id": ln}, "factor": 1.0, "value_key": "distance"}, perp_spec(pt, ln)))
	return out


func _all_pinned(entities: Array) -> bool:
	## True if every point of the picked points and lines is pinned (a part reference, the origin, or Fixed).
	var seen := 0
	for e in entities:
		var ids: Array = []
		match str(e["kind"]):
			"point":
				ids = [str(e["id"])]
			"line":
				ids = _line_points(str(e["id"]))
			"circle":
				var c: Dictionary = circles.get(str(e["id"]), {})
				ids = [c.get("c", ""), c.get("p", "")]
			"arc":
				var a: Dictionary = arcs.get(str(e["id"]), {})
				ids = [a.get("c", ""), a.get("s", ""), a.get("e", "")]
		for pid in ids:
			seen += 1
			if not point_locked.get(pid, false) and not is_origin(str(pid)):
				return false
	return seen > 0


func _ghost(key: String, label: String, unit: String, value: float, uv: Vector2, apply: Dictionary, spec: Dictionary = {}) -> Dictionary:
	return {"key": key, "label": label, "unit": unit, "value": value, "uv": uv, "apply": apply, "spec": spec}


static func format_value(value: float) -> String:
	## A dimension's number as a drawing writes it: two decimals, trailing zeros dropped (40, 12.5, 0.13).
	var text := "%.2f" % value
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text


func dimension_text(kind: String, value: float) -> String:
	match kind:
		"radius":
			return "R" + format_value(value)
		"diameter":
			return "\u2300" + format_value(value)
		"angle":
			return format_value(value) + "\u00b0"
	return format_value(value)


func circle_spec(kind: String, id: String) -> Dictionary:
	## The layout spec of a circle's or arc's radius / diameter: its centre, radius and the direction its radius point lies in.
	var c: Dictionary = circles.get(id, arcs.get(id, {}))
	var rim: String = c.get("p", c.get("s", ""))
	if not points.has(c.get("c", "")) or not points.has(rim):
		return {}
	var centre: Vector2 = points[c["c"]]
	var rim_pt: Vector2 = points[rim]
	var u := rim_pt - centre
	var r := u.length()
	if r < 0.0001:
		u = Vector2(1, 0)
	elif absf(u.x) < r * 0.2 or absf(u.y) < r * 0.2:
		# The radius point lies along an axis, where the centre mark already is: a leader or a diameter line is drawn at an angle instead (radius up and to the
		# right, diameter up and to the left), as on a drawing, so it does not run along the centre line.
		u = Vector2.from_angle(deg_to_rad(40.0 if kind == "radius" else 140.0))
	return {"kind": kind, "c": centre, "r": r, "u": u}


func angle_spec(l1: String, l2: String) -> Dictionary:
	## The layout spec of the angle between two lines: the point they meet at, a direction along each (away from it) and an arc radius.
	var p1 := _line_points(l1)
	var p2 := _line_points(l2)
	if not points.has(p1[0]) or not points.has(p1[1]) or not points.has(p2[0]) or not points.has(p2[1]):
		return {}
	var a0: Vector2 = points[p1[0]]
	var a1: Vector2 = points[p1[1]]
	var b0: Vector2 = points[p2[0]]
	var b1: Vector2 = points[p2[1]]
	var apex: Variant = Geometry2D.line_intersects_line(a0, a1 - a0, b0, b1 - b0)
	if apex == null:
		return {}
	var point: Vector2 = apex
	var far_a: Vector2 = a1 if a1.distance_to(point) >= a0.distance_to(point) else a0
	var far_b: Vector2 = b1 if b1.distance_to(point) >= b0.distance_to(point) else b0
	var d1 := far_a - point
	var d2 := far_b - point
	if d1.length() < 0.0001 or d2.length() < 0.0001:
		return {}
	return {"kind": "angle", "apex": point, "d1": d1.normalized(), "d2": d2.normalized(), "r": minf(d1.length(), d2.length()) * 0.6}


func perp_spec(point_id: String, line_id: String) -> Dictionary:
	var lp := _line_points(line_id)
	if not points.has(point_id) or not points.has(lp[0]) or not points.has(lp[1]):
		return {}
	var p: Vector2 = points[point_id]
	var foot := Geometry2D.get_closest_point_to_segment(p, points[lp[0]], points[lp[1]])
	return {"kind": "perp", "a": p, "b": foot}


func _is_internal_angle(c: Dictionary) -> bool:
	## A polygon holds its corners with an angle between each pair of its own (construction) centre-to-corner lines: part of the shape,
	## not a dimension anyone typed, so it is not drawn.
	for id in shapes:
		var radial: Array = shapes[id].get("radial_line_ids", [])
		if radial.has(str(c.get("line1_id", ""))) and radial.has(str(c.get("line2_id", ""))):
			return true
	return false


func dimension_items() -> Array:
	## What the sketch's existing (typed, not provisional) dimensions look like: [{id, spec, text}], for sketch_view.gd to draw as a drawing
	## draws them. A circle's / arc's own size dimension is a radius; a distance between two points is linear, horizontal or vertical.
	var out: Array = []
	var radius_of := {}
	for id in circles:
		radius_of[str(circles[id].get("k", ""))] = ["circle", id]
	for id in arcs:
		radius_of[str(arcs[id].get("k", ""))] = ["arc", id]
	for id in constraints:
		var c: Dictionary = constraints[id]
		var type := str(c.get("type", ""))
		if type == "distance" and not bool(c.get("provisional", false)) and float(c.get("distance", 0.0)) > 0.005: # (a zero distance is a shape's own structure, e.g. a circle's cardinal points)
			if radius_of.has(str(id)):
				var which: Array = radius_of[str(id)]
				var rspec := circle_spec("radius", str(which[1]))
				if not rspec.is_empty():
					out.append({"id": id, "spec": rspec, "text": dimension_text("radius", float(c["distance"]))})
			elif points.has(str(c.get("point_a_id", ""))) and points.has(str(c.get("point_b_id", ""))):
				var kind := str(c.get("orientation", "linear"))
				out.append({"id": id, "spec": {"kind": kind, "a": points[c["point_a_id"]], "b": points[c["point_b_id"]]}, "text": dimension_text("linear", float(c["distance"]))})
		elif type == "point_line_distance":
			var pspec := perp_spec(str(c.get("point_id", "")), str(c.get("line_id", "")))
			if not pspec.is_empty():
				out.append({"id": id, "spec": pspec, "text": dimension_text("linear", float(c.get("distance", 0.0)))})
		elif type == "line_distance":
			var lp := _line_points(str(c.get("line1_id", "")))
			var mid_id := str(lp[0])
			if points.has(mid_id):
				var lspec := perp_spec(mid_id, str(c.get("line2_id", "")))
				if not lspec.is_empty():
					out.append({"id": id, "spec": lspec, "text": dimension_text("linear", float(c.get("distance", 0.0)))})
		elif type == "angle" and not _is_internal_angle(c):
			var aspec := angle_spec(str(c.get("line1_id", "")), str(c.get("line2_id", "")))
			if not aspec.is_empty():
				out.append({"id": id, "spec": aspec, "text": dimension_text("angle", float(c.get("angle_degrees", 0.0)))})
	for item in driven_items():
		out.append(item)
	return out


func driven_items() -> Array:
	## The reference dimensions kept between pinned things, measured now from where those things are: [{id, spec, text: "(12.5)", driven: true}]. One whose
	## entities have gone is dropped.
	var out: Array = []
	var keep: Array = []
	for d in driven:
		var g := {}
		for candidate in _ghosts_raw(d["selection"]):
			if candidate["key"] == d["key"]:
				g = candidate
		if g.is_empty() or (g.get("spec", {}) as Dictionary).is_empty():
			continue
		keep.append(d)
		out.append({"id": d["id"], "spec": g["spec"], "text": "(%s)" % dimension_text(_dimension_kind(str(g["key"])), float(g["value"])), "driven": true})
	if keep.size() != driven.size():
		driven = keep
	return out


static func _dimension_kind(key: String) -> String:
	return key if key in ["radius", "diameter", "angle"] else "linear"


func keep_driven(key: String) -> Dictionary:
	## The user pointed at a driven candidate: keep it as a reference dimension. It measures the two pinned things and is drawn in brackets; nothing is
	## sent to the backend (it has no driven dimension), so it lasts as long as the sketch is open. Undo takes it back.
	var g := ghost(key)
	if g.is_empty() or not bool(g.get("driven", false)):
		return {"ok": false, "message": ""}
	_driven_n += 1
	var id := "driven%d" % _driven_n
	driven.append({"id": id, "selection": selection.duplicate(true), "key": key})
	_undo.append({"label": "reference dimension", "calls": [], "driven_id": id})
	selection.clear()
	ghosts.clear()
	changed.emit()
	return {"ok": true, "message": ""}


func _distance_apply(a: String, b: String, orientation: String) -> Dictionary:
	## Typing a distance between two points updates the dimension already between them (if any), else makes one.
	for id in constraints:
		var c: Dictionary = constraints[id]
		if str(c.get("type", "")) == "distance" and str(c.get("orientation", "linear")) == orientation:
			var pa := str(c.get("point_a_id", ""))
			var pb := str(c.get("point_b_id", ""))
			if (pa == a and pb == b) or (pa == b and pb == a):
				return {"patch_id": id, "factor": 1.0}
	return {"create": {"type": "distance", "point_a_id": a, "point_b_id": b, "orientation": orientation}, "factor": 1.0, "value_key": "distance"}


func ghost(key: String) -> Dictionary:
	for g in ghosts:
		if g["key"] == key:
			return g
	return {}


func confirm_ghost(key: String, value: float) -> Dictionary:
	## The user typed `value` (mm or degrees) for a dimension candidate. Returns {ok, message}.
	var g := ghost(key)
	if g.is_empty():
		return {"ok": false, "message": ""}
	if bool(g.get("driven", false)):
		return keep_driven(key) # a reference dimension has no value to type: it measures
	if value <= 0.0:
		var msg := "A dimension has to be bigger than zero."
		status.emit(msg)
		return {"ok": false, "message": msg}
	if busy:
		return {"ok": false, "message": ""}
	busy = true
	var apply: Dictionary = g["apply"]
	var stored: float = value * float(apply.get("factor", 1.0))
	var r: Dictionary
	var calls: Array = []
	if apply.has("patch_id"):
		r = await api.call(HTTPClient.METHOD_PATCH, SKETCH + sketch_id + "/constraints/" + str(apply["patch_id"]), {"value": stored})
	else:
		var body: Dictionary = (apply["create"] as Dictionary).duplicate()
		body[str(apply.get("value_key", "distance"))] = stored
		r = await _post(SKETCH + sketch_id + "/constraints", body)
		if r["ok"]:
			calls.append([HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(r["json"]["id"])])
	if not r["ok"]:
		busy = false
		var message := "Couldn't set that dimension: %s" % str(r["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	if not calls.is_empty():
		_undo.append({"label": "dimension", "calls": calls})
	await refresh(false)
	var kept := converged
	if not kept and not calls.is_empty():
		busy = false
		await undo()
		busy = true
		status.emit("That size conflicts with the other constraints, so it wasn't added.")
	selection.clear()
	ghosts.clear()
	busy = false
	changed.emit()
	return {"ok": kept, "message": "" if kept else "That size conflicts with the other constraints, so it wasn't added."}


# --- Undo --------------------------------------------------------------------------------

func can_undo() -> bool:
	return not _undo.is_empty() and not busy


func undo_label() -> String:
	return str(_undo.back()["label"]) if not _undo.is_empty() else ""


func undo() -> bool:
	## Takes back the last thing made, by deleting it (the flat app's way: undo only, no redo).
	if _undo.is_empty():
		return false
	var step: Dictionary = _undo.pop_back()
	var was_busy := busy
	busy = true
	if step.has("driven_id"):
		driven = driven.filter(func(d) -> bool: return d["id"] != step["driven_id"])
	for entry in step["calls"]:
		await api.call(int(entry[0]), str(entry[1]), entry[2] if entry.size() > 2 else null)
	pending.clear()
	selection.clear()
	ghosts.clear()
	await refresh(true)
	busy = was_busy
	return true
