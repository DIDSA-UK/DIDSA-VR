extends SceneTree
## NEEDS A REAL RENDER (Xvfb, see tests/room_clip_render.gd): the glass walls as pixels (shaders/room_walls.gdshader). A 3 m room seen straight on:
##   * the glass is mostly clear in the middle of a face and glows at its edges, so the room is always marked and never in the way;
##   * the grid is not there until a hand is near, and then shows on the face near it (and only there);
##   * with the glass switched off the faces are completely clear;
##   * a face being held by a wall-drag is lit.
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/room_walls_render.gd

const Room := preload("res://scripts/room/room.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")

var viewport: SubViewport


func px(x: float, y: float) -> Color:
	## The rendered colour at room-frame (x, y): the orthographic camera shows 4 m over 100 px (25 px per metre), the room centred.
	var img: Image = viewport.get_texture().get_image()
	return img.get_pixel(int(50.0 + x * 25.0), int(50.0 - y * 25.0))


func level(c: Color) -> float:
	return (c.r + c.g + c.b) / 3.0


func frames() -> void:
	for i in 4:
		await process_frame


func _initialize() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(100, 100)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	world_env.environment = env
	viewport.add_child(world_env)
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 0, 10)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4.0
	viewport.add_child(camera)

	var glb := RoomManagerTest.new().glb_for([{"pos": Vector3.ZERO, "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"}])
	var room := Room.new()
	room.build(glb, Transform3D(Basis.IDENTITY, Vector3.ZERO), Vector3(3, 3, 3), "S", "Sub")
	viewport.add_child(room)
	RoomRegistry.clear()
	room.register(RoomRegistry.add_room(room.volume))
	room.content_root.visible = false # only the walls are under test
	room.set_content_scale(0.001) # 1:1: a 500 mm grid
	room.update_reveal([]) # no hands near
	await frames()

	var centre := level(px(0.0, 0.0))
	var edge := 0.0
	for x in [1.44, 1.46, 1.48]:
		edge = maxf(edge, level(px(x, 0.2)))
	print("SMOKE the glass is clear in the middle of a face (barely tinted over the background): ", centre > 0.0 and centre < 0.18)
	print("SMOKE ...and glows at its edges, so the room is always marked: ", edge > centre + 0.12)
	var line_x := 0.5 # the 500 mm grid has a line 0.5 m from the middle
	var no_grid_line := maxf(level(px(line_x, 0.7)), level(px(line_x + 0.02, 0.7)))
	var no_grid_between := level(px(0.25, 0.7))

	# a hand near the front face: the grid shows near it
	room.update_reveal([Vector3(0.4, 0.5, 1.4)])
	await frames()
	var line_near := maxf(level(px(line_x, 0.7)), level(px(line_x + 0.02, 0.7)))
	var between_near := level(px(0.25, 0.7))
	print("SMOKE with no hand near there is no grid (a grid line is no brighter than between lines): ", absf(no_grid_line - no_grid_between) < 0.03)
	print("SMOKE a hand near a face brings the grid up on it (a line is clearly brighter than between lines): ", line_near > between_near + 0.06)
	var far_line := maxf(level(px(-1.0, -1.0)), level(px(-1.02, -1.0)))
	var far_between := level(px(-0.75, -1.0))
	print("SMOKE ...but only near the hand (the far side of the face stays clear): ", absf(far_line - far_between) < 0.04)

	# a face being held lights up
	room.update_reveal([])
	await frames()
	var before_held := level(px(0.0, 0.0))
	room.set_active_face(4) # +z, the face towards the camera
	await frames()
	print("SMOKE a face held by a wall-drag is lit: ", level(px(0.0, 0.0)) > before_held + 0.05)
	room.set_active_face(-1)

	# glass off: completely clear
	room.set_glass(false)
	await frames()
	print("SMOKE with the glass off the faces are completely clear (only the thin wireframe remains): ", level(px(0.0, 0.0)) < 0.01 and level(px(1.3, 0.0)) < 0.01)
	RoomRegistry.clear()
	quit()
