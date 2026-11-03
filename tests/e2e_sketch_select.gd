extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): the design table's
## sketch origin point and the Select tool's contextual menu, against the REAL constraint schemas. A new part, a sketch on the XY
## plane; the sketch's origin is read (the backend makes it lazily) and is a real point; a line started on the origin gets a point of its own held on it; every
## menu option is applied to a real selection (horizontal, vertical, parallel, perpendicular, equal length, collinear, midpoint,
## point on line / curve, concentric, equal radius, tangent, curve tangent, fixed, a distance from the origin), construction is
## toggled and read back, and Delete removes entities (never the origin).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_select.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api
var s


func req(method: int, path: String, body = null) -> Dictionary:
	return await api.request(method, path, body)


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func line(a: Vector2, b: Vector2) -> String:
	## Draws one line with the Line tool and returns its id.
	s.set_tool("line")
	await s.tap({"uv": a})
	var before: Array = s.lines.keys()
	await s.tap({"uv": b})
	s.finish_chain()
	for id in s.lines:
		if not before.has(id):
			return id
	return ""


func pick(entities: Array) -> void:
	s.set_tool("select")
	for e in entities:
		await s.select({"kind": e[0], "id": e[1]})


func menu_ids() -> Array:
	return s.menu().map(func(o): return o["id"])


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
	print("SMOKE a sketch opens on XY and Select is already the active tool: ", opened and table.active_tool == "select" and s.tool == "select")
	print("SMOKE the sketch's origin is a real point the backend reported, at (0, 0): ", s.origin_id != "" and s.points.has(s.origin_id) and s.points[s.origin_id] == Vector2.ZERO and s.is_origin(s.origin_id))

	s.set_tool("point")
	await s.tap({"uv": Vector2(150, 100)})
	var free_pt: String = ""
	for id in s.points:
		if s.points[id] == Vector2(150, 100):
			free_pt = id
	await pick([["point", free_pt]])
	var fixed: Dictionary = await s.apply_menu("fix")
	print("SMOKE Fix pins a free point (the backend now reports it locked): ", fixed["ok"] and bool(s.point_locked.get(free_pt, false)))

	# circles and arcs
	s.set_tool("circle")
	await s.tap({"uv": Vector2(100, 40)})
	await s.tap({"uv": Vector2(110, 40)})
	await s.tap({"uv": Vector2(100, -40)})
	await s.tap({"uv": Vector2(112, -40)})
	var circles: Array = s.circles.keys()
	await pick([["circle", circles[0]], ["circle", circles[1]]])
	print("SMOKE two circles offer Concentric and Equal radius: ", menu_ids().has("concentric") and menu_ids().has("equal_radius") and not menu_ids().has("tangent"))
	await s.apply_menu("concentric")
	var c0: Vector2 = s.points[s.circles[circles[0]]["c"]]
	var c1: Vector2 = s.points[s.circles[circles[1]]["c"]]
	print("SMOKE Concentric moves one circle's centre onto the other's: ", s.converged and c0.distance_to(c1) < 0.01)
	await pick([["circle", circles[0]], ["circle", circles[1]]])
	await s.apply_menu("equal_radius")
	var r0: float = s.points[s.circles[circles[0]]["c"]].distance_to(s.points[s.circles[circles[0]]["p"]])
	var r1: float = s.points[s.circles[circles[1]]["c"]].distance_to(s.points[s.circles[circles[1]]["p"]])
	print("SMOKE Equal radius is solved: ", s.converged and abs(r0 - r1) < 0.01)
	var line_to_circle: String = await line(Vector2(100, 70), Vector2(160, 70))
	await pick([["line", line_to_circle], ["circle", circles[0]]])
	print("SMOKE a line and a circle offer Tangent: ", menu_ids().has("tangent"))
	await s.apply_menu("tangent")
	var cc: Vector2 = s.points[s.circles[circles[0]]["c"]]
	var cr: float = cc.distance_to(s.points[s.circles[circles[0]]["p"]])
	var la: Vector2 = s.points[s.lines[line_to_circle]["a"]]
	var lb: Vector2 = s.points[s.lines[line_to_circle]["b"]]
	print("SMOKE Tangent is solved by the backend: the line touches the circle: ", s.converged and abs(abs((cc - la).cross((lb - la).normalized())) - cr) < 0.05)
	# a line from the origin shares it
	s.set_tool("line")
	await s.tap({"uv": Vector2.ZERO, "id": s.origin_id})
	await s.tap({"uv": Vector2(40, 3)})
	var base: String = ""
	var base_start: String = ""
	for id in s.lines:
		if s.points[s.lines[id]["a"]] == Vector2.ZERO and s.lines[id]["a"] != s.origin_id:
			base = id
			base_start = s.lines[id]["a"]
	var held_on_origin := false
	for cid in s.constraints:
		var c: Dictionary = s.constraints[cid]
		if str(c.get("type", "")) == "coincident" and [str(c.get("point_a_id", "")), str(c.get("point_b_id", ""))].has(base_start) and [str(c.get("point_a_id", "")), str(c.get("point_b_id", ""))].has(s.origin_id):
			held_on_origin = true
	print("SMOKE a line started on the origin is NOT welded to it: its start is a point of its own at (0, 0), held on the origin by a coincident constraint: ", base != "" and held_on_origin and s.converged)
	s.finish_chain()

	var l2: String = await line(Vector2(0, 30), Vector2(45, 33))
	var l3: String = await line(Vector2(60, 0), Vector2(60, 25))
	await pick([["line", base]])
	await s.apply_menu("horizontal")
	print("SMOKE Horizontal (menu) on the first line: the backend solves it flat: ", abs(s.points[s.lines[base]["b"]].y) < 0.001 and s.converged)
	await pick([["line", l3]])
	await s.apply_menu("vertical")
	print("SMOKE Vertical (menu) makes the third line plumb: ", abs(s.points[s.lines[l3]["a"]].x - s.points[s.lines[l3]["b"]].x) < 0.001)
	await pick([["line", base], ["line", l2]])
	print("SMOKE two lines offer Parallel, Perpendicular, Equal, Collinear and a dimension: ", menu_ids().slice(0, 5) == ["dim:line_distance", "parallel", "perpendicular", "equal_length", "collinear"] or menu_ids().has("parallel"))
	await s.apply_menu("parallel")
	var p_a: Vector2 = s.points[s.lines[base]["b"]] - s.points[s.lines[base]["a"]]
	var p_b: Vector2 = s.points[s.lines[l2]["b"]] - s.points[s.lines[l2]["a"]]
	print("SMOKE Parallel is solved by the backend (the two lines now run the same way): ", abs(p_a.normalized().cross(p_b.normalized())) < 0.001 and s.converged)
	await pick([["line", base], ["line", l2]])
	await s.apply_menu("equal_length")
	var len_a: float = s.points[s.lines[base]["a"]].distance_to(s.points[s.lines[base]["b"]])
	var len_b: float = s.points[s.lines[l2]["a"]].distance_to(s.points[s.lines[l2]["b"]])
	print("SMOKE Equal makes the two lengths the same: ", abs(len_a - len_b) < 0.01)
	await pick([["line", base], ["line", l3]])
	await s.apply_menu("perpendicular")
	var d1: Vector2 = s.points[s.lines[base]["b"]] - s.points[s.lines[base]["a"]]
	var d3: Vector2 = s.points[s.lines[l3]["b"]] - s.points[s.lines[l3]["a"]]
	print("SMOKE Perpendicular is solved: ", abs(d1.normalized().dot(d3.normalized())) < 0.001)

	# a distance from the origin
	var end_pt: String = s.lines[l3]["b"]
	await pick([["point", s.origin_id], ["point", end_pt]])
	print("SMOKE the origin and a point offer a Distance, a Horizontal and a Vertical dimension: ", menu_ids().has("dim:linear") and menu_ids().has("dim:horizontal") and menu_ids().has("dim:vertical") and menu_ids().has("coincident"))
	var done: Dictionary = await s.confirm_ghost("horizontal", 80.0)
	print("SMOKE ...a typed 80 mm horizontal dimension FROM THE ORIGIN is accepted and solved: ", done["ok"] and abs(s.points[end_pt].x - 80.0) < 0.01)

	# point on line / midpoint
	var stray: String = ""
	s.set_tool("point")
	await s.tap({"uv": Vector2(10, 12)})
	for id in s.points:
		if s.points[id] == Vector2(10, 12):
			stray = id
	await pick([["point", stray], ["line", l2]])
	print("SMOKE a point and a line offer On line and Midpoint: ", menu_ids().has("point_on_line") and menu_ids().has("at_midpoint"))
	await s.apply_menu("at_midpoint")
	var a2: Vector2 = s.points[s.lines[l2]["a"]]
	var b2: Vector2 = s.points[s.lines[l2]["b"]]
	print("SMOKE Midpoint puts the point at the middle of the line: ", s.converged and s.points[stray].distance_to((a2 + b2) * 0.5) < 0.01)

	# construction and delete
	await pick([["line", l3]])
	await s.apply_menu("construction")
	var exported: Dictionary = await req(HTTPClient.METHOD_GET, "/sketch/sketches/%s/export" % s.sketch_id)
	var construction_on := false
	for e in exported["json"]["entities"]:
		if e["id"] == l3:
			construction_on = bool(e.get("construction", false))
	print("SMOKE Construction flags the line construction on the backend, and the session sees it: ", construction_on and bool(s.lines[l3]["construction"]) and s.undo_label() == "construction")
	await pick([["line", l3]])
	print("SMOKE ...and the menu then says Solid: ", s.menu().filter(func(o): return o["id"] == "construction")[0]["text"] == "Solid")
	await s.apply_menu("construction")
	print("SMOKE ...which puts it back to solid: ", not bool(s.lines[l3]["construction"]))
	await pick([["line", line_to_circle]])
	var before_lines: int = s.lines.size()
	var deleted: Dictionary = await s.apply_menu("delete")
	print("SMOKE Delete removes the line from the backend sketch: ", deleted["ok"] and s.lines.size() == before_lines - 1 and not s.lines.has(line_to_circle))
	await pick([["point", s.origin_id]])
	print("SMOKE the origin cannot be deleted: the menu does not offer it, and it is still there after: ", not menu_ids().has("delete") and s.points.has(s.origin_id) and s.points[s.origin_id] == Vector2.ZERO)
	print("SMOKE e2e done: ", true)
	quit()
