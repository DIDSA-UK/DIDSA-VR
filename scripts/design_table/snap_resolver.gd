extends RefCounted
## Where a laser point on the sketch sheet really lands. Pure maths over the sketch session's local model, no scene
## tree, so it is unit-tested on its own (tests/design_table_logic.gd).
##
## Order, like the flat sketcher's (client/lib/sketch/sketch_controller.dart, _pointIdAt):
##   1. an EXISTING POINT within the radius -> reuse it (the entity then shares it, which is what makes shapes join). The sketch's ORIGIN is one
##      of them (kind "origin"), so a line can start on it, a circle can be centred on it, and a dimension can start or end at it;
##   2. a VERTEX of the part, projected onto the sheet (the corners of the face you're sketching on, and every other corner of the part seen
##      along the plane's normal): the pick carries a `ref` and the session makes it a pinned point that follows the part when it is used;
##      ...or the CENTRE of one of the part's circular edges (a hole or boss in the sketch plane): the pick carries a `ref` of kind "circle_centre", and
##      the session makes the pinned centre point (a construction circle on the hole, whose centre is a live reference);
##   3. a line's MIDPOINT, or the midpoint of a straight edge of the part (a `ref` of kind "edge_midpoint": a new point held at the middle of a pinned
##      construction line by an at-midpoint constraint);
##   4. the nearest spot ON a line, circle or arc (position only), or on an edge of the part (a `ref` of kind "edge_point": a new point on the pinned
##      line or circle, held there by a point-on-line / point-on-circle constraint);
##   5. otherwise the free position.
## Only (1) carries an id and (2) a reference to the part. The sketch's own midpoints and curves snap the position exactly but make an ordinary new point:
## the flat app makes a real constraint for those, which a later step here can add.
##
## Axis inference for a line: with one end placed, a second end within AXIS_DEGREES of horizontal or vertical is
## pulled exactly onto the axis and flagged, so the session can add the Horizontal / Vertical constraint.
## The snap toggle on the console turns all of this off (`enabled` false): the position comes back untouched.

const AXIS_DEGREES := 4.0

const EDGE_POINT_REACH := 0.6 ## along-an-edge snaps only within this fraction of the snap radius, like the sketch's own curves: a stray aim near an edge should not grab it

enum Kind { FREE, POINT, VERTEX, MIDPOINT, CURVE, ORIGIN, CENTRE, EDGE_MIDPOINT, EDGE_POINT }

const NAMES := {Kind.FREE: "free", Kind.POINT: "point", Kind.VERTEX: "vertex", Kind.MIDPOINT: "midpoint", Kind.CURVE: "curve", Kind.ORIGIN: "origin",
	Kind.CENTRE: "centre", Kind.EDGE_MIDPOINT: "edge_midpoint", Kind.EDGE_POINT: "edge_point"}


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
	if refs != null and session.references_ok:
		var rc: Dictionary = refs.nearest_centre(uv, radius)
		if not rc.is_empty() and float(rc["distance"]) <= best:
			best = float(rc["distance"])
			out = {"uv": rc["uv"], "id": "", "kind": NAMES[Kind.CENTRE], "infer": "", "ref": {"kind": "circle_centre", "body": rc["body"], "index": rc["index"]}}
	if out["kind"] == NAMES[Kind.VERTEX] or out["kind"] == NAMES[Kind.CENTRE]:
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
	if out["kind"] != NAMES[Kind.MIDPOINT] and refs != null and session.references_ok:
		var em: Dictionary = refs.nearest_midpoint(uv, radius)
		if not em.is_empty():
			out = {"uv": em["uv"], "id": "", "kind": NAMES[Kind.EDGE_MIDPOINT], "infer": "", "ref": {"kind": "edge_midpoint", "edge": refs.edge_ref(em)}}
	if out["kind"] == NAMES[Kind.MIDPOINT] or out["kind"] == NAMES[Kind.EDGE_MIDPOINT]:
		return out

	best = radius * EDGE_POINT_REACH
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
	if refs != null and session.references_ok:
		# An edge of the part, near enough (and at least as near as the sketch's own curve found above: a pinned line already lying on an edge is the
		# edge, and must not turn it into a plain free point): a point on it held there by a constraint.
		var along: Dictionary = refs.nearest_edge(uv, best, false)
		if not along.is_empty() and str(along["kind"]) == "line" and refs.edge_usable(along):
			out = {"uv": along["point"], "id": "", "kind": NAMES[Kind.EDGE_POINT], "infer": "", "ref": {"kind": "edge_point", "edge": refs.edge_ref(along)}}
			best = float(along["distance"])
		elif not along.is_empty() and not (along.get("circle", {}) as Dictionary).is_empty():
			var round_c: Vector2 = along["circle"]["c"]
			var on_rim: Vector2 = round_c + (uv - round_c).normalized() * float(along["circle"]["r"]) if along["circle"]["full"] else along["point"]
			out = {"uv": on_rim, "id": "", "kind": NAMES[Kind.EDGE_POINT], "infer": "", "ref": {"kind": "edge_point", "edge": refs.circle_ref(along)}}
			best = float(along["distance"])
	if out["kind"] == NAMES[Kind.CURVE] or out["kind"] == NAMES[Kind.EDGE_POINT]:
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
