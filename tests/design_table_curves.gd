extends SceneTree
## The Ellipse, Ellipse Arc, Spline and Text sketch tools (Phase 6.6) at the session level, fake backend. Taps become the right create bodies (the ellipse's short radius is the
## third tap's distance off the long axis, clamped to the long radius; the arc's start / end are parametric angles); a spline waits for Finish and refuses fewer than two points;
## Text refuses empty content and sends content / font / size / turn; one Undo step each (the delete of that entity). Ingest: the entity lists are read from the export, their
## outlines are sampled (an ellipse's extremes, an arc's half, a spline's through-points), the laser's nearest search finds them (a point wins over a curve), Select's menu offers
## Construction and Delete for them, Delete and Construction use the right routes, an ellipse's Dimension offers major / minor radius from its constraints.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_curves.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")
const SketchSession := preload("res://scripts/design_table/sketch_session.gd")


func post(rig, suffix: String) -> Array:
	var all: Array = rig.fake.calls.filter(func(c): return String(c[0]).begins_with("POST /sketch/sketches/") and String(c[0]).ends_with(suffix))
	return all.back() if not all.is_empty() else []


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	await rig.draw_rectangle()
	var s = ed.session
	# --- Ellipse
	table.manager.activate("ellipse")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 0)})
	var r: Dictionary = await s.tap({"uv": Vector2(3, 8)})
	var e := post(rig, "/ellipses")
	print("SMOKE three taps make one ellipse: centre, major point, minor radius 8 (the third tap's distance off the long axis): ", r["done"] and not e.is_empty() and absf(float(e[1]["minor_radius"]) - 8.0) < 0.001 and e[1].has("center_point_id") and e[1].has("major_point_id"), " ", e)
	print("SMOKE ...one Undo step deletes it: ", s.undo_label() == "ellipse")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(10, 0)})
	await s.tap({"uv": Vector2(0, 99)})
	e = post(rig, "/ellipses")
	print("SMOKE a short radius bigger than the long one is clamped to it: ", absf(float(e[1]["minor_radius"]) - 10.0) < 0.001, " ", e[1]["minor_radius"])
	# --- Ellipse arc
	table.manager.activate("ellipse_arc")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(20, 0)})
	await s.tap({"uv": Vector2(0, 10)})
	await s.tap({"uv": Vector2(20, 0)})
	r = await s.tap({"uv": Vector2(-20, 0)})
	var a := post(rig, "/ellipse-arcs")
	print("SMOKE five taps make an ellipse arc with parametric start 0 and end pi (right end to left end): ", r["done"] and not a.is_empty() and absf(float(a[1]["start_angle"])) < 0.001 and absf(float(a[1]["end_angle"]) - PI) < 0.001 and absf(float(a[1]["minor_radius"]) - 10.0) < 0.001, " ", a)
	# --- Spline
	table.manager.activate("spline")
	await s.tap({"uv": Vector2(0, 0)})
	var refused: Dictionary = await s.finish_spline()
	print("SMOKE one point is not a spline: ", not refused["ok"] and post(rig, "/splines").is_empty())
	await s.tap({"uv": Vector2(20, 15)})
	await s.tap({"uv": Vector2(40, 0)})
	ed._update_options()
	print("SMOKE taps only collect (the panel's Finish counts three): ", s.pending.size() == 3 and post(rig, "/splines").is_empty() and table.props.option_button("finish_spline").text.contains("3") and not table.props.option_button("finish_spline").disabled)
	var done: Dictionary = await s.finish_spline()
	var sp := post(rig, "/splines")
	print("SMOKE Finish posts the three through-points in order, once: ", done["ok"] and sp[1]["through_point_ids"].size() == 3 and s.pending.is_empty() and s.undo_label() == "spline")
	# --- Text
	table.manager.activate("text")
	await rig.frames(2)
	print("SMOKE Text's panel shows the words, font, size and turn: ", table.props.option_ids() == ["text_edit", "text_font", "text_size", "text_rot"])
	r = await s.tap({"uv": Vector2(5, 5)})
	print("SMOKE placing with nothing typed is refused, and says why: ", not r["ok"] and String(r["message"]).contains("Type the text") and post(rig, "/texts").is_empty())
	s.text_content = "HELLO"
	ed.option_typed("text_size", "12")
	ed.option_typed("text_rot", "-30")
	await ed.on_option("text_font")
	await ed.on_option("text_font")
	r = await s.tap({"uv": Vector2(5, 5)})
	var t := post(rig, "/texts")
	print("SMOKE a tap posts the text: content, font (the second in the list), size 12, turn -30 (a negative turn is allowed): ", r["done"] and t[1]["content"] == "HELLO" and t[1]["font"] == "Lato" and t[1]["size"] == 12.0 and t[1]["rotation_degrees"] == -30.0 and t[1].has("anchor_point_id"), " ", t)
	print("SMOKE the fonts are the backend's allow-list names: ", ed.FONTS.size() == 10 and ed.FONTS[0] == "Open Sans")
	# --- Ingest and pick
	s.points = {"c": Vector2(0, 0), "ma": Vector2(20, 0), "mi": Vector2(0, 10), "es": Vector2(20, 0), "ee": Vector2(-20, 0), "p1": Vector2(0, 0), "p2": Vector2(20, 15), "p3": Vector2(40, 0), "an": Vector2(30, -20)}
	s._ingest_entities({"entities": [
		{"type": "ellipse", "id": "E1", "center_point_id": "c", "major_point_id": "ma", "minor_point_id": "mi", "major_constraint_id": "KM", "minor_constraint_id": "KN"},
		{"type": "ellipse_arc", "id": "A1", "center_point_id": "c", "major_point_id": "ma", "minor_point_id": "mi", "start_point_id": "es", "end_point_id": "ee"},
		{"type": "spline", "id": "S1", "through_point_ids": ["p1", "p2", "p3"], "control_point_ids": []},
		{"type": "text", "id": "T1", "anchor_point_id": "an", "content": "HI", "font": "Roboto", "size": 10.0, "rotation_degrees": 0.0}]})
	var el: Array = s.outline_of("ellipse", "E1")
	var ys: Array = el.map(func(p): return p.y)
	print("SMOKE the ellipse's outline spans its radii: ", el.size() > 20 and absf(ys.max() - 10.0) < 0.01 and absf(ys.min() + 10.0) < 0.01)
	var arc: Array = s.outline_of("ellipse_arc", "A1")
	print("SMOKE the arc's outline is the upper half (right end to left end, through +y): ", arc.size() > 10 and arc.all(func(p): return p.y > -0.001) and absf(arc.map(func(p): return p.y).max() - 10.0) < 0.05 and arc[0].distance_to(Vector2(20, 0)) < 0.01)
	var spl: Array = s.outline_of("spline", "S1")
	print("SMOKE the spline's outline runs from its first through-point to its last: ", spl.size() > 16 and spl[0].distance_to(Vector2(0, 0)) < 0.01 and spl[spl.size() - 1].distance_to(Vector2(40, 0)) < 0.01 and absf(spl.map(func(p): return p.y).max() - 15.0) < 5.0)
	s.text_outlines["T1"] = [[Vector2(30, -20), Vector2(35, -20), Vector2(35, -12), Vector2(30, -12)]]
	var kinds := {"E1": [Vector2(14.14, 7.07), "ellipse"], "A1": [Vector2(14.14, 7.07), "ellipse_arc"], "S1": [spl[spl.size() / 4], "spline"], "T1": [Vector2(32, -20), "text"]}
	s.ellipse_arcs.erase("A1") # the arc and the ellipse share a rim: look them up separately
	var found := true
	for id in ["E1", "S1", "T1"]:
		var hit: Dictionary = s.nearest_entity(kinds[id][0], 1.0)
		found = found and hit.get("kind", "") == kinds[id][1] and hit.get("id", "") == id
		if hit.get("id", "") != id:
			print("  (miss) ", id, " ", kinds[id][0], " -> ", hit)
	print("SMOKE the laser's nearest search finds the ellipse, the spline and the text: ", found)
	print("SMOKE ...a point beats a curve through it (the ellipse's major point): ", s.nearest_entity(Vector2(20, 0.4), 1.0).get("kind", "") == "point")
	var menu: Array = SketchSelection.options([{"kind": "ellipse", "id": "E1"}, {"kind": "text", "id": "T1"}], s, [])
	print("SMOKE Select's menu for them offers Construction and Delete: ", menu.any(func(o): return o["id"] == "construction") and menu.any(func(o): return o["id"] == "delete"))
	s.selection = [{"kind": "ellipse", "id": "E1"}, {"kind": "spline", "id": "S1"}, {"kind": "text", "id": "T1"}]
	rig.fake.calls.clear()
	await s.delete_selection()
	var deletes: Array = rig.fake.calls.filter(func(c): return String(c[0]).begins_with("DELETE")).map(func(c): return String(c[0]).get_slice("/", 4) + "/" + String(c[0]).get_slice("/", 5))
	print("SMOKE Delete uses each kind's own route: ", deletes == ["ellipses/E1", "splines/S1", "texts/T1"], " ", deletes)
	s.points = {"c": Vector2(0, 0), "ma": Vector2(20, 0), "mi": Vector2(0, 10), "an": Vector2(30, -20)} # (a delete refreshes from the fake, which has none of these)
	s.selection = [{"kind": "ellipse", "id": "E1"}, {"kind": "text", "id": "T1"}]
	s.ellipses["E1"] = {"c": "c", "ma": "ma", "mi": "mi", "km": "KM", "kn": "KN", "construction": false}
	s.texts["T1"] = {"anchor": "an", "content": "HI", "font": "Roboto", "size": 10.0, "rot": 0.0, "construction": false}
	rig.fake.calls.clear()
	await s.toggle_construction()
	var patches: Array = rig.fake.calls.filter(func(c): return String(c[0]).begins_with("PATCH")).map(func(c): return String(c[0]).get_slice("/", 4))
	print("SMOKE Construction PATCHes each kind's own route: ", patches == ["ellipses", "texts"], " ", patches)
	s.points = {"c": Vector2(0, 0), "ma": Vector2(20, 0), "mi": Vector2(0, 10)} # (the refresh after the toggle emptied them again)
	s.ellipses["E1"] = {"c": "c", "ma": "ma", "mi": "mi", "km": "KM", "kn": "KN", "construction": false}
	s.selection.clear()
	s.set_tool("dimension")
	await s.select({"kind": "ellipse", "id": "E1"})
	print("SMOKE Dimension on an ellipse offers Major radius 20 and Minor radius 10 (patching its two size constraints): ", s.ghosts.map(func(g): return g["key"]) == ["major_radius", "minor_radius"] and absf(float(s.ghost("major_radius")["value"]) - 20.0) < 0.001 and s.ghost("minor_radius")["apply"]["patch_id"] == "KN")
	# --- Delete cascades like the flat app: constraints first, then what is built on a deleted point
	s.points = {"a": Vector2(0, 0), "b": Vector2(10, 0), "c": Vector2(10, 10)}
	s.lines = {"L1": {"a": "a", "b": "b", "construction": false}, "L2": {"a": "b", "b": "c", "construction": false}}
	s.circles.clear()
	s.arcs.clear()
	s.ellipses.clear()
	s.ellipse_arcs.clear()
	s.splines.clear()
	s.texts.clear()
	s.shapes.clear()
	s.constraints = {"H1": {"id": "H1", "type": "horizontal", "line_id": "L1"}, "D1": {"id": "D1", "type": "distance", "point_a_id": "b", "point_b_id": "c"}, "X": {"id": "X", "type": "vertical", "line_id": "L2"}}
	s.selection = [{"kind": "line", "id": "L1"}]
	var plan: Dictionary = s.delete_cascade()
	print("SMOKE deleting a line takes the constraints that name it (its Horizontal), not the others: ", plan["constraints"] == ["H1"] and plan["entities"]["line"] == ["L1"] and plan["points"].is_empty(), " ", plan)
	s.selection = [{"kind": "point", "id": "b"}]
	plan = s.delete_cascade()
	print("SMOKE deleting a point takes both lines on it and every constraint on the point or those lines, and says so: ", plan["entities"]["line"].size() == 2 and plan["constraints"].size() == 3 and String(plan["extra"]).contains("2 line") and String(plan["extra"]).contains("3 constraint"), " ", plan)
	s.shapes = {"R": {"kind": "rectangle", "point_ids": ["a", "b", "c", "d"], "own_point_ids": ["a", "b", "c", "d"]}}
	s.selection = [{"kind": "line", "id": "L1"}]
	plan = s.delete_cascade()
	print("SMOKE cutting one line out of a rectangle collapses it to plain lines instead of deleting the whole: ", plan["collapse"] == [{"kind": "rectangle", "id": "R"}] and plan["remove_shapes"].is_empty(), " ", plan)
	s.points["d"] = Vector2(0, 10)
	s.lines["L3"] = {"a": "c", "b": "d", "construction": false}
	s.lines["L4"] = {"a": "d", "b": "a", "construction": false}
	s.selection = [{"kind": "line", "id": "L1"}, {"kind": "line", "id": "L2"}, {"kind": "line", "id": "L3"}, {"kind": "line", "id": "L4"}]
	plan = s.delete_cascade()
	print("SMOKE taking all four sides deletes the rectangle whole: ", plan["remove_shapes"] == [{"kind": "rectangle", "id": "R"}] and plan["collapse"].is_empty(), " ", plan)
	s.shapes.clear()
	s.selection = [{"kind": "line", "id": "L1"}]
	rig.fake.calls.clear()
	await s.delete_selection()
	var order: Array = rig.fake.calls.filter(func(c): return String(c[0]).begins_with("DELETE")).map(func(c): return String(c[0]).get_slice("/", 4))
	print("SMOKE Delete sends the constraint's delete before the line's: ", order.size() >= 2 and order[0] == "constraints" and order[1] == "lines", " ", order)
	quit()
