extends Node3D
## Shared mechanism for a free-floating (not wrist-mounted), on-demand
## world-space UI panel: a Control tree in a SubViewport, rendered onto a
## quad, hit-tested by hand against the right hand's laser (no physics
## involved) - extracted from popup_keyboard.gd, which was the first thing
## in this repo built this way (wrist_tablet.gd predates it and still has
## its own copy of the same mechanism, wrist-mounted instead of free-
## floating; this base is deliberately NOT retrofitted onto either of those
## two proven, already-headset-tested files - see docs/status.md's
## "Floating windows" section for why).
##
## Subclasses override _build_content() to supply their own UI (a header
## with the panel's title and a close button are added automatically around
## whatever that returns), call setup() last from their own setup_xyz()
## once every field _build_content() might reference is already set, and
## can override _on_opened()/_on_closed() for any refresh-on-open behaviour.
##
## Multiple panels built on this base can be open at once. Each frame, a
## panel only claims the right controller's shared "ui_hover"/
## "ui_hit_distance" meta (the same convention wrist_tablet.gd/
## popup_keyboard.gd already use, and controller.gd already reads to know
## whether the trigger belongs to a UI panel instead of a part, and how far
## to shorten the laser) if nothing else has already claimed a NEARER hit
## that same frame - so whichever panel the laser is actually closest to
## wins, regardless of which panel's _process() happens to run first. This
## only works because controller.gd resets that meta to neutral at the very
## start of every frame, before any panel (wrist tablet, popup keyboard, or
## one of these) gets a chance to claim it - see controller.gd's own
## _process() docstring. The wrist tablet and popup keyboard predate this
## arbitration and always claim unconditionally when they're hovered - an
## accepted, documented gap (not fixed by touching either of those two
## already-proven, headset-tested files) that only matters if one of THEM
## geometrically overlaps a new panel in the same laser path, which the
## placement conventions each subclass uses (different open_distance/
## open_lateral_offset) are chosen to avoid in practice.

@export var panel_size := Vector2(0.26, 0.30) ## metres
@export var viewport_size := Vector2i(460, 560) ## pixels the UI is laid out in
@export var open_distance: float = 0.6 ## metres in front of the camera when opened
@export var open_lateral_offset: float = 0.0 ## metres, +right/-left of straight ahead - lets several windows spawn without stacking exactly on top of each other or the popup keyboard
@export var max_point_distance: float = 2.0 ## metres; laser reach
@export var click_action: String = "trigger_click"
@export var panel_title: String = "Window"

var _right: XRController3D
var _camera: XRCamera3D

var _viewport: SubViewport
var _quad: MeshInstance3D
var _cursor: Control
var _content_holder: Control

var _open := false
var _hovering := false
var _pointer_px := Vector2.ZERO
var _press_px := Vector2.ZERO ## frozen at trigger-down - see popup_keyboard.gd's _send_click() for the real-headset reason this matters
var _last_sent_px := Vector2(-1, -1)
var _pressed := false


func setup(right: XRController3D, camera: XRCamera3D) -> void:
	_right = right
	_camera = camera
	_build_viewport()
	_build_quad()
	_right.button_pressed.connect(_on_right_pressed)
	_right.button_released.connect(_on_right_released)
	visible = false


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_place_in_front_of_camera()
	_on_opened()


func close() -> void:
	_open = false
	visible = false
	_hovering = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _right:
		_right.set_meta("ui_hover", false)
		_right.set_meta("ui_hit_distance", -1.0) # _process() only runs while open - see popup_keyboard.gd's close() for why this needs doing explicitly too, not just left to next frame's reset
	_on_closed()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func _on_opened() -> void:
	pass # override in a subclass, e.g. to refresh data


func _on_closed() -> void:
	pass # override in a subclass


func _build_content() -> Control:
	return Control.new() # override in a subclass


func _place_in_front_of_camera() -> void:
	if _camera == null:
		return
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	# Yaw-only, same reasoning as popup_keyboard.gd's own _place_in_front_of_camera():
	# stays upright regardless of the camera's current pitch/roll.
	var right_axis := forward.cross(Vector3.UP).normalized()
	var target_position := _camera.global_position + forward * open_distance + right_axis * open_lateral_offset
	target_position.y = _camera.global_position.y - 0.1
	global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), target_position)


func _process(_delta: float) -> void:
	if not _open or _camera == null or _right == null:
		return
	_update_pointer()


func _update_pointer() -> void:
	var was_hovering := _hovering
	_hovering = false
	var normal := global_transform.basis.z.normalized()
	var origin := _right.global_position
	var dir := -_right.global_transform.basis.z.normalized()
	var geometrically_hit := false
	var hit_distance := -1.0
	var local_hit_px := Vector2.ZERO

	var hit = Plane(normal, global_position).intersects_ray(origin, dir)
	if hit != null and origin.distance_to(hit) <= max_point_distance:
		var local: Vector3 = global_transform.affine_inverse() * hit
		if absf(local.x) <= panel_size.x * 0.5 and absf(local.y) <= panel_size.y * 0.5:
			geometrically_hit = true
			hit_distance = origin.distance_to(hit)
			local_hit_px = Vector2(
				(local.x / panel_size.x + 0.5) * viewport_size.x,
				(0.5 - local.y / panel_size.y) * viewport_size.y
			)

	if geometrically_hit:
		var existing_hover: bool = _right.get_meta("ui_hover", false)
		var existing_distance: float = _right.get_meta("ui_hit_distance", -1.0)
		# Claim it only if nothing else already claimed a nearer hit this
		# frame - see this class's own top docstring for the full picture.
		if not existing_hover or existing_distance < 0.0 or hit_distance < existing_distance:
			_hovering = true
			if not _pressed:
				_pointer_px = local_hit_px
			_right.set_meta("ui_hover", true)
			_right.set_meta("ui_hit_distance", hit_distance)

	_cursor.visible = _hovering
	if _hovering:
		_cursor.position = _pointer_px - _cursor.size * 0.5
		if not _pressed and _pointer_px != _last_sent_px:
			var motion := InputEventMouseMotion.new()
			motion.position = _pointer_px
			motion.global_position = _pointer_px
			motion.relative = _pointer_px - (_last_sent_px if was_hovering else _pointer_px)
			_viewport.push_input(motion)
			_last_sent_px = _pointer_px
	elif was_hovering and _pressed:
		_send_click(false) # lost hover (laser moved off, or another panel won this frame): let go so nothing stays stuck down


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _hovering:
		_press_px = _pointer_px
		_send_click(true)
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and _pressed:
		_send_click(false)


func _send_click(down: bool) -> void:
	## Uses _press_px (frozen at press time), not the live _pointer_px, for
	## both down and up - see popup_keyboard.gd's own _send_click() for the
	## full real-headset reasoning this mirrors exactly.
	_pressed = down
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	click.position = _press_px
	click.global_position = _press_px
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	_viewport.push_input(click)


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while open
	add_child(_viewport)
	_viewport.add_child(_build_root_ui())


func _build_quad() -> void:
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = panel_size
	_quad.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	add_child(_quad)


func _build_root_ui() -> Control:
	var theme := Theme.new()
	theme.default_font_size = 26
	# Same pressed-state fix wrist_tablet.gd's own theme applies, for the
	# same real-headset reason (Godot's own default fallback doesn't read at
	# arm's length on an unshaded SubViewport quad) - see that file's
	# _build_ui() docstring.
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = Color(0.15, 0.55, 0.68)
	pressed_style.set_corner_radius_all(4)
	pressed_style.set_content_margin_all(6)
	theme.set_stylebox("pressed", "Button", pressed_style)
	theme.set_stylebox("hover_pressed", "Button", pressed_style)

	var root := Control.new()
	root.theme = theme
	root.size = Vector2(viewport_size)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.1, 0.13)
	bg.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", bg)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	var title := Label.new()
	title.text = panel_title
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.text = "X"
	close_button.pressed.connect(close)
	header.add_child(close_button)

	_content_holder = VBoxContainer.new()
	_content_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_content_holder)
	_content_holder.add_child(_build_content())

	# A soft glow where the laser terminates - same convention as
	# wrist_tablet.gd/popup_keyboard.gd's own cursor, for the same real-
	# headset reason (see either's docstring).
	_cursor = Control.new()
	_cursor.size = Vector2(28, 28)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.draw.connect(func() -> void:
		var centre: Vector2 = _cursor.size * 0.5
		for i in range(6, 0, -1):
			_cursor.draw_circle(centre, float(i) * 2.0, Color(1.0, 0.85, 0.1, 0.06))
		_cursor.draw_circle(centre, 5.0, Color(1.0, 0.95, 0.7, 0.9))
	)
	root.add_child(_cursor)

	return root
