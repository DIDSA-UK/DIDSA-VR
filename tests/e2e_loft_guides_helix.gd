extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): LOFT GUIDES and the HELIX tool (DIDSA-CAD docs/loft-gordon-and-helix-plan.md, milestone 4).
## Loft: a 40 x 40 square on XY (centred) and a 20 x 20 square on a plane 30 mm up, with a two-line guide drawn on the XZ plane that runs through the middle of the +X edge of both
## squares and bulges out to x = 28 at mid-height. The laser's pulls (sections, Add guide, the two lines, Done) and Apply make a solid that is 40 mm wide without the guide and reaches
## x = 28 with it; the Build row says "1 guide"; Edit > remove the guide > Apply takes the bulge away again; a guide that misses by far is refused in the backend's words.
## Helix: the Helix tool with a taper to an end diameter and three segments makes a curve feature whose row carries the end radius, the taper angle, the segments and the height.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_loft_guides_helix.gd  (needs secrets.cfg and a running backend)

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


func pick_sketch_line(ed, sketch_feature_id: String) -> void:
	for c in ed.rest_sketches.candidates():
		if str(c["sketch_feature_id"]) == sketch_feature_id:
			ed._hover_face = c
			ed._pick_sketch()
			return


func pull_curves_of(ed, sketch_feature_id: String) -> int:
	var n := 0
	for c in ed.sketch_picks.candidates():
		if str(c["sketch_feature_id"]) == sketch_feature_id:
			ed._hover_face = c
			ed._toggle_curve()
			n += 1
	return n


func fresh_part() -> void:
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return table.editor.state == "pick_plane")


func loft_rows(ed) -> Array:
	return ((await ed.features.list_features(ed.part_id))["features"] as Array).filter(func(f): return str(f.get("type", "")) == "loft")


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

	# --- Loft with a guide
	await fresh_part()
	await ed.begin_sketch({"fixed": "XY"})
	await rect(ed, Vector2(-20, -20), Vector2(20, 20))
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
	await rect(ed, Vector2(-10, -10), Vector2(10, 10))
	var sketch_b: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	# the guide, on XZ (the plane's x runs the other way: world x = -u): (20, 0, 0) -> (28, 0, 15) -> (10, 0, 30)
	await ed.begin_sketch({"fixed": "XZ"})
	table.manager.activate("line")
	await ed.session.tap({"uv": Vector2(-20, 0)})
	await ed.session.tap({"uv": Vector2(-28, 15)})
	await ed.session.tap({"uv": Vector2(-10, 30)})
	ed.session.finish_chain()
	var guide_sketch: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await table.build.reload()

	table.manager.activate("loft")
	await wait_for(func() -> bool: return ed.rest_sketches != null and is_instance_valid(ed.rest_sketches) and ed.rest_sketches.candidates().size() >= 10)
	pick_sketch_line(ed, sketch_a)
	pick_sketch_line(ed, sketch_b)
	print("SMOKE two sections picked, and Add guide is offered: ", ed.seed_sketches == [sketch_a, sketch_b] and table.props.option_ids().has("guide_add"))
	await ed.on_option("guide_add")
	var ready: bool = await wait_for(func() -> bool: return ed.state == "pick_curves" and ed.sketch_picks != null and is_instance_valid(ed.sketch_picks) and ed.sketch_picks.sketches.has(guide_sketch)) # the sketches are read one after another: wait for the guide's
	var pulled: int = pull_curves_of(ed, guide_sketch)
	print("SMOKE Add guide reads the finished sketches' curves; pulling the guide's two lines makes one guide of two curves: ", ready and pulled == 2 and ed.guide_draft.size() == 2 and ed.curve_picks.is_empty())
	await ed.on_option("guide_done")
	await wait_for(func() -> bool: return ed.state == "pick_sketch")
	print("SMOKE Done keeps it and goes back to the sections (still two): ", ed.guides.size() == 1 and ed.seed_sketches == [sketch_a, sketch_b])
	ed.options["boss"] = true
	ed.preview_enabled = true
	ed.schedule_preview()
	var previewed: bool = await wait_for(func() -> bool: return ed.preview.is_showing())
	print("SMOKE the coarse preview (real route) accepts the guide and shows a mesh: ", previewed and ed.preview.triangles > 0, " ", ed.preview.triangles)
	ed.preview_enabled = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var size: Vector3 = table.seated.get_aabb().size
	var rows: Array = await loft_rows(ed)
	print("SMOKE Apply makes the guided loft: 30 tall and bulging out to x = 28 (48 wide from -20) instead of 40: ", rows.size() == 1 and absf(size.z - 30.0) < 0.5 and size.x > 46.0 and size.x < 50.0, " ", size)
	print("SMOKE ...no warning, and the row reads '1 guide': ", not table.status().contains("misses") and (rows[0].get("guide_curves", []) as Array).size() == 1 and BuildTree.summary(rows, 0) == "Boss, 2 sections, 1 guide")
	var loft_id: String = str(rows[0]["id"])
	await table.build.reload()
	await ed.begin_tool_edit(loft_id)
	print("SMOKE Edit loads the guide: ", ed.guides.size() == 1 and (ed.guides[0] as Array).size() == 2)
	await ed.on_option("guide_del_0")
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	size = table.seated.get_aabb().size
	rows = await loft_rows(ed)
	print("SMOKE ...removing it and Apply gives the plain loft again: 40 wide, no guides: ", absf(size.x - 40.0) < 0.5 and (rows[0].get("guide_curves", []) as Array).is_empty(), " ", size)

	# --- a guide that misses by far: a second sketch away from the squares
	await ed.begin_sketch({"fixed": "XZ"})
	table.manager.activate("line")
	await ed.session.tap({"uv": Vector2(-200, 0)})
	await ed.session.tap({"uv": Vector2(-210, 30)})
	ed.session.finish_chain()
	var far_sketch: String = ed.session.feature_id
	var far_ref := {"sketch_id": ed.session.sketch_id, "entity_type": "line", "entity_id": str((ed.session.lines.keys() as Array)[0])}
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await table.build.reload()
	var refused: Dictionary = await ed.features.update_feature(ed.part_id, "loft", loft_id, {"guide_curves": [[far_ref]]})
	print("SMOKE a guide 200 mm from the squares is refused, and the message names the guide and the section (not just a type): ", not bool(refused["ok"]) and str(refused["error"]).contains("guide 1") and str(refused["error"]).contains("section 1"), " ", refused["error"])

	# --- Helix
	await fresh_part()
	table.manager.activate("helix")
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var tool = ed.tools["helix"]
	tool.type_value(ed, "h_diameter", "20")
	await ed.on_option("h_taper") # end diameter
	tool.type_value(ed, "h_taper_value", "28")
	await ed.on_option("h_add")
	await ed.on_option("h_add")
	tool.type_value(ed, "h_pitch_0", "2")
	tool.type_value(ed, "h_turns_0", "2")
	tool.type_value(ed, "h_pitch_1", "6")
	tool.type_value(ed, "h_turns_1", "3")
	tool.type_value(ed, "h_pitch_2", "2")
	tool.type_value(ed, "h_turns_2", "2")
	await ed.on_option("h_hand") # left-handed
	await ed.apply_feature()
	var curves: Array = ((await ed.features.list_features(ed.part_id))["features"] as Array).filter(func(f): return str(f.get("type", "")) == "curve")
	var row: Dictionary = curves[0] if not curves.is_empty() else {}
	var ok_row: bool = not row.is_empty() and str(row.get("curve_type", "")) == "helix" and absf(float(row.get("end_radius", 0.0)) - 14.0) < 1e-9 and (row.get("segments", []) as Array).size() == 3 and absf(float(row.get("total_height", 0.0)) - 26.0) < 1e-9 and row.get("right_handed") == false
	print("SMOKE Apply makes a left-handed helix curve: R 10 to 14, three segments, 26 mm tall: ", ok_row, " ", row.get("segments"), " ", row.get("total_height"))
	print("SMOKE ...the backend returns the taper as an angle too (atan(4 / 26) = 8.75 degrees) and a length: ", absf(float(row.get("taper_angle_degrees", 0.0)) - rad_to_deg(atan(4.0 / 26.0))) < 1e-6 and float(row.get("length", 0.0)) > 500.0, " ", row.get("taper_angle_degrees"), " ", row.get("length"))
	print("SMOKE ...its Build row reads the diameters, turns, segments and hand: ", BuildTree.summary(curves, 0) == "D 20 to 28 mm, 7 turns, 3 segments, left-handed", " ", BuildTree.summary(curves, 0))
	var helix_id: String = str(row.get("id", ""))
	await table.build.reload()
	await ed.begin_tool_edit(helix_id)
	await ed.on_option("h_taper") # end diameter -> angle
	tool.type_value(ed, "h_taper_value", "-5")
	await ed.apply_feature()
	curves = ((await ed.features.list_features(ed.part_id))["features"] as Array).filter(func(f): return str(f.get("type", "")) == "curve")
	row = curves[0] if not curves.is_empty() else {}
	print("SMOKE Edit > angle -5 > Apply PATCHes the curve: the end radius is now 10 - 26 x tan(5 degrees) = 7.73: ", absf(float(row.get("end_radius", 0.0)) - (10.0 - 26.0 * tan(deg_to_rad(5.0)))) < 1e-6, " ", row.get("end_radius"), " ", row.get("taper_angle_degrees"))
	quit()
