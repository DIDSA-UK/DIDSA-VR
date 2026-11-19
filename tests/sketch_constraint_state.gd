extends SceneTree
## Constraint state and relations at the session level (S3 of docs/dimension-constraint-parity-plan.md), no backend: the state is read from the
## backend's own wire shapes. Fully / under / over constrained (`constraint_state`: the DOF, `converged` and being tied to the origin), the points and
## entities of `solver_reported_failed_constraint_ids` (red), the status phrase, the glyph owners (the backend sends a Fix as `point_ids` and an Equal radius
## by centre / rim POINTS, so neither had an owner and neither was drawn), what a glyph holds (lit when hovered or picked), Unfix's menu entry, the
## `fully_constrained` signal (the editor ticks the hand) and the view's colours.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_constraint_state.gd  (see tests/README.md)

const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")

var fully_signals := 0


func _on_full() -> void:
	fully_signals += 1


func _state(s, dof: int, converged: bool, failed: Array = [], constraints: Array = []) -> void:
	var pts: Array = []
	for id in s.points:
		pts.append({"id": id, "x": s.points[id].x, "y": s.points[id].y, "is_locked": s.point_locked.get(id, false)})
	s._ingest_state({"points": pts, "constraints": constraints, "solve": {"dof": dof, "converged": converged, "solver_reported_failed_constraint_ids": failed}})
	s._note_state()


func _initialize() -> void:
	var s = SketchSession.new()
	s.sketch_id = "SK"
	s.origin_id = "O"
	s.fully_constrained.connect(_on_full)
	s.points = {"O": Vector2(0, 0), "a": Vector2(10, 0), "b": Vector2(10, 20), "c": Vector2(50, 50), "r": Vector2(60, 50), "c2": Vector2(90, 50), "r2": Vector2(95, 50), "f": Vector2(30, 30), "g": Vector2(40, 30)}
	s._ingest_entities({"entities": [
		{"type": "line", "id": "L1", "start_point_id": "a", "end_point_id": "b"},
		{"type": "line", "id": "L2", "start_point_id": "O", "end_point_id": "a"},
		{"type": "line", "id": "L3", "start_point_id": "f", "end_point_id": "g"},
		{"type": "circle", "id": "C1", "center_point_id": "c", "radius_point_id": "r", "radius_constraint_id": "K1"},
		{"type": "circle", "id": "C2", "center_point_id": "c2", "radius_point_id": "r2", "radius_constraint_id": "K2"}]})

	# --- nothing known / nothing drawn
	var empty = SketchSession.new()
	print("SMOKE no geometry or no solve yet: no state and no phrase: ", empty.constraint_state() == "" and empty.constraint_summary() == "")

	# --- under constrained
	_state(s, 5, true)
	print("SMOKE a sketch with DOF left is under constrained and says how many: ", s.constraint_state() == "under" and s.constraint_summary() == "5 DOF left.", " ", s.constraint_summary())
	print("SMOKE ...and nothing is red: ", s.failed_point_ids().is_empty() and s.failed_entity_ids().is_empty())

	# --- DOF 0 but floating (the solver counts a whole-body move as no freedom): not fully constrained
	s.lines.erase("L1")
	s.lines.erase("L2")
	s.circles.erase("C1")
	s.circles.erase("C2")
	_state(s, 0, true) # only L3 is left, floating
	print("SMOKE DOF 0 with the geometry tied to nothing is NOT fully constrained: ", s.constraint_state() == "under" and not s.is_grounded(), " ", s.constraint_summary())
	s._ingest_entities({"entities": [
		{"type": "line", "id": "L1", "start_point_id": "a", "end_point_id": "b"},
		{"type": "line", "id": "L2", "start_point_id": "O", "end_point_id": "a"},
		{"type": "line", "id": "L3", "start_point_id": "f", "end_point_id": "g"},
		{"type": "circle", "id": "C1", "center_point_id": "c", "radius_point_id": "r", "radius_constraint_id": "K1"},
		{"type": "circle", "id": "C2", "center_point_id": "c2", "radius_point_id": "r2", "radius_constraint_id": "K2"}]})

	# --- fully constrained: tied to the origin through a line and a constraint
	var fixes := {"type": "fixed", "id": "KF", "point_ids": ["f", "g"]}
	var eq := {"type": "equal_radius", "id": "KE", "center1_point_id": "c", "radius1_point_id": "r", "center2_point_id": "c2", "radius2_point_id": "r2"}
	var hz := {"type": "horizontal", "id": "KH", "line_id": "L2"}
	var perp := {"type": "perpendicular", "id": "KP", "line1_id": "L1", "line2_id": "L2"}
	var cons := [fixes, eq, hz, perp]
	fully_signals = 0
	_state(s, 3, true, [], cons)
	print("SMOKE the first state of a sketch never ticks: ", fully_signals == 0)
	_state(s, 0, true, [], cons)
	print("SMOKE DOF 0, converged and tied to the origin: fully constrained, with its phrase: ", s.constraint_state() == "full" and s.constraint_summary() == "Fully constrained.", " ", s.constraint_state())
	print("SMOKE ...reaching it ticks once (the hand), staying there does not: ", fully_signals == 1)
	_state(s, 0, true, [], cons)
	print("SMOKE a second solve in the same state does not tick again: ", fully_signals == 1)
	_state(s, 1, true, [], cons)
	_state(s, 0, true, [], cons)
	print("SMOKE leaving and reaching it again ticks again: ", fully_signals == 2)

	# --- over constrained: the points of the failed constraints go red
	_state(s, 0, false, ["KP", "KE"], cons)
	print("SMOKE a solve that did not converge is over constrained: ", s.constraint_state() == "over" and s.constraint_summary().begins_with("Over-constrained"), " ", s.constraint_state())
	var red: Dictionary = s.failed_point_ids()
	print("SMOKE the failed constraints' points are red (a line's ends, a circle's centre and rim from an Equal radius): ", red.has("a") and red.has("b") and red.has("O") and red.has("c") and red.has("r") and red.has("c2") and red.has("r2") and not red.has("f"), " ", red.keys())
	var red_e: Dictionary = s.failed_entity_ids()
	print("SMOKE ...and so are the entities built on them, not the others: ", red_e.has("L1") and red_e.has("L2") and red_e.has("C1") and red_e.has("C2") and not red_e.has("L3"), " ", red_e.keys())
	_state(s, 0, true, [], cons)
	print("SMOKE solved again, the red goes: ", s.failed_point_ids().is_empty())
	_state(s, 0, false, ["gone"], cons)
	print("SMOKE a failed id that no longer exists is ignored: ", s.failed_point_ids().is_empty() and s.constraint_state() == "over")

	# --- glyph owners, from the backend's own shapes
	_state(s, 0, true, [], [fixes, eq, hz, perp, {"type": "spline_tangent", "id": "KS", "spline_id": "x", "segment_a_p3": "b"}])
	var owners := {}
	for item in s.constraint_items():
		owners["%s@%s" % [item["id"], item["owner"]]] = item["text"]
	print("SMOKE a Fix on two points that are a line's ends is drawn on that line (it had no owner, so no glyph): ", owners.has("KF@L3") and owners.size() >= 1 and owners["KF@L3"] == "F", " ", owners)
	print("SMOKE an Equal radius is drawn on both circles (found by centre point): ", owners.has("KE@C1") and owners.has("KE@C2"), " ", owners.keys())
	print("SMOKE a spline tangent is drawn at the join: ", owners.has("KS@b"))
	print("SMOKE the old glyphs still draw (Horizontal on L2, Perpendicular on both lines): ", owners.has("KH@L2") and owners.has("KP@L1") and owners.has("KP@L2"))
	s.point_locked["c"] = true
	var one := {"type": "fixed", "id": "KG", "point_ids": ["c"]}
	_state(s, 0, true, [], [one])
	var on_point := false
	for item in s.constraint_items():
		on_point = on_point or (item["id"] == "KG" and item["owner"] == "c")
	print("SMOKE a Fix on one point is drawn at that point: ", on_point)
	_state(s, 0, true, [], [{"type": "fixed", "id": "KC", "point_ids": ["c", "r"]}])
	var on_circle := false
	for item in s.constraint_items():
		on_circle = on_circle or (item["id"] == "KC" and item["owner"] == "C1")
	print("SMOKE a Fix on a circle's centre and rim is drawn once, at the circle: ", on_circle and s.constraint_items().size() == 1)

	# --- what a glyph holds
	_state(s, 0, true, [], cons)
	var held: Dictionary = s.constraint_held("KP")
	print("SMOKE a Perpendicular holds its two lines: ", held.has("line:L1") and held.has("line:L2") and held.size() == 2, " ", held.keys())
	held = s.constraint_held("KF")
	print("SMOKE a Fix holds its points: ", held.has("point:f") and held.has("point:g"), " ", held.keys())
	held = s.constraint_held("KE")
	print("SMOKE an Equal radius holds its centre and rim points: ", held.has("point:c") and held.has("point:r2"), " ", held.keys())
	print("SMOKE an unknown id holds nothing: ", s.constraint_held("nope").is_empty())

	# --- Unfix: the menu entry and the constraints it removes
	_state(s, 0, true, [], cons)
	print("SMOKE Fix holds L3 and its points: ", s.fix_constraints_for([{"kind": "line", "id": "L3"}]) == ["KF"] and s.fix_constraints_for([{"kind": "point", "id": "g"}]) == ["KF"])
	print("SMOKE ...and nothing else: ", s.fix_constraints_for([{"kind": "line", "id": "L1"}]).is_empty() and s.fix_constraints_for([{"kind": "circle", "id": "C1"}]).is_empty())
	var ids_with := SketchSelection.options([{"kind": "line", "id": "L3"}], s, []).map(func(o): return o["id"])
	var ids_without := SketchSelection.options([{"kind": "line", "id": "L1"}], s, []).map(func(o): return o["id"])
	print("SMOKE the Select menu offers Unfix after Fix on something fixed, and not on something that is not: ", ids_with.has("unfix") and ids_with.find("unfix") == ids_with.find("fix") + 1 and not ids_without.has("unfix"), " ", ids_with)
	print("SMOKE Unfix is spelled out: ", SketchSelection.TEXT["unfix"] == "Unfix")

	# --- Unfix goes through the routes: one DELETE per Fix, one undo step that fixes the points again
	var calls: Array = []
	s.api = func(method: int, path: String, body) -> Dictionary:
		calls.append([method, path, body])
		return {"ok": true, "json": {}, "code": 200}
	s.selection = [{"kind": "line", "id": "L3"}]
	var r: Dictionary = await s.unfix_selection()
	var deletes := calls.filter(func(c): return int(c[0]) == HTTPClient.METHOD_DELETE)
	print("SMOKE Unfix deletes the Fix constraint of what is picked: ", r["ok"] and deletes.size() == 1 and String(deletes[0][1]).ends_with("/constraints/KF"), " ", calls)
	print("SMOKE ...as one undo step that fixes the Fix's points again: ", s.undo_label() == "unfix" and s._undo.back()["calls"].size() == 1 and s._undo.back()["calls"][0][2] == {"type": "fixed", "entity_id": "L3"})
	s.selection = [{"kind": "line", "id": "L1"}]
	var none: Dictionary = await s.unfix_selection()
	print("SMOKE Unfix with nothing fixed picked is refused with a reason: ", not none["ok"] and String(none["message"]) != "")

	# --- the view
	var View := load("res://scripts/design_table/sketch_view.gd")
	var view = View.new()
	root.add_child(view)
	view.setup({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.UP, "n": Vector3.BACK}, Vector2(0.4, 0.3), Vector2(50, 30), 0.004, load("res://ui/didsa_ui_theme.tres"))
	await process_frame
	s.api = Callable()
	s.points = {"O": Vector2(0, 0), "a": Vector2(10, 0), "b": Vector2(10, 20), "c": Vector2(50, 50), "r": Vector2(60, 50), "c2": Vector2(90, 50), "r2": Vector2(95, 50), "f": Vector2(30, 30), "g": Vector2(40, 30)} # (the fake route's empty answer cleared them)
	_state(s, 0, true, [], cons)
	view.rebuild(s, [], {})
	var colour_full: Color = _first_line_colour(view)
	_state(s, 3, true, [], cons)
	view.rebuild(s, [], {})
	var colour_under: Color = _first_line_colour(view)
	_state(s, 0, false, ["KP"], cons)
	view.rebuild(s, [], {})
	var colour_over: Color = _first_line_colour(view)
	print("SMOKE the sketch's lines are tinted when fully constrained, plain when under, red when they hold a failed constraint: ", colour_full == View.FULL_COLOUR and colour_under == View.OBJECT_COLOUR and colour_over == View.FAILED_COLOUR, " ", [colour_full, colour_under, colour_over])
	# hovering or picking a glyph lights what it holds (here: the Perpendicular's two lines go to the picked look, the circles stay as they were)
	_state(s, 3, true, [], cons)
	view.rebuild(s, [], {})
	var plain := _count_colour(view, view._tokens.warn)
	view.set_annotation_hover("constraint:KP")
	var hovered := _count_colour(view, view._tokens.warn)
	view.set_annotation_hover("")
	var cleared := _count_colour(view, view._tokens.warn)
	s.annotations = [{"kind": "constraint", "id": "KP"}]
	view.rebuild(s, [], {})
	var picked := _count_colour(view, view._tokens.warn)
	print("SMOKE hovering a glyph lights what it holds, leaving it puts that back, picking it lights it again: ", plain == 0 and hovered > 0 and cleared == 0 and picked == hovered, " ", [plain, hovered, cleared, picked])
	quit()


func _count_colour(view, want: Color) -> int:
	var cols: PackedColorArray = view._geo.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var n := 0
	for c in cols:
		if absf(c.r - want.r) < 0.01 and absf(c.g - want.g) < 0.01 and absf(c.b - want.b) < 0.01:
			n += 1
	return n


func _first_line_colour(view) -> Color:
	## The colour of the first vertex of the geometry mesh (the origin axes come first: skip to the first with the object / tint / red hue).
	var mesh: ArrayMesh = view._geo.mesh
	if mesh == null:
		return Color.BLACK
	var cols: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var View := load("res://scripts/design_table/sketch_view.gd")
	for c in cols: # vertex colours are stored in 8 bits: compare with a tolerance
		for want in [View.OBJECT_COLOUR, View.FULL_COLOUR, View.FAILED_COLOUR]:
			if absf(c.r - want.r) < 0.01 and absf(c.g - want.g) < 0.01 and absf(c.b - want.b) < 0.01 and c.a > 0.95:
				return want
	return Color.BLACK
