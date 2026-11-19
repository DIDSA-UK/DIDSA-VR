extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the part D dimension options made from a VR PICK
## (S4 of docs/dimension-constraint-parity-plan.md; S2's e2e made them through the routes). A new part, a sketch on XY with two lines, a quarter arc, two circles and
## free points. With the Dimension tool: an arc's length, a line's angle to horizontal, three points' angle, the minimum and maximum distance from a point to a circle,
## between two circles, and from a line to a circle (the tangent and far sides) are each picked, offered with the catalogue's key and label, typed at the value they
## already have and made by the backend as the right constraint (type, side), converged and drawn. Then the `pinned` block's part D kinds: a pinned arc, line, three
## points, a point and a circle each offer their part D kind as a DRIVEN candidate, and keeping one stores a reference dimension of that kind (no constraint made).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_dimension_options.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api
var s


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func line(a: Vector2, b: Vector2) -> String:
	s.set_tool("line")
	await s.tap({"uv": a})
	var before: Array = s.lines.keys()
	await s.tap({"uv": b})
	s.finish_chain()
	for id in s.lines:
		if not before.has(id):
			return id
	return ""


func circle(centre: Vector2, rim: Vector2) -> String:
	var before: Array = s.circles.keys()
	s.set_tool("circle")
	await s.tap({"uv": centre})
	await s.tap({"uv": rim})
	for id in s.circles:
		if not before.has(id):
			return id
	return ""


func point_at(uv: Vector2) -> String:
	s.set_tool("point")
	await s.tap({"uv": uv})
	for id in s.points:
		if (s.points[id] as Vector2).distance_to(uv) < 0.01:
			return str(id)
	return ""


func pick(entities: Array) -> void:
	s.set_tool("dimension")
	s.clear_selection()
	for e in entities:
		await s.select({"kind": e[0], "id": e[1]})


func keys() -> Array:
	return s.ghosts.map(func(g): return g["key"])


func made(type: String, side := "") -> Dictionary:
	## The constraint of this type (and side) the session now holds, {} for none.
	for id in s.constraints:
		var c: Dictionary = s.constraints[id]
		if str(c.get("type", "")) == type and (side == "" or str(c.get("side", "")) == side):
			return c
	return {}


func make(entities: Array, key: String, type: String, side := "") -> Dictionary:
	## Picks `entities`, types the candidate's own value, and returns the constraint it made ({} if it did not).
	await pick(entities)
	var g: Dictionary = s.ghost(key)
	if g.is_empty():
		print("  (no candidate ", key, " among ", keys(), ")")
		return {}
	var r: Dictionary = await s.confirm_ghost(key, float(g["value"]))
	if not r["ok"]:
		print("  (refused: ", r)
		return {}
	return made(type, side)


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	var url := str(cfg.get_value("backend", "url"))
	var key := str(cfg.get_value("backend", "api_key"))
	main.backend_url = url
	main.api_key = key
	table = main.design_table
	table.configure_backend(url, key)
	api = table.api
	table.surface.settle_seconds = 0.0

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")
	var opened: bool = await table.editor.begin_sketch({"fixed": "XY"})
	s = table.editor.session
	print("SMOKE a sketch opens on XY: ", opened)

	var la: String = await line(Vector2(10, 10), Vector2(70, 50))
	var lb: String = await line(Vector2(10, 110), Vector2(90, 110))
	s.set_tool("arc")
	await s.tap({"uv": Vector2(200, 0)})
	await s.tap({"uv": Vector2(230, 0)})
	await s.tap({"uv": Vector2(200, 30)})
	var arc_id: String = s.arcs.keys()[0] if not s.arcs.is_empty() else ""
	var c1: String = await circle(Vector2(200, 140), Vector2(210, 140))
	var c2: String = await circle(Vector2(260, 140), Vector2(268, 140))
	var free_pt: String = await point_at(Vector2(120, -40))
	print("SMOKE the sketch holds two lines, an arc, two circles and a point: ", la != "" and lb != "" and arc_id != "" and c1 != "" and c2 != "" and free_pt != "")
	var la_start: String = s.lines[la]["a"]
	var la_end: String = s.lines[la]["b"]
	var lb_start: String = s.lines[lb]["a"]

	# --- one line: four candidates, the angle among them
	await pick([["line", la]])
	print("SMOKE a line offers Length, Horizontal length, Vertical length and Angle to horizontal: ", keys() == ["length", "h", "v", "horizontalAngle"], " ", keys())
	var angle: Dictionary = s.ghost("horizontalAngle")
	print("SMOKE ...the angle's value is the line's own, 0-180 (33.69 degrees), and follows the pointer for its side: ", absf(float(angle["value"]) - rad_to_deg(atan2(40.0, 60.0))) < 0.01 and angle["side"] == "pointer")

	# --- the six part D options made from a pick
	var k_arc := await make([["arc", arc_id]], "arcLength", "arc_length")
	print("SMOKE an arc's Arc length is made from the pick (arc_length, its own length) and the sketch still solves: ", not k_arc.is_empty() and absf(float(k_arc["length"]) - 30.0 * PI * 0.5) < 0.05 and s.converged, " ", k_arc)
	var k_hang := await make([["line", la]], "horizontalAngle", "horizontal_angle")
	print("SMOKE a line's Angle to horizontal is made (horizontal_angle, 33.69 degrees): ", not k_hang.is_empty() and absf(float(k_hang["angle_degrees"]) - rad_to_deg(atan2(40.0, 60.0))) < 0.01 and s.converged, " ", k_hang)
	var k_pang := await make([["point", la_start], ["point", la_end], ["point", lb_start]], "pointAngle", "point_angle")
	print("SMOKE three points (the first the vertex) make a point_angle: ", not k_pang.is_empty() and str(k_pang["vertex_point_id"]) == la_start and s.converged, " ", k_pang)
	await pick([["point", free_pt], ["circle", c2]])
	print("SMOKE a point and a circle offer Aligned, Horizontal, Vertical, Minimum and Maximum distance: ", keys() == ["linear", "h", "v", "minDistance", "maxDistance"], " ", keys())
	var k_pc_min := await make([["point", free_pt], ["circle", c2]], "minDistance", "point_circle_distance", "min")
	var k_pc_max := await make([["point", free_pt], ["circle", c2]], "maxDistance", "point_circle_distance", "max")
	print("SMOKE ...Minimum and Maximum are made as point_circle_distance with side min and max: ", not k_pc_min.is_empty() and not k_pc_max.is_empty() and k_pc_min["id"] != k_pc_max["id"] and float(k_pc_max["distance"]) > float(k_pc_min["distance"]) and s.converged)
	await pick([["circle", c1], ["circle", c2]])
	print("SMOKE two apart circles offer Minimum (the gap) and Maximum: ", keys() == ["linear", "h", "v", "minDistance", "maxDistance"], " ", keys())
	var k_cc_min := await make([["circle", c1], ["circle", c2]], "minDistance", "circle_distance", "min")
	var k_cc_max := await make([["circle", c1], ["circle", c2]], "maxDistance", "circle_distance", "max")
	print("SMOKE ...made as circle_distance, min and max (the gap 42, the overall 78): ", not k_cc_min.is_empty() and not k_cc_max.is_empty() and absf(float(k_cc_min["distance"]) - 42.0) < 0.05 and absf(float(k_cc_max["distance"]) - 78.0) < 0.05 and s.converged, " ", k_cc_min, " ", k_cc_max)
	await pick([["line", lb], ["circle", c1]])
	print("SMOKE a line and a circle that does not touch it offer Perpendicular from centre, Tangent distance and Far-side distance: ", keys() == ["perpendicular", "tangentDistance", "farDistance"], " ", keys())
	var k_lc_min := await make([["line", lb], ["circle", c1]], "tangentDistance", "line_circle_distance", "min")
	var k_lc_max := await make([["line", lb], ["circle", c1]], "farDistance", "line_circle_distance", "max")
	print("SMOKE ...made as line_circle_distance, min (the tangent side, 20) and max (the far side, 40): ", not k_lc_min.is_empty() and not k_lc_max.is_empty() and absf(float(k_lc_min["distance"]) - 20.0) < 0.05 and absf(float(k_lc_max["distance"]) - 40.0) < 0.05 and s.converged, " ", k_lc_min, " ", k_lc_max)
	var drawn := 0
	for item in s.dimension_items():
		if str(item["id"]) in [k_arc.get("id"), k_hang.get("id"), k_pang.get("id"), k_pc_min.get("id"), k_pc_max.get("id"), k_cc_min.get("id"), k_cc_max.get("id"), k_lc_min.get("id"), k_lc_max.get("id")]:
			drawn += 1
	print("SMOKE all nine are read back and drawn as dimensions: ", drawn == 9, " ", drawn)

	# --- the pinned block's part D kinds, as reference dimensions
	var a2: String = ""
	s.set_tool("arc")
	await s.tap({"uv": Vector2(400, 0)})
	await s.tap({"uv": Vector2(430, 0)})
	await s.tap({"uv": Vector2(400, 30)})
	for id in s.arcs:
		if id != arc_id:
			a2 = str(id)
	var lc: String = await line(Vector2(400, 100), Vector2(470, 130))
	var p1: String = await point_at(Vector2(400, 200))
	var p2: String = await point_at(Vector2(440, 200))
	var p3: String = await point_at(Vector2(400, 240))
	var c3: String = await circle(Vector2(520, 200), Vector2(530, 200))
	var p4: String = await point_at(Vector2(520, 260))
	s.set_tool("select")
	for e in [["arc", a2], ["line", lc], ["point", p1], ["point", p2], ["point", p3], ["circle", c3], ["point", p4]]:
		s.clear_selection()
		await s.select({"kind": e[0], "id": e[1]})
		var fixed: Dictionary = await s.apply_menu("fix")
		if not fixed["ok"]:
			print("  (fix refused: ", e, " ", fixed)
	var before: int = s.constraints.size()
	var cases := [
		[[["arc", a2]], "arcLength", "arc_length"],
		[[["line", lc]], "horizontalAngle", "horizontal_angle"],
		[[["point", p1], ["point", p2], ["point", p3]], "pointAngle", "point_angle"],
		[[["point", p4], ["circle", c3]], "minDistance", "min_distance"],
		[[["point", p4], ["circle", c3]], "maxDistance", "max_distance"]]
	for case in cases:
		await pick(case[0])
		var g: Dictionary = s.ghost(case[1])
		var driven: bool = not g.is_empty() and bool(g.get("driven", false)) and g["ref"] == case[2]
		var r: Dictionary = await s.confirm_ghost(case[1], 0.0) if not g.is_empty() else {"ok": false}
		var stored := false
		for d in s.ref_dims:
			stored = stored or str(d["kind"]) == case[2]
		print("SMOKE pinned ", case[0].map(func(e): return e[0]), " offers ", case[1], " as a DRIVEN candidate and keeping it stores a ", case[2], " reference dimension: ", driven and r["ok"] and stored, " ", keys())
	print("SMOKE ...they made no constraint of their own: ", s.constraints.size() == before)
	var listed: Dictionary = await api.request(HTTPClient.METHOD_GET, "/sketch/sketches/%s/reference-dimensions" % s.sketch_id, null)
	print("SMOKE ...and the backend holds all five with a value each: ", listed["ok"] and (listed["json"] as Array).size() == 5 and (listed["json"] as Array).all(func(d): return d.get("value") != null), " ", listed.get("json"))
	var drawn_refs: int = s.driven_items().size()
	print("SMOKE ...and they are drawn in brackets: ", drawn_refs == 5, " ", s.driven_items().map(func(i): return i["text"]))
	quit()
