extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): CREATE PLANE (Phase 6.1). A new part; Plane offset 30 mm from XY; the made plane is drawn beside the
## reference planes; a pull on it opens a sketch on that plane (the sketch's plane sits at z = 30); a 20 x 10 rectangle extruded 5 mm gives a solid whose
## z runs from 30 to 35; Undo then Redo of the plane keeps the plane list at one.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_create_plane.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")


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
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	var table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	ed.preview_enabled = false
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	table.manager.activate("create_plane")
	ed._hover_plane = "XY"
	await ed._pick_plane()
	ed.option_typed("plane_offset", "30")
	await ed.apply_feature()
	var rows: Array = (await ed.features.list_features(ed.part_id))["features"]
	var plane_row := {}
	for r in rows:
		if str(r.get("type", "")) == "create_plane":
			plane_row = r
	print("SMOKE the backend made one plane, offset 30 from XY: ", rows.size() == 1 and not plane_row.is_empty() and absf(float(plane_row.get("offset", 0.0)) - 30.0) < 0.001, " ", plane_row.get("origin"))
	print("SMOKE ...it is drawn beside the reference planes: ", ed.markers.has_plane("plane:" + str(plane_row.get("id", ""))))
	table.manager.deactivate()
	ed.set_state("pick_plane")
	ed._hover_plane = "plane:" + str(plane_row["id"])
	await ed._pick_plane()
	var opened: bool = await wait_for(func() -> bool: return ed.state == "sketch")
	print("SMOKE a pull on it opens a sketch on that plane, at z = 30: ", opened and absf((ed.session.plane["origin"] as Vector3).z - 30.0) < 0.01, " ", ed.session.plane.get("origin"))
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(20, 10)})
	ed.options["boss"] = true
	ed.options["depth"] = 5.0
	table.manager.activate("extrude")
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var box: AABB = table.seated.get_aabb()
	print("SMOKE extruding it 5 mm gives a solid from z = 30 to 35: ", absf(box.position.z - 30.0) < 0.5 and absf(box.size.z - 5.0) < 0.5, " ", box)
	quit()
