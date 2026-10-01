extends ColorRect
## The glass overlay for one panel: a full-size, click-through ColorRect carrying
## shaders/ui_glass.gdshader. Add it as the LAST child of the panel's root Control (not inside a
## container, which would resize it) and call refresh() whenever the theme or the effects switch
## changes. It hides itself when effects are off or the theme asks for none, so a switched-off
## effect costs nothing.

const SHADER := preload("res://shaders/ui_glass.gdshader")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")

var _material := ShaderMaterial.new()


func setup(tokens: Resource) -> void:
	name = "FxOverlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	color = Color.WHITE
	_material.shader = SHADER
	material = _material
	resized.connect(_update_size)
	refresh(tokens)


func refresh(tokens: Resource) -> void:
	var strong: bool = tokens.fx_glow_strength > 0.001 or tokens.fx_sheen_strength > 0.001
	visible = UiThemes.fx_enabled and strong
	_material.set_shader_parameter("radius", float(tokens.radius_panel))
	_material.set_shader_parameter("glow_color", tokens.fx_glow_colour)
	_material.set_shader_parameter("glow_width", tokens.fx_glow_width)
	_material.set_shader_parameter("glow_strength", tokens.fx_glow_strength)
	_material.set_shader_parameter("sheen_strength", tokens.fx_sheen_strength)
	_update_size()


func _update_size() -> void:
	_material.set_shader_parameter("rect_size", size)
