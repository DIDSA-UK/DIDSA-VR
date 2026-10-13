extends Node3D
## One open Assembly Room (docs/assembly-rooms-scope.md): a box of space (its RoomVolume, registered with room_registry.gd so the shader and the picking
## code know about it) holding one assembly's meshes, drawn with a thin wireframe for its walls. The node sits at the box's centre and orientation (no scale:
## walls are never scaled); the content hangs off `content_root`, which carries the room's own scale, millimetres to metres times the fit factor.
##
## A room is a world within the world (R2): once the manager has read its Part's state from the backend and called `set_interactive(true)`, its parts
## are `grabbable_parts` like the world's (grip, laser, nudge, rotate, hide, undo all work, filtered by the walls), a `TwoHandModel` on `content_root`
## moves, turns and scales the whole content when you grip empty space inside the room, and a moved part is saved to the room's own Part.
## Before that (and in tests that skip the backend) the parts are only in `room_parts`: visible and clipped, not touchable.

const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")

const WallShader := preload("res://shaders/room_walls.gdshader")
const RoomHandles := preload("res://scripts/room/room_handles.gd")
const GRID_MIN_CELL_M := 0.25 ## the grid's cell, on screen, is at least this wide (and under 2.5 times it: the 1-2-5 steps)

const FILL_FRACTION := 0.7 ## how much of the room the content fills when it opens (the table's "scales to fit" idea)
const COLOURS: Array[Color] = [Color(0.35, 0.85, 1.0), Color(1.0, 0.65, 0.25), Color(0.55, 0.95, 0.5), Color(0.95, 0.5, 0.9), Color(0.95, 0.9, 0.35), Color(0.6, 0.6, 1.0)]

var volume: RefCounted ## RoomVolume
var part_id := "" ## the Part this room holds as its root
var label := ""
var seed_owner_part_id := "" ## where the opened occurrence sits (its parent Part) and which occurrence it is: how the world's copy is found
var seed_occurrence_id := ""
var colour := Color.WHITE
var content_root: Node3D
var parts: Array[MeshInstance3D] = []
var content_scale: float: ## metres per backend unit (mm) at the room's current scale; 0.001 is 1:1. Whole-room gestures change it by scaling content_root.
	get:
		return content_root.scale.x if content_root != null else 0.001
var two_hand: Node ## the TwoHandModel moving / turning / scaling this room's content (room_manager.gd makes it); null until the room is interactive
var interactive := false
const MINI_SIZE_M := 0.4 ## a minimised room's longest side
const MINI_HOVER_M := 0.9 ## and how high its underside hovers (about waist height)

var minimised := false
var _restore := {} ## what a minimised room goes back to: its box, content pose and whether it was interactive
var members_changed := false ## parts were added to or deleted from this room's Part: the world's own copies of it are out of date until the world is reloaded

var glass := true ## the see-through walls with the soft edge glow and the grid near your hands; off = the thin wireframe only
var _walls: MeshInstance3D ## the thin wireframe (always drawn)
var _glass: MeshInstance3D ## the glass box (when `glass`)
var _glass_material: ShaderMaterial
var _grid_scale := -1.0 ## the content scale the grid step was last worked out for
var handles: Node3D ## room_handles.gd: the face handles and the move bar
var console: Node3D ## room_console.gd: this room's own controls (null until the manager makes it, and in tests with no headset nodes)
var _bounds := AABB() ## the content's bounds in content_root's own (mm) frame


static func colour_for(slot: int) -> Color:
	return COLOURS[posmod(slot, COLOURS.size())]


static func content_bounds(root: Node3D) -> AABB:
	## Union of every mesh's bounding box, in `root`'s own frame (works for nodes not in the tree: only local transforms are used).
	var result := AABB()
	var first := true
	for node in _descendants(root):
		if not (node is MeshInstance3D) or (node as MeshInstance3D).mesh == null:
			continue
		var to_root := Transform3D.IDENTITY
		var n: Node = node
		while n != null and n != root:
			to_root = (n as Node3D).transform * to_root
			n = n.get_parent()
		var box: AABB = to_root * (node as MeshInstance3D).get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


static func fit_scale(bounds: AABB, full_size: Vector3, fraction: float = FILL_FRACTION) -> float:
	## Metres per backend unit that makes `bounds` fill `fraction` of the room on its tightest axis. 0.001 (1:1) if there is nothing to fit.
	var s := INF
	for axis in 3:
		if bounds.size[axis] > 0.0001:
			s = minf(s, fraction * full_size[axis] / bounds.size[axis])
	return 0.001 if s == INF else s


func build(glb_bytes: PackedByteArray, box_xform: Transform3D, full_size: Vector3, p_part_id: String, p_label: String) -> bool:
	## Parses the part's assembly-mesh.glb into the room, scaled to fit. False if the bytes are not a readable glb.
	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	if gltf_document.append_from_buffer(glb_bytes, "", gltf_state) != OK:
		return false
	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		return false
	MeshIdentity.tag_scene(gltf_state, scene)
	part_id = p_part_id
	label = p_label
	volume = RoomVolume.make(box_xform, full_size)
	transform = Transform3D(box_xform.basis.orthonormalized(), box_xform.origin)
	content_root = Node3D.new()
	content_root.name = "Content"
	add_child(content_root)
	_adopt(scene)
	_bounds = content_bounds(content_root)
	set_content_scale(fit_scale(_bounds, full_size))
	return true


func reload(glb_bytes: PackedByteArray) -> bool:
	## Swaps the content for a fresh copy of the Part's mesh (after parts were added or deleted), keeping the room's scale and where the content sits. The
	## old parts go (anything holding one must let go first: room_manager.gd does); the new ones are tagged, under the clip, and touchable if the room is.
	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	if gltf_document.append_from_buffer(glb_bytes, "", gltf_state) != OK:
		return false
	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		return false
	MeshIdentity.tag_scene(gltf_state, scene)
	var was_interactive := interactive
	set_interactive(false) # takes the old parts out of the grab group and frees their colliders
	for old in content_root.get_children():
		content_root.remove_child(old)
		old.queue_free()
	parts.clear()
	_adopt(scene)
	if volume.slot >= 0:
		for p in parts:
			RoomClip.assign(p, volume.slot)
	if was_interactive:
		set_interactive(true)
	return true


func _adopt(scene: Node) -> void:
	## Puts a parsed scene under content_root and records its meshes as this room's parts.
	content_root.add_child(scene)
	for node in _descendants(scene) + [scene]:
		if node is MeshInstance3D:
			parts.append(node)
			node.add_to_group("room_parts")
			node.set_meta("room_id", get_instance_id())


func owner_part_ids() -> Dictionary:
	## The distinct non-empty owner Part ids of this room's meshes: the sub-assembly Part and every nested one (a node's owner is its immediate parent
	## Part). The world's copy of this sub-assembly is the world nodes owned by these.
	var ids := {}
	for p in parts:
		var o := str(p.get_meta("owner_part_id", ""))
		if o != "":
			ids[o] = true
	return ids


func set_content_scale(metres_per_unit: float) -> void:
	## The room's scale (a display transform on the content only): keeps the content's middle at the room's middle.
	var s := maxf(metres_per_unit, 0.000001)
	content_root.scale = Vector3.ONE * s
	content_root.position = -s * _bounds.get_center()


func scale_text() -> String:
	## "1:1" at real size, else "n:1" (bigger) or "1:n" (smaller), like the Scale page's presets.
	var ratio := content_scale / 0.001
	if absf(ratio - 1.0) < 0.005:
		return "1:1"
	return "%s:1" % _trim(ratio) if ratio > 1.0 else "1:%s" % _trim(1.0 / ratio)


func register(slot: int) -> void:
	## Called once the registry has accepted the volume: tags the parts with the slot, draws the walls.
	colour = colour_for(slot)
	for p in parts:
		RoomClip.assign(p, slot)
	_build_walls()


func set_interactive(on: bool) -> void:
	## Makes the parts touchable (grabbable_parts, with collision for the laser and the grip) or not. Idempotent.
	if on == interactive:
		return
	interactive = on
	for p in parts:
		if not is_instance_valid(p):
			continue
		if on:
			p.add_to_group("grabbable_parts")
			p.create_trimesh_collision() # so the laser and the grip can find real geometry, like main.gd does for the world's parts
		else:
			p.remove_from_group("grabbable_parts")
			for child in p.get_children():
				if child is StaticBody3D:
					p.remove_child(child)
					child.free()


func close() -> void:
	set_interactive(false)
	RoomRegistry.remove_room(volume)
	queue_free()


func _build_walls() -> void:
	_walls = wall_lines(volume.half, colour)
	add_child(_walls)
	_glass_material = ShaderMaterial.new()
	_glass_material.shader = WallShader
	_glass_material.set_shader_parameter("tint", colour)
	_glass = MeshInstance3D.new()
	_glass.name = "Glass"
	_glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glass.material_override = _glass_material
	add_child(_glass)
	apply_volume()
	set_glass(glass)
	handles = RoomHandles.new()
	handles.name = "Handles"
	add_child(handles)
	handles.setup(self)


func minimise() -> bool:
	## The whole room (walls and content, uniformly, about its middle) shrunk to a small glass cube hovering at waist height where it stood: a world in
	## miniature that takes no space and can be looked at. Nothing in it can be touched, its handles and console are put away. restore() brings it back exactly.
	if minimised:
		return false
	_restore = {"xform": volume.xform, "half": volume.half, "content": content_root.global_transform, "interactive": interactive}
	var factor := MINI_SIZE_M / (2.0 * maxf(volume.half.x, maxf(volume.half.y, volume.half.z)))
	var old_centre: Vector3 = volume.xform.origin
	var new_half: Vector3 = volume.half * factor
	var new_centre := Vector3(old_centre.x, MINI_HOVER_M + new_half.y, old_centre.z)
	var t: Transform3D = content_root.global_transform
	var content_after := Transform3D(t.basis * factor, new_centre + (t.origin - old_centre) * factor)
	set_interactive(false)
	volume.xform = Transform3D(volume.xform.basis, new_centre)
	volume.half = new_half
	transform = Transform3D(volume.xform.basis, volume.xform.origin)
	content_root.global_transform = content_after
	apply_volume()
	if handles != null:
		handles.set_enabled(false)
	if console != null:
		console.close()
	minimised = true
	RoomRegistry.push()
	return true


func restore() -> bool:
	## Back to the box, the content's pose and the touchability it had. False (and still minimised) if another room now occupies that space.
	if not minimised:
		return false
	var box := RoomVolume.make(_restore["xform"], (_restore["half"] as Vector3) * 2.0)
	if RoomRegistry.would_overlap(box, volume):
		return false
	volume.xform = _restore["xform"]
	volume.half = _restore["half"]
	transform = Transform3D(volume.xform.basis, volume.xform.origin)
	content_root.global_transform = _restore["content"]
	apply_volume()
	if handles != null:
		handles.set_enabled(true)
	if console != null:
		console.open()
	minimised = false
	set_interactive(bool(_restore["interactive"]))
	_restore = {}
	RoomRegistry.push()
	return true


func refit(metres_per_unit: float) -> void:
	## The scale set and the content centred in the room again, from the content's CURRENT bounds (parts may have been added, deleted or moved since it opened).
	_bounds = content_bounds(content_root)
	set_content_scale(metres_per_unit)


func set_box(new_xform: Transform3D, new_half: Vector3) -> void:
	## The box was reshaped (a wall dragged): the room's walls move, the CONTENT STAYS where it is in the world (it is not scaled or carried along).
	var content_world := content_root.global_transform
	volume.xform = new_xform
	volume.half = new_half
	transform = Transform3D(volume.xform.basis, volume.xform.origin)
	content_root.global_transform = content_world
	apply_volume()
	RoomRegistry.push()


func move_box(new_xform: Transform3D) -> void:
	## The whole room carried (the move bar): the box and its content go together.
	volume.xform = new_xform
	transform = Transform3D(volume.xform.basis, volume.xform.origin)
	RoomRegistry.push()


func apply_volume() -> void:
	## The walls follow the box (after the walls were dragged): the wireframe and the glass are rebuilt for the current half extents.
	if _walls == null:
		return
	var fresh := wall_lines(volume.half, colour)
	_walls.mesh = fresh.mesh
	fresh.free()
	var box := BoxMesh.new()
	box.size = volume.half * 2.0
	_glass.mesh = box
	_glass_material.set_shader_parameter("half_size", volume.half)
	_grid_scale = -1.0
	_update_grid()
	if handles != null:
		handles.refresh()


func set_glass(on: bool) -> void:
	glass = on
	if _glass != null:
		_glass.visible = on


static func grid_step_mm(metres_per_mm: float) -> float:
	## The grid's cell in the room's real-world millimetres: the smallest round step (1, 2, 5, 10, 20, 50... mm) whose cell on screen is at least 0.25 m, so
	## it stays between 0.25 and 0.625 m wide whatever the room's scale. (A 10:1 room is not 60 mm cells; that would be 0.6 m cells of real 60 mm.)
	var step := 0.001
	var k := -3
	while k <= 8:
		for m in [1.0, 2.0, 5.0]:
			step = m * pow(10.0, k)
			if step * metres_per_mm >= GRID_MIN_CELL_M:
				return step
		k += 1
	return step


func grid_text() -> String:
	## "grid 20 mm" for the console.
	var mm := grid_step_mm(content_scale)
	return "grid %s mm" % _trim(mm) if mm < 1000.0 else "grid %s m" % _trim(mm / 1000.0)


func _update_grid() -> void:
	if _glass_material == null:
		return
	var s := content_scale
	if is_equal_approx(s, _grid_scale):
		return
	_grid_scale = s
	_glass_material.set_shader_parameter("grid_step", grid_step_mm(s) * s)


func update_reveal(hand_positions: Array) -> void:
	## Each frame: the two hands (world positions), so the grid fades in near them; and the grid keeps its round step as the room's scale changes.
	if _glass_material == null:
		return
	_update_grid()
	var far := Vector3(1.0e6, 1.0e6, 1.0e6)
	var a: Vector3 = volume.to_local(hand_positions[0]) if hand_positions.size() > 0 else far
	var b: Vector3 = volume.to_local(hand_positions[1]) if hand_positions.size() > 1 else far
	_glass_material.set_shader_parameter("hand_a", a)
	_glass_material.set_shader_parameter("hand_b", b)


func set_active_faces(mask: int) -> void:
	## Lights the faces in the bit mask (bit 0..5: +x, -x, +y, -y, +z, -z) while a corner-drag holds them, 0 for none.
	if _glass_material != null:
		_glass_material.set_shader_parameter("active_faces", mask)


func set_active_face(face: int) -> void:
	## One face (0..5), -1 for none.
	set_active_faces(0 if face < 0 else 1 << face)


static func wall_lines(h: Vector3, line_colour: Color) -> MeshInstance3D:
	## The twelve edges of a box with half extents `h`, as a thin wireframe in `line_colour` (a room's walls for now; the placement ghost uses it too).
	var corners: Array[Vector3] = []
	for i in 8:
		corners.append(Vector3(h.x if i & 1 else -h.x, h.y if i & 2 else -h.y, h.z if i & 4 else -h.z))
	var edges := [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]
	var points := PackedVector3Array()
	for e in edges:
		points.append(corners[e[0]])
		points.append(corners[e[1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(line_colour.r, line_colour.g, line_colour.b, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, mat)
	var node := MeshInstance3D.new()
	node.name = "Walls"
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func _descendants(root: Node) -> Array:
	var out: Array = []
	for c in root.get_children():
		out.append(c)
		out.append_array(_descendants(c))
	return out


static func _trim(x: float) -> String:
	var s := "%.2f" % x
	while s.contains(".") and (s.ends_with("0") or s.ends_with(".")):
		s = s.left(s.length() - 1)
	return s
