extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as tests/tablet_render.gd):
##   TABLET_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/topology_render.gd
## Draws the Measure highlights on tests/fixtures/topology_box_cylinder.glb from a viewer's eye and saves
## topology_hover_edge.png (yellow tube on the hovered edge), topology_picks.png (cyan edge tube + orange vertex
## ball) and topology_cylinder_rim.png (the circular edge), so the look can be eyeballed. Checks only that the
## highlights exist. GL-compatibility render, not the project's mobile renderer.
const TopologyPick := preload("res://scripts/topology_pick.gd")

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var r: XRController3D = main.get_node("XROrigin3D/RightController")
	main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	for i in 3:
		await process_frame
		await physics_frame
	var eye := Camera3D.new()
	eye.fov = 45.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.35, 1.45, 0.35)
	eye.look_at(Vector3(0.18, 1.04, -0.95), Vector3.UP)
	var dir := OS.get_environment("TABLET_RENDER_DIR")
	if dir == "":
		dir = "/tmp/lab"
	DirAccess.make_dir_recursive_absolute(dir)
	r.measure_tool_active = true
	main._measure_tool.set_active(true)
	var hand := Vector3(0.05, 1.05, 1.0)
	var aim := func(target: Vector3) -> void:
		r.global_transform = Transform3D(Basis.looking_at((target - hand).normalized(), Vector3.UP), hand)
	aim.call(Vector3(0.05, 1.098, -0.9))
	for i in 4:
		await process_frame
		await physics_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(dir.path_join("topology_hover_edge.png"))
	r._on_button_pressed("trigger_click")
	await process_frame
	aim.call(Vector3(0.098, 1.098, -0.9))
	for i in 3:
		await process_frame
		await physics_frame
	r._on_button_pressed("trigger_click")
	await process_frame
	aim.call(Vector3(0.05, 1.02, -0.9))
	for i in 4:
		await process_frame
		await physics_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(dir.path_join("topology_picks.png"))
	var ok: bool = main.face_highlight.pick_nodes().size() == 2
	print("SMOKE two picks (edge + corner) and a hovered face are drawn: ", ok and main.face_highlight.hover_node(r) != null)
	main._measure_tool.clear_picks()
	var cyl: Node3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_cyl":
			cyl = p
	var cyl_hand := Vector3(0.3, 1.05, 1.0)
	var target: Vector3 = cyl.global_transform * Vector3(0.0, 29.0, 100.0)
	r.global_transform = Transform3D(Basis.looking_at((target - cyl_hand).normalized(), Vector3.UP), cyl_hand)
	for i in 4:
		await process_frame
		await physics_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(dir.path_join("topology_cylinder_rim.png"))
	print("SMOKE the cylinder's rim is lit as an edge: ", str(main.face_highlight.hover_key(r)).begins_with("edge:body_cyl:"))
	quit()
