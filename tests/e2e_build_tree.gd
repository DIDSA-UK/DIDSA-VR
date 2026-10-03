extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY — never against a shared backend; it needs a backend
## with DIDSA-CAD's 2026-10-03 hidden_feature_ids / rollback_excluded_feature_ids on assembly-mesh.glb): the design table's BUILD tree
## end to end. A new part is given a sketch, an extrude and a fillet; the tree lists them; Edit changes the extrude's depth (the real
## mesh changes, Undo puts it back); Hide leaves the table's copy empty while the arena's part keeps its mesh; Roll back to the extrude
## shows the part without its fillet; Roll back to the sketch shows nothing; the hidden ids are written to a saved file; a cascade
## delete of the sketch takes the extrude and fillet with it.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_build_tree.gd
## Needs secrets.cfg to point at a running backend (a throwaway CAD_API_KEY, see docs/status.md "How this has been worked on").

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var api


func req(method: int, path: String, body = null) -> Dictionary:
	return await api.request(method, path, body)


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func face_total(mesh: Mesh) -> int:
	return mesh.get_faces().size() if mesh != null else 0


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
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

	# --- a part with a sketch, an extrude and a fillet
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0), "id": ""})
	await ed.session.tap({"uv": Vector2(60, 40), "id": ""})
	table.manager.activate("extrude")
	ed.options["boss"] = true
	ed.options["depth"] = 12.0
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	var body_id: String = (node.get_meta("topology") as Dictionary).keys()[0]
	var edge_index: int = ((node.get_meta("topology") as Dictionary)[body_id]["edges"] as Dictionary).keys()[0]
	var filleted: Dictionary = await ed.features.fillet(ed.part_id, [{"body_id": body_id, "shape_type": "edge", "index": edge_index}], 2.0)
	await ed.refresh_geometry()
	await wait_for(func() -> bool: return table.build.features.size() == 3)
	var b = table.build
	print("SMOKE the Build tree lists what built the part, in order: ", filleted["ok"] and b.features.map(func(f): return f["type"]) == ["sketch", "extrude", "fillet"] and b.names == ["Sketch 1", "Extrude 1", "Fillet 1"], " ", b.names)
	var rows: Array = table.tree._build_rows.get_children().filter(func(c): return c is Button and not c.text.begins_with("Body ")).map(func(c): return c.text)
	print("SMOKE ...and the window shows them with their numbers: ", rows.size() == 3 and rows[1].contains("Boss 12 mm") and rows[2].contains("R 2 mm"), " ", rows)
	var extrude_id: String = b.features[1]["id"]
	var sketch_id: String = b.features[0]["id"]
	var full_faces := face_total(node.mesh)

	# --- Edit the extrude's depth, then Undo
	b.select(extrude_id)
	print("SMOKE selecting the extrude lights up faces of its body: ", table.editor.highlight.set_nodes().size() > 0)
	await b.edit_typed(extrude_id, "20")
	var z_after: float = node.get_aabb().size.z
	print("SMOKE Edit changes the depth to 20 on the backend and the real mesh follows (the arena node too): ", absf(z_after - 20.0) < 0.5, " ", z_after)
	await ed.undo()
	await wait_for(func() -> bool: return absf(node.get_aabb().size.z - 12.0) < 0.5 and float(b.features[1]["end_distance"]) == 12.0)
	print("SMOKE Undo puts the 12 back (mesh and tree): ", absf(node.get_aabb().size.z - 12.0) < 0.5 and float(b.features[1]["end_distance"]) == 12.0)

	# --- Hide: the table's copy only
	b.select(extrude_id)
	await b.toggle_hidden_selected()
	print("SMOKE Hide leaves the table's copy empty (the backend left the body out) while the arena's part keeps its whole mesh: ", table.table_copy.layers == 0 and face_total(node.mesh) == full_faces and main.hidden_feature_ids() == [extrude_id])
	var saved_path: String = await main.save_native_snapshot("user://e2e_build_tree.didsa")
	var saved = JSON.parse_string(FileAccess.get_file_as_string(saved_path)) if saved_path != "" else null
	print("SMOKE the saved file carries the flat app's hidden_feature_ids with that id: ", saved is Dictionary and saved.get("hidden_feature_ids") == [extrude_id])
	if saved_path != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(saved_path))
	await b.toggle_hidden_selected()
	print("SMOKE Show brings the whole part back: ", table.table_copy.layers == 1 and face_total(table.table_copy.mesh) == full_faces)

	# --- Roll back
	b.select(extrude_id)
	await b.toggle_rollback_selected()
	var rolled_faces := face_total(table.table_copy.mesh)
	print("SMOKE Roll back to the extrude shows the part without its fillet (fewer faces on the table's copy, the arena's part unchanged): ", rolled_faces > 0 and rolled_faces < full_faces and face_total(node.mesh) == full_faces, " ", rolled_faces, " < ", full_faces)
	await b.roll_forward()
	b.select(sketch_id)
	await b.toggle_rollback_selected()
	print("SMOKE Roll back to the sketch shows nothing (a sketch alone is no geometry): ", table.table_copy.layers == 0)
	await b.roll_forward()
	print("SMOKE Roll forward brings it all back: ", table.table_copy.layers == 1 and face_total(table.table_copy.mesh) == full_faces)

	# --- Delete the sketch: the cascade takes the extrude and the fillet
	b.select(sketch_id)
	await b.delete_selected()
	await b.delete_selected()
	var emptied: bool = await wait_for(func() -> bool: return b.features.is_empty() and table.is_blank())
	var left: Dictionary = await req(HTTPClient.METHOD_GET, "/document/parts/%s/features" % ed.part_id)
	print("SMOKE Delete (two presses) cascades: the sketch, extrude and fillet are gone on the backend, and the new part is blank again: ", emptied and left["ok"] and (left["json"] as Array).is_empty() and node.get_meta("blank", false), " ", table.status())
	quit()
