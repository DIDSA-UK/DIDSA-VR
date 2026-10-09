extends SceneTree
## NEEDS A REAL RENDER (Xvfb) AND A RUNNING BACKEND: the translucent Fillet preview on a real part (Phase 5.5), and the Properties panel beside it.
##   PREVIEW_RENDER_DIR=/tmp/preview xvfb-run -a "$GODOT" --path . --script res://tests/preview_render.gd
## A 60 x 40 x 20 block, one edge picked with a 6 mm radius: the picked edge is lit, the rounded copy drawn translucent orange over the part, the panel
## showing Radius / Clear / Apply. Software (llvmpipe) render, not a headset view. Not in run_all.sh.

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")


func wait_for(pred: Callable, frames := 900) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func _initialize() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("res://secrets.cfg") != OK:
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend")
		quit()
		return
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	cam.position = Vector3(0, 1.6, 0)
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	main.backend_url = str(cfg.get_value("backend", "url"))
	main.api_key = str(cfg.get_value("backend", "api_key"))
	var table = main.design_table
	table.configure_backend(main.backend_url, main.api_key)
	table.surface.settle_seconds = 0.0
	var ed = table.editor
	await main.new_assembly()
	await table.new_part()
	await wait_for(func() -> bool: return ed.state == "pick_plane")
	await ed.begin_sketch({"fixed": "XY"})
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": Vector2(0, 0)})
	await ed.session.tap({"uv": Vector2(60, 40)})
	ed.options["depth"] = 20.0
	table.manager.activate("extrude")
	await wait_for(func() -> bool: return ed.preview.is_showing())
	await ed.apply_feature()
	await wait_for(func() -> bool: return not table.is_blank())
	table.manager.activate("fillet")
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	var eye_world: Vector3 = table.table_copy.global_transform * table.table_copy.get_aabb().get_center() + table.global_transform.basis * Vector3(0.22, 0.16, 0.26)
	var best_d := INF
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] != "line":
			continue
		var pts: PackedVector3Array = topo[body_id]["edges"][index]
		var mid_world: Vector3 = table.table_copy.global_transform * ((pts[0] + pts[pts.size() - 1]) * 0.5)
		if mid_world.distance_to(eye_world) < best_d:
			best_d = mid_world.distance_to(eye_world) # the line edge nearest the camera we will look from
			edge_index = int(index)
	ed.edges = [{"kind": "edge", "body_id": body_id, "index": edge_index, "key": "edge:%s:%d" % [body_id, edge_index]}]
	ed.highlight.set_set(table.table_copy, ed.edges)
	ed.options["radius"] = 8.0
	ed._update_options()
	ed.schedule_preview()
	var shown: bool = await wait_for(func() -> bool: return ed.preview.is_showing())
	for i in 20:
		await process_frame
	var dir := OS.get_environment("PREVIEW_RENDER_DIR")
	print("SMOKE the fillet preview is drawn on the real part (%d triangles): " % ed.preview.triangles, shown)
	if dir != "":
		var eye := Camera3D.new()
		eye.fov = 70.0
		main.add_child(eye)
		eye.make_current()
		eye.global_position = cam.global_position + Vector3(0.0, 0.0, 0.1)
		eye.look_at(table.global_position + Vector3(0.0, 0.12, 0.0))
		await create_timer(0.5).timeout
		root.get_texture().get_image().save_png(dir.path_join("fillet_preview_console.png"))
		var part_world: Vector3 = table.table_copy.global_transform * table.table_copy.get_aabb().get_center()
		eye.global_position = part_world + table.global_transform.basis * Vector3(0.22, 0.16, 0.26)
		eye.look_at(part_world)
		await create_timer(0.5).timeout
		root.get_texture().get_image().save_png(dir.path_join("fillet_preview_part.png"))
	quit()
