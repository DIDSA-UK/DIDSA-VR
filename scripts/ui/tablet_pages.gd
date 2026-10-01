extends RefCounted
## Every page the redesigned tablet shows, and the registration that puts them in
## the category grid / tool rail (scripts/ui/tablet_registry.gd). Ported from
## wrist_tablet.gd's page builders with the same behaviour and the same calls into
## main.gd and the tools, restyled through the UI theme (type variations, no
## hand-set sizes/colours) and trimmed where the new shell now does the job:
##   * a mode tool's on/off lives in the tool header (tool_manager.gd), not on its page;
##   * status text lives in the status bar (ToolDef.status_provider), not on each page;
##   * lists (existing mates, measurement results, model files) live in the side
##     panel (ToolDef.list_provider), not at the bottom of a scrolling page.
## The old tablet keeps its own copy of all this until it is deleted (Phase 4).
##
## ctx (Dictionary) wires the real thing in; the UI Lab passes a stub:
##   left, right, camera, two_hand, locomotion, main, command_stack, mates_tool,
##   colour_tool, section_tool, measure_tool, assembly_tree_window,
##   calculator_window, image_viewer_window, browser_window,
##   dragging: Callable() -> bool  (true while the laser is dragging a slider)

signal toast(text: String, kind: String)

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const MATE_TYPE_LABELS: Array[String] = ["Coincident", "Concentric", "Parallel", "Distance", "Angle"]
const COLOUR_SWATCHES: Array[Dictionary] = [
	{"name": "Red", "hex": "#e63946"}, {"name": "Orange", "hex": "#f4a340"},
	{"name": "Yellow", "hex": "#f1c40f"}, {"name": "Green", "hex": "#2ecc71"},
	{"name": "Blue", "hex": "#3498db"}, {"name": "Purple", "hex": "#9b59b6"},
	{"name": "White", "hex": "#f5f5f5"}, {"name": "Black", "hex": "#222222"},
]
const SCENE_ICONS := {"Light": "scene_light", "Dark": "scene_dark", "Mid": "scene_mid", "Passthrough": "scene_passthrough"}
const ACCENT_VIEW := Color(0.35, 0.78, 0.95)
const ACCENT_ASSEMBLY := Color(0.95, 0.72, 0.35)
const ACCENT_WINDOWS := Color(0.72, 0.60, 0.95)
const ACCENT_FILES := Color(0.50, 0.85, 0.60)

var tokens: Resource
var manager

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
var _dragging: Callable = Callable()

var _scale_label: Label
var _lock_button: Button
var _speed_label: Label
var _speed_slider: HSlider
var _mates_picks_label: Label
var _mates_value_label: Label
var _mates_create_button: Button
var _mates_relax_button: Button
var _mates_last_owner_part_id := ""
var _measure_picks_label: Label
var _colour_group_toggle: Button
var _environment_status_label: Label
var _project_folder_label: Label
var _info_label: Label
var _files_count_label: Label
var _files_cache: Array = [] ## [{path, native, root_id}] — scanned on select/Refresh, never per frame (a project folder may be a network mount)


func setup(ctx: Dictionary, p_tokens: Resource, p_manager) -> void:
	tokens = p_tokens
	manager = p_manager
	_left = ctx.get("left")
	_right = ctx.get("right")
	_camera = ctx.get("camera")
	_two_hand = ctx.get("two_hand")
	_locomotion = ctx.get("locomotion")
	_main = ctx.get("main")
	_command_stack = ctx.get("command_stack")
	_mates_tool = ctx.get("mates_tool")
	_colour_tool = ctx.get("colour_tool")
	_section_tool = ctx.get("section_tool")
	_measure_tool = ctx.get("measure_tool")
	_assembly_tree_window = ctx.get("assembly_tree_window")
	_calculator_window = ctx.get("calculator_window")
	_image_viewer_window = ctx.get("image_viewer_window")
	_browser_window = ctx.get("browser_window")
	_dragging = ctx.get("dragging", Callable())


func register(reg) -> void:
	reg.add_category("view", "View", "view", ACCENT_VIEW)
	reg.add_tool("view", "navigate", "Navigate", "navigate", _build_navigate_page, {
		"help": "Switch model movement, user movement and part manipulation on or off. Travel speed sets how fast the left stick walks you."})
	reg.add_tool("view", "scale", "Scale", "scale", _build_scale_page, {
		"help": "Jump to a preset scale about the model's centre. Fit to view brings the whole model in front of you; Home returns it to where it loaded. For an exact value, click the right thumbstick."})
	reg.add_tool("view", "visibility", "Visibility", "visibility", _build_visibility_page, {
		"help": "Hide or show every part at once, flip which parts are hidden, or isolate the selected part. All undoable."})
	reg.add_tool("view", "shoot_hide", "Shoot hide", "shoot_hide", _build_shoot_hide_page, {
		"kind": "mode", "on_activate": _set_shoot_hide.bind(true), "on_deactivate": _set_shoot_hide.bind(false),
		"hint": "Point at a part and pull the right trigger to hide it.",
		"help": "Switch the tool on, then point the right laser at a part and pull the trigger to hide it. Undo brings it back."})
	reg.add_tool("view", "environment", "Environment", "environment", _build_environment_page, {
		"help": "How the room around the model looks: a rendered backdrop, or step into mixed reality (Passthrough)."})

	reg.add_category("assembly", "Assembly", "assembly", ACCENT_ASSEMBLY)
	reg.add_tool("assembly", "mates", "Mates", "mates", _build_mates_page, {
		"kind": "mode", "on_activate": _set_mates.bind(true), "on_deactivate": _set_mates.bind(false),
		"on_select": _on_mates_selected, "status": _mates_status, "list": _mates_rows, "list_empty": "No mates yet.",
		"help": "Switch the tool on, laser-target a face on one part, then a face on a different part. Choose a type (Distance and Angle take a value), then Create mate."})
	reg.add_tool("assembly", "colours", "Colours", "colours", _build_colours_page, {
		"status": _colour_status,
		"help": "Laser-select a part first, then tap a swatch. Apply to whole group colours every occurrence sharing its owner. Not undoable: pick another colour or Clear."})
	reg.add_tool("assembly", "sections", "Sections", "sections", _build_sections_page, {
		"kind": "mode", "on_activate": _set_sections.bind(true), "on_deactivate": _set_sections.bind(false), "status": _sections_status,
		"help": "Switch the tool on to place a clip plane in front of you. Grip the plane to move or tilt it, like grabbing a part. Flip swaps the side that stays."})
	reg.add_tool("assembly", "measure", "Measure", "measure", _build_measure_page, {
		"kind": "mode", "on_activate": _set_measure.bind(true), "on_deactivate": _set_measure.bind(false),
		"status": _measure_status, "list": _measure_rows, "list_empty": "No measurements yet.",
		"help": "Switch the tool on, then pick a vertex, edge or face. A second pick compares the two; a third starts again. Results show beside the tablet."})

	reg.add_category("windows", "Windows", "windows", ACCENT_WINDOWS)
	reg.add_tool("windows", "windows", "Windows", "windows", _build_windows_page, {
		"help": "Open floating windows. Each opens in front of you with its own close button, grab handle and resize corners."})

	reg.add_category("files", "Files", "files", ACCENT_FILES)
	reg.add_tool("files", "models", "Models", "models", _build_files_page, {
		"on_select": _rescan_files, "status": _files_status, "list": _files_rows, "list_empty": "No model files found.",
		"help": "Open loads a model in place of the current one. Add merges a native file into the loaded assembly. Needs a configured backend for STEP, STL and OBJ."})


func refresh() -> void:
	## Called ~4 times a second while the tablet is open: live labels and states.
	if _scale_label and _two_hand:
		_scale_label.text = _two_hand.scale_text()
		_lock_button.set_pressed_no_signal(_two_hand.scale_locked)
		_lock_button.text = "Scale lock: %s" % ("ON" if _two_hand.scale_locked else "off")
	if _speed_slider and _locomotion and not (_dragging.is_valid() and _dragging.call()):
		_speed_slider.set_value_no_signal(_locomotion.speed_fraction())
		_refresh_speed_label()
	if _mates_picks_label and _mates_tool:
		var labels: Array = _mates_tool.picked_labels()
		_mates_picks_label.text = "Picked: %s" % (", ".join(labels) if not labels.is_empty() else "none")
		_mates_create_button.disabled = not _mates_tool.can_create()
	if _measure_picks_label and _measure_tool:
		var m: Array = _measure_tool.picked_labels()
		_measure_picks_label.text = "Picked: %s" % (", ".join(m) if not m.is_empty() else "none")


func set_info(text: String) -> void:
	if _info_label:
		_info_label.text = text


# --- Mode tool switches -------------------------------------------------------

func _set_shoot_hide(on: bool) -> void:
	_left.hide_tool_active = on
	_right.hide_tool_active = on


func _set_mates(on: bool) -> void:
	_left.mates_tool_active = on
	_right.mates_tool_active = on
	if _mates_tool:
		_mates_tool.set_active(on)


func _set_sections(on: bool) -> void:
	if _section_tool:
		_section_tool.set_active(on, _camera)


func _set_measure(on: bool) -> void:
	_left.measure_tool_active = on
	_right.measure_tool_active = on
	if _measure_tool:
		_measure_tool.set_active(on)


# --- Small widget helpers -----------------------------------------------------

func _page(separation: int = -1) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", tokens.gap + 2 if separation < 0 else separation)
	return page


func _hint(text: String, small: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = &"LabelSmall" if small else &"LabelDim"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _button(text: String, callback: Callable, variation: StringName = &"") -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if variation != &"":
		b.theme_type_variation = variation
	b.pressed.connect(callback)
	return b


func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", tokens.gap)
	return r


func _mode_toggle(label: String, apply: Callable, default_on: bool = true) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_pressed = default_on
	button.custom_minimum_size = Vector2(0, 56)
	button.text = "%s: %s" % [label, "ON" if default_on else "off"]
	button.toggled.connect(func(on: bool) -> void:
		button.text = "%s: %s" % [label, "ON" if on else "off"]
		apply.call(on)
	)
	return button


func _choice_row(title: String, options: Array, selected: int, on_pick: Callable) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_hint(title))
	var row := _row()
	box.add_child(row)
	var group := ButtonGroup.new()
	for i in options.size():
		var button := Button.new()
		button.text = str(options[i])
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(0, 56)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.button_pressed = (i == selected)
		button.pressed.connect(on_pick.bind(i))
		row.add_child(button)
	return box


func _make_slider(min_value: float, max_value: float, step: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.scrollable = false
	slider.custom_minimum_size = Vector2(0, 52)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return slider


# --- View: Navigate -------------------------------------------------------------

func _build_navigate_page() -> Control:
	var page := _page()
	page.add_child(_mode_toggle("Model movement", func(on: bool) -> void: _two_hand.enabled = on))
	page.add_child(_mode_toggle("User movement", func(on: bool) -> void: _locomotion.enabled = on))
	page.add_child(_mode_toggle("Part manipulation", func(on: bool) -> void:
		_left.set_parts_enabled(on)
		_right.set_parts_enabled(on)
	))
	page.add_child(_build_speed_row())
	page.add_child(_hint("Scale views: View > Scale. Steadiness: the Settings button."))
	return page


func _build_speed_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_speed_label = _hint("")
	box.add_child(_speed_label)
	_speed_slider = _make_slider(0.0, 1.0, 0.01)
	if _locomotion:
		_speed_slider.value = _locomotion.speed_fraction()
	_speed_slider.value_changed.connect(func(value: float) -> void:
		if _locomotion:
			_locomotion.set_speed_fraction(value)
		_refresh_speed_label()
	)
	box.add_child(_speed_slider)
	var ends := HBoxContainer.new()
	var low := _hint("Walking", true)
	low.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(low)
	ends.add_child(_hint("Village", true))
	box.add_child(ends)
	_refresh_speed_label()
	return box


func _refresh_speed_label() -> void:
	if _speed_label == null or _locomotion == null:
		return
	_speed_label.text = "Travel speed: %.1f m/s  (%.0f× walking)" % [_locomotion.move_speed, _locomotion.move_speed / _locomotion.min_move_speed]


# --- View: Scale ------------------------------------------------------------------

func _build_scale_page() -> Control:
	var page := _page()
	_scale_label = Label.new()
	page.add_child(_scale_label)
	var presets := HFlowContainer.new()
	presets.add_theme_constant_override("h_separation", tokens.gap)
	presets.add_theme_constant_override("v_separation", tokens.gap)
	page.add_child(presets)
	if _two_hand:
		for multiple in _two_hand.presets:
			var b := Button.new()
			b.text = _ratio_text(multiple)
			b.custom_minimum_size = Vector2(96, 56)
			b.pressed.connect(_two_hand.set_preset.bind(multiple))
			presets.add_child(b)
	_lock_button = Button.new()
	_lock_button.toggle_mode = true
	_lock_button.custom_minimum_size = Vector2(0, 56)
	_lock_button.toggled.connect(func(on: bool) -> void:
		if _two_hand:
			_two_hand.scale_locked = on
	)
	page.add_child(_lock_button)
	var view_row := _row()
	page.add_child(view_row)
	view_row.add_child(_button("Fit to view", func() -> void: _two_hand.fit_to_view(_camera)))
	view_row.add_child(_button("Home", func() -> void: _two_hand.go_home()))
	return page


func _ratio_text(multiple: float) -> String:
	return "%s:1" % _trim(multiple) if multiple >= 1.0 else "1:%s" % _trim(1.0 / multiple)


func _trim(x: float) -> String:
	return ("%.2f" % x).rstrip("0").rstrip(".")


# --- View: Visibility and Shoot hide ------------------------------------------------

func _build_visibility_page() -> Control:
	var page := _page()
	var row := _row()
	page.add_child(row)
	row.add_child(_button("Hide all", func() -> void: _main.hide_all_parts()))
	row.add_child(_button("Show all", func() -> void: _main.show_all_parts()))
	page.add_child(_button("Reverse visibility", func() -> void: _main.reverse_visibility()))
	page.add_child(_button("Isolate selected", func() -> void: _main.isolate_selected()))
	page.add_child(_hint("To hide parts by pointing at them, use Shoot hide."))
	return page


func _build_shoot_hide_page() -> Control:
	var page := _page()
	page.add_child(_hint("Switch the tool on (top right), then point the right laser at a part and pull the trigger to hide it. A hidden part is click-through for the laser and grip. Undo brings it back."))
	return page


# --- View: Environment --------------------------------------------------------------

func _build_environment_page() -> Control:
	var page := _page()
	page.add_child(_hint("How the room around the model looks: pick a rendered backdrop, or step into mixed reality."))
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", tokens.gap)
	grid.add_theme_constant_override("v_separation", tokens.gap)
	page.add_child(grid)
	var group := ButtonGroup.new()
	var current: String = _main.current_scene() if _main else ""
	for scene_name in (_main.available_scenes() if _main else []):
		var b := Button.new()
		b.text = scene_name
		b.icon = UiIcons.texture(SCENE_ICONS.get(scene_name, "scene_mid"), 28)
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(150, 56)
		b.button_pressed = (scene_name == current)
		b.toggled.connect(func(on: bool) -> void:
			if on:
				_main.set_scene(scene_name)
				_refresh_environment_status()
		)
		grid.add_child(b)
	_environment_status_label = _hint("")
	page.add_child(_environment_status_label)
	_refresh_environment_status()
	return page


func _refresh_environment_status() -> void:
	if _environment_status_label == null or _main == null:
		return
	if _main.current_scene() == "Passthrough" and not _main.is_passthrough_supported():
		_environment_status_label.text = "Passthrough isn't supported on this headset/runtime — showing black instead of a camera feed."
	else:
		_environment_status_label.text = "Scene: %s" % _main.current_scene()


# --- Assembly: Mates ----------------------------------------------------------------

func _build_mates_page() -> Control:
	var page := _page(8)
	_mates_picks_label = _hint("")
	page.add_child(_mates_picks_label)
	page.add_child(_button("Clear picks", func() -> void:
		if _mates_tool:
			_mates_tool.clear_picks()
	))
	page.add_child(_choice_row("Mate type", MATE_TYPE_LABELS, 0, func(i: int) -> void:
		if _mates_tool:
			_mates_tool.mate_type = _mates_tool.MATE_TYPES[i]
	))
	var toggles := _row()
	page.add_child(toggles)
	var flip := Button.new()
	flip.text = "Flip"
	flip.toggle_mode = true
	flip.custom_minimum_size = Vector2(0, 56)
	flip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flip.toggled.connect(func(on: bool) -> void:
		if _mates_tool:
			_mates_tool.mate_flipped = on
	)
	toggles.add_child(flip)
	var allow_rot := Button.new()
	allow_rot.text = "Allow rotation"
	allow_rot.toggle_mode = true
	allow_rot.button_pressed = true
	allow_rot.custom_minimum_size = Vector2(0, 56)
	allow_rot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	allow_rot.toggled.connect(func(on: bool) -> void:
		if _mates_tool:
			_mates_tool.mate_allow_rotation = on
	)
	toggles.add_child(allow_rot)

	var value_row := _row()
	page.add_child(value_row)
	_mates_value_label = Label.new()
	_mates_value_label.text = "Value: 0 (distance mm / angle deg)"
	_mates_value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mates_value_label.clip_text = true
	value_row.add_child(_mates_value_label)
	var set_value := Button.new()
	set_value.text = "Set value"
	set_value.custom_minimum_size = Vector2(0, 56)
	set_value.pressed.connect(_on_set_mate_value_pressed)
	value_row.add_child(set_value)

	_mates_create_button = _button("Create mate", _on_create_mate_pressed, &"ButtonAccent")
	_mates_create_button.disabled = true
	page.add_child(_mates_create_button)

	var bulk := _row()
	page.add_child(bulk)
	_mates_relax_button = Button.new()
	_mates_relax_button.text = "Relax all: off"
	_mates_relax_button.toggle_mode = true
	_mates_relax_button.custom_minimum_size = Vector2(0, 56)
	_mates_relax_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mates_relax_button.toggled.connect(func(on: bool) -> void:
		_mates_relax_button.text = "Relax all: %s" % ("ON" if on else "off")
		if _mates_tool:
			_mates_tool.set_relaxed(on)
	)
	bulk.add_child(_mates_relax_button)
	bulk.add_child(_button("Enforce all", func() -> void:
		var owner_part_id: String = _main.current_root_part_id()
		if _mates_tool and owner_part_id != "":
			_mates_last_owner_part_id = owner_part_id
			_mates_tool.enforce_all(owner_part_id)
	))
	# A grounded (fixed) part that has mates can't be moved while mates are
	# enforced: it's the anchor the others are solved against. This flips the
	# laser-selected part between grounded and floating, so YOU choose the anchor.
	page.add_child(_button("Fix / Float selected part", func() -> void:
		if _mates_tool:
			_mates_tool.toggle_fixed(_main.current_selected_part())
	))
	return page


func _on_mates_selected() -> void:
	var owner_part_id: String = _main.current_root_part_id() if _main else ""
	if _mates_tool and owner_part_id != "":
		_mates_last_owner_part_id = owner_part_id
		_mates_tool.refresh_mates(owner_part_id)


func _mates_status() -> String:
	return _mates_tool.status_text() if _mates_tool else ""


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
		toast.emit("Couldn't create mate: %s" % result["error"], "error")


func _mates_rows() -> Array:
	var rows := []
	if _mates_tool == null:
		return rows
	for mate in _mates_tool.mates:
		var type_label: String = str(mate.get("type", "?")).capitalize()
		var has_value: bool = mate.get("value") != null
		var mate_id := str(mate.get("id", ""))
		rows.append({
			"id": mate_id,
			"title": "%s%s" % [type_label, (" (%s)" % _trim_mate_value(mate.get("value"))) if has_value else ""],
			"subtitle": "", "state": "normal",
			"actions": [{"label": "Delete", "danger": true, "confirm": true, "callback": _on_delete_mate_pressed.bind(mate_id)}],
		})
	return rows


func _on_delete_mate_pressed(mate_id: String) -> void:
	if _mates_tool and _mates_last_owner_part_id != "" and mate_id != "":
		await _mates_tool.delete_mate(_mates_last_owner_part_id, mate_id)


func _trim_mate_value(x) -> String:
	return ("%.3f" % float(x)).rstrip("0").rstrip(".")


# --- Assembly: Colours ---------------------------------------------------------------

func _build_colours_page() -> Control:
	var page := _page(8)
	# Colouring hierarchy ("for now" scope, docs/status.md): "this one Occurrence"
	# (laser-select it, the default) or "every Occurrence sharing its immediate owner".
	_colour_group_toggle = _mode_toggle("Apply to whole group", func(_on: bool) -> void: pass, false)
	page.add_child(_colour_group_toggle)
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", tokens.gap)
	grid.add_theme_constant_override("v_separation", tokens.gap)
	page.add_child(grid)
	for swatch in COLOUR_SWATCHES:
		var b := Button.new()
		b.text = swatch["name"]
		b.custom_minimum_size = Vector2(120, 56)
		var fill := Color(swatch["hex"])
		var ink := _readable_text_color(swatch["hex"])
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			b.add_theme_color_override(state, ink)
		b.add_theme_stylebox_override("normal", tokens.box(fill, fill.darkened(0.25)))
		b.add_theme_stylebox_override("hover", tokens.box(fill.lightened(0.12), Color.WHITE))
		b.add_theme_stylebox_override("pressed", tokens.box(fill, Color.WHITE))
		b.pressed.connect(_apply_colour.bind(swatch["hex"]))
		grid.add_child(b)
	var custom_row := _row()
	page.add_child(custom_row)
	custom_row.add_child(_button("Custom hex…", _on_custom_colour_pressed))
	custom_row.add_child(_button("Clear colour", func() -> void: _apply_colour("")))
	return page


func _colour_status() -> String:
	var selected: Node3D = _main.current_selected_part() if _main else null
	return "Selected: %s" % (str(selected.name) if selected else "nothing — laser-select a part first")


func _on_custom_colour_pressed() -> void:
	_main.open_keyboard_for("", func(text: String) -> void:
		var hex := text if text.begins_with("#") else "#" + text
		if hex.length() == 7:
			_apply_colour(hex)
		else:
			toast.emit("Not a valid hex colour (want #RRGGBB): %s" % text, "error")
	, {"mode": "full", "title": "Custom colour, e.g. #3a7bd5 (0-9, a-f)", "confirm_label": "Set"})


func _apply_colour(hex: String) -> void:
	if not _colour_tool:
		return
	var part: Node3D = _main.current_selected_part()
	if part == null:
		toast.emit("Selected: nothing — laser-select a part first", "error")
		return
	if _colour_group_toggle and _colour_group_toggle.button_pressed:
		var group_result: Dictionary = await _colour_tool.set_group_color(part, hex)
		if group_result["ok"]:
			toast.emit("Coloured %d occurrence(s) in the group." % group_result["count"], "ok")
		elif group_result["count"] > 0:
			toast.emit("Coloured %d, then failed: %s" % [group_result["count"], group_result["error"]], "error")
		else:
			toast.emit("Couldn't colour the group: %s" % group_result["error"], "error")
		return
	var result: Dictionary = await _colour_tool.set_color(part, hex)
	if not result["ok"]:
		toast.emit("Couldn't set colour: %s" % result["error"], "error")


func _readable_text_color(hex: String) -> Color:
	var c := Color(hex)
	var luminance := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	return Color.BLACK if luminance > 0.6 else Color.WHITE


# --- Assembly: Sections ----------------------------------------------------------------

func _build_sections_page() -> Control:
	var page := _page()
	var flip := Button.new()
	flip.text = "Flip"
	flip.toggle_mode = true
	flip.custom_minimum_size = Vector2(0, 56)
	flip.toggled.connect(func(on: bool) -> void:
		if _section_tool:
			_section_tool.set_flipped(on)
	)
	page.add_child(flip)
	page.add_child(_hint("Grip the plane to move or tilt it, like grabbing a part."))
	return page


func _sections_status() -> String:
	if not _section_tool or not _section_tool.active:
		return "Off — switch the tool on to place the plane"
	return "Sectioning%s — grip the plane to move it" % (" (flipped)" if _section_tool.flipped else "")


# --- Assembly: Measure -----------------------------------------------------------------

func _build_measure_page() -> Control:
	var page := _page()
	_measure_picks_label = _hint("")
	page.add_child(_measure_picks_label)
	page.add_child(_button("Clear", func() -> void:
		if _measure_tool:
			_measure_tool.clear_picks()
	))
	page.add_child(_hint("Results appear beside the tablet."))
	return page


func _measure_status() -> String:
	return _measure_tool.status_text() if _measure_tool else ""


# Row order/labels/formatting match the flat app's own MeasurementPanel._resultRows
# (client/lib/viewport3d/measurement_panel.dart): a user moving between VR and flat
# sees the same numbers in the same order. Named two-entity results (axis/normal
# distance) come ahead of, never instead of, the generic distance.
func _measure_rows() -> Array:
	var rows := []
	var r: Dictionary = _measure_tool.result if _measure_tool else {}
	var spec := []
	if r.get("length") != null: spec.append(["Length", _fmt_unit(r["length"], "mm")])
	if r.get("diameter") != null: spec.append(["Diameter", _fmt_unit(r["diameter"], "mm")])
	if r.get("radius") != null: spec.append(["Radius", _fmt_unit(r["radius"], "mm")])
	if r.get("area") != null: spec.append(["Area", _fmt_unit(r["area"], "mm²")])
	if r.get("point") != null: spec.append(["Point", _fmt_vec_unit(r["point"], "mm")])
	if r.get("axis_distance") != null: spec.append(["Axis distance", _fmt_unit(r["axis_distance"], "mm")])
	if r.get("normal_distance") != null: spec.append(["Normal distance", _fmt_unit(r["normal_distance"], "mm")])
	if r.get("distance") != null: spec.append(["Distance", _fmt_unit(r["distance"], "mm")])
	if r.get("delta") != null: spec.append(["ΔX, ΔY, ΔZ", _fmt_vec_unit(r["delta"], "mm")])
	var body_volumes: Dictionary = r.get("body_volumes", {})
	var body_masses: Dictionary = r.get("body_masses", {})
	var multi_body: bool = body_volumes.size() > 1
	var i := 0
	for body_id in body_volumes:
		i += 1
		spec.append(["Volume%s" % (" (body %d)" % i if multi_body else ""), _fmt_unit(body_volumes[body_id], "mm³")])
	i = 0
	for body_id in body_masses:
		i += 1
		spec.append(["Mass%s" % (" (body %d)" % i if multi_body else ""), _fmt_unit(body_masses[body_id], "g")])
	for entry in spec:
		rows.append({"id": entry[0], "title": entry[1], "subtitle": entry[0], "state": "normal"})
	return rows


static func _fmt_num(x: float) -> String:
	return ("%.3f" % x).rstrip("0").rstrip(".")


static func _fmt_unit(x: float, unit: String) -> String:
	return "%s %s" % [_fmt_num(x), unit]


static func _fmt_vec_unit(v: Array, unit: String) -> String:
	var parts := []
	for x in v:
		parts.append(_fmt_num(x))
	return "%s %s" % [", ".join(parts), unit]


# --- Windows ---------------------------------------------------------------------------

func _build_windows_page() -> Control:
	var page := _page()
	if _assembly_tree_window:
		page.add_child(_button("Assembly Tree", _assembly_tree_window.toggle))
	if _calculator_window:
		page.add_child(_button("Calculator", _calculator_window.toggle))
	# Image Viewer and Browser: several can be open at once — the button opens one
	# (the first press) and another with every further press.
	if _image_viewer_window:
		page.add_child(_button("Image Viewer", func() -> void: _main.open_window("image")))
	if _browser_window:
		page.add_child(_button("Browser", func() -> void: _main.open_window("browser")))
	page.add_child(_hint("Each window opens in front of you and has its own close button and grab handle. Image Viewer and Browser: press again for another window."))
	return page


# --- Files -------------------------------------------------------------------------------

func _build_files_page() -> Control:
	var page := _page()
	page.add_child(_hint("Loads from res://models, user://models, and the Settings project folder. Pick Open or Add beside the tablet."))
	_files_count_label = Label.new()
	page.add_child(_files_count_label)
	page.add_child(_button("Refresh list", _rescan_files))
	return page


func _rescan_files() -> void:
	_files_cache.clear()
	if _main == null:
		return
	for path in _main.list_model_files():
		var native: bool = path.get_extension().to_lower() in ["didsa", "didsaprt"]
		_files_cache.append({"path": path, "native": native, "root_id": _main.native_file_root_part_id(path) if native else ""})
	if _files_count_label:
		_files_count_label.text = "%d model file(s) found" % _files_cache.size()


func _files_status() -> String:
	return str(_main.status_text) if _main else ""


func _files_rows() -> Array:
	var rows := []
	if _main == null:
		return rows
	var loaded_root: String = _main.current_root_part_id()
	var assembly_loaded := not loaded_root.is_empty()
	for f in _files_cache:
		var path: String = f["path"]
		var actions := [{"label": "Open", "accent": true, "callback": _main.load_model_file.bind(path)}]
		# "Add" only for native files, once something backend-hosted is loaded to add
		# onto, and never for the file that IS the loaded root (the backend rejects
		# that with 422 "Cannot insert a Part into itself").
		if f["native"] and assembly_loaded and f["root_id"] != loaded_root:
			actions.append({"label": "Add", "callback": _main.add_component_file.bind(path)})
		rows.append({"id": path, "title": path.get_file(), "subtitle": path.get_extension().to_upper(), "state": "normal", "actions": actions})
	return rows


# --- Settings (utility cluster) -----------------------------------------------------------

func settings_page() -> Control:
	var page := _page(14)
	page.add_child(_hint("Set-and-forget: steadiness, display quality and where the Files tool looks for models."))
	page.add_child(_choice_row("Steadiness (hold-still shake)", _two_hand.STEADINESS_NAMES, _two_hand.steadiness, func(i: int) -> void:
		_two_hand.set_steadiness(i) # whole-model moves
		_left.set_steadiness(i) # a single held part (grip), each hand
		_right.set_steadiness(i)
		if _section_tool:
			_section_tool.set_steadiness(i) # the section-plane gizmo, grabbed the same way
	))
	page.add_child(_hint("Display"))
	_info_label = _hint("")
	_info_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
	page.add_child(_info_label)
	page.add_child(_mode_toggle("Shadows", func(on: bool) -> void: _main.set_shadows(on)))
	page.add_child(_choice_row("Resolution", ["100%", "80%", "65%"], 0, func(i: int) -> void: _main.set_render_scale([1.0, 0.8, 0.65][i])))
	page.add_child(_choice_row("MSAA", ["Off", "2x", "4x"], 1, func(i: int) -> void: _main.set_msaa(i)))
	page.add_child(_hint("Comfort"))
	page.add_child(_mode_toggle("Reduce motion", func(on: bool) -> void: _main.set_reduce_motion(on), _main.reduce_motion()))
	page.add_child(_choice_row("Haptics", ["Off", "Low", "Normal", "High"], _main.haptics_level(), func(i: int) -> void:
		_main.set_haptics_level(i)
		UiFeedback.haptic(_right, "confirm") # a sample of the new level
	))
	page.add_child(_hint("Project folder"))
	_project_folder_label = Label.new()
	_project_folder_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_project_folder_label)
	_refresh_project_folder_label()
	var folder_row := _row()
	page.add_child(folder_row)
	folder_row.add_child(_button("Set folder…", _on_set_project_folder_pressed))
	folder_row.add_child(_button("Clear", func() -> void:
		_main.set_project_folder("")
		_refresh_project_folder_label()
	))
	return page


func _on_set_project_folder_pressed() -> void:
	_main.open_keyboard_for(_main.project_folder(), func(text: String) -> void:
		_main.set_project_folder(text.strip_edges())
		_refresh_project_folder_label()
	, {"mode": "full", "title": "Project folder (absolute path)", "confirm_label": "Set"})


func _refresh_project_folder_label() -> void:
	if not _project_folder_label:
		return
	var path: String = _main.project_folder()
	_project_folder_label.text = "Scanning: %s" % path if not path.is_empty() else "Scanning res://models and user://models only — no project folder set."
