extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): a sketch aligned to an edge and
## flipped (DIDSA-CAD docs/flutter-testing-feedback-2026-11-11-plan.md item 2, V2). A new part, a sketch on XY with one line at 30 degrees; a second sketch
## on XY aligned to that line (PATCH .../sketch-alignment) and then flipped (the flat app's controls); reopened here from the Build tree (it used to be
## refused); a 10 x 6 rectangle drawn at its local origin and extruded 5 mm. The backend's solid is where the frame says: 11.66 x 10.2 x 5 mm.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_revolve.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const SketchMathRef := preload("res://scripts/design_table/sketch_math.gd")

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
	var first = ed.session
	first.set_tool("line")
	await first.tap({"uv": Vector2(0, 0)})
	await first.tap({"uv": Vector2(20, 20.0 * tan(deg_to_rad(30.0)))})
	first.finish_chain()
	var line_id := ""
	for id in first.lines:
		line_id = str(id)
	var first_sketch_id: String = first.sketch_id
	var part_id: String = ed.part_id
	ed.end_sketch()
	await wait_for(func() -> bool: return table.build.features.size() == 1)

	var made: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts/%s/features/sketch" % part_id, {"plane": "XY"})
	var second_feature: String = str(made["json"]["id"])
	var second_sketch: String = str(made["json"]["sketch_id"])
	var aligned: Dictionary = await api.request(HTTPClient.METHOD_PATCH, "/document/parts/%s/features/%s/sketch-alignment" % [part_id, second_feature],
		{"x_axis_ref": {"sketch_id": first_sketch_id, "entity_type": "line", "entity_id": line_id}})
	var flipped: Dictionary = await api.request(HTTPClient.METHOD_PATCH, "/sketch/sketches/%s/orientation" % second_sketch, {"flip": true, "rotation_quarter_turns": 0})
	print("SMOKE the backend aligned the second sketch to the 30 degree line and flipped it: ", aligned["ok"] and flipped["ok"])
	await table.build.reload()
	await wait_for(func() -> bool: return table.build.features.size() == 2)
	var row: Dictionary = table.build.row(second_feature)
	var c := cos(deg_to_rad(30.0))
	var s := sin(deg_to_rad(30.0))
	print("SMOKE its row carries the resolved frame: x = -(cos 30, sin 30, 0), y = (-sin 30, cos 30, 0): ", SketchMathRef.has_frame(row) and Vector3(row["resolved_x_axis"][0], row["resolved_x_axis"][1], row["resolved_x_axis"][2]).is_equal_approx(Vector3(-c, -s, 0)) and Vector3(row["resolved_y_axis"][0], row["resolved_y_axis"][1], row["resolved_y_axis"][2]).is_equal_approx(Vector3(-s, c, 0)))

	var opened: bool = await ed.reopen_sketch(second_feature)
	print("SMOKE reopening the aligned, flipped sketch from the Build tree works (it used to be refused): ", opened and ed.session != null)
	var sess = ed.session
	sess.set_tool("rectangle")
	await sess.tap({"uv": Vector2(0, 0)})
	await sess.tap({"uv": Vector2(10, 6)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 5.0
	await ed.apply_feature()
	var done: bool = await wait_for(func() -> bool: return table.build.features.size() == 3)
	await wait_for(func() -> bool: return not table.is_blank())
	var sizes := [node.get_aabb().size.x, node.get_aabb().size.y, node.get_aabb().size.z]
	sizes.sort()
	var expect_x := 10.0 * c + 6.0 * s # 11.66
	var expect_y := 10.0 * s + 6.0 * c # 10.196
	print("SMOKE the extruded solid is where the frame says (11.66 x 10.2 x 5 mm, whatever way the table turns it): ", done and absf(sizes[0] - 5.0) < 0.5 and absf(sizes[1] - expect_y) < 0.6 and absf(sizes[2] - expect_x) < 0.6, " ", sizes)
	quit()
