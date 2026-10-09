extends RefCounted
## The translucent preview of a feature before Apply (Phase 5.5, DIDSA-CAD docs/live-preview-pattern.md), drawn as a child of the table's copy so
## it follows the part. Two sources, both just a Mesh here:
##   coarse   the body meshes JSON of a coarse-preview route (Pattern, Loft): nothing is stored on the backend (mesh_from_bodies)
##   eager    the part's own glb with the feature created and PATCHed as the settings change (every other feature): main.mesh_from_glb
## The part's own copy is NOT replaced while previewing, so the picks stay valid (the stable-pick-body pattern); Apply makes it real, Cancel
## deletes what was created. A preview over the triangle budget is not drawn (the user is told); the numbers are measured on a desktop, not a Quest.

const MAX_TRIANGLES := 150000 ## an extra translucent layer on top of the part: kept well inside what the headset draws per frame
const QUALITY := 0.3 ## the backend's mesh quality for a preview (the part itself is fetched at 0.5)
const GROW_MM := 0.25 ## in the part's own units (mm)
const TINT := Color(1.0, 0.62, 0.22, 0.42) ## the flat app's preview orange

var node: MeshInstance3D = null
var triangles := 0 ## of what is shown now
var skipped_over_budget := false ## the last mesh was too heavy to draw


static func within_budget(triangle_count: int) -> bool:
	return triangle_count <= MAX_TRIANGLES


static func triangle_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var n := 0
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices != null and (indices as PackedInt32Array).size() > 0:
			n += (indices as PackedInt32Array).size() / 3
		else:
			n += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


static func mesh_from_bodies(bodies: Array) -> ArrayMesh:
	## The coarse-preview response (a list of {body_id, source, mesh: {vertices, normals, triangle_indices, ...}}) as one mesh, a surface per body.
	## The backend's triangles are counter-clockwise from outside; Godot's front faces are clockwise, so each is flipped. null if there is nothing.
	var mesh := ArrayMesh.new()
	for body in bodies:
		var m: Dictionary = (body as Dictionary).get("mesh", {})
		var vertices := PackedVector3Array()
		for v in m.get("vertices", []):
			vertices.append(Vector3(float(v[0]), float(v[1]), float(v[2])))
		var normals := PackedVector3Array()
		for n in m.get("normals", []):
			normals.append(Vector3(float(n[0]), float(n[1]), float(n[2])))
		var indices := PackedInt32Array()
		for t in m.get("triangle_indices", []):
			indices.append_array([int(t[0]), int(t[2]), int(t[1])])
		if vertices.is_empty() or indices.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		if normals.size() == vertices.size():
			arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh if mesh.get_surface_count() > 0 else null


func show(parent: Node3D, mesh: Mesh) -> bool:
	## Draws `mesh` translucent on `parent`. false (and nothing drawn) for no mesh or one over the budget.
	skipped_over_budget = false
	if mesh == null or parent == null or not is_instance_valid(parent):
		clear()
		return false
	var count := triangle_count(mesh)
	if not within_budget(count):
		skipped_over_budget = true
		clear()
		return false
	if node == null or not is_instance_valid(node) or node.get_parent() != parent:
		clear()
		node = MeshInstance3D.new()
		node.name = "FeaturePreview"
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL # lit, so a rounded edge reads as rounded (a flat tint hid the shape)
		material.emission_enabled = true
		material.emission = Color(TINT.r, TINT.g, TINT.b) * 0.25
		material.albedo_color = TINT
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.render_priority = 2
		material.grow = true # the preview lies on the part's own surfaces: pushed out a hair along its normals so the two do not z-fight
		material.grow_amount = GROW_MM
		node.material_override = material
		parent.add_child(node)
	node.mesh = mesh
	triangles = count
	return true


func is_showing() -> bool:
	return node != null and is_instance_valid(node)


func clear() -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	node = null
	triangles = 0
