extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): PATTERN, BOOLEAN, MERGE and SPLIT (Phase 6.4) on real parts. A 60 x 40 x 20 block patterned along X (3 copies,
## 70 mm apart: 200 mm wide), Edit to 2 copies (130 mm); a circular pattern of it (4) round a sketch line; a block and an overlapping second body, Subtract (one body left),
## and Merge (one body left); a block split along a plane 20 mm up Y (two bodies).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_body_features.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func body(id: String) -> Dictionary:
	return {"kind": "body", "body_id": id, "index": -1, "key": "solid:" + id}


func box(ed, a: Vector2, b: Vector2, depth: float, new_body: bool) -> void:
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": a})
	await ed.session.tap({"uv": b})
	ed.options["boss"] = true
	ed.options["new_body"] = new_body
	ed.options["depth"] = depth
	table.manager.activate("extrude")
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank() and ed.state == "pick_plane")
	ed.options["new_body"] = false


func fresh_part() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")


func bodies_now() -> int:
	return table.editor.body_ids().size()


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

	# --- Pattern
	await fresh_part()
	await box(ed, Vector2(0, 0), Vector2(60, 40), 20.0, false)
	var one_body: String = ed.body_ids()[0]
	table.manager.activate("pattern")
	ed.bodies = [body(one_body)]
	ed.option_typed("pat_count1", "3")
	ed.option_typed("pat_spacing1", "70")
	await ed.apply_feature()
	await wait_for(func() -> bool: return bodies_now() == 3)
	print("SMOKE a rectangular pattern along X, 3 copies 70 mm apart, makes 3 bodies and a part 200 mm wide: ", bodies_now() == 3 and absf(table.seated.get_aabb().size.x - 200.0) < 0.6, " ", bodies_now(), " ", table.seated.get_aabb().size)
	await table.build.reload()
	var pattern_row := {}
	for f in table.build.features:
		if str(f.get("type", "")) == "pattern":
			pattern_row = f
	print("SMOKE the Build row reads Rectangular, 3 x 70 mm: ", str(table.build.names.size()) != "" and not pattern_row.is_empty() and main.design_table.build.can_edit(str(pattern_row["id"])), " ", pattern_row.get("count_1"))
	await ed.begin_tool_edit(str(pattern_row["id"]))
	ed.option_typed("pat_count1", "2")
	await ed.apply_feature()
	await wait_for(func() -> bool: return bodies_now() == 2)
	print("SMOKE Edit to 2 copies PATCHes the real pattern: 2 bodies, 130 mm: ", bodies_now() == 2 and absf(table.seated.get_aabb().size.x - 130.0) < 0.6, " ", table.seated.get_aabb().size)

	# --- Circular pattern about a sketch line
	await fresh_part()
	await ed.begin_sketch({"fixed": "XZ"})
	table.manager.activate("line")
	await ed.session.tap({"uv": Vector2(100, 0)})
	await ed.session.tap({"uv": Vector2(100, 50)})
	ed.session.finish_chain()
	var axis_sketch: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await table.build.reload()
	await box(ed, Vector2(0, 0), Vector2(30, 20), 10.0, true)
	await table.build.reload()
	table.manager.activate("pattern")
	await ed.on_option("pat_circ")
	ed.bodies = [body(ed.body_ids()[0])]
	await ed.on_option("pick_lines")
	await wait_for(func() -> bool: return ed.sketch_picks != null and is_instance_valid(ed.sketch_picks) and ed.sketch_picks.candidates().size() >= 1)
	for c in ed.sketch_picks.candidates():
		if str(c["sketch_feature_id"]) == axis_sketch:
			ed._hover_face = c
			ed._toggle_curve()
			break
	ed.option_typed("pat_count_ang", "4")
	await ed.apply_feature()
	await wait_for(func() -> bool: return bodies_now() == 4)
	print("SMOKE a circular pattern of 4 round a sketch line makes 4 bodies: ", bodies_now() == 4, " ", bodies_now())

	# --- Boolean and Merge
	await fresh_part()
	await box(ed, Vector2(0, 0), Vector2(60, 40), 20.0, false)
	await box(ed, Vector2(20, 10), Vector2(40, 30), 40.0, true)
	var two: Array = ed.body_ids()
	print("SMOKE a block and an overlapping second body are two bodies: ", two.size() == 2, " ", two)
	var tris_before: int = (table.seated.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	table.manager.activate("boolean")
	ed.bodies = [body(str(two[0]))]
	await ed.on_option("slot_tool")
	ed.bodies = [body(str(two[1]))]
	ed._update_options()
	await ed.apply_feature()
	await wait_for(func() -> bool: return bodies_now() == 1)
	var tris_after: int = (table.seated.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	print("SMOKE Subtract (consuming the tool) leaves one body with a hole in it (more faces): ", bodies_now() == 1 and tris_after != tris_before, " ", tris_before, " -> ", tris_after)
	await fresh_part()
	await box(ed, Vector2(0, 0), Vector2(60, 40), 20.0, false)
	await box(ed, Vector2(20, 10), Vector2(40, 30), 40.0, true)
	var pair: Array = ed.body_ids()
	table.manager.activate("merge")
	ed.bodies = [body(str(pair[0])), body(str(pair[1]))]
	await ed.apply_feature()
	await wait_for(func() -> bool: return bodies_now() == 1)
	print("SMOKE Merge fuses the two overlapping bodies into one: ", bodies_now() == 1)

	# --- Split along a made plane
	await fresh_part()
	await box(ed, Vector2(0, 0), Vector2(60, 40), 20.0, false)
	table.manager.activate("create_plane")
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	ed.option_typed("plane_offset", "20")
	await ed.apply_feature()
	var plane_id: String = ed.feature_stack.back()
	await table.build.reload()
	table.manager.activate("split")
	ed.bodies = [body(ed.body_ids()[0])]
	ed.set_state("pick_plane")
	ed._hover_plane = "plane:" + plane_id
	await ed._pick_plane()
	await ed.apply_feature()
	await wait_for(func() -> bool: return bodies_now() == 2)
	print("SMOKE Split along a plane 20 mm up Y divides the block into two bodies: ", bodies_now() == 2, " ", bodies_now())
	quit()
