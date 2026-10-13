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

var _walls: MeshInstance3D
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
	content_root.add_child(scene)
	for node in _descendants(scene) + [scene]:
		if node is MeshInstance3D:
			parts.append(node)
			node.add_to_group("room_parts")
			node.set_meta("room_id", get_instance_id())
	_bounds = content_bounds(content_root)
	set_content_scale(fit_scale(_bounds, full_size))
	return true


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
	var h: Vector3 = volume.half
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
	mat.albedo_color = Color(colour.r, colour.g, colour.b, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, mat)
	_walls = MeshInstance3D.new()
	_walls.name = "Walls"
	_walls.mesh = mesh
	_walls.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_walls)


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
