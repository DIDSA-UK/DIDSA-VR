extends RefCounted
## What you see while choosing what to grip or select (group_index.gd levels): the dead zone as a faint sphere with soft edges where the grip latched,
## corner brackets on the bounding box of the candidate (the same shape as the room drop cue: "this is a group"), and the breadcrumb of levels
## ("Bolt < Bracket < Drive unit") floating above it. All are children of the scene (not of a part), rebuilt when the candidate changes.

const DropCue := preload("res://scripts/room/drop_cue.gd")
const GroupIndex := preload("res://scripts/group_index.gd")

const COLOUR := Color(0.35, 0.85, 1.0)

const SPHERE_SHADER := "shader_type spatial;
render_mode unshaded, blend_mix, cull_back, depth_draw_never;
uniform vec4 tint : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform float strength = 0.22;
void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	ALBEDO = tint.rgb;
	ALPHA = strength * smoothstep(0.0, 0.75, facing);
}
"

static var _shader: Shader


static func sphere(radius: float) -> MeshInstance3D:
	## The dead zone: a sphere of `radius` metres whose rim fades out.
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SPHERE_SHADER
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 24
	mesh.rings = 12
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mesh.surface_set_material(0, mat)
	var node := MeshInstance3D.new()
	node.name = "GroupDeadZone"
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


const REFUSED_COLOUR := Color(1.0, 0.7, 0.15) ## amber: a level a grip would be refused (V-1)


static func brackets(world_box: AABB, colour: Color = COLOUR) -> MeshInstance3D:
	## Corner brackets round a world-space box, drawn on top. `colour` amber (REFUSED_COLOUR) marks a level that can't be moved.
	var node := DropCue.build(world_box, colour)
	node.name = "GroupBrackets"
	return node


static func caption(text: String, world_pos: Vector3) -> Label3D:
	var l := Label3D.new()
	l.name = "GroupCaption"
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.fixed_size = false
	l.pixel_size = 0.0012
	l.font_size = 40
	l.outline_size = 12
	l.modulate = Color(0.9, 0.98, 1.0)
	l.outline_modulate = Color(0.02, 0.06, 0.1, 0.95)
	l.render_priority = 10
	l.position = world_pos
	return l


static func clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.queue_free()
