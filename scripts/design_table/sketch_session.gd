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

const SKETCH := "/sketch/sketches/"
const TAPS_NEEDED := {"line": 2, "rectangle": 2, "circle": 2, "arc": 3, "polygon": 2, "point": 1}
const SELECT_NEEDED := {"horizontal": 1, "vertical": 1, "parallel": 2, "perpendicular": 2, "coincident": 2}
const PARALLEL_COS := 0.9998 ## two lines closer than ~1.1 degrees to parallel are measured as a distance, not an angle
const AXIS_SNAP_DEGREES := 4.0 ## a line within this of horizontal / vertical is made exactly so

var api: Callable
var owner_part_id := ""
var feature_id := "" ## the sketch FEATURE (what an extrude names)
var sketch_id := ""
var plane_feature_id := ""
var plane: Dictionary = {} ## {origin, x, y, n} in the part's frame, mm

var tool := ""
var pending: Array = [] ## taps so far for the current tool: [{uv, id}]
var polygon_sides := 6
var busy := false

var points := {} ## id -> Vector2 (sheet mm)
var point_locked := {} ## id -> bool
var lines := {} ## id -> {a, b, construction}
var circles := {} ## id -> {c, p, k} (centre point, radius point, radius constraint id)
var arcs := {} ## id -> {c, s, e, k}
var shapes := {} ## rectangle / polygon id -> {kind, point_ids}
var constraints := {} ## id -> the backend's constraint dictionary
var profile_status := ""
var dof := -1
var converged := true

var selection: Array = [] ## picked entities for the constraint / dimension tools: [{kind, id}]
var ghosts: Array = [] ## dimension candidates for the current selection (see _build_ghosts)

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
	var refreshed := await refresh(true)
	busy = false
	return refreshed


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
				circles[id] = {"c": str(e["center_point_id"]), "p": str(e["radius_point_id"]), "k": str(e.get("radius_constraint_id", ""))}
			"arc":
				arcs[id] = {"c": str(e["center_point_id"]), "s": str(e["start_point_id"]), "e": str(e["end_point_id"]), "k": str(e.get("radius_constraint_id", ""))}
			"rectangle":
				shapes[id] = {"kind": "rectangle", "point_ids": e.get("corner_point_ids", [])}
			"polygon":
				shapes[id] = {"kind": "polygon", "point_ids": e.get("vertex_point_ids", [])}


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
		_: result = {"ok": false, "message": ""}
	busy = false
	if not result["ok"] and str(result["message"]) != "":
		status.emit(str(result["message"]))
	return {"ok": bool(result["ok"]), "done": bool(result["ok"]), "message": str(result["message"])}


func _post(path: String, body) -> Dictionary:
	return await api.call(HTTPClient.METHOD_POST, path, body)


func _point(pick: Dictionary, created: Array) -> String:
	## The id of a pick's point: the existing one it snapped to, else a new one at its position.
	if str(pick.get("id", "")) != "":
		return str(pick["id"])
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
	## One laser pick of an entity for a constraint tool or Dimension. Returns {ok, done, message}.
	if busy or entity.is_empty():
		return {"ok": false, "done": false, "message": ""}
	if tool == "dimension":
		return _select_for_dimension(entity)
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
	## What the current selection can be dimensioned as, the way the flat app offers it: one line -> its length;
	## one circle / arc -> radius and diameter; two points -> linear, horizontal and vertical distance; a point and
	## a line -> their distance; two lines -> a distance if parallel, else an angle. Each: {key, label, unit,
	## value, uv (where the label floats), apply: {patch_id?, create?, factor}}.
	var out: Array = []
	if selection.is_empty():
		return out
	var first: Dictionary = selection[0]
	if selection.size() == 1:
		match first["kind"]:
			"line":
				var pts := _line_points(first["id"])
				if points.has(pts[0]) and points.has(pts[1]):
					var d: float = points[pts[0]].distance_to(points[pts[1]])
					out.append(_ghost("length", "Length", "mm", d, (points[pts[0]] + points[pts[1]]) * 0.5,
						_distance_apply(pts[0], pts[1], "linear")))
			"circle", "arc":
				var c: Dictionary = circles.get(first["id"], arcs.get(first["id"], {}))
				var rim: String = c.get("p", c.get("s", ""))
				if points.has(c.get("c", "")) and points.has(rim) and str(c.get("k", "")) != "":
					var r: float = points[c["c"]].distance_to(points[rim])
					out.append(_ghost("radius", "Radius", "mm", r, points[c["c"]] + Vector2(r * 0.5, 0), {"patch_id": c["k"], "factor": 1.0}))
					out.append(_ghost("diameter", "Diameter", "mm", r * 2.0, points[c["c"]] + Vector2(-r * 0.5, 0), {"patch_id": c["k"], "factor": 0.5}))
		return out
	var second: Dictionary = selection[1]
	if first["kind"] == "point" and second["kind"] == "point":
		var a: String = first["id"]
		var b: String = second["id"]
		if a != b and points.has(a) and points.has(b):
			var pa: Vector2 = points[a]
			var pb: Vector2 = points[b]
			out.append(_ghost("linear", "Distance", "mm", pa.distance_to(pb), (pa + pb) * 0.5, _distance_apply(a, b, "linear")))
			out.append(_ghost("horizontal", "Horizontal", "mm", absf(pb.x - pa.x), Vector2((pa.x + pb.x) * 0.5, minf(pa.y, pb.y)), _distance_apply(a, b, "horizontal")))
			out.append(_ghost("vertical", "Vertical", "mm", absf(pb.y - pa.y), Vector2(minf(pa.x, pb.x), (pa.y + pb.y) * 0.5), _distance_apply(a, b, "vertical")))
	elif first["kind"] == "line" and second["kind"] == "line" and first["id"] != second["id"]:
		var l1 := _line_points(first["id"])
		var l2 := _line_points(second["id"])
		if points.has(l1[0]) and points.has(l1[1]) and points.has(l2[0]) and points.has(l2[1]):
			var d1: Vector2 = (points[l1[1]] - points[l1[0]]).normalized()
			var d2: Vector2 = (points[l2[1]] - points[l2[0]]).normalized()
			var mid: Vector2 = (points[l1[0]] + points[l1[1]] + points[l2[0]] + points[l2[1]]) * 0.25
			if absf(d1.dot(d2)) >= PARALLEL_COS:
				var dist: float = absf((points[l2[0]] - points[l1[0]]).cross(d1))
				out.append(_ghost("line_distance", "Distance", "mm", dist, mid, {"create": {"type": "line_distance", "line1_id": first["id"], "line2_id": second["id"]}, "factor": 1.0, "value_key": "distance"}))
			else:
				var ang := rad_to_deg(acos(clampf(d1.dot(d2), -1.0, 1.0)))
				out.append(_ghost("angle", "Angle", "deg", ang, mid, {"create": {"type": "angle", "line1_id": first["id"], "line2_id": second["id"]}, "factor": 1.0, "value_key": "angle_degrees"}))
	elif (first["kind"] == "point" and second["kind"] == "line") or (first["kind"] == "line" and second["kind"] == "point"):
		var pt: String = first["id"] if first["kind"] == "point" else second["id"]
		var ln: String = first["id"] if first["kind"] == "line" else second["id"]
		var lp := _line_points(ln)
		if points.has(pt) and points.has(lp[0]) and points.has(lp[1]):
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(points[pt], points[lp[0]], points[lp[1]])
			var dist2: float = points[pt].distance_to(closest)
			out.append(_ghost("point_line", "Distance", "mm", dist2, (points[pt] + closest) * 0.5, {"create": {"type": "point_line_distance", "point_id": pt, "line_id": ln}, "factor": 1.0, "value_key": "distance"}))
	return out


func _ghost(key: String, label: String, unit: String, value: float, uv: Vector2, apply: Dictionary) -> Dictionary:
	return {"key": key, "label": label, "unit": unit, "value": value, "uv": uv, "apply": apply}


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
	for entry in step["calls"]:
		await api.call(int(entry[0]), str(entry[1]), null)
	pending.clear()
	selection.clear()
	ghosts.clear()
	await refresh(true)
	busy = was_busy
	return true
