extends MeshInstance3D
## The comfort vignette (shaders/comfort_vignette.gdshader): a full-screen quad in front of the camera whose edges darken with `strength`. Following the presenter or being gathered
## carries the view without the person's own movement, which is what makes some people ill; the edges close in while it happens and open again after. Off (strength 0) it draws nothing.
## Whether it is comfortable is the owner's to judge on a headset: only that it darkens the edges and not the centre is tested here (tests/session_vignette_render.gd).

const SHADER := preload("res://shaders/comfort_vignette.gdshader")

var strength := 0.0:
	set(value):
		strength = clampf(value, 0.0, 1.0)
		if _material != null:
			_material.set_shader_parameter("strength", strength)
		visible = strength > 0.001

var _material: ShaderMaterial


func _init() -> void:
	name = "ComfortVignette"
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	mesh = quad
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.render_priority = 127
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	extra_cull_margin = 16384.0 # (the vertex is moved onto the screen: the quad's own place must never cull it)
	visible = false
