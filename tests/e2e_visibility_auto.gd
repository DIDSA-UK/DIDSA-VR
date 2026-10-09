extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the AUTO-HIDE lifecycle (plan step 5) on a real part. A sketch with a rectangle is extruded: the
## sketch hides itself and the Build row says "seed of Extrude 1"; Undo (the backend deletes the last feature) brings the sketch back; Redo makes the
## extrude again and hides it again; a sketch the user showed by hand is not hidden again by a reload.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_visibility_auto.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


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
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0), "id": ""})
	await ed.session.tap({"uv": Vector2(60, 40), "id": ""})
	var sketch_feature: String = ed.session.feature_id
	var b = table.build
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 12.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	await b.reload()
	var extrude_id: String = ed.feature_stack.back()
	print("SMOKE a confirmed extrude hides the sketch it consumed on a real part: ", b.is_hidden(sketch_feature) and b.auto_hidden.get(sketch_feature, []) == [extrude_id], " ", b.hidden_ids())
	print("SMOKE ...the real row names the sketch as its seed, and the tree says 'seed of Extrude 1': ", str(b.row(extrude_id).get("sketch_feature_id", "")) == sketch_feature and b.auto_note(sketch_feature) == "seed of Extrude 1")
	await ed.undo()
	await b.reload()
	print("SMOKE Undo deletes the real feature and the sketch comes back: ", b.features.size() == 1 and not b.is_hidden(sketch_feature) and b.auto_hidden.is_empty())
	await ed.redo()
	await b.reload()
	print("SMOKE Redo makes the extrude again and hides the sketch again: ", b.features.size() == 2 and b.is_hidden(sketch_feature))
	await b.toggle_hidden(sketch_feature)
	await b.reload()
	print("SMOKE a sketch the user showed by hand stays shown after a reload: ", not b.is_hidden(sketch_feature))
	quit()
