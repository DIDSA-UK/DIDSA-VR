extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): LOFT and SWEEP (Phase 6.2 / 6.3). Loft: a 40 x 40 square on XY and a 20 x 20 square on a plane 30 mm up;
## the laser's pick of one line of each (read from the finished sketches, as the editor does) gives a two-section loft: a solid 30 mm tall; the coarse preview
## (nothing stored) answered with a mesh; the Build row reads "Boss, 2 sections" and Edit changes Ruled. Sweep: a circle (r 5) as the open profile, a 50 mm line on
## the XZ plane as the path picked from the finished sketch: a pipe 50 mm long.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_loft_sweep.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func rect(ed, a: Vector2, b: Vector2) -> void:
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": a})
	await ed.session.tap({"uv": b})


func pick_first_curve_of(ed, sketch_feature_id: String) -> void:
	for c in ed.sketch_picks.candidates():
		if str(c["sketch_feature_id"]) == sketch_feature_id:
			ed._hover_face = c
			ed._toggle_curve()
			return


func pick_sketch_line(ed, sketch_feature_id: String) -> void:
	## A pull on a line of that sketch with the viewport sketch picking (Loft with no sketch open): the sketch becomes the next section.
	for c in ed.rest_sketches.candidates():
		if str(c["sketch_feature_id"]) == sketch_feature_id:
			ed._hover_face = c
			ed._pick_sketch()
			return


func fresh_part() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")


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
	await fresh_part()
	# sketch A on XY, then a plane at 30, sketch B on it
	await ed.begin_sketch({"fixed": "XY"})
	await rect(ed, Vector2(0, 0), Vector2(40, 40))
	var sketch_a: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	table.manager.activate("create_plane")
	ed._hover_plane = "XY"
	await ed._pick_plane()
	ed.option_typed("plane_offset", "30")
	await ed.apply_feature()
	table.manager.deactivate()
	var plane_id: String = ed.feature_stack.back()
	ed.set_state("pick_plane")
	ed._hover_plane = "plane:" + plane_id
	await ed._pick_plane()
	await wait_for(func() -> bool: return ed.state == "sketch")
	await rect(ed, Vector2(10, 10), Vector2(30, 30))
	var sketch_b: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await table.build.reload()
	# Loft
	table.manager.activate("loft")
	var loaded: bool = await wait_for(func() -> bool: return ed.rest_sketches != null and is_instance_valid(ed.rest_sketches) and ed.rest_sketches.candidates().size() >= 8)
	print("SMOKE both finished sketches are drawn, read from the real backend (at least the two squares' eight lines), and Loft offers them as sections: ", loaded and ed.state == "pick_sketch", " ", ed.rest_sketches.candidates().size() if ed.rest_sketches != null else 0)
	pick_sketch_line(ed, sketch_a)
	pick_sketch_line(ed, sketch_b)
	print("SMOKE a pull on a line of each makes two sections, in pick order: ", ed.seed_sketches == [sketch_a, sketch_b])
	ed.options["boss"] = true
	ed.preview_enabled = true
	ed.schedule_preview()
	var previewed: bool = await wait_for(func() -> bool: return ed.preview.is_showing())
	print("SMOKE the coarse preview (real route) answers with a mesh and creates no feature: ", previewed and ed.preview_feature_id == "" and ed.preview.triangles > 0, " ", ed.preview.triangles)
	ed.preview_enabled = false
	var before: Array = (await ed.features.list_features(ed.part_id))["features"]
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var after: Array = (await ed.features.list_features(ed.part_id))["features"]
	var size: Vector3 = table.seated.get_aabb().size
	print("SMOKE Apply makes the real loft: a solid 40 x 40 x 30: ", after.size() == before.size() + 1 and absf(size.z - 30.0) < 0.5 and absf(size.x - 40.0) < 0.5, " ", size)
	var loft_row := {}
	for f in after:
		if str(f.get("type", "")) == "loft":
			loft_row = f
	print("SMOKE ...its row reads Boss, 2 sections and offers Edit: ", BuildTree.summary(after, after.find(loft_row)) == "Boss, 2 sections" and (loft_row.get("sections", []) as Array).size() == 2)
	await table.build.reload()
	await ed.begin_tool_edit(str(loft_row["id"]))
	await ed.on_option("ruled")
	await ed.apply_feature()
	var edited: Array = (await ed.features.list_features(ed.part_id))["features"]
	var ruled_row := {}
	for f in edited:
		if str(f.get("type", "")) == "loft":
			ruled_row = f
	print("SMOKE Edit > Ruled > Apply PATCHes the real loft (ruled is now true): ", bool(ruled_row.get("ruled", false)) and not table.is_blank())
	# Sweep, on a fresh part
	await fresh_part()
	await ed.begin_sketch({"fixed": "XZ"})
	table.manager.activate("line")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(0, 50)})
	ed.session.finish_chain()
	var path_sketch: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await table.build.reload()
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("circle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(5, 0)})
	table.manager.activate("sweep")
	var swept_ready: bool = await wait_for(func() -> bool: return ed.sketch_picks != null and is_instance_valid(ed.sketch_picks) and ed.sketch_picks.candidates().size() >= 1)
	pick_first_curve_of(ed, path_sketch)
	print("SMOKE with the circle open, Sweep reads the earlier sketch's line and a pick makes the path: ", swept_ready and ed.curve_picks.size() == 1)
	await ed.apply_feature()
	var piped: bool = await wait_for(func() -> bool: return not table.is_blank())
	var pipe: Vector3 = table.seated.get_aabb().size
	print("SMOKE Apply sweeps it: a pipe 10 x 10 x 50: ", piped and absf(pipe.z - 50.0) < 0.5 and absf(pipe.x - 10.0) < 0.5, " ", pipe)
	quit()
