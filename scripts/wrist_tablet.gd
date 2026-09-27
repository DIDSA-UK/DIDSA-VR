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
var _mates_tool: Node
var _colour_tool: Node
var _section_tool: Node
var _undo_button: Button
var _redo_button: Button

const MATE_TYPE_LABELS: Array[String] = ["Coincident", "Concentric", "Parallel", "Distance", "Angle"]

var _mates_status_label: Label
var _mates_picks_label: Label
var _mates_value_label: Label
var _mates_create_button: Button
var _mates_relax_button: Button
var _mates_list_box: VBoxContainer
var _mates_last_owner_part_id := ""

# Milestone 4: a fixed swatch palette (common colours, plus Custom via the
# popup keyboard) — "#RRGGBB" strings straight into colour_tool.gd, which
# sends them to the backend verbatim (an opaque, client-owned string, never
# parsed server-side — see OccurrenceTransformUpdate.color's own docstring).
const COLOUR_SWATCHES: Array[Dictionary] = [
	{"name": "Red", "hex": "#e63946"}, {"name": "Orange", "hex": "#f4a340"},
	{"name": "Yellow", "hex": "#f1c40f"}, {"name": "Green", "hex": "#2ecc71"},
	{"name": "Blue", "hex": "#3498db"}, {"name": "Purple", "hex": "#9b59b6"},
	{"name": "White", "hex": "#f5f5f5"}, {"name": "Black", "hex": "#222222"},
]
var _colour_status_label: Label
var _colour_message_hold_until_ms := 0 ## _show_colour_message()'s own hold window — see that function's docstring for why this exists
var _colour_group_toggle: Button ## "Apply to whole group" — read directly by _apply_colour(), not driven through its own toggled callback

# Milestone 4: Sections — a single grabbable clip-plane gizmo, client-side
# only (see section_tool.gd's own docstring for why: the backend's real
# section-preview endpoint re-tessellates a fresh OCCT boolean on every
# call, much too slow for a plane you're dragging at 90 Hz).
var _sections_status_label: Label
var _sections_flip_button: Button

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
var _press_px := Vector2.ZERO ## _pointer_px frozen at the moment the trigger went down — see _send_click()'s own docstring for why this isn't just _pointer_px
var _last_sent_px := Vector2(-1, -1)
var _refresh_left := 0.0


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D, two_hand: Node, locomotion: Node, main: Node, command_stack = null, mates_tool: Node = null, colour_tool: Node = null, section_tool: Node = null) -> void:
	_left = left
	_right = right
	_camera = camera
	_two_hand = two_hand
	_locomotion = locomotion
	_main = main
	_command_stack = command_stack
	_mates_tool = mates_tool
	_colour_tool = colour_tool
	_section_tool = section_tool

	_build_viewport()
	_build_quad()
	_left.add_child(self)
	position = mount_position
	rotation_degrees = Vector3(-90.0 + mount_tilt_degrees, 0.0, 0.0) # quad faces +Z; this turns it to face up out of the wrist
	_build_target()
	_right.button_pressed.connect(_on_right_pressed)
	_right.button_released.connect(_on_right_released)
	if _mates_tool:
		_mates_tool.picks_changed.connect(_refresh_mates_picks_display)
		_mates_tool.mates_changed.connect(_rebuild_mates_list)
	if _section_tool:
		_section_tool.changed.connect(_refresh_sections_display)
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
		if _colour_status_label and Time.get_ticks_msec() >= _colour_message_hold_until_ms:
			var selected: Node3D = _main.current_selected_part()
			_colour_status_label.text = "Selected: %s" % (str(selected.name) if selected else "nothing — laser-select a part first")


func _update_pointer(normal: Vector3) -> void:
	var was_hovering := _hovering
	_hovering = false
	var origin := _right.global_position
	var dir := -_right.global_transform.basis.z.normalized()
	var hit_distance := -1.0 ## -1 = not hovering anything of ours this frame; controller.gd's laser reads "ui_hit_distance" below to know how far to draw itself, falling back to its own part-raycast otherwise

	# The wrist bullseye: a sphere-shaped hit area around it.
	_target_hover = false
	if not _open:
		var hits := Geometry3D.segment_intersects_sphere(
			origin, origin + dir * max_point_distance, _target.global_position, target_radius
		)
		_target_hover = not hits.is_empty()
		if _target_hover:
			hit_distance = origin.distance_to(hits[0])
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
				hit_distance = origin.distance_to(hit)
				# While a click is being held, freeze the pointer at the press
				# position instead of following the live aim — see
				# _send_click()'s own docstring for the full reasoning: Godot's
				# BaseButton cancels a press the instant ANY MouseMotion event
				# lands outside its rect (tracked as "pressing_inside", checked
				# again only at release), regardless of what position the
				# eventual mouse-up event itself carries. A real hand's few mm
				# of drift during a ~100-300ms trigger squeeze is enough to
				# send at least one such motion event if this keeps tracking
				# the live aim, silently cancelling the click before release
				# even sees it.
				if not _pressed:
					_pointer_px = Vector2(
						(local.x / panel_size.x + 0.5) * viewport_size.x,
						(0.5 - local.y / panel_size.y) * viewport_size.y
					)

	_right.set_meta("ui_hover", _hovering or _target_hover)
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
		_send_click(false) # laser slid off the tablet mid-press: let go so nothing stays stuck down


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _target_hover and not _open:
		open_tablet()
		_right.trigger_haptic_pulse("haptic", 0.0, 0.6, 0.08, 0.0)
		return
	if action_name == click_action and _hovering:
		if (Time.get_ticks_msec() - _opened_at_ms) < open_settle_seconds * 1000.0:
			return
		_press_px = _pointer_px
		_send_click(true)
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and _pressed:
		_send_click(false)


func _send_click(down: bool) -> void:
	## Uses _press_px (frozen at the moment the trigger went down), not the
	## live _pointer_px, for BOTH the down and up events — real-headset
	## feedback: hover worked but buttons never actually activated. Root
	## cause: a real hand's trigger squeeze takes real time (the physical
	## press to release isn't instantaneous like a synthetic button_pressed/
	## button_released emit in a test), and _pointer_px keeps tracking the
	## laser every frame in between — so the "up" event used to land at
	## wherever the aim had drifted to by release, not where it was at press.
	## Godot's own Button only counts a click when down and up land on the
	## SAME control (BaseButton::_gui_input checks the event's own carried
	## position, not a separately-tracked live mouse position), so even a
	## few pixels of real hand tremor during the hold was enough to silently
	## drop every click while still showing a perfectly normal hover state
	## throughout — exactly why this was invisible to every headless test
	## (button_pressed.emit()/button_released.emit() there always fire with
	## the simulated controller in the same, unmoving position).
	_pressed = down
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	click.position = _press_px
	click.global_position = _press_px
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
	# Real-headset feedback: toggle buttons (Modes' three, Sections' Section
	# tool/Flip, Mates' Flip/Relax, the tab row, the choice rows) updated
	# their own text ("ON"/"off") but showed no visible highlight — this
	# theme never defined a "pressed" stylebox anywhere, so every toggle
	# button was relying entirely on Godot's own built-in default theme,
	# which isn't distinct enough on an unshaded SubViewport quad at arm's
	# length. One override here, theme-wide, fixes every toggle button in
	# the tablet at once — matches the app's own established cyan accent
	# (controller.gd's hover/select highlight materials use the same hue).
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = Color(0.15, 0.55, 0.68)
	pressed_style.set_corner_radius_all(4)
	pressed_style.set_content_margin_all(6)
	theme.set_stylebox("pressed", "Button", pressed_style)
	theme.set_stylebox("hover_pressed", "Button", pressed_style)

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

	# Tab bar: radio-style buttons, exactly one page showing. HFlowContainer
	# (same choice _build_scale_page()'s presets row and _build_colours_page()'s
	# swatch grid already make), not HBoxContainer: with 8 tabs now (Sections
	# added this session) the row's own minimum width — driven by each
	# button's own text, which SIZE_EXPAND_FILL can't shrink below — exceeds
	# viewport_size.x (640px) and HBoxContainer doesn't wrap, so every tab
	# past that point silently rendered outside the tablet's own clipped
	# area: still "visible" by Godot's own is_visible_in_tree() (nothing
	# hides it), but never reachable by a real laser aimed at the physical
	# panel. Found because it also shifted EVERY control below the tab row
	# far enough to break tests/tablet_scene.gd's existing click-position
	# math for a button that hadn't moved (the Modes tab's own Steadiness
	# row) — not a coincidence: the whole column below an overflowing row
	# shifts with it. HFlowContainer wraps to a second row instead.
	var tab_row := HFlowContainer.new()
	tab_row.add_theme_constant_override("h_separation", 8)
	tab_row.add_theme_constant_override("v_separation", 8)
	column.add_child(tab_row)
	var tab_group := ButtonGroup.new()
	var pages_holder := VBoxContainer.new()
	pages_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(pages_holder)

	var builders := {
		"Modes": _build_modes_page,
		"Scale": _build_scale_page,
		"Tools": _build_tools_page,
		"Mates": _build_mates_page,
		"Colours": _build_colours_page,
		"Sections": _build_sections_page,
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
		tab.toggled.connect(_on_tab_toggled.bind(tab_name))
		tab_row.add_child(tab)
		if tab_name == "Modes":
			tab.button_pressed = true
	_show_page("Modes")

	var close := Button.new()
	close.text = "X"
	close.pressed.connect(close_tablet)
	tab_row.add_child(close)

	# A soft glow showing where the laser terminates on the panel — real-
	# headset feedback wanted the laser to visibly stop and glow here rather
	# than (per the old flat 8px dot, and the laser itself previously never
	# shortening at all — see controller.gd's _update_laser_visual()) look
	# like it passed straight through. Concentric fading rings read as a
	# glow at arm's length better than one flat-alpha circle does.
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
	elif tab_name == "Mates":
		_refresh_mates_picks_display()
		var owner_part_id: String = _main.current_root_part_id()
		if _mates_tool and owner_part_id != "":
			_mates_last_owner_part_id = owner_part_id
			_mates_tool.refresh_mates(owner_part_id)


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
		func(i: int) -> void:
			_two_hand.set_steadiness(i) # whole-model moves
			_left.set_steadiness(i) # a single held part (grip), each hand
			_right.set_steadiness(i)
			if _section_tool:
				_section_tool.set_steadiness(i) # the section-plane gizmo, grabbed the same way
	))
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


# --- Mates: the vision brief's "Mates workflow" - start the tool, laser-
# target faces, pick a type, type a value on the popup keyboard, Create.
# Built as a client to DIDSA-CAD's real Mate endpoints (mates_tool.gd) so a
# mate authored here round-trips with the flat app - see that script's own
# docstring and docs/status.md.

func _build_mates_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	page.add_child(_mode_toggle("Mates tool", func(on: bool) -> void:
		_left.mates_tool_active = on
		_right.mates_tool_active = on
		if _mates_tool:
			_mates_tool.set_active(on)
	, false))

	_mates_status_label = Label.new()
	_mates_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_mates_status_label)

	_mates_picks_label = Label.new()
	_mates_picks_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mates_picks_label.add_theme_font_size_override("font_size", 18)
	_mates_picks_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(_mates_picks_label)

	var clear := Button.new()
	clear.text = "Clear picks"
	clear.pressed.connect(func() -> void:
		if _mates_tool:
			_mates_tool.clear_picks()
	)
	page.add_child(clear)

	page.add_child(_choice_row("Mate type", MATE_TYPE_LABELS, 0, func(i: int) -> void:
		if _mates_tool:
			_mates_tool.mate_type = _mates_tool.MATE_TYPES[i]
	))

	var toggles_row := HBoxContainer.new()
	toggles_row.add_theme_constant_override("separation", 8)
	page.add_child(toggles_row)
	var flip := Button.new()
	flip.text = "Flip"
	flip.toggle_mode = true
	flip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flip.toggled.connect(func(on: bool) -> void:
		if _mates_tool:
			_mates_tool.mate_flipped = on
	)
	toggles_row.add_child(flip)
	var allow_rot := Button.new()
	allow_rot.text = "Allow rotation"
	allow_rot.toggle_mode = true
	allow_rot.button_pressed = true
	allow_rot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	allow_rot.toggled.connect(func(on: bool) -> void:
		if _mates_tool:
			_mates_tool.mate_allow_rotation = on
	)
	toggles_row.add_child(allow_rot)

	var value_row := HBoxContainer.new()
	value_row.add_theme_constant_override("separation", 8)
	page.add_child(value_row)
	_mates_value_label = Label.new()
	_mates_value_label.text = "Value: 0 (distance mm / angle deg)"
	_mates_value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mates_value_label.clip_text = true
	value_row.add_child(_mates_value_label)
	var set_value := Button.new()
	set_value.text = "Set value"
	set_value.pressed.connect(_on_set_mate_value_pressed)
	value_row.add_child(set_value)

	_mates_create_button = Button.new()
	_mates_create_button.text = "Create mate"
	_mates_create_button.disabled = true
	_mates_create_button.pressed.connect(_on_create_mate_pressed)
	page.add_child(_mates_create_button)

	var bulk_row := HBoxContainer.new()
	bulk_row.add_theme_constant_override("separation", 8)
	page.add_child(bulk_row)
	_mates_relax_button = Button.new()
	_mates_relax_button.text = "Relax all: off"
	_mates_relax_button.toggle_mode = true
	_mates_relax_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mates_relax_button.toggled.connect(func(on: bool) -> void:
		_mates_relax_button.text = "Relax all: %s" % ("ON" if on else "off")
		if _mates_tool:
			_mates_tool.set_relaxed(on)
	)
	bulk_row.add_child(_mates_relax_button)
	var enforce := Button.new()
	enforce.text = "Enforce all"
	enforce.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enforce.pressed.connect(func() -> void:
		var owner_part_id: String = _main.current_root_part_id()
		if _mates_tool and owner_part_id != "":
			_mates_last_owner_part_id = owner_part_id
			_mates_tool.enforce_all(owner_part_id)
	)
	bulk_row.add_child(enforce)

	var list_label := Label.new()
	list_label.text = "Existing mates:"
	list_label.add_theme_font_size_override("font_size", 18)
	list_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(list_label)
	_mates_list_box = VBoxContainer.new()
	_mates_list_box.add_theme_constant_override("separation", 4)
	page.add_child(_mates_list_box)

	_refresh_mates_picks_display()
	return page


func _on_set_mate_value_pressed() -> void:
	if not _mates_tool:
		return
	_main.open_keyboard_for(_trim_mate_value(_mates_tool.mate_value), func(text: String) -> void:
		_mates_tool.mate_value = text.to_float()
		_mates_value_label.text = "Value: %s (distance mm / angle deg)" % _trim_mate_value(_mates_tool.mate_value)
	)


func _on_create_mate_pressed() -> void:
	if not _mates_tool or not _mates_tool.can_create():
		return
	_mates_create_button.disabled = true
	var result: Dictionary = await _mates_tool.create_mate()
	_mates_create_button.disabled = not _mates_tool.can_create()
	if not result["ok"]:
		_mates_status_label.text = "Couldn't create mate: %s" % result["error"]


func _refresh_mates_picks_display() -> void:
	if not _mates_tool or _mates_status_label == null:
		return
	_mates_status_label.text = _mates_tool.status_text()
	var labels: Array = _mates_tool.picked_labels()
	_mates_picks_label.text = "Picked: %s" % (", ".join(labels) if not labels.is_empty() else "none")
	if _mates_create_button:
		_mates_create_button.disabled = not _mates_tool.can_create()


func _rebuild_mates_list() -> void:
	if _mates_list_box == null:
		return
	for child in _mates_list_box.get_children():
		_mates_list_box.remove_child(child)
		child.queue_free()
	var owner_part_id: String = _mates_last_owner_part_id
	for mate in _mates_tool.mates:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var label := Label.new()
		var type_label: String = str(mate.get("type", "?")).capitalize()
		var has_value: bool = mate.get("value") != null
		label.text = "%s%s" % [type_label, (" (%s)" % _trim_mate_value(mate.get("value"))) if has_value else ""]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		row.add_child(label)
		var delete_button := Button.new()
		delete_button.text = "Delete"
		delete_button.pressed.connect(_on_delete_mate_pressed.bind(owner_part_id, str(mate.get("id", ""))))
		row.add_child(delete_button)
		_mates_list_box.add_child(row)
	if _mates_tool.mates.is_empty():
		var none := Label.new()
		none.text = "No mates yet."
		_mates_list_box.add_child(none)


func _on_delete_mate_pressed(owner_part_id: String, mate_id: String) -> void:
	if _mates_tool and owner_part_id != "" and mate_id != "":
		await _mates_tool.delete_mate(owner_part_id, mate_id)


func _trim_mate_value(x) -> String:
	return ("%.3f" % float(x)).rstrip("0").rstrip(".")


# --- Colours: the vision brief's Assembly tools "Colours" - acts on
# whichever part is already laser-selected (no picking tool of its own, see
# colour_tool.gd's own docstring for why), a fixed swatch palette plus a
# Custom hex entry via the popup keyboard, and Clear.

func _build_colours_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	_colour_status_label = Label.new()
	_colour_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_colour_status_label)

	# Colouring hierarchy, "for now" scope (docs/status.md has the full
	# write-up): the only two levels reachable without new backend work are
	# "this one Occurrence" (the default — laser-select it directly, exactly
	# as before) and "every Occurrence sharing its immediate owner" (the
	# closest approximation of "sub-assembly/pattern" this client can reach
	# without a real assembly-tree endpoint). This toggle picks between
	# them for every swatch/custom-hex/clear action below — no separate
	# button set needed.
	_colour_group_toggle = _mode_toggle("Apply to whole group", func(_on: bool) -> void: pass, false)
	page.add_child(_colour_group_toggle)

	var swatch_grid := HFlowContainer.new()
	swatch_grid.add_theme_constant_override("h_separation", 8)
	swatch_grid.add_theme_constant_override("v_separation", 8)
	page.add_child(swatch_grid)
	for swatch in COLOUR_SWATCHES:
		var button := Button.new()
		button.text = swatch["name"]
		button.add_theme_color_override("font_color", _readable_text_color(swatch["hex"]))
		var style := StyleBoxFlat.new()
		style.bg_color = Color(swatch["hex"])
		style.set_content_margin_all(10)
		button.add_theme_stylebox_override("normal", style)
		button.pressed.connect(_on_colour_swatch_pressed.bind(swatch["hex"]))
		swatch_grid.add_child(button)

	var custom_row := HBoxContainer.new()
	custom_row.add_theme_constant_override("separation", 8)
	page.add_child(custom_row)
	var custom := Button.new()
	custom.text = "Custom hex…"
	custom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom.pressed.connect(_on_custom_colour_pressed)
	custom_row.add_child(custom)
	var clear := Button.new()
	clear.text = "Clear colour"
	clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear.pressed.connect(func() -> void: _apply_colour(""))
	custom_row.add_child(clear)

	return page


func _on_colour_swatch_pressed(hex: String) -> void:
	_apply_colour(hex)


func _on_custom_colour_pressed() -> void:
	_main.open_keyboard_for("", func(text: String) -> void:
		var hex := text if text.begins_with("#") else "#" + text
		if hex.length() == 7:
			_apply_colour(hex)
		else:
			_show_colour_message("Not a valid hex colour (want #RRGGBB): %s" % text)
	)


func _show_colour_message(text: String, hold_seconds: float = 3.0) -> void:
	## Real-headset feedback: the Colours tab's status label was also the
	## periodic "Selected: <name>" readout (see _process()'s own refresh
	## timer, every 0.25s while the tablet is open) — an error set via plain
	## `.text =` got overwritten by that readout within a quarter second,
	## nowhere near long enough to read. Anything shown through here holds
	## the label for real (default 3s) before the periodic refresh is
	## allowed to touch it again.
	if not _colour_status_label:
		return
	_colour_status_label.text = text
	_colour_message_hold_until_ms = Time.get_ticks_msec() + int(hold_seconds * 1000.0)


func _apply_colour(hex: String) -> void:
	if not _colour_tool:
		return
	var part: Node3D = _main.current_selected_part()
	if part == null:
		_show_colour_message("Selected: nothing — laser-select a part first")
		return
	if _colour_group_toggle and _colour_group_toggle.button_pressed:
		var group_result: Dictionary = await _colour_tool.set_group_color(part, hex)
		if group_result["ok"]:
			_show_colour_message("Coloured %d occurrence(s) in the group." % group_result["count"])
		elif group_result["count"] > 0:
			_show_colour_message("Coloured %d, then failed: %s" % [group_result["count"], group_result["error"]])
		else:
			_show_colour_message("Couldn't colour the group: %s" % group_result["error"])
		return
	var result: Dictionary = await _colour_tool.set_color(part, hex)
	if not result["ok"]:
		_show_colour_message("Couldn't set colour: %s" % result["error"])


func _readable_text_color(hex: String) -> Color:
	## Plain luminance check so a swatch's own label stays legible against
	## both light (White/Yellow) and dark (Black) backgrounds.
	var c := Color(hex)
	var luminance := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	return Color.BLACK if luminance > 0.6 else Color.WHITE


# --- Sections: the vision brief's Assembly tools "sections" - a single
# grabbable clip-plane gizmo, client-side only (see section_tool.gd's own
# docstring for why: the backend's real section-preview endpoint
# re-tessellates a fresh OCCT boolean on every call, much too slow for a
# plane dragged at 90 Hz). GRIP grabs the gizmo directly in-world, same feel
# as grabbing a part - this tab just toggles it on/off and flips which side
# is kept.

func _build_sections_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	page.add_child(_mode_toggle("Section tool", func(on: bool) -> void:
		if _section_tool:
			_section_tool.set_active(on, _camera)
	, false))

	_sections_status_label = Label.new()
	_sections_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_sections_status_label)

	_sections_flip_button = Button.new()
	_sections_flip_button.text = "Flip"
	_sections_flip_button.toggle_mode = true
	_sections_flip_button.toggled.connect(func(on: bool) -> void:
		if _section_tool:
			_section_tool.set_flipped(on)
	)
	page.add_child(_sections_flip_button)

	var hint := Label.new()
	hint.text = "Grip the plane to move/tilt it, like grabbing a part."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)

	_refresh_sections_display()
	return page


func _refresh_sections_display() -> void:
	if not _section_tool or _sections_status_label == null:
		return
	if not _section_tool.active:
		_sections_status_label.text = "Off — turn on Section tool to place the plane"
	else:
		_sections_status_label.text = "Sectioning%s — grip the plane to move it" % (" (flipped)" if _section_tool.flipped else "")


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
		none.text = "No model files found.\nPut a .glb/.gltf/.step/.stl/.obj in the project's models folder."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_files_box.add_child(none)
	for i in mini(files.size(), max_files_listed):
		var path := files[i]
		var button := Button.new()
		button.text = path.get_file()
		button.clip_text = true
		button.pressed.connect(_main.load_model_file.bind(path))
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
