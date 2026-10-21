extends RefCounted
## An engineering dimension line for a rocket in the garden: a cyan line with arrowheads and end ticks beside the rocket (up its side, or along it for one that
## lies flat), its size written on it and its name above, drawn like a callout on a drawing. Built in the rocket's own frame (origin at the middle of its base,
## +Z towards the user). Sized by distance so it reads the same from 40 m as from 60 m. Unshaded and fog-free so the lines stay crisp across the haze.

const CYAN := Color(0.30, 0.88, 1.0)
const INK := Color(0.95, 0.98, 1.0)
const LINE_FRACTION := 0.0026 ## line thickness as a fraction of the distance (0.16 m at 60 m)
const TAG_HEIGHTS: Array[float] = [2.5, 6.5] ## where a vertical callout's tag sits (metres up), alternating by rocket so neighbours' tags never overlap


static func build(size: Vector3, distance: float, name_text: String, value_text: String, slot: int = 0) -> Node3D:
	## `size`: the rocket's bounding box (metres). Returns {node} with the labels named "Name" and "Value".
	var root := Node3D.new()
	root.name = "Callout"
	var t := distance * LINE_FRACTION
	var vertical := size.y >= maxf(size.x, size.z)
	var length := size.y if vertical else maxf(size.x, size.z)
	var material := _material(CYAN)
	var z := size.z * 0.5 + 1.0
	var tick := t * 9.0
	var arrow_len := t * 7.0
	var arrow_radius := t * 2.6
	var text_height := distance * 0.022 # a letter is about this tall (metres)
	var pixel := text_height / 64.0
	if vertical:
		var x := maxf(size.x, size.z) * 0.5 + 2.5 + tick
		root.add_child(_box(Vector3(t, maxf(length - 2.0 * arrow_len, t), t), Vector3(x, length * 0.5, z), material))
		for end in [0.0, length]:
			root.add_child(_box(Vector3(tick * 2.0, t, t), Vector3(x, end, z), material))
		root.add_child(_cone(arrow_radius, arrow_len, Vector3(x, length - arrow_len * 0.5, z), 0.0, material))
		root.add_child(_cone(arrow_radius, arrow_len, Vector3(x, arrow_len * 0.5, z), 180.0, material))
		# The tag (name and size) sits low on the line, where you can read it, rather than at the middle of a 100 m line, which is above the clouds.
		var tag_y := minf(length * 0.5, TAG_HEIGHTS[slot % TAG_HEIGHTS.size()])
		root.add_child(_label("Value", value_text, Vector3(x + tick * 2.0 + text_height * 0.4, tag_y, z), pixel * 1.1, CYAN, HORIZONTAL_ALIGNMENT_LEFT))
		root.add_child(_label("Name", name_text, Vector3(x + tick * 2.0 + text_height * 0.4, tag_y + text_height * 1.45, z), pixel * 1.3, INK, HORIZONTAL_ALIGNMENT_LEFT))
	else:
		var y := size.y + 2.5 + tick
		var half := length * 0.5
		root.add_child(_box(Vector3(maxf(length - 2.0 * arrow_len, t), t, t), Vector3(0.0, y, z), material))
		for end in [-half, half]:
			root.add_child(_box(Vector3(t, tick * 2.0, t), Vector3(end, y, z), material))
		root.add_child(_cone(arrow_radius, arrow_len, Vector3(half - arrow_len * 0.5, y, z), -90.0, material))
		root.add_child(_cone(arrow_radius, arrow_len, Vector3(-half + arrow_len * 0.5, y, z), 90.0, material))
		root.add_child(_label("Value", value_text, Vector3(0.0, y + text_height * 0.9, z), pixel * 1.1, CYAN, HORIZONTAL_ALIGNMENT_CENTER))
		root.add_child(_label("Name", name_text, Vector3(0.0, y + text_height * 2.5, z), pixel * 1.3, INK, HORIZONTAL_ALIGNMENT_CENTER))
	return root


static func _material(colour: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = colour
	m.disable_fog = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _box(size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func _cone(radius: float, length: float, at: Vector3, roll_degrees: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 10
	mesh.rings = 1
	mesh.material = material
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.rotation_degrees = Vector3(0.0, 0.0, roll_degrees)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


static func _label(node_name: String, text: String, at: Vector3, pixel_size: float, colour: Color, align: int) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.text = text
	label.font_size = 64
	label.pixel_size = pixel_size
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.shaded = false
	label.double_sided = true
	label.fixed_size = false
	label.no_depth_test = false
	label.modulate = colour
	label.outline_size = 10
	label.outline_modulate = Color(0.0, 0.02, 0.06, 0.95)
	label.horizontal_alignment = align
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	label.position = at
	return label
