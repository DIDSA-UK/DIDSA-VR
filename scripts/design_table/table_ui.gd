extends Control
## The design table's tool deck, from John's concept sketch: a row of category buttons
## and, under it, a row of up to six tool buttons that changes with the category. A
## contextual row under those holds the active tool's own settings (polygon sides, Boss
## or Cut, depth...), then a status line with Snap, Undo and Close at its right.
##
## Pure 2D Controls, like tablet_ui.gd: no XR, no scene-tree dependency beyond itself,
## so it runs on a SubViewport quad (design_table.gd) and in a plain window (the UI
## Lab) alike. It never names a specific tool: everything comes from the registry
## (scripts/ui/tablet_registry.gd, filled by table_tools.gd), the one-active-tool rule
## from the tool manager (scripts/ui/tool_manager.gd) and the "More" paging from
## tool_pager.gd. Styling is the shared UI theme (ui/didsa_ui_theme.tres): the same
## ButtonRail buttons, per-category accent and selected look as the wrist tablet.

signal option_pressed(option_id: String)
signal snap_toggled(on: bool)
signal undo_pressed
signal close_requested
signal feedback(event: String) ## "press" / "error": the host turns it into a haptic pulse and a sound
signal activity ## something on screen changed that the host's render gate should know about

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const FxOverlay := preload("res://scripts/ui/fx_overlay.gd")
const Pager := preload("res://scripts/design_table/tool_pager.gd")

var tokens: Resource
var registry
var manager
var selected_category_id := ""

var _panel: PanelContainer
var _cat_row: HBoxContainer
var _tool_row: HBoxContainer
var _options_row: HBoxContainer
var _status_label: Label
var _snap_button: Button
var _undo_button: Button
var _close_button: Button
var _fx: ColorRect
var _cat_group := ButtonGroup.new()
var _cat_buttons := {}
var _tool_buttons := {}
var _more_button: Button
var _pages := {} ## category id -> page shown
var _options: Array = []
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
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap)
	_panel.add_child(column)

	_cat_row = HBoxContainer.new()
	_cat_row.add_theme_constant_override("separation", tokens.gap)
	column.add_child(_cat_row)

	_tool_row = HBoxContainer.new()
	_tool_row.add_theme_constant_override("separation", tokens.gap)
	column.add_child(_tool_row)

	_options_row = HBoxContainer.new()
	_options_row.add_theme_constant_override("separation", tokens.gap)
	_options_row.visible = false
	column.add_child(_options_row)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", tokens.gap)
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(bottom)
	var status_panel := PanelContainer.new()
	status_panel.theme_type_variation = &"PanelRaised"
	status_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label = Label.new()
	_status_label.theme_type_variation = &"LabelDim"
	_status_label.clip_text = true
	status_panel.add_child(_status_label)
	bottom.add_child(status_panel)
	_snap_button = _utility("snap", "Snap", true)
	_snap_button.set_pressed_no_signal(true)
	_snap_button.toggled.connect(func(on: bool) -> void:
		feedback.emit("press")
		snap_toggled.emit(on))
	bottom.add_child(_snap_button)
	_undo_button = _utility("undo", "", false)
	_undo_button.disabled = true
	_undo_button.pressed.connect(func() -> void:
		feedback.emit("press")
		undo_pressed.emit())
	bottom.add_child(_undo_button)
	_close_button = _utility("close", "", false)
	_close_button.theme_type_variation = &"ButtonDanger"
	_close_button.pressed.connect(func() -> void: close_requested.emit())
	bottom.add_child(_close_button)

	_fx = FxOverlay.new() # last child of the root, so the glass sits over everything but the laser cursor the host adds after
	add_child(_fx)
	_fx.setup(tokens)


func _utility(icon_name: String, text: String, toggle: bool) -> Button:
	var b := Button.new()
	b.icon = UiIcons.texture(icon_name, 32)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER if text == "" else HORIZONTAL_ALIGNMENT_LEFT
	b.text = text
	b.toggle_mode = toggle
	b.custom_minimum_size = Vector2(64 if text == "" else 150, 56)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER # one row tall like the other buttons, not stretched to the status line
	return b


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
	for child in _tool_row.get_children():
		_tool_row.remove_child(child)
		child.queue_free()
	_tool_buttons.clear()
	_more_button = null
	var cat = registry.category(selected_category_id)
	if cat == null:
		return
	var page: Dictionary = Pager.slots(cat.tools, int(_pages.get(cat.id, 0)))
	_pages[cat.id] = page["page"]
	for t in page["tools"]:
		var b := Button.new()
		b.text = t.label
		b.icon = UiIcons.texture(t.icon, 28)
		b.toggle_mode = true
		b.clip_text = true
		b.theme_type_variation = &"ButtonRail"
		b.custom_minimum_size = Vector2(0, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", tokens.font_small)
		_style_selected(b, cat.accent, false)
		b.pressed.connect(_on_tool_pressed.bind(t.id))
		_tool_row.add_child(b)
		_tool_buttons[t.id] = b
	if page["has_more"]:
		_more_button = Button.new()
		_more_button.text = "More %d/%d" % [int(page["page"]) + 1, int(page["pages"])]
		_more_button.icon = UiIcons.texture("tool_more", 28)
		_more_button.clip_text = true
		_more_button.custom_minimum_size = Vector2(0, 64)
		_more_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_more_button.add_theme_font_size_override("font_size", tokens.font_small)
		_more_button.pressed.connect(_on_more_pressed)
		_tool_row.add_child(_more_button)
	_refresh_tool_visuals()


func _on_tool_pressed(tool_id: String) -> void:
	feedback.emit("press")
	manager.toggle(tool_id)
	_refresh_tool_visuals()


func _on_more_pressed() -> void:
	var cat = registry.category(selected_category_id)
	if cat == null:
		return
	feedback.emit("press")
	_pages[cat.id] = Pager.next_page(int(_pages.get(cat.id, 0)), cat.tools.size())
	_rebuild_tools()
	activity.emit()


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
	_fx.refresh(tokens)
	activity.emit()


func _process(_delta: float) -> void:
	if _seen_revision != UiThemes.revision:
		apply_theme()


# --- What the host sets -------------------------------------------------------------

func set_status(text: String) -> void:
	if _status_label.text != text:
		_status_label.text = text
		activity.emit()


func set_undo_enabled(on: bool) -> void:
	if _undo_button.disabled == on:
		_undo_button.disabled = not on
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


func more_button() -> Button:
	return _more_button


func shown_tool_ids() -> Array:
	return _tool_buttons.keys()


func option_button(option_id: String) -> Button:
	for i in _options.size():
		if str(_options[i].get("id", "")) == option_id:
			return _options_row.get_child(i) as Button
	return null


func status_text() -> String:
	return _status_label.text
