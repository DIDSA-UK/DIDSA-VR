extends RefCounted
## Where a laser point on the sketch sheet really lands. Pure maths over the sketch session's local model, no scene
## tree, so it is unit-tested on its own (tests/design_table_logic.gd).
##
## Order, like the flat sketcher's (client/lib/sketch/sketch_controller.dart, _pointIdAt):
##   1. an EXISTING POINT within the radius -> reuse it (the entity then shares it, which is what makes shapes join);
##   2. a VERTEX of the part that lies on the sheet's plane (the corners of the face you're sketching on);
##   3. a line's MIDPOINT;
##   4. the nearest spot ON a line, circle or arc (position only);
##   5. otherwise the free position.
## Only (1) carries an id. (2)-(4) snap the position exactly but make an ordinary new point: the flat app makes a real
## constraint for those, which a later step here can add.
##
## Axis inference for a line: with one end placed, a second end within AXIS_DEGREES of horizontal or vertical is
## pulled exactly onto the axis and flagged, so the session can add the Horizontal / Vertical constraint.
## The snap toggle on the console turns all of this off (`enabled` false): the position comes back untouched.

const AXIS_DEGREES := 4.0

enum Kind { FREE, POINT, VERTEX, MIDPOINT, CURVE }

const NAMES := {Kind.FREE: "free", Kind.POINT: "point", Kind.VERTEX: "vertex", Kind.MIDPOINT: "midpoint", Kind.CURVE: "curve"}


static func resolve(uv: Vector2, session, radius: float, enabled: bool, vertices: Array = [], line_start: Variant = null) -> Dictionary:
	## {uv, id, kind (a name), infer}. `session` is a sketch_session.gd (points / lines / circles / arcs).
	## `vertices` are the part's vertices on the sheet (Vector2s). `line_start` is the first end of the line being drawn, if any.
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
		return out

	best = radius
	for v in vertices:
		var d: float = uv.distance_to(v)
		if d <= best:
			best = d
			out = {"uv": v, "id": "", "kind": NAMES[Kind.VERTEX], "infer": ""}
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
