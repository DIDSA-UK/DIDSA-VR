extends SceneTree
## Parity follow-ups F7 part 2: the rigidity count (scripts/design_table/sketch_rigidity.gd, pinned by sketch_rigidity_vectors.gd) wired into the sketch, from the backend's own wire
## shapes, no backend. Session: `rigidity()` (fixed = the origin, locked points, a Fix's points; trust = converged and dof >= 0), `entity_states()` (a half-dimensioned rectangle
## leaves its structure free and a fully dimensioned one is fully constrained; a line both horizontal and vertical, and two lines both parallel and perpendicular, are over;
## a constraint the solve failed is over; the whole-sketch override), `contradictory_points()` and `on_contradictory_line`. The pre-grab rule (`PointDrag.refusal_for`) now
## refuses an over-constrained or fully constrained point through the count. The view: the state reaches the drawn entity in the flat app's order (over, construction, fully,
## plain), a changed state redraws an entity whose geometry did not change, and a drag frame (`redraw_moved`) keeps the colours.
## NOT checked: a render (the colours are read from the mesh's vertex colours), the feel, a headset.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_rigidity_wiring.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const PointDrag := preload("res://scripts/design_table/point_drag.gd")
const View := preload("res://scripts/design_table/sketch_view.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _con(id: String, type: String, fields: Dictionary) -> Dictionary:
	var c := {"id": id, "type": type}
	c.merge(fields)
	return c


func _hv(id: String, type: String, line: String, a: String, b: String) -> Dictionary:
	return _con(id, type, {"line_id": line, "point_a_id": a, "point_b_id": b})


func _dist(id: String, a: String, b: String, d: float) -> Dictionary:
	return _con(id, "distance", {"point_a_id": a, "point_b_id": b, "distance": d, "orientation": "linear"})


func _rect_constraints(width: bool, height: bool) -> Array:
	## A rectangle A B C D hung on the origin O: A is held by a Horizontal and a distance to O (two freedoms), then the rectangle's own four Horizontal / Vertical and its dimensions.
	var out: Array = [
		_con("oa-h", "horizontal", {"point_a_id": "O", "point_b_id": "A"}), _dist("oa-d", "O", "A", 10.0),
		_hv("h1", "horizontal", "ab", "A", "B"), _hv("v1", "vertical", "bc", "B", "C"), _hv("h2", "horizontal", "cd", "D", "C"), _hv("v2", "vertical", "da", "A", "D")]
	if width:
		out.append(_dist("w", "A", "B", 40.0))
	if height:
		out.append(_dist("hh", "B", "C", 20.0))
	return out


func _sketch(constraints: Array, dof: int, converged := true, failed: Array = [], locked: Array = []) -> Object:
	## The rectangle, a separate free line F (f -> g) and the origin, as the backend's state and entities would arrive.
	var xy := {"O": [0.0, 0.0], "A": [10.0, 0.0], "B": [50.0, 0.0], "C": [50.0, 20.0], "D": [10.0, 20.0], "f": [30.0, 40.0], "g": [45.0, 55.0]}
	var pts: Array = []
	for id in xy:
		pts.append({"id": id, "x": xy[id][0], "y": xy[id][1], "is_locked": locked.has(id)})
	var s = Session.new(Callable())
	s.sketch_id = "SK"
	s.origin_id = "O"
	s._ingest_state({"points": pts, "constraints": constraints, "solve": {"dof": dof, "converged": converged, "solver_reported_failed_constraint_ids": failed}})
	s._ingest_entities({"entities": [
		{"type": "line", "id": "ab", "start_point_id": "A", "end_point_id": "B"}, {"type": "line", "id": "bc", "start_point_id": "B", "end_point_id": "C"},
		{"type": "line", "id": "cd", "start_point_id": "C", "end_point_id": "D"}, {"type": "line", "id": "da", "start_point_id": "D", "end_point_id": "A"},
		{"type": "line", "id": "F", "start_point_id": "f", "end_point_id": "g"}]})
	return s


func _states(s, kind := "line") -> Dictionary:
	var all: Dictionary = s.entity_states()
	var out := {}
	for k in all:
		if str(k).begins_with(kind + ":"):
			out[str(k).substr(kind.length() + 1)] = all[k]
	return out


func _rect_is(st: Dictionary, want: String) -> bool:
	for id in ["ab", "bc", "cd", "da"]:
		if st.get(id) != want:
			return false
	return true


func _mobility(projector, s, id: String) -> int:
	var pts := {}
	for pid in s.points:
		pts[pid] = [s.points[pid].x, s.points[pid].y]
	return projector.mobility(pts, s.constraints.values(), s.lines, id, PointDrag.pinned_ids(s))


func _count_colour(view, want: Color) -> int:
	var cols: PackedColorArray = view._geo.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var n := 0
	for c in cols:
		if absf(c.r - want.r) < 0.01 and absf(c.g - want.g) < 0.01 and absf(c.b - want.b) < 0.01 and c.a > 0.95:
			n += 1
	return n


func _initialize() -> void:
	# --- the count: fixed and trust
	var s = _sketch(_rect_constraints(true, true), 4)
	var r: RefCounted = s.rigidity()
	_check(r.is_pinned("O") and r.is_grounded("A") and r.is_fully("A") and r.is_fully("C") and not r.is_fully("f"), "rigidity(): the origin grounds the rectangle, all four corners are fully constrained, the free line's end is in no cluster")
	var locked = _sketch([_dist("fg", "f", "g", 20.0)], 3, true, [], ["f"])
	_check((locked.rigidity() as RefCounted).is_pinned("f") and (locked.rigidity() as RefCounted).is_grounded("g"), "...a locked point is fixed too (it grounds what it is tied to)")
	var fix = _sketch([_dist("fg", "f", "g", 20.0), {"id": "kf", "type": "fixed", "point_ids": ["g"]}], 1)
	_check((fix.rigidity() as RefCounted).is_pinned("g") and (fix.rigidity() as RefCounted).is_grounded("f"), "...and so is a point a Fix holds")
	var redundant = _rect_constraints(true, true)
	redundant.append(_dist("w2", "D", "C", 40.0))
	var untrusted = _sketch(redundant, 0, false)
	var trusted = _sketch(redundant, 0, true)
	_check((untrusted.rigidity() as RefCounted).is_over("B") and not (trusted.rigidity() as RefCounted).is_over("B"), "...a redundant set reads over until the solve converges (trust = converged and dof >= 0)")
	var neg = _sketch(redundant, -1, true)
	_check((neg.rigidity() as RefCounted).is_over("B"), "...and a negative dof is not trusted either")

	# --- a half-dimensioned rectangle leaves its structure free; a fully dimensioned one is fully constrained
	s = _sketch(_rect_constraints(true, false), 5)
	var st := _states(s)
	_check(_rect_is(st, "free") and st["F"] == "free", "a rectangle with its width but not its height: every line of the structure is free (and so is the separate free line): %s" % str(st))
	_check(s.point_rigidity("C") == "free", "...point_rigidity says free")
	s = _sketch(_rect_constraints(true, true), 4)
	st = _states(s)
	_check(_rect_is(st, "fully") and st["F"] == "free", "with its height too the rectangle is fully constrained; the separate free line still is not: %s" % str(st))
	_check(s.point_rigidity("C") == "fully" and s.point_rigidity("f") == "free" and s.point_rigidity("O") == "pinned", "...point_rigidity: fully, free, pinned (the origin)")
	_check(not s.entity_states().has("point:A") and s.entity_states().has("line:ab"), "entity_states names lines, circles, arcs ... as `kind:id` and no points")

	# --- a line that is both horizontal and vertical is red
	var both = _rect_constraints(false, false)
	both.append(_hv("x1", "vertical", "ab", "A", "B"))
	s = _sketch(both, 1)
	st = _states(s)
	_check(st["ab"] == "over" and st["F"] == "free", "a line that is both horizontal and vertical is over (the solve converged, so the count alone would not say so): %s" % str(st))
	_check(st["bc"] == "over" and st["da"] == "over", "...and so are the lines that share its endpoints (a point is forced over: the entity holding it is red)")
	_check(s.on_contradictory_line("A") and s.on_contradictory_line("B") and not s.on_contradictory_line("C") and not s.on_contradictory_line("f"), "on_contradictory_line reads contradictory_points: the line's two endpoints")
	var by_ends: Array = [_con("hp", "horizontal", {"point_a_id": "f", "point_b_id": "g"}), _con("vp", "vertical", {"point_a_id": "g", "point_b_id": "f"})]
	s = _sketch(by_ends, 2)
	_check(_states(s)["F"] == "over", "...also when the Horizontal and the Vertical name only the line's two points, not the line")
	only_h_check()
	var pp: Array = [_con("pa", "parallel", {"line1_id": "ab", "line2_id": "F"}), _con("pe", "perpendicular", {"line1_id": "F", "line2_id": "ab"})]
	s = _sketch(pp, 2)
	st = _states(s)
	_check(st["ab"] == "over" and st["F"] == "over" and st["cd"] == "free", "two lines that are both parallel and perpendicular are both over: %s" % str(st))
	s = _sketch([_con("pa", "parallel", {"line1_id": "ab", "line2_id": "F"})], 4)
	_check(_states(s)["ab"] == "free" and s.contradictory_points().is_empty(), "...a parallel alone is not")

	# --- a constraint the last solve failed: its points' entities are over
	s = _sketch(_rect_constraints(true, true), 0, false, ["w"])
	st = _states(s)
	_check(st["ab"] == "over" and st["da"] == "over" and st["F"] == "free", "the points of a constraint the solve reported failed are forced over: their lines are over, the others are not: %s" % str(st))

	# --- the whole-sketch override
	s = _sketch(_rect_constraints(true, false), 0, true)
	st = _states(s)
	_check(_rect_is(st, "fully") and st["F"] == "fully", "whole-sketch override: the backend says dof 0 and converged, something is grounded: every entity is fully constrained, even where the count says free: %s" % str(st))
	s = _sketch([_dist("fg", "f", "g", 20.0)], 0, true)
	_check(_states(s)["F"] == "free", "...but not when nothing is grounded (a floating line has dof 0 for the solver too)")
	s = _sketch(_rect_constraints(true, false), 0, false)
	_check(_states(s)["ab"] == "free", "...nor when the solve did not converge")
	s = _sketch(_rect_constraints(true, false), 1, true)
	_check(_states(s)["ab"] == "free", "...nor with a freedom left")
	var over_whole = _rect_constraints(true, false)
	over_whole.append(_hv("x1", "vertical", "ab", "A", "B"))
	s = _sketch(over_whole, 0, true)
	st = _states(s)
	_check(st["ab"] == "over" and st["F"] == "fully", "...and what is over stays over under it: %s" % str(st))
	var empty = Session.new(Callable())
	_check(empty.entity_states().is_empty() and empty.rigidity() != null, "an empty sketch has no states")

	# --- the pre-grab rule reads the count
	var d := PointDrag.new()
	d.synchronous = true
	s = _sketch(_rect_constraints(true, true), 4) # the rectangle is rigid, the free line is not: the backend's dof is not 0, so only the count can say so
	_check(not d.begin(s, "C", Vector2(50, 20)) and d.refusal.contains("fully constrained"), "a corner of the fully dimensioned rectangle (dof 4, so not the whole-sketch case) is refused as fully constrained: %s" % d.refusal)
	_check(not d.begin(s, "A", Vector2(10, 0)) and d.refusal != "", "...so is A, the corner the origin holds")
	d = PointDrag.new()
	d.synchronous = true
	_check(d.begin(s, "f", Vector2(30, 40)) and d.refusal == "", "...the free line's end still starts a drag")
	d.cancel()
	s = _sketch(_rect_constraints(true, false), 5)
	d = PointDrag.new()
	d.synchronous = true
	_check(d.begin(s, "C", Vector2(50, 20)), "a corner of the half-dimensioned rectangle starts a drag")
	d.cancel()
	s = _sketch(redundant, 0, false)
	d = PointDrag.new()
	d.synchronous = true
	_check(s.failed_point_ids().is_empty() and not s.on_contradictory_line("B") and s.point_rigidity("B") == "over", "a redundant set the solve did not converge on: the count says over (nothing failed, no contradictory line)")
	_check(not d.begin(s, "B", Vector2(50, 0)) and d.refusal.contains("over-constrained"), "...and the pre-grab rule refuses the point as over-constrained: %s" % d.refusal)
	s = _sketch(_rect_constraints(true, true), 0, true)
	d = PointDrag.new()
	d.synchronous = true
	_check(s.sketch_grounded() and not d.begin(s, "C", Vector2(50, 20)) and d.refusal.contains("fully constrained"), "the whole-sketch case (dof 0, converged, grounded) refuses a point of the rigid rectangle: %s" % d.refusal)
	s = _sketch([_dist("fg", "f", "g", 20.0)], 0, true)
	d = PointDrag.new()
	d.synchronous = true
	_check(not s.sketch_grounded() and d.begin(s, "f", Vector2(30, 40)), "...but a floating sketch with dof 0 is not grounded, so its points drag")
	d.cancel()

	# --- the mobility oracle (spec 13.6): 0 / 1 / 2 directions at first order; -1 when it has no answer
	var Projector := load("res://scripts/motion/sketch_projector.gd")
	s = _sketch(_rect_constraints(true, true), 4)
	_check(_mobility(Projector, s, "C") == 0 and _mobility(Projector, s, "A") == 0 and _mobility(Projector, s, "f") == 2, "mobility: a corner of the rigid rectangle 0, the corner the origin holds 0, a point no constraint reaches 2")
	s = _sketch(_rect_constraints(true, false), 5)
	_check(_mobility(Projector, s, "C") == 1 and _mobility(Projector, s, "D") == 1 and _mobility(Projector, s, "B") == 0, "...without the height C and D can slide along the sides (1), B is held by the width (0)")
	s = _sketch([_dist("of", "O", "f", 50.0)], 1)
	_check(_mobility(Projector, s, "f") == 1, "...a point at a distance from a pinned one moves on its circle (1, at first order)")
	s = _sketch([_con("hp", "horizontal", {"point_a_id": "f", "point_b_id": "g"})], 3)
	_check(_mobility(Projector, s, "f") == 2 and _mobility(Projector, s, "g") == 2, "...a free line kept horizontal: each end still goes anywhere (the pair translates), 2")
	var tangent = _rect_constraints(true, false)
	tangent.append(_con("st", "spline_tangent", {"segment_a_p0": "A", "segment_a_p1": "B", "segment_a_p2": "C", "segment_a_p3": "D", "segment_b_p0": "D", "segment_b_p1": "D", "segment_b_p2": "f", "segment_b_p3": "g"}))
	s = _sketch(tangent, 0, true)
	_check(_mobility(Projector, s, "C") == -1, "...a spline tangency in the group: no answer (-1)")
	d = PointDrag.new()
	d.synchronous = true
	_check(s.sketch_grounded() and not d.begin(s, "C", Vector2(50, 20)) and d.refusal.contains("fully constrained"), "...and the pre-grab rule takes its fallback then (the whole sketch is fully constrained): %s" % d.refusal)
	s = _sketch(_rect_constraints(true, false), 0, true)
	d = PointDrag.new()
	d.synchronous = true
	_check(d.begin(s, "C", Vector2(50, 20)), "...with an answer the oracle decides: the half-dimensioned rectangle's corner moves even if the backend's dof says 0")
	d.cancel()

	# --- entity_states is kept between redraws and recomputed when a solve or an edit changes what it reads
	s = _sketch(_rect_constraints(true, false), 5)
	var first: Dictionary = s.entity_states()
	_check(s.entity_states() == first and is_same(s.entity_states(), first), "entity_states: a second pass with nothing changed is the kept answer (a hover redraw does not recount)")
	var pts_now: Array = []
	for id in s.points:
		pts_now.append({"id": id, "x": s.points[id].x, "y": s.points[id].y, "is_locked": false})
	s._ingest_state({"points": pts_now, "constraints": _rect_constraints(true, true), "solve": {"dof": 4, "converged": true, "solver_reported_failed_constraint_ids": []}})
	_check(_rect_is(_states(s), "fully"), "...and a new solve's state (the height added) is counted afresh: the rectangle turns fully constrained")
	s._ingest_state({"points": pts_now, "constraints": _rect_constraints(true, true), "solve": {"dof": 4, "converged": false, "solver_reported_failed_constraint_ids": ["w"]}})
	_check(_states(s)["ab"] == "over", "...also a failed list")
	s.lines["extra"] = {"a": "f", "b": "g"}
	_check(_states(s).has("extra"), "...and a line added without a solve")

	# --- the view
	var view = View.new()
	root.add_child(view)
	view.setup({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.UP, "n": Vector3.BACK}, Vector2(0.4, 0.3), Vector2(50, 30), 0.004, load("res://ui/didsa_ui_theme.tres"))
	await process_frame
	_check(View._object_colour(false, "free", false, View.OBJECT_COLOUR) == View.OBJECT_COLOUR and View._object_colour(false, "fully", false, View.OBJECT_COLOUR) == View.FULL_COLOUR, "_object_colour: plain stays the base, fully is green")
	_check(View._object_colour(false, "over", false, View.OBJECT_COLOUR) == View.FAILED_COLOUR and View._object_colour(true, "free", false, View.OBJECT_COLOUR) == View.FAILED_COLOUR, "...over, or on the solver's failed list, is red")
	_check(View._object_colour(false, "fully", true, View.OBJECT_COLOUR) == View.CONSTRUCTION_COLOUR and View._object_colour(false, "over", true, View.OBJECT_COLOUR) == View.FAILED_COLOUR, "...construction geometry stays construction-coloured when fully constrained, and shows red when over (the flat app's order: over, construction, fully, plain)")

	s = _sketch(_rect_constraints(true, false), 5)
	view.rebuild(s, [], {})
	var green_half := _count_colour(view, View.FULL_COLOUR)
	var plain_half := _count_colour(view, View.OBJECT_COLOUR)
	s = _sketch(_rect_constraints(true, true), 4) # the same drawing, a different state: the cached pieces must not be reused
	view.rebuild(s, [], {})
	var green_full := _count_colour(view, View.FULL_COLOUR)
	var plain_full := _count_colour(view, View.OBJECT_COLOUR)
	print("SMOKE BENCH info: vertices green / plain, half-dimensioned ", green_half, " / ", plain_half, ", fully dimensioned ", green_full, " / ", plain_full)
	_check(green_half == 0 and plain_half > 0, "half-dimensioned: no line is green, they are all plain")
	_check(green_full > 0 and plain_full > 0 and plain_full < plain_half, "fully dimensioned rectangle: its four lines are green, the separate free line stays plain (a state change redraws an entity whose points did not move)")
	var cons = _rect_constraints(true, true)
	cons.append(_hv("x1", "vertical", "ab", "A", "B"))
	s = _sketch(cons, 4)
	view.rebuild(s, [], {})
	_check(_count_colour(view, View.FAILED_COLOUR) > 0, "a line both horizontal and vertical is drawn red")

	# a drag frame keeps the colours
	s = _sketch(_rect_constraints(true, true), 4)
	view.rebuild(s, [], {})
	var before := [_count_colour(view, View.FULL_COLOUR), _count_colour(view, View.OBJECT_COLOUR), _count_colour(view, View.FAILED_COLOUR)]
	s.points["g"] = Vector2(48.0, 58.0) # the free line's end moves (a drag frame's accepted point)
	view.redraw_moved(s, ["g"])
	var after := [_count_colour(view, View.FULL_COLOUR), _count_colour(view, View.OBJECT_COLOUR), _count_colour(view, View.FAILED_COLOUR)]
	_check(before[0] > 0 and after == before, "a drag frame (redraw_moved) keeps every colour: green rectangle, plain free line: %s -> %s" % [str(before), str(after)])
	s.points["C"] = Vector2(52.0, 20.0)
	s.points["B"] = Vector2(50.0, 1.0)
	view.redraw_moved(s, ["B", "C"])
	_check(_count_colour(view, View.FULL_COLOUR) == before[0], "...also when the moved points are a fully constrained entity's own")

	print("SMOKE ", "PASSED" if failures == 0 else "FAILED %d" % failures)
	quit(1 if failures > 0 else 0)


func only_h_check() -> void:
	var s = _sketch([_con("hp", "horizontal", {"point_a_id": "f", "point_b_id": "g"})], 3)
	_check(_states(s)["F"] == "free" and s.contradictory_points().is_empty(), "...a Horizontal alone is not")
