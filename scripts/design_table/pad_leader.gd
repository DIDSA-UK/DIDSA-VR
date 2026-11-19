extends MeshInstance3D
## B2 (docs/parity-followups-investigation.md, owner decision 2): a dropped dimension's number pad opens at its dock (V-8: one place for every typed value, never over the
## sketch), and this line runs from the pad to the dimension's frozen label on the sheet, with that label lit, so "which one am I typing" is answered at a glance.
##
## It owns nothing: it is told two places (callables returning a world point, or null while there is none) and a test for "the pad is up on a dropped dimension"
## (`active_fn`), and draws between the places while that holds, so the line goes by itself when the pad closes (typed, cancelled, B). The label is lit while the
## line is up (`light_label`). Unshaded, drawn over everything like the selection drawer's leader line.

const LINE_COLOUR := Color(1.0, 0.86, 0.35, 0.9)

var active_fn := Callable() ## () -> bool: a dropped dimension's pad is up
var light_label := Callable() ## (on: bool) -> void: lights / un-lights the frozen label
var from_point := Callable() ## () -> Variant: the pad's anchor in the world (a Vector3), or null
var to_point := Callable() ## () -> Variant: the frozen label's centre in the world (a Vector3), or null
var drawn := false ## the line is on show (a test reads it)
var drawn_from := Vector3.ZERO
var drawn_to := Vector3.ZERO
var _mesh := ImmediateMesh.new()


func _ready() -> void:
	top_level = true # the points are world points: the console's moves and scale do not carry the line
	mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = LINE_COLOUR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 6
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


func _process(_delta: float) -> void:
	update_line()


func update_line() -> void:
	## Redraws for this frame (also called by tests, which have no frames to wait on).
	var active: bool = active_fn.is_valid() and bool(active_fn.call())
	var a: Variant = from_point.call() if active and from_point.is_valid() else null
	var b: Variant = to_point.call() if active and to_point.is_valid() else null
	if a == null or b == null or not (a is Vector3) or not (b is Vector3):
		if drawn:
			_mesh.clear_surfaces()
			drawn = false
			visible = false
			if light_label.is_valid():
				light_label.call(false)
		return
	if light_label.is_valid():
		light_label.call(true)
	drawn_from = a
	drawn_to = b
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	_mesh.surface_add_vertex(a)
	_mesh.surface_add_vertex(b)
	_mesh.surface_end()
	drawn = true
	visible = true
