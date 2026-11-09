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
##   appearance_tool, section_tool, measure_tool, assembly_tree_window,
##   calculator_window, image_viewer_window, browser_window,
##   dragging: Callable() -> bool  (true while the laser is dragging a slider)
##   navigate: Callable(category_id)  (opens a category on the tablet: a status chip's tap)

signal toast(text: String, kind: String)

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const FolderChooser := preload("res://scripts/ui/folder_chooser.gd")
const ProjectFolder := preload("res://scripts/project_folder.gd")
const NativeCompose := preload("res://scripts/native_compose.gd") ## which file names are native files (any extension they have had)
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const _MatesTool := preload("res://scripts/mates_tool.gd")
const MATE_TYPE_LABELS: Array[String] = ["Coincident", "Concentric", "Parallel", "Distance", "Angle", "Width", "Symmetric", "Gear", "Rack and pinion", "Screw", "Limit distance", "Limit angle"]
const AppearancePage := preload("res://scripts/ui/appearance_page.gd")
const ScenesPage := preload("res://scripts/ui/scenes_page.gd")
const COLOUR_SWATCHES: Array[Dictionary] = AppearancePage.PALETTE ## the tool wheel's palette is the Appearance page's
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
var _appearance_tool: Node
var _section_tool: Node
var _measure_tool: Node
var _assembly_tree_window: Node
var _calculator_window: Node
var _image_viewer_window: Node
var _browser_window: Node
var _design_table: Node
var _dragging: Callable = Callable()
var _navigate: Callable = Callable() ## (category_id) -> void: opens a category on the tablet (a status chip's tap)
var _open_tool: Callable = Callable() ## (tool_id) -> void: opens a tool's page on the tablet

var _scale_label: Label
var _lock_button: Button
var _speed_label: Label
var _speed_slider: HSlider
var _mates_picks_label: Label
var _mates_value_label: Label
var _mates_toggles_row: Control ## Allow rotation / Minimal movement: neither means anything for a coupler (nothing moves when one is made)
var _mates_create_button: Button
var _mates_branch_label: Label ## which orientation / side the preview shows, and where Next solution is (MatesTool.branch_text)
var _mates_alignment_button: Button
var _mates_flip_button: Button
var _mates_next_button: Button
var _mates_relax_button: Button
var _mates_last_owner_part_id := ""
var _measure_picks_label: Label
var _appearance_page: RefCounted = null ## appearance_page.gd, once built
var _scenes_page: RefCounted = null ## scenes_page.gd, once built
var _environment_status_label: Label
var _project_folder_label: Label
var _info_label: Label
var _files_count_label: Label
var _dirty_label: Label ## "Unsaved changes" on the Files page
var _new_assembly_button: Button
var _discard_box: VBoxContainer ## Files page: "you have unsaved changes" with Discard / Save first / Cancel, while main.gd has a replace waiting
var _discard_label: Label
var _new_assembly_armed_until_ms := 0 ## New assembly discards what is loaded, so it needs a second press within this long
const NEW_ASSEMBLY_CONFIRM_MS := 4000
const ROOM_TILE_COLUMNS := 2 ## the Rooms page's grid of open rooms
const ROOM_THUMB_HEIGHT := 150 ## tablet pixels
var _files_cache: Array = [] ## [{path, native, root_id}] — scanned on select/Refresh, never per frame (a project folder may be a network mount)
var _locate_key := "" ## Files > References' Locate...: the reference being located ("" = the review list shows)
var _locate_ref := ""
var _locate_ref_id := ""
var _locate_files: Array = [] ## file_index.gd's entries, scanned once when Locate... is pressed (never per frame)


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
	_appearance_tool = ctx.get("appearance_tool")
	_section_tool = ctx.get("section_tool")
	_measure_tool = ctx.get("measure_tool")
	_assembly_tree_window = ctx.get("assembly_tree_window")
	_calculator_window = ctx.get("calculator_window")
	_image_viewer_window = ctx.get("image_viewer_window")
	_browser_window = ctx.get("browser_window")
	_design_table = ctx.get("design_table")
	_dragging = ctx.get("dragging", Callable())
	_navigate = ctx.get("navigate", func(_category_id: String) -> void: pass)
	_open_tool = ctx.get("open_tool", func(_tool_id: String) -> void: pass)


func register(reg) -> void:
	## One category = one tile on the home screen, in the order the tiles appear (6 x 2):
	## Design | Assemble | View | Inspect | Files   /   Tree | Calculator | Images | Browser | Settings (and Home, which makes 12).
	## Design and the four window tiles are "action" tiles (they act straight from Home);
	## View and Settings are hubs (a screen of tiles first); the rest open a tool view.
	reg.add_category("design", "Design", "design", ACCENT_DESIGN, {
		"subtitle": "sketch · extrude", "action": _on_design_tile, "caption": _design_caption})

	reg.add_category("rooms", "Rooms", "room", ACCENT_ASSEMBLY, {"subtitle": "assembly rooms"})
	reg.add_tool("rooms", "rooms", "Rooms", "room", _build_rooms_page, {
		"help": "Assembly Rooms. New room makes an empty sub-assembly in a room of its own; Room on an Assembly Tree row opens an existing one. Each open room has a tile: Bring to me moves it (and a minimised one comes back full size) in front of you, Close closes it."})

	reg.add_category("assemble", "Assemble", "assembly", ACCENT_ASSEMBLY, {"subtitle": "mates · fix · relax"})
	reg.add_tool("assemble", "mates", "Mates", "mates", _build_mates_page, {
		"kind": "mode", "on_activate": _set_mates.bind(true), "on_deactivate": _set_mates.bind(false),
		"on_select": _on_mates_selected, "status": _mates_status, "list": _mates_rows, "list_empty": "No mates yet.", "row_select": _on_mate_row_selected,
		"help": "Switch the tool on, laser-target a face on one part, then a face on a different part. Choose a type (Distance and Angle take a value): a blue ghost shows where the part will go, so Flip it if it faces the wrong way, then Create mate. A mate in the list can be flipped, locked or given a new value afterwards."})

	reg.add_tool("assemble", "drive", "Drive", "movement", _build_drive_page, {
		"kind": "mode", "on_activate": _set_drive.bind(true), "on_deactivate": _set_drive.bind(false), "status": _drive_status,
		"caption": "turn a part, run the mechanism", "hint": "Point at a round face (or a straight edge) of a mated part and pull the trigger.",
		"help": "Switch the tool on, then pull the right trigger on a round face or circular edge of a part held by mates (a gear, say) to turn it about that axis, or on a straight edge to slide it along it. Push the right stick sideways to run: full deflection is 30 rpm (50 mm/s when sliding), either way. A keeps it running at that speed with the stick at rest, B (or Stop) stops it. Everything the mates couple to it moves too; the readout shows each turning part's rpm. Stopping stores the pose as one undo step."})
	reg.add_tool("assemble", "scenes", "Scenes", "scenes", _build_scenes_page, {
		"caption": "show · save · back to default",
		"help": "A scene is a named arrangement of the assembly (parts moved, hidden or painted, and where you look from) that changes nothing in the model. Show relaxes the mates and arranges the parts as the scene says; anything you move or paint then is temporary. Update scene keeps what is on screen in the shown scene; Save as new names a new one (from the default too: relax, move, paint, save). Back to default puts every part back, and asks first if the scene has unsaved changes. View on Show turns and places the model to the scene's viewpoint at the scale you have."})

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
	reg.add_tool("view", "shoot_hide", "Hide tool", "shoot_hide", _build_shoot_hide_page, {
		"kind": "mode", "on_activate": _set_shoot_hide.bind(true), "on_deactivate": _set_shoot_hide.bind(false),
		"caption": "point and hide",
		"hint": "Point at a part and pull the right trigger to hide it.",
		"help": "Switch the tool on, then point the right laser at a part and pull the trigger to hide it. Undo brings it back."})
	reg.add_tool("view", "display", "Display", "eye_shaded", _build_display_page, {
		"caption": "shaded · edges · wire",
		"help": "How models are drawn: Shaded, Shaded + edges (the part's real CAD edges over its faces) or Wireframe (edges only). Saved for next time."})
	reg.add_tool("view", "paint", "Appearance", "paint", _build_paint_page, {
		"kind": "mode", "on_activate": _set_paint.bind(true), "on_deactivate": _set_paint.bind(false),
		"caption": "colour · see-through · shine · glow", "status": _paint_status,
		"hint": "Click paints the body under the laser. Hold the trigger to choose what to paint.",
		"help": "Switch the tool on and set the brush: a colour (palette, picker, hex, recent, or the eyedropper), and any of opacity, shine, metal and glow (only the switched-on properties are painted). Point the right laser at a part: a click paints that body; hold the trigger to choose the face, the part, every copy of a pattern, every placement of the part, a sub-assembly or the whole assembly, and let go on the row (off the panel paints nothing). Clear removes that level's own paint. Undo puts it back. While mates are relaxed, painting is temporary and goes back with the parts."})
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
	reg.add_tool("files", "references", "References", "files", _build_references_page, {
		"caption": "moved · missing files", "on_select": _cancel_locate, "status": _references_status, "list": _references_rows,
		"list_empty": "Every file the opened assembly places was found where it was.",
		"help": "The parts the opened assembly places are found by their path, and when a file has moved, by its part id in the project folder. A file found in a new place is used and listed here; Save as new file writes its new path. When several files carry the part, or only a file with the same name is found, nothing is loaded until you pick one here: Use opens the assembly again with it (a file that is not the placed part asks for a second press). Locate... lists every model file to pick from; Leave missing hides the row."})

	# Each floating window is its own tile: tap to open it (Image Viewer and Browser: tap again for another).
	reg.add_category("tree", "Tree", "tree", ACCENT_WINDOWS, {"subtitle": "", "action": _open_window.bind("tree")})
	reg.add_category("calculator", "Calculator", "calculator", ACCENT_WINDOWS, {"subtitle": "", "action": _open_window.bind("calculator")})
	reg.add_category("images", "Images", "image", ACCENT_WINDOWS, {"subtitle": "", "action": _open_window.bind("image")})
	reg.add_category("browser", "Browser", "browser", ACCENT_WINDOWS, {"subtitle": "", "action": _open_window.bind("browser")})

	reg.add_category("settings", "Settings", "settings", ACCENT_SETTINGS, {"hub": true})
	reg.add_category("home", "Home", "home", ACCENT_SETTINGS, {"subtitle": "landing · demos", "action": _on_home_tile})
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


func _on_home_tile() -> void:
	## Back to the landing (logo, demos, launcher). The UI Lab's stub main has no landing, so it does nothing there.
	if _main != null and _main.has_method("go_home"):
		_main.go_home()


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
		_refresh_mates_branch_controls()
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


func _set_paint(on: bool) -> void:
	_left.paint_active = on
	_right.paint_active = on


func set_paint_colour(hex: String) -> void:
	## The colour the Appearance tool paints (the tool wheel's palette and the page both set it; the brush's other properties stay).
	if _appearance_page != null:
		_appearance_page.set_colour(hex)
	elif _appearance_tool != null:
		var b: Dictionary = _appearance_tool.brush.duplicate()
		b["colour"] = hex.to_upper()
		_appearance_tool.brush = b


func set_paint_clear() -> void:
	## The Clear swatch (the wheel's palette has it too).
	if _appearance_page != null:
		_appearance_page.set_clear()
	elif _appearance_tool != null:
		_appearance_tool.brush = {}


func paint_colour() -> String:
	## The brush's colour, "Clear" for the Clear swatch, "" if it paints no colour.
	if _appearance_tool == null:
		return ""
	return "Clear" if _appearance_tool.brush.is_empty() else str(_appearance_tool.brush.get("colour", ""))


func _paint_status() -> String:
	return _appearance_tool.panel_title() if _appearance_tool != null else ""


func _build_paint_page() -> Control:
	if _appearance_tool == null:
		return _hint("The Appearance tool isn't available.")
	_appearance_page = AppearancePage.new(_appearance_tool, tokens, _main.open_keyboard_for if _main != null else Callable(), func(text: String, kind: String) -> void: toast.emit(text, kind))
	return _appearance_page.build()


func _build_scenes_page() -> Control:
	var scenes = _main.get("scenes_tool") if _main != null else null
	if scenes == null:
		return _hint("Scenes aren't available.")
	_scenes_page = ScenesPage.new(scenes, tokens, _main.open_keyboard_for, func(text: String, kind: String) -> void: toast.emit(text, kind))
	_scenes_page.scope_names = func(root: String) -> String: return _main.scope_name(root) if _main.has_method("scope_name") else root
	return _scenes_page.build()


func _on_custom_colour_pressed() -> void:
	## The hex field (the full keyboard: it needs a-f).
	if _appearance_page != null:
		_appearance_page._on_hex()


func _set_mates(on: bool) -> void:
	_left.mates_tool_active = on
	_right.mates_tool_active = on
	if _mates_tool:
		_mates_tool.set_active(on)


func _set_drive(on: bool) -> void:
	var drive = _main.get("drive_tool") if _main != null else null
	_left.drive_tool_active = on
	_right.drive_tool_active = on
	if drive != null:
		drive.set_active(on)


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


func _choice_row(title: String, options: Array, selected: int, on_pick: Callable, per_row := 0) -> Control:
	## One of several choices as toggle buttons sharing a group. `per_row` > 0 wraps them into lines of that many (a long list would otherwise widen the page).
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.add_child(_hint(title))
	var row := _row()
	box.add_child(row)
	var group := ButtonGroup.new()
	for i in options.size():
		if per_row > 0 and i > 0 and i % per_row == 0:
			row = _row()
			box.add_child(row)
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
	page.add_child(_hint("To hide parts by pointing at them, use the Hide tool."))
	var rm = _main.room_manager if _main and _main.get("room_manager") else null
	if rm != null:
		page.add_child(_hint("Delete takes the selected part out of the assembly (its mates go too). Two presses; undo puts it back.", true))
		var del := _button(rm.delete_selected_label(), func() -> void: rm.delete_selected_press())
		rm.delete_state_changed.connect(func() -> void:
			if is_instance_valid(del):
				del.text = rm.delete_selected_label())
		page.add_child(del)
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

func _build_rooms_page() -> Control:
	## New room, then a tile per open room: its picture (room_thumbnail.gd), name and scale, Bring to me and Close.
	var page := _page(8)
	var rm = _main.room_manager if _main and _main.get("room_manager") else null
	if rm == null:
		page.add_child(_hint("Rooms are not available."))
		return page
	page.add_child(_button("New room", func() -> void: rm.new_room(), &"ButtonAccent"))
	var grid := GridContainer.new()
	grid.columns = ROOM_TILE_COLUMNS
	grid.add_theme_constant_override("h_separation", tokens.gap)
	grid.add_theme_constant_override("v_separation", tokens.gap)
	page.add_child(grid)
	var empty := _hint("No rooms open. New room makes an empty one; Room on an Assembly Tree row opens a sub-assembly in one.")
	page.add_child(empty)
	var fill := func() -> void:
		for c in grid.get_children():
			grid.remove_child(c)
			c.queue_free()
		empty.visible = rm.rooms.is_empty()
		for r in rm.rooms:
			grid.add_child(_room_tile(rm, r))
	fill.call()
	rm.rooms_changed.connect(fill)
	page.tree_exiting.connect(func() -> void:
		if rm.rooms_changed.is_connected(fill):
			rm.rooms_changed.disconnect(fill))
	return page


func _room_tile(rm, room) -> Control:
	var tile := PanelContainer.new()
	tile.theme_type_variation = &"PanelRaised"
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	tile.add_child(box)
	var picture := TextureRect.new()
	picture.custom_minimum_size = Vector2(0, ROOM_THUMB_HEIGHT)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.texture = UiIcons.texture("room", 96) # until the picture is ready, and for an empty room
	picture.modulate = room.colour
	box.add_child(picture)
	_fill_room_thumbnail(rm, room, picture)
	var name_l := Label.new()
	name_l.text = room.label
	name_l.clip_text = true
	box.add_child(name_l)
	var sub := _hint("%s%s" % [room.scale_text(), "  (minimised)" if room.minimised else ""], true)
	box.add_child(sub)
	var row := _row()
	row.add_child(_button("Bring to me", func() -> void: rm.bring_to_me(room)))
	row.add_child(_button("Close", func() -> void: rm.close_room(room), &"ButtonDanger"))
	box.add_child(row)
	return tile


func _fill_room_thumbnail(rm, room, picture: TextureRect) -> void:
	var texture: Texture2D = await rm.thumbnail(room)
	if texture != null and is_instance_valid(picture):
		picture.texture = texture
		picture.modulate = Color.WHITE


func _build_mates_page() -> Control:
	var page := _page(8)
	_mates_picks_label = _hint("")
	page.add_child(_mates_picks_label)
	var pick_buttons := _row()
	page.add_child(pick_buttons)
	pick_buttons.add_child(_button("Clear picks", func() -> void:
		if _mates_tool:
			_mates_tool.clear_picks()
	))
	pick_buttons.add_child(_button("Undo pick", func() -> void:
		if _mates_tool:
			_mates_tool.back_pick()
	))
	page.add_child(_choice_row("Mate type", MATE_TYPE_LABELS, 0, func(i: int) -> void:
		if _mates_tool:
			_mates_tool.mate_type = _mates_tool.MATE_TYPES[i]
	, 5))
	var toggles := _row()
	_mates_toggles_row = toggles
	page.add_child(toggles)
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
	var min_move := Button.new()
	min_move.text = "Minimal movement"
	min_move.tooltip_text = "On: move only the mated part when that is enough, and let connected parts follow only when it is not. Off: connected parts may always follow."
	min_move.toggle_mode = true
	min_move.button_pressed = true
	min_move.custom_minimum_size = Vector2(0, 56)
	min_move.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	min_move.toggled.connect(func(on: bool) -> void:
		if _mates_tool:
			_mates_tool.mate_minimal_movement = on
	)
	toggles.add_child(min_move)

	# Which orientation / side the preview shows - only the controls the picked geometry has (the backend's `controls`), shown by
	# _refresh_mates_branch_controls. Left alone, the backend picks the nearest ("auto"); a press names the branch.
	_mates_branch_label = _hint("")
	_mates_branch_label.visible = false
	page.add_child(_mates_branch_label)
	var branch_row := _row()
	page.add_child(branch_row)
	_mates_alignment_button = _branch_button("Orientation", func() -> void:
		if _mates_tool:
			_mates_tool.toggle_alignment())
	_mates_flip_button = _branch_button("Flip", func() -> void:
		if _mates_tool:
			_mates_tool.toggle_secondary_flip())
	_mates_next_button = _branch_button("Next solution", func() -> void:
		if _mates_tool:
			_mates_tool.next_solution())
	for b in [_mates_alignment_button, _mates_flip_button, _mates_next_button]:
		branch_row.add_child(b)

	var value_row := _row()
	page.add_child(value_row)
	_mates_value_label = Label.new()
	_mates_value_label.text = "Value: 0 (distance mm / angle deg; Width: offset from centre)"
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
	_mates_relax_button.text = "Relax mates"
	_mates_relax_button.toggle_mode = true
	_mates_relax_button.custom_minimum_size = Vector2(0, 56)
	_mates_relax_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Relax all mates is a sandbox (mates_tool.gd set_relaxed): on, moves are temporary; off ("Return parts"), everything goes back.
	_mates_relax_button.toggled.connect(func(on: bool) -> void:
		var scenes = _main.get("scenes_tool") if _main != null else null
		if not on and scenes != null and scenes.scene_unsaved():
			# Return parts would lose a scene's unsaved changes: the Scenes page asks first (Update / Discard / Stay).
			_mates_relax_button.set_pressed_no_signal(true)
			scenes.request_back()
			_open_tool.call("scenes")
			return
		_show_relax_state(on)
		if _mates_tool:
			_mates_tool.set_relaxed(on)
	)
	if _mates_tool and _mates_tool.has_signal("sandbox_changed"):
		_mates_tool.sandbox_changed.connect(func(on: bool) -> void:
			_mates_relax_button.set_pressed_no_signal(on)
			_show_relax_state(on))
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


func _branch_button(text: String, on_press: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.visible = false
	button.custom_minimum_size = Vector2(0, 56)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(on_press)
	return button


func _refresh_mates_branch_controls() -> void:
	## Shows exactly the branch controls the latest preview named, with their current values; Next solution only with two or more.
	if _mates_branch_label == null or _mates_tool == null:
		return
	var tool = _mates_tool
	if _mates_toggles_row != null:
		_mates_toggles_row.visible = not tool.is_coupler() and not tool.is_limit()
	var text: String = tool.branch_text()
	_mates_branch_label.text = text
	_mates_branch_label.visible = text != ""
	_mates_alignment_button.visible = tool.branch_controls.has("alignment")
	_mates_alignment_button.text = "%s: %s" % [_MatesTool.alignment_title(tool.mate_type), _MatesTool.alignment_label(tool.mate_type, tool.shown_alignment())]
	_mates_flip_button.visible = tool.branch_controls.has("secondary_flip")
	_mates_flip_button.text = "%s: %s" % [_MatesTool.secondary_flip_label(tool.mate_type), "on" if tool.flip_is_on() else "off"]
	if _mates_value_label != null and tool.is_coupler():
		_mates_value_label.text = _coupler_value_label(tool)
	elif _mates_value_label != null and tool.is_limit():
		_mates_value_label.text = _limit_value_label(tool)
	var steps: int = tool.branch_alternatives.size()
	_mates_next_button.visible = steps > 1
	var index: int = _MatesTool.alternative_index(tool.branch_alternatives, tool.shown_alignment(), tool.shown_secondary_flip())
	_mates_next_button.text = "Next solution (%d of %d)" % [index + 1, steps] if index >= 0 else "Next solution (%d)" % steps


func _on_mates_selected() -> void:
	var owner_part_id: String = _main.current_root_part_id() if _main else ""
	if _mates_tool and owner_part_id != "":
		_mates_last_owner_part_id = owner_part_id
		_mates_tool.refresh_mates(owner_part_id)


func _on_mate_row_selected(mate_id: String) -> void:
	## T3: a mate row tapped in the list: its two entities light up (a second tap, or leaving the list, puts them out).
	if _mates_tool == null:
		return
	var camera: Camera3D = _main.get_node_or_null("XROrigin3D/XRCamera3D") if _main != null else null
	_mates_tool.highlight_mate(mate_id, camera)


func _mates_status() -> String:
	return _mates_tool.status_text() if _mates_tool else ""


func _coupler_value_label(tool) -> String:
	## The value line of a coupler mate: what the value is, what it is now ("Auto" shows what the backend would take from the teeth).
	var shown := ""
	if tool.mate_value > 0.0:
		shown = _trim_mate_value(tool.mate_value)
	elif tool.mate_type == "screw":
		shown = "(set it)"
	else:
		shown = "Auto" if tool.preview_coupler_value <= 0.0 else "Auto = %s" % _MatesTool.coupler_value_text(tool.mate_type, tool.preview_coupler_value)
	return "%s: %s" % [_MatesTool.value_prompt(tool.mate_type).split(" (")[0], shown]


func _limit_value_label(tool) -> String:
	## The value line of a limit mate: its range as typed so far, and where the picked pair is now.
	var range_text: String = _MatesTool.limit_range_text(tool.mate_type, tool.limit_min, tool.limit_max)
	var now: String = _MatesTool.limit_now_text(tool.mate_type, tool.preview_limit_value)
	return "Range: %s%s" % ["(set it)" if range_text == "" else range_text, "" if now == "" else "  (%s)" % now.trim_suffix(".")]


func _ask_limit_range(type: String, lo, hi, on_done: Callable) -> void:
	## Two keyboards, minimum then maximum (empty = no bound on that side); `on_done(lo, hi)` gets the pair only if both parsed and form a range.
	var unit := "degrees" if type == "limit_angle" else "mm"
	_main.open_keyboard_for("" if lo == null else _trim_mate_value(lo), func(min_text: String) -> void:
		var parsed_min: Dictionary = _MatesTool.parse_limit_bound(type, min_text)
		if not parsed_min["ok"]:
			toast.emit(str(parsed_min["error"]), "error")
			return
		_main.open_keyboard_for("" if hi == null else _trim_mate_value(hi), func(max_text: String) -> void:
			var parsed_max: Dictionary = _MatesTool.parse_limit_bound(type, max_text)
			if not parsed_max["ok"]:
				toast.emit(str(parsed_max["error"]), "error")
				return
			var problem: String = _MatesTool.limit_range_error(parsed_min["value"], parsed_max["value"])
			if problem != "":
				toast.emit(problem, "error")
				return
			on_done.call(parsed_min["value"], parsed_max["value"])
		, {"title": "Maximum (%s, empty = none)" % unit})
	, {"title": "Minimum (%s, empty = none)" % unit})


func _on_set_mate_value_pressed() -> void:
	if not _mates_tool:
		return
	if _mates_tool.is_limit():
		_ask_limit_range(_mates_tool.mate_type, _mates_tool.limit_min, _mates_tool.limit_max, func(lo, hi) -> void:
			_mates_tool.limit_min = lo
			_mates_tool.limit_max = hi
			_mates_value_label.text = _limit_value_label(_mates_tool))
		return
	if _mates_tool.is_coupler():
		_main.open_keyboard_for(_trim_mate_value(_mates_tool.mate_value) if _mates_tool.mate_value > 0.0 else "", func(text: String) -> void:
			var parsed: Dictionary = _MatesTool.parse_value(_mates_tool.mate_type, text)
			if not parsed["ok"]:
				toast.emit(str(parsed["error"]), "error")
				return
			_mates_tool.mate_value = float(parsed["value"])
			_mates_value_label.text = _coupler_value_label(_mates_tool)
		, {"title": _MatesTool.value_prompt(_mates_tool.mate_type)})
		return
	_main.open_keyboard_for(_trim_mate_value(_mates_tool.width_offset if _mates_tool.is_width() else _mates_tool.mate_value), func(text: String) -> void:
		# A Width mate's value is its offset from the centre: a distance (never negative; empty / 0 = centred exactly).
		var is_width: bool = _mates_tool.is_width()
		var parsed: Dictionary = _MatesTool.parse_value("distance" if is_width else _mates_tool.mate_type, text)
		if not parsed["ok"]:
			toast.emit(str(parsed["error"]), "error")
			return
		if is_width:
			_mates_tool.width_offset = float(parsed["value"])
			_mates_value_label.text = "Offset from centre: %s mm (0 = centred)" % _trim_mate_value(_mates_tool.width_offset)
			return
		_mates_tool.mate_value = float(parsed["value"])
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
		var is_width_mate := false
		for ref in mate.get("references", []):
			if ref is Dictionary and ref.get("midplane") != null:
				is_width_mate = true
		var refs_list: Array = mate.get("references", [])
		var is_symmetric_mate: bool = refs_list.size() == 2 and refs_list[0] is Dictionary and refs_list[0].get("midplane") != null and refs_list[1] is Dictionary and refs_list[1].get("midplane") == null
		var type_label: String = "Symmetric" if is_symmetric_mate else ("Width" if is_width_mate else _MatesTool.type_label(type_str))
		var is_coupler_mate: bool = type_str in _MatesTool.COUPLER_TYPES
		var is_limit_mate: bool = type_str in _MatesTool.LIMIT_TYPES
		var has_value: bool = mate.get("value") != null and not is_coupler_mate
		var mate_id := str(mate.get("id", ""))
		var free_spin := bool(mate.get("allow_rotation", true))
		var alignment = mate.get("alignment")
		var secondary = mate.get("secondary_flip")
		var notes := []
		if is_coupler_mate:
			notes.append(_MatesTool.coupler_value_text(type_str, mate.get("value"))) # (the raw sense means nothing on its own: only the Reverse action shows it)
		if is_limit_mate:
			notes.append(_MatesTool.limit_range_text(type_str, mate.get("limit_min"), mate.get("limit_max")))
			if mate.get("limit_value") != null:
				notes.append("now %s%s" % [_trim_mate_value(mate["limit_value"]), _MatesTool.limit_unit(type_str)])
		if alignment != null:
			notes.append(("swing %s" % _MatesTool.alignment_label(type_str, str(alignment))) if type_str == "angle" else ("aligned" if str(alignment) == "aligned" else "anti-aligned"))
		if secondary != null and not is_coupler_mate:
			notes.append("%s %s" % [_MatesTool.secondary_flip_label(type_str).to_lower(), "on" if bool(secondary) else "off"])
		if type_str == "concentric":
			notes.append("free to spin" if free_spin else "rotation locked")
		# Only the branch fields this mate's geometry uses are set on it (the backend leaves the others null): one action for each.
		var actions := []
		if alignment != null:
			actions.append({"label": "Flip swing" if type_str == "angle" else "Flip orientation", "callback": _on_edit_mate.bind(mate_id, {"alignment": "anti_aligned" if str(alignment) == "aligned" else "aligned"})})
		if secondary != null:
			actions.append({"label": _MatesTool.secondary_flip_label(type_str), "callback": _on_edit_mate.bind(mate_id, {"secondary_flip": not bool(secondary)})})
		if type_str == "concentric":
			actions.append({"label": "Lock rotation" if free_spin else "Free rotation", "callback": _on_edit_mate.bind(mate_id, {"allow_rotation": not free_spin})})
		if type_str in ["distance", "angle"] or is_coupler_mate:
			actions.append({"label": "Value", "callback": _on_edit_mate_value.bind(mate_id, mate.get("value"))})
		if is_limit_mate:
			actions.append({"label": "Range", "callback": _on_edit_limit_range.bind(mate_id, type_str, mate.get("limit_min"), mate.get("limit_max"))})
		actions.append({"label": "Delete", "danger": true, "confirm": true, "callback": _on_delete_mate_pressed.bind(mate_id)})
		# A mate the backend computes as broken (its residual at the stored poses is above tolerance, a limit is outside its range, or a reference
		# no longer resolves - e.g. a pattern edit its part could not follow): "Broken" after the name, in the theme's error colour.
		var broken: bool = _MatesTool.is_broken(mate)
		if broken:
			notes.push_front("can't be satisfied")
		rows.append({
			"id": mate_id, "selectable": true,
			"title": "%s%s%s" % [type_label, (" (%s)" % _trim_mate_value(mate.get("value"))) if has_value else "", " - Broken" if broken else ""],
			"subtitle": ", ".join(notes), "state": "error" if broken else "normal", "broken": broken,
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


func _on_edit_limit_range(mate_id: String, type_str: String, lo, hi) -> void:
	if _mates_tool == null or _main == null:
		return
	_ask_limit_range(type_str, lo, hi, func(new_lo, new_hi) -> void:
		_on_edit_mate(mate_id, {"limit_min": new_lo, "limit_max": new_hi}))


func _on_edit_mate_value(mate_id: String, current) -> void:
	if _mates_tool == null or _main == null:
		return
	_main.open_keyboard_for(_trim_mate_value(current if current != null else 0.0), func(text: String) -> void:
		var type_str := ""
		for mate in _mates_tool.mates:
			if str(mate.get("id", "")) == mate_id:
				type_str = str(mate.get("type", ""))
		var parsed: Dictionary = _MatesTool.parse_value(type_str, text, false) # an existing mate has no Auto
		if not parsed["ok"]:
			toast.emit(str(parsed["error"]), "error")
			return
		_on_edit_mate(mate_id, {"value": float(parsed["value"])})
	)


func _on_delete_mate_pressed(mate_id: String) -> void:
	if _mates_tool and _mates_last_owner_part_id != "" and mate_id != "":
		await _mates_tool.delete_mate(_mates_last_owner_part_id, mate_id)


func _trim_mate_value(x) -> String:
	return ("%.3f" % float(x)).rstrip("0").rstrip(".")


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


# --- Assembly: Drive ---------------------------------------------------------------------

func _build_drive_page() -> Control:
	var page := _page()
	page.add_child(_hint("Right stick sideways: speed. A: keep running. B: stop.", true))
	page.add_child(_button("Stop", func() -> void:
		var drive = _main.get("drive_tool") if _main != null else null
		if drive != null:
			drive.stop()
	))
	return page


func _drive_status() -> String:
	var drive = _main.get("drive_tool") if _main != null else null
	if drive == null or not drive.active:
		return "Off: switch the tool on, then pick the round face to turn."
	return drive.status_text()


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

var _files_folder_label: Label

func _build_files_page() -> Control:
	var page := _page()
	page.add_child(_hint("Loads from res://models, user://models, and the Settings project folder. Pick Open or Add beside the tablet."))
	_files_folder_label = _hint("")
	_files_folder_label.name = "FilesFolder"
	page.add_child(_files_folder_label)
	if _main != null:
		_files_folder_label.text = _main.folder_label()
	_files_count_label = Label.new()
	page.add_child(_files_count_label)
	_dirty_label = _hint("")
	_dirty_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3))
	page.add_child(_dirty_label)
	if _main != null:
		_main.dirty_changed.connect(func(_d: bool) -> void: _refresh_dirty_label())
	_refresh_dirty_label()
	page.add_child(_build_discard_box())
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


func _build_discard_box() -> VBoxContainer:
	## The choice main.confirm_discard() asks for when an Open would lose unsaved changes: discard them and open, save first, or cancel.
	_discard_box = VBoxContainer.new()
	_discard_box.add_theme_constant_override("separation", tokens.gap)
	_discard_label = _hint("")
	_discard_label.add_theme_color_override("font_color", tokens.warn)
	_discard_box.add_child(_discard_label)
	var row := _row()
	row.add_child(_button("Discard and open", func() -> void:
		await _main.discard_and_continue()
		_rescan_files(), &"ButtonDanger"))
	row.add_child(_button("Save, then open", func() -> void:
		await _main.save_and_continue()
		_rescan_files(), &"ButtonAccent"))
	row.add_child(_button("Cancel", func() -> void: _main.cancel_discard()))
	_discard_box.add_child(row)
	if _main != null:
		_main.discard_prompt_changed.connect(_refresh_discard_box)
	_refresh_discard_box()
	return _discard_box


func _refresh_discard_box() -> void:
	if not is_instance_valid(_discard_box) or _main == null:
		return
	var what: String = _main.pending_discard()
	_discard_box.visible = what != ""
	_discard_label.text = "You have unsaved changes. \"%s\" will lose them." % what


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
	if _files_folder_label != null:
		_files_folder_label.text = _main.folder_label()
	for path in _main.list_model_files():
		var native: bool = NativeCompose.native_extension(path) != ""
		_files_cache.append({"path": path, "native": native, "root_id": _main.native_file_root_part_id(path) if native else ""})
	if _files_count_label:
		_files_count_label.text = "%d model file(s) found" % _files_cache.size()


# --- Files > References: finding moved files (DIDSA-CAD docs/moved-files-scope.md, F2) ---------------------------------

func _build_references_page() -> Control:
	var page := _page()
	page.add_child(_hint("Files the opened assembly places that moved or are missing. The choices are beside the tablet."))
	page.add_child(_hint("The project folder (Settings) and the models folders are searched, every subfolder included.", true))
	return page


func _references_status() -> String:
	if _main == null:
		return ""
	var r: Dictionary = _main.reference_review()
	if str(r["root"]) == "":
		return "Open a native assembly first."
	if _locate_key != "":
		return "Locate the file for %s." % _locate_ref.get_file()
	return "%s: %d found in a new place, %d to review." % [str(r["root"]).get_file(), (r["relinked"] as Array).size(), (r["review"] as Array).size()]


func _references_rows() -> Array:
	var rows := []
	if _main == null:
		return rows
	if _locate_key != "":
		rows.append({"id": "locate", "title": "Locate %s" % _locate_ref.get_file(), "subtitle": "Pick the file this reference should place.",
			"state": "normal", "actions": [{"label": "Cancel", "callback": _cancel_locate}]})
		for f in _locate_files:
			rows.append(_candidate_row(_locate_key, _locate_ref_id, f))
		return rows
	var r: Dictionary = _main.reference_review()
	for m in r["relinked"]:
		var how := "picked by you" if m["via"] == "choice" else "found by its part id"
		rows.append({"id": "moved:" + str(m["key"]), "title": "%s -> %s" % [str(m["ref"]).get_file(), m["path"]],
			"subtitle": "Moved, %s%s. Save as new file writes the new path." % [how, "; the file at the old path is a different part" if m["path_mismatch"] else ""], "state": "ok"})
	for item in r["review"]:
		var ref := str(item["ref"])
		var why := "Not found in the project folder or the models folders."
		match str(item["result"]):
			"ask":
				why = "Moved, and %d files carry this part (copies?). Pick the right one; nothing is loaded until you do." % (item["candidates"] as Array).size()
			"suggest":
				why = ("The file at %s is a different part." % ref) if item["path_mismatch"] else "Not found. A file with the same name is elsewhere; it may be a different part."
		rows.append({"id": "ref:" + str(item["key"]), "title": ref.get_file(), "subtitle": why, "state": "warn" if item["result"] != "missing" else "error",
			"actions": [{"label": "Locate...", "callback": _start_locate.bind(str(item["key"]), ref, str(item["ref_part_id"]))},
				{"label": "Leave missing", "callback": _main.leave_reference_missing.bind(str(item["key"]))}]})
		for c in item["candidates"]:
			rows.append(_candidate_row(str(item["key"]), str(item["ref_part_id"]), c))
	return rows


func _candidate_row(key: String, ref_part_id: String, c: Dictionary) -> Dictionary:
	## One file that could be the reference's: Use re-opens the assembly with it. A file that is not the placed part (another id, or one
	## that couldn't be read) needs a second press: never a silent swap.
	var same := ref_part_id != "" and str(c["part_id"]) == ref_part_id
	return {"id": "use:%s:%s" % [key, c["file"]], "title": str(c["path"]),
		"subtitle": "The placed part." if same else "A different part, or one that couldn't be read: press Use twice to use it anyway.",
		"state": "normal" if same else "warn",
		"actions": [{"label": "Use", "accent": same, "confirm": not same, "callback": _use_reference.bind(key, str(c["file"]))}]}


func _use_reference(key: String, file: String) -> void:
	_cancel_locate()
	_main.choose_reference(key, file)


func _start_locate(key: String, ref: String, ref_part_id: String) -> void:
	_locate_key = key
	_locate_ref = ref
	_locate_ref_id = ref_part_id
	_locate_files = _main.reference_files() if _main != null else []


func _cancel_locate() -> void:
	_locate_key = ""
	_locate_files = []


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
		_main.room_manager.apply_steadiness(i) # and each Assembly Room's whole-room moves
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
	page.add_child(_choice_row("MSAA", ["Off", "2x", "4x"], _main.msaa_level() if _main else 2, func(i: int) -> void: _main.set_msaa(i))) # the project starts at 4x (msaa_3d = 2)
	page.add_child(_mode_toggle("Relaxed: ghost where each part goes back", func(on: bool) -> void: _main.set_sandbox_ghosts(on), _main.sandbox_ghosts()))
	page.add_child(_mode_toggle("Relaxed: line to where it goes back", func(on: bool) -> void: _main.set_sandbox_lines(on), _main.sandbox_lines()))
	page.add_child(_choice_row("Sub-assembly grip dead zone", ["Off", "Small (2 cm)", "Medium (4 cm)"], _main.group_deadzone_level(), func(i: int) -> void: _main.set_group_deadzone(i)))
	var room_limits := [1, 2, 3, 4, 6, 8]
	page.add_child(_choice_row("Max rooms", ["1", "2", "3", "4", "6", "8"], maxi(room_limits.find(_main.max_rooms()), 3), func(i: int) -> void: _main.set_max_rooms(room_limits[i])))
	return page


func _show_relax_state(on: bool) -> void:
	_mates_relax_button.text = "Return parts" if on else "Relax mates"


func _build_settings_appearance() -> Control:
	var page := _page(14)
	page.add_child(_choice_row("Theme", UiThemes.ORDER, maxi(UiThemes.ORDER.find(_main.ui_theme()), 0), func(i: int) -> void: _main.set_ui_theme(UiThemes.ORDER[i])))
	page.add_child(_mode_toggle("Shader effects", func(on: bool) -> void: _main.set_fx_enabled(on), _main.fx_enabled()))
	page.add_child(_mode_toggle("Glass room walls", func(on: bool) -> void: _main.set_room_glass(on), _main.room_glass()))
	page.add_child(_mode_toggle("Auto-update world preview", func(on: bool) -> void: _main.set_world_preview_auto(on), _main.world_preview_auto()))
	page.add_child(_mode_toggle("Pulse world preview", func(on: bool) -> void: _main.set_world_preview_pulse(on), _main.world_preview_pulse()))
	page.add_child(_mode_toggle("Room console pedestal", func(on: bool) -> void: _main.set_room_pedestal(on), _main.room_pedestal()))
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
	page.add_child(_mode_toggle("Tool wheel (right trigger + grip)", func(on: bool) -> void: _main.set_wheel_enabled(on), _main.wheel_enabled()))
	page.add_child(_choice_row("Wheel size", ["Small", "Normal", "Large"], _main.wheel_size(), func(i: int) -> void: _main.set_wheel_size(i)))
	return page


func _build_settings_folder() -> Control:
	## T1: the project folder. Shows the real path, whether it can be written to and how many model files it holds; a laser folder chooser
	## replaces typing (typing stays as a secondary button); All files access is offered for files other apps put there.
	var page := _page(14)
	_folder_box = VBoxContainer.new()
	_folder_box.add_theme_constant_override("separation", 10)
	page.add_child(_folder_box)
	_rebuild_folder_page(false)
	return page


var _folder_box: VBoxContainer


func _rebuild_folder_page(choosing: bool) -> void:
	if _folder_box == null or _main == null:
		return
	for child in _folder_box.get_children():
		_folder_box.remove_child(child)
		child.queue_free()
	if choosing:
		var chooser := FolderChooser.new()
		chooser.name = "FolderChooser"
		_folder_box.add_child(chooser)
		chooser.setup(_main, _main.project_folder())
		chooser.chosen.connect(func(_p: String) -> void: _rebuild_folder_page(false))
		chooser.cancelled.connect(func() -> void: _rebuild_folder_page(false))
		return
	_folder_box.add_child(_hint("Where saves go, and where the Files tool looks besides res://models and user://models."))
	_project_folder_label = Label.new()
	_project_folder_label.name = "FolderStatus"
	_project_folder_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_folder_box.add_child(_project_folder_label)
	_refresh_project_folder_label()
	_folder_box.add_child(_button("Choose folder...", func() -> void: _rebuild_folder_page(true)))
	_folder_box.add_child(_button("Use Documents/DIDSA", func() -> void:
		_main.use_default_project_folder()
		_rebuild_folder_page(false)))
	_folder_box.add_child(_button("Keep in app storage", func() -> void:
		_main.keep_in_app_storage()
		_rebuild_folder_page(false)))
	_folder_box.add_child(_button("Type a path...", _on_set_project_folder_pressed))
	_folder_box.add_child(_hint("On the headset (Android scoped storage) a folder can be read only if this app made the files, or All files access is on. It is needed to open files copied in by USB or from the flat app."))
	var access := _hint(_main.all_files_access_text())
	access.name = "AllFilesState"
	_folder_box.add_child(access)
	_folder_box.add_child(_button("Allow opening files from other apps", func() -> void:
		_main.request_all_files_access()
		access.text = _main.all_files_access_text()))


func _build_settings_table() -> Control:
	var page := _page(14)
	if _design_table == null or _main == null or _main.app_settings() == null:
		page.add_child(_hint("The design table isn't available here."))
		return page
	var settings = _main.app_settings()
	var table = _design_table
	if table.get("world_preview") != null:
		var preview_text := func() -> String:
			return "Table part, in the world: %s" % table.world_preview.WorldPreview.MODE_NAMES[int(table.world_preview.mode)] if table.world_preview.available() else "Table part, in the world: put a part on the design table first"
		var world_button := _button(preview_text.call(), func() -> void: pass)
		world_button.pressed.connect(func() -> void:
			if table.world_preview.available():
				table.world_preview.cycle()
			world_button.text = preview_text.call())
		page.add_child(world_button)
	page.add_child(_choice_row("A part sent back to the arena", ["Original turn", "As turned"], 1 if settings.table_keep_turn else 0, func(i: int) -> void:
		_design_table.keep_turn_on_return = i == 1
		settings.set_table_keep_turn(i == 1)))
	page.add_child(_choice_row("Sketch sheet", ["Front (hinged)", "Middle"], 0 if settings.table_sheet_front else 1, func(i: int) -> void:
		_design_table.sketch_sheet_front = i == 0
		settings.set_table_sheet(i == 0, settings.table_sheet_lean)))
	var leans := [10, 15, 25]
	var lean_now := leans.find(settings.table_sheet_lean)
	page.add_child(_choice_row("Front sheet leans back", ["10°", "15°", "25°"], lean_now if lean_now >= 0 else 1, func(i: int) -> void:
		_design_table.sketch_lean_back_degrees = float(leans[i])
		settings.set_table_sheet(settings.table_sheet_front, leans[i])))
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
		var path := text.strip_edges()
		if path.is_empty():
			_main.keep_in_app_storage()
		else:
			_main.use_project_folder(path) # refused, with the reason in the status line, if it can't be written
		_rebuild_folder_page(false)
	, {"mode": "full", "title": "Project folder (absolute path)", "confirm_label": "Set"})


func _refresh_project_folder_label() -> void:
	if not _project_folder_label:
		return
	var path: String = _main.project_folder()
	var where := "App storage (no project folder)" if path.is_empty() else "Project folder"
	_project_folder_label.text = "%s\n%s" % [where, ProjectFolder.status_line(path)]
