extends SceneTree
## S6 of docs/dimension-constraint-parity-plan.md: editing what is there, as logic against the fake backend.
##   * A label dragged: `label_candidate` builds the drag's `g` from the dimension's drawn row, the placement the pointer gives is the one saved (PUT .../label) and the
##     label draws at the pointer; the drag's own preview (`label_override`) is not saved and is dropped with the move; Undo puts the old placement back (or the automatic one);
##     a reference (driven) dimension is not draggable; a Delete then Undo brings the dimension back WITH its placement.
##   * The R / diameter switch on an existing circle dimension: a view choice (nothing sent), the label and the value pad read twice the stored radius, an edit sends half.
##   * An angle's side: PATCH {value, quadrant} with what that side measures now (the geometry does not move); Undo sends the old side back.
##   * A full ellipse's axis dimension: drawn tip to tip, its number and `dimension_value` twice the stored value, an edit sends half.
##   * The conflict rule (3.3, second refinement): a conflict at creation is taken back only if the sketch converged before, or the failed list names the new constraint;
##     in a sketch already failing, a constraint the solver does not blame is kept. Checked for the confirm_ghost dimension, the Select menu relation and the drawing
##     paths' inferred relation.
## NOT checked here: the trigger-hold on the real laser (tests/design_table_label_drag.gd), the real backend (tests/e2e_sketch_label_edit.gd).
## Run: "$GODOT" --headless --path . --script res://tests/sketch_label_edit.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const Flow := preload("res://scripts/design_table/dimension_preview.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const TOL := 1e-3

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _params() -> Dictionary:
	return {"offset": 2.0, "arrow": 0.5, "gap": 0.2, "over": 0.3, "centroid": Vector2.ZERO, "text_h": 1.0, "text_w": 3.0}


func _centre(item: Dictionary) -> Vector2:
	return DimLayout.layout(item["spec"], _params())["text_uv"]


func _item(s, id: String) -> Dictionary:
	for it in s.dimension_items():
		if str(it["id"]) == id:
			return it
	return {}


func _session(fake) -> Object:
	var s = Session.new(Callable(fake, "handle"))
	s.owner_part_id = "P"
	await s.open_sketch({"fixed": "XY"})
	return s


func _draw_line(s, a: Vector2, b: Vector2) -> String:
	s.set_tool("line")
	await s.tap({"uv": a})
	await s.tap({"uv": b})
	s.finish_chain()
	return str(s.lines.keys()[-1])


func _puts(fake) -> Array:
	return fake.calls.filter(func(c): return c[0].begins_with("PUT") and c[0].ends_with("/label"))


func _drag_and_undo() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	var line := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": line})
	await s.confirm_ghost("length", 40.0)
	var id := str(fake.cons.keys()[-1])
	var g: Dictionary = s.label_candidate(id)
	_check(not g.is_empty() and g["spec"]["kind"] == "linear", "an existing dimension gives the label drag its candidate (spec from its drawn row)")
	var place: Dictionary = Flow.placement_at(s, g, Vector2(30, 12))
	_check(absf(float(place["offset"]) - 12.0) < TOL and absf(float(place["along"]) - 10.0) < TOL, "the pointer gives the saved placement (offset from the line, along from its middle)")
	s.label_override[id] = place
	_check(_centre(_item(s, id)).distance_to(Vector2(30, 12)) < TOL, "the dragged label is drawn at the pointer before anything is saved")
	_check(_puts(fake).is_empty(), "...and nothing is sent while it is dragged")
	fake.calls.clear()
	var r: Dictionary = await s.move_label(id, place)
	var puts := _puts(fake)
	_check(r["ok"] and puts.size() == 1 and puts[0][0].contains(id) and absf(float(puts[0][1]["offset"]) - 12.0) < TOL, "the drop saves it: PUT .../constraints/{id}/label with that placement")
	_check(not s.label_override.has(id) and _centre(_item(s, id)).distance_to(Vector2(30, 12)) < TOL, "...the preview is replaced by the saved placement (same place)")
	fake.calls.clear()
	await s.undo()
	_check(fake.calls.any(func(c): return c[0].begins_with("DELETE") and c[0].ends_with("/label")), "Undo of the first move deletes the placement (the automatic place returns)")
	_check(not fake.cons[id].has("label") or fake.cons[id].get("label") == null, "...on the backend too")
	# a second move: Undo puts the first back
	await s.move_label(id, {"offset": 5.0, "along": 1.0})
	await s.move_label(id, {"offset": 9.0, "along": 2.0})
	fake.calls.clear()
	await s.undo()
	var back := _puts(fake)
	_check(back.size() == 1 and absf(float(back[0][1]["offset"]) - 5.0) < TOL, "Undo of a later move saves the placement it had before")
	# a placement of a bad pointer leaves the label where it was
	var p2: Dictionary = Flow.placement_at(s, g, Vector2(0, 0))
	_check(not p2.is_empty(), "(a pointer on the line's end still gives a placement)")
	# delete then undo keeps the placement
	await s.toggle_annotation("dimension", id)
	fake.calls.clear()
	await s.delete_annotations()
	await s.undo()
	var remade: String = str(fake.cons.keys()[-1])
	_check(str(remade) != id and fake.cons[remade].has("label") and absf(float(fake.cons[remade]["label"]["offset"]) - 5.0) < TOL, "Delete then Undo brings the dimension back with its saved placement")


func _driven_is_not_draggable() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s.ref_dims = [{"id": "r1", "kind": "distance", "refs": [{"type": "point", "id": "a"}, {"type": "point", "id": "b"}], "value": 5.0}]
	s.points["a"] = Vector2(0, 0)
	s.points["b"] = Vector2(5, 0)
	_check(s.label_candidate("r1").is_empty(), "a reference (driven) dimension has no placement on the backend: it is not draggable")


func _diameter_switch() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s.set_tool("circle")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(5, 0)})
	var cid := str(s.circles.keys()[-1])
	var k := str(s.circles[cid]["k"])
	s.constraints[k] = {"id": k, "type": "distance", "point_a_id": s.circles[cid]["c"], "point_b_id": s.circles[cid]["p"], "distance": 5.0}
	fake.cons[k] = s.constraints[k].duplicate()
	var item := _item(s, k)
	_check(not item.is_empty() and item["spec"]["kind"] == "radius" and str(item["text"]).begins_with("R"), "a circle's size dimension reads as a radius at first")
	_check(s.toggle_diameter(k) and _item(s, k)["spec"]["kind"] == "diameter" and str(_item(s, k)["text"]).begins_with("⌀") and str(_item(s, k)["text"]).contains("10"), "the switch reads it as a diameter: twice the radius")
	_check(absf(float(s.dimension_value(k)["value"]) - 10.0) < TOL, "the value pad then shows the diameter")
	var puts := fake.calls.filter(func(c): return c[0].begins_with("PUT"))
	_check(puts.size() == 1 and puts[0][0].ends_with("/label") and puts[0][1] == {"show": "diameter"}, "the switch saves its choice in the label record: `show` alone, no placement (F5)")
	_check(fake.cons[k].get("label", {}).get("show") == "diameter" and not s.show_writes_pending(), "...and the backend (fake) holds it")
	fake.calls.clear()
	await s.edit_dimension(k, 12.0)
	var patch := fake.calls.filter(func(c): return c[0].begins_with("PATCH"))
	_check(patch.size() == 1 and absf(float(patch[0][1]["value"]) - 6.0) < TOL, "an edit of the diameter sends the radius (half)")
	s.toggle_diameter(k)
	_check(_item(s, k)["spec"]["kind"] == "radius" and absf(float(s.dimension_value(k)["value"]) - 6.0) < TOL, "and back to the radius")
	_check(not s.toggle_diameter("nope"), "only a circle's or arc's size dimension switches")


func _angle_side() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	var l1 := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	var l2 := await _draw_line(s, Vector2(0, 0), Vector2(30, 30))
	fake.cons["ka"] = {"id": "ka", "type": "angle", "line1_id": l1, "line2_id": l2, "angle_degrees": 45.0, "quadrant": 0}
	s.constraints["ka"] = fake.cons["ka"].duplicate()
	var v1: float = s.angle_side_value("ka", 0)
	var v1b: float = s.angle_side_value("ka", 1)
	_check(absf(v1 - 45.0) < 0.01 and absf(v1b - 135.0) < 0.01, "a side measures the angle between its rays now: 45 and the supplement 135")
	fake.calls.clear()
	var r: Dictionary = await s.set_angle_side("ka")
	var patch := fake.calls.filter(func(c): return c[0].begins_with("PATCH"))
	_check(r["ok"] and patch.size() == 1 and int(patch[0][1]["quadrant"]) == 1 and absf(float(patch[0][1]["value"]) - 135.0) < 0.01, "'Other side' sends the next quadrant with the angle it measures there (the geometry stays)")
	fake.calls.clear()
	await s.undo()
	var back := fake.calls.filter(func(c): return c[0].begins_with("PATCH"))
	_check(back.size() == 1 and int(back[0][1]["quadrant"]) == 0 and absf(float(back[0][1]["value"]) - 45.0) < 0.01, "Undo sends the old side and value")
	_check(not (await s.set_angle_side("nope"))["ok"], "only an angle has a side")


func _ellipse_axis() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s.points = {"c": Vector2(0, 0), "ma": Vector2(10, 0), "man": Vector2(-10, 0), "mi": Vector2(0, 4), "mnn": Vector2(0, -4)}
	s.ellipses["e1"] = {"c": "c", "ma": "ma", "mi": "mi", "man": "man", "mnn": "mnn", "km": "km", "kn": "kn", "construction": false}
	s.constraints["km"] = {"id": "km", "type": "distance", "point_a_id": "c", "point_b_id": "ma", "distance": 10.0, "label": {"offset": 3.0, "along": 2.0}}
	fake.cons["km"] = s.constraints["km"].duplicate()
	var item := _item(s, "km")
	_check(not item.is_empty() and item["spec"]["a"].distance_to(Vector2(-10, 0)) < TOL and item["spec"]["b"].distance_to(Vector2(10, 0)) < TOL, "an ellipse's axis dimension is drawn tip to tip")
	_check(str(item["text"]) == "20.00" or str(item["text"]) == "20" or str(item["text"]).begins_with("20"), "...with twice the stored value")
	_check(absf(float(s.dimension_value("km")["value"]) - 20.0) < TOL, "dimension_value reads the same twice-the-stored number")
	_check(_centre(item).distance_to(Vector2(2, 3)) < TOL, "a placement saved for it is read from the tip-to-tip line (offset 3, along 2 from the middle)")
	# the candidates are drawn on the same line, so a dropped placement is the one it reads
	s.set_tool("dimension")
	await s.select({"kind": "ellipse", "id": "e1"})
	var cands: Array = s.ghosts
	var major := cands.filter(func(c): return c["key"] == "majorradius")
	var major_dia := cands.filter(func(c): return c["key"] == "majordiameter")
	_check(major.size() == 1 and major[0]["spec"]["a"].distance_to(Vector2(0, 0)) < TOL and str(major[0]["show"]) == "semi", "the full ellipse's Radius candidate is the semi-axis, centre to tip (F5)")
	_check(major_dia.size() == 1 and major_dia[0]["spec"]["a"].distance_to(Vector2(-10, 0)) < TOL and str(major_dia[0]["show"]) == "full", "...and its Diameter candidate tip to tip")
	fake.calls.clear()
	await s.edit_dimension("km", 30.0)
	var patch := fake.calls.filter(func(c): return c[0].begins_with("PATCH"))
	_check(patch.size() == 1 and absf(float(patch[0][1]["value"]) - 15.0) < TOL, "an edit of the shown 30 stores 15")


func _conflict_rule() -> void:
	# a sketch that converged: a conflicting new dimension is taken back
	var fake := Fake.new()
	var s = await _session(fake)
	var line := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": line})
	fake.converge = false
	var r: Dictionary = await s.confirm_ghost("length", 41.0)
	_check(not r["ok"] and fake.cons.is_empty(), "converged before, conflicting now: the new dimension is taken back")
	# already failing: kept unless named
	fake.converge = true
	await s.select({"kind": "line", "id": line})
	await s.confirm_ghost("length", 40.0)
	var first := str(fake.cons.keys()[-1])
	fake.converge = false
	fake.failed_ids = [first] # a kept conflict
	await s.refresh(false)
	_check(not s.converged, "(the sketch now fails)")
	var l2 := await _draw_line(s, Vector2(0, 10), Vector2(40, 10))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l2})
	var count := fake.cons.size()
	fake.failed_ids = [first]
	r = await s.confirm_ghost("length", 40.0)
	_check(r["ok"] and fake.cons.size() == count + 1, "already failing and the failed list does not name the new dimension: it is kept")
	var l3 := await _draw_line(s, Vector2(0, 20), Vector2(40, 20))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l3})
	count = fake.cons.size()
	var named := "k%d" % (fake.n + 1)
	fake.failed_ids = [first, named]
	r = await s.confirm_ghost("length", 33.0)
	_check(not r["ok"] and fake.cons.size() == count, "already failing, and the failed list names the new dimension: taken back")
	# the Select menu relation
	fake.failed_ids = [first]
	await s.select({"kind": "line", "id": l2})
	count = fake.cons.size()
	var menu: Dictionary = await s.apply_menu("horizontal")
	_check(menu["ok"] and fake.cons.size() == count + 1, "a Select menu relation in an already failing sketch is kept when the failed list does not name it")
	await s.select({"kind": "line", "id": line})
	count = fake.cons.size()
	named = "k%d" % (fake.n + 1)
	fake.failed_ids = [first, named]
	menu = await s.apply_menu("vertical")
	_check(not menu["ok"] and fake.cons.size() == count, "...and taken back when the failed list names it")
	# the drawing path's inferred relation
	fake.failed_ids = [first]
	await s.refresh(false)
	count = fake.cons.size()
	await s._finish_inferred("line", [], {"type": "horizontal", "line_id": l2}, {"kind": "horizontal"})
	_check(fake.cons.size() == count + 1, "an inferred relation of a drawn line is kept in an already failing sketch the failed list does not blame it for")
	count = fake.cons.size()
	fake.failed_ids = [first, "k%d" % (fake.n + 1)]
	await s._finish_inferred("line", [], {"type": "vertical", "line_id": l2}, {"kind": "vertical"})
	_check(fake.cons.size() == count, "...and taken back (the shape stays) when it names it")
	# a sketch that converged before takes a conflicting inferred relation back
	var fake2 := Fake.new()
	var s2 = await _session(fake2)
	var m := await _draw_line(s2, Vector2(0, 0), Vector2(40, 0))
	fake2.converge = false
	await s2._finish_inferred("line", [], {"type": "horizontal", "line_id": m}, {"kind": "horizontal"})
	_check(fake2.cons.is_empty(), "a sketch that converged before takes a conflicting inferred relation back")


func _initialize() -> void:
	await _drag_and_undo()
	await _driven_is_not_draggable()
	await _diameter_switch()
	await _angle_side()
	await _ellipse_axis()
	await _conflict_rule()
	print("SMOKE label edit failures: ", failures)
	quit(1 if failures > 0 else 0)
