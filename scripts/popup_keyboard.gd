extends Node3D
## The popup keyboard from the vision brief: "A popup keyboard opens on a
## click of the right thumbstick, everywhere, for any text entry." Reserved
## since milestone 1's wrist tablet was built (`primary_click` was left
## deliberately unused there). This first real use is a numeric keypad for
## typing an exact scale multiple (wired up by main.gd): press the right
## thumbstick to open it pre-filled with the model's current scale, type a
## new number, OK to apply it (goes through two_hand_model.gd's set_preset(),
## so it's undoable like any other scale change), Cancel/thumbstick-click-
## again to back out.
##
## Same mechanism as wrist_tablet.gd: a Control UI in a SubViewport on a
## quad, hit-tested by hand against the right hand's laser (no physics), with
## mouse events pushed into the SubViewport. It isn't wrist-mounted — it pops
## up in front of wherever you're looking, since the brief says "everywhere",
## not tied to one tool or tab.

@export var panel_size := Vector2(0.22, 0.26) ## metres
@export var viewport_size := Vector2i(420, 520) ## pixels the UI is laid out in
@export var open_distance: float = 0.6 ## metres in front of the camera when opened
@export var max_point_distance: float = 2.0 ## metres; laser reach for pressing keys
@export var click_action: String = "trigger_click"

var _right: XRController3D
var _camera: XRCamera3D

var _viewport: SubViewport
var _quad: MeshInstance3D
var _cursor: Control
var _display: Label

var _open := false
var _text := ""
var _pristine := false ## true until the first keystroke: that keystroke clears the pre-filled value instead of appending to it
var _on_confirm: Callable = Callable()
var _hovering := false
var _pointer_px := Vector2.ZERO
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


func open_for(initial_text: String, on_confirm: Callable) -> void:
	## initial_text pre-fills the display (e.g. the model's current scale);
	## on_confirm(text: String) is called once, with whatever was typed, when
	## OK is pressed — it decides how to parse/apply it (and can reject it by
	## just doing nothing).
	_text = initial_text
	_pristine = true
	_on_confirm = on_confirm
	_update_display()
	_place_in_front_of_camera()
	_open = true
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func close() -> void:
	_open = false
	visible = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_right.set_meta("ui_hover", false)


func _place_in_front_of_camera() -> void:
	if _camera == null:
		return
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	# Yaw-only: ignores camera pitch/roll so the keyboard stays upright and
	# doesn't tilt away from you if you happen to be looking up or down when
	# you click the thumbstick. Its local -Z is set to `forward` (the
	# direction you're facing) so local +Z — the quad's textured front face —
	# points back at the camera, the same convention wrist_tablet.gd's "quad
	# faces +Z" comment describes, just built with looking_at() instead of a
	# fixed mount rotation since this panel can appear anywhere.
	var target_position := _camera.global_position + forward * open_distance
	target_position.y = _camera.global_position.y - 0.1
	global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), target_position)


func _process(_delta: float) -> void:
	if not _open or _camera == null:
		return
	_update_pointer()


func _update_pointer() -> void:
	var was_hovering := _hovering
	_hovering = false
	var normal := global_transform.basis.z.normalized()
	var origin := _right.global_position
	var dir := -_right.global_transform.basis.z.normalized()
	var hit = Plane(normal, global_position).intersects_ray(origin, dir)
	if hit != null and origin.distance_to(hit) <= max_point_distance:
		var local: Vector3 = global_transform.affine_inverse() * hit
		if absf(local.x) <= panel_size.x * 0.5 and absf(local.y) <= panel_size.y * 0.5:
			_hovering = true
			_pointer_px = Vector2(
				(local.x / panel_size.x + 0.5) * viewport_size.x,
				(0.5 - local.y / panel_size.y) * viewport_size.y
			)

	_right.set_meta("ui_hover", _hovering)
	_cursor.visible = _hovering
	if _hovering:
		_cursor.position = _pointer_px - _cursor.size * 0.5
		if _pointer_px != _last_sent_px:
			var motion := InputEventMouseMotion.new()
			motion.position = _pointer_px
			motion.global_position = _pointer_px
			motion.relative = _pointer_px - (_last_sent_px if was_hovering else _pointer_px)
			_viewport.push_input(motion)
			_last_sent_px = _pointer_px
	elif was_hovering and _pressed:
		_send_click(false) # laser slid off mid-press: let go so nothing stays stuck down


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _hovering:
		_send_click(true)
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and _pressed:
		_send_click(false)


func _send_click(down: bool) -> void:
	_pressed = down
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	click.position = _pointer_px
	click.global_position = _pointer_px
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	_viewport.push_input(click)


func _key_pressed(key: String) -> void:
	if key == "OK":
		close()
		if _on_confirm.is_valid():
			_on_confirm.call(_text)
		return
	if key == "Cancel":
		close()
		return
	if _pristine:
		# First keystroke after opening replaces the pre-filled value (the
		# current scale, say) rather than appending to it — typing "2.5" over
		# a pre-filled "1" should give "2.5", not "12.5".
		_text = ""
		_pristine = false
	match key:
		"<-":
			_text = _text.substr(0, max(0, _text.length() - 1))
		"-":
			# only meaningful as a leading sign; typing it again removes it
			_text = _text.substr(1) if _text.begins_with("-") else "-" + _text
		".":
			if not "." in _text:
				_text += "."
		_:
			_text += key
	_update_display()


func _update_display() -> void:
	if _display:
		_display.text = _text if _text != "" else "0"


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while open
	add_child(_viewport)
	_viewport.add_child(_build_ui())


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


func _build_ui() -> Control:
	var theme := Theme.new()
	theme.default_font_size = 30

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

	_display = Label.new()
	_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_display.add_theme_font_size_override("font_size", 44)
	column.add_child(_display)

	var rows := [
		["7", "8", "9"],
		["4", "5", "6"],
		["1", "2", "3"],
		[".", "0", "-"],
		["<-", "Cancel", "OK"],
	]
	for row_keys in rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		column.add_child(row)
		for key in row_keys:
			var button := Button.new()
			button.text = key
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.pressed.connect(_key_pressed.bind(key))
			row.add_child(button)

	_cursor = Control.new()
	_cursor.size = Vector2(16, 16)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.draw.connect(func() -> void: _cursor.draw_circle(Vector2(8, 8), 8.0, Color(1.0, 0.85, 0.1)))
	root.add_child(_cursor)

	return root
