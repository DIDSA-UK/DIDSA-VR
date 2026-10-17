extends SceneTree
## NEEDS A REAL RENDER (Xvfb, see tests/room_clip_render.gd): a real Room (scripts/room/room.gd) built from a glb in the backend's shape, with the world
## around it, as pixels. The room's content is drawn inside its walls and scaled to fit; the world's slab is cut away where it passes through the room
## and drawn outside it; closing the room gives the world its slab back whole. (The clip itself is tests/room_clip_render.gd; this is the room built on it.)
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/room_render.gd

const Room := preload("res://scripts/room/room.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")
const RoomThumbnail := preload("res://scripts/room/room_thumbnail.gd")

var viewport: SubViewport


func px(x: float, y: float) -> Color:
	var img: Image = viewport.get_texture().get_image()
	return img.get_pixel(int(50.0 + x * 10.0), int(50.0 - y * 10.0))


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
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	world_env.environment = env
	viewport.add_child(world_env)
	var camera := Camera3D.new()
	camera.current = true
	camera.position = Vector3(0, 0, 10)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	viewport.add_child(camera)
	var light := DirectionalLight3D.new()
	light.light_energy = 3.0
	light.rotation_degrees = Vector3(-40, -30, 0)
	viewport.add_child(light)

	# the world: a wide slab at height 1.3 m, straight through the room's upper part (the room's top is at 1.5 m)
	var slab := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(8, 0.5, 0.1)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 1, 1)
	box.material = mat
	slab.mesh = box
	slab.position = Vector3(0, 1.3, 0)
	slab.add_to_group("grabbable_parts")
	viewport.add_child(slab)
	await frames()
	var test_helper := RoomManagerTest.new()
	print("SMOKE calibration, no room: the slab is lit across its width: ", px(-3, 1.3).r > 0.3 and px(0, 1.3).r > 0.3 and px(3, 1.3).r > 0.3)

	# the room: a 3 m cube at the origin holding two 100 mm cubes 400 mm apart, fitted to the room
	var glb: PackedByteArray = test_helper.glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "o1"},
		{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "o2"},
	])
	var room := Room.new()
	var size := Vector3(3, 3, 3)
	print("SMOKE the room builds from the glb: ", room.build(glb, Transform3D(Basis.IDENTITY, Vector3.ZERO), size, "S", "Sub"))
	var slot := RoomRegistry.add_room(room.volume)
	viewport.add_child(room)
	room.register(slot)
	var parts: Array = [slab]
	parts.append_array(room.parts)
	RoomClip.reconcile(parts)
	await frames()
	# fitted: 500 mm of content across 70% of 3 m = 2.1 m; each cube is 0.42 m, centres at x = -0.84 and +0.84
	print("SMOKE the room's content is drawn inside its walls (both cubes lit): ", px(-0.84, 0).r > 0.3 and px(0.84, 0).r > 0.3)
	print("SMOKE ...scaled up to fill the room (not left at 100 mm real size): ", px(-0.95, 0.0).r > 0.3 and px(0.95, 0.0).r > 0.3 and px(0.0, 0.0).r < 0.1)
	print("SMOKE the world's slab is cut away where it passes through the room: ", px(0, 1.3).r < 0.1 and px(1.2, 1.3).r < 0.1 and px(-1.2, 1.3).r < 0.1)
	print("SMOKE ...and still drawn outside the room's walls: ", px(-3, 1.3).r > 0.3 and px(3, 1.3).r > 0.3)
	var wall_seen := false
	for x in [1.35, 1.4, 1.45, 1.5, 1.55]: # the 1 px wall line lands on one of these pixel columns
		wall_seen = wall_seen or (px(x, 0.0).g > 0.5 and px(x, 0.0).r < 0.6)
	print("SMOKE the walls are drawn (the room's cyan wireframe shows at its edge): ", wall_seen)

	# the Rooms page's picture of this room (room_thumbnail.gd): rendered off-screen in its own world, without the room's clip
	var thumbs := RoomThumbnail.new()
	root.add_child(thumbs)
	var tex: Texture2D = await thumbs.render(room)
	var img: Image = tex.get_image() if tex != null else null
	var lit := 0
	if img != null:
		for y in range(0, img.get_height(), 4):
			for x in range(0, img.get_width(), 4):
				if img.get_pixel(x, y).r > RoomThumbnail.BACKGROUND.r + 0.15:
					lit += 1
	print("SMOKE the room's thumbnail renders its two parts over the background: ", img != null and img.get_size() == Vector2i(RoomThumbnail.SIZE_PX, RoomThumbnail.SIZE_PX) and lit > 40 and absf(img.get_pixel(1, 1).r - RoomThumbnail.BACKGROUND.r) < 0.02 and absf(img.get_pixel(1, 1).b - RoomThumbnail.BACKGROUND.b) < 0.02)
	print("SMOKE ...and is cached until the room's parts change: ", thumbs.cached(room) == tex and thumbs.get_children().all(func(c): return c.is_queued_for_deletion()))
	thumbs.queue_free()

	room.close()
	await frames()
	RoomClip.reconcile(parts) # (the closed room's freed parts are still in the list: reconcile skips them)
	await frames()
	print("SMOKE closing the room: the slab is whole again and the content is gone: ", px(0, 1.3).r > 0.3 and px(-0.84, 0).r < 0.1 and RoomRegistry.room_count() == 0 and slab.material_override == null)
	quit()
