extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): S5 of docs/dimension-constraint-parity-plan.md,
## pick -> preview -> drop -> type, through the design table's own flow (table_editor.gd's dim_flow and dimension_typed, the number pad's callback) on a real
## sketch. A new part, a sketch on XY with a free line, two lines that meet and a circle. Each case picks, previews at a sheet point, drops there and types a
## value; the backend then holds the constraint (its kind from the stick / the default, the angle's quadrant from the laser) and, read back fresh from the
## backend, the placement the drop saved; the dimension is drawn with its label at the drop point. A drop stepped back from (B) makes nothing.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_sketch_dimension_drop.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const DimLayout := preload("res://scripts/design_table/dimension_layout.gd")

var main
var table
var api
var ed
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


func pick(entities: Array) -> void:
	s.set_tool("dimension")
	s.clear_selection()
	for e in entities:
		await s.select({"kind": e[0], "id": e[1]})
	ed.dim_flow.sync(s)


func drop_and_type(at: Vector2, text: String, step := 0) -> Dictionary:
	## Previews at `at` (stepping the kind `step` times on the stick first), drops there and types `text` as the pad would. Returns the dropped candidate.
	ed.dim_flow.preview(s, at, 1.0)
	if step != 0:
		ed.dim_flow.cycle(s, at, step)
	var g: Dictionary = ed.dim_flow.drop(s, at, 1.0)
	if g.is_empty():
		return {}
	await ed.dimension_typed(str(g["key"]), text, g.duplicate(true))
	return g


func newest(type: String) -> Dictionary:
	var best: Dictionary = {}
	for id in s.constraints:
		if str(s.constraints[id].get("type", "")) == type:
			best = s.constraints[id]
	return best


func backend_label(cid: String) -> Variant:
	## The constraint's saved placement as the backend returns it now (a fresh GET of the sketch).
	var r: Dictionary = await s.api.call(HTTPClient.METHOD_GET, "/sketch/sketches/" + s.sketch_id + "/constraints", null)
	if not r["ok"] or not (r["json"] is Array):
		return null
	for c in r["json"]:
		if str(c.get("id", "")) == cid:
			return c.get("label")
	return null


func same_place(got: Variant, want: Dictionary) -> bool:
	if not (got is Dictionary) or (got as Dictionary).size() != want.size():
		return false
	for k in want:
		if not (got as Dictionary).has(k) or absf(float(got[k]) - float(want[k])) > 1e-4:
			return false
	return true


func drawn_at(cid: String) -> Variant:
	for it in s.dimension_items():
		if str(it["id"]) == cid:
			return DimLayout.layout(it["spec"], {"offset": 2.0, "arrow": 0.5, "gap": 0.2, "over": 0.3, "centroid": Vector2.ZERO, "text_h": 1.0, "text_w": 3.0})["text_uv"]
	return null


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
	ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var opened: bool = await ed.begin_sketch({"fixed": "XY"})
	s = ed.session
	print("SMOKE a sketch opens on XY: ", opened)
	var free_line: String = await line(Vector2(10, 10), Vector2(70, 50))
	var la: String = await line(Vector2(100, 0), Vector2(160, 0))
	var lb: String = await line(Vector2(100, 0), Vector2(140, 40))
	s.set_tool("circle")
	await s.tap({"uv": Vector2(220, 60)})
	await s.tap({"uv": Vector2(232, 60)})
	var circ: String = s.circles.keys()[0] if not s.circles.is_empty() else ""
	print("SMOKE the sketch holds a free line, two lines that meet and a circle: ", free_line != "" and la != "" and lb != "" and circ != "")

	# --- a line's Length (the default) dropped beside it
	await pick([["line", free_line]])
	var at := Vector2(30, 45)
	var g := await drop_and_type(at, "60")
	var c := newest("distance")
	print("SMOKE a line picked, previewed, dropped and typed: the backend holds its length, 60: ", g.get("key") == "length" and not c.is_empty() and str(c.get("orientation", "linear")) == "linear" and absf(float(c["distance"]) - 60.0) < 1e-6 and s.converged)
	var lbl: Variant = await backend_label(str(c.get("id", "")))
	print("SMOKE ...and, read back fresh from the backend (GET .../constraints), the placement the drop saved: ", same_place(lbl, g["place"]))
	var drawn: Variant = drawn_at(str(c.get("id", "")))
	print("SMOKE ...so it is drawn with its label at the drop point: ", drawn != null and (drawn as Vector2).distance_to(at) < 1e-3)
	print("SMOKE ...and the tool is back to picking: ", ed.dim_flow.stage == "picking" and s.selection.is_empty())

	# --- stepped on the stick to Horizontal length
	await pick([["line", free_line]])
	g = await drop_and_type(Vector2(40, 70), "45", 1)
	var h := {}
	for id in s.constraints:
		if str(s.constraints[id].get("type", "")) == "distance" and str(s.constraints[id].get("orientation", "")) == "horizontal":
			h = s.constraints[id]
	print("SMOKE the stick stepped once: Horizontal length, made with its placement: ", g.get("key") == "h" and not h.is_empty() and absf(float(h["distance"]) - 45.0) < 1e-6 and same_place(await backend_label(str(h.get("id", ""))), g["place"]))

	# --- a circle's diameter (an existing size constraint, patched) with its radial placement
	await pick([["circle", circ]])
	g = await drop_and_type(Vector2(240, 75), "30")
	var k := str((s.circles[circ] as Dictionary).get("k", ""))
	print("SMOKE a circle: Diameter by default, its size constraint set (radius 15) and its placement saved (angle, leg): ", g.get("key") == "diameter" and k != "" and absf(float(s.constraints[k].get("distance", 0.0)) - 15.0) < 1e-6 \
		and same_place(await backend_label(k), g["place"]) and (g["place"] as Dictionary).has("angle") and (g["place"] as Dictionary).has("leg"))

	# --- two lines: the angle's sector from the laser
	await pick([["line", la], ["line", lb]])
	var behind := Vector2(85, 8) # past the first line's back, inside the second's: quadrant 1
	g = await drop_and_type(behind, "135") # (the angle that sector has now: the lines do not move, so the label is drawn where it was dropped)
	var a := newest("angle")
	print("SMOKE two lines: the angle in the sector the laser was in (quadrant 1), 135 degrees, converged: ", int(g.get("quadrant", -1)) == 1 and not a.is_empty() and int(a.get("quadrant", -1)) == 1 and absf(float(a["angle_degrees"]) - 135.0) < 1e-6 and s.converged)
	var albl: Variant = await backend_label(str(a.get("id", "")))
	print("SMOKE ...its placement saved (radius, along) and the label drawn at the drop point: ", same_place(albl, g["place"]) and (albl as Dictionary).has("radius") and drawn_at(str(a["id"])) != null and (drawn_at(str(a["id"])) as Vector2).distance_to(behind) < 0.05)

	# --- the angle to horizontal, from the line's end
	await pick([["line", free_line]])
	ed.dim_flow.choose(s, "horizontalAngle")
	var end_uv: Vector2 = s.points[s._line_points(free_line)[1]]
	g = await drop_and_type(end_uv + Vector2(-8, 4), str(snappedf(rad_to_deg(atan2(end_uv.y - s.points[s._line_points(free_line)[0]].y, end_uv.x - s.points[s._line_points(free_line)[0]].x)), 0.01)))
	var ha := newest("horizontal_angle")
	print("SMOKE Angle to horizontal dropped near the line's end, left of it: quadrant 3 on the backend, its placement saved: ", int(g.get("quadrant", -1)) == 3 and not ha.is_empty() and int(ha.get("quadrant", -1)) == 3 and same_place(await backend_label(str(ha.get("id", ""))), g["place"]))

	# --- B steps back: nothing made
	var count: int = s.constraints.size()
	await pick([["line", la]])
	ed.dim_flow.preview(s, Vector2(130, -10), 1.0)
	ed.dim_flow.drop(s, Vector2(130, -10), 1.0)
	var back1: String = ed.dim_flow.step_back(s)
	var back2: String = ed.dim_flow.step_back(s)
	print("SMOKE a drop stepped back from (B, B): pad -> preview -> picking, and nothing is made: ", back1 == "preview" and back2 == "picking" and s.selection.is_empty() and s.constraints.size() == count)
	quit()
