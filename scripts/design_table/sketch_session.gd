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
signal fully_constrained ## a solve has just brought the sketch (the same one, already open) to fully constrained

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")

const ShapeProposals := preload("res://scripts/motion/shape_proposals.gd")
const SketchRigidity := preload("res://scripts/design_table/sketch_rigidity.gd")
const SKETCH := "/sketch/sketches/"
const SELECT := "select" ## the tool that picks entities for the contextual menu (no limit on how many)
const TAPS_NEEDED := {"line": 2, "rectangle": 2, "circle": 2, "arc": 3, "polygon": 2, "point": 1, "slot": 3, "ellipse": 3, "ellipse_arc": 5, "spline": 9999, "text": 1} ## (a spline takes any number: Finish makes it)
const CURVE_KINDS := ["ellipse", "ellipse_arc", "spline"] ## entities drawn from a sampled outline
const OUTLINE_SEGMENTS := 64
const SELECT_NEEDED := {"horizontal": 1, "vertical": 1, "parallel": 2, "perpendicular": 2, "coincident": 2}
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
var circle_method := "centre" ## "centre" (a centre and a point on it) | "three" (three points on it)
var rect_method := "corners" ## "corners" (two opposite corners) | "centre" (the centre and a corner) | "three" (one side and the width)
var line_method := "ends" ## "ends" (end to end, chained) | "middle" (the middle and one end)
var busy := false

var points := {} ## id -> Vector2 (sheet mm)
var point_xy := {} ## id -> [x, y]: the same points as the backend sent them (64-bit; a Vector2 is not), what a point drag starts the projector from (S10)
var point_locked := {} ## id -> bool
var reference_ids := {} ## id -> true: the points and shapes the backend says are reference helpers (made only to point the sketch at the part's own corner, edge, hole or face). Drawn quietly, never offered for selection or deletion
var lines := {} ## id -> {a, b, construction}
var circles := {} ## id -> {c, p, k, construction} (centre point, radius point, radius constraint id)
var ellipses := {} ## id -> {c, ma (major point), mi (minor point), km / kn (the size constraints), construction}
var ellipse_arcs := {} ## id -> {c, ma, mi, s, e, construction}
var splines := {} ## id -> {through: [point ids], control: [handle point ids], construction}
var texts := {} ## id -> {anchor, content, font, size, rot, construction}
var text_outlines := {} ## text id -> [glyph polylines], fetched from the backend (its font outlines), keyed by what they were made from
var _text_keys := {}
var text_content := "" ## what the Text tool places next
var text_font := "Open Sans"
var text_size := 10.0
var text_rotation := 0.0
var arcs := {} ## id -> {c, s, e, k, construction}
var shapes := {} ## rectangle / polygon id -> {kind, point_ids}
var _structure := {} ## shape id -> its structural constraint ids, as the last press read them (kept across refreshes, which rebuild `shape_records`)
var shape_records := {} ## id -> the backend's whole entity dictionary plus "kind", for the seven closed-form shape families (F8: shape_proposals.gd reads these, including every circle / arc)
var constraints := {} ## id -> the backend's constraint dictionary
var profile_status := ""
var profile_open_chain := false ## no closed profile but exactly one open chain of lines / arcs (the backend's `open_chain`): a thin Revolve can use it
var dof := -1
var converged := true
var failed_constraint_ids: Array = [] ## the backend's `solver_reported_failed_constraint_ids` of the last solve: only ever filled when the solve did not converge (a conflict that came later, or one the user kept)
var label_override: Dictionary = {} ## constraint id -> a placement being dragged (S6): drawn instead of the saved one until the drop saves it (or the drag is let go)
var diameter_shown: Dictionary = {} ## constraint id -> true: a circle's / arc's size dimension read as a diameter (the flat app's R / diameter toggle; the stored value stays the radius). Saved in the label's `show`
var axis_semi: Dictionary = {} ## constraint id -> true (semi) | false (full): an ellipse axis dimension's saved reading (`show`), absent when none is saved (default_show)
var _show_writes: Dictionary = {} ## constraint id -> PUTs of `show` in flight
var _state_sketch := "" ## the sketch the last state below belongs to
var _last_state := ""

var references_ok := false ## the part's own vertices and edges may be used as references (set by the editor: the topology it shows is the one the backend resolves against)
var annotations: Array = [] ## T5: picked dimension labels and constraint glyphs: [{kind: "dimension" | "constraint", id}] (a dimension IS a constraint of the backend; it is a separate kind here because it is picked by its label)
var selection: Array = [] ## picked entities for the constraint / dimension tools: [{kind, id}]
var ghosts: Array = [] ## dimension candidates for the current selection (see _build_ghosts)

var _ref_points := {} ## "body:vertex index" -> the pinned point made for it; "body:c<edge index>" -> the pinned centre of that circular edge
var reference_rows: Array = [] ## the backend's health of this sketch's references (GET .../external-references): [{point_id, body_id, kind, vertex_index, status, reason, candidates}]
var ref_dims: Array = [] ## the sketch's persistent reference-only (driven) dimensions, as the backend last said (every solve brings them fresh, so a value follows the part): [{id, kind, refs: [{type, id}], value}]. They measure, they never drive: the solver does not see them
var _undo: Array = [] ## [{label, calls: [[method, path]]}]
var chain_first := "" ## the point the current run of lines started on: a line that ends on it closes the loop and ends the run ("" between runs)
var _pending_holds: Array = [] ## ids of the constraints the picks of the shape being made are held by (a point welded to the origin, a midpoint, a point on a curve): taken back with it


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
		# A sketch on a face gets the same default origin as in the flat app (the face's bottom-left corner, or a disc's centre), worked out once by the
		# backend: there is no orientation step here and no flip or rotate. A reference or created plane sends nothing (the plane's own origin, as before).
		feature_body = {"plane_feature_id": plane_feature_id, "origin": "auto"}
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
	plane = SketchMath.with_frame(plane, sketch["json"]) # the sketch's (0, 0) may not be the plane's origin; the frame is the backend's own when it sends one
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


# --- Names (parity follow-ups F5, A1) ------------------------------------------------------------------------------------------------
# The backend numbers everything at creation and keeps the number (DIDSA-CAD backend/app/sketch/numbering.py): `Line 3`, `Point 12`, `D4`, `Coincident 2`. Points, constraints
# and reference dimensions carry `number` in the solve-and-refresh state, the other entities are in the export's `numbers` map (id -> number). An older backend sends none:
# then the name falls back to the thing's place in its kind (the flat app's rule), so it never shows an id.

const ENTITY_LABELS := {"point": "Point", "line": "Line", "circle": "Circle", "arc": "Arc", "ellipse": "Ellipse", "ellipse_arc": "Ellipse Arc", "polygon": "Polygon", "slot": "Slot", "rectangle": "Rectangle", "spline": "Spline", "text": "Text"}
const RELATION_LABELS := {"horizontal": "Horizontal", "vertical": "Vertical", "coincident": "Coincident", "parallel": "Parallel", "perpendicular": "Perpendicular", "equal_length": "Equal length",
	"tangent": "Tangent", "curve_tangent": "Curve tangent", "equal_radius": "Equal radius", "concentric": "Concentric", "collinear": "Collinear", "at_midpoint": "Midpoint",
	"spline_tangent": "Spline tangent", "point_on_line": "Point on line", "point_on_circle": "Point on circle", "point_on_ellipse": "Point on ellipse", "fixed": "Fixed"}
const DIMENSION_TYPES := ["distance", "angle", "line_distance", "point_line_distance", "arc_length", "horizontal_angle", "point_angle", "point_circle_distance", "circle_distance", "line_circle_distance"]

var numbers := {} ## id -> the backend's number (points, entities, constraints, reference dimensions); an id the backend has not numbered is absent
var hole_points := {} ## id -> true: the reference points that track a hole's centre (named `Hole centre n`; the others are `Part corner n`)


func number_of(id: String) -> int:
	## The backend's number of a point, entity, dimension or relation; -1 when it has none (the origin, shape glue, an older backend).
	return int(numbers[id]) if numbers.has(id) and numbers[id] != null else -1


func _note_number(id: String, value: Variant) -> void:
	if value != null and (value is float or value is int) and float(value) >= 1.0:
		numbers[id] = int(value)


func _position_number(kind: String, id: String) -> int:
	## The flat app's fallback (an older backend): 1 + the place among the things of its kind, in the order the backend sent them.
	var keys: Array = []
	match kind:
		"point":
			for pid in points:
				if not is_origin(str(pid)) and not is_reference(str(pid)):
					keys.append(pid)
		"line": keys = lines.keys()
		"circle": keys = circles.keys()
		"arc": keys = arcs.keys()
		"ellipse": keys = ellipses.keys()
		"ellipse_arc": keys = ellipse_arcs.keys()
		"spline": keys = splines.keys()
		"text": keys = texts.keys()
		"dimension":
			for cid in constraints:
				if str((constraints[cid] as Dictionary).get("type", "")) in DIMENSION_TYPES:
					keys.append(cid)
		"constraint":
			for cid in constraints:
				if str((constraints[cid] as Dictionary).get("type", "")) not in DIMENSION_TYPES:
					keys.append(cid)
	var i := keys.find(id)
	return i + 1 if i >= 0 else -1


func name_of(kind: String, id: String) -> String:
	## What a person calls a selected thing: `Line 3`, `Point 12`, `Origin`, `Part corner 2`, `D4 Length 40`, `Coincident 2`. Never an id ("" when it names nothing known).
	var n := number_of(id)
	match kind:
		"point":
			if is_origin(id):
				return "Origin"
			if is_reference(id):
				return "%s %d" % ["Hole centre" if hole_points.has(id) else "Part corner", maxi(n, 1)]
			n = n if n > 0 else _position_number("point", id)
			return "Point %d" % n if n > 0 else "Point"
		"dimension":
			n = n if n > 0 else _position_number("dimension", id)
			var word := _dimension_word(id)
			var v := dimension_value(id)
			var shown := "" if not bool(v.get("ok", false)) else " %s" % format_value(float(v["value"]))
			return ("D%d" % n if n > 0 else "Dimension") + ((" " + word) if word != "" else "") + shown
		"constraint":
			var label := str(RELATION_LABELS.get(str((constraints.get(id, {}) as Dictionary).get("type", "")), "Relation"))
			n = n if n > 0 else _position_number("constraint", id)
			return "%s %d" % [label, n] if n > 0 else label
	var base := str(ENTITY_LABELS.get(kind, kind.replace("_", " ").capitalize()))
	n = n if n > 0 else _position_number(kind, id)
	return "%s %d" % [base, n] if n > 0 else base


func _dimension_word(id: String) -> String:
	## The kind of a dimension in a word, for its name (`D4 Length 40`).
	var c: Dictionary = constraints.get(id, {})
	if is_size_dimension(id):
		return "Diameter" if bool(diameter_shown.get(id, false)) else "Radius"
	if not ellipse_axis_line(id).is_empty():
		return "Axis"
	match str(c.get("type", "")):
		"distance":
			return "Length"
		"angle", "horizontal_angle", "point_angle":
			return "Angle"
		"arc_length":
			return "Arc length"
		"line_distance", "point_line_distance", "point_circle_distance", "circle_distance", "line_circle_distance":
			return "Distance"
	return ""


# --- Reading the backend's answer --------------------------------------------------------

func refresh(with_entities: bool = true, solve_body: Variant = null) -> bool:
	## ONE solve-and-refresh (points, constraints, profile), plus an export when entities changed. `solve_body` (S10): the drop's {anchor_point_ids, point_updates}.
	var state: Dictionary = await api.call(HTTPClient.METHOD_POST, SKETCH + sketch_id + "/solve-and-refresh", solve_body)
	if not state["ok"]:
		status.emit("Couldn't solve the sketch: %s" % str(state["error"]))
		return false
	_ingest_state(state["json"])
	if with_entities:
		var exported: Dictionary = await api.call(HTTPClient.METHOD_GET, SKETCH + sketch_id + "/export", null)
		if exported["ok"]:
			_ingest_entities(exported["json"])
			if not texts.is_empty() or not text_outlines.is_empty():
				await _fetch_text_outlines()
	_note_state()
	changed.emit()
	return true


func _ingest_state(json: Dictionary) -> void:
	revision += 1
	points.clear()
	point_xy.clear()
	point_locked.clear()
	for p in json.get("points", []):
		points[str(p["id"])] = Vector2(float(p["x"]), float(p["y"]))
		point_xy[str(p["id"])] = [float(p["x"]), float(p["y"])]
		point_locked[str(p["id"])] = bool(p.get("is_locked", false))
		_note_number(str(p["id"]), p.get("number"))
		if bool(p.get("is_reference", false)):
			reference_ids[str(p["id"])] = true
		else:
			reference_ids.erase(str(p["id"]))
	constraints.clear()
	for c in json.get("constraints", []):
		constraints[str(c["id"])] = c
		_note_number(str(c["id"]), c.get("number"))
		if c.get("label") is Dictionary and (c["label"] as Dictionary).has("show") and int(_show_writes.get(str(c["id"]), 0)) == 0:
			_note_show(str(c["id"]), str((c["label"] as Dictionary)["show"])) # the saved reading (radius / diameter / semi / full), both apps' alike
	ref_dims = json.get("reference_dimensions", [])
	for d in ref_dims:
		_note_number(str((d as Dictionary).get("id", "")), (d as Dictionary).get("number"))
	var solve: Dictionary = json.get("solve", {})
	dof = int(solve.get("dof", -1))
	converged = bool(solve.get("converged", true))
	failed_constraint_ids = _strings(solve.get("solver_reported_failed_constraint_ids", []))
	profile_status = str(json.get("profile", {}).get("status", ""))
	profile_open_chain = bool(json.get("profile", {}).get("open_chain", false))


func _ingest_entities(json: Dictionary) -> void:
	lines.clear()
	circles.clear()
	arcs.clear()
	ellipses.clear()
	ellipse_arcs.clear()
	splines.clear()
	texts.clear()
	shapes.clear()
	shape_records.clear()
	reference_ids.clear()
	for id in json.get("reference_ids", []):
		reference_ids[str(id)] = true
	var nums: Variant = json.get("numbers", {})
	if nums is Dictionary:
		for nid in nums:
			_note_number(str(nid), nums[nid])
	hole_points.clear()
	var refs: Variant = json.get("external_references", [])
	if refs is Array:
		for r in refs:
			if r is Dictionary and str(r.get("kind", "")) == "circle_centre":
				hole_points[str(r.get("point_id", r.get("id", "")))] = true
	elif refs is Dictionary:
		for rid in refs:
			if refs[rid] is Dictionary and str(refs[rid].get("kind", "")) == "circle_centre":
				hole_points[str(rid)] = true
	for e in json.get("entities", []):
		var id := str(e.get("id", ""))
		if str(e.get("type", "")) in ["circle", "arc", "ellipse", "ellipse_arc", "rectangle", "polygon", "slot"]:
			var rec: Dictionary = (e as Dictionary).duplicate(true)
			rec["kind"] = str(e["type"])
			if _structure.has(id):
				rec["structural_constraint_ids"] = _structure[id]
			shape_records[id] = rec
		match str(e.get("type", "")):
			"line":
				lines[id] = {"a": str(e["start_point_id"]), "b": str(e["end_point_id"]), "construction": bool(e.get("construction", false))}
			"circle":
				circles[id] = {"c": str(e["center_point_id"]), "p": str(e["radius_point_id"]), "k": str(e.get("radius_constraint_id", "")), "cards": _strings(e.get("cardinal_point_ids", [])), "construction": bool(e.get("construction", false))}
			"arc":
				arcs[id] = {"c": str(e["center_point_id"]), "s": str(e["start_point_id"]), "e": str(e["end_point_id"]), "k": str(e.get("radius_constraint_id", "")), "construction": bool(e.get("construction", false))}
			"ellipse":
				ellipses[id] = {"c": str(e["center_point_id"]), "ma": str(e["major_point_id"]), "mi": str(e["minor_point_id"]), "man": str(e.get("major_point_neg_id", "")), "mnn": str(e.get("minor_point_neg_id", "")), "km": str(e.get("major_constraint_id", "")), "kn": str(e.get("minor_constraint_id", "")), "construction": bool(e.get("construction", false))}
			"ellipse_arc":
				ellipse_arcs[id] = {"c": str(e["center_point_id"]), "ma": str(e["major_point_id"]), "mi": str(e["minor_point_id"]), "s": str(e["start_point_id"]), "e": str(e["end_point_id"]), "construction": bool(e.get("construction", false))}
			"spline":
				splines[id] = {"through": e.get("through_point_ids", []), "control": e.get("control_point_ids", []), "construction": bool(e.get("construction", false))}
			"text":
				texts[id] = {"anchor": str(e["anchor_point_id"]), "content": str(e.get("content", "")), "font": str(e.get("font", "")), "size": float(e.get("size", 10.0)), "rot": float(e.get("rotation_degrees", 0.0)), "construction": bool(e.get("construction", false))}
			"rectangle":
				shapes[id] = {"kind": "rectangle", "point_ids": e.get("corner_point_ids", []), "own_point_ids": _strings(e.get("corner_point_ids", [])) + _strings([e.get("center_point_id", "")])}
			"polygon":
				shapes[id] = {"kind": "polygon", "point_ids": e.get("vertex_point_ids", []), "radial_line_ids": e.get("radial_line_ids", []), "own_point_ids": _strings(e.get("vertex_point_ids", [])) + _strings([e.get("center_point_id", "")])}
			"slot":
				shapes[id] = {"kind": "slot", "point_ids": [str(e.get("center1_point_id", "")), str(e.get("center2_point_id", ""))],
					"own_point_ids": _strings([e.get("center1_point_id", ""), e.get("center2_point_id", ""), e.get("a_point_id", ""), e.get("b_point_id", ""), e.get("c_point_id", ""), e.get("d_point_id", "")])}


static func _strings(values: Array) -> Array:
	## The non-empty entries of a list of ids, as Strings.
	var out: Array = []
	for v in values:
		if v != null and str(v) != "":
			out.append(str(v))
	return out


func outline_of(kind: String, id: String) -> Array:
	## The sampled outline (Vector2s) of an ellipse, partial ellipse or spline, from its points; [] if a point is missing.
	match kind:
		"ellipse":
			var e: Dictionary = ellipses.get(id, {})
			if not points.has(e.get("c", "")) or not points.has(e.get("ma", "")) or not points.has(e.get("mi", "")):
				return []
			return ellipse_points(points[e["c"]], points[e["ma"]], points[e["mi"]], 0.0, TAU, OUTLINE_SEGMENTS)
		"ellipse_arc":
			var a: Dictionary = ellipse_arcs.get(id, {})
			for k in ["c", "ma", "mi", "s", "e"]:
				if not points.has(a.get(k, "")):
					return []
			var t0 := ellipse_param(points[a["c"]], points[a["ma"]], points[a["mi"]], points[a["s"]])
			var t1 := ellipse_param(points[a["c"]], points[a["ma"]], points[a["mi"]], points[a["e"]])
			var sweep := fposmod(t1 - t0, TAU)
			if sweep < 0.00001:
				sweep = TAU
			return ellipse_points(points[a["c"]], points[a["ma"]], points[a["mi"]], t0, t0 + sweep, OUTLINE_SEGMENTS)
		"spline":
			var sp: Dictionary = splines.get(id, {})
			var through: Array = sp.get("through", [])
			var control: Array = sp.get("control", [])
			var out: Array = []
			for i in through.size() - 1:
				if not points.has(through[i]) or not points.has(through[i + 1]):
					return []
				var p0: Vector2 = points[through[i]]
				var p3: Vector2 = points[through[i + 1]]
				var h1 := p0.lerp(p3, 1.0 / 3.0)
				var h2 := p0.lerp(p3, 2.0 / 3.0)
				if control.size() >= 2 * i + 2 and points.has(control[2 * i]) and points.has(control[2 * i + 1]):
					h1 = points[control[2 * i]]
					h2 = points[control[2 * i + 1]]
				for k in 17:
					if i > 0 and k == 0:
						continue
					out.append(p0.bezier_interpolate(h1, h2, p3, float(k) / 16.0))
			return out
	return []


static func ellipse_points(centre: Vector2, major: Vector2, minor: Vector2, from_t: float, to_t: float, segments: int) -> Array:
	## Points of an ellipse (centre, the end of the major axis, the end of the minor axis) from parameter `from_t` to `to_t` (radians).
	var a_vec := major - centre
	var b_vec := minor - centre
	var out: Array = []
	for i in segments + 1:
		var t := from_t + (to_t - from_t) * float(i) / float(segments)
		out.append(centre + a_vec * cos(t) + b_vec * sin(t))
	return out


static func ellipse_param(centre: Vector2, major: Vector2, minor: Vector2, p: Vector2) -> float:
	## The parameter t (radians) at which the ellipse passes the point p (or the point's direction).
	var a_vec := major - centre
	var b_vec := minor - centre
	var rel := p - centre
	var u := rel.dot(a_vec.normalized()) / maxf(a_vec.length(), 0.000001)
	var v := rel.dot(b_vec.normalized()) / maxf(b_vec.length(), 0.000001)
	return atan2(v, u)


func is_reference(id: String) -> bool:
	## A reference helper (see reference_ids): the sketch's plumbing to the part's own geometry, not the user's.
	return reference_ids.has(id)


func profile_ok() -> bool:
	## True if the sketch holds a closed profile an extrude can use.
	return profile_status == "closed_loop" or profile_status == "multiple_loops"


func open_chain_ok() -> bool:
	## True if the sketch has no closed profile but one open chain: only a thin Revolve can use that (a solid one needs a closed shape).
	return not profile_ok() and profile_open_chain


func entity_count() -> int:
	return lines.size() + circles.size() + arcs.size()


# --- Tools -----------------------------------------------------------------------------

func set_tool(tool_id: String) -> void:
	tool = tool_id
	pending.clear()
	chain_first = ""
	selection.clear()
	ghosts.clear()


func taps_needed() -> int:
	if (tool == "circle" and circle_method == "three") or (tool == "rectangle" and rect_method == "three"):
		return 3
	return int(TAPS_NEEDED.get(tool, 0))


func preview_id() -> String:
	## What the rubber band should draw for the tool as it is set now (sketch_view.gd's set_preview): the tool, or a variant for another way of making it.
	if tool == "circle" and circle_method == "three":
		return "circle3"
	if tool == "rectangle" and rect_method != "corners":
		return "rect_centre" if rect_method == "centre" else "rect3"
	if tool == "line" and line_method == "middle":
		return "line_mid"
	return tool


func set_method(tool_id: String, method: String) -> void:
	## Chooses how a circle, rectangle or line is made (taps already placed are forgotten: they meant something else).
	match tool_id:
		"circle": circle_method = method
		"rectangle": rect_method = method
		"line": line_method = method
	pending.clear()
	chain_first = ""


func finish_chain() -> void:
	## Ends a run of lines: the next tap starts afresh.
	pending.clear()
	chain_first = ""


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
	_pending_holds.clear()
	var result: Dictionary
	match tool:
		"point": result = await _make_point(taps)
		"line": result = await _make_line(taps)
		"rectangle": result = await _make_rectangle(taps)
		"circle": result = await _make_circle(taps)
		"arc": result = await _make_arc(taps)
		"polygon": result = await _make_polygon(taps)
		"slot": result = await _make_slot(taps)
		"ellipse": result = await _make_ellipse(taps)
		"ellipse_arc": result = await _make_ellipse_arc(taps)
		"text": result = await _make_text(taps)
		_: result = {"ok": false, "message": ""}
	busy = false
	if not result["ok"]:
		await _drop_holds() # a failed shape leaves none of its constraints behind
		if str(result["message"]) != "":
			status.emit(str(result["message"]))
	return {"ok": bool(result["ok"]), "done": bool(result["ok"]), "message": str(result["message"])}


# --- Trim and Offset (picked entities, not taps) ----------------------------------------------------------

func trim_at(entity: Dictionary, uv: Vector2) -> Dictionary:
	## Trim / Extend the entity under the laser, at the spot tapped. A line: the part between the two crossings around the tap is cut away (split-trim);
	## when the tap is not bracketed by two crossings, the nearer end is moved to the next crossing (trim / extend). A circle: the tapped segment between
	## crossings goes and an arc is left. An arc: its nearer end is moved. NOT undoable here (it moves or replaces what is already drawn).
	## {ok, message}.
	if busy:
		return {"ok": false, "message": ""}
	busy = true
	var kind := str(entity.get("kind", ""))
	var id := str(entity.get("id", ""))
	var message := ""
	var ok := false
	if kind == "line" and lines.has(id):
		var split: Dictionary = await _post(SKETCH + sketch_id + "/lines/" + id + "/split-trim", {"click_x": uv.x, "click_y": uv.y})
		if split["ok"]:
			ok = true
		else:
			var l: Dictionary = lines[id]
			var near: String = l["a"] if uv.distance_to(points.get(l["a"], uv)) <= uv.distance_to(points.get(l["b"], uv)) else l["b"]
			var trimmed: Dictionary = await _post(SKETCH + sketch_id + "/lines/" + id + "/trim", {"moved_point_id": near})
			ok = bool(trimmed["ok"])
			message = "" if ok else _trim_reason(trimmed)
	elif kind == "circle" and circles.has(id):
		var cut: Dictionary = await _post(SKETCH + sketch_id + "/circles/" + id + "/trim", {"click_x": uv.x, "click_y": uv.y})
		ok = bool(cut["ok"])
		message = "" if ok else _trim_reason(cut)
	elif kind == "arc" and arcs.has(id):
		var a: Dictionary = arcs[id]
		var end_id: String = a["s"] if uv.distance_to(points.get(a["s"], uv)) <= uv.distance_to(points.get(a["e"], uv)) else a["e"]
		var moved: Dictionary = await _post(SKETCH + sketch_id + "/arcs/" + id + "/trim", {"moved_point_id": end_id})
		ok = bool(moved["ok"])
		message = "" if ok else _trim_reason(moved)
	else:
		message = "Aim at a line, circle or arc to trim."
	busy = false
	if ok:
		await refresh(true)
		message = "Trimmed. (Trim can't be undone here yet: draw it again if it was wrong.)"
	if message != "":
		status.emit(message)
	return {"ok": ok, "message": message}


func _trim_reason(r: Dictionary) -> String:
	if int(r.get("code", 0)) == 422:
		return "There is nothing to trim it to there: it needs another line or curve crossing it."
	return "Couldn't trim that: %s" % str(r.get("error", ""))


func offset_entity(entity: Dictionary, distance: float) -> Dictionary:
	## A line or arc copied `distance` mm to one side (a negative distance the other). One step on Undo. {ok, message}.
	if busy:
		return {"ok": false, "message": ""}
	var kind := str(entity.get("kind", ""))
	var id := str(entity.get("id", ""))
	if kind != "line" and kind != "arc":
		return {"ok": false, "message": "Offset takes a line or an arc."}
	if is_zero_approx(distance):
		return {"ok": false, "message": "The offset can't be zero."}
	busy = true
	var route := "/lines/%s/offset" % id if kind == "line" else "/arcs/%s/offset" % id
	var r: Dictionary = await _post(SKETCH + sketch_id + route, {"distance": distance, "construction": false})
	busy = false
	if not r["ok"]:
		var message := "Couldn't offset that: %s" % str(r["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	var made: Dictionary = (r["json"] as Dictionary).get("line", (r["json"] as Dictionary).get("arc", {}))
	var made_id := str(made.get("id", ""))
	await _finish("offset", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + ("/lines/" if kind == "line" else "/arcs/") + made_id]])
	return {"ok": true, "message": ""}


func _ellipse_frame(taps: Array, created: Array) -> Dictionary:
	## The centre and major-axis points of the first two taps and the minor radius from the third (its distance off the major axis), or {}.
	var centre_id := await _point(taps[0], created)
	var major_id := await _point(taps[1], created)
	if centre_id == "" or major_id == "":
		return {}
	var c: Vector2 = points.get(centre_id, taps[0]["uv"])
	var m: Vector2 = points.get(major_id, taps[1]["uv"])
	var a := c.distance_to(m)
	if a < 0.001:
		return {}
	var dir := (m - c) / a
	var b: float = absf(((taps[2]["uv"] as Vector2) - c).cross(dir))
	return {"centre": centre_id, "major": major_id, "a": a, "b": clampf(b, a * 0.02, a), "c": c, "m": m, "dir": dir}


func _make_ellipse(taps: Array) -> Dictionary:
	var created: Array = []
	var f := await _ellipse_frame(taps, created)
	if f.is_empty():
		await _cleanup(created)
		return {"ok": false, "message": "Pick the centre, the end of the long axis, then a point for the short radius."}
	var r := await _post(SKETCH + sketch_id + "/ellipses", {"center_point_id": f["centre"], "major_point_id": f["major"], "minor_radius": f["b"]})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make that ellipse: %s" % str(r["error"])}
	return await _finish("ellipse", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/ellipses/" + str(r["json"]["id"])]])


func _make_ellipse_arc(taps: Array) -> Dictionary:
	var created: Array = []
	var f := await _ellipse_frame(taps, created)
	if f.is_empty():
		await _cleanup(created)
		return {"ok": false, "message": "Pick the centre, the end of the long axis, a point for the short radius, then the start and the end."}
	var c: Vector2 = f["c"]
	var dir: Vector2 = f["dir"]
	var minor_dir := Vector2(-dir.y, dir.x)
	var minor_pt: Vector2 = c + minor_dir * float(f["b"])
	var t0 := ellipse_param(c, f["m"], minor_pt, taps[3]["uv"])
	var t1 := ellipse_param(c, f["m"], minor_pt, taps[4]["uv"])
	var r := await _post(SKETCH + sketch_id + "/ellipse-arcs", {"center_point_id": f["centre"], "major_point_id": f["major"], "minor_radius": f["b"], "start_angle": fposmod(t0, TAU), "end_angle": fposmod(t1, TAU)})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make that partial ellipse: %s" % str(r["error"])}
	return await _finish("ellipse arc", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/ellipse-arcs/" + str(r["json"]["id"])]])


func finish_spline() -> Dictionary:
	## Makes the spline through the points tapped so far (two or more, in order). {ok, message}.
	if busy or tool != "spline":
		return {"ok": false, "message": ""}
	if pending.size() < 2:
		var message := "A spline needs at least two points."
		status.emit(message)
		return {"ok": false, "message": message}
	busy = true
	var taps := pending.duplicate()
	pending.clear()
	var created: Array = []
	var ids: Array = []
	for t in taps:
		var id := await _point(t, created)
		if id == "":
			await _cleanup(created)
			busy = false
			return {"ok": false, "message": "Couldn't place those points."}
		ids.append(id)
	var r := await _post(SKETCH + sketch_id + "/splines", {"through_point_ids": ids})
	var result: Dictionary
	if not r["ok"]:
		await _cleanup(created)
		result = {"ok": false, "message": "Couldn't make that spline: %s" % str(r["error"])}
		status.emit(str(result["message"]))
	else:
		result = await _finish("spline", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/splines/" + str(r["json"]["id"])]])
	busy = false
	return result


func _make_text(taps: Array) -> Dictionary:
	if text_content.strip_edges() == "":
		return {"ok": false, "message": "Type the text first (the Text button), then place it."}
	var created: Array = []
	var anchor := await _point(taps[0], created)
	if anchor == "":
		return {"ok": false, "message": "Couldn't place the text there."}
	var r := await _post(SKETCH + sketch_id + "/texts", {"content": text_content, "anchor_point_id": anchor, "font": text_font, "size": text_size, "rotation_degrees": text_rotation})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make that text: %s" % str(r["error"])}
	return await _finish("text", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/texts/" + str(r["json"]["id"])]])


func _fetch_text_outlines() -> void:
	## The glyph outlines of every text, from the backend (it owns the fonts), once per content / font / size / rotation / place.
	for id in texts:
		var t: Dictionary = texts[id]
		var key := "%s|%s|%s|%s|%s" % [t["content"], t["font"], t["size"], t["rot"], str(points.get(t["anchor"], Vector2.ZERO))]
		if _text_keys.get(id, "") == key and text_outlines.has(id):
			continue
		var r: Dictionary = await api.call(HTTPClient.METHOD_GET, SKETCH + sketch_id + "/texts/" + id + "/preview", null)
		if not r["ok"] or not (r["json"] is Dictionary):
			continue
		var polys: Array = []
		for contour in (r["json"] as Dictionary).get("contours", []):
			polys.append((contour["outer"] as Array).map(func(p): return Vector2(float(p[0]), float(p[1]))))
			for hole in contour.get("holes", []):
				polys.append((hole as Array).map(func(p): return Vector2(float(p[0]), float(p[1]))))
		text_outlines[id] = polys
		_text_keys[id] = key
	for id in text_outlines.keys():
		if not texts.has(id):
			text_outlines.erase(id)
			_text_keys.erase(id)


func _post(path: String, body) -> Dictionary:
	return await api.call(HTTPClient.METHOD_POST, path, body)


func _point(pick: Dictionary, created: Array, hold_on_curve: bool = true) -> String:
	## The id of a pick's point: the existing one it snapped to, the pinned reference point of a part vertex it snapped to (made now, if it is
	## the first time), else a new one at its position. Three snaps make a point that is HELD by a constraint, as the flat app does:
	##  - the sketch's ORIGIN: a new point exactly on it and a coincident constraint (a shape is never welded to the origin point itself, so it can be
	##    freed from it later);
	##  - the middle of a line of the sketch: a point and an at-midpoint constraint (a point already held at that middle is reused);
	##  - a spot on a line, circle or arc of the sketch: a point and a point-on-line / point-on-circle constraint (unless `hold_on_curve` is false:
	##    the second end of a line gets it from the line's own inference).
	## The constraints go in `_pending_holds`, which _finish puts at the front of the undo.
	if str(pick.get("id", "")) != "":
		if is_origin(str(pick["id"])):
			return await _point_at_origin(str(pick["id"]), created)
		return str(pick["id"])
	if pick.get("ref") is Dictionary:
		if str((pick["ref"] as Dictionary).get("kind", "")) in ["edge_midpoint", "edge_point"]:
			return await _point_on_reference(pick, created)
		var made := await ensure_reference(pick["ref"])
		return str(made["id"]) if made["ok"] else ""
	var target: Variant = pick.get("target")
	if target is Dictionary and not (target as Dictionary).is_empty() and (hold_on_curve or str(pick.get("snap", "")) == "midpoint"):
		return await _point_on_sketch_shape(pick, target, created)
	var uv: Vector2 = pick["uv"]
	var r := await _post(SKETCH + sketch_id + "/points", {"x": uv.x, "y": uv.y})
	if not r["ok"]:
		return ""
	created.append(str(r["json"]["id"]))
	return str(r["json"]["id"])


func _pick_position(pick: Dictionary) -> Vector2:
	## Where a pick lands: the point it snapped to, else the spot tapped.
	var id := str(pick.get("id", ""))
	if id != "" and points.has(id):
		return points[id]
	return pick.get("uv", Vector2.ZERO)


func _hold(constraint: Dictionary) -> bool:
	## Makes one holding constraint for the shape being made. False if the backend refused it.
	var c := await _post(SKETCH + sketch_id + "/constraints", constraint)
	if c["ok"]:
		_pending_holds.append(str(c["json"]["id"]))
	return bool(c["ok"])


func _point_at_origin(origin: String, created: Array) -> String:
	var at: Vector2 = points.get(origin, Vector2.ZERO)
	var r := await _post(SKETCH + sketch_id + "/points", {"x": at.x, "y": at.y})
	if not r["ok"]:
		return ""
	var id := str(r["json"]["id"])
	created.append(id)
	if not await _hold({"type": "coincident", "point_a_id": id, "point_b_id": origin}):
		return "" # the caller's cleanup takes the point back out
	return id


func _point_on_sketch_shape(pick: Dictionary, target: Dictionary, created: Array) -> String:
	var kind := str(target.get("kind", ""))
	var target_id := str(target.get("id", ""))
	var at_middle := str(pick.get("snap", "")) == "midpoint"
	if at_middle:
		for cid in constraints:
			var c: Dictionary = constraints[cid]
			if str(c.get("type", "")) == "at_midpoint" and str(c.get("line_id", "")) == target_id and points.has(str(c.get("point_id", ""))):
				return str(c["point_id"]) # the middle of that line already has its point
	var uv: Vector2 = pick["uv"]
	var r := await _post(SKETCH + sketch_id + "/points", {"x": uv.x, "y": uv.y})
	if not r["ok"]:
		return ""
	var id := str(r["json"]["id"])
	created.append(id)
	var body: Dictionary
	if at_middle:
		body = {"type": "at_midpoint", "point_id": id, "line_id": target_id}
	elif kind == "line":
		body = {"type": "point_on_line", "point_id": id, "line_id": target_id}
	else:
		body = {"type": "point_on_circle", "point_id": id, "circle_or_arc_id": target_id}
	if not await _hold(body):
		status.emit("Couldn't hold that point on the %s, so it is just placed there." % ("middle of the line" if at_middle else kind))
	return id


func _drop_holds() -> void:
	## Takes back the constraints made for a shape that did not get made.
	for cid in _pending_holds:
		await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(cid), null)
	_pending_holds.clear()


func _cleanup(created: Array) -> void:
	await _drop_holds() # a point a constraint still names cannot be deleted
	for id in created:
		await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/points/" + str(id), null)


func _finish(label: String, calls: Array, with_entities: bool = true) -> Dictionary:
	var held: Array = _pending_holds.map(func(cid): return [HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(cid)])
	_pending_holds.clear()
	_undo.append({"label": label, "calls": held + calls})
	await refresh(with_entities)
	return {"ok": true, "message": ""}


static func infer_of(pick: Dictionary) -> Dictionary:
	## The relationship a pick was inferred to have: {kind, target?} or {}. (A bare "horizontal" / "vertical" string, the older shape, still reads.)
	var infer: Variant = pick.get("infer", {})
	if infer is String:
		return {"kind": infer} if infer != "" else {}
	return infer if infer is Dictionary else {}


static func inferred_body(infer: Dictionary, line_id: String, end_id: String) -> Dictionary:
	## The request body of the constraint a line's inferred relationship makes (the new line `line_id`, ending on `end_id`), or {} for none.
	var kind := str(infer.get("kind", ""))
	var target: Dictionary = infer.get("target", {})
	var target_id := str(target.get("id", ""))
	match kind:
		"horizontal", "vertical":
			return {"type": kind, "line_id": line_id}
		"parallel", "perpendicular", "collinear":
			return {"type": kind, "line1_id": line_id, "line2_id": target_id} if target_id != "" else {}
		"tangent":
			return {"type": "tangent", "circle_or_arc_id": target_id, "line_id": line_id} if target_id != "" else {}
		"on_curve":
			if target_id == "":
				return {}
			if str(target.get("kind", "")) == "line":
				return {"type": "point_on_line", "point_id": end_id, "line_id": target_id}
			return {"type": "point_on_circle", "point_id": end_id, "circle_or_arc_id": target_id}
	return {}


static func concentric_body(infer: Dictionary, entity_id: String) -> Dictionary:
	## A new circle or arc whose centre was put on another's: held concentric with it.
	if str(infer.get("kind", "")) != "concentric" or str((infer.get("target", {}) as Dictionary).get("id", "")) == "":
		return {}
	return {"type": "concentric", "entity1_id": str(infer["target"]["id"]), "entity2_id": entity_id}


func _taken_back(was_converged: bool, made_ids: Array) -> bool:
	## 3.3 (as built in S1, accepted): is what was just made, after its solve, to be taken back? A sketch that converged before and no longer does: yes. A sketch that was
	## ALREADY not converged (a conflict kept earlier) keeps the new constraint unless the solve's failed list names it (else one kept conflict would block every
	## new constraint). Read after `refresh`, which fills `converged` and `failed_constraint_ids`.
	if converged:
		return false
	if was_converged:
		return true
	for id in made_ids:
		if failed_constraint_ids.has(str(id)):
			return true
	return false


func _finish_inferred(label: String, calls: Array, body: Dictionary, infer: Dictionary) -> Dictionary:
	## `_finish`, with the one constraint the shape was inferred to have. If the solver will not take it with the rest of the sketch only IT is taken back
	## out: the shape stays (a conflicting guess must not cost the line), and the status line says so.
	if body.is_empty():
		return await _finish(label, calls)
	var was_converged := converged
	var made := await _post(SKETCH + sketch_id + "/constraints", body)
	var undo_call: Array = []
	if made["ok"]:
		undo_call = [HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(made["json"]["id"])]
		calls.push_front(undo_call)
	var done := await _finish(label, calls)
	var what := str(infer.get("kind", "")).replace("_", " ")
	if not made["ok"]:
		status.emit("Couldn't keep it %s: %s" % [what, str(made["error"])])
	elif _taken_back(was_converged, [str(made["json"]["id"])]):
		await api.call(int(undo_call[0]), str(undo_call[1]), null)
		(_undo.back()["calls"] as Array).erase(undo_call)
		await refresh(false)
		status.emit("Couldn't keep it %s: it conflicted." % what)
	return done


func _make_point(taps: Array) -> Dictionary:
	var created: Array = []
	var id := await _point(taps[0], created)
	if id == "":
		return {"ok": false, "message": "Couldn't place the point."}
	return await _finish("point", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/points/" + id]], false)


func _make_line(taps: Array) -> Dictionary:
	if line_method == "middle":
		return await _make_line_from_middle(taps)
	var created: Array = []
	if _pick_position(taps[0]).distance_to(_pick_position(taps[1])) < 0.000001:
		return {"ok": false, "message": "A line needs two different points."}
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
	var infer := infer_of(taps[1])
	if chain_first == "":
		chain_first = a # the first line of a run: the run closes where it started
	var closed := b == chain_first
	if closed:
		pending.clear()
		chain_first = ""
	else:
		pending = [{"uv": taps[1]["uv"], "id": b}] # the end is the next line's start
	var done := await _finish_inferred("line", calls, inferred_body(infer, line_id, b), infer)
	if closed:
		status.emit("Closed.")
	return done


func _make_line_from_middle(taps: Array) -> Dictionary:
	## The first tap is the line's middle, the second one end; the other end is the reflection. A point at the middle is held there (at-midpoint) so it stays in the middle.
	var created: Array = []
	var centre_uv: Vector2 = taps[0]["uv"]
	var end_uv: Vector2 = taps[1]["uv"]
	if centre_uv.distance_to(end_uv) < 0.01:
		return {"ok": false, "message": "Pick an end away from the middle."}
	var mid := await _point(taps[0], created)
	var b := await _point(taps[1], created)
	var a := await _point({"uv": SketchMath.mirrored_end(centre_uv, end_uv)}, created)
	if mid == "" or a == "" or b == "" or a == b or mid == b:
		await _cleanup(created)
		return {"ok": false, "message": "A line needs two different ends and a middle between them."}
	var r := await _post(SKETCH + sketch_id + "/lines", {"start_point_id": a, "end_point_id": b})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the line: %s" % str(r["error"])}
	var line_id := str(r["json"]["id"])
	var calls: Array = [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/lines/" + line_id]]
	var c := await _post(SKETCH + sketch_id + "/constraints", {"type": "at_midpoint", "point_id": mid, "line_id": line_id})
	if c["ok"]:
		calls.push_front([HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(c["json"]["id"])])
	var infer := infer_of(taps[1]) # the free end is decided the same way as a line's second end
	return await _finish_inferred("line", calls, inferred_body(infer, line_id, b), infer)


func _make_rectangle(taps: Array) -> Dictionary:
	if rect_method != "corners":
		return await _make_rectangle_by(taps)
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


func _make_rectangle_by(taps: Array) -> Dictionary:
	## Centre and a corner (axis-aligned), or one side and the width (turned). The corners are computed (sketch_math.gd); a tap that snapped to an existing point keeps that point
	## as its corner (the second tap of Centre, the first two of Three).
	var created: Array = []
	var centre_method := rect_method == "centre"
	var uvs: Array = []
	if centre_method:
		uvs = SketchMath.rect_from_centre(taps[0]["uv"], taps[1]["uv"])
	else:
		uvs = SketchMath.rect_from_three(taps[0]["uv"], taps[1]["uv"], taps[2]["uv"])
	if uvs.is_empty():
		return {"ok": false, "message": "Pick the centre and a corner that isn't in line with it." if centre_method else "Pick the two ends of one side, then a point off that side for the width."}
	var ids: Array = []
	for i in 4:
		var pick := {"uv": uvs[i]}
		if centre_method and i == 2 and str(taps[1].get("id", "")) != "":
			pick["id"] = taps[1]["id"]
		elif not centre_method and i < 2 and str(taps[i].get("id", "")) != "":
			pick["id"] = taps[i]["id"]
		var id := await _point(pick, created)
		if id == "":
			await _cleanup(created)
			return {"ok": false, "message": "Couldn't place the corners."}
		ids.append(id)
	var r := await _post(SKETCH + sketch_id + "/rectangles", {"corner_point_ids": ids, "axis_aligned": centre_method})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the rectangle: %s" % str(r["error"])}
	return await _finish("rectangle", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/rectangles/" + str(r["json"]["id"])]])


func _make_circle_through(taps: Array) -> Dictionary:
	## Three points on the circle: its centre and radius are computed, the first point is the radius point, and the other two are held on the circle (point-on-circle).
	var created: Array = []
	var fit := SketchMath.circumcircle(taps[0]["uv"], taps[1]["uv"], taps[2]["uv"])
	if not bool(fit["ok"]):
		return {"ok": false, "message": "Those three points are in a line. Pick three that aren't."}
	var rim := await _point(taps[0], created)
	var second := await _point(taps[1], created)
	var third := await _point(taps[2], created)
	var c := await _point({"uv": fit["centre"]}, created)
	if rim == "" or second == "" or third == "" or c == "" or rim == c:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't place the points."}
	var r := await _post(SKETCH + sketch_id + "/circles", {"center_point_id": c, "radius_point_id": rim})
	if not r["ok"]:
		await _cleanup(created)
		return {"ok": false, "message": "Couldn't make the circle: %s" % str(r["error"])}
	var circle_id := str(r["json"]["id"])
	var calls: Array = [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/circles/" + circle_id]]
	for pid in [second, third]:
		if pid == rim:
			continue
		var k := await _post(SKETCH + sketch_id + "/constraints", {"type": "point_on_circle", "point_id": pid, "circle_or_arc_id": circle_id})
		if not k["ok"]:
			for entry in calls:
				await api.call(int(entry[0]), str(entry[1]), null)
			await _cleanup(created)
			return {"ok": false, "message": "Couldn't hold the points on the circle: %s" % str(k["error"])}
		calls.push_front([HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(k["json"]["id"])])
	return await _finish("circle", calls)


func _make_circle(taps: Array) -> Dictionary:
	if circle_method == "three":
		return await _make_circle_through(taps)
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
	var concentric := infer_of(taps[0])
	return await _finish_inferred("circle", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/circles/" + str(r["json"]["id"])]], concentric_body(concentric, str(r["json"]["id"])), concentric)


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
	var concentric := infer_of(taps[0])
	return await _finish_inferred("arc", [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/arcs/" + str(r["json"]["id"])]], concentric_body(concentric, str(r["json"]["id"])), concentric)


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
	## Makes a part vertex, edge, hole or face usable in this sketch and returns {ok, id, message}: a vertex becomes a pinned point that follows the
	## part (the backend re-resolves it whenever the part changes, and flags the sketch if it can't), an edge a pinned construction line between two such
	## points, a hole's rim a pinned circle with a live centre, a face (standing square to the sketch, or round with its axis square to it) a pinned
	## line or a live centre. Everything made is flagged as a reference helper by the backend (`reference: true`), so it is drawn quietly, never offered for
	## selection or deletion, and cleaned up when nothing depends on it. Every route is idempotent: asking again gives the same thing. Nothing for the
	## user to convert, fix or mark as construction, and a failure leaves nothing half made (one call each).
	if not references_ok:
		return {"ok": false, "id": "", "message": "This sketch can't use the part's own geometry (the part shown isn't the one the backend sketches on)."}
	match str(ref.get("kind", "")):
		"vertex":
			return await _ensure_vertex(str(ref["body"]), int(ref["index"]))
		"edge":
			return await _ensure_edge_line(ref)
		"face_line":
			return await _ensure_face(str(ref["body"]), int(ref["index"]))
		"face_axis":
			return await _ensure_face(str(ref["body"]), int(ref["index"]))
		"circle_centre":
			var on_circle := await _ensure_circle(str(ref["body"]), int(ref["index"]))
			if not on_circle["ok"]:
				return on_circle
			return {"ok": true, "id": on_circle["centre"], "message": ""}
		"circle_edge":
			return await _ensure_circle(str(ref["body"]), int(ref["index"]))
		"ellipse_edge":
			return await _ensure_ellipse(str(ref["body"]), int(ref["index"]))
	return {"ok": false, "id": "", "message": ""}


func _ensure_ellipse(body: String, edge_index: int) -> Dictionary:
	## A full elliptical edge of the part lying in the sketch plane as a pinned reference ellipse (convert-entities/edge, idempotent). Its centre is a plain
	## pinned point (the backend has no live reference for an ellipse's centre yet: it does not follow an upstream change, see docs/design-table-gaps.md).
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/edge" % [owner_part_id, feature_id], {"body_id": body, "edge_index": edge_index, "construction": true, "reference": true})
	if not made["ok"]:
		return {"ok": false, "id": "", "message": "Couldn't use that edge: %s" % str(made["error"])}
	var json: Dictionary = made["json"]
	if not (json.get("ellipse") is Dictionary):
		await refresh(true)
		return {"ok": false, "id": "", "message": "That edge isn't an ellipse in this sketch's plane."}
	await refresh(true) # the ellipse's five points and its axis lines come in with one read
	return {"ok": true, "id": str(json["ellipse"]["id"]), "message": ""}


func _take_in_point(json: Dictionary) -> void:
	## A point the backend just answered with (a convert route's response): into the local picture at once, pinned and flagged as a helper.
	var id := str(json["id"])
	points[id] = Vector2(float(json["x"]), float(json["y"]))
	point_locked[id] = true
	if bool(json.get("is_reference", false)):
		reference_ids[id] = true


func _ensure_edge_line(ref: Dictionary) -> Dictionary:
	## A straight edge of the part as a pinned construction line (convert-entities/edge: two live corner references and the line between them, reused if it
	## is there). A line already in the picture between the pinned points of its two corners is the answer without asking. Not a line after all (the edge is
	## round in this plane) is refused: the call is one, so nothing is left half made.
	var body := str(ref["body"])
	var key_a := "%s:%d" % [body, int(ref.get("a_vertex", -1))]
	var key_b := "%s:%d" % [body, int(ref.get("b_vertex", -1))]
	if _ref_points.has(key_a) and _ref_points.has(key_b):
		for id in lines:
			var l: Dictionary = lines[id]
			if (l["a"] == _ref_points[key_a] and l["b"] == _ref_points[key_b]) or (l["a"] == _ref_points[key_b] and l["b"] == _ref_points[key_a]):
				return {"ok": true, "id": id, "message": ""}
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/edge" % [owner_part_id, feature_id], {"body_id": body, "edge_index": int(ref["index"]), "construction": true, "reference": true})
	if not made["ok"]:
		return {"ok": false, "id": "", "message": "Couldn't use that edge: %s" % str(made["error"])}
	var json: Dictionary = made["json"]
	if not (json.get("line") is Dictionary):
		await refresh(true) # a round edge came back as a circle or arc: not what was asked for, and the backend made it, so read it in (it is a flagged helper, quiet, and goes with its last user)
		return {"ok": false, "id": "", "message": "That edge isn't straight in this sketch's plane."}
	_take_in_point(json["start_point"])
	_take_in_point(json["end_point"])
	for end in [json["start_point"], json["end_point"]]:
		var at := Vector2(float(end["x"]), float(end["y"]))
		if ref.has("a") and at.distance_to(ref["a"]) < 0.01:
			_ref_points[key_a] = str(end["id"])
		elif ref.has("b") and at.distance_to(ref["b"]) < 0.01:
			_ref_points[key_b] = str(end["id"])
	var line: Dictionary = json["line"]
	var id := str(line["id"])
	lines[id] = {"a": str(line["start_point_id"]), "b": str(line["end_point_id"]), "construction": true}
	if bool(line.get("is_reference", false)):
		reference_ids[id] = true
	changed.emit()
	return {"ok": true, "id": id, "message": ""}


func _ensure_face(body: String, face_index: int) -> Dictionary:
	## A face of the part as something to point at: a flat face standing square to the sketch becomes a pinned line, a round face with its axis square to it
	## a live centre (convert-entities/face). {ok, id (the line, or the centre point), kind ("line" | "centre"), centre?, message}.
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/face" % [owner_part_id, feature_id], {"body_id": body, "face_index": face_index, "construction": true, "reference": true})
	if not made["ok"]:
		return {"ok": false, "id": "", "message": "Couldn't use that face: %s" % _face_reason(str(made["error"]))}
	var json: Dictionary = made["json"]
	if str(json.get("kind", "")) == "centre":
		_take_in_point(json["center_point"])
		changed.emit()
		return {"ok": true, "id": str(json["center_point"]["id"]), "kind": "point", "message": ""}
	_take_in_point(json["start_point"])
	_take_in_point(json["end_point"])
	var line: Dictionary = json["line"]
	var id := str(line["id"])
	lines[id] = {"a": str(line["start_point_id"]), "b": str(line["end_point_id"]), "construction": true}
	if bool(line.get("is_reference", false)):
		reference_ids[id] = true
	changed.emit()
	return {"ok": true, "id": id, "kind": "line", "message": ""}


static func _face_reason(error: String) -> String:
	for known in {"face_not_perpendicular": "it isn't square to the sketch plane.", "face_axis_not_perpendicular": "its axis isn't square to the sketch plane.", "unsupported_face": "that kind of face can't be used.", "face_has_no_circular_edge": "it has no round edge to find its axis from.", "degenerate_face": "it has no width seen from here."}.keys():
		if error.contains(known):
			return {"face_not_perpendicular": "it isn't square to the sketch plane.", "face_axis_not_perpendicular": "its axis isn't square to the sketch plane.", "unsupported_face": "that kind of face can't be used.", "face_has_no_circular_edge": "it has no round edge to find its axis from.", "degenerate_face": "it has no width seen from here."}[known]
	return error


func _ensure_circle(body: String, edge_index: int) -> Dictionary:
	## A circular edge of the part in the sketch plane (a hole's or boss's rim, or an arc of one) as a pinned construction circle / arc in the sketch, and its
	## centre as a pinned point: convert-entities/edge does both (the centre is a live reference of kind "circle_centre", so it follows the hole when the part
	## changes and is flagged when the hole is gone). The route is idempotent per edge (a second call answers with the circle already there), so asking again
	## is the way to find it; it is only read back when the circle is not yet in this session's picture. {ok, id (the circle / arc), kind, centre (its centre point), message}.
	var key := "%s:c%d" % [body, edge_index]
	if _ref_points.has(key) and points.has(_ref_points[key]):
		for cid in circles: # already here: the shape on that pinned centre (nothing remembered about it, it is read off the picture)
			if circles[cid]["c"] == _ref_points[key]:
				return {"ok": true, "id": cid, "kind": "circle", "centre": _ref_points[key], "message": ""}
		for aid in arcs:
			if arcs[aid]["c"] == _ref_points[key]:
				return {"ok": true, "id": aid, "kind": "arc", "centre": _ref_points[key], "message": ""}
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/edge" % [owner_part_id, feature_id], {"body_id": body, "edge_index": edge_index, "construction": true, "reference": true})
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
	var was_converged := converged
	var held := await _post(SKETCH + sketch_id + "/constraints", constraint)
	if not held["ok"]:
		status.emit("Couldn't hold that point on the part's edge: %s" % str(held["error"]))
		return "" # the caller's cleanup takes the point back out
	await refresh(false)
	if _taken_back(was_converged, [str(held["json"]["id"])]):
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
	var made := await _post("/document/parts/%s/features/sketch/%s/convert-entities/vertex" % [owner_part_id, feature_id], {"body_id": body, "vertex_index": index, "reference": true})
	if not made["ok"]:
		return {"ok": false, "id": "", "message": "Couldn't use that corner of the part: %s" % str(made["error"])}
	var id := str(made["json"]["id"])
	_take_in_point(made["json"])
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


func nearest_entity(uv: Vector2, radius: float, kinds: Array = ["point", "line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]) -> Dictionary:
	## The nearest thing to a sheet position: {kind, id, distance} or {}. A point beats a line it's on.
	var best := {}
	var best_d := radius
	if "point" in kinds:
		for id in points:
			if reference_ids.has(id):
				continue # the sketch's plumbing to the part: picked through the part's own corner / edge / hole (part_references.gd), never as itself
			var d := uv.distance_to(points[id])
			if d <= best_d:
				best_d = d
				best = {"kind": "point", "id": id, "distance": d}
	var point_hit := not best.is_empty()
	if "line" in kinds and not point_hit:
		for id in lines:
			var l: Dictionary = lines[id]
			if reference_ids.has(id) or not points.has(l["a"]) or not points.has(l["b"]):
				continue
			var d := uv.distance_to(Geometry2D.get_closest_point_to_segment(uv, points[l["a"]], points[l["b"]]))
			if d <= best_d:
				best_d = d
				best = {"kind": "line", "id": id, "distance": d}
	if "circle" in kinds and not point_hit:
		for id in circles:
			var c: Dictionary = circles[id]
			if reference_ids.has(id) or not points.has(c["c"]) or not points.has(c["p"]):
				continue
			var d := absf(uv.distance_to(points[c["c"]]) - points[c["c"]].distance_to(points[c["p"]]))
			if d <= best_d:
				best_d = d
				best = {"kind": "circle", "id": id, "distance": d}
	if "arc" in kinds and not point_hit:
		for id in arcs:
			var a: Dictionary = arcs[id]
			if reference_ids.has(id) or not points.has(a["c"]) or not points.has(a["s"]) or not points.has(a["e"]):
				continue
			var d := _distance_to_arc(uv, points[a["c"]], points[a["s"]], points[a["e"]])
			if d <= best_d:
				best_d = d
				best = {"kind": "arc", "id": id, "distance": d}
	for kind in CURVE_KINDS:
		if kind in kinds and not point_hit:
			var source: Dictionary = {"ellipse": ellipses, "ellipse_arc": ellipse_arcs, "spline": splines}[kind]
			for id in source:
				if reference_ids.has(id):
					continue # the part's own elliptical edge: picked through the part (part_references.gd), never as itself
				var outline: Array = outline_of(kind, id)
				for i in outline.size() - 1:
					var d := uv.distance_to(Geometry2D.get_closest_point_to_segment(uv, outline[i], outline[i + 1]))
					if d <= best_d:
						best_d = d
						best = {"kind": kind, "id": id, "distance": d}
	if "text" in kinds and not point_hit:
		for id in texts:
			var t: Dictionary = texts[id]
			var d := INF
			for poly in text_outlines.get(id, []):
				for i in (poly as Array).size():
					d = minf(d, uv.distance_to(Geometry2D.get_closest_point_to_segment(uv, poly[i], poly[(i + 1) % poly.size()])))
			if d == INF and points.has(t["anchor"]):
				d = uv.distance_to(points[t["anchor"]])
			if d <= best_d:
				best_d = d
				best = {"kind": "text", "id": id, "distance": d}
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
	var was_converged := converged
	var r := await _post(SKETCH + sketch_id + "/constraints", body)
	if not r["ok"]:
		return {"ok": false, "message": "Couldn't add that constraint: %s" % str(r["error"])}
	var calls: Array = [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(r["json"]["id"])]]
	await _finish(tool_id, calls, false)
	if _taken_back(was_converged, [str(r["json"]["id"])]):
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
	ghosts = _build_ghosts() if selection.size() <= 3 else []
	changed.emit()


func menu() -> Array:
	## The contextual menu for the current selection (sketch_selection.gd).
	prune_annotations()
	if not annotations.is_empty():
		return SketchSelection.annotation_options(annotations, selection, self)
	return SketchSelection.options(selection, self, ghosts)


# --- Merge: two or more points become one ----------------------------------------------------------------------------------

func merge_ids() -> Array:
	## The selected points, in the order they were picked.
	return _ids_of("point")


func _quadrant_ids() -> Dictionary:
	## A circle's four quadrant points and an ellipse's four axis ends: they belong to their shape, and v1 refuses to merge them (Coincident ties them).
	var out := {}
	for id in circles:
		for pid in circles[id].get("cards", []):
			out[str(pid)] = true
	for id in ellipses:
		for key in ["ma", "mi", "man", "mnn"]:
			if str(ellipses[id].get(key, "")) != "":
				out[str(ellipses[id][key])] = true
	return out


func _entity_point_sets() -> Array:
	## Each entity's own points, as a list of Dictionaries used as sets (id -> true): the mirror of the backend's _entity_defining_point_ids.
	var out: Array = []
	for id in lines:
		out.append(_set_of([lines[id]["a"], lines[id]["b"]]))
	for id in circles:
		out.append(_set_of([circles[id]["c"], circles[id]["p"]] + circles[id].get("cards", [])))
	for id in arcs:
		out.append(_set_of([arcs[id]["c"], arcs[id]["s"], arcs[id]["e"]]))
	for id in ellipses:
		out.append(_set_of([ellipses[id]["c"], ellipses[id]["ma"], ellipses[id]["mi"], ellipses[id].get("man", ""), ellipses[id].get("mnn", "")]))
	for id in ellipse_arcs:
		out.append(_set_of([ellipse_arcs[id]["c"], ellipse_arcs[id]["ma"], ellipse_arcs[id]["mi"], ellipse_arcs[id]["s"], ellipse_arcs[id]["e"]]))
	for id in shapes:
		out.append(_set_of(shapes[id].get("own_point_ids", [])))
	for id in splines:
		out.append(_set_of(splines[id].get("through", []) + splines[id].get("control", [])))
	for id in texts:
		out.append(_set_of([texts[id]["anchor"]]))
	return out


static func _set_of(ids: Array) -> Dictionary:
	var out := {}
	for pid in ids:
		if str(pid) != "":
			out[str(pid)] = true
	return out


func merge_offered(picked: Variant = null) -> bool:
	## Whether Merge suits these points (the selected ones by default): two or more, none the origin or a quadrant point, and no single entity using two of
	## them (merging would collapse it). The rest (a dimension between them, a part feature, a conflict) is the backend's to refuse, in words.
	var ids: Array = merge_ids() if picked == null else picked
	var distinct := {}
	for id in ids:
		distinct[str(id)] = true
	if distinct.size() < 2:
		return false
	var quadrant := _quadrant_ids()
	for id in distinct:
		if is_origin(id) or quadrant.has(id) or not points.has(id):
			return false
	for set in _entity_point_sets():
		var n := 0
		for id in distinct:
			if set.has(id):
				n += 1
		if n >= 2:
			return false
	return true


func _constraint_points(c: Dictionary) -> Dictionary:
	## Every point a backend constraint holds (a set): the point ids it names, and the ends of the lines it names (the backend's Constraint.point_ids).
	var out := {}
	for key in c:
		if key == "id" or key == "type":
			continue
		var value = c[key]
		var values: Array = value if value is Array else [value]
		for v in values:
			var text := str(v)
			if points.has(text):
				out[text] = true
			elif lines.has(text):
				out[str(lines[text]["a"])] = true
				out[str(lines[text]["b"])] = true
	return out


func merge_keep_order(picked: Variant = null) -> Array:
	## `ids` ordered by which stays when they are merged (the backend's rule, so the point that will stay can be ringed first): a pinned point, then the one
	## with the most constraints on it (not counting a provisional dimension or a Coincident between two of these points), then the one picked first. The
	## backend also knows which points a part feature uses; in that rare case its answer wins.
	var ids: Array = merge_ids() if picked == null else picked
	var distinct: Array = []
	for id in ids:
		if not distinct.has(str(id)):
			distinct.append(str(id))
	var chosen := _set_of(distinct)
	var counts := {}
	for id in distinct:
		counts[id] = 0
	for cid in constraints:
		var c: Dictionary = constraints[cid]
		if str(c.get("type", "")) == "distance" and bool(c.get("provisional", false)):
			continue
		if str(c.get("type", "")) == "coincident" and chosen.has(str(c.get("point_a_id", ""))) and chosen.has(str(c.get("point_b_id", ""))):
			continue
		for pid in _constraint_points(c):
			if counts.has(pid):
				counts[pid] += 1
	var order := distinct.duplicate()
	order.sort_custom(func(a, b) -> bool:
		var pinned_a := bool(point_locked.get(a, false))
		var pinned_b := bool(point_locked.get(b, false))
		if pinned_a != pinned_b:
			return pinned_a
		if counts[a] != counts[b]:
			return counts[a] > counts[b]
		return distinct.find(a) < distinct.find(b))
	return order


func merge_keep_id() -> String:
	## The point Merge would keep for the selection, or "" when Merge is not on offer.
	var ids := merge_ids()
	return str(merge_keep_order(ids)[0]) if merge_offered(ids) else ""


func describe_point(point_id: String) -> String:
	## What the point is, in a few words, for the status line: "the rectangle corner", "the line end", "a pinned point"...
	if bool(point_locked.get(point_id, false)):
		return "the pinned point"
	for id in shapes:
		if (shapes[id].get("own_point_ids", []) as Array).has(point_id):
			return "the %s corner" % shapes[id]["kind"] if shapes[id]["kind"] == "rectangle" else "the %s point" % shapes[id]["kind"]
	for id in circles:
		if circles[id]["c"] == point_id:
			return "the circle centre"
	for id in arcs:
		if arcs[id]["c"] == point_id:
			return "the arc centre"
	for id in lines:
		if lines[id]["a"] == point_id or lines[id]["b"] == point_id:
			return "the line end"
	return "the first point"


func stacked_alternative(entity: Dictionary, reach: float) -> Dictionary:
	## Pick cycling on a stack of points. Two points on top of each other (a profile that looks closed and is not) cannot be picked one by one: a pull only ever
	## finds the nearest. When the point pulled is already selected and another, unselected point lies within `reach` of it (a quarter of the pick radius), that one
	## is the pick instead; a second pull on a stacked pair adds the other point. Anywhere else a pull on a selected point deselects it, as before. {} when none.
	if str(entity.get("kind", "")) != "point" or not is_selected(entity) or not points.has(str(entity["id"])):
		return {}
	var here: Vector2 = points[str(entity["id"])]
	var best := {}
	var best_d := reach
	for id in points:
		if id == str(entity["id"]) or is_origin(id) or reference_ids.has(id) or is_selected({"kind": "point", "id": id}):
			continue
		var d: float = here.distance_to(points[id])
		if d <= best_d:
			best_d = d
			best = {"kind": "point", "id": id, "distance": d}
	return best


func points_stacked_at(point_id: String, reach: float) -> int:
	## How many points (this one included; not the origin, not reference helpers) lie within `reach` of this point.
	if not points.has(point_id):
		return 0
	var here: Vector2 = points[point_id]
	var n := 0
	for id in points:
		if is_origin(id) or reference_ids.has(id):
			continue
		if here.distance_to(points[id]) <= reach:
			n += 1
	return n


func merge_selected() -> Dictionary:
	## Merges the selected points into one (POST .../points/merge). The backend decides which stays and refuses what it can't, in words (a dimension holds the
	## two apart, a part feature uses one, they would collapse an entity...), shown as they come. Undo is a restore of the whole sketch from the `before` snapshot
	## the backend returns (PUT .../state), sent back as the exact text it came in.
	var ids := merge_ids()
	if busy or not merge_offered(ids):
		return {"ok": false, "message": ""}
	busy = true
	var r := await _post(SKETCH + sketch_id + "/points/merge", {"point_ids": ids})
	if not r["ok"]:
		busy = false
		var message := _refusal_text(r)
		status.emit(message)
		return {"ok": false, "message": message}
	_undo.append({"label": "merge", "calls": [[HTTPClient.METHOD_PUT, SKETCH + sketch_id + "/state", str(r["json"]["before"])]]})
	selection.clear()
	ghosts.clear()
	await refresh(true)
	busy = false
	return {"ok": true, "message": ""}


static func _refusal_text(r: Dictionary) -> String:
	## The words the backend gave for a refused Merge: cad_api's own error text prefers a structured detail's `type` ("merge_refused"), which says nothing.
	var json: Variant = r.get("json")
	if json is Dictionary and (json as Dictionary).get("detail") is Dictionary:
		var detail: Dictionary = json["detail"]
		if str(detail.get("message", "")) != "":
			return str(detail["message"])
	return "Couldn't merge those points: %s" % str(r.get("error", ""))


func apply_menu(option_id: String) -> Dictionary:
	## Does one menu option on the current selection. Returns {ok, message}.
	if busy:
		return {"ok": false, "message": ""}
	if not annotations.is_empty() and option_id in ["delete", "clear"]:
		if option_id == "clear":
			clear_selection()
			return {"ok": true, "message": ""}
		return await delete_annotations()
	if selection.is_empty():
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
		"unfix":
			return await unfix_selection()
	if option_id == "merge":
		return await merge_selected()
	var bodies := _bodies_for(option_id)
	if bodies.is_empty():
		return {"ok": false, "message": "That doesn't fit what is selected."}
	return await _constrain_selection(option_id, bodies)


func _constrain_selection(label: String, bodies: Array) -> Dictionary:
	busy = true
	var calls: Array = []
	var was_converged := converged
	var made_ids: Array = []
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
		made_ids.append(str(r["json"]["id"]))
	selection.clear()
	ghosts.clear()
	await _finish(label, calls, false)
	busy = false
	if _taken_back(was_converged, made_ids):
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
		"point_on_ellipse":
			if points_sel.size() == 1 and _ids_of("ellipse").size() == 1:
				return [{"type": "point_on_ellipse", "point_id": points_sel[0], "ellipse_id": _ids_of("ellipse")[0]}]
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


const ENTITY_ROUTES := {"line": "lines", "circle": "circles", "arc": "arcs", "ellipse": "ellipses", "ellipse_arc": "ellipse-arcs", "spline": "splines", "text": "texts"}
const SHAPE_ROUTES := {"rectangle": "rectangles", "polygon": "polygons", "slot": "slots"}


func _entity_dict(kind: String) -> Dictionary:
	match kind:
		"line":
			return lines
		"circle":
			return circles
		"arc":
			return arcs
		"ellipse":
			return ellipses
		"ellipse_arc":
			return ellipse_arcs
		"spline":
			return splines
		"text":
			return texts
	return {}


func _entity_point_ids(kind: String, entity: Dictionary) -> Array:
	## The points an entity is made of.
	match kind:
		"line":
			return [entity.get("a", ""), entity.get("b", "")]
		"circle":
			return [entity.get("c", ""), entity.get("p", "")]
		"arc":
			return [entity.get("c", ""), entity.get("s", ""), entity.get("e", "")]
		"ellipse":
			return [entity.get("c", ""), entity.get("ma", ""), entity.get("mi", "")]
		"ellipse_arc":
			return [entity.get("c", ""), entity.get("ma", ""), entity.get("mi", ""), entity.get("s", ""), entity.get("e", "")]
		"spline":
			return (entity.get("through", []) as Array) + (entity.get("control", []) as Array)
		"text":
			return [entity.get("anchor", "")]
	return []


func delete_cascade(picked: Array = selection) -> Dictionary:
	## Everything deleting `picked` has to take with it, the way the flat app works it out (sketch_controller.dart computeDeleteCascade): a
	## deleted POINT takes every line, circle, arc, ellipse, spline and text built on it; every constraint that names a deleted point or
	## entity goes too (the backend refuses to leave one dangling, and refuses to delete a point a constraint still holds); a rectangle, polygon
	## or slot that loses only some of its pieces is COLLAPSED (it stays as plain lines and constraints) and one that loses all of them is deleted
	## whole. Returns {entities: {kind: [ids]}, points: [ids], constraints: [ids], collapse: [{kind, id}], remove_shapes: [{kind, id}], extra: String}
	## where `extra` says what came with the selection ("" when nothing did).
	var doomed := {} # id -> true: every point and entity going
	var picked_ids := {}
	var points_out := {}
	var entities := {}
	for kind in ENTITY_ROUTES:
		entities[kind] = {}
	for e in picked:
		var kind := str(e.get("kind", ""))
		var id := str(e.get("id", ""))
		picked_ids[id] = true
		if kind == "point":
			if not is_origin(id) and points.has(id):
				points_out[id] = true
				doomed[id] = true
		elif entities.has(kind) and _entity_dict(kind).has(id):
			entities[kind][id] = true
			doomed[id] = true
	for kind in entities:
		var source := _entity_dict(kind)
		for id in source:
			if entities[kind].has(id) or reference_ids.has(id):
				continue
			for pid in _entity_point_ids(kind, source[id]):
				if points_out.has(str(pid)):
					entities[kind][id] = true
					doomed[id] = true
					break
	var touched := points_out.duplicate() # every point that is going or loses something that held it
	for kind in entities:
		for id in entities[kind]:
			for pid in _entity_point_ids(kind, _entity_dict(kind)[id]):
				touched[str(pid)] = true
	var collapse: Array = []
	var remove_shapes: Array = []
	for sid in shapes:
		var own: Array = shapes[sid].get("own_point_ids", shapes[sid].get("point_ids", []))
		var hit := 0
		for pid in own:
			if touched.has(str(pid)):
				hit += 1
		if hit == 0:
			continue
		var entry := {"kind": str(shapes[sid]["kind"]), "id": str(sid)}
		if hit == own.size():
			remove_shapes.append(entry)
		else:
			collapse.append(entry)
	var own_radius := {} # a circle's / arc's / ellipse's own size constraint: the backend removes it with the entity
	for kind in ["circle", "arc"]:
		for id in entities[kind]:
			own_radius[str(_entity_dict(kind)[id].get("k", ""))] = true
	for id in entities["ellipse"]:
		own_radius[str(ellipses[id].get("km", ""))] = true
		own_radius[str(ellipses[id].get("kn", ""))] = true
	var dropped: Array = []
	for cid in constraints:
		if own_radius.has(cid):
			continue
		var c: Dictionary = constraints[cid]
		var named := false
		for key in c:
			if key == "id" or key == "type":
				continue
			var value = c[key]
			if value is String and doomed.has(value):
				named = true
			elif value is Array:
				for v in value:
					if v is String and doomed.has(v):
						named = true
		if named:
			dropped.append(str(cid))
	var out_entities := {}
	var extra_lines := 0
	var extra_curves := 0
	for kind in entities:
		out_entities[kind] = entities[kind].keys().filter(func(id): return not reference_ids.has(id))
		for id in out_entities[kind]:
			if not picked_ids.has(id):
				if kind == "line":
					extra_lines += 1
				else:
					extra_curves += 1
	var bits: Array = []
	if extra_lines > 0:
		bits.append("%d line%s" % [extra_lines, "" if extra_lines == 1 else "s"])
	if extra_curves > 0:
		bits.append("%d curve%s" % [extra_curves, "" if extra_curves == 1 else "s"])
	if not dropped.is_empty():
		bits.append("%d constraint%s" % [dropped.size(), "" if dropped.size() == 1 else "s"])
	return {"entities": out_entities, "points": points_out.keys(), "constraints": dropped, "collapse": collapse, "remove_shapes": remove_shapes,
		"extra": ("Also removed " + ", ".join(bits) + " that depended on it.") if not bits.is_empty() else ""}


func delete_selection() -> Dictionary:
	## Deletes the selected points, lines, circles, arcs, ellipses, splines and texts (never the origin) AND whatever depends on them, as the
	## flat app does (delete_cascade): the constraints that hold them (a line's Horizontal, a circle's Concentric...), the lines and curves built on a
	## deleted point, and a rectangle / polygon / slot that is cut about (collapsed to plain lines) or entirely taken (deleted whole). Order matters to
	## the backend: shapes, then constraints, then entities, then points. The backend prunes the points nothing uses any more. Takes one step back
	## with Undo only if nothing was deleted (there is no restore for a delete, as in the flat app's Delete): take care with the picks.
	if busy:
		return {"ok": false, "message": ""}
	var plan := delete_cascade()
	var nothing: bool = plan["points"].is_empty() and plan["constraints"].is_empty() and plan["collapse"].is_empty() and plan["remove_shapes"].is_empty()
	for kind in plan["entities"]:
		nothing = nothing and (plan["entities"][kind] as Array).is_empty()
	if nothing:
		return {"ok": false, "message": "The origin can't be deleted." if not selection.is_empty() else ""}
	busy = true
	var failed := ""
	var shape_ops: Array = []
	for entry in plan["collapse"]:
		shape_ops.append(SKETCH + sketch_id + "/" + SHAPE_ROUTES[entry["kind"]] + "/" + str(entry["id"]) + "/collapse")
	for path in shape_ops:
		var r: Dictionary = await api.call(HTTPClient.METHOD_POST, path, {})
		if not r["ok"]:
			failed = str(r["error"])
	for entry in plan["remove_shapes"]:
		var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/" + SHAPE_ROUTES[entry["kind"]] + "/" + str(entry["id"]), null)
		if not r["ok"]:
			failed = str(r["error"])
	if not shape_ops.is_empty() or not (plan["remove_shapes"] as Array).is_empty():
		await refresh(true) # a deleted shape took its own pieces and constraints with it: plan the rest against what is really left
		plan = delete_cascade()
	for cid in plan["constraints"]:
		var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + str(cid), null)
		if not r["ok"] and int(r.get("code", 0)) != 404:
			failed = str(r["error"])
	for kind in ENTITY_ROUTES:
		for id in plan["entities"][kind]:
			var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/" + ENTITY_ROUTES[kind] + "/" + str(id), null)
			if not r["ok"]:
				failed = str(r["error"])
	var gone := await _refresh_points_only()
	for pid in plan["points"]: # points last: deleting a line may already have taken one
		if gone.has(pid) or not points.has(pid):
			continue
		var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/points/" + str(pid), null)
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
	if str(plan["extra"]) != "":
		status.emit(str(plan["extra"]))
	return {"ok": refreshed, "message": ""}


func _refresh_points_only() -> Dictionary:
	## The points the backend has already removed by now (it prunes the ones nothing needs): {id: true}. Reads the sketch afresh.
	var before := points.duplicate()
	await refresh(false)
	var gone := {}
	for pid in before:
		if not points.has(pid):
			gone[pid] = true
	return gone


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
			"ellipse":
				path = SKETCH + sketch_id + "/ellipses/" + id
				was = bool(ellipses.get(id, {}).get("construction", false))
			"ellipse_arc":
				path = SKETCH + sketch_id + "/ellipse-arcs/" + id
				was = bool(ellipse_arcs.get(id, {}).get("construction", false))
			"spline":
				path = SKETCH + sketch_id + "/splines/" + id
				was = bool(splines.get(id, {}).get("construction", false))
			"text":
				path = SKETCH + sketch_id + "/texts/" + id
				was = bool(texts.get(id, {}).get("construction", false))
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
	## One pick for the Dimension tool, by the catalogue's pick rules: at most two picks, and a third restarts the selection unless all three are Points (the
	## first is the vertex); picking a picked entity again takes it out; an ellipse, a partial ellipse, a spline or a text stands alone (a pick of one restarts,
	## and so does a pick after one).
	var kind := str(entity["kind"])
	var id := str(entity["id"])
	for i in selection.size():
		if str(selection[i]["kind"]) == kind and str(selection[i]["id"]) == id:
			selection.remove_at(i)
			ghosts = _build_ghosts()
			changed.emit()
			return {"ok": true, "done": false, "message": ""}
	if kind in STANDALONE_KINDS or (not selection.is_empty() and str(selection[0]["kind"]) in STANDALONE_KINDS):
		selection.clear()
	elif selection.size() >= 2 and not (selection.size() == 2 and kind == "point" and selection.all(func(e): return str(e["kind"]) == "point")):
		selection.clear()
	selection.append({"kind": kind, "id": id})
	ghosts = _build_ghosts()
	changed.emit()
	return {"ok": true, "done": false, "message": ""}


func clear_selection() -> void:
	selection.clear()
	annotations.clear()
	ghosts.clear()
	changed.emit()


func is_annotation_selected(kind: String, id: String) -> bool:
	for a in annotations:
		if str(a["kind"]) == kind and str(a["id"]) == id:
			return true
	return false


func toggle_annotation(kind: String, id: String) -> void:
	## T5: a pull on a dimension label or constraint glyph: selected, or (already selected) let go again.
	for i in annotations.size():
		if str(annotations[i]["kind"]) == kind and str(annotations[i]["id"]) == id:
			annotations.remove_at(i)
			changed.emit()
			return
	if constraints.has(id):
		annotations.append({"kind": kind, "id": id})
		ghosts.clear() # dimension candidates belong to the geometry selection; the label's own menu takes over
		changed.emit()


func prune_annotations() -> void:
	## Drops the selected labels whose constraint is gone (deleted, or rebuilt by a refresh).
	annotations = annotations.filter(func(a) -> bool: return constraints.has(str(a["id"])))


func dimension_value(id: String) -> Dictionary:
	## The value of a dimension constraint as the label shows it: {ok, value, unit, kind}. Angles are degrees; everything else mm (a circle's size is its radius; an arc's length and
	## the three distances to circles are their own fields: `length`, `distance`).
	var c: Dictionary = constraints.get(id, {})
	match str(c.get("type", "")):
		"distance", "point_line_distance", "line_distance":
			return {"ok": true, "value": float(c.get("distance", 0.0)) * value_scale(id), "unit": "mm", "kind": "distance"}
		"angle", "horizontal_angle", "point_angle":
			return {"ok": true, "value": float(c.get("angle_degrees", 0.0)), "unit": "deg", "kind": "angle"}
		"arc_length":
			return {"ok": true, "value": float(c.get("length", 0.0)), "unit": "mm", "kind": "arc_length"}
		"point_circle_distance", "circle_distance", "line_circle_distance":
			return {"ok": true, "value": float(c.get("distance", 0.0)), "unit": "mm", "kind": "distance"}
	return {"ok": false, "value": 0.0, "unit": "", "kind": ""}


func value_scale(id: String) -> float:
	## How many times the stored value the label shows: 2 for an ellipse's axis read as the full axis (tip to tip) and for a circle's / arc's size dimension read as a
	## diameter (the toggles, saved in the label's `show`); else 1. dimension_value multiplies by it and edit_dimension divides: "show full, type 80" stores 40.
	if is_axis_dimension(id):
		return 2.0 if shows_full_axis(id) else 1.0
	if bool(diameter_shown.get(id, false)) and is_size_dimension(id):
		return 2.0
	return 1.0


func is_axis_dimension(id: String) -> bool:
	## An ellipse's axis dimension (a full ellipse's size constraint, or an elliptical arc's centre-to-tip distance): what the semi / full toggle flips.
	return not ellipse_axis_line(id).is_empty() or not ellipse_arc_axis(id).is_empty()


func shows_full_axis(id: String) -> bool:
	## Whether an axis dimension reads as the full axis: the saved choice, else the default (a full ellipse's axis reads full, tip to tip, as both apps draw it;
	## an elliptical arc's axis keeps reading centre to tip, the stored value, as it did before there was a choice).
	if axis_semi.has(id):
		return not bool(axis_semi[id])
	return not ellipse_axis_line(id).is_empty()


func default_show(id: String) -> String:
	## What a dimension reads as when no choice is saved: "radius" (a circle's or arc's size), "full" or "semi" (an axis); "" for any other.
	if is_size_dimension(id):
		return "radius"
	if not ellipse_axis_line(id).is_empty():
		return "full"
	if not ellipse_arc_axis(id).is_empty():
		return "semi"
	return ""


func show_of(id: String) -> String:
	## The reading a size or axis dimension has now: "radius" | "diameter" | "semi" | "full", "" when it has none.
	if is_size_dimension(id):
		return "diameter" if bool(diameter_shown.get(id, false)) else "radius"
	if is_axis_dimension(id):
		return "full" if shows_full_axis(id) else "semi"
	return ""


func ellipse_arc_axis(constraint_id: String) -> Dictionary:
	## {arc, axis ("major" | "minor"), c, tip} (point ids) when `constraint_id` is the plain distance from an elliptical arc's centre to one of its axis points, else {}.
	var c: Dictionary = constraints.get(constraint_id, {})
	if str(c.get("type", "")) != "distance" or str(c.get("orientation", "linear")) != "linear":
		return {}
	for aid in ellipse_arcs:
		var a: Dictionary = ellipse_arcs[aid]
		var pa := str(c.get("point_a_id", ""))
		var pb := str(c.get("point_b_id", ""))
		for axis in ["major", "minor"]:
			var tip := str(a["ma"] if axis == "major" else a["mi"])
			if (pa == a["c"] and pb == tip) or (pb == a["c"] and pa == tip):
				return {"arc": aid, "axis": axis, "c": str(a["c"]), "tip": tip}
	return {}


func is_size_dimension(id: String) -> bool:
	## Whether constraint `id` is the radius a circle or an arc holds (what the R / diameter toggle flips).
	for cid in circles:
		if str(circles[cid].get("k", "")) == id:
			return true
	for aid in arcs:
		if str(arcs[aid].get("k", "")) == id:
			return true
	return false


func toggle_diameter(id: String) -> bool:
	## The flat app's Radius / Diameter toggle for an existing circle or arc dimension: the same stored radius, read the other way (R5 <-> diameter 10). The choice is
	## saved in the dimension's label record (`show`, F5 / decision 10) so a reload and the flat app show it the same way. False when `id` is not a size dimension.
	if not is_size_dimension(id):
		return false
	_set_show(id, "radius" if bool(diameter_shown.get(id, false)) else "diameter")
	return true


func toggle_axis(id: String) -> bool:
	## The semi / full toggle of an ellipse's axis dimension: the stored value is always the semi-axis, the choice is how it is read (full: tip to tip, twice the value;
	## semi: centre to tip, the value). Saved as `show`. False when `id` is not an axis dimension.
	if not is_axis_dimension(id):
		return false
	_set_show(id, "semi" if shows_full_axis(id) else "full")
	return true


func _set_show(id: String, show: String) -> void:
	_note_show(id, show)
	var label: Dictionary = (constraints.get(id, {}).get("label", {}) as Dictionary).duplicate() if constraints.get(id, {}).get("label") is Dictionary else {}
	label["show"] = show
	if constraints.has(id):
		constraints[id]["label"] = label
	changed.emit()
	_write_show(id, show)


func _note_show(id: String, show: String) -> void:
	## Takes a reading choice: a diameter flag for a circle / arc size, a semi flag for an axis; anything else is ignored.
	match show:
		"diameter":
			diameter_shown[id] = true
		"radius":
			diameter_shown.erase(id)
		"semi":
			axis_semi[id] = true
		"full":
			axis_semi[id] = false


func _write_show(id: String, show: String) -> void:
	## PUT .../constraints/{id}/label with `show` ALONE: the backend keeps the placement a show-only PUT leaves out (and a placement-only PUT keeps the show), so
	## neither wipes the other. In-flight writes are counted so a refresh does not overwrite the choice with an older one.
	_show_writes[id] = int(_show_writes.get(id, 0)) + 1
	var r: Dictionary = await api.call(HTTPClient.METHOD_PUT, SKETCH + sketch_id + "/constraints/" + id + "/label", {"show": show})
	_show_writes[id] = int(_show_writes.get(id, 1)) - 1
	if not bool(r["ok"]):
		status.emit("Couldn't save how that dimension is shown: %s" % str(r["error"]))
	changed.emit()


func show_writes_pending() -> bool:
	for id in _show_writes:
		if int(_show_writes[id]) > 0:
			return true
	return false


func ellipse_axis_line(constraint_id: String) -> Dictionary:
	## {a, b} (sketch mm): the tip-to-tip line of the full ellipse axis whose size constraint is `constraint_id` (a: the far tip, b: the tip the constraint names); {} when
	## it is not one. The far tip is the ellipse's own negative tip Point, else the mirror of b through the centre.
	for eid in ellipses:
		var e: Dictionary = ellipses[eid]
		var major := str(e.get("km", "")) == constraint_id
		if not (major or str(e.get("kn", "")) == constraint_id) or constraint_id == "":
			continue
		var tip_id := str(e["ma"] if major else e["mi"])
		var neg_id := str(e.get("man", "") if major else e.get("mnn", ""))
		if not points.has(str(e.get("c", ""))) or not points.has(tip_id):
			return {}
		var tip: Vector2 = points[tip_id]
		var far: Vector2 = points[neg_id] if neg_id != "" and points.has(neg_id) else (points[e["c"]] as Vector2) * 2.0 - tip
		return {"a": far, "b": tip}
	return {}


func angle_side_value(id: String, quadrant: int) -> float:
	## The angle (degrees) that angle dimension `id` would measure in sector `quadrant` of the lines / points as they are now: what keeps the geometry still when the side
	## changes. -1 when `id` is not an angle or its lines are not here.
	var c: Dictionary = constraints.get(id, {})
	var spec: Dictionary = {}
	match str(c.get("type", "")):
		"angle":
			spec = angle_spec(str(c.get("line1_id", "")), str(c.get("line2_id", "")), -1.0, quadrant)
		"horizontal_angle":
			spec = horizontal_angle_spec(str(c.get("line_id", "")), quadrant)
		"point_angle":
			spec = point_angle_spec(str(c.get("vertex_point_id", "")), str(c.get("point1_id", "")), str(c.get("point2_id", "")), quadrant)
	if spec.is_empty() or not spec.has("d1") or not spec.has("d2"):
		return -1.0
	return rad_to_deg(acos(clampf((spec["d1"] as Vector2).dot(spec["d2"]), -1.0, 1.0)))


func set_angle_side(id: String, quadrant: int = -1) -> Dictionary:
	## Edits which angle an existing angle dimension is (S6; the flat app re-sends the value with a new quadrant, PATCH .../constraints/{id} {value, quadrant}). The new
	## value is what the picked side measures NOW, so nothing moves; type a number afterwards to turn it. `quadrant` -1: the next of the four (0-3, as the backend
	## saves it). Undo puts the old side and value back. A conflict is kept, red, as an edited value is. {ok, message}.
	var c: Dictionary = constraints.get(id, {})
	if busy or not str(c.get("type", "")) in ["angle", "horizontal_angle", "point_angle"]:
		return {"ok": false, "message": ""}
	var current := _quadrant_of(c)
	var q := quadrant if quadrant >= 0 else posmod((current if current >= 0 else 0) + 1, 4)
	var value := angle_side_value(id, q)
	if value <= 0.0:
		var msg := "That side has no angle: the lines are parallel there."
		status.emit(msg)
		return {"ok": false, "message": msg}
	busy = true
	var path := SKETCH + sketch_id + "/constraints/" + id
	var old_body := {"value": float(c.get("angle_degrees", 0.0))}
	if current >= 0:
		old_body["quadrant"] = current
	var r: Dictionary = await api.call(HTTPClient.METHOD_PATCH, path, {"value": value, "quadrant": q})
	if not r["ok"]:
		busy = false
		var message := "Couldn't change that angle: %s" % str(r["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	_undo.append({"label": "angle side", "calls": [[HTTPClient.METHOD_PATCH, path, old_body]]})
	await refresh(false)
	annotations.clear()
	busy = false
	changed.emit()
	var message := "" if converged else "That side conflicts with the other constraints: what it holds is red. Change it again, or Undo."
	if message != "":
		status.emit(message)
	return {"ok": true, "message": message}


func label_candidate(id: String) -> Dictionary:
	## An existing dimension as the label drag reads it (the shape DimensionPreview.placement_at takes): {key, spec, apply: {create}}, built from its drawn row; {} for a
	## reference (driven) dimension, which carries no placement on the backend, and for what is not a dimension.
	var c: Dictionary = constraints.get(id, {})
	if c.is_empty():
		return {}
	for item in dimension_items():
		if str(item["id"]) != id:
			continue
		if bool(item.get("driven", false)):
			return {}
		var key := "x"
		match str(c.get("type", "")):
			"angle":
				key = "angle"
			"line_distance":
				key = "lineDistance"
			"horizontal_angle":
				key = "horizontalAngle"
			"point_angle":
				key = "pointAngle"
		return {"key": key, "spec": item["spec"], "apply": {"create": c}}
	return {}


func edit_dimension(id: String, value: float) -> Dictionary:
	## T5: sets an existing dimension's value (PATCH the constraint, as confirm_ghost does for a first value). Undo puts the old one back; a value the
	## solver cannot meet is KEPT and shown red (a conflict that comes later, 3.3 of docs/dimension-constraint-parity-plan.md). {ok, message}: ok even then, the message says so.
	var current := dimension_value(id)
	if not current["ok"] or busy:
		return {"ok": false, "message": "That isn't a dimension with a value."}
	if value <= 0.0:
		var msg := "A dimension has to be bigger than zero."
		status.emit(msg)
		return {"ok": false, "message": msg}
	busy = true
	var path := SKETCH + sketch_id + "/constraints/" + id
	var scale := value_scale(id)
	var r: Dictionary = await api.call(HTTPClient.METHOD_PATCH, path, {"value": value / scale})
	if not r["ok"]:
		busy = false
		var message := "Couldn't change that dimension: %s" % str(r["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	_undo.append({"label": "dimension value", "calls": [[HTTPClient.METHOD_PATCH, path, {"value": float(current["value"]) / scale}]]})
	await refresh(false)
	# A conflict that comes LATER (an edited value) is kept, as in the flat app: the solver's failed list turns what it holds red. (A constraint that conflicts
	# right after it is made is still taken back: that is confirm_ghost's and the menu's rule.)
	var message := "" if converged else "That value conflicts with the other constraints: what it holds is red. Change it again, or Undo."
	if message != "":
		status.emit(message)
	annotations.clear()
	busy = false
	changed.emit()
	return {"ok": true, "message": message}


func delete_annotations() -> Dictionary:
	## T5: Delete with dimension labels / constraint glyphs selected: those constraints go (undo puts a deleted one back), and then, when geometry is
	## selected too, that geometry with what depends on it (delete_selection: no undo, as there). {ok, message}.
	if busy:
		return {"ok": false, "message": ""}
	prune_annotations()
	var ids: Array = []
	for a in annotations:
		if str(a["id"]) not in ids:
			ids.append(str(a["id"]))
	busy = true
	var calls: Array = []
	var labels := {} ## index into calls -> the saved label placement of the constraint that call re-makes
	var failed := ""
	for cid in ids:
		var c: Dictionary = (constraints.get(cid, {}) as Dictionary).duplicate(true)
		var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + cid, null)
		if r["ok"]:
			c.erase("id")
			c.erase("number")
			if number_of(cid) > 0:
				c["number"] = number_of(cid) # an undo that re-creates a thing restores its name (D4 stays D4): every create route takes the old number (F4)
			var saved_place: Variant = c.get("label")
			c.erase("label")
			if saved_place is Dictionary and not (saved_place as Dictionary).is_empty():
				labels[calls.size()] = saved_place # the label is its own route: Undo puts it back after the constraint is made again
			calls.append([HTTPClient.METHOD_POST, SKETCH + sketch_id + "/constraints", c])
		elif int(r.get("code", 0)) != 404:
			failed = str(r["error"])
	annotations.clear()
	var with_geometry := not selection.is_empty()
	if not calls.is_empty() and not with_geometry:
		_undo.append({"label": "delete constraint", "calls": calls, "labels": labels})
	await refresh(false)
	busy = false
	if with_geometry:
		var geometry := await delete_selection()
		return {"ok": failed == "" and bool(geometry["ok"]), "message": failed if failed != "" else str(geometry.get("message", ""))}
	changed.emit()
	if failed != "":
		status.emit("Couldn't delete: %s" % failed)
	return {"ok": failed == "" and not calls.is_empty(), "message": failed}


func _line_points(id: String) -> Array:
	var l: Dictionary = lines.get(id, {})
	return [l.get("a", ""), l.get("b", "")]


func _build_ghosts() -> Array:
	return _ghosts_for(selection)


func _ghosts_for(picked: Array) -> Array:
	## What `picked` can be dimensioned as: exactly the options of DIDSA-CAD's docs/sketch-dimension-catalogue.json (keys, labels, order, conditions;
	## tests/sketch_dimension_catalogue.gd holds this to it). Each: {key, label, unit, value, uv (where the label floats), apply: {patch_id?, create?, factor},
	## spec (how it is drawn), creates (the catalogue's `creates`), ref (the reference kind it would be), text_kind, side? ("pointer": which angle it is follows the
	## pointer, frozen at the drop)}. When everything picked is already pinned (pieces of the part, the origin, or Fixed) nothing a dimension could say would move
	## anything, so the catalogue's `pinned` block applies instead (PINNED_KINDS): the candidates whose reference kind it lists, each a DRIVEN (reference-only) one:
	## `driven` true, it only measures, and keeping it (keep_driven) adds no constraint: it becomes a persistent reference dimension on the backend.
	var out: Array = _ghosts_raw(picked)
	if not out.is_empty() and _all_pinned(picked):
		var allowed: Array = PINNED_KINDS.get(pins_key(picked), [])
		var seen := {}
		var kept: Array = []
		for g in out:
			var ref := str(g.get("ref", ""))
			if ref == "" or not allowed.has(ref) or seen.has(ref):
				continue # (another candidate of the same reference kind says the same thing)
			seen[ref] = true
			g["driven"] = true
			g["label"] = "Reference " + str(g["label"]).to_lower()
			kept.append(g)
		return kept
	return out


const PINNED_KINDS := { ## the catalogue's `pinned.kinds`: what is offered as a reference dimension between pinned things (tests hold it to the file)
	"point+point": ["distance", "horizontal", "vertical"], "point+line": ["distance"], "line": ["distance", "horizontal", "vertical", "horizontal_angle"],
	"line+line": ["angle", "distance"], "circle": ["radius", "diameter"], "arc": ["radius", "diameter", "arc_length"], "point+point+point": ["point_angle"],
	"point+circle": ["min_distance", "max_distance"], "point+arc": ["min_distance", "max_distance"], "circle+circle": ["min_distance", "max_distance"],
	"circle+arc": ["min_distance", "max_distance"], "arc+arc": ["min_distance", "max_distance"], "line+circle": ["min_distance", "max_distance"],
	"line+arc": ["min_distance", "max_distance"]}
const KIND_RANK := {"point": 0, "line": 1, "circle": 2, "arc": 3, "ellipse": 4, "ellipse_arc": 5, "spline": 6, "text": 7}
const STANDALONE_KINDS := ["ellipse", "ellipse_arc", "spline", "text"] ## dimensioned on their own: a pick of one restarts the selection, and so does a pick after it


static func pins_key(picked: Array) -> String:
	## The catalogue's key for a pick: the kinds joined with '+', in the fixed order point, line, circle, arc (three points keep their order: the vertex first).
	var kinds: Array = picked.map(func(e): return str(e["kind"]))
	if kinds.size() != 3:
		kinds.sort_custom(func(x, y): return int(KIND_RANK.get(x, 9)) < int(KIND_RANK.get(y, 9)))
	return "+".join(kinds)


static func dimension_kind_of_key(key: String) -> String:
	## How a candidate's number is written (dimension_text's kinds), from its key (the catalogue's keys, or a reference dimension's kind).
	if key in ["radius", "majorradius", "minorradius"]:
		return "radius"
	if key in ["diameter", "majordiameter", "minordiameter"]:
		return "diameter"
	if key in ["angle", "horizontalAngle", "pointAngle", "horizontal_angle", "point_angle"]:
		return "angle"
	if key in ["arcLength", "arc_length"]:
		return "arc_length"
	return "linear"


func _cand(key: String, label: String, unit: String, value: float, uv: Vector2, apply: Dictionary, spec: Dictionary, creates: String, ref := "", side := "") -> Dictionary:
	var g := _ghost(key, label, unit, value, uv, apply, spec)
	g["creates"] = creates
	g["ref"] = ref
	g["text_kind"] = dimension_kind_of_key(key)
	if side != "":
		g["side"] = side
	return g


func _spec_value(spec: Dictionary) -> float:
	## The length a linear / perp spec measures (the value of the distances that have no number of their own to read).
	return (spec["a"] as Vector2).distance_to(spec["b"]) if spec.has("a") and spec.has("b") else 0.0


func _ghosts_raw(picked: Array) -> Array:
	## The catalogue's options for a selection, no pinned rule. [] for anything the catalogue offers nothing for.
	if picked.is_empty():
		return []
	if picked.size() == 1:
		return _single_ghosts(picked[0])
	if picked.size() == 2:
		return _pair_ghosts(picked[0], picked[1])
	if picked.size() == 3 and picked.all(func(e): return str(e["kind"]) == "point"):
		return _point_angle_ghosts(str(picked[0]["id"]), str(picked[1]["id"]), str(picked[2]["id"]))
	return []


func _single_ghosts(first: Dictionary) -> Array:
	var out: Array = []
	var id := str(first["id"])
	match str(first["kind"]):
		"line":
			var pts := _line_points(id)
			if points.has(pts[0]) and points.has(pts[1]):
				var pa: Vector2 = points[pts[0]]
				var pb: Vector2 = points[pts[1]]
				out.append(_cand("length", "Length", "mm", pa.distance_to(pb), (pa + pb) * 0.5, _distance_apply(pts[0], pts[1], "linear"), {"kind": "linear", "a": pa, "b": pb}, "distance:linear", "distance"))
				out.append(_cand("h", "Horizontal length", "mm", absf(pb.x - pa.x), Vector2((pa.x + pb.x) * 0.5, minf(pa.y, pb.y)), _distance_apply(pts[0], pts[1], "horizontal"), {"kind": "horizontal", "a": pa, "b": pb}, "distance:horizontal", "horizontal"))
				out.append(_cand("v", "Vertical length", "mm", absf(pb.y - pa.y), Vector2(minf(pa.x, pb.x), (pa.y + pb.y) * 0.5), _distance_apply(pts[0], pts[1], "vertical"), {"kind": "vertical", "a": pa, "b": pb}, "distance:vertical", "vertical"))
				if pa.distance_to(pb) > 0.0001:
					# From the start against +x (quadrant 0): the angle the reference dimension reads, 0-180. The pointer picks the end and the side later (S5).
					var theta := rad_to_deg(absf((pb - pa).angle()))
					out.append(_cand("horizontalAngle", "Angle to horizontal", "deg", theta, (pa + pb) * 0.5,
						{"create": {"type": "horizontal_angle", "line_id": id, "quadrant": 0}, "factor": 1.0, "value_key": "angle_degrees"}, horizontal_angle_spec(id, 0, theta), "horizontal_angle", "horizontal_angle", "pointer"))
		"circle", "arc":
			var c: Dictionary = circles.get(id, arcs.get(id, {}))
			var rim: String = c.get("p", c.get("s", ""))
			if points.has(c.get("c", "")) and points.has(rim) and str(c.get("k", "")) != "":
				var r: float = points[c["c"]].distance_to(points[rim])
				var radius := _cand("radius", "Radius", "mm", r, points[c["c"]] + Vector2(r * 0.5, 0), {"patch_id": c["k"], "factor": 1.0}, circle_spec("radius", id), "radius", "radius")
				var diameter := _cand("diameter", "Diameter", "mm", r * 2.0, points[c["c"]] + Vector2(-r * 0.5, 0), {"patch_id": c["k"], "factor": 0.5}, circle_spec("diameter", id), "diameter", "diameter")
				radius["show"] = "radius"
				diameter["show"] = "diameter"
				out.append_array([diameter, radius] if str(first["kind"]) == "circle" else [radius, diameter]) # a circle is dimensioned by its diameter first
				if str(first["kind"]) == "arc":
					var length := _arc_length(id)
					if length > 0.0:
						var existing := _constraint_where("arc_length", "arc_id", id)
						var apply: Dictionary = {"patch_id": existing, "factor": 1.0} if existing != "" else {"create": {"type": "arc_length", "arc_id": id}, "factor": 1.0, "value_key": "length"}
						out.append(_cand("arcLength", "Arc length", "mm", length, points[c["c"]], apply, arc_length_spec(id), "arc_length", "arc_length"))
		"ellipse", "ellipse_arc":
			out = _ellipse_ghosts(first)
	return out


func _line_pair_apply(type: String, l1: String, l2: String, value_key: String) -> Dictionary:
	## Typing a two-line angle or a line-to-line distance again updates the one already between those lines (either order), as the flat app does (C5); else makes one.
	## The create body stays beside the patch so the angle's side (quadrant, dimension_preview.with_side) still has something to set.
	var apply: Dictionary = {"create": {"type": type, "line1_id": l1, "line2_id": l2}, "factor": 1.0, "value_key": value_key}
	for id in constraints:
		var c: Dictionary = constraints[id]
		if str(c.get("type", "")) != type:
			continue
		var a := str(c.get("line1_id", ""))
		var b := str(c.get("line2_id", ""))
		if (a == l1 and b == l2) or (a == l2 and b == l1):
			apply["patch_id"] = id
			apply["swapped"] = a != l1 # the constraint's own line order is the other way round: its quadrant's two flip bits swap
			break
	return apply


func _point_line_apply(pt: String, ln: String) -> Dictionary:
	## A point's perpendicular distance to a line typed again updates the existing one (C5).
	var apply: Dictionary = {"create": {"type": "point_line_distance", "point_id": pt, "line_id": ln}, "factor": 1.0, "value_key": "distance"}
	for id in constraints:
		var c: Dictionary = constraints[id]
		if str(c.get("type", "")) == "point_line_distance" and str(c.get("point_id", "")) == pt and str(c.get("line_id", "")) == ln:
			apply["patch_id"] = id
			break
	return apply


func _constraint_where(type: String, field: String, value: String) -> String:
	## The id of an existing constraint of this type whose `field` is `value` ("" for none).
	for cid in constraints:
		if str(constraints[cid].get("type", "")) == type and str(constraints[cid].get(field, "")) == value:
			return str(cid)
	return ""


func _arc_length(id: String) -> float:
	var a: Dictionary = arcs.get(id, {})
	if a.is_empty() or not points.has(a["c"]) or not points.has(a["s"]) or not points.has(a["e"]):
		return 0.0
	var c: Vector2 = points[a["c"]]
	return c.distance_to(points[a["s"]]) * fposmod((points[a["e"]] - c).angle() - (points[a["s"]] - c).angle(), TAU)


func _ellipse_ghosts(first: Dictionary) -> Array:
	## An ellipse or partial ellipse: both axes' radius and diameter, major first (the catalogue's order). A full ellipse's axes are its two size constraints; a
	## partial one has none, so its axis is a plain distance from the centre to the axis point.
	var out: Array = []
	var id := str(first["id"])
	var is_full := str(first["kind"]) == "ellipse"
	var el: Dictionary = ellipses.get(id, {}) if is_full else ellipse_arcs.get(id, {})
	if is_reference(id) or not points.has(el.get("c", "")) or not points.has(el.get("ma", "")) or not points.has(el.get("mi", "")):
		return out # a pinned reference ellipse: its size is the part's, there is nothing to dimension
	var cc: Vector2 = points[el["c"]]
	for axis in ["major", "minor"]:
		var tip_id: String = el["ma"] if axis == "major" else el["mi"]
		var k := str(el.get("km" if axis == "major" else "kn", ""))
		var tip: Vector2 = points[tip_id]
		var r := cc.distance_to(tip)
		var radius_apply: Dictionary
		var diameter_apply: Dictionary
		if is_full:
			if k == "":
				continue
			radius_apply = {"patch_id": k, "factor": 1.0}
			diameter_apply = {"patch_id": k, "factor": 0.5}
		else:
			radius_apply = _distance_apply(str(el["c"]), tip_id, "linear")
			diameter_apply = _distance_apply(str(el["c"]), tip_id, "linear")
			diameter_apply["factor"] = 0.5
		# A full ellipse's axis is a straight dimension: semi (the Radius candidate) centre to tip, full (the Diameter candidate) tip to tip, as the flat app draws it once
		# made, so a placement dropped on the candidate is the one that dimension reads (kind `ellipse_axis`, {offset, along}). An elliptical arc's axis is laid out radially
		# (kind `radius`, {angle, leg}): a radius leader for the semi-axis, the circle-diameter style for the full one. Each candidate carries the `show` it makes: a new
		# dimension reads as it was chosen (F5, C4; the choice is saved with it).
		var far: Vector2 = cc * 2.0 - tip
		if is_full:
			var far_id := str(el.get("man", "") if axis == "major" else el.get("mnn", ""))
			if far_id != "" and points.has(far_id):
				far = points[far_id]
		var semi_spec: Dictionary = {"kind": "linear", "a": cc, "b": tip} if is_full else radial_spec("radius", cc, tip)
		var full_spec: Dictionary = {"kind": "linear", "a": far, "b": tip} if is_full else radial_spec("diameter", cc, tip)
		var semi_cand := _cand("%sradius" % axis, "%s radius" % axis.capitalize(), "mm", r, cc + (tip - cc) * 0.5, radius_apply, semi_spec, "radius")
		var full_cand := _cand("%sdiameter" % axis, "%s diameter" % axis.capitalize(), "mm", r * 2.0, cc + (tip - cc) * 0.5, diameter_apply, full_spec, "diameter")
		semi_cand["show"] = "semi"
		full_cand["show"] = "full"
		out.append(semi_cand)
		out.append(full_cand)
	return out


func _point_pair_ghosts(a: String, b: String) -> Array:
	## Aligned, Horizontal and Vertical between two points (a circle's or arc's centre stands in for it).
	if a == b or not points.has(a) or not points.has(b):
		return []
	var pa: Vector2 = points[a]
	var pb: Vector2 = points[b]
	return [
		_cand("linear", "Aligned", "mm", pa.distance_to(pb), (pa + pb) * 0.5, _distance_apply(a, b, "linear"), {"kind": "linear", "a": pa, "b": pb}, "distance:linear", "distance"),
		_cand("h", "Horizontal", "mm", absf(pb.x - pa.x), Vector2((pa.x + pb.x) * 0.5, minf(pa.y, pb.y)), _distance_apply(a, b, "horizontal"), {"kind": "horizontal", "a": pa, "b": pb}, "distance:horizontal", "horizontal"),
		_cand("v", "Vertical", "mm", absf(pb.y - pa.y), Vector2(minf(pa.x, pb.x), (pa.y + pb.y) * 0.5), _distance_apply(a, b, "vertical"), {"kind": "vertical", "a": pa, "b": pb}, "distance:vertical", "vertical")]


static func point_pair_kind(pa: Vector2, pb: Vector2, cursor: Vector2) -> String:
	## The catalogue's cursor rule "point_pair_box", for a pair of points (or centres), until a kind has been picked: the cursor within the pair's x span and outside
	## its y span gives "h"; within the y span and outside the x span, "v"; else (inside the box, or a corner region) "linear". Spans are closed intervals.
	var in_x := cursor.x >= minf(pa.x, pb.x) and cursor.x <= maxf(pa.x, pb.x)
	var in_y := cursor.y >= minf(pa.y, pb.y) and cursor.y <= maxf(pa.y, pb.y)
	if in_x and not in_y:
		return "h"
	if in_y and not in_x:
		return "v"
	return "linear"


func cursor_rule(picked: Array = selection) -> Dictionary:
	## {rule: "point_pair_box", a, b} for the selections the catalogue gives that rule (two points, or centres standing in for circles / arcs), else {}.
	if picked.size() != 2:
		return {}
	var anchors: Array = []
	for e in picked:
		match str(e["kind"]):
			"point":
				anchors.append(str(e["id"]))
			"circle", "arc":
				anchors.append(str((circles.get(str(e["id"]), arcs.get(str(e["id"]), {})) as Dictionary).get("c", "")))
			_:
				return {}
	if anchors[0] == anchors[1] or not points.has(anchors[0]) or not points.has(anchors[1]) or _ghosts_raw(picked).is_empty() or _line_pair_for_points(picked).size() == 2:
		return {}
	return {"rule": "point_pair_box", "a": points[anchors[0]], "b": points[anchors[1]]}


func _lines_parallel(l1: String, l2: String) -> bool:
	## The catalogue's lines_parallel: the unit directions' |cross| <= sin(0.02 rad).
	var p1 := _line_points(l1)
	var p2 := _line_points(l2)
	if not points.has(p1[0]) or not points.has(p1[1]) or not points.has(p2[0]) or not points.has(p2[1]):
		return false
	var d1: Vector2 = points[p1[1]] - points[p1[0]]
	var d2: Vector2 = points[p2[1]] - points[p2[0]]
	if d1.length() < 0.000001 or d2.length() < 0.000001:
		return false
	return absf(d1.normalized().cross(d2.normalized())) <= sin(0.02)


func _lines_of_point(point_id: String) -> Array:
	## The lines a point is an end of or sits at the middle of.
	var out: Array = []
	if not points.has(point_id):
		return out
	for lid in lines:
		var ends := _line_points(str(lid))
		if ends[0] == point_id or ends[1] == point_id:
			out.append(lid)
		elif points.has(ends[0]) and points.has(ends[1]) and (points[point_id] - (points[ends[0]] + points[ends[1]]) * 0.5).length_squared() <= 1e-9:
			out.append(lid)
	return out


func _line_pair_for_points(picked: Array) -> Array:
	## Two points that each lie on a line (an end or the middle) where those lines are different and parallel are read as those two lines: [l1, l2], else [].
	if picked.size() != 2 or str(picked[0]["kind"]) != "point" or str(picked[1]["kind"]) != "point":
		return []
	for l1 in _lines_of_point(str(picked[0]["id"])):
		for l2 in _lines_of_point(str(picked[1]["id"])):
			if l1 != l2 and _lines_parallel(str(l1), str(l2)):
				return [l1, l2]
	return []


func _line_pair_ghosts(l1: String, l2: String) -> Array:
	## Two lines: their distance when parallel, else the angle between them.
	if l1 == l2:
		return []
	var p1 := _line_points(l1)
	var p2 := _line_points(l2)
	if not points.has(p1[0]) or not points.has(p1[1]) or not points.has(p2[0]) or not points.has(p2[1]):
		return []
	var mid: Vector2 = (points[p1[0]] + points[p1[1]] + points[p2[0]] + points[p2[1]]) * 0.25
	if _lines_parallel(l1, l2):
		var spec := line_distance_spec(l1, l2)
		var d1: Vector2 = (points[p1[1]] - points[p1[0]]).normalized()
		var dist: float = absf((points[p2[0]] - points[p1[0]]).cross(d1))
		return [_cand("lineDistance", "Distance", "mm", dist, mid, _line_pair_apply("line_distance", l1, l2, "distance"), spec, "line_distance", "distance")]
	var d1n: Vector2 = (points[p1[1]] - points[p1[0]]).normalized()
	var d2n: Vector2 = (points[p2[1]] - points[p2[0]]).normalized()
	var ang := rad_to_deg(acos(clampf(d1n.dot(d2n), -1.0, 1.0)))
	return [_cand("angle", "Angle", "deg", ang, mid, _line_pair_apply("angle", l1, l2, "angle_degrees"), angle_spec(l1, l2), "angle", "angle", "pointer")]


func _point_line_ghosts(pt: String, ln: String, perpendicular_label: String, with_axes: bool) -> Array:
	## A point (or a circle's centre) against a line: the perpendicular distance; for a plain point also Horizontal / Vertical / Aligned to the line's nearer end.
	## Nothing when the point is one of the line's own ends.
	var lp := _line_points(ln)
	if not points.has(pt) or not points.has(lp[0]) or not points.has(lp[1]) or pt == lp[0] or pt == lp[1]:
		return []
	var perp := perp_spec(pt, ln)
	var out: Array = [_cand("perpendicular", perpendicular_label, "mm", _spec_value(perp), ((perp["a"] + perp["b"]) * 0.5) if not perp.is_empty() else points[pt],
		_point_line_apply(pt, ln), perp, "point_line_distance", "distance")]
	if with_axes:
		var near: String = lp[0] if points[pt].distance_squared_to(points[lp[0]]) <= points[pt].distance_squared_to(points[lp[1]]) else lp[1]
		var pa: Vector2 = points[pt]
		var pb: Vector2 = points[near]
		out.append(_cand("h", "Horizontal", "mm", absf(pb.x - pa.x), Vector2((pa.x + pb.x) * 0.5, minf(pa.y, pb.y)), _distance_apply(pt, near, "horizontal"), {"kind": "horizontal", "a": pa, "b": pb}, "distance:horizontal", ""))
		out.append(_cand("v", "Vertical", "mm", absf(pb.y - pa.y), Vector2(minf(pa.x, pb.x), (pa.y + pb.y) * 0.5), _distance_apply(pt, near, "vertical"), {"kind": "vertical", "a": pa, "b": pb}, "distance:vertical", ""))
		out.append(_cand("linear", "Aligned", "mm", pa.distance_to(pb), (pa + pb) * 0.5, _distance_apply(pt, near, "linear"), {"kind": "linear", "a": pa, "b": pb}, "distance:linear", ""))
	return out


func _curve_own_points(id: String) -> Array:
	## A circle's centre and rim, an arc's centre, start and end.
	if circles.has(id):
		return [circles[id]["c"], circles[id]["p"]]
	if arcs.has(id):
		return [arcs[id]["c"], arcs[id]["s"], arcs[id]["e"]]
	return []


func _centre_of(id: String) -> String:
	return str((circles.get(id, arcs.get(id, {})) as Dictionary).get("c", ""))


func _min_max(key: String, label: String, side: String, value: float, uv: Vector2, create: Dictionary, spec: Dictionary, creates: String) -> Dictionary:
	create["side"] = side
	return _cand(key, label, "mm", value, uv, {"create": create, "factor": 1.0, "value_key": "distance"}, spec, creates, "%s_distance" % side)


func _pair_ghosts(first: Dictionary, second: Dictionary) -> Array:
	var ka := str(first["kind"])
	var kb := str(second["kind"])
	var a := str(first["id"])
	var b := str(second["id"])
	if ka == "point" and kb == "point":
		var pair := _line_pair_for_points([first, second])
		if pair.size() == 2:
			return _line_pair_ghosts(str(pair[0]), str(pair[1]))
		return _point_pair_ghosts(a, b)
	if ka == "line" and kb == "line":
		return _line_pair_ghosts(a, b)
	if (ka == "point" and kb == "line") or (ka == "line" and kb == "point"):
		return _point_line_ghosts(a if ka == "point" else b, a if ka == "line" else b, "Perpendicular", true)
	var a_round := ka in ["circle", "arc"]
	var b_round := kb in ["circle", "arc"]
	if not (a_round or b_round):
		return []
	# a circle or arc against a point, a line or another circle / arc: its centre stands in for it
	var anchor_a := _centre_of(a) if a_round else (a if ka == "point" else "")
	var anchor_b := _centre_of(b) if b_round else (b if kb == "point" else "")
	if anchor_a != "" and anchor_b != "":
		if anchor_a == anchor_b:
			return []
		var out := _point_pair_ghosts(anchor_a, anchor_b)
		if out.is_empty():
			return out
		out.append_array(_curve_distance_ghosts(first, second))
		return out
	var line_id := a if ka == "line" else (b if kb == "line" else "")
	var curve: Dictionary = first if a_round else second
	if line_id != "":
		var out := _point_line_ghosts(_centre_of(str(curve["id"])), line_id, "Perpendicular from centre", false)
		if out.is_empty():
			return out # (the centre is an end of the line)
		out.append_array(_line_curve_ghosts(line_id, str(curve["id"])))
		return out
	return []


func _curve_distance_ghosts(first: Dictionary, second: Dictionary) -> Array:
	## Minimum and Maximum distance: a point to a circle / arc, or two circles / arcs.
	var ka := str(first["kind"])
	var kb := str(second["kind"])
	var a := str(first["id"])
	var b := str(second["id"])
	if ka in ["circle", "arc"] and kb in ["circle", "arc"]:
		var ra := _round_of(a)
		var rb := _round_of(b)
		if ra.is_empty() or rb.is_empty():
			return []
		var apart := (ra["c"] as Vector2).distance_to(rb["c"])
		var out: Array = []
		var base := {"type": "circle_distance", "entity1_id": a, "entity2_id": b}
		if apart > float(ra["r"]) + float(rb["r"]):
			var s_min := circle_circle_spec(a, b, "min")
			out.append(_min_max("minDistance", "Minimum distance", "min", _spec_value(s_min), (ra["c"] + rb["c"]) * 0.5, base.duplicate(), s_min, "circle_distance:min"))
		var s_max := circle_circle_spec(a, b, "max")
		out.append(_min_max("maxDistance", "Maximum distance", "max", _spec_value(s_max), (ra["c"] + rb["c"]) * 0.5, base.duplicate(), s_max, "circle_distance:max"))
		return out
	var pt := a if ka == "point" else b
	var curve := b if ka == "point" else a
	if not points.has(pt) or _curve_own_points(curve).has(pt):
		return [] # the point is one of the curve's own: there is no distance to measure
	var out: Array = []
	for side in ["min", "max"]:
		var spec := point_circle_spec(pt, curve, side)
		out.append(_min_max("%sDistance" % side, "%s distance" % ("Minimum" if side == "min" else "Maximum"), side, _spec_value(spec), (points[pt] + _round_of(curve).get("c", points[pt])) * 0.5,
			{"type": "point_circle_distance", "point_id": pt, "circle_or_arc_id": curve}, spec, "point_circle_distance:%s" % side))
	return out


func _line_curve_ghosts(line_id: String, curve: String) -> Array:
	## Tangent distance (only while the circle does not touch the line) and Far-side distance from a line to a circle / arc.
	var rd := _round_of(curve)
	var ends := _line_points(line_id)
	if rd.is_empty() or not points.has(ends[0]) or not points.has(ends[1]) or ends.has(_centre_of(curve)):
		return []
	var gap := _point_line_gap(rd["c"], points[ends[0]], points[ends[1]]) - float(rd["r"])
	var out: Array = []
	var base := {"type": "line_circle_distance", "line_id": line_id, "circle_or_arc_id": curve}
	if gap > 0.0:
		var s_min := line_circle_spec(line_id, curve, "min")
		out.append(_min_max("tangentDistance", "Tangent distance", "min", _spec_value(s_min), rd["c"], base.duplicate(), s_min, "line_circle_distance:min"))
	var s_max := line_circle_spec(line_id, curve, "max")
	out.append(_min_max("farDistance", "Far-side distance", "max", _spec_value(s_max), rd["c"], base.duplicate(), s_max, "line_circle_distance:max"))
	return out


static func _point_line_gap(p: Vector2, a: Vector2, b: Vector2) -> float:
	## A point's distance from the line's infinite extension.
	return p.distance_to(Geometry2D.get_closest_point_to_segment_uncapped(p, a, b))


func _point_angle_ghosts(vertex: String, p1: String, p2: String) -> Array:
	## Three points, the first the vertex: the angle between the rays to the other two (the pointer picks the sector later).
	if vertex == p1 or vertex == p2 or p1 == p2 or not points.has(vertex) or not points.has(p1) or not points.has(p2):
		return []
	var d1: Vector2 = points[p1] - points[vertex]
	var d2: Vector2 = points[p2] - points[vertex]
	if d1.length() < 0.0001 or d2.length() < 0.0001:
		return []
	var ang := rad_to_deg(acos(clampf(d1.normalized().dot(d2.normalized()), -1.0, 1.0)))
	return [_cand("pointAngle", "Angle", "deg", ang, points[vertex] + (d1.normalized() + d2.normalized()).normalized() * minf(d1.length(), d2.length()) * 0.6,
		{"create": {"type": "point_angle", "vertex_point_id": vertex, "point1_id": p1, "point2_id": p2, "quadrant": 0}, "factor": 1.0, "value_key": "angle_degrees"},
		point_angle_spec(vertex, p1, p2, 0), "point_angle", "point_angle", "pointer")]


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
			"ellipse", "ellipse_arc":
				ids = _entity_point_ids(str(e["kind"]), _entity_dict(str(e["kind"])).get(str(e["id"]), {}))
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
	## The label is the magnitude: a line-distance or point-line dimension is signed (the side of the line), and a minus on a label means nothing.
	value = absf(value)
	match kind:
		"radius":
			return "R" + format_value(value)
		"diameter":
			return "\u2300" + format_value(value)
		"angle":
			return format_value(value) + "\u00b0"
		"arc_length":
			return "\u2312" + format_value(value) # the arc sign, as the flat app writes an arc's length
	return format_value(value)


func circle_spec(kind: String, id: String, place := {}) -> Dictionary:
	## The layout spec of a circle's or arc's radius / diameter: its centre, radius and the direction its radius point lies in. A saved placement
	## (`angle`: the leader's direction in degrees counter-clockwise from the rim point's; `leg`: the label's distance beyond the circle) overrides the
	## automatic direction.
	var c: Dictionary = circles.get(id, arcs.get(id, {}))
	var rim: String = c.get("p", c.get("s", ""))
	if not points.has(c.get("c", "")) or not points.has(rim):
		return {}
	return radial_spec(kind, points[c["c"]], points[rim], place)


static func radial_spec(kind: String, centre: Vector2, rim_pt: Vector2, place := {}) -> Dictionary:
	## circle_spec's layout from a centre and a point on the rim (an elliptical arc's axis is laid out the same way from its centre and its tip, F5 / C4).
	var u := rim_pt - centre
	var r := u.length()
	var rim_angle := u.angle()
	if r < 0.0001:
		u = Vector2(1, 0)
	elif absf(u.x) < r * 0.2 or absf(u.y) < r * 0.2:
		# The radius point lies along an axis, where the centre mark already is: a leader or a diameter line is drawn at an angle instead (radius up and to the
		# right, diameter up and to the left), as on a drawing, so it does not run along the centre line.
		u = Vector2.from_angle(deg_to_rad(40.0 if kind == "radius" else 140.0))
	var spec := {"kind": kind, "c": centre, "r": r, "u": u, "rim_a": rim_angle}
	if r >= 0.0001 and (place.has("angle") or place.has("leg")):
		spec["u"] = Vector2.from_angle(rim_angle + deg_to_rad(float(place.get("angle", 0.0))))
		spec["label_r"] = r + float(place.get("leg", 0.0))
	return spec


static func _place_of(c: Dictionary) -> Dictionary:
	## The saved label placement of a constraint (`PUT .../constraints/{id}/label`), {} when it has none.
	var label: Variant = c.get("label")
	return label if label is Dictionary else {}


static func _linear_place(place: Dictionary) -> Dictionary:
	## The part of a saved placement a linear dimension reads ({} when it carries none of it).
	if not (place.has("offset") or place.has("along")):
		return {}
	return {"offset": float(place.get("offset", 0.0)), "along": float(place.get("along", 0.0))}


func angle_spec(l1: String, l2: String, value := -1.0, quadrant := -1, place := {}) -> Dictionary:
	## The layout spec of the angle between two lines: the point they meet at, a direction along each (away from it) and an arc radius. With the constraint's
	## own `value` and `quadrant` it is the sector the backend measures (quadrant bit 0 flips the first ray, bit 1 the second; none saved: the second flips
	## when the angle between the outward rays is nearer 180 - value than value), and a saved placement (`radius`, `along`) sets the arc's radius and where
	## the label sits on it. Without them (a candidate): the nearer sector.
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
	var r := minf(d1.length(), d2.length()) * 0.6
	if value >= 0.0 or quadrant >= 0:
		d1 = (a0 + a1) * 0.5 - point # outward: from where they meet towards each line's middle
		d2 = (b0 + b1) * 0.5 - point
		if d1.length() < 0.0001 or d2.length() < 0.0001:
			d1 = far_a - point
			d2 = far_b - point
		if quadrant >= 0:
			d1 = -d1 if quadrant & 1 != 0 else d1
			d2 = -d2 if quadrant & 2 != 0 else d2
		else:
			var between := rad_to_deg(absf(wrapf(d2.angle() - d1.angle(), -PI, PI)))
			if absf(between - (180.0 - value)) < absf(between - value):
				d2 = -d2
	var spec := {"kind": "angle", "apex": point, "d1": d1.normalized(), "d2": d2.normalized(), "r": r}
	if place.has("radius") or place.has("along"):
		_place_on_arc(spec, place, true)
	return spec


static func _place_on_arc(spec: Dictionary, place: Dictionary, along_is_length: bool) -> void:
	## Turns a saved angle placement into the spec's own keys: `r` (the arc's radius) and `label_a` (where the label sits on it, radians). The label is
	## `along` (an arc length, positive towards the second ray) or `angle` (degrees counter-clockwise) from the middle of the arc that runs the short way
	## from the first ray to the second.
	var a1 := (spec["d1"] as Vector2).angle()
	var sweep := wrapf((spec["d2"] as Vector2).angle() - a1, -PI, PI)
	var r := float(place["radius"]) if place.has("radius") else float(spec["r"])
	if r < 0.0001:
		return
	var mid := a1 + sweep * 0.5
	spec["r"] = r
	spec["label_a"] = mid + (signf(sweep) * float(place.get("along", 0.0)) / r if along_is_length else deg_to_rad(float(place.get("angle", 0.0))))


func horizontal_angle_spec(line_id: String, quadrant := -1, value := -1.0, place := {}) -> Dictionary:
	## A line's angle to the horizontal: drawn at the line's end (quadrant bit 0, else its start), against the +x ray (bit 1 set: -x). None saved: from the start,
	## against whichever horizontal ray makes the sector the value.
	var ends := _line_points(line_id)
	if not points.has(ends[0]) or not points.has(ends[1]):
		return {}
	var start: Vector2 = points[ends[0]]
	var end: Vector2 = points[ends[1]]
	var at_end := quadrant >= 0 and quadrant & 1 != 0
	var minus_x := quadrant >= 0 and quadrant & 2 != 0
	if quadrant < 0 and value >= 0.0:
		var to_x := rad_to_deg(absf((end - start).angle()))
		minus_x = absf(180.0 - to_x - value) < absf(to_x - value)
	var vertex := end if at_end else start
	var ray := (start if at_end else end) - vertex
	if ray.length() < 0.0001:
		return {}
	var spec := {"kind": "angle", "apex": vertex, "d1": ray.normalized(), "d2": Vector2(-1.0 if minus_x else 1.0, 0.0), "r": ray.length() * 0.5}
	if place.has("radius") or place.has("angle"):
		_place_on_arc(spec, place, false)
	return spec


func point_angle_spec(vertex_id: String, p1_id: String, p2_id: String, quadrant := -1, place := {}) -> Dictionary:
	## The angle at a vertex Point between the rays to two others (quadrant bit 0 flips the first ray, bit 1 the second).
	if not points.has(vertex_id) or not points.has(p1_id) or not points.has(p2_id):
		return {}
	var v: Vector2 = points[vertex_id]
	var d1: Vector2 = points[p1_id] - v
	var d2: Vector2 = points[p2_id] - v
	if d1.length() < 0.0001 or d2.length() < 0.0001:
		return {}
	var r := minf(d1.length(), d2.length()) * 0.6
	if quadrant >= 0:
		d1 = -d1 if quadrant & 1 != 0 else d1
		d2 = -d2 if quadrant & 2 != 0 else d2
	var spec := {"kind": "angle", "apex": v, "d1": d1.normalized(), "d2": d2.normalized(), "r": r}
	if place.has("radius") or place.has("angle"):
		_place_on_arc(spec, place, false)
	return spec


func arc_length_spec(arc_id: String, place := {}) -> Dictionary:
	## An arc's length: the dimension arc runs round beside the arc itself (`leg` out from it when saved, never nearer the centre than a tenth of the radius),
	## the label `angle` degrees counter-clockwise of its middle when saved.
	var a: Dictionary = arcs.get(arc_id, {})
	if a.is_empty() or not points.has(a["c"]) or not points.has(a["s"]) or not points.has(a["e"]):
		return {}
	var c: Vector2 = points[a["c"]]
	var r: float = c.distance_to(points[a["s"]])
	if r < 0.0001:
		return {}
	var start: Vector2 = points[a["s"]]
	var end: Vector2 = points[a["e"]]
	var a0 := (start - c).angle()
	var sweep := fposmod((end - c).angle() - a0, TAU)
	if sweep < 0.00001:
		sweep = TAU
	var spec := {"kind": "arc_length", "c": c, "r": r, "a0": a0, "sweep": sweep}
	if place.has("leg") or place.has("angle"):
		spec["ra"] = maxf(r + float(place.get("leg", 0.0)), 0.1 * r)
		spec["label_a"] = a0 + sweep * 0.5 + deg_to_rad(float(place.get("angle", 0.0)))
	return spec


func _round_of(id: String) -> Dictionary:
	## A circle's or arc's {c, r} (centre and radius), {} if it is not here.
	var d: Dictionary = circles.get(id, arcs.get(id, {}))
	var rim: String = d.get("p", d.get("s", ""))
	if d.is_empty() or not points.has(d.get("c", "")) or not points.has(rim):
		return {}
	var centre: Vector2 = points[d["c"]]
	return {"c": centre, "r": centre.distance_to(points[rim])}


static func _linear_between(a: Vector2, b: Vector2, place: Dictionary) -> Dictionary:
	if a.distance_to(b) < 0.0001:
		return {}
	var spec := {"kind": "linear", "a": a, "b": b}
	var p := _linear_place(place)
	if not p.is_empty():
		spec["place"] = p
	return spec


func point_circle_spec(point_id: String, curve_id: String, side: String, place := {}) -> Dictionary:
	## A Point's nearest (min) or farthest (max) distance to a circle or arc: a linear dimension from the Point to the circle's point on the line through the
	## Point and the centre, the nearer one for min.
	var rd := _round_of(curve_id)
	if rd.is_empty() or not points.has(point_id):
		return {}
	var p: Vector2 = points[point_id]
	var c: Vector2 = rd["c"]
	if p.distance_to(c) < 0.0001:
		return {}
	var u := (c - p).normalized()
	return _linear_between(p, c - u * float(rd["r"]) if side == "min" else c + u * float(rd["r"]), place)


func circle_circle_spec(id1: String, id2: String, side: String, place := {}) -> Dictionary:
	## Two circles' / arcs' gap (min: facing each other) or overall size (max: facing away) along their centre line.
	var r1 := _round_of(id1)
	var r2 := _round_of(id2)
	if r1.is_empty() or r2.is_empty() or (r1["c"] as Vector2).distance_to(r2["c"]) < 0.0001:
		return {}
	var u: Vector2 = ((r2["c"] as Vector2) - (r1["c"] as Vector2)).normalized()
	var facing := 1.0 if side == "min" else -1.0
	return _linear_between((r1["c"] as Vector2) + u * float(r1["r"]) * facing, (r2["c"] as Vector2) - u * float(r2["r"]) * facing, place)


func line_circle_spec(line_id: String, curve_id: String, side: String, place := {}) -> Dictionary:
	## A line's distance to a circle's / arc's tangent side (min) or far side (max): from the centre's foot on the line to the circle's point square to it.
	var rd := _round_of(curve_id)
	var ends := _line_points(line_id)
	if rd.is_empty() or not points.has(ends[0]) or not points.has(ends[1]) or (points[ends[0]] as Vector2).distance_to(points[ends[1]]) < 0.0001:
		return {}
	var c: Vector2 = rd["c"]
	var foot := Geometry2D.get_closest_point_to_segment_uncapped(c, points[ends[0]], points[ends[1]])
	if foot.distance_to(c) < 0.0001:
		return {}
	var toward := (foot - c).normalized()
	return _linear_between(foot, c + toward * float(rd["r"]) * (1.0 if side == "min" else -1.0), place)


func perp_spec(point_id: String, line_id: String, place := {}) -> Dictionary:
	var lp := _line_points(line_id)
	if not points.has(point_id) or not points.has(lp[0]) or not points.has(lp[1]):
		return {}
	var p: Vector2 = points[point_id]
	var foot := Geometry2D.get_closest_point_to_segment_uncapped(p, points[lp[0]], points[lp[1]]) # (the line's extension: a point beyond its end is measured to it)
	var spec := {"kind": "perp", "a": p, "b": foot}
	var lp_place := _linear_place(place)
	if not lp_place.is_empty():
		spec["place"] = lp_place
	return spec


func line_distance_spec(l1: String, l2: String, place := {}) -> Dictionary:
	## The distance between two parallel lines: across from the first line's middle to its foot on the second. A saved placement moves the dimension line along
	## the first line (`offset`) and the label across (`along`).
	var p1 := _line_points(l1)
	var p2 := _line_points(l2)
	if not points.has(p1[0]) or not points.has(p1[1]) or not points.has(p2[0]) or not points.has(p2[1]):
		return {}
	var a0: Vector2 = points[p1[0]]
	var a1: Vector2 = points[p1[1]]
	if a0.distance_to(a1) < 0.0001:
		return {}
	var mid := (a0 + a1) * 0.5
	var foot := Geometry2D.get_closest_point_to_segment_uncapped(mid, points[p2[0]], points[p2[1]])
	if mid.distance_to(foot) < 0.0001:
		return {}
	var spec := {"kind": "perp", "a": mid, "b": foot}
	var lp_place := _linear_place(place)
	if not lp_place.is_empty():
		spec["u"] = (a1 - a0).normalized()
		spec["place"] = lp_place
	return spec


func _is_internal_angle(c: Dictionary) -> bool:
	## A polygon holds its corners with an angle between each pair of its own (construction) centre-to-corner lines: part of the shape,
	## not a dimension anyone typed, so it is not drawn.
	for id in shapes:
		var radial: Array = shapes[id].get("radial_line_ids", [])
		if radial.has(str(c.get("line1_id", ""))) and radial.has(str(c.get("line2_id", ""))):
			return true
	return false


# --- Constraint state (S3): fully / under / over constrained, what the solver reported failed ---------------

func _note_state() -> void:
	## Remembers the state after a solve; a sketch that has just become fully constrained says so (the editor ticks the hand).
	var state := constraint_state()
	if _state_sketch == sketch_id and state == "full" and _last_state != "full":
		fully_constrained.emit()
	_state_sketch = sketch_id
	_last_state = state


func _kind_of_id(id: String) -> String:
	## "point" | "line" | "circle" | "arc" | "ellipse" | "ellipse_arc" | "spline" | "text" for an id of this sketch, "" for none of them.
	if points.has(id):
		return "point"
	for kind in ["line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]:
		if _entity_dict(kind).has(id):
			return kind
	return ""


func _ids_named_by(c: Dictionary) -> Array:
	## Every id (point or entity) a constraint's fields name, whatever the field is called (`line_id`, `entity1_id`, `point_ids`, `center1_point_id`, ...).
	var out: Array = []
	for key in c:
		if str(key) == "id":
			continue
		var v = c[key]
		if v is String:
			if _kind_of_id(v) != "":
				out.append(v)
		elif v is Array:
			for item in v:
				if item is String and _kind_of_id(item) != "":
					out.append(item)
	return out


func constraint_point_ids(c: Dictionary) -> Array:
	## The points a constraint holds: the ones it names plus the points of the entities it names.
	var seen := {}
	for id in _ids_named_by(c):
		var kind := _kind_of_id(id)
		if kind == "point":
			seen[id] = true
		else:
			for pid in _entity_point_ids(kind, _entity_dict(kind)[id]):
				if str(pid) != "":
					seen[str(pid)] = true
	return seen.keys()


func constraint_held(constraint_id: String) -> Dictionary:
	## What picking or hovering a constraint's glyph / label should light: {"kind:id": true} for the points and entities it names ("point:p1", "line:l2").
	var out := {}
	var c: Dictionary = constraints.get(constraint_id, {})
	for id in _ids_named_by(c):
		out["%s:%s" % [_kind_of_id(id), id]] = true
	return out


func failed_point_ids() -> Dictionary:
	## id -> true for the points of every constraint the last solve reported failed (red in the view).
	var out := {}
	for cid in failed_constraint_ids:
		for pid in constraint_point_ids(constraints.get(str(cid), {})):
			out[pid] = true
	return out


func failed_entity_ids() -> Dictionary:
	## id -> true for each line, circle, arc ... with a point in failed_point_ids().
	var out := {}
	var red := failed_point_ids()
	if red.is_empty():
		return out
	for kind in ["line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]:
		var dict := _entity_dict(kind)
		for id in dict:
			for pid in _entity_point_ids(kind, dict[id]):
				if red.has(str(pid)):
					out[id] = true
					break
	return out


func has_geometry() -> bool:
	return not (lines.is_empty() and circles.is_empty() and arcs.is_empty() and ellipses.is_empty() and ellipse_arcs.is_empty() and splines.is_empty() and texts.is_empty())


func is_grounded() -> bool:
	## True when some drawn geometry is tied (through entities and constraints) to the origin, a fixed point or a point of the part. A fully dimensioned
	## shape floating free has a DOF of 0 too (the solver counts a whole-body move as no freedom), so the DOF alone must not say "fully constrained".
	var parent := {}
	var find := func(x: String) -> String:
		var r := x
		while parent.get(r, r) != r:
			r = parent[r]
		var c := x
		while parent.get(c, c) != r: # compress
			var nxt: String = parent[c]
			parent[c] = r
			c = nxt
		return r
	var link := func(ids: Array) -> void:
		var first := ""
		for id in ids:
			var sid := str(id)
			if sid == "":
				continue
			if first == "":
				first = sid
			else:
				parent[find.call(sid)] = find.call(first)
	for kind in ["line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]:
		var dict := _entity_dict(kind)
		for id in dict:
			link.call(_entity_point_ids(kind, dict[id]))
	for id in shapes:
		link.call(shapes[id].get("own_point_ids", []))
	for cid in constraints:
		link.call(constraint_point_ids(constraints[cid]))
	var seeds: Array = []
	if origin_id != "":
		seeds.append(origin_id)
	for pid in point_locked:
		if point_locked[pid]:
			seeds.append(pid)
	for pid in reference_ids:
		if points.has(pid):
			seeds.append(pid)
	var grounded := {}
	for pid in seeds:
		grounded[find.call(str(pid))] = true
	for kind in ["line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]:
		var dict := _entity_dict(kind)
		for id in dict:
			for pid in _entity_point_ids(kind, dict[id]):
				if str(pid) != "" and not seeds.has(str(pid)) and grounded.has(find.call(str(pid))):
					return true
	return false


func constraint_state() -> String:
	## "" (unknown, or nothing drawn yet) | "over" (the solve did not converge) | "full" (nothing left to move, and tied to the origin) | "under".
	if dof < 0 or not has_geometry():
		return ""
	if not converged:
		return "over"
	if dof <= 0 and is_grounded():
		return "full"
	return "under"


func constraint_summary() -> String:
	## One short phrase for the status line: "Fully constrained", "3 DOF left" or "Over-constrained: red parts conflict" ("" while unknown).
	match constraint_state():
		"full":
			return "Fully constrained."
		"over":
			return "Over-constrained: the red parts conflict."
		"under":
			return "%d DOF left." % maxi(dof, 1) if dof > 0 else "Not tied to the origin yet."
	return ""


func fix_constraints_for(picked: Array = selection) -> Array:
	## Ids of the Fix constraints that hold something in `picked` (what Unfix removes).
	var mine := {}
	for e in picked:
		var kind := str(e.get("kind", ""))
		var id := str(e.get("id", ""))
		if kind == "point":
			mine[id] = true
		elif _entity_dict(kind).has(id):
			for pid in _entity_point_ids(kind, _entity_dict(kind)[id]):
				mine[str(pid)] = true
	var out: Array = []
	for cid in constraints:
		if str(constraints[cid].get("type", "")) != "fixed":
			continue
		for pid in constraints[cid].get("point_ids", []):
			if mine.has(str(pid)):
				out.append(str(cid))
				break
	return out


func unfix_selection() -> Dictionary:
	## Select's Unfix: removes the Fix constraints that hold what is picked (one undo step puts them back). {ok, message}.
	if busy:
		return {"ok": false, "message": ""}
	var ids := fix_constraints_for()
	if ids.is_empty():
		return {"ok": false, "message": "Nothing picked is fixed."}
	busy = true
	var calls: Array = []
	var failed := ""
	for cid in ids:
		var c: Dictionary = (constraints.get(cid, {}) as Dictionary).duplicate(true)
		var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/constraints/" + cid, null)
		if r["ok"]:
			var owners: Array = _fix_owners(c.get("point_ids", []))
			for owner in owners: # (undo fixes the same thing again: the entity those points make up, else each point)
				var body := {"type": "fixed", "entity_id": str(owner)}
				if owners.size() == 1 and number_of(cid) > 0:
					body["number"] = number_of(cid) # the one Fix it makes again keeps its name
				calls.append([HTTPClient.METHOD_POST, SKETCH + sketch_id + "/constraints", body])
		else:
			failed = str(r["error"])
	selection.clear()
	ghosts.clear()
	if not calls.is_empty():
		_undo.append({"label": "unfix", "calls": calls})
	await refresh(false)
	busy = false
	if failed != "":
		status.emit("Couldn't unfix: %s" % failed)
	return {"ok": failed == "" and not calls.is_empty(), "message": failed}


const CONSTRAINT_GLYPHS := {"horizontal": "H", "vertical": "V", "parallel": "//", "perpendicular": "|_", "equal_length": "=", "equal_radius": "=", "collinear": "co",
	"concentric": "(o)", "point_on_line": "on", "point_on_circle": "on", "at_midpoint": "M", "tangent": "T", "curve_tangent": "T", "spline_tangent": "T", "point_on_ellipse": "on", "fixed": "F"} ## plain letters: they always have a glyph in the font


func _curve_with_centre(point_id: String) -> String:
	## The circle or arc whose centre is `point_id` ("" for none): the backend names Equal radius by centre and rim POINTS, not by entity.
	for id in circles:
		if str(circles[id]["c"]) == point_id:
			return id
	for id in arcs:
		if str(arcs[id]["c"]) == point_id:
			return id
	return ""


func _fix_owners(point_ids: Array) -> Array:
	## Where a Fix glyph sits: the entity those points make up when there is one (a line's middle, a circle's centre), else on each point. The backend
	## sends the resolved `point_ids`, never the entity the user picked.
	if point_ids.size() <= 1:
		return point_ids
	for kind in ["line", "circle", "arc"]:
		var dict := _entity_dict(kind)
		for id in dict:
			var mine := _entity_point_ids(kind, dict[id])
			var all := true
			for pid in point_ids:
				if not mine.has(pid):
					all = false
					break
			if all:
				return [id]
	return point_ids


func constraint_items() -> Array:
	## The sketch's constraints as glyphs to draw beside what they hold: [{id, text, uv, normal, owner}] (owner: the entity the glyph sits on, so
	## several on one line stack). Coincident points are left out (the shared point is the glyph) and dimensions are dimension_items()'s.
	var out: Array = []
	for id in constraints:
		out.append_array(glyph_items_of(str(id), constraints[id]))
	return out


func glyph_items_of(id: String, c: Dictionary) -> Array:
	## The glyphs of one constraint (constraint_items()'s rows for it, in its order): none for a dimension or a coincident pair.
	var out: Array = []
	var type := str(c.get("type", ""))
	if not CONSTRAINT_GLYPHS.has(type):
		return out
	var text: String = CONSTRAINT_GLYPHS[type]
	var owners: Array = []
	match type:
		"horizontal", "vertical":
			owners = [str(c.get("line_id", ""))]
		"parallel", "perpendicular", "equal_length", "collinear":
			owners = [str(c.get("line1_id", "")), str(c.get("line2_id", ""))]
		"concentric":
			owners = [str(c.get("entity1_id", "")), str(c.get("entity2_id", ""))]
		"equal_radius":
			owners = [_curve_with_centre(str(c.get("center1_point_id", ""))), _curve_with_centre(str(c.get("center2_point_id", "")))]
		"point_on_line", "at_midpoint", "point_on_circle", "point_on_ellipse":
			owners = [str(c.get("point_id", ""))]
		"tangent":
			owners = [str(c.get("line_id", ""))]
		"curve_tangent":
			owners = [str(c.get("shared_point_id", ""))]
		"spline_tangent":
			owners = [str(c.get("segment_a_p3", ""))] # the join of the two segments
		"fixed":
			owners = _fix_owners(c.get("point_ids", []))
	for owner in owners:
		if str(owner) == "":
			continue
		var spot := _glyph_spot(str(owner))
		if not spot.is_empty():
			out.append({"id": id, "text": text, "uv": spot["uv"], "normal": spot["normal"], "owner": owner})
	return out


func _glyph_spot(entity_id: String) -> Dictionary:
	## Where a constraint glyph on this entity sits: a line's middle (pushed off to its side), a point, a circle's or arc's centre.
	if lines.has(entity_id):
		var l: Dictionary = lines[entity_id]
		if points.has(l["a"]) and points.has(l["b"]):
			var d: Vector2 = (points[l["b"]] - points[l["a"]]).normalized()
			return {"uv": (points[l["a"]] + points[l["b"]]) * 0.5, "normal": Vector2(-d.y, d.x)}
	elif points.has(entity_id):
		return {"uv": points[entity_id], "normal": Vector2(0.7, 0.7)}
	elif circles.has(entity_id) and points.has(circles[entity_id]["c"]):
		return {"uv": points[circles[entity_id]["c"]], "normal": Vector2(0.7, 0.7)}
	elif arcs.has(entity_id) and points.has(arcs[entity_id]["c"]):
		return {"uv": points[arcs[entity_id]["c"]], "normal": Vector2(0.7, 0.7)}
	return {}


func dimension_items() -> Array:
	## What the sketch's existing (typed, not provisional) dimensions look like: [{id, spec, text}], for sketch_view.gd to draw as a drawing
	## draws them. A circle's / arc's own size dimension is a radius; a distance between two points is linear, horizontal or vertical; the part D types
	## (arc length, two angles, three distances to circles) have their own. A saved label placement is honoured for every type; unplaced, the layout is automatic.
	var out: Array = []
	var radius_of := _radius_owners()
	for id in constraints:
		var item := _dimension_item(str(id), constraints[id], radius_of)
		if not item.is_empty():
			out.append(item)
	for item in driven_items():
		out.append(item)
	return out


func dimension_item_for(id: String) -> Dictionary:
	## One constraint's row of dimension_items() ({} when it is not a drawn dimension): what a point drag's frame asks for the dimensions a moved point touches.
	if not constraints.has(id):
		return {}
	return _dimension_item(id, constraints[id], _radius_owners())


func _radius_owners() -> Dictionary:
	## radius constraint id -> ["circle" | "arc", id]
	var radius_of := {}
	for id in circles:
		radius_of[str(circles[id].get("k", ""))] = ["circle", id]
	for id in arcs:
		radius_of[str(arcs[id].get("k", ""))] = ["arc", id]
	return radius_of


func _dimension_item(id: String, c: Dictionary, radius_of: Dictionary) -> Dictionary:
	## One constraint as a drawn dimension {id, spec, text}, {} when it is not one (or what it measures is not here).
	var type := str(c.get("type", ""))
	var place: Dictionary = label_override.get(id, _place_of(c))
	var spec := {}
	var text := ""
	match type:
		"distance":
			if bool(c.get("provisional", false)) or float(c.get("distance", 0.0)) <= 0.005: # (a zero distance is a shape's own structure, e.g. a circle's cardinal points)
				return {}
			var value := float(c["distance"])
			var axis := ellipse_axis_line(id)
			if radius_of.has(id):
				var shown_diameter := bool(diameter_shown.get(id, false))
				spec = circle_spec("diameter" if shown_diameter else "radius", str((radius_of[id] as Array)[1]), place)
				text = dimension_text("diameter" if shown_diameter else "radius", value * (2.0 if shown_diameter else 1.0))
			elif not axis.is_empty():
				# a full ellipse's axis: read as the full axis (the default, as the flat app draws it) it runs tip to tip and the number is twice the stored (centre to tip)
				# value; read as the semi-axis it runs centre to tip and the number is the stored value (F5, C4). Placement kind `ellipse_axis` {offset, along} either way.
				var full_axis := shows_full_axis(id)
				spec = {"kind": "linear", "a": axis["a"] if full_axis else ((axis["a"] as Vector2) + (axis["b"] as Vector2)) * 0.5, "b": axis["b"]}
				var axis_place := _linear_place(place)
				if not axis_place.is_empty():
					spec["place"] = axis_place
				text = dimension_text("linear", value * (2.0 if full_axis else 1.0))
			elif not ellipse_arc_axis(id).is_empty():
				# an elliptical arc's axis, laid out radially as the flat app does (placement kind `radius`, {angle, leg}): semi is a radius leader from the centre to the
				# arc's tip, full the circle-diameter style through the centre (F5, C4)
				var arc_axis := ellipse_arc_axis(id)
				var full_axis := shows_full_axis(id)
				var tip_pt: Vector2 = points.get(arc_axis["tip"], Vector2.ZERO)
				var centre_pt: Vector2 = points.get(arc_axis["c"], Vector2.ZERO)
				spec = radial_spec("diameter" if full_axis else "radius", centre_pt, tip_pt, place)
				text = dimension_text("diameter" if full_axis else "radius", value * (2.0 if full_axis else 1.0))
			elif points.has(str(c.get("point_a_id", ""))) and points.has(str(c.get("point_b_id", ""))):
				spec = {"kind": str(c.get("orientation", "linear")), "a": points[c["point_a_id"]], "b": points[c["point_b_id"]]}
				var p := _linear_place(place)
				if not p.is_empty():
					spec["place"] = p
				text = dimension_text("linear", value)
		"point_line_distance":
			spec = perp_spec(str(c.get("point_id", "")), str(c.get("line_id", "")), place)
			text = dimension_text("linear", float(c.get("distance", 0.0)))
		"line_distance":
			spec = line_distance_spec(str(c.get("line1_id", "")), str(c.get("line2_id", "")), place)
			text = dimension_text("linear", float(c.get("distance", 0.0)))
		"angle":
			if not _is_internal_angle(c):
				var value := float(c.get("angle_degrees", 0.0))
				spec = angle_spec(str(c.get("line1_id", "")), str(c.get("line2_id", "")), value, _quadrant_of(c), place)
				text = dimension_text("angle", value)
		"horizontal_angle":
			var value := float(c.get("angle_degrees", 0.0))
			spec = horizontal_angle_spec(str(c.get("line_id", "")), _quadrant_of(c), value, place)
			text = dimension_text("angle", value)
		"point_angle":
			spec = point_angle_spec(str(c.get("vertex_point_id", "")), str(c.get("point1_id", "")), str(c.get("point2_id", "")), _quadrant_of(c), place)
			text = dimension_text("angle", float(c.get("angle_degrees", 0.0)))
		"arc_length":
			spec = arc_length_spec(str(c.get("arc_id", "")), place)
			text = dimension_text("arc_length", float(c.get("length", 0.0)))
		"point_circle_distance":
			spec = point_circle_spec(str(c.get("point_id", "")), str(c.get("circle_or_arc_id", "")), str(c.get("side", "min")), place)
			text = dimension_text("linear", float(c.get("distance", 0.0)))
		"circle_distance":
			spec = circle_circle_spec(str(c.get("entity1_id", "")), str(c.get("entity2_id", "")), str(c.get("side", "min")), place)
			text = dimension_text("linear", float(c.get("distance", 0.0)))
		"line_circle_distance":
			spec = line_circle_spec(str(c.get("line_id", "")), str(c.get("circle_or_arc_id", "")), str(c.get("side", "min")), place)
			text = dimension_text("linear", float(c.get("distance", 0.0)))
	if spec.is_empty():
		return {}
	return {"id": id, "spec": spec, "text": text}


static func _quadrant_of(c: Dictionary) -> int:
	## The saved quadrant of an angle dimension (0-3), -1 when it has none.
	var q: Variant = c.get("quadrant")
	return int(q) if q != null and float(q) >= 0.0 else -1


func driven_items() -> Array:
	## The reference dimensions the backend holds for this sketch, as drawn items: [{id, spec, text: "(12.5)", driven: true}]. The number is the backend's own
	## (calculated from where the things are now, so it follows the part); one whose entities are not in the picture is left out.
	var out: Array = []
	for d in ref_dims:
		var spec := _ref_dim_spec(d)
		if spec.is_empty() or d.get("value") == null:
			continue
		out.append({"id": str(d["id"]), "spec": spec, "text": "(%s)" % dimension_text(_dimension_kind(_ref_dim_key(d)), float(d["value"])), "driven": true})
	return out


static func _ref_dim_key(d: Dictionary) -> String:
	## The candidate key a stored reference dimension is laid out like (the catalogue's: h, v, linear, lineDistance, perpendicular, radius ...; a part D kind keeps its
	## own name): what dimension_layout draws it as.
	var types: Array = (d.get("refs", []) as Array).map(func(r): return str(r.get("type", "")))
	match str(d.get("kind", "")):
		"radius", "diameter", "angle", "arc_length", "horizontal_angle", "point_angle", "min_distance", "max_distance":
			return str(d["kind"])
		"horizontal":
			return "h"
		"vertical":
			return "v"
		"distance":
			if types == ["line"]:
				return "length"
			if types == ["point", "point"]:
				return "linear"
			if types == ["line", "line"]:
				return "lineDistance"
			return "perpendicular"
	return "linear"


func _ref_dim_spec(d: Dictionary) -> Dictionary:
	## How dimension_layout draws a stored reference dimension: the same spec a ghost of the same entities carries. {} if what it measures is not here.
	var refs: Array = d.get("refs", [])
	var selected: Array = refs.map(func(r): return {"kind": str(r["type"]), "id": str(r["id"])})
	var key := _ref_dim_key(d)
	var part_d: Variant = _part_d_ref_spec(key, refs, float(d.get("value", -1.0)) if d.get("value") != null else -1.0)
	if part_d != null:
		return part_d as Dictionary
	for g in _ghosts_raw(selected):
		if g["key"] == key and not (g.get("spec", {}) as Dictionary).is_empty():
			return g["spec"]
	if refs.size() == 1 and str(refs[0]["type"]) == "line" and str(d.get("kind", "")) in ["horizontal", "vertical"]:
		var ends := _line_points(str(refs[0]["id"])) # a line's own horizontal / vertical extent: not a candidate VR offers, but the flat app can make one
		if points.has(ends[0]) and points.has(ends[1]):
			return {"kind": str(d["kind"]), "a": points[ends[0]], "b": points[ends[1]]}
	return {}


func _part_d_ref_spec(key: String, refs: Array, value: float) -> Variant:
	## The layout of a stored reference dimension of a part D kind (arc length, angle to horizontal, three-point angle, min / max distance), automatic as it has
	## no saved placement; null for another kind.
	var ids: Array = refs.map(func(r): return str(r["id"]))
	var types: Array = refs.map(func(r): return str(r["type"]))
	match key:
		"arc_length":
			return arc_length_spec(str(ids[0]))
		"horizontal_angle":
			return horizontal_angle_spec(str(ids[0]), -1, value)
		"point_angle":
			return point_angle_spec(str(ids[0]), str(ids[1]), str(ids[2]))
		"min_distance", "max_distance":
			var side := "min" if key == "min_distance" else "max"
			if types.has("point") and types.size() == 2:
				var k := types.find("point")
				return point_circle_spec(str(ids[k]), str(ids[1 - k]), side)
			if types.has("line") and types.size() == 2:
				var k := types.find("line")
				return line_circle_spec(str(ids[k]), str(ids[1 - k]), side)
			if types.size() == 2:
				return circle_circle_spec(str(ids[0]), str(ids[1]), side)
			return {}
	return null


static func _dimension_kind(key: String) -> String:
	## How a candidate's or reference dimension's number is written (dimension_text's kinds).
	return dimension_kind_of_key(key)


func keep_driven(key: String) -> Dictionary:
	## The user pointed at a driven candidate: keep it as a reference dimension. The backend stores it (POST .../reference-dimensions: it measures the pinned
	## things and never reaches the solver), so it lasts: closing and reopening the sketch, saving and opening the file, the flat app. It is drawn in brackets and
	## follows the part. Undo deletes it (and the backend frees a helper only it kept). A refusal (the backend's reason) leaves nothing.
	var g := ghost(key)
	if g.is_empty() or not bool(g.get("driven", false)):
		return {"ok": false, "message": ""}
	if str(g.get("ref", "")) == "":
		return {"ok": false, "message": ""}
	var request := {"kind": str(g["ref"]), "refs": selection.map(func(e): return {"type": str(e["kind"]), "id": str(e["id"])})}
	var made := await _post(SKETCH + sketch_id + "/reference-dimensions", request)
	if not made["ok"]:
		var message := "Couldn't keep that dimension: %s" % str(made["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	var id := str((made["json"] as Dictionary)["id"])
	_undo.append({"label": "reference dimension", "calls": [[HTTPClient.METHOD_DELETE, SKETCH + sketch_id + "/reference-dimensions/" + id]]})
	selection.clear()
	ghosts.clear()
	await refresh(false)
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


func save_label(id: String, place: Dictionary) -> Dictionary:
	## Saves where a dimension's label sits (PUT .../constraints/{id}/label; the placement is the flat app's too, section 3.2): a new dimension's drop and a label dragged
	## afterwards both come here. The drawing takes it at once; Undo puts the old placement back (or none). {ok, message}.
	if id == "" or place.is_empty() or not constraints.has(id):
		return {"ok": false, "message": ""}
	var old: Dictionary = _place_of(constraints[id]).duplicate()
	var kept_show: Variant = old.get("show") # the saved reading (Radius / Diameter, semi / full) is not part of the placement: Undo's PUT of `old` must not re-send it, and this PUT does not lose it (the backend keeps it)
	old.erase("show")
	var saved: Dictionary = await api.call(HTTPClient.METHOD_PUT, SKETCH + sketch_id + "/constraints/" + id + "/label", place)
	if not saved["ok"]:
		var message := "Couldn't save the label's place: %s" % str(saved["error"])
		status.emit(message)
		return {"ok": false, "message": message}
	var now: Dictionary = place.duplicate() # drawn there at once (the next solve brings it back from the backend too)
	if kept_show != null and not now.has("show"):
		now["show"] = kept_show
	if now.has("show"):
		_note_show(id, str(now["show"]))
	constraints[id]["label"] = now
	label_override.erase(id)
	changed.emit()
	return {"ok": true, "message": "", "old": old}


func move_label(id: String, place: Dictionary) -> Dictionary:
	## A label dragged and dropped (S6, F5): its new placement is saved as above and Undo puts the old one back (or the automatic place, when it had none).
	if busy:
		label_override.erase(id)
		changed.emit()
		return {"ok": false, "message": ""}
	var saved := await save_label(id, place)
	if bool(saved["ok"]):
		var old: Dictionary = saved["old"]
		var path := SKETCH + sketch_id + "/constraints/" + id + "/label"
		_undo.append({"label": "label move", "calls": [[HTTPClient.METHOD_PUT, path, old]] if not old.is_empty() else [[HTTPClient.METHOD_DELETE, path]]})
	else:
		label_override.erase(id)
		changed.emit()
	return saved


const SHAPE_LIST_ROUTES := {"circle": "circles", "arc": "arcs", "ellipse": "ellipses", "ellipse_arc": "ellipse-arcs", "rectangle": "rectangles", "polygon": "polygons", "slot": "slots"}


func load_shape_structure(point_id: String) -> void:
	## F8: the sketch state's entities do not carry `structural_constraint_ids` (only the per-family GET routes do), and the hybrid drag needs them to tell the shape's own
	## constraints from the user's. One GET of the family's list, at the press, for the shape the point belongs to; its entry in `shape_records` gets the list. A failed GET
	## leaves the record without it (the spec's "structural ids unknown": a plain drag).
	var exact := {}
	for id in points:
		exact[str(id)] = [points[id].x, points[id].y]
	var exists := {}
	for id in lines:
		exists[str(id)] = true
	for id in arcs:
		exists[str(id)] = true
	var shape: Dictionary = ShapeProposals.locate(shape_records, exact, exists, point_id)
	if shape.is_empty() or not SHAPE_LIST_ROUTES.has(shape["kind"]):
		return
	var r: Dictionary = await api.call(HTTPClient.METHOD_GET, SKETCH + sketch_id + "/" + str(SHAPE_LIST_ROUTES[shape["kind"]]), null)
	if not bool(r.get("ok", false)) or not (r.get("json") is Array):
		return
	for e in r["json"]:
		if e is Dictionary and str(e.get("id", "")) == str(shape["id"]) and e.has("structural_constraint_ids") and shape_records.has(shape["id"]):
			_structure[str(shape["id"])] = _strings(e["structural_constraint_ids"])
			shape_records[shape["id"]]["structural_constraint_ids"] = _structure[str(shape["id"])]


func rigidity() -> RefCounted:
	## The topological rigidity count (sketch_rigidity.gd, F7) of the sketch as it is. Fixed = the origin, the locked points and the points of a Fix; trust = the last solve
	## converged with dof >= 0 (so a redundant but consistent set is not called over-constrained). No geometry is read; recomputed per call (a refresh or a press makes a few).
	var fixed := {}
	if origin_id != "":
		fixed[origin_id] = true
	for id in point_locked:
		if bool(point_locked[id]):
			fixed[str(id)] = true
	for cid in constraints:
		var c: Dictionary = constraints[cid]
		if str(c.get("type", "")) == "fixed":
			for pid in constraint_point_ids(c):
				fixed[str(pid)] = true
	return SketchRigidity.analyse(points.keys(), fixed.keys(), lines, constraints.values(), converged and dof >= 0)


func point_rigidity(id: String) -> String:
	## What the rigidity count says of a point: "over", "pinned" (tied to a fixed point by coincident / concentric links), "fully" (fully constrained) or "free".
	var r: RefCounted = rigidity()
	if r.is_over(id):
		return "over"
	if r.is_pinned(id):
		return "pinned"
	return "fully" if r.is_fully(id) else "free"


func sketch_grounded() -> bool:
	## The rigidity count grounds at least one point (the pre-grab rule's whole-sketch case).
	return (rigidity() as RefCounted).any_grounded


func contradictory_points() -> Dictionary:
	## id -> true: the endpoints of a line that is both horizontal and vertical, or of either of two lines that are both parallel and perpendicular (forced over-constrained,
	## rigidity spec 4 and projector spec 13.5).
	var kinds := {} ## line id -> {type: true}; "a|b" -> {type: true} for a pair of lines
	var by_ends := {} ## "start|end" -> line id (a Horizontal / Vertical made between two points names no line; the line they end is the one meant)
	for lid in lines:
		by_ends["%s|%s" % [lines[lid]["a"], lines[lid]["b"]]] = str(lid)
		by_ends["%s|%s" % [lines[lid]["b"], lines[lid]["a"]]] = str(lid)
	for cid in constraints:
		var c: Dictionary = constraints[cid]
		var t := str(c.get("type", ""))
		if t == "horizontal" or t == "vertical":
			var lid := str(c.get("line_id", ""))
			if lid == "":
				lid = str(by_ends.get("%s|%s" % [c.get("point_a_id", ""), c.get("point_b_id", "")], ""))
			if lid != "":
				kinds[lid] = kinds.get(lid, {})
				kinds[lid][t] = true
		elif t == "parallel" or t == "perpendicular":
			var key := "|".join(PackedStringArray([str(c.get("line1_id", "")), str(c.get("line2_id", ""))]))
			var rev := "|".join(PackedStringArray([str(c.get("line2_id", "")), str(c.get("line1_id", ""))]))
			kinds[key] = kinds.get(key, {})
			kinds[key][t] = true
			kinds[rev] = kinds[key]
	var out := {}
	for key in kinds:
		var both: bool = (kinds[key].has("horizontal") and kinds[key].has("vertical")) or (kinds[key].has("parallel") and kinds[key].has("perpendicular"))
		if not both:
			continue
		for lid in str(key).split("|"):
			if lines.has(lid):
				out[str(lines[lid]["a"])] = true
				out[str(lines[lid]["b"])] = true
	return out


func on_contradictory_line(point_id: String) -> bool:
	## The point is on a line that is both horizontal and vertical, or on either of two lines that are both parallel and perpendicular (13.5 step 2).
	return contradictory_points().has(point_id)


func entity_states() -> Dictionary:
	## "kind:id" -> "over" | "fully" | "free" for every line, circle, arc, ellipse, elliptical arc, spline and text (F7, rigidity spec 4). Forced-over points = the points of
	## a constraint the last solve reported failed, plus the endpoints of a line both horizontal and vertical or of two lines both parallel and perpendicular. Then the pair
	## rule (over when a defining pair is over by the count or a defining point is forced; fully when every pair is fully constrained), then the whole-sketch override: a
	## sketch fully constrained as a whole (converged, dof <= 0, geometry, something grounded) makes every entity that is not over fully constrained. Colours are the view's.
	var r: RefCounted = rigidity()
	var whole: bool = has_geometry() and converged and dof <= 0 and r.any_grounded
	var forced := failed_point_ids()
	forced.merge(contradictory_points())
	var out := {}
	for kind in ["line", "circle", "arc", "ellipse", "ellipse_arc", "spline", "text"]:
		var source: Dictionary = _entity_dict(kind)
		for id in source:
			var e: Dictionary = source[id]
			var pts: Array = []
			match kind:
				"line":
					pts = [e.get("a", ""), e.get("b", "")]
				"circle":
					pts = [e.get("c", ""), e.get("p", "")]
				"arc":
					pts = [e.get("c", ""), e.get("s", ""), e.get("e", "")]
				"ellipse":
					pts = [e.get("c", ""), e.get("ma", ""), e.get("mi", "")]
				"ellipse_arc":
					pts = [e.get("c", ""), e.get("ma", ""), e.get("mi", ""), e.get("s", ""), e.get("e", "")]
				"spline":
					pts = e.get("through", [])
				"text":
					pts = [e.get("anchor", "")]
			var ids: Array = pts.map(func(v: Variant) -> String: return str(v)).filter(func(v: String) -> bool: return v != "")
			var state := "free"
			if ids.size() >= (1 if kind == "text" else 2):
				state = r.entity_state(SketchRigidity.pairs_of(kind, ids))
				for pid in ids:
					if forced.has(pid):
						state = "over"
						break
				if whole and state != "over":
					state = "fully"
			out["%s:%s" % [kind, id]] = state
	return out


func restore_points() -> void:
	## The points as the backend last said (a point drag lays its frames over `points`; this takes them off again).
	for id in point_xy:
		points[id] = Vector2(point_xy[id][0], point_xy[id][1])


func drop_points(drop: Dictionary) -> Dictionary:
	## A sketch-point drag dropped (S10, F6): `drop` is PointDrag.finish()'s {updates: id -> [x, y], anchors, old, unsupported}. Sent as the wish, as the flat app does it:
	## ONE solve-and-refresh with `point_updates` (written first, all or nothing) and `anchor_point_ids` (the grabbed points stay where they were dropped while the
	## rest settles around them); the backend's answer is the truth (points, DOF colours, the failed list). A conflict it leaves is kept, red (3.3: only a conflict
	## right after making something is taken back), and Undo puts every point that moved back. Returns {ok, message}.
	var updates: Dictionary = drop["updates"]
	if updates.is_empty():
		restore_points()
		changed.emit()
		return {"ok": true, "message": "", "moved": false} # nothing moved: the editor says so rather than "Point moved."
	if busy:
		restore_points()
		changed.emit()
		return {"ok": false, "message": "The sketch was busy: the point went back."}
	busy = true
	var before: Dictionary = point_xy.duplicate(true)
	var wish: Array = []
	for id in updates:
		wish.append({"id": str(id), "x": float(updates[id][0]), "y": float(updates[id][1])})
	var ok := await refresh(false, {"anchor_point_ids": drop["anchors"], "point_updates": wish})
	busy = false
	if not ok:
		restore_points()
		changed.emit()
		return {"ok": false, "message": "The point could not be moved."}
	var back: Array = []
	for id in before:
		if point_xy.has(id) and (absf(point_xy[id][0] - before[id][0]) > 1e-9 or absf(point_xy[id][1] - before[id][1]) > 1e-9):
			back.append({"id": str(id), "x": before[id][0], "y": before[id][1]})
	if not back.is_empty():
		_undo.append({"label": "point move", "calls": [[HTTPClient.METHOD_POST, SKETCH + sketch_id + "/solve-and-refresh", {"anchor_point_ids": [], "point_updates": back}]]})
	return {"ok": true, "moved": true, "message": "" if converged else "Moved, but the sketch no longer solves: the red parts say where. Undo puts it back."}


func confirm_ghost(key: String, value: float, dropped: Dictionary = {}) -> Dictionary:
	## The user typed `value` (mm or degrees) for a dimension candidate. Returns {ok, message}. `dropped` (S5): the candidate as the Dimension tool's
	## drop froze it (dimension_preview.gd): its create body carries the side (quadrant) the laser chose, and its `place` is saved as the new
	## dimension's label placement (PUT .../constraints/{id}/label) once the dimension is kept, so it stays where it was dropped.
	var g := ghost(key)
	if g.is_empty():
		return {"ok": false, "message": ""}
	if not dropped.is_empty() and str(dropped.get("key", "")) == key:
		g = dropped
	if bool(g.get("driven", false)):
		return await keep_driven(key) # a reference dimension has no value to type: it measures
	if value <= 0.0:
		var msg := "A dimension has to be bigger than zero."
		status.emit(msg)
		return {"ok": false, "message": msg}
	if busy:
		return {"ok": false, "message": ""}
	busy = true
	var was_converged := converged
	var apply: Dictionary = g["apply"]
	var stored: float = value * float(apply.get("factor", 1.0))
	var r: Dictionary
	var calls: Array = []
	if apply.has("patch_id"):
		var patch: Dictionary = {"value": stored}
		var q: Variant = (apply.get("create", {}) as Dictionary).get("quadrant")
		if q != null:
			var qi := int(q)
			patch["quadrant"] = ((qi & 1) << 1) | ((qi & 2) >> 1) if bool(apply.get("swapped", false)) else qi # the side the laser chose, in the constraint's own line order
		r = await api.call(HTTPClient.METHOD_PATCH, SKETCH + sketch_id + "/constraints/" + str(apply["patch_id"]), patch)
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
	var made_id := str(r["json"]["id"]) if r["json"] is Dictionary and (r["json"] as Dictionary).has("id") else ""
	var kept := not (not calls.is_empty() and _taken_back(was_converged, [made_id]))
	if not kept:
		busy = false
		await undo()
		busy = true
		status.emit("That size conflicts with the other constraints, so it wasn't added.")
	var place: Dictionary = g.get("place", {})
	var cid := str(apply["patch_id"]) if apply.has("patch_id") else made_id
	if kept and cid != "":
		# the placement it was dropped at and the reading it was made with (Radius / Diameter, semi / full) go in one PUT: both are the dimension's label record. A reading
		# that is what the dimension reads anyway is not sent, so a dimension keeps the choice already saved on it.
		var body: Dictionary = place.duplicate() if not place.is_empty() and not bool(g.get("place_unsaved", false)) else {}
		var chosen := str(g.get("show", ""))
		if chosen != "" and chosen != show_of(cid):
			body["show"] = chosen
		if not body.is_empty():
			await save_label(cid, body)
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
	var labels: Dictionary = step.get("labels", {})
	var index := 0
	for entry in step["calls"]:
		var done: Dictionary = await api.call(int(entry[0]), str(entry[1]), entry[2] if entry.size() > 2 else null)
		if labels.has(index) and done["ok"] and done["json"] is Dictionary and (done["json"] as Dictionary).has("id"):
			await api.call(HTTPClient.METHOD_PUT, SKETCH + sketch_id + "/constraints/" + str(done["json"]["id"]) + "/label", labels[index])
		index += 1
	pending.clear()
	chain_first = ""
	selection.clear()
	ghosts.clear()
	await refresh(true)
	busy = was_busy
	return true
