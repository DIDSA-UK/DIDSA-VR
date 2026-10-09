extends Control
## The design table's tool deck, from John's concept sketch (test round 9 Oct 2026). Two
## kinds of control, kept apart:
##   * LEFT, the tool area: a row of category tabs; under the selected tab a framed panel in
##     that category's colour, joined to the tab by a caret, holding the tool list (two rows of
##     small buttons that scrolls sideways when there are more than fit), then Exit sketch (leaves the open sketch). The tool tip and the active
##     tool's own settings (polygon sides, Boss or Cut, depth...) live in the Properties panel
##     (table_props_window.gd); a row inside the frame holds the settings when there is none.
##   * RIGHT, the generic controls: Undo, Redo, Close, Snap, Fit, Reset, To arena, Orbit lock. Undo, Redo and Close are in the top right. They are not
##     about one tool and are always where you left them; one that cannot mean anything right now
##     (no part on the table, no sketch open) is hidden rather than greyed.
## Glyphs carry colour (green Exit sketch, red Close, amber Undo...) so a button reads without its label.
##
## Pure 2D Controls, like tablet_ui.gd: no XR, no scene-tree dependency beyond itself,
## so it runs on a SubViewport quad (design_table.gd) and in a plain window (the UI
## Lab) alike. It never names a specific tool: everything comes from the registry
## (scripts/ui/tablet_registry.gd, filled by table_tools.gd), the one-active-tool rule
## from the tool manager (scripts/ui/tool_manager.gd) and the tool list that scrolls sideways.
## Styling is the shared UI theme (ui/didsa_ui_theme.tres): the same
## ButtonRail buttons, per-category accent and selected look as the wrist tablet.

signal option_pressed(option_id: String)
signal snap_toggled(on: bool)
signal undo_pressed
signal redo_pressed ## "Redo": puts back the feature (or Build-tree edit) Undo just took back
signal reset_pressed ## "Reset": the part back to the middle of the slab at its fitted size, sketch plane flat
signal part_lock_toggled(locked: bool) ## "Orbit lock On / Off" while a sketch is open: Locked keeps the tilt and the plane (grips slide the part under the sketch window and zoom it), Free lets them move, turn and scale the part anywhere
signal done_pressed ## "Exit sketch": leave the open sketch (the part is refreshed if it was changed)
signal fit_pressed ## "Fit": slide and zoom the part so the sketch fills the sketch window
signal return_pressed ## "To arena": the real part goes back where it came from
signal close_requested
signal feedback(event: String) ## "press" / "error": the host turns it into a haptic pulse and a sound
signal activity ## something on screen changed that the host's render gate should know about

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const FxOverlay := preload("res://scripts/ui/fx_overlay.gd")

const TOOL_BUTTON := Vector2(140, 52) ## a tool-list button: small enough that most categories fit without scrolling
const GENERIC_ICON_BUTTON := Vector2(70, 52)
const GENERIC_LABEL_BUTTON := Vector2(150, 52)
const VIOLET := Color(0.78, 0.55, 0.98)


class Connector extends Control:
	## The caret under the selected category tab that joins it to the tool frame below, in the
	## category's colour: it shows which tab the tools belong to.
	var tab: Control = null
	var colour := Color.WHITE

	func _draw() -> void:
		if tab == null or not is_instance_valid(tab) or not tab.is_inside_tree() or not is_inside_tree():
			return
		var cx := tab.get_global_rect().get_center().x - get_global_rect().position.x
		var h := size.y
		draw_colored_polygon(PackedVector2Array([Vector2(cx - 14.0, h), Vector2(cx, 1.0), Vector2(cx + 14.0, h)]), colour)

var tokens: Resource
var registry
var manager
var selected_category_id := ""

var _panel: PanelContainer
var _cat_row: HBoxContainer
var _tool_frame: PanelContainer
var _tool_scroll: ScrollContainer
var _tool_columns: HBoxContainer
var _scroll_left: Button
var _scroll_right: Button
var _connector: Control
var _options_row: HBoxContainer
var _status := "" ## the tool tip text: shown in the side panel (table_props_window.gd), kept here for the host and tests
var _snap_button: Button
var _undo_button: Button
var _redo_button: Button
var _close_button: Button
var _reset_button: Button
var _return_button: Button
var _lock_button: Button
var _fit_button: Button
var _done_button: Button
var _active_chip: Label
var _fx: ColorRect
var _cat_group := ButtonGroup.new()
var _cat_buttons := {}
var _tool_buttons := {}
var _options: Array = []
var options_sink = null ## table_props_window.gd: when set, the active tool's settings go there and this deck's own options row stays hidden
var _seen_revision := -1


func setup(p_tokens: Resource, p_registry, p_manager) -> void:
	tokens = p_tokens
	registry = p_registry
	manager = p_manager
	theme = tokens.build_theme()
	_seen_revision = UiThemes.revision
	_build_shell()
	rebuild()
	manager.active_changed.connect(func(_id: String) -> void:
		_refresh_tool_visuals()
		activity.emit())
	registry.changed.connect(rebuild, CONNECT_DEFERRED)


# --- Shell ----------------------------------------------------------------------

func _build_shell() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", tokens.gap + 4)
	_panel.add_child(main)

	# --- Left: the tool area ---
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_child(left)

	_cat_row = HBoxContainer.new()
	_cat_row.add_theme_constant_override("separation", tokens.gap)
	_cat_row.sort_children.connect(_update_connector)
	left.add_child(_cat_row)

	_connector = Connector.new()
	_connector.custom_minimum_size = Vector2(0, 12)
	_connector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(_connector)

	_tool_frame = PanelContainer.new()
	_tool_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(_tool_frame)
	var frame_column := VBoxContainer.new()
	frame_column.add_theme_constant_override("separation", tokens.gap)
	_tool_frame.add_child(frame_column)

	var tool_line := HBoxContainer.new()
	tool_line.add_theme_constant_override("separation", 4)
	frame_column.add_child(tool_line)
	_scroll_left = _scroll_arrow("\u2039", -1)
	tool_line.add_child(_scroll_left)
	_tool_scroll = ScrollContainer.new()
	_tool_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER ## the arrows scroll it; a bar would be one more thing to aim at
	_tool_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tool_scroll.custom_minimum_size = Vector2(0, TOOL_BUTTON.y * 2.0 + tokens.gap)
	tool_line.add_child(_tool_scroll)
	_tool_columns = HBoxContainer.new()
	_tool_columns.add_theme_constant_override("separation", tokens.gap)
	_tool_scroll.add_child(_tool_columns)
	_scroll_right = _scroll_arrow("\u203a", 1)
	tool_line.add_child(_scroll_right)

	_options_row = HBoxContainer.new()
	_options_row.add_theme_constant_override("separation", tokens.gap)
	_options_row.visible = false
	frame_column.add_child(_options_row)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", tokens.gap)
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame_column.add_child(bottom)
	_active_chip = Label.new()
	_active_chip.text = "TABLE ACTIVE"
	_active_chip.theme_type_variation = &"LabelSmall"
	_active_chip.visible = false
	_active_chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_active_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_active_chip.add_theme_color_override("font_color", tokens.accent)
	_active_chip.add_theme_font_size_override("font_size", tokens.font_small + 3)
	bottom.add_child(_active_chip)
	_done_button = _utility("enforce", "Exit sketch", false) ## tool-specific: it leaves the sketch that is open
	_done_button.disabled = true
	_done_button.visible = false
	_done_button.pressed.connect(func() -> void:
		feedback.emit("press")
		done_pressed.emit())
	bottom.add_child(_done_button)


	# --- Right: the generic controls ---
	var generic_divider := VSeparator.new()
	main.add_child(generic_divider)
	var generic := VBoxContainer.new()
	generic.add_theme_constant_override("separation", tokens.gap)
	generic.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(generic)
	var top_row := HBoxContainer.new() ## Undo, Redo and Close in the dock's top right corner, level with the tabs
	top_row.add_theme_constant_override("separation", tokens.gap)
	top_row.alignment = BoxContainer.ALIGNMENT_END
	top_row.custom_minimum_size = Vector2(0, 64)
	generic.add_child(top_row)
	var top_gap := Control.new()
	top_gap.custom_minimum_size = Vector2(0, 12)
	generic.add_child(top_gap)
	_undo_button = _utility("undo", "", false)
	_undo_button.disabled = true
	_undo_button.pressed.connect(func() -> void:
		feedback.emit("press")
		undo_pressed.emit())
	top_row.add_child(_undo_button)
	_redo_button = _utility("redo", "", false)
	_redo_button.disabled = true
	_redo_button.pressed.connect(func() -> void:
		feedback.emit("press")
		redo_pressed.emit())
	top_row.add_child(_redo_button)
	_close_button = _utility("close", "", false)
	_close_button.theme_type_variation = &"ButtonDanger"
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	top_row.add_child(_close_button)

	var view_row := HBoxContainer.new()
	view_row.add_theme_constant_override("separation", tokens.gap)
	generic.add_child(view_row)
	_snap_button = _utility("snap", "Snap", true)
	_snap_button.set_pressed_no_signal(true)
	_snap_button.toggled.connect(func(on: bool) -> void:
		feedback.emit("press")
		snap_toggled.emit(on))
	view_row.add_child(_snap_button)
	_fit_button = _utility("fit", "Fit", false)
	_fit_button.disabled = true
	_fit_button.visible = false
	_fit_button.pressed.connect(func() -> void:
		feedback.emit("press")
		fit_pressed.emit())
	view_row.add_child(_fit_button)

	var part_row := HBoxContainer.new()
	part_row.add_theme_constant_override("separation", tokens.gap)
	generic.add_child(part_row)
	_reset_button = _utility("recentre", "Reset", false)
	_reset_button.disabled = true
	_reset_button.visible = false
	_reset_button.pressed.connect(func() -> void:
		feedback.emit("press")
		reset_pressed.emit())
	part_row.add_child(_reset_button)
	_return_button = _utility("to_arena", "To arena", false)
	_return_button.disabled = true
	_return_button.visible = false
	_return_button.pressed.connect(func() -> void:
		feedback.emit("press")
		return_pressed.emit())
	part_row.add_child(_return_button)

	var lock_row := HBoxContainer.new()
	lock_row.add_theme_constant_override("separation", tokens.gap)
	generic.add_child(lock_row)
	_lock_button = _utility("lock", "Orbit lock: On", true)
	_lock_button.custom_minimum_size.x = GENERIC_LABEL_BUTTON.x * 2.0 + tokens.gap
	_lock_button.set_pressed_no_signal(true)
	_lock_button.disabled = true
	_lock_button.visible = false
	_lock_button.toggled.connect(func(on: bool) -> void:
		_lock_button.text = "Orbit lock: On" if on else "Orbit lock: Off"
		feedback.emit("press")
		part_lock_toggled.emit(on))
	lock_row.add_child(_lock_button)

	_tint_glyphs()
	_style_frame()

	_fx = FxOverlay.new() # last child of the root, so the glass sits over everything but the laser cursor the host adds after
	add_child(_fx)
	_fx.setup(tokens)


func _utility(icon_name: String, text: String, toggle: bool) -> Button:
	var b := Button.new()
	b.icon = UiIcons.texture(icon_name, 28)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if text == "" else HORIZONTAL_ALIGNMENT_LEFT
	b.text = text
	b.toggle_mode = toggle
	b.clip_text = true
	b.custom_minimum_size = GENERIC_ICON_BUTTON if text == "" else GENERIC_LABEL_BUTTON
	b.add_theme_font_size_override("font_size", tokens.font_small)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER # one row tall like the other buttons, not stretched to the status line
	return b


func _scroll_arrow(glyph: String, direction: int) -> Button:
	var b := Button.new()
	b.text = glyph
	b.custom_minimum_size = Vector2(40, TOOL_BUTTON.y * 2.0 + tokens.gap)
	b.add_theme_font_size_override("font_size", tokens.font_title)
	b.visible = false
	b.pressed.connect(func() -> void:
		feedback.emit("press")
		scroll_tools(direction))
	return b


func scroll_tools(direction: int) -> void:
	## Slides the tool list by most of its width (the arrows at its ends).
	_tool_scroll.scroll_horizontal = maxi(0, _tool_scroll.scroll_horizontal + direction * int(_tool_scroll.size.x * 0.8))
	activity.emit()


func _tint_glyphs() -> void:
	## The glyphs carry colour, so a button reads without its label: green Done, red Close, amber for
	## taking back and starting over, the table's own colours for the rest. (Per-button overrides on
	## top of the theme, so they are re-applied when the theme changes.)
	_tint(_done_button, tokens.ok)
	_tint(_close_button, tokens.danger)
	_tint(_undo_button, tokens.warn)
	_tint(_redo_button, tokens.warn)
	_tint(_reset_button, tokens.warn)
	_tint(_lock_button, tokens.warn)
	_tint(_snap_button, tokens.accent)
	_tint(_fit_button, tokens.accent)
	_tint(_return_button, VIOLET)


func _tint(b: Button, colour: Color) -> void:
	for item in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		b.add_theme_color_override(item, colour)


func _style_frame() -> void:
	## The tool frame is outlined in the selected category's colour, so the caret above it and the
	## frame say which tab the tools belong to.
	var cat = registry.category(selected_category_id) if registry != null else null
	var colour: Color = cat.accent if cat != null else tokens.accent
	_tool_frame.add_theme_stylebox_override("panel", tokens.box(tokens.bg_raised.darkened(0.15), colour.darkened(0.15), tokens.radius_control, 10, 2))
	_connector.colour = colour
	_update_connector()


func _update_connector() -> void:
	if _connector == null:
		return
	_connector.tab = _cat_buttons.get(selected_category_id)
	_connector.queue_redraw()


# --- Building from the registry ---------------------------------------------------

func rebuild() -> void:
	for child in _cat_row.get_children():
		_cat_row.remove_child(child)
		child.queue_free()
	_cat_buttons.clear()
	_cat_group = ButtonGroup.new()
	var cats = registry.categories()
	for cat in cats:
		var b := Button.new()
		b.text = cat.label
		b.icon = UiIcons.texture(cat.icon, 30)
		b.toggle_mode = true
		b.button_group = _cat_group
		b.custom_minimum_size = Vector2(0, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.clip_text = true
		b.add_theme_font_size_override("font_size", tokens.font_small + 2)
		_style_selected(b, cat.accent, true)
		b.pressed.connect(select_category.bind(cat.id))
		_cat_row.add_child(b)
		_cat_buttons[cat.id] = b
	var keep: String = selected_category_id if registry.category(selected_category_id) != null else (cats[0].id if not cats.is_empty() else "")
	selected_category_id = ""
	if keep != "":
		select_category(keep)


func select_category(category_id: String) -> void:
	var cat = registry.category(category_id)
	if cat == null:
		return
	if selected_category_id != category_id:
		feedback.emit("press")
	selected_category_id = category_id
	if _cat_buttons.has(category_id):
		(_cat_buttons[category_id] as Button).set_pressed_no_signal(true)
	_rebuild_tools()
	activity.emit()


func _rebuild_tools() -> void:
	for child in _tool_columns.get_children():
		_tool_columns.remove_child(child)
		child.queue_free()
	_tool_buttons.clear()
	var cat = registry.category(selected_category_id)
	if cat == null:
		return
	var column: VBoxContainer = null
	for i in cat.tools.size():
		if i % 2 == 0: # two rows: tools go down a column, then on to the next
			column = VBoxContainer.new()
			column.add_theme_constant_override("separation", tokens.gap)
			_tool_columns.add_child(column)
		var t = cat.tools[i]
		var b := Button.new()
		b.text = t.label
		b.icon = UiIcons.texture(t.icon, 26)
		b.toggle_mode = true
		b.clip_text = true
		b.theme_type_variation = &"ButtonRail"
		b.custom_minimum_size = TOOL_BUTTON
		b.add_theme_font_size_override("font_size", tokens.font_small)
		_style_selected(b, cat.accent, false)
		_tint(b, cat.accent)
		b.pressed.connect(_on_tool_pressed.bind(t.id))
		column.add_child(b)
		_tool_buttons[t.id] = b
	_tool_scroll.scroll_horizontal = 0
	_style_frame()
	_refresh_tool_visuals()


func _on_tool_pressed(tool_id: String) -> void:
	feedback.emit("press")
	manager.toggle(tool_id)
	_refresh_tool_visuals()


func _style_selected(b: Button, accent: Color, both_icon_states: bool) -> void:
	## The selected look in the category's accent colour (a per-button override on top of the
	## theme, so it has to be re-applied when the theme changes). Same as tablet_ui.gd.
	var on_style: StyleBoxFlat = tokens.selected_box(accent)
	b.add_theme_stylebox_override("pressed", on_style)
	b.add_theme_stylebox_override("hover_pressed", on_style)
	b.add_theme_color_override("icon_pressed_color", accent)
	if both_icon_states:
		b.add_theme_color_override("icon_hover_pressed_color", accent)


func _refresh_tool_visuals() -> void:
	for id in _tool_buttons:
		(_tool_buttons[id] as Button).set_pressed_no_signal(manager.is_active(id))


func apply_theme() -> void:
	## Re-themes in place after ui_themes.gd changed the shared theme or the effects switch.
	## Nothing is rebuilt, so the selected tool and category stay exactly as they were.
	_seen_revision = UiThemes.revision
	theme = tokens.build_theme()
	for cat in registry.categories():
		if _cat_buttons.has(cat.id):
			_style_selected(_cat_buttons[cat.id], cat.accent, true)
	var current = registry.category(selected_category_id)
	if current != null:
		for id in _tool_buttons:
			_style_selected(_tool_buttons[id], current.accent, false)
			_tint(_tool_buttons[id], current.accent)
	_active_chip.add_theme_color_override("font_color", tokens.accent)
	_tint_glyphs()
	_style_frame()
	_fx.refresh(tokens)
	activity.emit()


func _process(_delta: float) -> void:
	if _seen_revision != UiThemes.revision:
		apply_theme()
	var overflow := _tool_columns.size.x > _tool_scroll.size.x + 1.0 ## the arrows only exist when the list does not fit
	if _scroll_left.visible != overflow:
		_scroll_left.visible = overflow
		_scroll_right.visible = overflow
		activity.emit()


# --- What the host sets -------------------------------------------------------------

func set_status(text: String) -> void:
	if _status != text:
		_status = text
		activity.emit()


func set_redo_enabled(on: bool) -> void:
	if _redo_button.disabled == on:
		_redo_button.disabled = not on
		activity.emit()


func redo_button() -> Button:
	return _redo_button


func set_undo_enabled(on: bool) -> void:
	if _undo_button.disabled == on:
		_undo_button.disabled = not on
		activity.emit()


func set_part_present(on: bool) -> void:
	## Reset and To arena only mean something while a part is on the table.
	if _reset_button.disabled == on:
		_reset_button.disabled = not on
		_return_button.disabled = not on
		activity.emit()
	_reset_button.visible = on ## not greyed: with no part on the table there is nothing to reset or send back
	_return_button.visible = on


func set_sketching(on: bool) -> void:
	## Orbit lock On / Off and Fit only mean something while a sketch is open.
	if _lock_button.disabled == on:
		_lock_button.disabled = not on
		_fit_button.disabled = not on
		_done_button.disabled = not on
		activity.emit()
	_lock_button.visible = on ## the sketch's own buttons only exist while a sketch is open
	_fit_button.visible = on
	_done_button.visible = on


func set_part_locked(on: bool) -> void:
	_lock_button.set_pressed_no_signal(on)
	_lock_button.text = "Orbit lock: On" if on else "Orbit lock: Off"


func lock_button() -> Button:
	return _lock_button


func done_button() -> Button:
	return _done_button


func fit_button() -> Button:
	return _fit_button



func set_engaged(on: bool) -> void:
	## The chip that says the table has the stick and A / B (the part is gripped or the laser is on it).
	if _active_chip.visible != on:
		_active_chip.visible = on
		activity.emit()


func set_snap(on: bool) -> void:
	_snap_button.set_pressed_no_signal(on)


func snap_on() -> bool:
	return _snap_button.button_pressed


func set_options(options: Array) -> void:
	## The active tool's own controls, left to right: [{id, text, icon?, toggle?, pressed?,
	## disabled?}]. An empty array hides the row. Pressing one emits option_pressed(id).
	if options == _options:
		return
	_options = options.duplicate(true)
	if options_sink != null and is_instance_valid(options_sink):
		_options_row.visible = false
		options_sink.set_options(_options)
		activity.emit()
		return
	for child in _options_row.get_children():
		_options_row.remove_child(child)
		child.queue_free()
	for o in _options:
		var b := Button.new()
		b.text = str(o.get("text", ""))
		if o.has("icon"):
			b.icon = UiIcons.texture(str(o["icon"]), 28)
		b.toggle_mode = bool(o.get("toggle", false))
		b.set_pressed_no_signal(bool(o.get("pressed", false)))
		b.disabled = bool(o.get("disabled", false))
		b.clip_text = true
		b.custom_minimum_size = Vector2(0, 56)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", tokens.font_small)
		var accent_colour: Color = tokens.accent
		var cat = registry.category(selected_category_id)
		if cat != null:
			accent_colour = cat.accent
		_style_selected(b, accent_colour, false)
		var id := str(o.get("id", ""))
		b.pressed.connect(func() -> void:
			feedback.emit("press")
			option_pressed.emit(id))
		_options_row.add_child(b)
	_options_row.visible = not _options.is_empty()
	activity.emit()


# --- For tests and the host ---------------------------------------------------------

func tool_button(tool_id: String) -> Button:
	return _tool_buttons.get(tool_id)


func category_button(category_id: String) -> Button:
	return _cat_buttons.get(category_id)


func shown_tool_ids() -> Array:
	return _tool_buttons.keys()


func option_button(option_id: String) -> Button:
	if options_sink != null and is_instance_valid(options_sink):
		return options_sink.option_button(option_id)
	for i in _options.size():
		if str(_options[i].get("id", "")) == option_id:
			return _options_row.get_child(i) as Button
	return null


func reset_button() -> Button:
	return _reset_button


func return_button() -> Button:
	return _return_button


func chip_visible() -> bool:
	return _active_chip.visible


func status_text() -> String:
	return _status
