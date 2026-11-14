extends SceneTree
## NEEDS A REAL RENDER (Xvfb, see tests/room_clip_render.gd). S4: the picture of the open model for the landing's Continue tile (room_thumbnail.gd render_model), drawn for real:
## a model of two coloured boxes comes out as an image of the thumbnail's size, its corners are the background and its middle is not, the colour of the part shows, the picture is kept by
## thumbnail_store.gd and loaded back, and a model with nothing visible gives none.
## Run: xvfb-run -a "$GODOT" --path . --script res://tests/thumbnail_render.gd

const RoomThumbnail := preload("res://scripts/room/room_thumbnail.gd")
const ThumbnailStore := preload("res://scripts/thumbnail_store.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _box(at: Vector3, colour: Color) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.4, 0.4, 0.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = colour
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material = mat
	m.mesh = box
	m.position = at
	return m


func _initialize() -> void:
	OS.set_environment(ThumbnailStore.DIR_ENV, "user://thumbnails_render_test")
	DirAccess.make_dir_recursive_absolute(ThumbnailStore.dir())
	ThumbnailStore.forget("/model/a.didsa")
	var thumbs := RoomThumbnail.new()
	root.add_child(thumbs)
	var assembly := Node3D.new()
	assembly.scale = Vector3.ONE * 0.5
	root.add_child(assembly)
	assembly.add_child(_box(Vector3(-0.3, 0, 0), Color(1, 0, 0)))
	assembly.add_child(_box(Vector3(0.3, 0, 0), Color(0, 0, 1)))
	await process_frame
	var image: Image = await thumbs.render_model(assembly)
	_check(image != null and image.get_width() == RoomThumbnail.SIZE_PX and image.get_height() == RoomThumbnail.SIZE_PX, "an open model is drawn as a picture of the thumbnail's size")
	if image == null:
		quit()
		return
	var corner := image.get_pixel(2, 2)
	var middle := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
	_check(corner.is_equal_approx(RoomThumbnail.BACKGROUND) or corner.get_luminance() < 0.2, "...its corner is the background")
	_check(not middle.is_equal_approx(corner), "...and the model is drawn in the middle")
	var seen_red := false
	var seen_blue := false
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			if c.r > 0.6 and c.g < 0.3 and c.b < 0.3:
				seen_red = true
			if c.b > 0.6 and c.r < 0.3 and c.g < 0.3:
				seen_blue = true
	_check(seen_red and seen_blue, "...both parts show in their own colour")
	_check(ThumbnailStore.save("/model/a.didsa", image) and ThumbnailStore.load_texture("/model/a.didsa", 96).get_width() == 96, "the picture is kept and comes back at the size the tile wants")
	assembly.visible = false
	var none: Image = await thumbs.render_model(assembly)
	_check(none == null, "a model with nothing visible gives no picture")
	ThumbnailStore.forget("/model/a.didsa")
	quit()
