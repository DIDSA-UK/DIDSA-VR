extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): Revolve on the design
## table. A new part, a sketch on XY with a rectangle beside a vertical line, Revolve with that line as the axis through the editor's own
## options (Axis, Angle, Boss) and Apply; the real mesh is a ring-shaped solid of the expected size; the Build tree lists the revolve with
## its angle and its Edit changes the angle (the mesh follows); Undo takes it back.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_revolve.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


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
	var ed = table.editor

	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	var s = ed.session
	s.set_tool("rectangle")
	await s.tap({"uv": Vector2(10, 0)})
	await s.tap({"uv": Vector2(30, 40)})
	s.set_tool("line")
	await s.tap({"uv": Vector2(0, 0)})
	await s.tap({"uv": Vector2(0, 50)})
	s.finish_chain()
	var axis_line := ""
	for id in s.lines:
		var l: Dictionary = s.lines[id]
		if absf(s.points[l["a"]].x) < 0.01 and absf(s.points[l["b"]].x) < 0.01 and absf(s.points[l["b"]].y - s.points[l["a"]].y) > 40.0:
			axis_line = id
	print("SMOKE a closed rectangle and a separate vertical line are in the sketch: ", s.profile_ok() and axis_line != "")

	table.manager.activate("revolve")
	ed.revolve_axis = axis_line # (the laser pick is covered by design_table_editing.gd)
	ed.options["boss"] = true
	ed.options["angle"] = 360.0
	await ed.apply_feature()
	var done: bool = await wait_for(func() -> bool: return not table.is_blank())
	var size := node.get_aabb().size
	print("SMOKE Revolve 360 about that line makes a real solid: a ring 60 mm across (the rectangle reaches 30 mm out) and 40 mm along the axis (the part's Y): ", done and absf(size.x - 60.0) < 1.0 and absf(size.y - 40.0) < 1.0 and absf(size.z - 60.0) < 1.0, " ", size)
	await wait_for(func() -> bool: return table.build.features.size() == 2)
	var b = table.build
	var kinds: Array = b.features.map(func(f): return f["type"])
	print("SMOKE the Build tree lists the sketch and the revolve, with its angle: ", kinds == ["sketch", "revolve"] and b.names == ["Sketch 1", "Revolve 1"] and str(b.features[1].get("angle")) == "360.0" and table.tree._build_rows.find_children("*", "Button", true, false).any(func(x): return x.text.contains("Boss 360 deg")))
	var revolve_id: String = b.features[1]["id"]
	await b.edit_typed(revolve_id, "180")
	var half_ok: bool = await wait_for(func() -> bool: return absf(node.get_aabb().size.z - 30.0) < 1.5 and absf(node.get_aabb().size.x - 60.0) < 1.0)
	print("SMOKE Edit changes the angle to 180 on the backend and the mesh follows (a half ring: 30 mm instead of 60 across): ", half_ok, " ", node.get_aabb().size)
	print("SMOKE a typed angle over 360 is refused with no change: ", await _refused(b, revolve_id))
	await ed.undo()
	await wait_for(func() -> bool: return float(b.features[1]["angle"]) == 360.0)
	print("SMOKE Undo puts the 360 back: ", float(b.features[1]["angle"]) == 360.0)
	quit()


func _refused(b, id: String) -> bool:
	var before: float = float(b.row(id)["angle"])
	await b.edit_typed(id, "400")
	return float(b.row(id)["angle"]) == before
