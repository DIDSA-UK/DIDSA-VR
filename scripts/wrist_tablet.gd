extends Node3D
## The wrist tablet from the vision brief: a small panel on the left wrist for
## UI/UX settings, tool selection and menus.
##
## It's closed by default, so it can't pop up by accident: a small bullseye
## floats on the left wrist, and shooting it (right laser + trigger) opens the
## tablet. Press the X on the tablet, or shoot the bullseye again once it's
## closed, to put it away.
##
## Point the RIGHT hand's laser at the tablet and pull the trigger to press
## buttons. While the laser is over the tablet or the bullseye, the trigger
## belongs to them: that sets the "ui_hover" meta on the right controller,
## which controller.gd checks before laser-selecting a part.
##
## Tabs: Modes (switch the brief's manipulation modes on/off, hold-still
## steadiness), Scale (scale views, Fit, Home), Files (load a local .glb),
## Perf (frame timings, and the levers for speed: shadows, resolution, MSAA).
##
## While closed it costs almost nothing: its panel isn't rendered and nothing
## is measured.
##
## How it works: a normal Godot Control UI lives in a SubViewport, drawn onto
## a quad. There's no physics — the laser is intersected with the quad's plane
## by hand and turned into mouse events pushed into the SubViewport.
##
## The right thumbstick click is deliberately NOT used here: the vision brief
## reserves it for the popup keyboard, everywhere.

@export var panel_size := Vector2(0.24, 0.18) ## metres
@export var viewport_size := Vector2i(640, 480) ## pixels the UI is laid out in
@export var mount_position := Vector3(0.0, 0.06, 0.07) ## relative to the left controller: above and a little behind it
@export var mount_tilt_degrees: float = 0.0 ## extra tilt about X; tweak if it sits awkwardly on your wrist
@export var target_position := Vector3(0.0, 0.05, 0.06) ## the wrist bullseye, relative to the left controller
@export var target_radius: float = 0.035 ## metres; how generous the "shot" hit area is (the drawn ring is smaller)
@export var max_point_distance: float = 2.0 ## metres; laser reach for pressing buttons
@export var click_action: String = "trigger_click"
@export var max_files_listed: int = 5
@export var open_settle_seconds: float = 0.4 ## presses are ignored this long after opening: your laser is still resting where the bullseye was, so a quick second pull would hit whatever button appears there

var _left: XRController3D
var _right: XRController3D
var _camera: XRCamera3D
var _two_hand: Node
var _locomotion: Node
var _main: Node
var _command_stack = null
var _undo_button: Button
var _redo_button: Button

var _viewport: SubViewport
var _quad: MeshInstance3D
var _cursor: Control
var _pages := {} # tab name -> Control
var _info_label: Label
var _scale_label: Label
var _lock_button: Button
var _files_box: VBoxContainer

var _open := false
var _last_target_hover := false
var _opened_at_ms := 0
var _target: Node3D
var _target_materials: Array[StandardMaterial3D] = []
var _target_hover := false
var _hovering := false
var _pressed := false
var _pointer_px := Vector2.ZERO
var _last_sent_px := Vector2(-1, -1)
var _refresh_left := 0.0


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D, two_hand: Node, locomotion: Node, main: Node, command_stack = null) -> void:
	_left = left
	_right = right
	_camera = camera
	_two_hand = two_hand
	_locomotion = locomotion
	_main = main
	_command_stack = command_stack

	_build_viewport()
	_build_quad()
	_left.add_child(self)
	position = mount_position
	rotation_degrees = Vector3(-90.0 + mount_tilt_degrees, 0.0, 0.0) # quad faces +Z; this turns it to face up out of the wrist
	_build_target()
	_right.button_pressed.connect(_on_right_pressed)
	_right.button_released.connect(_on_right_released)
	visible = false


func is_open() -> bool:
	return _open


func open_tablet() -> void:
	_open = true
	_opened_at_ms = Time.get_ticks_msec()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_main.set_measuring(true)


func close_tablet() -> void:
	_open = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_main.set_measuring(false)


func set_info(text: String) -> void:
	if _info_label:
		_info_label.text = text


func _process(delta: float) -> void:
	if _camera == null:
		return

	visible = _open
	_target.visible = not _open
	_update_pointer(global_transform.basis.z.normalized())

	_refresh_left -= delta
	if _open and _refresh_left <= 0.0:
		_refresh_left = 0.25
		_scale_label.text = _two_hand.scale_text()
		_lock_button.set_pressed_no_signal(_two_hand.scale_locked)
		_lock_button.text = "Scale lock: %s" % ("ON" if _two_hand.scale_locked else "off")
		if _command_stack:
			_undo_button.disabled = not _command_stack.can_undo()
			_redo_button.disabled = not _command_stack.can_redo()


func _update_pointer(normal: Vector3) -> void:
	var was_hovering := _hovering
	_hovering = false
	var origin := _right.global_position
	var dir := -_right.global_transform.basis.z.normalized()

	# The wrist bullseye: a sphere-shaped hit area around it.
	_target_hover = false
	if not _open:
		var hits := Geometry3D.segment_intersects_sphere(
			origin, origin + dir * max_point_distance, _target.global_position, target_radius
		)
		_target_hover = not hits.is_empty()
	if _target_hover != _last_target_hover:
		_last_target_hover = _target_hover
		for mat in _target_materials:
			mat.albedo_color = Color(1.0, 0.85, 0.1) if _target_hover else Color(0.3, 0.9, 1.0)

	if visible:
		var hit = Plane(normal, global_position).intersects_ray(origin, dir)
		if hit != null and origin.distance_to(hit) <= max_point_distance:
			var local: Vector3 = global_transform.affine_inverse() * hit
			if absf(local.x) <= panel_size.x * 0.5 and absf(local.y) <= panel_size.y * 0.5:
				_hovering = true
				_pointer_px = Vector2(
					(local.x / panel_size.x + 0.5) * viewport_size.x,
					(0.5 - local.y / panel_size.y) * viewport_size.y
				)

	_right.set_meta("ui_hover", _hovering or _target_hover)
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
		_send_click(false) # laser slid off the tablet mid-press: let go so nothing stays stuck down


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _target_hover and not _open:
		open_tablet()
		_right.trigger_haptic_pulse("haptic", 0.0, 0.6, 0.08, 0.0)
		return
	if action_name == click_action and _hovering:
		if (Time.get_ticks_msec() - _opened_at_ms) < open_settle_seconds * 1000.0:
			return
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


func _build_target() -> void:
	# A little flat bullseye (ring + centre dot) hovering over the wrist.
	_target = Node3D.new()
	_left.add_child(_target)
	_target.position = target_position
	var parts := {"ring": TorusMesh.new(), "dot": SphereMesh.new()}
	var ring: TorusMesh = parts["ring"]
	ring.inner_radius = 0.02
	ring.outer_radius = 0.03
	var dot: SphereMesh = parts["dot"]
	dot.radius = 0.007
	dot.height = 0.014
	for mesh in parts.values():
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.3, 0.9, 1.0)
		mesh.material = mat
		_target_materials.append(mat)
		var instance := MeshInstance3D.new()
		instance.mesh = mesh
		_target.add_child(instance)


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while the tablet is open
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
	theme.default_font_size = 26

	# A plain holder, so the cursor dot can sit over the panel without the
	# PanelContainer stretching it to fill the whole thing.
	var root := Control.new()
	root.theme = theme
	root.size = Vector2(viewport_size)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.1, 0.13)
	bg.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", bg)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	# Undo/redo: always visible, regardless of which tab is open, since it
	# applies across all of them (part moves, model moves, and whatever
	# later tools push to the same command_stack.gd history).
	var history_row := HBoxContainer.new()
	history_row.add_theme_constant_override("separation", 8)
	column.add_child(history_row)
	_undo_button = Button.new()
	_undo_button.text = "Undo"
	_undo_button.disabled = true
	_undo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_undo_button.pressed.connect(_on_undo_pressed)
	history_row.add_child(_undo_button)
	_redo_button = Button.new()
	_redo_button.text = "Redo"
	_redo_button.disabled = true
	_redo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_redo_button.pressed.connect(_on_redo_pressed)
	history_row.add_child(_redo_button)

	# Tab bar: radio-style buttons, exactly one page showing.
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 8)
	column.add_child(tab_row)
	var tab_group := ButtonGroup.new()
	var pages_holder := VBoxContainer.new()
	pages_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(pages_holder)

	var builders := {
		"Modes": _build_modes_page,
		"Scale": _build_scale_page,
		"Tools": _build_tools_page,
		"Files": _build_files_page,
		"Perf": _build_perf_page,
	}
	for tab_name in builders:
		var page: Control = builders[tab_name].call()
		_pages[tab_name] = page
		pages_holder.add_child(page)
		var tab := Button.new()
		tab.text = tab_name
		tab.toggle_mode = true
		tab.button_group = tab_group
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.toggled.connect(_on_tab_toggled.bind(tab_name))
		tab_row.add_child(tab)
		if tab_name == "Modes":
			tab.button_pressed = true
	_show_page("Modes")

	var close := Button.new()
	close.text = "X"
	close.pressed.connect(close_tablet)
	tab_row.add_child(close)

	# Little dot showing where the laser is on the panel.
	_cursor = Control.new()
	_cursor.size = Vector2(16, 16)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.draw.connect(func() -> void: _cursor.draw_circle(Vector2(8, 8), 8.0, Color(1.0, 0.85, 0.1)))
	root.add_child(_cursor)

	return root


func _on_undo_pressed() -> void:
	if _command_stack:
		_command_stack.undo()


func _on_redo_pressed() -> void:
	if _command_stack:
		_command_stack.redo()


func _on_tab_toggled(on: bool, tab_name: String) -> void:
	if on:
		_show_page(tab_name)


func _show_page(tab_name: String) -> void:
	for page_name in _pages:
		_pages[page_name].visible = (page_name == tab_name)
	if tab_name == "Files":
		_rebuild_files()


# --- Modes: the brief's four manipulation modes, switchable on their own ---

func _build_modes_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.add_child(_mode_toggle("Model movement", func(on: bool) -> void: _two_hand.enabled = on))
	page.add_child(_mode_toggle("User movement", func(on: bool) -> void: _locomotion.enabled = on))
	page.add_child(_mode_toggle("Part manipulation", func(on: bool) -> void:
		_left.set_parts_enabled(on)
		_right.set_parts_enabled(on)
	))
	page.add_child(_choice_row("Steadiness (hold-still shake)", _two_hand.STEADINESS_NAMES, _two_hand.steadiness,
		func(i: int) -> void: _two_hand.set_steadiness(i)))
	var hint := Label.new()
	hint.text = "Scale views: see the Scale tab."
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)
	return page


func _mode_toggle(label: String, apply: Callable, default_on: bool = true) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_pressed = default_on
	button.text = "%s: %s" % [label, "ON" if default_on else "off"]
	button.toggled.connect(func(on: bool) -> void:
		button.text = "%s: %s" % [label, "ON" if on else "off"]
		apply.call(on)
	)
	return button


# --- Scale: scale views (brief mode 4), Fit, Home ---

func _build_scale_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	_scale_label = Label.new()
	page.add_child(_scale_label)

	var presets_row := HFlowContainer.new()
	presets_row.add_theme_constant_override("h_separation", 8)
	presets_row.add_theme_constant_override("v_separation", 8)
	page.add_child(presets_row)
	for multiple in _two_hand.presets:
		var button := Button.new()
		button.text = _ratio_text(multiple)
		button.pressed.connect(_two_hand.set_preset.bind(multiple))
		presets_row.add_child(button)

	_lock_button = Button.new()
	_lock_button.toggle_mode = true
	_lock_button.toggled.connect(func(on: bool) -> void: _two_hand.scale_locked = on)
	page.add_child(_lock_button)

	var view_row := HBoxContainer.new()
	view_row.add_theme_constant_override("separation", 8)
	page.add_child(view_row)
	var fit := Button.new()
	fit.text = "Fit to view"
	fit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fit.pressed.connect(func() -> void: _two_hand.fit_to_view(_camera))
	view_row.add_child(fit)
	var home := Button.new()
	home.text = "Home"
	home.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	home.pressed.connect(func() -> void: _two_hand.go_home())
	view_row.add_child(home)
	return page


# --- Tools: assembly tools from the vision brief's "Assembly tools" list ---

func _build_tools_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	page.add_child(_mode_toggle("Shoot to hide", func(on: bool) -> void:
		_left.hide_tool_active = on
		_right.hide_tool_active = on
	, false))

	var visibility_row := HBoxContainer.new()
	visibility_row.add_theme_constant_override("separation", 8)
	page.add_child(visibility_row)
	var hide_all := Button.new()
	hide_all.text = "Hide all"
	hide_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hide_all.pressed.connect(_main.hide_all_parts)
	visibility_row.add_child(hide_all)
	var show_all := Button.new()
	show_all.text = "Show all"
	show_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	show_all.pressed.connect(_main.show_all_parts)
	visibility_row.add_child(show_all)

	var reverse := Button.new()
	reverse.text = "Reverse visibility"
	reverse.pressed.connect(_main.reverse_visibility)
	page.add_child(reverse)

	var isolate := Button.new()
	isolate.text = "Isolate selected"
	isolate.pressed.connect(_main.isolate_selected)
	page.add_child(isolate)

	return page


# --- Files: load a local .glb ---

func _build_files_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	_files_box = VBoxContainer.new()
	_files_box.add_theme_constant_override("separation", 8)
	page.add_child(_files_box)
	return page


func _rebuild_files() -> void:
	for child in _files_box.get_children():
		_files_box.remove_child(child)
		child.queue_free()

	var files: PackedStringArray = _main.list_model_files()
	if files.is_empty():
		var none := Label.new()
		none.text = "No .glb files found.\nPut them in the project's models folder."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_files_box.add_child(none)
	for i in mini(files.size(), max_files_listed):
		var path := files[i]
		var button := Button.new()
		button.text = path.get_file()
		button.clip_text = true
		button.pressed.connect(_main.load_glb_file.bind(path))
		_files_box.add_child(button)
	if files.size() > max_files_listed:
		var more := Label.new()
		more.text = "+ %d more (not listed yet)" % (files.size() - max_files_listed)
		_files_box.add_child(more)

	var refresh := Button.new()
	refresh.text = "Refresh list"
	refresh.pressed.connect(_rebuild_files)
	_files_box.add_child(refresh)


# --- Perf: numbers, and the levers ---

func _build_perf_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 6)
	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 20)
	_info_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
	page.add_child(_info_label)

	page.add_child(_mode_toggle("Shadows", func(on: bool) -> void: _main.set_shadows(on)))
	page.add_child(_choice_row("Resolution", ["100%", "80%", "65%"], 0,
		func(i: int) -> void: _main.set_render_scale([1.0, 0.8, 0.65][i])))
	page.add_child(_choice_row("MSAA", ["Off", "2x", "4x"], 1,
		func(i: int) -> void: _main.set_msaa(i)))
	return page


func _choice_row(title: String, options: Array, selected: int, on_pick: Callable) -> Control:
	## A caption and a row of radio-style buttons; on_pick gets the chosen index.
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var caption := Label.new()
	caption.text = title
	caption.add_theme_font_size_override("font_size", 18)
	caption.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	box.add_child(caption)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var group := ButtonGroup.new()
	for i in options.size():
		var button := Button.new()
		button.text = str(options[i])
		button.toggle_mode = true
		button.button_group = group
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.button_pressed = (i == selected)
		button.pressed.connect(on_pick.bind(i))
		row.add_child(button)
	return box


func _ratio_text(multiple: float) -> String:
	return "%s:1" % _trim(multiple) if multiple >= 1.0 else "1:%s" % _trim(1.0 / multiple)


func _trim(x: float) -> String:
	return ("%.2f" % x).rstrip("0").rstrip(".")
