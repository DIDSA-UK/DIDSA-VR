extends RefCounted
## The cue that a carried part will be ADDED to the room it is over when let go: corner brackets on its bounding box in that room's colour (the same shape
## as the resize brackets), drawn on top of everything so they show through the geometry. Built once per carried part, in the part's own frame, so it turns
## and scales with it. room_manager.gd shows it while the part's middle is inside a room that can take it, and takes it away again on release.

const NAME := "DropCue"
const ARM := 0.28 ## each bracket arm is this fraction of the box side


static func build(aabb: AABB, colour: Color) -> MeshInstance3D:
	var points := PackedVector3Array()
	var lo := aabb.position
	var hi := aabb.end
	for i in 8:
		var corner := Vector3(hi.x if i & 1 else lo.x, hi.y if i & 2 else lo.y, hi.z if i & 4 else lo.z)
		var toward := Vector3(lo.x if i & 1 else hi.x, lo.y if i & 2 else hi.y, lo.z if i & 4 else hi.z) - corner # the way back into the box
		points.append(corner)
		points.append(corner + Vector3(toward.x * ARM, 0.0, 0.0))
		points.append(corner)
		points.append(corner + Vector3(0.0, toward.y * ARM, 0.0))
		points.append(corner)
		points.append(corner + Vector3(0.0, 0.0, toward.z * ARM))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = Color(colour.r, colour.g, colour.b, 0.95)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_set_material(0, mat)
	var node := MeshInstance3D.new()
	node.name = NAME
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func show_on(part: MeshInstance3D, colour: Color) -> void:
	var cue := part.get_node_or_null(NAME) as MeshInstance3D
	if cue == null:
		cue = build(part.get_aabb(), colour)
		part.add_child(cue)
	else:
		(cue.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color = Color(colour.r, colour.g, colour.b, 0.95)
	cue.visible = true


static func hide_on(part: Node) -> void:
	var cue := part.get_node_or_null(NAME) if is_instance_valid(part) else null
	if cue != null:
		cue.visible = false
