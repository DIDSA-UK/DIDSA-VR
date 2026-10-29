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
## INFERRED RELATIONSHIPS (the Infer toggle; `opts.infer` false turns them off, leaving only the position snaps): the pick's `infer` is {} or
## {kind, target?} with kind one of horizontal / vertical (no target), parallel / perpendicular / collinear (a line), tangent (a circle or arc), on_curve
## (a line, circle or arc the end lands on) and concentric (a circle or arc whose centre a new centre is put on). For a line's end, in this order after the
## points and the part: tangent to a circle or arc, a point on a line / circle / arc, the line's own horizontal / vertical, collinear with a line through
## the start, then parallel / perpendicular to a WOKEN line (`opts.woken`: ids the laser has recently passed over) or to the segment the run is
## continuing. Angles: horizontal / vertical / parallel / perpendicular / collinear 4 degrees, tangent 6; reach for tangent / on-curve / concentric is
## CURVE_REACH times the point radius (15 mm world against 12).
## The snap toggle on the console turns all of this off (`enabled` false): the position comes back untouched.

const AXIS_DEGREES := 4.0
const PARALLEL_DEGREES := 4.0 ## parallel, perpendicular and collinear: as the flat app (parallelPerpendicularSnapAngleDegrees, collinearSnapAngleDegrees)
const TANGENT_DEGREES := 6.0
const CURVE_REACH := 1.25 ## tangent, point-on-curve and concentric reach, as a multiple of the point snap radius (the flat app's 18 px against 14: 15 mm against 12)

const EDGE_POINT_REACH := 0.6 ## along-an-edge snaps only within this fraction of the snap radius, like the sketch's own curves: a stray aim near an edge should not grab it

enum Kind { FREE, POINT, VERTEX, MIDPOINT, CURVE, ORIGIN, CENTRE, EDGE_MIDPOINT, EDGE_POINT, FACE_AXIS, PARALLEL, PERPENDICULAR, COLLINEAR, TANGENT, ON_CURVE, CONCENTRIC }

const NAMES := {Kind.FREE: "free", Kind.POINT: "point", Kind.VERTEX: "vertex", Kind.MIDPOINT: "midpoint", Kind.CURVE: "curve", Kind.ORIGIN: "origin",
	Kind.CENTRE: "centre", Kind.EDGE_MIDPOINT: "edge_midpoint", Kind.EDGE_POINT: "edge_point", Kind.FACE_AXIS: "face_axis",
	Kind.PARALLEL: "parallel", Kind.PERPENDICULAR: "perpendicular", Kind.COLLINEAR: "collinear", Kind.TANGENT: "tangent", Kind.ON_CURVE: "on_curve", Kind.CONCENTRIC: "concentric"}


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
	## `start_id` (the id of the point at `line_start`, if it is an existing one), `infer` (false: no relationship is inferred and none is held; default
	## true), `woken` (ids of the lines parallel / perpendicular may be inferred against), `concentric` (this tap places a circle's or arc's centre).
	var out := {"uv": uv, "id": "", "kind": NAMES[Kind.FREE], "infer": {}}
	if not enabled or session == null:
		return out
	var chain_first := str(opts.get("chain_first", ""))
	var start_id := str(opts.get("start_id", ""))
	var infer_on := bool(opts.get("infer", true))
	var curve_reach := radius * CURVE_REACH
	if line_start != null and chain_first != "" and session.points.has(chain_first) and uv.distance_to(session.points[chain_first]) <= radius:
		return _closing(chain_first, session, line_start, infer_on)

	var best := radius
	for id in session.points:
		if session.is_reference(id):
			continue # plumbing to the part: the corner / centre it stands for is snapped to below as the part's own, whether or not it has been made yet
		var d: float = uv.distance_to(session.points[id])
		# (a point lying exactly on the origin, as a shape started there has, is taken rather than the origin itself)
		if d < best or (d <= best and (str(out["id"]) == "" or session.is_origin(str(out["id"])))):
			best = d
			out = {"uv": session.points[id], "id": id, "kind": NAMES[Kind.POINT], "infer": {}}
	if out["id"] != "":
		if session.is_origin(str(out["id"])):
			out["kind"] = NAMES[Kind.ORIGIN] # the sketch's own origin: a real point, shown as such
		elif line_start != null and chain_first != "" and str(out["id"]) == chain_first:
			return _closing(chain_first, session, line_start, infer_on)
		return out

	best = radius
	for v in vertices:
		var d: float = uv.distance_to(v)
		if d <= best:
			best = d
			out = {"uv": v, "id": "", "kind": NAMES[Kind.VERTEX], "infer": {}}
	if refs != null and session.references_ok:
		var rv: Dictionary = refs.nearest_vertex(uv, radius)
		if not rv.is_empty() and float(rv["distance"]) <= best:
			best = float(rv["distance"])
			out = {"uv": rv["uv"], "id": "", "kind": NAMES[Kind.VERTEX], "infer": {}, "ref": {"kind": "vertex", "body": rv["body"], "index": rv["index"]}}
	if refs != null and session.references_ok:
		var rc: Dictionary = refs.nearest_centre(uv, radius)
		if not rc.is_empty() and float(rc["distance"]) <= best:
			best = float(rc["distance"])
			out = {"uv": rc["uv"], "id": "", "kind": NAMES[Kind.CENTRE], "infer": {}, "ref": {"kind": "circle_centre", "body": rc["body"], "index": rc["index"]}}
	if refs != null and session.references_ok and out["kind"] != NAMES[Kind.VERTEX] and out["kind"] != NAMES[Kind.CENTRE]:
		var fa: Dictionary = refs.nearest_face_axis(uv, radius)
		if not fa.is_empty():
			out = {"uv": fa["uv"], "id": "", "kind": NAMES[Kind.FACE_AXIS], "infer": {}, "ref": refs.face_axis_ref(fa)}
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
			out = {"uv": mid, "id": "", "kind": NAMES[Kind.MIDPOINT], "infer": {}, "target": {"kind": "line", "id": id}}
	if out["kind"] != NAMES[Kind.MIDPOINT] and refs != null and session.references_ok:
		var em: Dictionary = refs.nearest_midpoint(uv, radius)
		if not em.is_empty():
			out = {"uv": em["uv"], "id": "", "kind": NAMES[Kind.EDGE_MIDPOINT], "infer": {}, "ref": {"kind": "edge_midpoint", "edge": refs.edge_ref(em)}}
	if out["kind"] == NAMES[Kind.MIDPOINT] or out["kind"] == NAMES[Kind.EDGE_MIDPOINT]:
		if not infer_on:
			out.erase("target") # Infer off: the position only, a plain point (nothing holds it at the middle)
			out.erase("ref")
		return out

	var ends_line := line_start != null and infer_on ## the end of a line: a tangent comes before a point on a curve, and the reach is the wider one
	if ends_line:
		var tangent := _tangent_candidate(uv, session, line_start, curve_reach)
		if not tangent.is_empty():
			return tangent
	best = curve_reach if ends_line else radius * EDGE_POINT_REACH
	for id in session.lines:
		var l: Dictionary = session.lines[id]
		if session.is_reference(id) or not session.points.has(l["a"]) or not session.points.has(l["b"]):
			continue
		if ends_line and start_id != "" and (l["a"] == start_id or l["b"] == start_id):
			continue # a point on a line that leaves the start would make the new line lie along it: that is collinear, found below
		var near: Vector2 = Geometry2D.get_closest_point_to_segment(uv, session.points[l["a"]], session.points[l["b"]])
		var d := uv.distance_to(near)
		if d <= best:
			best = d
			out = {"uv": near, "id": "", "kind": NAMES[Kind.CURVE], "infer": {}, "target": {"kind": "line", "id": id}}
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
			out = {"uv": on_circle, "id": "", "kind": NAMES[Kind.CURVE], "infer": {}, "target": {"kind": "circle", "id": id}}
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
				out = {"uv": on_arc, "id": "", "kind": NAMES[Kind.CURVE], "infer": {}, "target": {"kind": "arc", "id": id}}
	if refs != null and session.references_ok:
		# An edge of the part, near enough (and at least as near as the sketch's own curve found above: a pinned line already lying on an edge is the
		# edge, and must not turn it into a plain free point): a point on it held there by a constraint.
		var along: Dictionary = refs.nearest_edge(uv, minf(best, radius * EDGE_POINT_REACH), false) # (the part's edges keep their own, shorter reach)
		if not along.is_empty() and str(along["kind"]) == "line" and refs.edge_usable(along):
			out = {"uv": along["point"], "id": "", "kind": NAMES[Kind.EDGE_POINT], "infer": {}, "ref": {"kind": "edge_point", "edge": refs.edge_ref(along)}}
			best = float(along["distance"])
		elif not along.is_empty() and not (along.get("circle", {}) as Dictionary).is_empty():
			var round_c: Vector2 = along["circle"]["c"]
			var on_rim: Vector2 = round_c + (uv - round_c).normalized() * float(along["circle"]["r"]) if along["circle"]["full"] else along["point"]
			out = {"uv": on_rim, "id": "", "kind": NAMES[Kind.EDGE_POINT], "infer": {}, "ref": {"kind": "edge_point", "edge": refs.circle_ref(along)}}
			best = float(along["distance"])
	if out["kind"] == NAMES[Kind.CURVE] or out["kind"] == NAMES[Kind.EDGE_POINT]:
		if not infer_on:
			out.erase("target") # Infer off: position only (a plain point)
			out.erase("ref")
		elif out["kind"] == NAMES[Kind.CURVE] and line_start != null:
			# the end of a line that lands on a curve: the line's own inference holds it there (point-on-line / point-on-circle), not the session's snap
			out["kind"] = NAMES[Kind.ON_CURVE]
			out["infer"] = {"kind": "on_curve", "target": out["target"]}
			out["marker"] = out["uv"]
			out.erase("target")
		return out

	if line_start != null and infer_on:
		return _end_inference(uv, session, radius, line_start, chain_first, start_id, opts)
	if line_start == null and infer_on and bool(opts.get("concentric", false)):
		var concentric := _concentric_candidate(uv, session, radius, curve_reach)
		if not concentric.is_empty():
			return concentric
	return out


static func _end_inference(uv: Vector2, session, radius: float, start: Vector2, chain_first: String, start_id: String, opts: Dictionary) -> Dictionary:
	## The free end of a line: the first of tangent (found by the caller), the axis, collinear, parallel / perpendicular, decides the inferred relationship
	## and the snapped end; then the end as drawn is tested against the existing points again.
	var out := {"uv": uv, "id": "", "kind": NAMES[Kind.FREE], "infer": {}}
	var delta := uv - start
	if delta.length() > radius:
		var found := {}
		var axis := _axis_of(delta)
		if axis == "horizontal":
			found = {"kind": "horizontal", "pos": Vector2(uv.x, start.y)}
		elif axis == "vertical":
			found = {"kind": "vertical", "pos": Vector2(start.x, uv.y)}
		else:
			found = _collinear_candidate(uv, session, start, start_id)
			if found.is_empty():
				found = _parallel_candidate(uv, session, start, start_id, opts.get("woken", []))
		if not found.is_empty():
			var kind: String = found["kind"]
			out = {"uv": found["pos"], "id": "", "kind": NAMES[Kind.FREE], "infer": {"kind": kind}}
			if found.has("target"):
				out["infer"]["target"] = found["target"]
				out["kind"] = kind
				out["marker"] = found["marker"]
	var end_uv: Vector2 = out["uv"]
	if not end_uv.is_equal_approx(uv):
		# The end as it will be drawn is not where the laser is: an existing point near THAT spot is the end (else a new point goes just off it, and a
		# loop that looks closed is not).
		if chain_first != "" and session.points.has(chain_first) and end_uv.distance_to(session.points[chain_first]) <= radius:
			return _closing(chain_first, session, start, true)
		var landed := _point_near(session, end_uv, radius, start_id)
		if landed != "":
			var landed_kind := Kind.ORIGIN if session.is_origin(landed) else Kind.POINT
			return {"uv": session.points[landed], "id": landed, "kind": NAMES[landed_kind], "infer": {}}
	return out


static func _undirected_delta(a: float, b: float) -> float:
	## Degrees apart two undirected angles (radians) are, 0..90: a segment and its reverse are the same line.
	var diff := fposmod(absf(rad_to_deg(a - b)), 360.0)
	if diff > 180.0:
		diff = 360.0 - diff
	if diff > 90.0:
		diff = 180.0 - diff
	return diff


static func _directed_delta(a: float, b: float) -> float:
	## Degrees apart two directed angles (radians) are, 0..180.
	var diff := fposmod(rad_to_deg(a - b), 360.0)
	if diff > 180.0:
		diff -= 360.0
	return absf(diff)


static func _closest_directed(toward: float, axis: float) -> float:
	## `axis` or its reverse, whichever the segment pointing `toward` is nearer.
	return axis if _directed_delta(toward, axis) <= _directed_delta(toward, axis + PI) else axis + PI


static func _circle_of(session, kind: String, id: String) -> Dictionary:
	## {c, r} of a circle or an arc of the sketch (an arc's own circle), or {} if it is a reference helper or its points are gone.
	if session.is_reference(id):
		return {}
	if kind == "circle":
		var c: Dictionary = session.circles.get(id, {})
		if c.is_empty() or not session.points.has(c["c"]) or not session.points.has(c["p"]):
			return {}
		return {"c": session.points[c["c"]], "r": (session.points[c["c"]] as Vector2).distance_to(session.points[c["p"]])}
	var arc_map: Variant = session.get("arcs")
	var a: Dictionary = (arc_map as Dictionary).get(id, {}) if arc_map is Dictionary else {}
	if a.is_empty() or not session.points.has(a["c"]) or not session.points.has(a["s"]) or not session.points.has(a["e"]):
		return {}
	return {"c": session.points[a["c"]], "r": (session.points[a["c"]] as Vector2).distance_to(session.points[a["s"]]), "s": session.points[a["s"]], "e": session.points[a["e"]]}


static func _round_shapes(session) -> Array:
	## [{kind, id, c, r, s?, e?}] for every circle and arc of the sketch that is not a reference helper.
	var out: Array = []
	for id in session.circles:
		var shape := _circle_of(session, "circle", id)
		if not shape.is_empty():
			shape["kind"] = "circle"
			shape["id"] = id
			out.append(shape)
	var arc_map: Variant = session.get("arcs")
	if arc_map is Dictionary:
		for id in arc_map:
			var shape := _circle_of(session, "arc", id)
			if not shape.is_empty():
				shape["kind"] = "arc"
				shape["id"] = id
				out.append(shape)
	return out


static func _distance_to_round(uv: Vector2, shape: Dictionary) -> float:
	## How far `uv` is from the curve itself: the whole circle, or an arc's sweep (past its ends, the nearer end).
	var centre: Vector2 = shape["c"]
	if shape["kind"] == "circle":
		return absf(uv.distance_to(centre) - float(shape["r"]))
	var on_arc: Variant = nearest_on_arc(uv, centre, shape["s"], shape["e"])
	if on_arc != null:
		return uv.distance_to(on_arc)
	return minf(uv.distance_to(shape["s"]), uv.distance_to(shape["e"]))


static func _tangent_candidate(uv: Vector2, session, start: Vector2, reach: float) -> Dictionary:
	## A circle or arc the aim is near whose tangent line from the start points within TANGENT_DEGREES of the aim: the end pulled onto that tangent line.
	## The marker is where the tangent touches the circle.
	var delta := uv - start
	if delta.length() < 0.000001:
		return {}
	var best := {}
	var best_delta := INF
	var aim := delta.angle()
	for shape in _round_shapes(session):
		if _distance_to_round(uv, shape) > reach:
			continue
		var centre: Vector2 = shape["c"]
		var radius: float = shape["r"]
		var to_centre := centre - start
		var d := to_centre.length()
		if d <= radius + 0.000000001:
			continue # the start is on or inside it: no tangent line from here
		var phi := to_centre.angle()
		var theta := asin(clampf(radius / d, -1.0, 1.0))
		for tangent_angle in [phi - theta, phi + theta]:
			var off := _directed_delta(aim, tangent_angle)
			if off <= TANGENT_DEGREES and off < best_delta:
				best_delta = off
				var dir := Vector2.from_angle(tangent_angle)
				best = {"uv": start + dir * delta.length(), "id": "", "kind": NAMES[Kind.TANGENT], "infer": {"kind": "tangent", "target": {"kind": shape["kind"], "id": shape["id"]}}, "marker": start + dir * to_centre.dot(dir)}
	return best


static func _lines_at(session, point_id: String) -> Array:
	## Ids of the sketch's lines (not reference helpers) that have `point_id` as an end.
	var out: Array = []
	if point_id == "":
		return out
	for id in session.lines:
		var l: Dictionary = session.lines[id]
		if (l["a"] == point_id or l["b"] == point_id) and not session.is_reference(id):
			out.append(id)
	return out


static func _collinear_candidate(uv: Vector2, session, start: Vector2, start_id: String) -> Dictionary:
	## The new line carrying straight on from a line that ends at the start (within PARALLEL_DEGREES): {kind, target, pos, marker}.
	var delta := uv - start
	var seg := delta.angle()
	var best := {}
	var best_delta := INF
	for id in _lines_at(session, start_id):
		var l: Dictionary = session.lines[id]
		var other_id: String = l["b"] if l["a"] == start_id else l["a"]
		if not session.points.has(other_id):
			continue
		var outward: Vector2 = start - (session.points[other_id] as Vector2)
		if outward.length() < 0.000001:
			continue
		var off := _undirected_delta(seg, outward.angle())
		if off <= PARALLEL_DEGREES and off < best_delta:
			best_delta = off
			var snap := _closest_directed(seg, outward.angle())
			best = {"kind": "collinear", "target": {"kind": "line", "id": id}, "pos": start + Vector2.from_angle(snap) * delta.length(), "marker": start}
	return best


static func _parallel_candidate(uv: Vector2, session, start: Vector2, start_id: String, woken: Array) -> Dictionary:
	## Parallel or perpendicular to a line the laser has woken, or to a line that leaves the start (the segment the run is continuing). Only those:
	## a laser shakes, and an unrelated line elsewhere in the sketch must not be matched by chance.
	var delta := uv - start
	var seg := delta.angle()
	var ids: Array = _lines_at(session, start_id)
	for id in woken:
		if not ids.has(id) and session.lines.has(id) and not session.is_reference(id):
			ids.append(id)
	var best := {}
	var best_delta := INF
	for id in ids:
		var l: Dictionary = session.lines[id]
		if not session.points.has(l["a"]) or not session.points.has(l["b"]):
			continue
		var a: Vector2 = session.points[l["a"]]
		var b: Vector2 = session.points[l["b"]]
		if a.distance_to(b) < 0.000001:
			continue
		var line_angle := (b - a).angle()
		var parallel_off := _undirected_delta(seg, line_angle)
		var perpendicular_off := absf(90.0 - parallel_off)
		var marker := (a + b) * 0.5
		if parallel_off <= PARALLEL_DEGREES and parallel_off < best_delta:
			best_delta = parallel_off
			best = {"kind": "parallel", "target": {"kind": "line", "id": id}, "pos": start + Vector2.from_angle(_closest_directed(seg, line_angle)) * delta.length(), "marker": marker}
		elif perpendicular_off <= PARALLEL_DEGREES and perpendicular_off < best_delta:
			best_delta = perpendicular_off
			best = {"kind": "perpendicular", "target": {"kind": "line", "id": id}, "pos": start + Vector2.from_angle(_closest_directed(seg, line_angle + PI * 0.5)) * delta.length(), "marker": marker}
	return best


static func _concentric_candidate(uv: Vector2, session, radius: float, reach: float) -> Dictionary:
	## A centre placed near (but outside the point snap of) the centre of a circle or arc: put exactly on it and held concentric with that shape.
	var best := {}
	var best_d := reach
	for shape in _round_shapes(session):
		var centre: Vector2 = shape["c"]
		var d := uv.distance_to(centre)
		if d > radius and d <= best_d:
			best_d = d
			best = {"uv": centre, "id": "", "kind": NAMES[Kind.CONCENTRIC], "infer": {"kind": "concentric", "target": {"kind": shape["kind"], "id": shape["id"]}}, "marker": centre}
	return best


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


static func _closing(first_id: String, session, start: Vector2, infer_on: bool = true) -> Dictionary:
	## The first point of a run, as the end of a line that closes it. The closing edge still carries horizontal / vertical when it is within AXIS_DEGREES of an
	## axis (nothing else is inferred for it: its slope is the loop's).
	var at: Vector2 = session.points[first_id]
	var axis := _axis_of(at - start) if infer_on else ""
	return {"uv": at, "id": first_id, "kind": NAMES[Kind.POINT], "infer": {"kind": axis} if axis != "" else {}, "closing": true}


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
