extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the design table's VISIBILITY model (scripts/design_table/visibility.gd) on real feature rows.
## A part with two sketches lofted (the second on a created plane) and a third, free sketch. The real rows must give the seeds the fake backend
## assumed (the loft's sections), the load rule must hide the consumed sketches and the plane and keep the free sketch, the category buttons
## must edit hidden_feature_ids, the backend must accept sketch and plane ids in `hidden_feature_ids` (and leave the mesh as it was), and hiding
## the body must empty the table's copy.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_visibility.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const Vis := preload("res://scripts/design_table/visibility.gd")

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


func pick_section(ed, sketch_feature_id: String) -> void:
	## Loft with no sketch open: a pull on a line of the sketch makes it the next section.
	for c in ed.rest_sketches.candidates():
		if str(c["sketch_feature_id"]) == sketch_feature_id:
			ed._hover_face = c
			ed._pick_sketch()
			return


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
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")

	# sketch A on XY, a plane 30 up with sketch B on it, the loft of the two, then a free sketch C on XY
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
	table.manager.activate("loft")
	await wait_for(func() -> bool: return ed.rest_sketches != null and is_instance_valid(ed.rest_sketches) and ed.rest_sketches.candidates().size() >= 8)
	pick_section(ed, sketch_a)
	pick_section(ed, sketch_b)
	ed.options["boss"] = true
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	table.manager.deactivate()
	ed.set_state("pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	await rect(ed, Vector2(100, 100), Vector2(120, 120))
	var sketch_c: String = ed.session.feature_id
	ed.finish_sketch()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	main.visibility_ruled_parts.clear() # the rule meets the finished part as a load would
	await table.build.reload()
	var b = table.build
	var types: Array = b.features.map(func(f): return str(f.get("type", "")))
	print("INFO real feature types: ", types)

	var seeds := Vis.seed_sketch_ids(b.features)
	print("SMOKE the real loft row names its two section sketches as seeds, the free sketch is not one: ", seeds.has(sketch_a) and seeds.has(sketch_b) and not seeds.has(sketch_c) and seeds.size() == 2, " ", seeds)
	var hidden: Array = main.hidden_feature_ids()
	print("SMOKE the load rule hides the consumed sketches and the created plane and keeps the free sketch and the body shown: ", hidden.has(sketch_a) and hidden.has(sketch_b) and hidden.has(plane_id) and not hidden.has(sketch_c) and hidden.size() == 3, " ", hidden)
	var st: Dictionary = b.category_state(Vis.SKETCHES)
	print("SMOKE ...the Sketches category reads 1 of 3, Planes 0 of 1, Bodies all visible: ", st["label"] == "1 of 3" and b.category_state(Vis.PLANES)["label"] == "0 of 1" and b.category_state(Vis.BODIES)["state"] == "all", " ", st)

	var faces_before: int = table.table_copy.mesh.get_faces().size()
	var fetched: Dictionary = await table.api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5&hidden_feature_ids=%s&hidden_feature_ids=%s&hidden_feature_ids=%s" % [ed.part_id, sketch_a, sketch_b, plane_id])
	var parsed: Dictionary = main.mesh_from_glb(fetched["bytes"]) if fetched["ok"] else {"ok": false}
	print("SMOKE the backend accepts sketch and plane ids in hidden_feature_ids and returns the same solid: ", fetched["ok"] and parsed["ok"] and parsed["mesh"].get_faces().size() == faces_before, " ", faces_before)

	await b.toggle_category(Vis.SKETCHES)
	print("SMOKE the Sketches button on the mixed state shows all three and leaves the plane hidden: ", b.category_state(Vis.SKETCHES)["state"] == "all" and main.hidden_feature_ids() == [plane_id])
	await b.toggle_category(Vis.BODIES)
	var emptied: bool = await wait_for(func() -> bool: return table.table_copy.layers == 0)
	print("SMOKE the Bodies button hides the loft: the table's copy is empty, and the arena's real part keeps its mesh: ", emptied and b.category_state(Vis.BODIES)["state"] == "none")
	await b.toggle_category(Vis.BODIES)
	var back: bool = await wait_for(func() -> bool: return table.table_copy.layers == 1)
	print("SMOKE pressing it again shows the loft: ", back and b.category_state(Vis.BODIES)["state"] == "all" and table.table_copy.mesh.get_faces().size() == faces_before)

	await b.set_all_visible(false)
	print("SMOKE Hide all hides every feature of the part (sketches, planes and the body): ", b.category_state(Vis.SKETCHES)["state"] == "none" and b.category_state(Vis.PLANES)["state"] == "none" and b.category_state(Vis.BODIES)["state"] == "none", " ", main.hidden_feature_ids())
	var extras_keys: Array = main.native_extras_to_add({}).keys()
	# vr_stale_mates is the mates feature's own key (it was there before visibility): not a visibility key
	print("SMOKE ...and the file's only visibility key is hidden_feature_ids (no vr_ visibility keys): ", extras_keys.filter(func(k): return str(k).contains("hid") or str(k).contains("visib") or (str(k).begins_with("vr_") and str(k) != "vr_stale_mates")) == ["hidden_feature_ids"], " ", extras_keys)
	await b.set_all_visible(true)
	print("SMOKE Show all brings everything back: ", main.hidden_feature_ids().is_empty() and table.table_copy.layers == 1)
	quit()
