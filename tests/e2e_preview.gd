extends SceneTree
## Talks to a real backend, same caveat as the other e2e_*.gd tests (LOCAL ONLY): the PREVIEW before Apply (Phase 5.5) and REDO (5.6) against the
## real routes. A new part, a 60 x 40 rectangle: Extrude's preview creates the extrude as soon as the tool has a closed shape (the part is not
## changed yet), a depth change PATCHes it, Apply keeps that one feature; Fillet on an edge of the result previews a rounded copy (more triangles than
## the plain part) with the part's own mesh untouched, a radius change PATCHes the same feature, choosing another tool deletes it from the backend;
## Undo then Redo of the extrude puts the same solid back (new id).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_preview.gd  (needs secrets.cfg and a running backend, see tests/README.md)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func tri(m: Mesh) -> int:
	if m == null or m.get_surface_count() == 0:
		return 0
	var idx = m.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	return (idx as PackedInt32Array).size() / 3 if idx != null and (idx as PackedInt32Array).size() > 0 else (m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3


func features_on_backend(ed) -> Array:
	var r: Dictionary = await ed.features.list_features(ed.part_id)
	return r["features"]


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
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	var node: MeshInstance3D = table.seated
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(60, 40)})
	var before: Array = await features_on_backend(ed)

	# --- Extrude: the preview creates the feature, Apply keeps it
	ed.options["boss"] = true
	ed.options["depth"] = 20.0
	table.manager.activate("extrude")
	var previewed: bool = await wait_for(func() -> bool: return ed.preview.is_showing())
	var during: Array = await features_on_backend(ed)
	print("SMOKE with a closed shape Extrude's preview makes the feature on the backend at once and draws it translucent: ", previewed and during.size() == before.size() + 1 and ed.preview_feature_id != "" and ed.preview.triangles > 0, " ", before.size(), "->", during.size())
	print("SMOKE ...the part's own mesh is not changed yet (still the empty placeholder or blank): ", table.is_blank())
	var preview_id: String = ed.preview_feature_id
	ed.option_typed("depth", "12")
	await wait_for(func() -> bool: return not ed._preview_running, 600)
	var patched: Array = await features_on_backend(ed)
	var row := {}
	for f in patched:
		if str(f.get("id", "")) == preview_id:
			row = f
	print("SMOKE a depth change PATCHes that one feature on the backend (still one extrude, now 12 mm deep): ", patched.size() == during.size() and absf(float(row.get("end_distance", 0.0)) - float(row.get("start_distance", 0.0))) == 12.0, " ", row.get("end_distance"))
	await ed.apply_feature()
	var applied: bool = await wait_for(func() -> bool: return not table.is_blank())
	var after_apply: Array = await features_on_backend(ed)
	var solid := node.get_aabb().size
	print("SMOKE Apply keeps the preview's feature (no second extrude) and the part is the real 60 x 40 x 12 solid: ", applied and after_apply.size() == during.size() and ed.preview_feature_id == "" and not ed.preview.is_showing() and absf(solid.z - 12.0) < 0.5, " ", solid)
	var plain_tris: int = tri(node.mesh)

	# --- Fillet: a rounded translucent copy, the part untouched, deleted on another tool
	table.manager.activate("fillet")
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "line":
			edge_index = int(index)
			break
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	ed.options["radius"] = 3.0
	ed.schedule_preview()
	var rounded: bool = await wait_for(func() -> bool: return ed.preview.is_showing() and ed.preview_feature_id != "")
	print("SMOKE a picked edge previews the fillet: a translucent copy with more triangles than the plain part, the part's own mesh untouched: ", rounded and ed.preview.triangles > plain_tris and tri(table.table_copy.mesh) == plain_tris, " ", ed.preview.triangles, " vs ", plain_tris)
	var fillet_id: String = ed.preview_feature_id
	ed.option_typed("radius", "5")
	await wait_for(func() -> bool: return not ed._preview_running, 600)
	var with_fillet: Array = await features_on_backend(ed)
	var fillet_row := {}
	for f in with_fillet:
		if str(f.get("id", "")) == fillet_id:
			fillet_row = f
	print("SMOKE a radius change PATCHes that fillet (radius 5, no second fillet): ", float(fillet_row.get("radius", 0.0)) == 5.0 and with_fillet.size() == after_apply.size() + 1, " ", fillet_row.get("radius"))
	table.manager.activate("chamfer")
	await wait_for(func() -> bool: return ed.preview_feature_id == "" and not ed._preview_running, 600)
	await process_frame
	var gone: Array = await features_on_backend(ed)
	print("SMOKE choosing another tool deletes the unapplied fillet from the backend and the overlay goes: ", gone.size() == after_apply.size() and not ed.preview.is_showing(), " ", gone.size(), " ", after_apply.size())
	table.manager.deactivate()

	# --- Undo / Redo of the extrude (the last feature is the extrude again once the fillet is gone)
	await ed.undo()
	var undone: bool = await wait_for(func() -> bool: return table.is_blank())
	var after_undo: Array = await features_on_backend(ed)
	print("SMOKE Undo takes the extrude back (blank part again) and the backend has it no more: ", undone and after_undo.size() == after_apply.size() - 1)
	await ed.redo()
	var redone: bool = await wait_for(func() -> bool: return not table.is_blank())
	var after_redo: Array = await features_on_backend(ed)
	print("SMOKE Redo makes the same solid again, with a new id: ", redone and after_redo.size() == after_apply.size() and absf(node.get_aabb().size.z - 12.0) < 0.5 and str(ed.feature_stack.back()) != preview_id, " ", node.get_aabb().size)
	quit()
