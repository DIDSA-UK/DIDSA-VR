extends SceneTree
## Parity follow-ups F5 (docs/parity-followups-investigation.md), as logic against the fake backend:
##   * C5: typing an existing two-line angle, point-to-line distance or line-to-line distance again PATCHes the one already there (either line order): one constraint, the new
##     value; an angle's side (quadrant) goes with it, in the constraint's own line order.
##   * Names (A1): the backend's `number` is read from the state (points, constraints, reference dimensions) and the export's `numbers` map; `name_of` gives `Line 3`, `Origin`,
##     `Part corner 2`, `D4 Length 40`, `Coincident 2`; with no numbers (an older backend) the position rule gives one; the breadcrumb shows the name, never the id.
##   * C4 / decision 10: the semi / full toggle of a full ellipse's axis (the stored value stays the semi-axis; the pad shows and an edit stores the value on show) and of an
##     elliptical arc's axis (radial layout, kind `radius` / `diameter`, placement {angle, leg} read and saved); the Radius / Diameter and semi / full choices are saved in the
##     label record (`show`, alone), read back, and never wiped by a placement PUT (nor re-sent by an Undo of a label move).
##   * An Undo that re-creates a constraint sends its old `number`.
## NOT checked here: the real backend (tests/e2e_sketch_dimension_edits.gd), the look on a headset.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_dimension_edits.gd  (see tests/README.md)

const Session := preload("res://scripts/design_table/sketch_session.gd")
const Flow := preload("res://scripts/design_table/dimension_preview.gd")
const Crumbs := preload("res://scripts/design_table/selection_breadcrumbs.gd")
const Selection := preload("res://scripts/design_table/sketch_selection.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const TOL := 1e-3

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


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


func _of_type(fake, type: String) -> Array:
	return fake.cons.values().filter(func(c): return str(c.get("type", "")) == type)


func _calls(fake, verb: String, tail := "") -> Array:
	return fake.calls.filter(func(c): return c[0].begins_with(verb) and c[0].ends_with(tail))


func _item(s, id: String) -> Dictionary:
	for it in s.dimension_items():
		if str(it["id"]) == id:
			return it
	return {}


func _two_lines() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	var l1 := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	var l2 := await _draw_line(s, Vector2(0, 10), Vector2(20, 40))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l1})
	await s.select({"kind": "line", "id": l2})
	var made: Dictionary = await s.confirm_ghost("angle", 30.0)
	_check(bool(made["ok"]) and _of_type(fake, "angle").size() == 1, "the angle between two lines is made")
	# typed again, the same lines in the other order
	s.clear_selection()
	await s.select({"kind": "line", "id": l2})
	await s.select({"kind": "line", "id": l1})
	fake.calls.clear()
	var again: Dictionary = await s.confirm_ghost("angle", 45.0)
	var angles := _of_type(fake, "angle")
	_check(bool(again["ok"]) and angles.size() == 1 and absf(float(angles[0]["angle_degrees"]) - 45.0) < TOL, "typing the angle again leaves ONE constraint, with the new value (C5)")
	_check(_calls(fake, "PATCH").size() == 1 and _calls(fake, "POST", "/constraints").is_empty(), "...by a PATCH, not a second constraint")
	# a side chosen with the laser goes with the patch, in the constraint's own line order (the lines were picked the other way round: its two flip bits swap)
	s.clear_selection()
	await s.select({"kind": "line", "id": l2})
	await s.select({"kind": "line", "id": l1})
	var g: Dictionary = s.ghost("angle")
	var sided := Flow.with_side(s, g, 1)
	fake.calls.clear()
	await s.confirm_ghost("angle", 50.0, sided)
	var patch := _calls(fake, "PATCH")
	_check(patch.size() == 1 and patch[0][1].has("quadrant") and int(patch[0][1]["quadrant"]) == 2, "the side goes with the patch, its flip bits swapped for the other line order")
	_check(_of_type(fake, "angle").size() == 1, "...still one angle")


func _point_line() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	var l1 := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	var l2 := await _draw_line(s, Vector2(5, 20), Vector2(30, 25))
	var pt := str(s.lines[l2]["a"])
	s.set_tool("dimension")
	await s.select({"kind": "point", "id": pt})
	await s.select({"kind": "line", "id": l1})
	var made: Dictionary = await s.confirm_ghost("perpendicular", 20.0)
	_check(bool(made["ok"]) and _of_type(fake, "point_line_distance").size() == 1, "a point's distance to a line is made")
	s.clear_selection()
	await s.select({"kind": "point", "id": pt})
	await s.select({"kind": "line", "id": l1})
	fake.calls.clear()
	await s.confirm_ghost("perpendicular", 12.0)
	var rows := _of_type(fake, "point_line_distance")
	_check(rows.size() == 1 and absf(float(rows[0]["distance"]) - 12.0) < TOL and _calls(fake, "PATCH").size() == 1, "typed again: one constraint, the new value (C5)")


func _line_line() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	var l1 := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	var l2 := await _draw_line(s, Vector2(0, 20), Vector2(40, 20))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l1})
	await s.select({"kind": "line", "id": l2})
	await s.confirm_ghost("lineDistance", 20.0)
	_check(_of_type(fake, "line_distance").size() == 1, "the distance between two parallel lines is made")
	s.clear_selection()
	await s.select({"kind": "line", "id": l2})
	await s.select({"kind": "line", "id": l1})
	fake.calls.clear()
	await s.confirm_ghost("lineDistance", 25.0)
	var rows := _of_type(fake, "line_distance")
	_check(rows.size() == 1 and absf(float(rows[0]["distance"]) - 25.0) < TOL and _calls(fake, "PATCH").size() == 1, "typed again (the lines the other way round): one constraint, the new value (C5)")


func _names() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s._ingest_state({"points": [{"id": "o", "x": 0, "y": 0, "number": null}, {"id": "p", "x": 1, "y": 0, "number": 12.0}, {"id": "q", "x": 2, "y": 0, "number": 2.0, "is_reference": true}, {"id": "h", "x": 3, "y": 0, "number": 1.0, "is_reference": true}],
		"constraints": [{"id": "d", "type": "distance", "point_a_id": "p", "point_b_id": "q", "distance": 40.0, "orientation": "linear", "number": 4.0}, {"id": "c", "type": "coincident", "number": 2.0}],
		"reference_dimensions": [{"id": "rd", "kind": "distance", "refs": [], "value": 1.0, "number": 5.0}], "solve": {}})
	s._ingest_entities({"entities": [{"type": "line", "id": "l", "start_point_id": "p", "end_point_id": "q"}, {"type": "ellipse_arc", "id": "ea", "center_point_id": "p", "major_point_id": "q", "minor_point_id": "q", "start_point_id": "p", "end_point_id": "q"}],
		"numbers": {"l": 3.0, "ea": 1.0}, "reference_ids": ["q", "h"], "external_references": [{"point_id": "h", "kind": "circle_centre"}]})
	s.origin_id = "o"
	_check(s.name_of("point", "p") == "Point 12" and s.name_of("point", "o") == "Origin", "a point is `Point 12` and the origin `Origin`")
	_check(s.name_of("point", "q") == "Part corner 2" and s.name_of("point", "h") == "Hole centre 1", "a part reference point is `Part corner 2` / `Hole centre 1`")
	_check(s.name_of("line", "l") == "Line 3" and s.name_of("ellipse_arc", "ea") == "Ellipse Arc 1", "an entity is its kind and number (`Line 3`, `Ellipse Arc 1`)")
	_check(s.name_of("dimension", "d") == "D4 Length 40", "a dimension is `D4` with its kind and value: " + s.name_of("dimension", "d"))
	_check(s.name_of("constraint", "c") == "Coincident 2", "a relation is its type and number (`Coincident 2`)")
	_check(s.number_of("rd") == 5, "a reference dimension's number is read too")
	var crumb: Array = Crumbs.chain([{"kind": "line", "id": "9b1f3c2e-4d5a-4e6f-8a7b-0c1d2e3f4a5b", "name": "Line 3"}], {"sketch_name": "Sketch 2"})
	_check(str(crumb[0]["text"]) == "Line 3" and str(crumb[1]["text"]) == "Sketch 2", "the breadcrumb shows the name and the open sketch's feature name, never the id")
	var bare: Array = Crumbs.chain([{"kind": "line", "id": "9b1f3c2e-4d5a-4e6f-8a7b-0c1d2e3f4a5b"}])
	_check(not str(bare[0]["text"]).contains("9b1f"), "even with no name the id is not shown")
	# an older backend: no numbers, the position rule
	var old = await _session(Fake.new())
	old.lines["a"] = {"a": "x", "b": "y"}
	old.lines["b"] = {"a": "x", "b": "y"}
	_check(old.name_of("line", "b") == "Line 2" and old.name_of("circle", "zzz") == "Circle", "with no number the name falls back to the place in its kind (`Line 2`), never an id")


func _show_choice() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s.set_tool("circle")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(5, 0)})
	var cid := str(s.circles.keys()[-1])
	var k := str(s.circles[cid]["k"])
	s.constraints[k] = {"id": k, "type": "distance", "point_a_id": s.circles[cid]["c"], "point_b_id": s.circles[cid]["p"], "distance": 5.0}
	fake.cons[k] = s.constraints[k].duplicate()
	s.toggle_diameter(k)
	_check(fake.cons[k]["label"] == {"show": "diameter"}, "Show diameter is saved as `show` alone")
	# a placement saved afterwards (a label dragged) does not wipe it, locally or on the backend
	fake.calls.clear()
	await s.save_label(k, {"angle": 30.0, "leg": 2.0})
	var lab: Dictionary = fake.cons[k]["label"]
	_check(lab.get("show") == "diameter" and absf(float(lab.get("angle", 0.0)) - 30.0) < TOL, "a placement PUT keeps the saved `show` (backend and session)")
	_check(not _calls(fake, "PUT", "/label")[0][1].has("show"), "...and it does not send one")
	# the next solve brings the choice back from the backend
	s.diameter_shown.clear()
	await s.refresh(true)
	_check(s.show_of(k) == "diameter" and float(s.dimension_value(k)["value"]) == 10.0, "the choice is read back with the constraint list")
	# an Undo of a label move puts the old placement back and does not re-send `show`
	await s.move_label(k, {"angle": 50.0, "leg": 4.0})
	fake.calls.clear()
	await s.undo()
	var undone := _calls(fake, "PUT", "/label")
	_check(undone.size() == 1 and not undone[0][1].has("show") and absf(float(undone[0][1]["angle"]) - 30.0) < TOL, "Undo of a label move sends the old placement only")
	_check(fake.cons[k]["label"].get("show") == "diameter", "...and the diameter is still saved")
	# a dimension made as a Diameter is saved as one
	var fake2 := Fake.new()
	var s2 = await _session(fake2)
	s2.set_tool("circle")
	await s2.tap({"uv": Vector2(0, 0)})
	await s2.tap({"uv": Vector2(5, 0)})
	var c2 := str(s2.circles.keys()[-1])
	var k2 := str(s2.circles[c2]["k"])
	s2.constraints[k2] = {"id": k2, "type": "distance", "point_a_id": s2.circles[c2]["c"], "point_b_id": s2.circles[c2]["p"], "distance": 5.0}
	fake2.cons[k2] = s2.constraints[k2].duplicate()
	s2.set_tool("dimension")
	await s2.select({"kind": "circle", "id": c2})
	await s2.confirm_ghost("diameter", 12.0)
	_check(fake2.cons[k2].get("label", {}).get("show") == "diameter" and absf(float(fake2.cons[k2]["distance"]) - 6.0) < TOL, "a dimension made with the Diameter candidate is saved as diameter (radius stored: 6)")


func _full_ellipse_axis() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s.points = {"c": Vector2(0, 0), "ma": Vector2(10, 0), "man": Vector2(-10, 0), "mi": Vector2(0, 4), "mnn": Vector2(0, -4)}
	s.ellipses["e1"] = {"c": "c", "ma": "ma", "mi": "mi", "man": "man", "mnn": "mnn", "km": "km", "kn": "kn", "construction": false}
	fake.points = s.points.duplicate() # (a refresh takes the points from the fake)
	s.constraints["km"] = {"id": "km", "type": "distance", "point_a_id": "c", "point_b_id": "ma", "distance": 10.0}
	fake.cons["km"] = s.constraints["km"].duplicate()
	_check(s.is_axis_dimension("km") and s.shows_full_axis("km") and s.default_show("km") == "full", "a full ellipse's axis reads as the full axis when nothing is saved")
	_check(absf(float(s.dimension_value("km")["value"]) - 20.0) < TOL, "...twice the stored value")
	s.toggle_axis("km")
	var item := _item(s, "km")
	_check(fake.cons["km"]["label"] == {"show": "semi"} and absf(float(s.dimension_value("km")["value"]) - 10.0) < TOL, "Show semi-axis: saved as `show`, the value is the stored 10")
	_check(item["spec"]["a"].distance_to(Vector2(0, 0)) < TOL and item["spec"]["b"].distance_to(Vector2(10, 0)) < TOL, "...drawn centre to tip")
	fake.calls.clear()
	await s.edit_dimension("km", 12.0)
	_check(absf(float(_calls(fake, "PATCH")[0][1]["value"]) - 12.0) < TOL, "an edit with the semi-axis shown stores what is typed (12)")
	s.toggle_axis("km")
	fake.calls.clear()
	await s.edit_dimension("km", 80.0)
	_check(absf(float(_calls(fake, "PATCH")[0][1]["value"]) - 40.0) < TOL, "show full, type 80: stored 40")
	_check(fake.cons["km"]["label"].get("show") == "full", "...and the choice is full")
	_check(not s.toggle_axis("nope"), "only an axis dimension toggles")
	var opts: Array = Selection.annotation_options([{"kind": "dimension", "id": "km"}], [], s)
	_check(opts.any(func(o): return o["id"] == "axis_toggle" and o["text"] == "Show semi-axis" and o["group"] == "Edit"), "the EDIT group offers `Show semi-axis` while the full axis is shown")
	# a candidate made as the Radius of the axis is saved as semi
	s.set_tool("dimension")
	await s.select({"kind": "ellipse", "id": "e1"})
	fake.calls.clear()
	await s.confirm_ghost("majorradius", 11.0)
	_check(fake.cons["km"]["label"].get("show") == "semi" and absf(float(fake.cons["km"]["distance"]) - 11.0) < TOL, "a dimension made with the semi-axis candidate reads as the semi-axis")


func _arc_axis() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	s.points = {"c": Vector2(0, 0), "ma": Vector2(10, 5), "mi": Vector2(-5, 10), "es": Vector2(10, 5), "ee": Vector2(-10, -5)}
	fake.points = s.points.duplicate()
	s.ellipse_arcs["a1"] = {"c": "c", "ma": "ma", "mi": "mi", "s": "es", "e": "ee", "construction": false}
	s.constraints["ka"] = {"id": "ka", "type": "distance", "point_a_id": "c", "point_b_id": "ma", "distance": 11.1803, "orientation": "linear", "label": {"angle": 90.0, "leg": 3.0}}
	fake.cons["ka"] = s.constraints["ka"].duplicate()
	_check(s.is_axis_dimension("ka") and not s.shows_full_axis("ka") and s.default_show("ka") == "semi", "an elliptical arc's axis reads centre to tip (the stored value) when nothing is saved")
	var item := _item(s, "ka")
	var tip := Vector2(10, 5)
	_check(not item.is_empty() and item["spec"]["kind"] == "radius" and str(item["text"]).begins_with("R"), "its semi-axis is a radius leader")
	var want_u := Vector2.from_angle(tip.angle() + PI / 2.0)
	_check((item["spec"]["u"] as Vector2).distance_to(want_u) < 0.01 and absf(float(item["spec"]["label_r"]) - (tip.length() + 3.0)) < TOL, "the flat app's saved radial placement {angle 90, leg 3} is read")
	s.toggle_axis("ka")
	item = _item(s, "ka")
	_check(item["spec"]["kind"] == "diameter" and str(item["text"]).begins_with("⌀") and absf(float(s.dimension_value("ka")["value"]) - 22.3606) < 0.01, "Show full axis: the diameter style, twice the value")
	_check(fake.cons["ka"]["label"].get("show") == "full" and absf(float(fake.cons["ka"]["label"].get("angle", 0.0)) - 90.0) < TOL, "...saved as `show`, the placement kept")
	# the candidates: radial, placement saved, show carried
	s.constraints.erase("ka")
	fake.cons.erase("ka")
	s.set_tool("dimension")
	await s.select({"kind": "ellipse_arc", "id": "a1"})
	var cands: Array = s.ghosts
	var major := cands.filter(func(c): return c["key"] == "majorradius")
	var major_dia := cands.filter(func(c): return c["key"] == "majordiameter")
	_check(major.size() == 1 and major[0]["spec"]["kind"] == "radius" and not bool(major[0].get("place_unsaved", false)) and str(major[0]["show"]) == "semi", "the arc's Radius candidate is a radial leader whose placement is saved")
	_check(major_dia.size() == 1 and major_dia[0]["spec"]["kind"] == "diameter" and str(major_dia[0]["show"]) == "full", "...and its Diameter candidate the circle-diameter style")
	var dropped: Dictionary = major_dia[0].duplicate(true)
	dropped["place"] = {"angle": 20.0, "leg": 4.0}
	fake.calls.clear()
	var made: Dictionary = await s.confirm_ghost("majordiameter", 22.0, dropped)
	var made_id := ""
	for id in fake.cons:
		made_id = str(id)
	var label: Dictionary = fake.cons[made_id].get("label", {}) if fake.cons.has(made_id) else {}
	_check(bool(made["ok"]) and absf(float(label.get("angle", 0.0)) - 20.0) < TOL and absf(float(label.get("leg", 0.0)) - 4.0) < TOL and label.get("show") == "full", "a dropped axis dimension saves its radial placement and its `full` reading in one record")
	_check(made_id != "" and absf(float(fake.cons[made_id]["distance"]) - 11.0) < TOL, "...the stored value is the semi-axis (22 typed as the full axis stores 11)")


func _undo_number() -> void:
	var fake := Fake.new()
	var s = await _session(fake)
	var l1 := await _draw_line(s, Vector2(0, 0), Vector2(40, 0))
	s.set_tool("dimension")
	await s.select({"kind": "line", "id": l1})
	await s.confirm_ghost("length", 40.0)
	var id := str(fake.cons.keys()[-1])
	fake.cons[id]["number"] = 4.0
	await s.refresh(false)
	s.annotations.append({"kind": "dimension", "id": id})
	fake.calls.clear()
	await s.delete_annotations()
	await s.undo()
	var posts := _calls(fake, "POST", "/constraints")
	_check(posts.size() == 1 and int(posts[0][1].get("number", -1)) == 4, "an Undo that re-creates a dimension sends its old number (D4 stays D4)")


func _initialize() -> void:
	await _two_lines()
	await _point_line()
	await _line_line()
	await _names()
	await _show_choice()
	await _full_ellipse_axis()
	await _arc_axis()
	await _undo_number()
	print("SMOKE dimension edits failures: ", failures)
	quit(1 if failures > 0 else 0)
