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
## Navigation: a left-hand category rail (View, Assembly, Windows, Files),
## each with its own row of sub-tabs, plus a small cogwheel pinned in the
## panel's top-right corner for Settings — the set-and-forget stuff
## (Steadiness, display quality, the project folder) that doesn't belong in
## day-to-day flow. See _build_ui() for the exact tree.
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

@export var panel_size := Vector2(0.3375, 0.27) ## metres — real-headset feedback: wider so the four categories + Settings/Close fit on ONE row with their labels unclipped (they need ~900 px: 4x160 + 150 + close + gaps + margins), and 20% taller (0.225 -> 0.27). Same 2667 px/m as the old 0.24 m / 640 px, so text stays the same physical size.
@export var viewport_size := Vector2i(900, 720) ## pixels the UI is laid out in (was 640x600)
@export var scroll_speed_px: float = 900.0 ## pixels/second the right thumbstick scrolls the tablet at full deflection while the right laser is on it
@export var scroll_deadzone: float = 0.5 ## a deliberate push, not a resting thumb: 0.2 (the first cut) is well inside the drift/contact a thumb makes on the stick while the index finger pulls the trigger, and scrolling during a click slid the buttons out from under it
@export var scroll_click_lockout_ms: int = 400 ## no stick-scrolling while a click is held, or this long after one is released
@export var mount_position := Vector3(0.0, 0.06, 0.07) ## relative to the left controller: above and a little behind it
@export var mount_tilt_degrees: float = 0.0 ## extra tilt about X; tweak if it sits awkwardly on your wrist
@export var target_position := Vector3(0.0, 0.05, 0.122) ## the wrist bullseye/tablet icon, relative to the left controller — was too far forward (0.06); nudged back by its own ring's 0.062m outer diameter, same fix as the controller button discs (controller.gd's _add_button_discs())
@export var target_radius: float = 0.035 ## metres; how generous the "shot" hit area is (the drawn ring is smaller)
@export var max_point_distance: float = 2.0 ## metres; laser reach for pressing buttons
@export var click_action: String = "trigger_click"
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
var _measure_tool: Node
var _assembly_tree_window: Node
var _calculator_window: Node
var _image_viewer_window: Node
var _browser_window: Node
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

# Milestone 4: Measurements — laser-pick 1-2 entities, live result from
# DIDSA-CAD's real POST .../measure endpoint (see measure_tool.gd's own
# docstring). Row ordering/formatting mirrors the flat app's own
# MeasurementPanel (client/lib/viewport3d/measurement_panel.dart) exactly,
# so a user moving between VR and flat sees the same numbers laid out the
# same way.
var _measure_status_label: Label
var _measure_picks_label: Label
var _measure_result_box: VBoxContainer

var _viewport: SubViewport
var _quad: MeshInstance3D
var _cursor: Control
var _pages := {} # tab name -> Control
var _info_label: Label
var _scale_label: Label
var _lock_button: Button
var _files_box: VBoxContainer
var _files_status_label: Label
var _environment_status_label: Label
var _project_folder_label: Label

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
var _pages_scroll: ScrollContainer ## wraps every page — content taller than the panel used to be clipped with no way to reach it
var _sliders: Array[Slider] = [] ## every Slider on the tablet: a press that starts on one keeps tracking the laser (a slider has to be DRAGGED), unlike a button press, whose pointer is frozen — see _update_pointer()
var _drag_slider := false
var _speed_label: Label
var _speed_slider: HSlider
var _last_click_ms := -100000 ## when the last click (press OR release) was sent — see _scroll_with_stick()
var _scroll_f := 0.0 ## sub-pixel accumulator for the thumbstick scroll (ScrollContainer.scroll_vertical is an int)


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D, two_hand: Node, locomotion: Node, main: Node, command_stack = null, mates_tool: Node = null, colour_tool: Node = null, section_tool: Node = null, measure_tool: Node = null, assembly_tree_window: Node = null, calculator_window: Node = null, image_viewer_window: Node = null, browser_window: Node = null) -> void:
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
	_measure_tool = measure_tool
	_assembly_tree_window = assembly_tree_window
	_calculator_window = calculator_window
	_image_viewer_window = image_viewer_window
	_browser_window = browser_window

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
	if _measure_tool:
		_measure_tool.picks_changed.connect(_refresh_measure_picks_display)
		_measure_tool.result_changed.connect(_rebuild_measure_result)
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

	if _open and _hovering:
		_scroll_with_stick(delta)

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
		if _files_status_label:
			_files_status_label.text = _main.status_text
		if _speed_slider and not _drag_slider:
			_speed_slider.set_value_no_signal(_locomotion.speed_fraction())
			_refresh_speed_label()


func _scroll_with_stick(delta: float) -> void:
	## Right thumbstick Y scrolls the tablet while the right laser is on it
	## (push down = scroll down). locomotion.gd and controller.gd stand their
	## own use of that stick down whenever "ui_hover" is set, so it can't also
	## teleport or spin a selected part.
	if _pages_scroll == null:
		return
	if _pressed or Time.get_ticks_msec() - _last_click_ms < scroll_click_lockout_ms:
		_scroll_f = float(_pages_scroll.scroll_vertical)
		return # mid-click: the page must not move under the frozen press point (see _send_click())
	_scroll_by_stick(_right.get_vector2("primary").y, delta)


func _scroll_by_stick(stick_y: float, delta: float) -> void:
	## Split from _scroll_with_stick() so tests can drive it without a real XR runtime.
	if absf(stick_y) < scroll_deadzone:
		_scroll_f = float(_pages_scroll.scroll_vertical)
		return
	_scroll_f = maxf(_scroll_f - stick_y * scroll_speed_px * delta, 0.0)
	_pages_scroll.scroll_vertical = int(_scroll_f)
	if float(_pages_scroll.scroll_vertical) < _scroll_f - 1.0:
		_scroll_f = float(_pages_scroll.scroll_vertical) # clamped at the bottom: don't keep accumulating past it


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
			mat.albedo_color = Color(0.75, 0.85, 1.0) if _target_hover else Color(0.8, 0.83, 0.87) # a slight blue tint plus a swell (below) on hover, rather than a hue-free brightness change
		_target.scale = Vector3.ONE * (1.2 if _target_hover else 1.0)

	if visible:
		var hit = Plane(normal, global_position).intersects_ray(origin, dir)
		if hit != null and origin.distance_to(hit) <= max_point_distance:
			var local: Vector3 = global_transform.affine_inverse() * hit
			# While a click is held, the panel's edge is forgiving (a trigger
			# squeeze tilts the controller by a few degrees): losing hover
			# mid-press let go of the button and made the laser run through
			# the panel (see the `elif was_hovering and _pressed` below).
			var slack := 0.03 if _pressed else 0.0
			if absf(local.x) <= panel_size.x * 0.5 + slack and absf(local.y) <= panel_size.y * 0.5 + slack:
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
				if not _pressed or _drag_slider:
					_pointer_px = Vector2(
						(local.x / panel_size.x + 0.5) * viewport_size.x,
						(0.5 - local.y / panel_size.y) * viewport_size.y
					)

	_right.set_meta("ui_hover", _hovering or _target_hover)
	_right.set_meta("ui_hit_distance", hit_distance)
	_cursor.visible = _hovering
	if _hovering:
		_cursor.position = _pointer_px - _cursor.size * 0.5
		if (not _pressed or _drag_slider) and _pointer_px != _last_sent_px:
			var motion := InputEventMouseMotion.new()
			motion.position = _pointer_px
			motion.global_position = _pointer_px
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT if _pressed else 0
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
		_drag_slider = _slider_at(_press_px)
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
	_last_click_ms = Time.get_ticks_msec()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	# A slider drag is released wherever the laser has got to (that's where the
	# value ends up); every other press releases at its frozen press point.
	var at := _pointer_px if (_drag_slider and not down) else _press_px
	click.position = at
	click.global_position = at
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	_viewport.push_input(click)
	if not down:
		_drag_slider = false


func _build_target() -> void:
	# A little flat bullseye hovering over the wrist: a thin ring with a
	# landscape rectangle inside it — a stylised tablet — rather than the
	# original spike's plain ring-and-dot, so the icon itself hints at what
	# shooting it opens. Thin white lines throughout, matching this pass's
	# visual language elsewhere (floor grid, controller discs).
	_target = Node3D.new()
	_left.add_child(_target)
	_target.position = target_position

	var ring := TorusMesh.new()
	ring.inner_radius = 0.027
	ring.outer_radius = 0.031
	_add_target_mesh(ring)

	# The tablet rectangle's outline, four thin bars (each extended by its
	# own thickness so the corners meet cleanly rather than leaving a gap).
	var half_width := 0.017
	var half_height := 0.011
	var bar_thickness := 0.0025
	var bar_height := 0.001 # thin along local Y so it lies flat, matching the ring
	var bars := [
		{"size": Vector3(half_width * 2.0 + bar_thickness, bar_height, bar_thickness), "pos": Vector3(0.0, 0.0, -half_height)}, # top
		{"size": Vector3(half_width * 2.0 + bar_thickness, bar_height, bar_thickness), "pos": Vector3(0.0, 0.0, half_height)}, # bottom
		{"size": Vector3(bar_thickness, bar_height, half_height * 2.0 + bar_thickness), "pos": Vector3(-half_width, 0.0, 0.0)}, # left
		{"size": Vector3(bar_thickness, bar_height, half_height * 2.0 + bar_thickness), "pos": Vector3(half_width, 0.0, 0.0)}, # right
	]
	for bar in bars:
		var box := BoxMesh.new()
		box.size = bar["size"]
		var instance := _add_target_mesh(box)
		instance.position = bar["pos"]


func _add_target_mesh(mesh: Mesh) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.8, 0.83, 0.87)
	mesh.material = mat
	_target_materials.append(mat)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	_target.add_child(instance)
	return instance


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


const _CATEGORY_ACCENTS := {
	"View": Color(0.35, 0.78, 0.95),
	"Assembly": Color(0.95, 0.72, 0.35),
	"Windows": Color(0.72, 0.6, 0.95),
	"Files": Color(0.5, 0.85, 0.6),
}


func _build_ui() -> Control:
	var theme := Theme.new()
	theme.default_font_size = 24
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
	pressed_style.set_corner_radius_all(6)
	pressed_style.set_content_margin_all(8)
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
	bg.bg_color = Color(0.07, 0.085, 0.11)
	bg.border_color = Color(0.18, 0.4, 0.48)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(12)
	bg.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", bg)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	# Undo/redo: always visible, regardless of which category is open, since
	# it applies across all of them (part moves, model moves, and whatever
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

	# Header: a left-hand category rail (View / Assembly / Windows / Files —
	# each holding its own row of sub-tabs, built by _build_subtabbed()) plus
	# a small Settings cogwheel and Close pinned to the corner on the right,
	# out of the main flow — set-and-forget stuff doesn't belong beside the
	# tools used every session. HFlowContainer for the rail itself for the
	# same reason the old flat tab row used it (see git history): it wraps
	# instead of silently overflowing the panel's own clipped area.
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	column.add_child(header_row)

	var category_rail := HFlowContainer.new()
	category_rail.add_theme_constant_override("h_separation", 6)
	category_rail.add_theme_constant_override("v_separation", 6)
	category_rail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(category_rail)

	var corner_row := HBoxContainer.new()
	corner_row.add_theme_constant_override("separation", 6)
	header_row.add_child(corner_row)

	# Real-headset feedback: the tablet overflowed at the bottom with no way to
	# scroll. Every page sits in one ScrollContainer; while the right laser is
	# on the tablet the right thumbstick scrolls it (see _scroll_with_stick()).
	_pages_scroll = ScrollContainer.new()
	_pages_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pages_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pages_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_pages_scroll)
	var pages_holder := VBoxContainer.new()
	pages_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pages_scroll.add_child(pages_holder)

	var tab_group := ButtonGroup.new()

	var view_page := _build_subtabbed({
		"Navigate": _build_navigate_page,
		"Scale": _build_scale_page,
		"Visibility": _build_visibility_page,
		"Environment": _build_environment_page,
	}, "Navigate", _CATEGORY_ACCENTS["View"])
	var assembly_page := _build_subtabbed({
		"Mates": _build_mates_page,
		"Colours": _build_colours_page,
		"Sections": _build_sections_page,
		"Measure": _build_measure_page,
	}, "Mates", _CATEGORY_ACCENTS["Assembly"])

	var category_pages := {
		"View": view_page,
		"Assembly": assembly_page,
		"Windows": _build_windows_page(),
		"Files": _build_files_page(),
	}
	for category_name in category_pages:
		var page: Control = category_pages[category_name]
		_pages[category_name] = page
		# SHRINK_BEGIN, not the Control default: pages_holder is itself
		# SIZE_EXPAND_FILL, and BoxContainer distributes its own leftover
		# space equally among children that have no expand flag of their
		# own — with only one page visible at a time, that one page (and
		# everything inside it, recursively) would otherwise balloon to
		# fill the tablet's whole remaining height, pushing later buttons
		# below the panel's clipped 480px canvas: still found by a laser
		# raycast (is_visible_in_tree() doesn't check clip bounds) but
		# never actually reachable by one aimed at the physical panel —
		# the same class of bug the old flat tab row's own HFlowContainer
		# fix (see git history) was for, just vertical instead of horizontal.
		page.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		pages_holder.add_child(page)
		var btn := _build_icon_button(category_name, category_name.to_lower(), _CATEGORY_ACCENTS[category_name], 160.0)
		btn.toggle_mode = true
		btn.button_group = tab_group
		btn.toggled.connect(_on_tab_toggled.bind(category_name))
		category_rail.add_child(btn)
		if category_name == "View":
			btn.button_pressed = true

	# Settings: a smaller cogwheel button pinned in the corner, out of the
	# main category rail — set-and-forget stuff (Steadiness, display
	# quality, project folder), not a tool reached for mid-task.
	var settings_page := _build_settings_page()
	_pages["Settings"] = settings_page
	settings_page.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	pages_holder.add_child(settings_page)
	var settings_btn := _build_icon_button("Settings", "settings", Color(0.78, 0.81, 0.85), 150.0)
	settings_btn.button_group = tab_group
	settings_btn.toggled.connect(_on_tab_toggled.bind("Settings"))
	corner_row.add_child(settings_btn)

	var close := Button.new()
	close.text = "X"
	close.custom_minimum_size = Vector2(40, 46)
	close.pressed.connect(close_tablet)
	corner_row.add_child(close)

	_show_page("View")

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


## A category's own internal navigation: a row of sub-tab buttons above a
## stack of pages, exactly one visible — the same radio-button-group
## mechanism _build_ui()'s own category rail uses one level up, just scoped
## to this one category instead of the whole tablet. Used by View (Navigate/
## Scale/Visibility/Environment) and Assembly (Mates/Colours/Sections/
## Measure); Windows and Files are short enough to stay flat, single pages.
func _build_subtabbed(subbuilders: Dictionary, default_name: String, accent: Color) -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)

	var sub_row := HFlowContainer.new()
	sub_row.add_theme_constant_override("h_separation", 6)
	sub_row.add_theme_constant_override("v_separation", 6)
	outer.add_child(sub_row)

	var holder := VBoxContainer.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(holder)

	var group := ButtonGroup.new()
	var subpages := {}
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = accent.darkened(0.62)
	pressed_style.set_corner_radius_all(4)
	pressed_style.set_content_margin_all(6)

	for sub_name in subbuilders:
		var page: Control = subbuilders[sub_name].call()
		subpages[sub_name] = page
		page.size_flags_vertical = Control.SIZE_SHRINK_BEGIN # see the matching comment in _build_ui() — same fix, one level down
		holder.add_child(page)
		var btn := Button.new()
		btn.text = sub_name
		btn.toggle_mode = true
		btn.button_group = group
		btn.add_theme_font_size_override("font_size", 20)
		btn.add_theme_stylebox_override("pressed", pressed_style)
		btn.add_theme_stylebox_override("hover_pressed", pressed_style)
		btn.toggled.connect(_on_subtab_toggled.bind(subpages, sub_name))
		sub_row.add_child(btn)
		if sub_name == default_name:
			btn.button_pressed = true
	_show_subpage(subpages, default_name)
	return outer


func _on_subtab_toggled(on: bool, subpages: Dictionary, sub_name: String) -> void:
	if on:
		_show_subpage(subpages, sub_name)


func _show_subpage(subpages: Dictionary, sub_name: String) -> void:
	for page_name in subpages:
		subpages[page_name].visible = (page_name == sub_name)
	if sub_name == "Mates":
		_refresh_mates_picks_display()
		var owner_part_id: String = _main.current_root_part_id()
		if _mates_tool and owner_part_id != "":
			_mates_last_owner_part_id = owner_part_id
			_mates_tool.refresh_mates(owner_part_id)
	elif sub_name == "Measure":
		_refresh_measure_picks_display()
		_rebuild_measure_result()


## --- Icons: small glyphs stamped into an Image and handed to Button.icon as
## a real Texture2D — in the same single-stroke, single-colour style
## DIDSA-CAD's own SVG icon set uses (client/assets/icons/ —
## stroke="currentColor", round joins) — so every category/scene button
## keeps Godot's own native icon+text layout (and Button.text stays real
## text, not folded into a child Control) rather than a hand-rolled overlay.
## No image assets, no import step: built at UI-construction time from
## plain circle/rect/line stamps, recoloured per category with a Color.

func _stamp_disc(img: Image, center: Vector2, radius: float, color: Color) -> void:
	var x0 := maxi(int(floor(center.x - radius)), 0)
	var x1 := mini(int(ceil(center.x + radius)), img.get_width())
	var y0 := maxi(int(floor(center.y - radius)), 0)
	var y1 := mini(int(ceil(center.y + radius)), img.get_height())
	for x in range(x0, x1):
		for y in range(y0, y1):
			if Vector2(x + 0.5, y + 0.5).distance_to(center) <= radius:
				img.set_pixel(x, y, color)


func _stamp_ring(img: Image, center: Vector2, radius: float, width: float, color: Color) -> void:
	var outer: float = radius + width * 0.5
	var inner: float = radius - width * 0.5
	var x0 := maxi(int(floor(center.x - outer)), 0)
	var x1 := mini(int(ceil(center.x + outer)), img.get_width())
	var y0 := maxi(int(floor(center.y - outer)), 0)
	var y1 := mini(int(ceil(center.y + outer)), img.get_height())
	for x in range(x0, x1):
		for y in range(y0, y1):
			var d: float = Vector2(x + 0.5, y + 0.5).distance_to(center)
			if d <= outer and d >= inner:
				img.set_pixel(x, y, color)


func _stamp_rect_fill(img: Image, rect: Rect2, color: Color) -> void:
	var x0 := maxi(int(floor(rect.position.x)), 0)
	var x1 := mini(int(ceil(rect.position.x + rect.size.x)), img.get_width())
	var y0 := maxi(int(floor(rect.position.y)), 0)
	var y1 := mini(int(ceil(rect.position.y + rect.size.y)), img.get_height())
	for x in range(x0, x1):
		for y in range(y0, y1):
			img.set_pixel(x, y, color)


func _stamp_rect_outline(img: Image, rect: Rect2, width: float, color: Color) -> void:
	_stamp_rect_fill(img, Rect2(rect.position, Vector2(rect.size.x, width)), color) # top
	_stamp_rect_fill(img, Rect2(rect.position + Vector2(0, rect.size.y - width), Vector2(rect.size.x, width)), color) # bottom
	_stamp_rect_fill(img, Rect2(rect.position, Vector2(width, rect.size.y)), color) # left
	_stamp_rect_fill(img, Rect2(rect.position + Vector2(rect.size.x - width, 0), Vector2(width, rect.size.y)), color) # right


func _stamp_line(img: Image, from: Vector2, to: Vector2, width: float, color: Color) -> void:
	var min_x := maxi(int(floor(minf(from.x, to.x) - width)), 0)
	var max_x := mini(int(ceil(maxf(from.x, to.x) + width)), img.get_width())
	var min_y := maxi(int(floor(minf(from.y, to.y) - width)), 0)
	var max_y := mini(int(ceil(maxf(from.y, to.y) + width)), img.get_height())
	var seg: Vector2 = to - from
	var seg_len2: float = maxf(seg.length_squared(), 0.0001)
	for x in range(min_x, max_x):
		for y in range(min_y, max_y):
			var p := Vector2(x + 0.5, y + 0.5)
			var t: float = clampf((p - from).dot(seg) / seg_len2, 0.0, 1.0)
			var closest: Vector2 = from + seg * t
			if p.distance_to(closest) <= width * 0.5:
				img.set_pixel(x, y, color)


func _make_icon_texture(icon_name: String, sz: int, color: Color) -> ImageTexture:
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var o := Vector2(sz, sz) * 0.5
	var s := float(sz)
	var w: float = maxf(s * 0.1, 1.5)
	match icon_name:
		"view":
			_stamp_ring(img, o, s * 0.32, w, color)
			_stamp_disc(img, o, s * 0.09, color)
		"assembly":
			_stamp_rect_outline(img, Rect2(o + Vector2(-s * 0.30, -s * 0.12), Vector2(s * 0.42, s * 0.42)), w, color)
			_stamp_rect_outline(img, Rect2(o + Vector2(-s * 0.12, -s * 0.30), Vector2(s * 0.42, s * 0.42)), w, color)
		"windows":
			var r := Rect2(o + Vector2(-s * 0.36, -s * 0.30), Vector2(s * 0.72, s * 0.60))
			_stamp_rect_outline(img, r, w, color)
			_stamp_line(img, r.position + Vector2(0, s * 0.16), r.position + Vector2(r.size.x, s * 0.16), w, color)
		"files":
			_stamp_rect_outline(img, Rect2(o + Vector2(-s * 0.34, -s * 0.20), Vector2(s * 0.68, s * 0.50)), w, color)
			_stamp_rect_outline(img, Rect2(o + Vector2(-s * 0.34, -s * 0.30), Vector2(s * 0.32, s * 0.14)), w, color)
		"settings":
			_stamp_ring(img, o, s * 0.26, w, color)
			_stamp_disc(img, o, s * 0.08, color)
			for i in 8:
				var a: float = TAU * float(i) / 8.0
				var dir := Vector2(cos(a), sin(a))
				_stamp_line(img, o + dir * s * 0.34, o + dir * s * 0.45, w, color)
		"scene_light":
			_stamp_disc(img, o, s * 0.20, color)
			for i in 8:
				var a: float = TAU * float(i) / 8.0
				var dir := Vector2(cos(a), sin(a))
				_stamp_line(img, o + dir * s * 0.30, o + dir * s * 0.42, w, color)
		"scene_dark":
			_stamp_disc(img, o, s * 0.22, color)
			_stamp_disc(img, o + Vector2(s * 0.28, -s * 0.24), s * 0.05, color)
			_stamp_disc(img, o + Vector2(-s * 0.30, -s * 0.12), s * 0.035, color)
			_stamp_disc(img, o + Vector2(s * 0.14, s * 0.28), s * 0.04, color)
		"scene_mid":
			_stamp_ring(img, o, s * 0.28, w, color)
			_stamp_rect_fill(img, Rect2(o + Vector2(-s * 0.28, -s * 0.28), Vector2(s * 0.28, s * 0.56)), color)
		"scene_passthrough":
			_stamp_ring(img, o + Vector2(-s * 0.17, 0), s * 0.16, w, color)
			_stamp_ring(img, o + Vector2(s * 0.17, 0), s * 0.16, w, color)
			_stamp_line(img, o + Vector2(-s * 0.02, 0), o + Vector2(s * 0.02, 0), w, color)
		_:
			_stamp_ring(img, o, s * 0.28, w, color)
	return ImageTexture.create_from_image(img)


## A toggle button with a real icon + real text, side by side via Godot's
## own native Button layout (Button.text stays real text, not folded into a
## drawn/child-Control label — buttons found by their text, e.g. tests/*.gd
## and screen readers alike, still work exactly as before).
func _build_icon_button(label_text: String, icon_name: String, accent: Color, min_width: float = 120.0) -> Button:
	var btn := Button.new()
	btn.text = label_text
	btn.icon = _make_icon_texture(icon_name, 24, accent)
	btn.toggle_mode = true
	btn.custom_minimum_size = Vector2(min_width, 46)
	btn.clip_text = true
	return btn


# --- Navigate (View category): the brief's three manipulation modes,
# switchable on their own. Steadiness moved to the Settings cogwheel — it's
# a set-and-forget comfort setting, not something toggled mid-task like
# these three are.

func _build_navigate_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	page.add_child(_mode_toggle("Model movement", func(on: bool) -> void: _two_hand.enabled = on))
	page.add_child(_mode_toggle("User movement", func(on: bool) -> void: _locomotion.enabled = on))
	page.add_child(_mode_toggle("Part manipulation", func(on: bool) -> void:
		_left.set_parts_enabled(on)
		_right.set_parts_enabled(on)
	))
	page.add_child(_build_speed_row())
	var hint := Label.new()
	hint.text = "Scale views: see View > Scale. Steadiness: the Settings cogwheel."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)
	return page


func _build_speed_row() -> Control:
	## Travel speed: how fast the LEFT thumbstick walks you. The bottom of the
	## slider is the original walking pace and the default, so nothing changes
	## until you push it up to cross a large open space (a house's grounds, a
	## small village). Exponential (locomotion.gd's set_speed_fraction()).
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_speed_label = Label.new()
	box.add_child(_speed_label)
	_speed_slider = _make_slider(0.0, 1.0, 0.01)
	_speed_slider.value = _locomotion.speed_fraction()
	_speed_slider.value_changed.connect(func(value: float) -> void:
		_locomotion.set_speed_fraction(value)
		_refresh_speed_label()
	)
	box.add_child(_speed_slider)
	var ends := HBoxContainer.new()
	var low := Label.new()
	low.text = "Walking"
	low.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var high := Label.new()
	high.text = "Village"
	for end_label in [low, high]:
		end_label.add_theme_font_size_override("font_size", 16)
		end_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	ends.add_child(low)
	ends.add_child(high)
	box.add_child(ends)
	_refresh_speed_label()
	return box


func _refresh_speed_label() -> void:
	if _speed_label == null or _locomotion == null:
		return
	_speed_label.text = "Travel speed: %.1f m/s  (%.0f× walking)" % [_locomotion.move_speed, _locomotion.move_speed / _locomotion.min_move_speed]


func _make_slider(min_value: float, max_value: float, step: float) -> HSlider:
	## A slider readable and grabbable at arm's length: a fat track and a big
	## round knob (Godot's default knob is a few pixels).
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.scrollable = false
	slider.custom_minimum_size = Vector2(0, 52)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.16, 0.19, 0.24)
	track.set_corner_radius_all(6)
	track.content_margin_top = 6
	track.content_margin_bottom = 6
	var filled := StyleBoxFlat.new()
	filled.bg_color = Color(0.15, 0.55, 0.68)
	filled.set_corner_radius_all(6)
	filled.content_margin_top = 6
	filled.content_margin_bottom = 6
	var filled_hot := filled.duplicate() as StyleBoxFlat
	filled_hot.bg_color = Color(0.3, 0.75, 0.9)
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", filled)
	slider.add_theme_stylebox_override("grabber_area_highlight", filled_hot)
	var knob := _make_knob_texture(40, Color(0.85, 0.93, 1.0))
	var knob_hot := _make_knob_texture(40, Color(1.0, 1.0, 1.0))
	slider.add_theme_icon_override("grabber", knob)
	slider.add_theme_icon_override("grabber_highlight", knob_hot)
	slider.add_theme_icon_override("grabber_disabled", knob)
	_sliders.append(slider)
	return slider


static func _make_knob_texture(diameter: int, color: Color) -> ImageTexture:
	var img := Image.create(diameter, diameter, false, Image.FORMAT_RGBA8)
	var c := (diameter - 1) * 0.5
	var radius := diameter * 0.5 - 1.0
	for y in diameter:
		for x in diameter:
			var d := Vector2(x - c, y - c).length()
			if d <= radius:
				var edge := clampf(radius - d, 0.0, 1.0) # 1px antialiased rim
				var shade := color if d < radius - 3.0 else color.darkened(0.35)
				img.set_pixel(x, y, Color(shade.r, shade.g, shade.b, edge))
	return ImageTexture.create_from_image(img)


func _slider_at(px: Vector2) -> bool:
	for slider in _sliders:
		if slider.is_visible_in_tree() and Rect2(slider.global_position, slider.size).has_point(px):
			return true
	return false


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


# --- Visibility (View category): assembly tools from the vision brief's
# "Assembly tools" list ---

func _build_visibility_page() -> Control:
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

	# Grounding: a grounded (fixed) part that has mates can't be moved while
	# mates are enforced — it's the anchor the others are solved against. This
	# flips the laser-selected part between grounded and floating (the same
	# Fix/Float the flat app has), so YOU choose which part is the anchor.
	var fix_button := Button.new()
	fix_button.text = "Fix / Float selected part"
	fix_button.pressed.connect(func() -> void:
		if _mates_tool:
			_mates_tool.toggle_fixed(_main.current_selected_part())
	)
	page.add_child(fix_button)

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
	, {"mode": "full", "title": "Custom colour, e.g. #3a7bd5 (0-9, a-f)", "confirm_label": "Set"})


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


# --- Measure: milestone 4's last assembly tool - laser-pick 1-2 entities,
# live result from measure_tool.gd's real POST .../measure client. No
# create step (unlike Mates) and nothing to relax/enforce - see that
# script's own docstring.

func _build_measure_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	page.add_child(_mode_toggle("Measure tool", func(on: bool) -> void:
		_left.measure_tool_active = on
		_right.measure_tool_active = on
		if _measure_tool:
			_measure_tool.set_active(on)
	, false))

	_measure_status_label = Label.new()
	_measure_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_measure_status_label)

	_measure_picks_label = Label.new()
	_measure_picks_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_measure_picks_label.add_theme_font_size_override("font_size", 18)
	_measure_picks_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(_measure_picks_label)

	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(func() -> void:
		if _measure_tool:
			_measure_tool.clear_picks()
	)
	page.add_child(clear)

	var result_label := Label.new()
	result_label.text = "Result:"
	result_label.add_theme_font_size_override("font_size", 18)
	result_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(result_label)
	_measure_result_box = VBoxContainer.new()
	_measure_result_box.add_theme_constant_override("separation", 2)
	page.add_child(_measure_result_box)

	_refresh_measure_picks_display()
	_rebuild_measure_result()
	return page


func _refresh_measure_picks_display() -> void:
	if not _measure_tool or _measure_status_label == null:
		return
	_measure_status_label.text = _measure_tool.status_text()
	var labels: Array = _measure_tool.picked_labels()
	_measure_picks_label.text = "Picked: %s" % (", ".join(labels) if not labels.is_empty() else "none")


# Row order/labels/formatting deliberately match the flat app's own
# MeasurementPanel._resultRows exactly (client/lib/viewport3d/
# measurement_panel.dart) - a user moving between VR and flat sees the same
# numbers laid out the same way. Named two-entity results (axis/normal
# distance) are shown ahead of, never instead of, the generic distance -
# both stay meaningful together (e.g. the gap between two coaxial
# cylindrical faces is still worth showing alongside its axis distance).
func _rebuild_measure_result() -> void:
	if _measure_result_box == null:
		return
	for child in _measure_result_box.get_children():
		_measure_result_box.remove_child(child)
		child.queue_free()

	var r: Dictionary = _measure_tool.result if _measure_tool else {}
	var rows: Array = []
	if r.get("length") != null:
		rows.append(["Length", _fmt_measure_unit(r["length"], "mm")])
	if r.get("diameter") != null:
		rows.append(["Diameter", _fmt_measure_unit(r["diameter"], "mm")])
	if r.get("radius") != null:
		rows.append(["Radius", _fmt_measure_unit(r["radius"], "mm")])
	if r.get("area") != null:
		rows.append(["Area", _fmt_measure_unit(r["area"], "mm²")])
	if r.get("point") != null:
		rows.append(["Point", _fmt_measure_vec_unit(r["point"], "mm")])
	if r.get("axis_distance") != null:
		rows.append(["Axis distance", _fmt_measure_unit(r["axis_distance"], "mm")])
	if r.get("normal_distance") != null:
		rows.append(["Normal distance", _fmt_measure_unit(r["normal_distance"], "mm")])
	if r.get("distance") != null:
		rows.append(["Distance", _fmt_measure_unit(r["distance"], "mm")])
	if r.get("delta") != null:
		rows.append(["ΔX, ΔY, ΔZ", _fmt_measure_vec_unit(r["delta"], "mm")])

	var body_volumes: Dictionary = r.get("body_volumes", {})
	var body_masses: Dictionary = r.get("body_masses", {})
	var multi_body: bool = body_volumes.size() > 1
	var i := 0
	for body_id in body_volumes:
		i += 1
		rows.append(["Volume%s" % (" (body %d)" % i if multi_body else ""), _fmt_measure_unit(body_volumes[body_id], "mm³")])
	i = 0
	for body_id in body_masses:
		i += 1
		rows.append(["Mass%s" % (" (body %d)" % i if multi_body else ""), _fmt_measure_unit(body_masses[body_id], "g")])

	for row in rows:
		var hbox := HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 6)
		var label := Label.new()
		label.text = row[0]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(label)
		var value := Label.new()
		value.text = row[1]
		hbox.add_child(value)
		_measure_result_box.add_child(hbox)
	if rows.is_empty():
		var none := Label.new()
		none.text = "No measurements yet."
		_measure_result_box.add_child(none)


static func _fmt_measure_num(x: float) -> String:
	return ("%.3f" % x).rstrip("0").rstrip(".")


static func _fmt_measure_unit(x: float, unit: String) -> String:
	return "%s %s" % [_fmt_measure_num(x), unit]


static func _fmt_measure_vec_unit(v: Array, unit: String) -> String:
	var parts := []
	for x in v:
		parts.append(_fmt_measure_num(x))
	return "%s %s" % [", ".join(parts), unit]


# --- Windows: milestone 3's floating windows - the Assembly Tree (browse
# and select occurrences without laser-pointing at their geometry - see
# assembly_tree_window.gd's own docstring), a Calculator and an Image
# Viewer. Each is its own free-floating diegetic_panel.gd panel, spawned in
# front of the camera the first time it's opened, and can be open at the
# same time as any of the others (and this tablet) - see docs/status.md's
# "Floating windows" section for the framework this is built on.

func _build_windows_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	if _assembly_tree_window:
		page.add_child(_window_toggle_button("Assembly Tree", _assembly_tree_window))
	if _calculator_window:
		page.add_child(_window_toggle_button("Calculator", _calculator_window))
	# Image Viewer and Browser: several can be open at once — the button opens
	# one (the first press) and another with every further press. Each has its
	# own close (X); closing one leaves the rest.
	if _image_viewer_window:
		var image_button := Button.new()
		image_button.text = "Image Viewer"
		image_button.pressed.connect(func() -> void: _main.open_window("image"))
		page.add_child(image_button)
	if _browser_window:
		var browser_button := Button.new()
		browser_button.text = "Browser"
		browser_button.pressed.connect(func() -> void: _main.open_window("browser"))
		page.add_child(browser_button)

	var hint := Label.new()
	hint.text = "Each window opens in front of you and has its own close (X). Image Viewer and Browser: press again for another window."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)
	return page


func _window_toggle_button(label: String, window: Node) -> Button:
	## A plain (non-toggle-mode) button that just calls window.toggle() each
	## press - deliberately not a toggle button, since the window can also
	## be closed by its own "X" (see diegetic_panel.gd), and keeping a
	## separate toggle-button's pressed-state in sync with that would need
	## its own polling; a plain button sidesteps that entirely.
	var button := Button.new()
	button.text = label
	button.pressed.connect(window.toggle)
	return button


# --- Files: load a local .glb ---

func _build_files_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	var hint := Label.new()
	hint.text = "Loads from res://models, user://models, and the Settings cogwheel's project folder."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)
	# Real-headset feedback: "Add" (and Open/import) failing silently — the
	# only feedback main.gd's own load/add/import functions ever gave was
	# _set_status()'s console print, invisible in a headset (see that
	# function's own docstring: no floating 3D text, deliberately, per
	# earlier feedback that it was distracting). "Add" needing a configured
	# backend in particular has no other symptom at all otherwise — from
	# inside the headset, clicking it with no secrets.cfg just does nothing.
	_files_status_label = Label.new()
	_files_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_files_status_label.add_theme_font_size_override("font_size", 16)
	_files_status_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
	page.add_child(_files_status_label)
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
		none.text = "No model files found.\nPut a .glb/.gltf/.didsa/.step/.stl/.obj in the project's models folder."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_files_box.add_child(none)
	var loaded_root: String = _main.current_root_part_id()
	var assembly_loaded: bool = not loaded_root.is_empty()
	for path in files: # every file — the tablet scrolls (right thumbstick over it) instead of capping the list at 5
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var button := Button.new()
		button.text = path.get_file()
		button.clip_text = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_main.load_model_file.bind(path))
		row.add_child(button)
		# Native files get a second "Add" action alongside the row's normal
		# tap-to-open one — merges this file's own Part as a new component
		# of whichever assembly is currently loaded (main.gd's
		# add_component_file()), rather than replacing it. Only meaningful
		# once something backend-hosted is already loaded to add onto.
		# Not offered on the file that IS the loaded root: the backend rejects
		# that with 422 "Cannot insert a Part into itself".
		if path.get_extension().to_lower() in ["didsa", "didsaprt"] and assembly_loaded and _main.native_file_root_part_id(path) != loaded_root:
			var add_button := Button.new()
			add_button.text = "Add"
			add_button.tooltip_text = "Add this file's Part to the loaded assembly"
			add_button.pressed.connect(_main.add_component_file.bind(path))
			row.add_child(add_button)
		_files_box.add_child(row)
	var refresh := Button.new()
	refresh.text = "Refresh list"
	refresh.pressed.connect(_rebuild_files)
	_files_box.add_child(refresh)


# --- Environment (View category): Light/Dark/Mid rendered presets plus
# Passthrough (OpenXR mixed reality) — see environment_manager.gd, which
# owns the actual WorldEnvironment/DirectionalLight3D/passthrough switch.

const _SCENE_ICONS := {
	"Light": "scene_light", "Dark": "scene_dark", "Mid": "scene_mid", "Passthrough": "scene_passthrough",
}

func _build_environment_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)

	var hint := Label.new()
	hint.text = "How the room around the model looks — pick a rendered backdrop, or step into mixed reality."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)

	var scenes: Array = _main.available_scenes()
	var current: String = _main.current_scene()
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	page.add_child(grid)

	var group := ButtonGroup.new()
	for scene_name in scenes:
		var btn := _build_icon_button(scene_name, _SCENE_ICONS.get(scene_name, "scene_mid"), _CATEGORY_ACCENTS["View"], 140.0)
		btn.button_group = group
		btn.button_pressed = (scene_name == current)
		btn.toggled.connect(_on_scene_toggled.bind(scene_name))
		grid.add_child(btn)

	_environment_status_label = Label.new()
	_environment_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_environment_status_label.add_theme_font_size_override("font_size", 18)
	_environment_status_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(_environment_status_label)
	_refresh_environment_status()
	return page


func _on_scene_toggled(on: bool, scene_name: String) -> void:
	if on:
		_main.set_scene(scene_name)
		_refresh_environment_status()


func _refresh_environment_status() -> void:
	if not _environment_status_label:
		return
	if _main.current_scene() == "Passthrough":
		_environment_status_label.text = _main.passthrough_status() # says whether it's on and, if not, what the runtime offers
	else:
		_environment_status_label.text = "Scene: %s" % _main.current_scene()


# --- Settings (corner cogwheel): set-and-forget stuff — Steadiness, display
# quality and the perf readout that goes with it, and the project folder
# the Files tab scans. Deliberately separate from the main category rail
# (see _build_ui()) since none of this is touched mid-task.

func _build_settings_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)

	var hint := Label.new()
	hint.text = "Set-and-forget: steadiness, display quality and where the Files tab looks for models."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(hint)

	page.add_child(_choice_row("Steadiness (hold-still shake)", _two_hand.STEADINESS_NAMES, _two_hand.steadiness,
		func(i: int) -> void:
			_two_hand.set_steadiness(i) # whole-model moves
			_left.set_steadiness(i) # a single held part (grip), each hand
			_right.set_steadiness(i)
			if _section_tool:
				_section_tool.set_steadiness(i) # the section-plane gizmo, grabbed the same way
	))

	var display_heading := Label.new()
	display_heading.text = "Display"
	display_heading.add_theme_font_size_override("font_size", 18)
	display_heading.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(display_heading)

	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 18)
	_info_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
	page.add_child(_info_label)

	page.add_child(_mode_toggle("Shadows", func(on: bool) -> void: _main.set_shadows(on)))
	page.add_child(_choice_row("Resolution", ["100%", "80%", "65%"], 0,
		func(i: int) -> void: _main.set_render_scale([1.0, 0.8, 0.65][i])))
	page.add_child(_choice_row("MSAA", ["Off", "2x", "4x"], 1,
		func(i: int) -> void: _main.set_msaa(i)))

	var files_heading := Label.new()
	files_heading.text = "Project folder"
	files_heading.add_theme_font_size_override("font_size", 18)
	files_heading.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	page.add_child(files_heading)

	_project_folder_label = Label.new()
	_project_folder_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_project_folder_label)
	_refresh_project_folder_label()

	var folder_row := HBoxContainer.new()
	folder_row.add_theme_constant_override("separation", 8)
	page.add_child(folder_row)
	var set_folder := Button.new()
	set_folder.text = "Set folder…"
	set_folder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_folder.pressed.connect(_on_set_project_folder_pressed)
	folder_row.add_child(set_folder)
	var clear_folder := Button.new()
	clear_folder.text = "Clear"
	clear_folder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_folder.pressed.connect(_on_clear_project_folder_pressed)
	folder_row.add_child(clear_folder)

	return page


func _on_set_project_folder_pressed() -> void:
	_main.open_keyboard_for(_main.project_folder(), func(text: String) -> void:
		_main.set_project_folder(text.strip_edges())
		_refresh_project_folder_label()
	, {"mode": "full", "title": "Project folder (absolute path)", "confirm_label": "Set"})


func _on_clear_project_folder_pressed() -> void:
	_main.set_project_folder("")
	_refresh_project_folder_label()


func _refresh_project_folder_label() -> void:
	if not _project_folder_label:
		return
	var path: String = _main.project_folder()
	_project_folder_label.text = "Scanning: %s" % path if not path.is_empty() else "Scanning res://models and user://models only — no project folder set."


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
