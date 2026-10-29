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
##      ...or the AXIS of one of the part's round faces (a blind hole's wall, whose rim is not in the sketch plane): a `ref` of kind "face_axis", made a live centre;
##   3. a line's MIDPOINT, or the midpoint of a straight edge of the part (a `ref` of kind "edge_midpoint": a new point held at the middle of a pinned
##      construction line by an at-midpoint constraint);
##   4. the nearest spot ON a line, circle or arc (position only), or on an edge of the part (a `ref` of kind "edge_point": a new point on the pinned
##      line or circle, held there by a point-on-line / point-on-circle constraint);
##   5. otherwise the free position.
## Only (1) carries an id and (2) a reference to the part. A snap to the sketch's own midpoint or curve (3, 4) carries a `target` ({kind: "line" | "circle" |
## "arc", id}) so the session can HOLD the new point there with a constraint (at-midpoint / point-on-line / point-on-circle), as the flat app does.
##
## Axis inference for a line: with one end placed, a second end within AXIS_DEGREES of horizontal or vertical is
## pulled exactly onto the axis and flagged, so the session can add the Horizontal / Vertical constraint.
## The END of a line is decided where the ghost draws it (the flat app's _resolveLineEnd): an existing point near the raw aim wins (the first point of the
## run before any other, so a loop closes); otherwise the inferred end (the axis-snapped one) is tested against the existing points again, and if it lands
## on one that point wins; else a new point goes at the snapped position. A closing edge within AXIS_DEGREES of an axis still carries horizontal / vertical.
## The snap toggle on the console turns all of this off (`enabled` false): the position comes back untouched.

const AXIS_DEGREES := 4.0

const EDGE_POINT_REACH := 0.6 ## along-an-edge snaps only within this fraction of the snap radius, like the sketch's own curves: a stray aim near an edge should not grab it

enum Kind { FREE, POINT, VERTEX, MIDPOINT, CURVE, ORIGIN, CENTRE, EDGE_MIDPOINT, EDGE_POINT, FACE_AXIS }

const NAMES := {Kind.FREE: "free", Kind.POINT: "point", Kind.VERTEX: "vertex", Kind.MIDPOINT: "midpoint", Kind.CURVE: "curve", Kind.ORIGIN: "origin",
	Kind.CENTRE: "centre", Kind.EDGE_MIDPOINT: "edge_midpoint", Kind.EDGE_POINT: "edge_point", Kind.FACE_AXIS: "face_axis"}


static func nearest_on_arc(uv: Vector2, c: Vector2, s: Vector2, e: Vector2) -> Variant:
	## The spot of the arc (counter-clockwise from its start to its end, as the backend's are) nearest `uv`, or null when `uv` lies off its sweep (the ends
	## are points, snapped to as points).
	var r := c.distance_to(s)
	var to := uv - c
	if to.length() < 0.000001:
		return null
	var a0 := fposmod((s - c).angle(), TAU)
	var sweep := fposmod(fposmod((e - c).angle(), TAU) - a0, TAU)
	if fposmod(to.angle() - a0, TAU) > sweep:
		return null
	return c + to.normalized() * r


static func resolve(uv: Vector2, session, radius: float, enabled: bool, vertices: Array = [], line_start: Variant = null, refs: Variant = null, opts: Dictionary = {}) -> Dictionary:
	## {uv, id, kind (a name), infer, ref?, target?}. `session` is a sketch_session.gd (points / lines / circles / arcs).
	## `vertices` are plain positions to snap to (Vector2s); `refs` is the part's projected geometry (part_references.gd), whose vertices are snapped
	## to as references. `line_start` is the first end of the line being drawn, if any.
	## `opts`: `chain_first` (the id of the point the run of lines started on: ending on it closes the loop; "" when none or when it is the start itself),
	## `start_id` (the id of the point at `line_start`, if it is an existing one).
	var out := {"uv": uv, "id": "", "kind": NAMES[Kind.FREE], "infer": ""}
	if not enabled or session == null:
		return out
	var chain_first := str(opts.get("chain_first", ""))
	var start_id := str(opts.get("start_id", ""))
	if line_start != null and chain_first != "" and session.points.has(chain_first) and uv.distance_to(session.points[chain_first]) <= radius:
		return _closing(chain_first, session, line_start)

	var best := radius
	for id in session.points:
		if session.is_reference(id):
			continue # plumbing to the part: the corner / centre it stands for is snapped to below as the part's own, whether or not it has been made yet
		var d: float = uv.distance_to(session.points[id])
		# (a point lying exactly on the origin, as a shape started there has, is taken rather than the origin itself)
		if d < best or (d <= best and (str(out["id"]) == "" or session.is_origin(str(out["id"])))):
			best = d
			out = {"uv": session.points[id], "id": id, "kind": NAMES[Kind.POINT], "infer": ""}
	if out["id"] != "":
		if session.is_origin(str(out["id"])):
			out["kind"] = NAMES[Kind.ORIGIN] # the sketch's own origin: a real point, shown as such
		elif line_start != null and chain_first != "" and str(out["id"]) == chain_first:
			return _closing(chain_first, session, line_start)
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
	if refs != null and session.references_ok and out["kind"] != NAMES[Kind.VERTEX] and out["kind"] != NAMES[Kind.CENTRE]:
		var fa: Dictionary = refs.nearest_face_axis(uv, radius)
		if not fa.is_empty():
			out = {"uv": fa["uv"], "id": "", "kind": NAMES[Kind.FACE_AXIS], "infer": "", "ref": refs.face_axis_ref(fa)}
	if out["kind"] == NAMES[Kind.VERTEX] or out["kind"] == NAMES[Kind.CENTRE] or out["kind"] == NAMES[Kind.FACE_AXIS]:
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
			out = {"uv": mid, "id": "", "kind": NAMES[Kind.MIDPOINT], "infer": "", "target": {"kind": "line", "id": id}}
	if out["kind"] != NAMES[Kind.MIDPOINT] and refs != null and session.references_ok:
		var em: Dictionary = refs.nearest_midpoint(uv, radius)
		if not em.is_empty():
			out = {"uv": em["uv"], "id": "", "kind": NAMES[Kind.EDGE_MIDPOINT], "infer": "", "ref": {"kind": "edge_midpoint", "edge": refs.edge_ref(em)}}
	if out["kind"] == NAMES[Kind.MIDPOINT] or out["kind"] == NAMES[Kind.EDGE_MIDPOINT]:
		return out

	best = radius * EDGE_POINT_REACH
	for id in session.lines:
		var l: Dictionary = session.lines[id]
		if session.is_reference(id) or not session.points.has(l["a"]) or not session.points.has(l["b"]):
			continue
		var near: Vector2 = Geometry2D.get_closest_point_to_segment(uv, session.points[l["a"]], session.points[l["b"]])
		var d := uv.distance_to(near)
		if d <= best:
			best = d
			out = {"uv": near, "id": "", "kind": NAMES[Kind.CURVE], "infer": "", "target": {"kind": "line", "id": id}}
	for id in session.circles:
		var c: Dictionary = session.circles[id]
		if session.is_reference(id) or not session.points.has(c["c"]) or not session.points.has(c["p"]):
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
			out = {"uv": on_circle, "id": "", "kind": NAMES[Kind.CURVE], "infer": "", "target": {"kind": "circle", "id": id}}
	var arc_map: Variant = session.get("arcs")
	if arc_map is Dictionary:
		for id in arc_map:
			var a: Dictionary = arc_map[id]
			if session.is_reference(id) or not session.points.has(a["c"]) or not session.points.has(a["s"]) or not session.points.has(a["e"]):
				continue
			var on_arc: Variant = nearest_on_arc(uv, session.points[a["c"]], session.points[a["s"]], session.points[a["e"]])
			if on_arc == null:
				continue
			var d := uv.distance_to(on_arc)
			if d <= best:
				best = d
				out = {"uv": on_arc, "id": "", "kind": NAMES[Kind.CURVE], "infer": "", "target": {"kind": "arc", "id": id}}
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
			var axis := _axis_of(delta)
			if axis == "horizontal":
				out = {"uv": Vector2(uv.x, start.y), "id": "", "kind": NAMES[Kind.FREE], "infer": "horizontal"}
			elif axis == "vertical":
				out = {"uv": Vector2(start.x, uv.y), "id": "", "kind": NAMES[Kind.FREE], "infer": "vertical"}
		var end_uv: Vector2 = out["uv"]
		if not end_uv.is_equal_approx(uv):
			# The end as it will be drawn is not where the laser is: an existing point near THAT spot is the end (else a new point goes just off it, and a
			# loop that looks closed is not).
			if chain_first != "" and session.points.has(chain_first) and end_uv.distance_to(session.points[chain_first]) <= radius:
				return _closing(chain_first, session, line_start)
			var landed := _point_near(session, end_uv, radius, start_id)
			if landed != "":
				var kind := Kind.ORIGIN if session.is_origin(landed) else Kind.POINT
				return {"uv": session.points[landed], "id": landed, "kind": NAMES[kind], "infer": ""}
	return out


static func _axis_of(delta: Vector2) -> String:
	## "horizontal" / "vertical" when a segment of this direction is within AXIS_DEGREES of an axis (a line and its reverse are the same line), else "".
	if delta.length() < 0.000001:
		return ""
	var folded := fposmod(rad_to_deg(delta.angle()), 180.0) # 0..180
	if minf(folded, 180.0 - folded) <= AXIS_DEGREES:
		return "horizontal"
	if absf(folded - 90.0) <= AXIS_DEGREES:
		return "vertical"
	return ""


static func _closing(first_id: String, session, start: Vector2) -> Dictionary:
	## The first point of a run, as the end of a line that closes it. The closing edge still carries horizontal / vertical when it is within AXIS_DEGREES of an
	## axis (nothing else is inferred for it: its slope is the loop's).
	var at: Vector2 = session.points[first_id]
	return {"uv": at, "id": first_id, "kind": NAMES[Kind.POINT], "infer": _axis_of(at - start), "closing": true}


static func _point_near(session, at: Vector2, radius: float, skip_id: String = "") -> String:
	## The nearest point of the sketch within `radius` of `at` (the part's reference helpers and `skip_id` left out; a point on the origin before the origin), or "".
	var found := ""
	var best := radius
	for id in session.points:
		if id == skip_id or session.is_reference(id):
			continue
		var d: float = at.distance_to(session.points[id])
		if d < best or (d <= best and (found == "" or session.is_origin(found))):
			best = d
			found = id
	return found
