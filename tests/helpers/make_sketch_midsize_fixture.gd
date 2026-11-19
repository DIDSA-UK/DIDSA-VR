extends SceneTree
## Writes tests/fixtures/sketch_midsize_state.json from a REAL local backend (F3 of docs/parity-followups-investigation.md, the sketch of C1): a new part, a sketch on XY with
## 10 rectangles (each a width and a height dimension) with a circle beside each, and a 20-point chain of 19 dimensioned lines. Built through the session's own routes (taps and
## confirm_ghost), then the two answers the session reads are saved as they came: `state` (POST .../solve-and-refresh) and `export` (GET .../export), with the sketch's origin
## point id. tests/sketch_midsize_redraw.gd loads that file and needs no backend.
## Run (a backend on secrets.cfg, see tests/README.md): "$GODOT" --headless --path . --script res://tests/helpers/make_sketch_midsize_fixture.gd

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const OUT := "res://tests/fixtures/sketch_midsize_state.json"

var main
var s
var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func point_near(uv: Vector2) -> String:
	for id in s.points:
		if (s.points[id] as Vector2).distance_to(uv) < 0.5 and not s.is_origin(str(id)):
			return str(id)
	return ""


func line_between(a: String, b: String) -> String:
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if [l["a"], l["b"]].has(a) and [l["a"], l["b"]].has(b):
			return str(id)
	return ""


func dimension_line(line_id: String) -> bool:
	## A length dimension on the line, at the length it has now (so the sketch does not move).
	var l: Dictionary = s.lines[line_id]
	var length: float = (s.points[l["a"]] as Vector2).distance_to(s.points[l["b"]])
	s.set_tool("dimension")
	s.clear_selection()
	await s.select({"kind": "line", "id": line_id})
	var made: Dictionary = await s.confirm_ghost("length", snappedf(length, 0.01))
	s.clear_selection()
	return bool(made["ok"])


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this needs a running local backend, see tests/README.md")
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
	var table = main.design_table
	table.configure_backend(url, key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var opened: bool = await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	_check(opened, "a sketch opens on XY")

	# 10 rectangles in 2 rows of 5, each 18 x 10 mm with a circle of radius 3 beside it
	var dims_made := 0
	for i in 10:
		var x0 := -90.0 + float(i % 5) * 40.0
		var y0 := 30.0 + float(i / 5) * 28.0
		s.set_tool("rectangle")
		await s.tap({"uv": Vector2(x0, y0)})
		await s.tap({"uv": Vector2(x0 + 18.0, y0 + 10.0)})
		var a := point_near(Vector2(x0, y0))
		var b := point_near(Vector2(x0 + 18.0, y0))
		var d := point_near(Vector2(x0, y0 + 10.0))
		var bottom := line_between(a, b)
		var left := line_between(a, d)
		if bottom != "" and await dimension_line(bottom):
			dims_made += 1
		if left != "" and await dimension_line(left):
			dims_made += 1
		s.set_tool("circle")
		await s.tap({"uv": Vector2(x0 + 26.0, y0 + 5.0)})
		await s.tap({"uv": Vector2(x0 + 29.0, y0 + 5.0)})
	_check(dims_made == 20, "20 rectangle dimensions made (%d)" % dims_made)

	# the chain: 20 points along y = -40, a zig-zag of +-4 mm, 9.5 mm apart (not straight: a straight chain is a singular start)
	var pts: Array = []
	for i in 20:
		pts.append(Vector2(-90.0 + float(i) * 9.5, -40.0 + (4.0 if i % 2 == 1 else 0.0)))
	s.set_tool("line")
	for p in pts:
		await s.tap({"uv": p})
	s.set_tool("select")
	var chain_dims := 0
	for i in 19:
		var la := point_near(pts[i])
		var lb := point_near(pts[i + 1])
		var lid := line_between(la, lb)
		if lid != "" and await dimension_line(lid):
			chain_dims += 1
	_check(chain_dims == 19, "19 chain dimensions made (%d)" % chain_dims)

	var state: Dictionary = await s.api.call(HTTPClient.METHOD_POST, "/sketch/sketches/" + s.sketch_id + "/solve-and-refresh", null)
	var exported: Dictionary = await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/export", null)
	_check(bool(state["ok"]) and bool(exported["ok"]), "the state and the export are read back")
	var n_dim := 0
	for c in s.constraints.values():
		n_dim += 1 if s.dimension_value(str((c as Dictionary)["id"])).get("ok", false) else 0
	print("SMOKE the sketch: %d points, %d lines, %d circles, %d constraints, %d dimensions, dof %d" % [s.points.size(), s.lines.size(), s.circles.size(), s.constraints.size(), n_dim, s.dof])
	var doc := {"about": "A real backend's answers for the sketch of F3 / C1 (tests/helpers/make_sketch_midsize_fixture.gd): state = POST .../solve-and-refresh, export = GET .../export",
		"origin_point_id": s.origin_id, "state": state["json"], "export": exported["json"]}
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc, "\t", true))
	f.close()
	print("SMOKE written ", OUT)
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
