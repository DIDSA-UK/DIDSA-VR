extends SceneTree
## NEEDS A REAL RENDER (Xvfb), a layout smoke test and a picture for a human, in the real scene: an Assembly Room with its glass walls, handles, content and
## console (with its pedestal) seen from eye height. Checks the scene draws; $ROOM_RENDER_DIR gets room_scene.png.
##   ROOM_RENDER_DIR=/tmp/lab xvfb-run -a "$GODOT" --path . --script res://tests/room_scene_render.gd
## GL-compatibility render, not the project's mobile renderer: a layout look only.

const RoomManagerTest := preload("res://tests/room_manager.gd")


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var eye := Camera3D.new()
	eye.fov = 75.0
	main.add_child(eye)
	eye.make_current()
	eye.global_position = Vector3(0.9, 1.6, 2.2)
	eye.look_at(Vector3(0.0, 1.2, -2.5))
	origin.get_node("XRCamera3D").global_position = eye.global_position
	origin.get_node("XRCamera3D").global_rotation = eye.global_rotation
	for i in 3:
		await process_frame
	var glb := RoomManagerTest.new().glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(160, 100, 100), "owner": "S", "occ": "k1"},
		{"pos": Vector3(200, 60, 0), "size": Vector3(100, 220, 100), "owner": "S", "occ": "k2"},
	])
	var manager = main.room_manager
	var room = manager.open_from_bytes(glb, "S", "Gearbox", "", "", Transform3D(Basis.IDENTITY, Vector3(0.0, 1.5, -3.5)))
	manager.activate(room)
	origin.get_node("RightController").global_position = Vector3(0.6, 1.2, -2.2) # a hand near the front face: the grid shows there
	for i in 10:
		await process_frame
	var dir := OS.get_environment("ROOM_RENDER_DIR")
	var img := root.get_texture().get_image()
	if dir != "":
		img.save_png(dir.path_join("room_scene.png"))
	var lit := 0
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if img.get_pixel(x, y).get_luminance() > 0.04:
				lit += 1
	print("SMOKE the room, its content and its console draw into the 3D view: ", lit > 300 and room.console != null and room.console.is_open())
	quit()
