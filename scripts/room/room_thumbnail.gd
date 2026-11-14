extends Node
## A small picture of what an Assembly Room holds, for its tile on the tablet's Rooms page. The room's visible parts are copied
## (sharing their meshes, with the colour they had before the room's clip material wrapped them) into an off-screen SubViewport with
## its own world, light and camera, rendered once, read back into an ImageTexture, and the viewport is freed: nothing keeps
## rendering. Cached per room until its parts change (count, or the room reloads). Empty room or no renderer (headless): null, and
## the tile shows a placeholder instead.

const RoomClip := preload("res://scripts/room/room_clip.gd")
const Room := preload("res://scripts/room/room.gd")

const SIZE_PX := 192
const VIEW_DIRECTION := Vector3(1.0, 0.8, 1.2) ## the camera looks at the content from up here (front-right, above), like an isometric view
const FOV_DEGREES := 35.0
const BACKGROUND := Color(0.11, 0.13, 0.16)

var _cache: Dictionary = {} ## room instance id -> {key: String, texture: Texture2D}


static func cache_key(room: Node) -> String:
	## What the picture depends on: which parts, and the room's content having been rebuilt (a reload replaces every part node).
	var ids := PackedStringArray()
	for p in room.parts:
		if is_instance_valid(p) and p.visible:
			ids.append(str(p.get_instance_id()))
	return ",".join(ids)


func cached(room: Node) -> Texture2D:
	var entry: Dictionary = _cache.get(room.get_instance_id(), {})
	if entry.is_empty() or entry["key"] != cache_key(room):
		return null
	return entry["texture"]


func forget(room: Node) -> void:
	_cache.erase(room.get_instance_id())


static func build_copy(room) -> Node3D: # (a Room, or the small ModelParts holder below: anything with content_root and parts)
	## The room's visible parts, in its content's own (mm) frame, as plain mesh instances with their own colours. Null if there is nothing to show.
	var copy := Node3D.new()
	var inverse: Transform3D = room.content_root.global_transform.affine_inverse() if room.content_root.is_inside_tree() else Transform3D.IDENTITY
	for p in room.parts:
		if not is_instance_valid(p) or not p.visible or p.mesh == null:
			continue
		var m := MeshInstance3D.new()
		m.mesh = p.mesh
		var mat: Material = p.material_override
		if p.has_meta(RoomClip.WRAPPED) and mat == p.get_meta(RoomClip.WRAPPED):
			mat = p.get_meta(RoomClip.PRIOR, null) # the room's clip shader would cut the copy away in this other world: the colour under it
		m.material_override = mat
		m.transform = inverse * p.global_transform if p.is_inside_tree() else p.transform
		copy.add_child(m)
	if copy.get_child_count() == 0:
		copy.free()
		return null
	return copy


static func frame(bounds: AABB, fov_degrees: float = FOV_DEGREES) -> Transform3D:
	## Where the camera goes to see all of `bounds` from VIEW_DIRECTION.
	var radius := maxf(bounds.size.length() * 0.5, 0.001)
	var distance := radius / sin(deg_to_rad(fov_degrees) * 0.5) * 1.05
	var centre := bounds.get_center()
	var eye := centre + VIEW_DIRECTION.normalized() * distance
	return Transform3D(Basis.looking_at(centre - eye, Vector3.UP), eye)


func render(room: Node) -> Texture2D:
	## The room's picture (cached, or rendered now: takes a couple of frames). Null for an empty room, or where nothing renders.
	if not is_instance_valid(room) or room.content_root == null or DisplayServer.get_name() == "headless":
		return null # (headless draws nothing, so there would be no picture to read back)
	var hit := cached(room)
	if hit != null:
		return hit
	var key := cache_key(room)
	var image: Image = await render_copy(build_copy(room))
	if image == null:
		return null
	var texture := ImageTexture.create_from_image(image)
	if is_instance_valid(room):
		_cache[room.get_instance_id()] = {"key": key, "texture": texture}
	return texture


func render_model(content_root: Node3D) -> Image:
	## S4: a picture of the model that is open (everything visible under `content_root`, e.g. the assembly root), for the landing's Continue tile. Same view as a room's
	## tile. Null when there is nothing to show or nothing renders (headless).
	if content_root == null or not is_instance_valid(content_root) or DisplayServer.get_name() == "headless":
		return null
	var holder := ModelParts.new()
	holder.content_root = content_root
	for node in Room._descendants(content_root):
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null and (node as MeshInstance3D).is_visible_in_tree():
			holder.parts.append(node)
	return await render_copy(build_copy(holder))


class ModelParts:
	extends RefCounted
	var content_root: Node3D
	var parts: Array = []


func render_copy(copy: Node3D) -> Image:
	## Draws `copy` (from build_copy) once in an off-screen world and reads it back; the viewport is freed. Null when there is nothing to draw.
	if copy == null:
		return null
	var bounds := Room.content_bounds(copy)
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE_PX, SIZE_PX)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.msaa_3d = Viewport.MSAA_4X
	add_child(vp)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = BACKGROUND
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.57, 0.6)
	vp.add_child(env)
	var light := DirectionalLight3D.new()
	light.transform = Transform3D(Basis.looking_at(Vector3(-0.4, -1.0, -0.6), Vector3.UP), Vector3.ZERO)
	vp.add_child(light)
	vp.add_child(copy)
	var camera := Camera3D.new()
	camera.fov = FOV_DEGREES
	var radius := maxf(bounds.size.length() * 0.5, 0.001)
	camera.near = radius * 0.01
	camera.far = radius * 10.0
	camera.transform = frame(bounds)
	vp.add_child(camera)
	camera.current = true
	for i in 3:
		await get_tree().process_frame # UPDATE_ONCE draws it with the next frame
	var image: Image = vp.get_texture().get_image() if is_instance_valid(vp) and vp.get_texture() != null else null
	if is_instance_valid(vp):
		vp.queue_free()
	return image if image != null and not image.is_empty() else null
