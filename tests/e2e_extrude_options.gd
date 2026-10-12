extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): Phase 7.1's Extrude options on the
## design table against the real feature schemas. A 60 x 40 rectangle extruded 20 mm is a 48000 mm3 solid; Both sides spans -10 to +10; a thin wall of
## 2 mm is a hollow shell of the expected volume in each direction (outward / inward / symmetric); a draft widens it; a wall and a draft together are
## refused by the backend with its own message; Edit from the Build row turns the wall off (an explicit null) and Undo brings it back.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_extrude_options.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

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


func volume(ed) -> float:
	## Total volume of the part's bodies (mm3) from the backend, not the mesh.
	var res: Dictionary = await ed.api.request(HTTPClient.METHOD_GET, "/document/parts/%s/mass-properties" % ed.part_id)
	var total := 0.0
	if bool(res.get("ok", false)):
		for v in (res["json"]["body_volumes"] as Dictionary).values():
			total += float(v)
	return total


func near(a: float, b: float, tolerance := 0.01) -> bool:
	return absf(a - b) <= absf(b) * tolerance


func new_rect_part(ed) -> MeshInstance3D:
	var before = table.seated
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane" and table.seated != null and table.seated != before)
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(60, 40)})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	for key in ["ext_sym", "ext_thin", "ext_draft"]:
		ed.options[key] = false
	return table.seated


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
	await main.new_assembly()

	# --- Both sides: a 20 mm depth spans -10 to +10 about the sketch plane
	var node: MeshInstance3D = await new_rect_part(ed)
	ed.options["ext_sym"] = true
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var box := node.get_aabb()
	print("SMOKE Both sides: a 20 mm depth spans -10 to +10 on the real backend (60 x 40 x 20): ", absf(box.size.z - 20.0) < 0.5 and absf(box.position.z + 10.0) < 0.5, " ", box)
	var solid := await volume(ed)
	print("SMOKE ...and the volume is 48000 mm3: ", near(solid, 48000.0), " ", solid)

	# --- Thin wall, 2 mm, outward: made, then Edit moves it inward and then to the middle (same Edit path, one PATCH each)
	node = await new_rect_part(ed)
	ed.options["ext_thin"] = true
	ed.options["ext_wall"] = 2.0
	ed.options["ext_dir"] = "outward"
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var b = table.build
	await wait_for(func() -> bool: return b.features.size() == 2)
	var extrude_id := str(b.features[1]["id"])
	var outward := await volume(ed)
	print("SMOKE Thin wall 2 mm outward is a hollow shell of (64 x 44 - 60 x 40) x 20 = 8320 mm3: ", near(outward, 8320.0), " ", outward)
	print("SMOKE ...the Build row says so: ", b.features[1].get("thickness") != null and str(b.features[1].get("thickness_direction")) == "outward" and BuildTree.summary(b.features, 1).contains("wall 2"))
	await ed.begin_tool_edit(extrude_id)
	print("SMOKE Edit on the Build row opens the Extrude tool with the wall and its side loaded: ", not ed.editing.is_empty() and bool(ed.options["ext_thin"]) and ed.options["ext_wall"] == 2.0 and str(ed.options["ext_dir"]) == "outward" and float(ed.options["depth"]) == 20.0)
	ed.options["ext_dir"] = "inward"
	await ed.apply_feature()
	await wait_for(func() -> bool: return str(b.features[1].get("thickness_direction", "")) == "inward")
	var inward := await volume(ed)
	print("SMOKE ...changed to inward it is (60 x 40 - 56 x 36) x 20 = 7680 mm3 (the backend's own inward sign is unconfirmed in its docs: this checks it): ", near(inward, 7680.0), " ", inward)
	await ed.begin_tool_edit(extrude_id)
	ed.options["ext_dir"] = "symmetric"
	await ed.apply_feature()
	await wait_for(func() -> bool: return str(b.features[1].get("thickness_direction", "")) == "symmetric")
	var middle := await volume(ed)
	print("SMOKE ...from the middle it is (62 x 42 - 58 x 38) x 20 = 8000 mm3: ", near(middle, 8000.0), " ", middle)

	# --- Edit turns the wall off (an explicit null), Undo puts it back
	await ed.begin_tool_edit(extrude_id)
	ed.options["ext_thin"] = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return b.features[1].get("thickness") == null)
	var solid_again := await volume(ed)
	print("SMOKE Edit with Thin wall off clears the wall on the backend and the part is solid again (48000 mm3): ", b.features[1].get("thickness") == null and near(solid_again, 48000.0), " ", solid_again)
	await ed.undo()
	await wait_for(func() -> bool: return b.features[1].get("thickness") != null)
	var restored := await volume(ed)
	print("SMOKE ...Undo puts the wall back (8000 mm3 again): ", b.features[1].get("thickness") != null and near(restored, 8000.0), " ", restored)

	# --- A wall and a draft together: the tool refuses, and the backend refuses the same thing with its own words
	var sketch_id := str(b.features[0]["id"])
	var both: Dictionary = await ed.api.request(HTTPClient.METHOD_POST, "/document/parts/%s/extrude-features" % ed.part_id,
		{"sketch_feature_id": sketch_id, "extrude_type": "boss", "start_distance": 0.0, "end_distance": 5.0, "target_body_ids": [], "thickness": 1.0, "draft_angle": 5.0})
	print("SMOKE The backend refuses a wall and a draft together (a 4xx with a reason): ", not bool(both.get("ok", true)) and str(both.get("error", "")) != "", " ", both.get("error", ""))

	# --- Draft: a 5 degree outward taper over 20 mm makes the part wider at the top, so more volume than the straight prism
	node = await new_rect_part(ed)
	ed.options["ext_draft"] = true
	ed.options["ext_angle"] = 5.0
	ed.options["ext_draft_out"] = true
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var drafted := await volume(ed)
	var top := node.get_aabb().size
	print("SMOKE Draft 5 degrees outward over 20 mm: wider than the sketch (more than 48000 mm3, and a bounding box wider than 60 x 40) on the real backend: ", drafted > 49000.0 and top.x > 61.0 and top.y > 41.0, " ", drafted, " ", top)
	quit()
