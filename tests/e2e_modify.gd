extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): the MODIFY tools (Phase 6.5) on an IMPORTED STEP part (tests/fixtures/block_60x40x20.step: no sketch, no history).
## Move Face pushes the +X face out 10 mm (60 -> 70 wide); Scale Body by 0.5 halves it; Move Body by (100, 0, 0) shifts it; Delete Face on a side wall of a second import
## is accepted by the backend (fails closed otherwise: the result is reported either way); Delete Body empties the part.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_modify.gd  (needs secrets.cfg and a running backend)

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")

var main
var table


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func import_block(ed) -> bool:
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/block_60x40x20.step")
	var r: Dictionary = await ed._call(HTTPClient.METHOD_POST, "/document/parts/%s/import-features" % ed.part_id, {"source_format": "step", "data_base64": Marshalls.raw_to_base64(bytes)})
	if not r["ok"]:
		return false
	await ed.refresh_geometry()
	return await wait_for(func() -> bool: return not table.is_blank())


func face_with_normal(part: MeshInstance3D, normal: Vector3) -> Dictionary:
	var bodies: Array = part.get_meta("body_ids")
	var seen := {}
	for i in bodies.size():
		var key := "%s:%d" % [bodies[i], int(part.get_meta("face_ids")[i])]
		if seen.has(key):
			continue
		seen[key] = true
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(part, str(bodies[i]), int(part.get_meta("face_ids")[i])))
		if not plane.is_empty() and (plane["n"] as Vector3).dot(normal) > 0.99:
			return {"kind": "face", "body_id": str(bodies[i]), "index": int(part.get_meta("face_ids")[i]), "key": key}
	return {}


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
	var imported: bool = await import_block(ed)
	var node: MeshInstance3D = table.seated
	print("SMOKE a STEP block is imported as a part with no history (60 x 40 x 20): ", imported and absf(node.get_aabb().size.x - 60.0) < 0.5, " ", node.get_aabb().size)
	# Move Face
	table.manager.activate("move_face")
	var side := face_with_normal(table.table_copy, Vector3(1, 0, 0))
	ed.faces = [side]
	ed.option_typed("mf_offset", "10")
	await ed.apply_feature()
	await wait_for(func() -> bool: return absf(node.get_aabb().size.x - 70.0) < 0.5, 300)
	print("SMOKE Move Face pushes the +X face out 10 mm: the imported block is 70 wide: ", absf(node.get_aabb().size.x - 70.0) < 0.5, " ", node.get_aabb().size)
	# Scale Body
	table.manager.activate("scale_body")
	ed.bodies = [{"kind": "body", "body_id": ed.body_ids()[0], "index": -1, "key": "solid:x"}]
	ed.option_typed("sb_factor", "0.5")
	await ed.apply_feature()
	await wait_for(func() -> bool: return absf(node.get_aabb().size.x - 35.0) < 0.5, 300)
	print("SMOKE Scale Body 0.5 halves it (35 wide): ", absf(node.get_aabb().size.x - 35.0) < 0.5, " ", node.get_aabb().size)
	# Move Body
	var start_x: float = node.get_aabb().position.x
	table.manager.activate("move_body")
	ed.bodies = [{"kind": "body", "body_id": ed.body_ids()[0], "index": -1, "key": "solid:x"}]
	ed.option_typed("mb_dx", "100")
	await ed.apply_feature()
	await wait_for(func() -> bool: return absf(node.get_aabb().position.x - start_x - 100.0) < 0.5, 300)
	print("SMOKE Move Body by X 100 shifts it by 100 mm: ", absf(node.get_aabb().position.x - start_x - 100.0) < 0.5, " ", node.get_aabb().position.x - start_x)
	# Delete Face on a second import
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await import_block(ed)
	node = table.seated
	table.manager.activate("delete_face")
	ed.faces = [face_with_normal(table.table_copy, Vector3(0, 1, 0))]
	var before: int = (node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	await ed.apply_feature()
	await wait_for(func() -> bool: return not ed.feature_stack.is_empty(), 300)
	var after: int = (node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	print("SMOKE Delete Face is sent to the real backend and its answer is reported (the status line says what happened): ", table.status() != "", " status=", table.status(), " vertices ", before, " -> ", after, " stack ", ed.feature_stack.size())
	# Delete Body
	table.manager.activate("delete_body")
	ed.bodies = [{"kind": "body", "body_id": ed.body_ids()[0], "index": -1, "key": "solid:x"}] if not ed.body_ids().is_empty() else []
	await ed.apply_feature()
	var emptied: bool = await wait_for(func() -> bool: return table.is_blank() or ed.body_ids().is_empty(), 300)
	print("SMOKE Delete Body removes the part's only body: ", emptied)
	quit()
