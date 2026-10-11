extends RefCounted
## Every page the redesigned tablet shows, and the registration that puts them in
## the home-screen tiles / hubs / tool strip (scripts/ui/tablet_registry.gd). Ported from
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
##   navigate: Callable(category_id)  (opens a category on the tablet: a status chip's tap)

signal toast(text: String, kind: String)

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const MATE_TYPE_LABELS: Array[String] = ["Coincident", "Concentric", "Parallel", "Distance", "Angle"]
const COLOUR_SWATCHES: Array[Dictionary] = [
	{"name": "Red", "hex": "#e63946"}, {"name": "Orange", "hex": "#f4a340"},
	{"name": "Yellow", "hex": "#f1c40f"}, {"name": "Green", "hex": "#2ecc71"},
	{"name": "Blue", "hex": "#3498db"}, {"name": "Purple", "hex": "#9b59b6"},
	{"name": "White", "hex": "#f5f5f5"}, {"name": "Black", "hex": "#222222"},
]
const SCENE_ICONS := {"Light": "scene_light", "Dark": "scene_dark", "Mid": "scene_mid", "Passthrough": "scene_passthrough"}
const ACCENT_DESIGN := Color(1.00, 0.71, 0.33)
const ACCENT_ASSEMBLY := Color(0.37, 0.76, 1.00)
const ACCENT_VIEW := Color(0.48, 0.88, 0.69)
const ACCENT_INSPECT := Color(0.77, 0.55, 1.00)
const ACCENT_FILES := Color(1.00, 0.82, 0.40)
const ACCENT_WINDOWS := Color(0.43, 0.66, 1.00)
const ACCENT_SETTINGS := Color(0.62, 0.70, 0.80)

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
var _design_table: Node
var _dragging: Callable = Callable()
var _navigate: Callable = Callable() ## (category_id) -> void: opens a category on the tablet (a status chip's tap)

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
var _dirty_label: Label ## "Unsaved changes" on the Files page
var _new_assembly_button: Button
var _new_assembly_armed_until_ms := 0 ## New assembly discards what is loaded, so it needs a second press within this long
const NEW_ASSEMBLY_CONFIRM_MS := 4000
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
	_design_table = ctx.get("design_table")
	_dragging = ctx.get("dragging", Callable())
	_navigate = ctx.get("navigate", func(_category_id: String) -> void: pass)


func register(reg) -> void:
	## One category = one tile on the home screen, in the order the tiles appear (5 x 2):
	## Design | Assemble | View | Inspect | Files   /   Tree | Calculator | Images | Browser | Settings.
	## Design and the four window tiles are "action" tiles (they act straight from Home);
	## View and Settings are hubs (a screen of tiles first); the rest open a tool view.
	reg.add_category("design", "Design", "design", ACCENT_DESIGN, {
		"subtitle": "sketch · extrude", "action": _on_design_tile, "caption": _design_caption})

	reg.add_category("assemble", "Assemble", "assembly", ACCENT_ASSEMBLY, {"subtitle": "mates · fix · relax"})
	reg.add_tool("assemble", "mates", "Mates", "mates", _build_mates_page, {
		"kind": "mode", "on_activate": _set_mates.bind(true), "on_deactivate": _set_mates.bind(false),
		"on_select": _on_mates_selected, "status": _mates_status, "list": _mates_rows, "list_empty": "No mates yet.",
		"help": "Switch the tool on, laser-target a face on one part, then a face on a different part. Choose a type (Distance and Angle take a value): a blue ghost shows where the part will go, so Flip it if it faces the wrong way, then Create mate. A mate in the list can be flipped, locked or given a new value afterwards."})

	reg.add_category("view", "View", "view", ACCENT_VIEW, {"subtitle": "scale · hide · display", "hub": true})
	reg.add_tool("view", "navigate", "Navigate", "navigate", _build_navigate_page, {
		"caption": "hands · speed",
		"help": "Switch model movement, user movement and part manipulation on or off. Travel speed sets how fast the left stick walks you."})
	reg.add_tool("view", "scale", "Scale", "scale", _build_scale_page, {
		"caption": "presets · fit · home",
		"help": "Jump to a preset scale about the model's centre. Fit to view brings the whole model in front of you; Home returns it to where it loaded. For an exact value, click the right thumbstick."})
	reg.add_tool("view", "visibility", "Visibility", "visibility", _build_visibility_page, {
		"caption": "hide · show · isolate",
		"help": "Hide or show every part at once, flip which parts are hidden, or isolate the selected part. All undoable."})
	reg.add_tool("view", "shoot_hide", "Shoot hide", "shoot_hide", _build_shoot_hide_page, {
		"kind": "mode", "on_activate": _set_shoot_hide.bind(true), "on_deactivate": _set_shoot_hide.bind(false),
		"caption": "point and hide",
		"hint": "Point at a part and pull the right trigger to hide it.",
		"help": "Switch the tool on, then point the right laser at a part and pull the trigger to hide it. Undo brings it back."})
	reg.add_tool("view", "display", "Display", "eye_shaded", _build_display_page, {
		"caption": "shaded · edges · wire",
		"help": "How models are drawn: Shaded, Shaded + edges (the part's real CAD edges over its faces) or Wireframe (edges only). Saved for next time."})
	reg.add_tool("view", "colours", "Colours", "colours", _build_colours_page, {
		"caption": "paint parts", "status": _colour_status,
		"help": "Laser-select a part first, then tap a swatch. Apply to whole group colours every occurrence sharing its owner. Not undoable: pick another colour or Clear."})
	reg.add_tool("view", "environment", "Environment", "environment", _build_environment_page, {
		"caption": "scene · passthrough",
		"help": "How the room around the model looks: a rendered backdrop, or step into mixed reality (Passthrough)."})

	reg.add_category("inspect", "Inspect", "measure", ACCENT_INSPECT, {"subtitle": "measure · sections"})
	reg.add_tool("inspect", "measure", "Measure", "measure", _build_measure_page, {
		"kind": "mode", "on_activate": _set_measure.bind(true), "on_deactivate": _set_measure.bind(false),
		"status": _measure_status, "list": _measure_rows, "list_empty": "No measurements yet.",
		"help": "Switch the tool on, then pick a vertex, edge or face. A second pick compares the two; a third starts again. Results show beside the tablet."})
	reg.add_tool("inspect", "sections", "Sections", "sections", _build_sections_page, {
		"kind": "mode", "on_activate": _set_sections.bind(true), "on_deactivate": _set_sections.bind(false), "status": _sections_status,
		"help": "Switch the tool on to place a clip plane in front of you. Grip the plane to move or tilt it, like grabbing a part. Flip swaps the side that stays."})

	reg.add_category("files", "Files", "files", ACCENT_FILES, {"subtitle": "open · save · new"})
	reg.add_tool("files", "models", "Models", "models", _build_files_page, {
		"on_select": _rescan_files, "status": _files_status, "list": _files_rows, "list_empty": "No model files found.",
		"help": "Open loads a model in place of the current one. Add merges a native file into the loaded assembly. New assembly starts an empty one. Needs a configured backend for STEP, STL and OBJ."})

	# Each floating window is its own tile: tap to open it (Image Viewer and Browser: tap again for another).
	reg.add_category("tree", "Tree", "tree", ACCENT_WINDOWS, {"subtitle": "window", "action": _open_window.bind("tree")})
	reg.add_category("calculator", "Calculator", "calculator", ACCENT_WINDOWS, {"subtitle": "window", "action": _open_window.bind("calculator")})
	reg.add_category("images", "Images", "image", ACCENT_WINDOWS, {"subtitle": "window", "action": _open_window.bind("image")})
	reg.add_category("browser", "Browser", "browser", ACCENT_WINDOWS, {"subtitle": "window", "action": _open_window.bind("browser")})

	reg.add_category("settings", "Settings", "settings", ACCENT_SETTINGS, {"subtitle": "set & forget", "hub": true})
	reg.add_tool("settings", "set_movement", "Movement", "movement", _build_settings_movement, {
		"caption": "steadiness", "help": "How much a held part or the model is steadied against hand shake."})
	reg.add_tool("settings", "set_display", "Display", "eye_shaded", _build_settings_display, {
		"caption": "shadows · resolution · MSAA", "help": "Image quality against speed. Lower the resolution or MSAA if the headset struggles."})
	reg.add_tool("settings", "set_appearance", "Appearance", "colours", _build_settings_appearance, {
		"caption": "theme · effects", "help": "The tablet's look. Shader effects can be switched off if they cost too much."})
	reg.add_tool("settings", "set_comfort", "Comfort", "comfort", _build_settings_comfort, {
		"caption": "motion · sound · haptics", "help": "Reduce motion, sound and its volume, and how strongly the controllers buzz."})
	reg.add_tool("settings", "set_folder", "Project folder", "files", _build_settings_folder, {
		"caption": "where models live", "help": "An extra folder the Files tool scans for models."})
	reg.add_tool("settings", "set_table", "Design table", "table", _build_settings_table, {
		"caption": "turn · zoom limits", "help": "How the design table treats a part sent back to the arena, and how far you can zoom a part on it."})


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
	if _new_assembly_button and _new_assembly_armed_until_ms > 0 and Time.get_ticks_msec() > _new_assembly_armed_until_ms:
		_disarm_new_assembly()
	_refresh_environment_status() # also picks up Passthrough turning on/off after the headset gains focus
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


func _build_display_page() -> Control:
	var page := _page()
	if _main == null or _main.get("view_modes") == null:
		page.add_child(_hint("Display modes aren't available here."))
		return page
	page.add_child(_hint("How models are drawn. Edges are the part's real CAD edges, so they need a model made by the backend; a bare local file shows its sharp edges instead."))
	var group := ButtonGroup.new()
	var modes = _main.view_modes
	for i in modes.NAMES.size():
		var b := _button(modes.NAMES[i], func() -> void: modes.set_mode(i))
		b.toggle_mode = true
		b.button_group = group
		b.set_pressed_no_signal(modes.mode == i)
		page.add_child(b)
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
	if _main.current_scene() == "Passthrough":
		_environment_status_label.text = _main.passthrough_status() # says whether it's on and, if not, what the runtime offers
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
		var type_str := str(mate.get("type", "?"))
		var type_label: String = type_str.capitalize()
		var has_value: bool = mate.get("value") != null
		var mate_id := str(mate.get("id", ""))
		var flipped := bool(mate.get("flipped", false))
		var free_spin := bool(mate.get("allow_rotation", true))
		var notes := []
		if flipped:
			notes.append("flipped")
		if type_str == "concentric":
			notes.append("free to spin" if free_spin else "rotation locked")
		var actions := [{"label": "Flip", "callback": _on_edit_mate.bind(mate_id, {"flipped": not flipped})}]
		if type_str == "concentric":
			actions.append({"label": "Lock rotation" if free_spin else "Free rotation", "callback": _on_edit_mate.bind(mate_id, {"allow_rotation": not free_spin})})
		if type_str in ["distance", "angle"]:
			actions.append({"label": "Value", "callback": _on_edit_mate_value.bind(mate_id, mate.get("value"))})
		actions.append({"label": "Delete", "danger": true, "confirm": true, "callback": _on_delete_mate_pressed.bind(mate_id)})
		rows.append({
			"id": mate_id,
			"title": "%s%s" % [type_label, (" (%s)" % _trim_mate_value(mate.get("value"))) if has_value else ""],
			"subtitle": ", ".join(notes), "state": "normal",
			"actions": actions,
		})
	return rows


func _on_edit_mate(mate_id: String, fields: Dictionary) -> void:
	## Flip / lock rotation / change the value of a mate that already exists (the backend's PATCH), and apply it.
	if _mates_tool == null or _mates_last_owner_part_id == "" or mate_id == "":
		return
	var result: Dictionary = await _mates_tool.update_mate(_mates_last_owner_part_id, mate_id, fields)
	if not result["ok"]:
		toast.emit("Couldn't change the mate: %s" % result["error"], "error")


func _on_edit_mate_value(mate_id: String, current) -> void:
	if _mates_tool == null or _main == null:
		return
	_main.open_keyboard_for(_trim_mate_value(current if current != null else 0.0), func(text: String) -> void:
		_on_edit_mate(mate_id, {"value": text.to_float()})
	)


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


# --- Design and window tiles ---------------------------------------------------------------

func _on_design_tile() -> void:
	## One tile, no menu: the table is closed -> summon it; it is open -> bring it to you. New part, Edit and
	## the rest live on the table itself (its tree's + and each part's Table button, or carry a part over it).
	if _design_table == null:
		return
	if _design_table.is_open():
		_design_table.recall()
	else:
		_design_table.open()


func _design_caption() -> String:
	if _design_table == null:
		return "sketch · extrude"
	return "Bring it to me" if _design_table.is_open() else "Summon table"


func _open_window(which: String) -> void:
	match which:
		"tree":
			if _assembly_tree_window:
				_assembly_tree_window.toggle()
		"calculator":
			if _calculator_window:
				_calculator_window.toggle()
		"image", "browser":
			# Several can be open at once: the first press opens one, every further press another.
			if _main != null:
				_main.open_window(which)


func chips() -> Array:
	## The status chips along the tablet's top bar, besides the active mode tool (which tablet_ui adds itself).
	var out: Array = []
	if _main != null and _main.document_dirty:
		out.append({"text": "Unsaved", "kind": "warn", "tap": _navigate.bind("files")})
	if _design_table != null and _design_table.is_open():
		out.append({"text": "Table open", "kind": "ok", "tap": _design_table.recall})
	return out


# --- Files -------------------------------------------------------------------------------

func _build_files_page() -> Control:
	var page := _page()
	page.add_child(_hint("Loads from res://models, user://models, and the Settings project folder. Pick Open or Add beside the tablet."))
	_files_count_label = Label.new()
	page.add_child(_files_count_label)
	_dirty_label = _hint("")
	_dirty_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	page.add_child(_dirty_label)
	if _main != null:
		_main.dirty_changed.connect(func(_d: bool) -> void: _refresh_dirty_label())
	_refresh_dirty_label()
	page.add_child(_button("Refresh list", _rescan_files))
	page.add_child(_hint("Save writes the whole session, including edits made on the design table, as a new .didsa file the flat app can open. It never overwrites the file you opened.", true))
	page.add_child(_button("Save as new file", func() -> void:
		var saved: String = await _main.save_native_snapshot()
		if saved != "":
			_rescan_files()))
	page.add_child(_hint("New assembly throws away what is loaded (Save first if you want to keep it) and starts an empty one; then add parts with the design table's New part. Needs the backend.", true))
	_new_assembly_button = _button("New assembly", _on_new_assembly_pressed)
	page.add_child(_new_assembly_button)
	return page


func _refresh_dirty_label() -> void:
	if _dirty_label == null or _main == null:
		return
	var dir: String = ProjectSettings.globalize_path(_main.snapshot_path().get_base_dir())
	_dirty_label.text = ("Unsaved changes. Save as new file before opening or starting anything else. Saves go to %s" if _main.document_dirty else "Nothing unsaved. Saves go to %s") % dir
	if _new_assembly_button:
		_new_assembly_button.text = "New assembly" if _new_assembly_armed_until_ms == 0 else _new_assembly_armed_text()


func _new_assembly_armed_text() -> String:
	return "Unsaved! Press again to discard" if _main != null and _main.document_dirty else "Press again to discard"


func _on_new_assembly_pressed() -> void:
	## Two presses: the first arms the button ("Press again to discard"), the second, within a few seconds, starts the empty assembly.
	if _main == null:
		return
	var now := Time.get_ticks_msec()
	if _new_assembly_armed_until_ms == 0 or now > _new_assembly_armed_until_ms:
		_new_assembly_armed_until_ms = now + NEW_ASSEMBLY_CONFIRM_MS
		_new_assembly_button.text = _new_assembly_armed_text()
		_new_assembly_button.theme_type_variation = &"ButtonDanger"
		return
	_disarm_new_assembly()
	if await _main.new_assembly(true):
		_rescan_files()


func _disarm_new_assembly() -> void:
	_new_assembly_armed_until_ms = 0
	if _new_assembly_button:
		_new_assembly_button.text = "New assembly"
		_new_assembly_button.theme_type_variation = &""


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


# --- Settings (the Settings hub's pages) -----------------------------------------------------

func _build_settings_movement() -> Control:
	var page := _page(14)
	page.add_child(_hint("How much hand shake is filtered out of a held part and of moving the whole model."))
	page.add_child(_choice_row("Steadiness (hold-still shake)", _two_hand.STEADINESS_NAMES, _two_hand.steadiness, func(i: int) -> void:
		_two_hand.set_steadiness(i) # whole-model moves
		_left.set_steadiness(i) # a single held part (grip), each hand
		_right.set_steadiness(i)
		if _section_tool:
			_section_tool.set_steadiness(i) # the section-plane gizmo, grabbed the same way
	))
	return page


func _build_settings_display() -> Control:
	var page := _page(14)
	_info_label = _hint("")
	_info_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
	# A FIXED height: the readout gains and loses lines (parts loaded, load summary, wrapping) and
	# a label that resized with it shifted every button below it while you were aiming at one.
	_info_label.clip_text = true
	_info_label.custom_minimum_size = Vector2(0, 176)
	page.add_child(_info_label)
	page.add_child(_mode_toggle("Shadows", func(on: bool) -> void: _main.set_shadows(on)))
	page.add_child(_choice_row("Resolution", ["100%", "80%", "65%"], 0, func(i: int) -> void: _main.set_render_scale([1.0, 0.8, 0.65][i])))
	page.add_child(_choice_row("MSAA", ["Off", "2x", "4x"], 1, func(i: int) -> void: _main.set_msaa(i)))
	return page


func _build_settings_appearance() -> Control:
	var page := _page(14)
	page.add_child(_choice_row("Theme", UiThemes.ORDER, maxi(UiThemes.ORDER.find(_main.ui_theme()), 0), func(i: int) -> void: _main.set_ui_theme(UiThemes.ORDER[i])))
	page.add_child(_mode_toggle("Shader effects", func(on: bool) -> void: _main.set_fx_enabled(on), _main.fx_enabled()))
	return page


func _build_settings_comfort() -> Control:
	var page := _page(14)
	page.add_child(_mode_toggle("Reduce motion", func(on: bool) -> void: _main.set_reduce_motion(on), _main.reduce_motion()))
	page.add_child(_mode_toggle("Sound", func(on: bool) -> void: _main.set_sound_enabled(on), _main.sound_enabled()))
	page.add_child(_build_volume_row())
	page.add_child(_choice_row("Haptics", ["Off", "Low", "Normal", "High"], _main.haptics_level(), func(i: int) -> void:
		_main.set_haptics_level(i)
		UiFeedback.haptic(_right, "confirm") # a sample of the new level
	))
	return page


func _build_settings_folder() -> Control:
	var page := _page(14)
	page.add_child(_hint("Where the Files tool looks for models, besides res://models and user://models."))
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


func _build_settings_table() -> Control:
	var page := _page(14)
	if _design_table == null or _main == null or _main.app_settings() == null:
		page.add_child(_hint("The design table isn't available here."))
		return page
	var settings = _main.app_settings()
	page.add_child(_choice_row("A part sent back to the arena", ["Original turn", "As turned"], 1 if settings.table_keep_turn else 0, func(i: int) -> void:
		_design_table.keep_turn_on_return = i == 1
		settings.set_table_keep_turn(i == 1)))
	var limits := [2.0, 3.0, 5.0, 8.0]
	var current := limits.find(settings.table_max_scale)
	page.add_child(_choice_row("Biggest zoom of the part (a sketch always allows 8x)", ["2x", "3x", "5x", "8x"], current if current >= 0 else 1, func(i: int) -> void:
		_design_table.max_scale_setting = limits[i]
		settings.set_table_max_scale(limits[i])))
	return page


var _volume_label: Label
var _last_volume_preview_ms := 0

func _build_volume_row() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	_volume_label = _hint("")
	box.add_child(_volume_label)
	var slider := _make_slider(0.0, 1.0, 0.05)
	slider.value = _main.sound_volume()
	slider.value_changed.connect(func(v: float) -> void:
		_main.set_sound_volume(v)
		_refresh_volume_label()
		var now := Time.get_ticks_msec() # a click to hear the new level, but not on every tick of a drag
		if now - _last_volume_preview_ms > 250:
			_last_volume_preview_ms = now
			UiFeedback.play("confirm", _right)
	)
	box.add_child(slider)
	_refresh_volume_label()
	return box


func _refresh_volume_label() -> void:
	if _volume_label:
		_volume_label.text = "Volume: %d%%" % int(round(_main.sound_volume() * 100.0))


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
