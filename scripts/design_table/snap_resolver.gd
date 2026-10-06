extends RefCounted
## Where a laser point on the sketch sheet really lands. Pure maths over the sketch session's local model, no scene
## tree, so it is unit-tested on its own (tests/design_table_logic.gd).
##
## Order, like the flat sketcher's (client/lib/sketch/sketch_controller.dart, _pointIdAt):
##   1. an EXISTING POINT within the radius -> reuse it (the entity then shares it, which is what makes shapes join). The sketch's ORIGIN is one
##      of them (kind "origin"), so a line can start on it, a circle can be centred on it, and a dimension can start or end at it;
##   2. a VERTEX of the part, projected onto the sheet (the corners of the face you're sketching on, and every other corner of the part seen
##      along the plane's normal): the pick carries a `ref` and the session makes it a pinned point that follows the part when it is used;
##   3. a line's MIDPOINT;
##   4. the nearest spot ON a line, circle or arc (position only);
##   5. otherwise the free position.
## Only (1) carries an id and (2) a reference to the part's vertex. (3)-(4) snap the position exactly but make an ordinary new point: the flat
## app makes a real constraint for those, which a later step here can add.
##
## Axis inference for a line: with one end placed, a second end within AXIS_DEGREES of horizontal or vertical is
## pulled exactly onto the axis and flagged, so the session can add the Horizontal / Vertical constraint.
## The snap toggle on the console turns all of this off (`enabled` false): the position comes back untouched.

const AXIS_DEGREES := 4.0

enum Kind { FREE, POINT, VERTEX, MIDPOINT, CURVE, ORIGIN }

const NAMES := {Kind.FREE: "free", Kind.POINT: "point", Kind.VERTEX: "vertex", Kind.MIDPOINT: "midpoint", Kind.CURVE: "curve", Kind.ORIGIN: "origin"}


static func resolve(uv: Vector2, session, radius: float, enabled: bool, vertices: Array = [], line_start: Variant = null, refs: Variant = null) -> Dictionary:
	## {uv, id, kind (a name), infer, ref?}. `session` is a sketch_session.gd (points / lines / circles / arcs).
	## `vertices` are plain positions to snap to (Vector2s); `refs` is the part's projected geometry (part_references.gd), whose vertices are snapped
	## to as references. `line_start` is the first end of the line being drawn, if any.
	var out := {"uv": uv, "id": "", "kind": NAMES[Kind.FREE], "infer": ""}
	if not enabled or session == null:
		return out

	var best := radius
	for id in session.points:
		var d: float = uv.distance_to(session.points[id])
		if d <= best:
			best = d
			out = {"uv": session.points[id], "id": id, "kind": NAMES[Kind.POINT], "infer": ""}
	if out["id"] != "":
		if session.is_origin(str(out["id"])):
			out["kind"] = NAMES[Kind.ORIGIN] # the sketch's own origin: a real point, shown as such
		return out

	best = radius
	for v in vertices:
		var d: float = uv.distance_to(v)
		if d <= best:
			best = d
			out = {"uv": v, "id": "", "kind": NAMES[Kind.VERTEX], "infer": ""}
	if refs != null and session.references_ok:
		var rv: Dictionary = refs.nearest_vertex(uv, radius)
		if not rv.is_empty() and float(rv["distance"]) <= best:
			best = float(rv["distance"])
			out = {"uv": rv["uv"], "id": "", "kind": NAMES[Kind.VERTEX], "infer": "", "ref": {"kind": "vertex", "body": rv["body"], "index": rv["index"]}}
	if out["kind"] == NAMES[Kind.VERTEX]:
		return out

	best = radius
	for id in session.lines:
		var l: Dictionary = session.lines[id]
		if l.get("construction", false) or not session.points.has(l["a"]) or not session.points.has(l["b"]):
			continue
		var mid: Vector2 = (session.points[l["a"]] + session.points[l["b"]]) * 0.5
		var d := uv.distance_to(mid)
		if d <= best:
			best = d
			out = {"uv": mid, "id": "", "kind": NAMES[Kind.MIDPOINT], "infer": ""}
	if out["kind"] == NAMES[Kind.MIDPOINT]:
		return out

	best = radius * 0.6
	for id in session.lines:
		var l: Dictionary = session.lines[id]
		if not session.points.has(l["a"]) or not session.points.has(l["b"]):
			continue
		var near: Vector2 = Geometry2D.get_closest_point_to_segment(uv, session.points[l["a"]], session.points[l["b"]])
		var d := uv.distance_to(near)
		if d <= best:
			best = d
			out = {"uv": near, "id": "", "kind": NAMES[Kind.CURVE], "infer": ""}
	for id in session.circles:
		var c: Dictionary = session.circles[id]
		if not session.points.has(c["c"]) or not session.points.has(c["p"]):
			continue
		var centre: Vector2 = session.points[c["c"]]
		var r: float = centre.distance_to(session.points[c["p"]])
		var to: Vector2 = uv - centre
		if to.length() < 0.000001:
			continue
		var on_circle := centre + to.normalized() * r
		var d := uv.distance_to(on_circle)
		if d <= best:
			best = d
			out = {"uv": on_circle, "id": "", "kind": NAMES[Kind.CURVE], "infer": ""}
	if out["kind"] == NAMES[Kind.CURVE]:
		return out

	if line_start != null:
		var start: Vector2 = line_start
		var delta := uv - start
		if delta.length() > radius:
			var folded := fposmod(rad_to_deg(delta.angle()), 180.0) # a line and its reverse are the same line: 0..180
			var from_x := minf(folded, 180.0 - folded)
			var from_y := absf(folded - 90.0)
			if from_x <= AXIS_DEGREES:
				out = {"uv": Vector2(uv.x, start.y), "id": "", "kind": NAMES[Kind.FREE], "infer": "horizontal"}
			elif from_y <= AXIS_DEGREES:
				out = {"uv": Vector2(start.x, uv.y), "id": "", "kind": NAMES[Kind.FREE], "infer": "vertical"}
	return out
