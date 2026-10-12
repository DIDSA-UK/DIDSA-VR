extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY, never against a shared backend): Phase 7.2's small tool options on the design table
## against the real feature schemas. A 60 x 40 x 20 box (48000 mm3). Chamfer: a plain symmetric chamfer removes some volume, the same edge with a 30 degree angle removes
## tan(30) = 0.577 of it (flipped too, a right-angle corner is symmetric), turning the angle off by Edit restores the plain one. Move Face along X moves the +X face by +10 / -10
## (70 / 50 wide), the Build row says so. Pattern: 5 copies along X are 5 bodies, Edit with copy 2 skipped leaves 4. Loft: two squares lofted solid, then thin (a hollow tube), then Edit
## turns the wall off again (the backend now reads an explicit null as "no wall").
## Run: "$GODOT" --headless --path . --script res://tests/e2e_options_small.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func volumes(ed) -> Dictionary:
	var res: Dictionary = await ed.api.request(HTTPClient.METHOD_GET, "/document/parts/%s/mass-properties" % ed.part_id)
	return (res["json"]["body_volumes"] as Dictionary) if bool(res.get("ok", false)) else {}


func total(ed) -> float:
	var t := 0.0
	for v in (await volumes(ed)).values():
		t += float(v)
	return t


func near(a: float, b: float, tolerance := 0.01) -> bool:
	return absf(a - b) <= absf(b) * tolerance


func rect(ed, a: Vector2, b: Vector2) -> void:
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": a})
	await ed.session.tap({"uv": b})


func box_part(ed) -> MeshInstance3D:
	var before = table.seated
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane" and table.seated != null and table.seated != before)
	await ed.begin_sketch({"fixed": "XY"})
	await rect(ed, Vector2(0, 0), Vector2(60, 40))
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	for key in ["ext_sym", "ext_thin", "ext_draft"]:
		ed.options[key] = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	return table.seated


func a_line_edge(node: MeshInstance3D) -> Dictionary:
	var topo: Dictionary = node.get_meta("topology")
	var body_id: String = topo.keys()[0]
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "line":
			return {"kind": "edge", "body_id": body_id, "index": int(index), "key": TopologyPick.entity_key("edge", body_id, int(index))}
	return {}


func plus_x_face(part: MeshInstance3D) -> Dictionary:
	var best := {}
	var best_x := -INF
	var bodies: Array = part.get_meta("body_ids")
	for i in bodies.size():
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i])))
		if not plane.is_empty() and plane["n"].dot(Vector3(1, 0, 0)) > 0.99 and plane["origin"].x > best_x:
			best_x = plane["origin"].x
			best = {"kind": "face", "body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i]), "key": TopologyPick.entity_key("face", str(bodies[i]), int(part.get_meta("face_ids")[i]))}
	return best


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
	await main.new_assembly()

	# --- Chamfer: plain, then the same edge with an angle (Edit), flipped, then off again
	var node: MeshInstance3D = await box_part(ed)
	var b = table.build
	table.manager.activate("chamfer")
	ed.edges = [a_line_edge(node)]
	ed.options["distance"] = 5.0
	ed.options["ch_angle_on"] = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return b.features.size() == 3)
	var chamfer_id := str(b.features[2]["id"])
	var plain_removed := 48000.0 - await total(ed)
	print("SMOKE A plain 5 mm chamfer of one edge removes volume (12.5 x the edge's length): ", plain_removed > 100.0 and b.features[2].get("edge_options", {}).is_empty(), " ", plain_removed)
	await ed.begin_tool_edit(chamfer_id)
	print("SMOKE Edit on the chamfer's Build row opens the Chamfer tool with its edge and distance: ", not ed.editing.is_empty() and ed.edges.size() == 1 and float(ed.options["distance"]) == 5.0 and not bool(ed.options["ch_angle_on"]))
	ed.options["ch_angle_on"] = true
	ed.options["ch_angle"] = 30.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not (b.features[2].get("edge_options", {}) as Dictionary).is_empty())
	var angled_removed := 48000.0 - await total(ed)
	print("SMOKE ...with a 30 degree angle it removes tan(30) = 0.577 of the plain chamfer's volume: ", near(angled_removed / plain_removed, tan(deg_to_rad(30.0)), 0.02), " ", angled_removed / plain_removed)
	print("SMOKE ...the Build row says angled: ", BuildTree.summary(b.features, 2).ends_with("angled"), " ", BuildTree.summary(b.features, 2))
	await ed.begin_tool_edit(chamfer_id)
	print("SMOKE ...Edit loads the angle back: ", bool(ed.options["ch_angle_on"]) and float(ed.options["ch_angle"]) == 30.0 and not bool(ed.options["ch_flip"]))
	ed.options["ch_flip"] = true
	await ed.apply_feature()
	await wait_for(func() -> bool: return bool(((b.features[2]["edge_options"] as Dictionary).values()[0] as Dictionary).get("flip", false)))
	var flipped_removed := 48000.0 - await total(ed)
	print("SMOKE ...Flip is stored and a right-angle corner removes the same (the other face gets the distance): ", near(flipped_removed, angled_removed, 0.02), " ", flipped_removed)
	await ed.begin_tool_edit(chamfer_id)
	ed.options["ch_angle_on"] = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return (b.features[2].get("edge_options", {}) as Dictionary).is_empty())
	var back_removed := 48000.0 - await total(ed)
	print("SMOKE ...turning the angle off by Edit sends an empty edge_options and the plain chamfer is back: ", near(back_removed, plain_removed, 0.01), " ", back_removed)
	table.manager.deactivate()

	# --- Move Face along X
	node = await box_part(ed)
	b = table.build
	table.manager.activate("move_face")
	ed.faces = [plus_x_face(node)]
	await ed.on_option("mf_dir_x")
	ed.options["mf_offset"] = 10.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return b.features.size() == 3)
	var wider: bool = await wait_for(func() -> bool: return absf(node.get_aabb().size.x - 70.0) < 0.5)
	print("SMOKE Move Face along X by +10 widens the box from 60 to 70 on the real backend: ", wider, " ", node.get_aabb().size)
	print("SMOKE ...its row is a direction move and the Build row names the axis: ", b.features[2].get("direction_ref") != null and b.features[2].get("offset_distance") == null and BuildTree.summary(b.features, 2).ends_with("along X"), " ", BuildTree.summary(b.features, 2))
	await ed.begin_tool_edit(str(b.features[2]["id"]))
	print("SMOKE ...Edit loads X and 10 mm: ", str(ed.options["mf_dir"]) == "x" and float(ed.options["mf_offset"]) == 10.0 and not bool(ed.options["mf_flip"]))
	ed.options["mf_flip"] = true
	await ed.apply_feature()
	var narrower: bool = await wait_for(func() -> bool: return absf(node.get_aabb().size.x - 50.0) < 0.5)
	print("SMOKE ...Reverse by Edit pulls the face the other way, to 50 wide: ", narrower, " ", node.get_aabb().size)
	table.manager.deactivate()

	# --- Pattern: 5 copies along X, then Edit skips copy 2
	node = await box_part(ed)
	b = table.build
	table.manager.activate("pattern")
	ed.bodies = [{"kind": "body", "body_id": str(ed.body_ids()[0]), "index": -1, "key": "solid:%s" % str(ed.body_ids()[0])}]
	ed.options["pat_type"] = "rectangular"
	ed.options["pat_dir1"] = "x"
	ed.options["pat_count1"] = 5.0
	ed.options["pat_spacing1"] = 70.0
	ed.options["pat_dir2"] = "none"
	ed.options["pat_merge"] = false
	await ed.apply_feature()
	await wait_for(func() -> bool: return b.features.size() == 3)
	var five := (await volumes(ed)).size()
	print("SMOKE A pattern of 5 along X (70 mm apart, kept separate) is 5 bodies on the real backend: ", five == 5, " ", five)
	await ed.begin_tool_edit(str(b.features[2]["id"]))
	print("SMOKE ...Edit loads the count, the spacing and no skips: ", float(ed.options["pat_count1"]) == 5.0 and ed.options["pat_skip"] == [])
	ed.tools["pattern"].skip_typed(ed, "2")
	await ed.apply_feature()
	await wait_for(func() -> bool: return (b.features[2].get("skip_indices", []) as Array) == [2])
	var four := (await volumes(ed)).size()
	print("SMOKE ...skipping copy 2 leaves 4 bodies, and the row keeps skip_indices [2]: ", four == 4, " ", four)
	await ed.begin_tool_edit(str(b.features[2]["id"]))
	ed.tools["pattern"].skip_typed(ed, "")
	await ed.apply_feature()
	await wait_for(func() -> bool: return (b.features[2].get("skip_indices", []) as Array).is_empty())
	var again := (await volumes(ed)).size()
	print("SMOKE ...clearing the list by Edit (an empty list is sent) brings the 5th body back: ", again == 5, " ", again)
	table.manager.deactivate()

	# --- Loft: solid, then a thin wall, then the wall off again
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
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
	var made: Dictionary = await ed.features.post(ed.part_id, PartFeatures.loft_request([sketch_a, sketch_b], true, false, []))
	var solid_volume := await total(ed)
	print("SMOKE A loft of two squares (40 and 20 wide, 30 apart) is a solid: ", made["ok"] and solid_volume > 20000.0, " ", solid_volume, " ", made.get("error", ""))
	var loft_row := {}
	for f in (await ed.features.list_features(ed.part_id))["features"]:
		if str(f.get("type")) == "loft":
			loft_row = f
	await table.build.reload()
	await ed.begin_tool_edit(str(loft_row["id"]))
	ed.options["lo_thin"] = true
	ed.options["lo_wall"] = 1.0
	ed.options["lo_closed"] = true
	await ed.apply_feature()
	var thin: bool = await wait_for(func() -> bool: return table.build.row(str(loft_row["id"])).get("thickness") != null)
	var thin_volume := await total(ed)
	print("SMOKE Edit adds a 1 mm wall from the closed profiles: a hollow tube, far less volume than the solid: ", thin and thin_volume > 500.0 and thin_volume < solid_volume * 0.5, " ", thin_volume)
	print("SMOKE ...the Build row says thin wall: ", BuildTree.summary(table.build.features, table.build.index_of(str(loft_row["id"]))).ends_with("thin wall"))
	await ed.begin_tool_edit(str(loft_row["id"]))
	print("SMOKE ...Edit loads the wall and its source: ", bool(ed.options["lo_thin"]) and float(ed.options["lo_wall"]) == 1.0 and bool(ed.options["lo_closed"]))
	ed.options["lo_thin"] = false
	await ed.apply_feature()
	var solid_again: bool = await wait_for(func() -> bool: return table.build.row(str(loft_row["id"])).get("thickness") == null)
	var back_volume := await total(ed)
	print("SMOKE ...turning the wall off by Edit (an explicit null, which the backend now honours) gives the solid back: ", solid_again and near(back_volume, solid_volume, 0.01), " ", back_volume)
	quit()
