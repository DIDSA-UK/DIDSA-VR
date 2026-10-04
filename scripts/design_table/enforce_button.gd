extends Node3D
## The "Enforce mates" button that appears where a part with dirty mates (dirty_mates.gd) is put down — or handed back to the arena
## when the table closes. It floats just above that part and always faces you, a small panel in the shared UI theme with the same
## laser handling as every other floating panel (laser_surface.gd), so a trigger on it never also selects a part.
## One button, for the whole assembly: pressing it asks the design table to re-solve the mates (mates_tool.gd's enforce_all) and the
## flags are cleared only if every mate could be satisfied. It follows the part it was shown for, goes while that part is carried,
## and tells you in a line under the button what came of the last try.

signal pressed_enforce

const LaserSurface := preload("res://scripts/ui/laser_surface.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const FxOverlay := preload("res://scripts/ui/fx_overlay.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"

@export var panel_size := Vector2(0.20, 0.09) ## metres
@export var pixels_per_metre: float = 2667.0
@export var lift := 0.13 ## metres above the top of the part
@export var max_point_distance: float = 3.0

var tokens: Resource
var surface ## LaserSurface
var target: Node3D = null ## the part it was shown for

var _camera: XRCamera3D
var _right: XRController3D
var _viewport: SubViewport
var _button: Button
var _message: Label
var _fx: ColorRect
var _busy := false
var _showing := false ## shown for a part; `visible` is also false while that part is in a hand
var _root: Control
var _seen_revision := -1


func setup(right: XRController3D, camera: XRCamera3D) -> void:
	_right = right
	_camera = camera
	tokens = load(THEME_PATH)
	_seen_revision = UiThemes.revision
	var px := Vector2i((panel_size * pixels_per_metre).round())
	_viewport = SubViewport.new()
	_viewport.size = px
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	var root := Control.new()
	_root = root
	root.size = Vector2(px)
	root.theme = tokens.build_theme()
	_viewport.add_child(root)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap)
	panel.add_child(column)
	_button = Button.new()
	_button.text = "Enforce mates"
	_button.icon = UiIcons.texture("enforce", 32)
	_button.theme_type_variation = &"ButtonAccent"
	_button.custom_minimum_size = Vector2(0, 72)
	_button.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_button.pressed.connect(func() -> void:
		if _busy:
			return
		UiFeedback.haptic(_right, "press")
		pressed_enforce.emit())
	column.add_child(_button)
	_message = Label.new()
	_message.theme_type_variation = &"LabelSmall"
	_message.text = "This part changed: its mates need redoing."
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_message)
	_fx = FxOverlay.new()
	root.add_child(_fx)
	_fx.setup(tokens)
	var cursor := LaserSurface.make_cursor()
	root.add_child(cursor)

	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = panel_size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	quad.mesh = mesh
	add_child(quad)

	surface = LaserSurface.new()
	surface.setup(self, _viewport, _right, panel_size)
	surface.claim_first = true
	surface.max_point_distance = max_point_distance
	surface.cursor = cursor
	visible = false


func show_for(part: Node3D) -> void:
	## Show the button over this part.
	target = part
	_showing = true
	_busy = false
	_button.disabled = false
	_button.text = "Enforce mates"
	_message.text = "This part changed: its mates need redoing."
	visible = true
	surface.arm()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_follow()


func hide_button() -> void:
	target = null
	_showing = false
	visible = false
	if surface:
		surface.release_all()
	if _viewport:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func hide_after(seconds: float) -> void:
	## Stays up with its message for a few seconds, then goes (unless it was shown for another part meanwhile).
	var shown_for := target
	await get_tree().create_timer(seconds).timeout
	if _showing and target == shown_for:
		hide_button()


func is_showing() -> bool:
	return _showing and target != null


func set_busy(on: bool) -> void:
	_busy = on
	_button.disabled = on
	if on:
		_message.text = "Re-solving the mates..."


func set_message(text: String) -> void:
	_message.text = text


func offer(button_text: String, message_text: String) -> void:
	## Turns the button into a second step (e.g. "Remake 2 mates") with a line saying what it will do; shown again for the same part.
	_button.text = button_text
	_message.text = message_text
	_button.disabled = false
	_busy = false
	visible = true


func reset_label() -> void:
	_button.text = "Enforce mates"


func message() -> String:
	return _message.text


func button() -> Button:
	return _button


func _follow() -> void:
	## Just above the part's bounds, facing you.
	if target == null or not is_instance_valid(target) or not (target is MeshInstance3D):
		return
	var part := target as MeshInstance3D
	var top := part.global_transform * part.get_aabb().get_center()
	var half_height := part.get_aabb().size.length() * 0.5 * part.global_transform.basis.get_scale().x
	var pos := top + Vector3(0.0, half_height + lift, 0.0)
	var away := pos - _camera.global_position
	away.y = 0.0
	if away.length() < 0.001:
		away = Vector3.FORWARD
	global_transform = Transform3D(Basis.looking_at(away.normalized(), Vector3.UP), pos) # +Z towards you


func _process(delta: float) -> void:
	if _seen_revision != UiThemes.revision:
		_seen_revision = UiThemes.revision
		_root.theme = tokens.build_theme()
		_fx.refresh(tokens)
	if not _showing:
		return
	if target == null or not is_instance_valid(target):
		hide_button()
		return
	if bool(target.get_meta("held", false)) or not target.visible:
		visible = false # parked while the part is in a hand (or hidden on the table)
		surface.release_all()
		return
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_follow()
	surface.process(delta, true)
