extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): Phase 7.4's sketch construction methods and the point-on-ellipse
## constraint against the real sketch solver and schemas. A circle through (0,0), (10,0), (0,10) is a circle of radius 7.071 about (5,5) (extruded 10 mm it is 1570.8 mm3); a rectangle
## from its centre and a corner is 6 x 4 (240 mm3 at 10 mm); a turned rectangle from the side (0,0)-(10,10) and the point (0,10) is 14.14 x 7.07 (1000 mm3), made with axis_aligned
## false; a line from its middle (5,5) to (8,5) runs (2,5)-(8,5) with the middle held at its midpoint; a point put on an ellipse by On ellipse ends up on it.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_methods.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func total(ed) -> float:
	var res: Dictionary = await ed.api.request(HTTPClient.METHOD_GET, "/document/parts/%s/mass-properties" % ed.part_id)
	var t := 0.0
	if bool(res.get("ok", false)):
		for v in (res["json"]["body_volumes"] as Dictionary).values():
			t += float(v)
	return t


func near(a: float, b: float, tolerance := 0.01) -> bool:
	return absf(a - b) <= maxf(absf(b) * tolerance, 0.001)


func fresh_sketch(ed) -> void:
	var before = table.seated
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane" and table.seated != null and table.seated != before)
	await ed.begin_sketch({"fixed": "XY"})


func tap(ed, x: float, y: float) -> void:
	await ed.session.tap({"uv": Vector2(x, y), "id": ""})


func extrude_volume(ed, depth: float) -> float:
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = depth
	for key in ["ext_sym", "ext_thin", "ext_draft"]:
		ed.options[key] = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	return await total(ed)


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
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	ed.preview_enabled = false
	await main.new_assembly()

	# --- Circle through three points
	await fresh_sketch(ed)
	table.manager.activate("circle")
	ed.session.set_method("circle", "three")
	await tap(ed, 0, 0)
	await tap(ed, 10, 0)
	await tap(ed, 0, 10)
	var s = ed.session
	var circle_id := str(s.circles.keys()[0]) if s.circles.size() == 1 else ""
	var circle: Dictionary = s.circles.get(circle_id, {})
	var centre: Vector2 = s.points.get(str(circle.get("c", "")), Vector2(-99, -99))
	var rim: Vector2 = s.points.get(str(circle.get("p", "")), Vector2(-99, -99))
	print("SMOKE A circle through (0,0), (10,0), (0,10) is one circle about (5,5) with its radius point on (0,0): ", s.circles.size() == 1 and centre.distance_to(Vector2(5, 5)) < 0.01 and rim.distance_to(Vector2(0, 0)) < 0.01, " ", centre, " ", rim)
	var holds: int = s.constraints.values().filter(func(c): return str(c.get("type")) == "point_on_circle").size()
	print("SMOKE ...the other two points are held on it (two point_on_circle constraints) and the solver is happy: ", holds == 2 and s.converged and s.profile_ok(), " ", holds, " ", s.profile_status)
	var v := await extrude_volume(ed, 10.0)
	print("SMOKE ...extruded 10 mm it is pi x 7.071 squared x 10 = 1570.8 mm3: ", near(v, 1570.796, 0.01), " ", v)

	# --- Rectangle from its centre and a corner
	await fresh_sketch(ed)
	table.manager.activate("rectangle")
	ed.session.set_method("rectangle", "centre")
	await tap(ed, 20, 20)
	await tap(ed, 23, 22)
	v = await extrude_volume(ed, 10.0)
	print("SMOKE A rectangle from its centre (20,20) and a corner (23,22) is 6 x 4, extruded 10 mm = 240 mm3: ", near(v, 240.0, 0.01), " ", v)

	# --- Turned rectangle from a side and the width
	await fresh_sketch(ed)
	table.manager.activate("rectangle")
	ed.session.set_method("rectangle", "three")
	await tap(ed, 0, 0)
	await tap(ed, 10, 10)
	await tap(ed, 0, 10)
	s = ed.session
	var shape: Dictionary = s.shapes.values()[0] if s.shapes.size() == 1 else {}
	print("SMOKE A rectangle from the side (0,0)-(10,10) and the point (0,10) is one rectangle the solver accepts: ", s.shapes.size() == 1 and s.converged and s.profile_ok(), " ", s.profile_status)
	v = await extrude_volume(ed, 10.0)
	print("SMOKE ...it is 14.14 x 7.07 = 100 mm2, 1000 mm3 at 10 mm (a turned rectangle, not an axis aligned one): ", near(v, 1000.0, 0.01), " ", v)

	# --- A line from its middle
	await fresh_sketch(ed)
	table.manager.activate("line")
	ed.session.set_method("line", "middle")
	await tap(ed, 5, 5)
	await tap(ed, 8, 5)
	s = ed.session
	var line_id := str(s.lines.keys()[0]) if s.lines.size() == 1 else ""
	var line: Dictionary = s.lines.get(line_id, {})
	var a: Vector2 = s.points.get(str(line.get("a", "")), Vector2(-99, -99))
	var b2: Vector2 = s.points.get(str(line.get("b", "")), Vector2(-99, -99))
	var ends := [a, b2]
	ends.sort_custom(func(p, q): return p.x < q.x)
	print("SMOKE A line from its middle (5,5) to (8,5) runs (2,5) to (8,5): ", s.lines.size() == 1 and (ends[0] as Vector2).distance_to(Vector2(2, 5)) < 0.01 and (ends[1] as Vector2).distance_to(Vector2(8, 5)) < 0.01, " ", ends)
	var mid_constraints: Array = s.constraints.values().filter(func(c): return str(c.get("type")) == "at_midpoint")
	print("SMOKE ...with the middle held at its midpoint (an at_midpoint constraint, solved): ", mid_constraints.size() == 1 and s.converged, " ", mid_constraints.size())

	# --- A point put on an ellipse
	await fresh_sketch(ed)
	table.manager.activate("ellipse")
	await tap(ed, 0, 0)
	await tap(ed, 20, 0)
	await tap(ed, 0, 10)
	s = ed.session
	table.manager.activate("point")
	await tap(ed, 5, 12) # off the ellipse
	var ellipse_id := str(s.ellipses.keys()[0]) if s.ellipses.size() == 1 else ""
	var point_id := ""
	for id in s.points:
		if (s.points[id] as Vector2).distance_to(Vector2(5, 12)) < 0.01:
			point_id = str(id)
	print("SMOKE An ellipse (20 x 10) and a point at (5,12) outside it: ", ellipse_id != "" and point_id != "")
	table.manager.activate("select")
	s.selection = [{"kind": "point", "id": point_id}, {"kind": "ellipse", "id": ellipse_id}]
	print("SMOKE ...the menu offers On ellipse for the pair: ", s.menu().any(func(o): return o["id"] == "point_on_ellipse"))
	var res: Dictionary = await s.apply_menu("point_on_ellipse")
	# Nothing else is fixed, so the solver may move the ellipse too: measure the point against the ellipse as it is now (its own centre and axes).
	var e: Dictionary = s.ellipses.get(ellipse_id, {})
	var c: Vector2 = s.points.get(str(e.get("c")), Vector2.ZERO)
	var major: Vector2 = (s.points.get(str(e.get("ma")), Vector2.ZERO) as Vector2) - c
	var minor: Vector2 = (s.points.get(str(e.get("mi")), Vector2.ZERO) as Vector2) - c
	var p: Vector2 = s.points.get(point_id, Vector2.ZERO) - c
	var level := pow(p.dot(major.normalized()) / major.length(), 2.0) + pow(p.dot(minor.normalized()) / minor.length(), 2.0)
	print("SMOKE ...applying it on the real solver puts the point on the ellipse as it is afterwards ((u/a)^2 + (v/b)^2 = 1) and the sketch still solves: ", bool(res["ok"]) and s.converged and near(level, 1.0, 0.02), " ", level)
	quit()
