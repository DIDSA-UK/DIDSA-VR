extends Control
## The redesigned tablet's 2D shell, from John's sketch: a category grid (top left,
## 4 columns x up to 2 rows), a utility cluster (undo, redo, settings, close) after
## a divider (top right), a tool rail down the left, the active tool's controls
## in the middle with a tool header (name, on/off switch for mode tools, "?" help),
## and a one-line status bar along the bottom.
##
## Pure 2D Controls: no XR, no scene-tree dependency beyond itself, so it runs in a
## plain window (the UI Lab) and on a SubViewport quad (wrist_tablet_v2.gd) alike.
## It never names a specific tool: everything comes from the registry
## (tablet_registry.gd), and the one-active-tool rule from the tool manager
## (tool_manager.gd).
##
## Selecting:
##  * a category shows its last-viewed (else first) tool WITHOUT switching any
##    mode tool on — browsing must never change what the laser does;
##  * a rail button on a "page" tool just shows it;
##  * a rail button on a "mode" tool shows it AND turns it on (turning any other
##    mode tool off); pressing the selected, active one again turns it off.
##
## The host polls list_source() for the side panel and calls tick(delta) each frame.

signal close_requested
signal selection_changed ## category/tool/settings/history changed: re-read list_source()
signal feedback(event: String) ## "error" / "confirm": the host turns it into a haptic pulse and/or a sound
signal activity ## anything on screen changed that the host's render gate should know about (a toast, a page switch)

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const LONG_PRESS_MS := 600
const TOAST_SECONDS := 3.0

var tokens: Resource
var registry
var manager
var command_stack = null ## duck-typed: can_undo/can_redo/undo/redo/history_labels/redo_labels
var settings_builder: Callable = Callable()

var selected_category_id := ""
var selected_tool_id := ""
var settings_open := false
var history_open := false
var help_open := false

var pages_scroll: ScrollContainer ## the host hands this to its LaserSurface as scroll_target
var sliders: Array = [] ## every HSlider in every page, for LaserSurface.add_slider()

var _panel: PanelContainer
var _cat_grid: GridContainer
var _cat_group := ButtonGroup.new()
var _cat_buttons := {}
var _rail_scroll: ScrollContainer
var _rail_box: VBoxContainer
var _rail_group := ButtonGroup.new()
var _rail_buttons := {}
var _holder: VBoxContainer
var _pages := {}
var _settings_page: Control
var _title: Label
var _chip: Label
var _help_button: Button
var _switch_button: Button
var _help_card: PanelContainer
var _help_label: Label
var _status_label: Label
var _status_panel: PanelContainer
var _undo_button: Button
var _redo_button: Button
var _settings_button: Button
var _last_tool := {}
var _toast_text := ""
var _toast_kind := "info"
var _toast_until_ms := 0
var _undo_down_ms := -1
var _long_press_fired := false


func setup(p_tokens: Resource, p_registry, p_manager, options: Dictionary = {}) -> void:
	tokens = p_tokens
	registry = p_registry
	manager = p_manager
	command_stack = options.get("command_stack")
	settings_builder = options.get("settings_builder", Callable())
	theme = tokens.build_theme()
	_build_shell()
	rebuild()
	manager.active_changed.connect(func(_id: String) -> void: _refresh_rail_visuals())
	registry.changed.connect(rebuild, CONNECT_DEFERRED)


# --- Shell ---------------------------------------------------------------

func _build_shell() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap + 4)
	_panel.add_child(column)

	# Top bar: category grid | divider | utility cluster
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", tokens.gap)
	column.add_child(top)
	_cat_grid = GridContainer.new()
	_cat_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cat_grid.add_theme_constant_override("h_separation", tokens.gap)
	_cat_grid.add_theme_constant_override("v_separation", tokens.gap)
	top.add_child(_cat_grid)
	var divider := ColorRect.new()
	divider.custom_minimum_size = Vector2(2, 0)
	divider.color = tokens.border
	top.add_child(divider)
	var utility := HBoxContainer.new()
	utility.add_theme_constant_override("separation", tokens.gap)
	top.add_child(utility)
	_undo_button = _utility_button("undo", false)
	_undo_button.disabled = true
	_undo_button.pressed.connect(_on_undo_pressed)
	_undo_button.button_down.connect(func() -> void: _undo_down_ms = Time.get_ticks_msec(); _long_press_fired = false)
	_undo_button.button_up.connect(func() -> void: _undo_down_ms = -1)
	utility.add_child(_undo_button)
	_redo_button = _utility_button("redo", false)
	_redo_button.disabled = true
	_redo_button.pressed.connect(func() -> void:
		if command_stack:
			command_stack.redo()
	)
	utility.add_child(_redo_button)
	_settings_button = _utility_button("settings", true)
	_settings_button.pressed.connect(func() -> void: set_settings_open(not settings_open))
	utility.add_child(_settings_button)
	var close := _utility_button("close", false)
	close.theme_type_variation = &"ButtonDanger"
	close.pressed.connect(func() -> void: close_requested.emit())
	utility.add_child(close)

	# Body: rail | pane
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", tokens.gap + 4)
	column.add_child(body)
	_rail_scroll = ScrollContainer.new()
	_rail_scroll.custom_minimum_size = Vector2(226, 0)
	_rail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(_rail_scroll)
	_rail_box = VBoxContainer.new()
	_rail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rail_box.add_theme_constant_override("separation", tokens.gap)
	_rail_scroll.add_child(_rail_box)

	var pane := VBoxContainer.new()
	pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pane.add_theme_constant_override("separation", tokens.gap)
	body.add_child(pane)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", tokens.gap)
	pane.add_child(header)
	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	header.add_child(_title) # no clip_text: a clipping Label's minimum width is 0 and a header HBox then squeezes the title away
	_chip = Label.new()
	_chip.theme_type_variation = &"LabelSmall"
	_chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chip.clip_text = true
	header.add_child(_chip)
	_switch_button = Button.new()
	_switch_button.toggle_mode = true
	_switch_button.custom_minimum_size = Vector2(0, 52)
	_switch_button.pressed.connect(func() -> void: manager.toggle(selected_tool_id))
	header.add_child(_switch_button)
	_help_button = Button.new()
	_help_button.icon = UiIcons.texture("help", 28)
	_help_button.toggle_mode = true
	_help_button.custom_minimum_size = Vector2(52, 52)
	_help_button.pressed.connect(func() -> void: set_help_open(not help_open))
	header.add_child(_help_button)
	_help_card = PanelContainer.new()
	_help_card.theme_type_variation = &"PanelRaised"
	_help_card.visible = false
	_help_label = Label.new()
	_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_label.theme_type_variation = &"LabelDim"
	_help_card.add_child(_help_label)
	pane.add_child(_help_card)

	pages_scroll = ScrollContainer.new()
	pages_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pane.add_child(pages_scroll)
	_holder = VBoxContainer.new()
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages_scroll.add_child(_holder)

	# Status bar
	var status := PanelContainer.new()
	status.theme_type_variation = &"PanelRaised"
	_status_panel = status
	_status_label = Label.new()
	_status_label.theme_type_variation = &"LabelDim"
	_status_label.clip_text = true
	status.add_child(_status_label)
	column.add_child(status)


func _utility_button(icon_name: String, toggle: bool) -> Button:
	var b := Button.new()
	b.icon = UiIcons.texture(icon_name, 32)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.toggle_mode = toggle
	b.custom_minimum_size = Vector2(64, 64)
	return b


# --- Building from the registry ---------------------------------------------

func rebuild() -> void:
	for child in _cat_grid.get_children():
		_cat_grid.remove_child(child); child.queue_free()
	for child in _holder.get_children():
		_holder.remove_child(child); child.queue_free()
	_cat_buttons.clear()
	_pages.clear()
	_settings_page = null
	_cat_group = ButtonGroup.new()

	var cats = registry.categories()
	_cat_grid.columns = clampi(cats.size(), 1, registry.GRID_COLUMNS)
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
		var on_style: StyleBoxFlat = tokens.selected_box(cat.accent)
		b.add_theme_stylebox_override("pressed", on_style)
		b.add_theme_stylebox_override("hover_pressed", on_style)
		b.add_theme_color_override("icon_pressed_color", cat.accent)
		b.add_theme_color_override("icon_hover_pressed_color", cat.accent)
		b.pressed.connect(select_category.bind(cat.id))
		_cat_grid.add_child(b)
		_cat_buttons[cat.id] = b
		for t in cat.tools:
			var page: Control = t.build.call() if t.build.is_valid() else Control.new()
			page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			page.size_flags_vertical = Control.SIZE_SHRINK_BEGIN # a BoxContainer would otherwise balloon the one visible page to the whole pane (the old tablet's "buttons below the clip" bug)
			page.visible = false
			_holder.add_child(page)
			_pages[t.id] = page
	if settings_builder.is_valid():
		_settings_page = settings_builder.call()
		_settings_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_settings_page.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		_settings_page.visible = false
		_holder.add_child(_settings_page)
	sliders = _holder.find_children("*", "HSlider", true, false)

	var keep: String = selected_category_id if registry.category(selected_category_id) != null else (cats[0].id if not cats.is_empty() else "")
	selected_category_id = ""
	selected_tool_id = ""
	if keep != "":
		select_category(keep)


func _rebuild_rail() -> void:
	for child in _rail_box.get_children():
		_rail_box.remove_child(child); child.queue_free()
	_rail_buttons.clear()
	_rail_group = ButtonGroup.new()
	var cat = registry.category(selected_category_id)
	if cat == null:
		return
	for t in cat.tools:
		var b := Button.new()
		b.text = t.label
		b.icon = UiIcons.texture(t.icon, 28)
		b.toggle_mode = true
		b.button_group = _rail_group
		b.clip_text = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 64)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.theme_type_variation = &"ButtonRail"
		b.add_theme_font_size_override("font_size", tokens.font_small + 2)
		var on_style: StyleBoxFlat = tokens.selected_box(cat.accent)
		b.add_theme_stylebox_override("pressed", on_style)
		b.add_theme_stylebox_override("hover_pressed", on_style)
		b.add_theme_color_override("icon_pressed_color", cat.accent)
		b.pressed.connect(_on_rail_pressed.bind(t.id))
		_rail_box.add_child(b)
		_rail_buttons[t.id] = b
	_refresh_rail_visuals()


func _refresh_rail_visuals() -> void:
	for id in _rail_buttons:
		var b: Button = _rail_buttons[id]
		var def = registry.tool_def(id)
		var live: bool = def != null and def.is_mode() and manager.is_active(id)
		b.theme_type_variation = &"ButtonRailLive" if (live and id != selected_tool_id) else &"ButtonRail"
		b.set_pressed_no_signal(id == selected_tool_id and not settings_open)
	_refresh_header()


# --- Selection --------------------------------------------------------------

func select_category(category_id: String) -> void:
	var cat = registry.category(category_id)
	if cat == null:
		return
	settings_open = false
	history_open = false
	selected_category_id = category_id
	for id in _cat_buttons:
		(_cat_buttons[id] as Button).set_pressed_no_signal(id == category_id)
	_rebuild_rail()
	var pick: String = _last_tool.get(category_id, "")
	if registry.tool_def(pick) == null and not cat.tools.is_empty():
		pick = cat.tools[0].id
	_show_tool(pick)


func select_tool(tool_id: String, activate_mode: bool = false) -> void:
	## Show a tool; with activate_mode a mode tool is also switched on.
	var def = registry.tool_def(tool_id)
	if def == null:
		return
	if def.category_id != selected_category_id:
		selected_category_id = def.category_id
		for id in _cat_buttons:
			(_cat_buttons[id] as Button).set_pressed_no_signal(id == selected_category_id)
		_rebuild_rail()
	settings_open = false
	history_open = false
	_show_tool(tool_id)
	if activate_mode and def.is_mode():
		manager.activate(tool_id)


func _on_rail_pressed(tool_id: String) -> void:
	var def = registry.tool_def(tool_id)
	if def == null:
		return
	if def.is_mode() and tool_id == selected_tool_id and not settings_open:
		manager.toggle(tool_id)
		_refresh_rail_visuals()
		return
	select_tool(tool_id, true)


func _show_tool(tool_id: String) -> void:
	selected_tool_id = tool_id
	if tool_id != "":
		_last_tool[selected_category_id] = tool_id
	help_open = false
	for id in _pages:
		(_pages[id] as Control).visible = (id == tool_id)
	if _settings_page:
		_settings_page.visible = false
	pages_scroll.scroll_vertical = 0
	_fade_in(_pages.get(tool_id))
	var def = registry.tool_def(tool_id)
	if def != null and def.on_select.is_valid():
		def.on_select.call()
	_refresh_rail_visuals()
	selection_changed.emit()


func set_settings_open(on: bool) -> void:
	if on and _settings_page == null:
		return
	settings_open = on
	history_open = false
	help_open = false
	for id in _pages:
		(_pages[id] as Control).visible = (not on and id == selected_tool_id)
	if _settings_page:
		_settings_page.visible = on
	_settings_button.set_pressed_no_signal(on)
	pages_scroll.scroll_vertical = 0
	_fade_in(_settings_page if on else _pages.get(selected_tool_id))
	_rail_scroll.visible = not on
	_refresh_rail_visuals()
	selection_changed.emit()


func set_help_open(on: bool) -> void:
	help_open = on
	_refresh_header()


func _refresh_header() -> void:
	_rail_scroll.visible = not settings_open
	_settings_button.set_pressed_no_signal(settings_open)
	var def = registry.tool_def(selected_tool_id)
	var cat = registry.category(selected_category_id)
	if settings_open:
		_title.text = "Settings"
		_chip.text = ""
		_switch_button.visible = false
		_help_button.visible = false
		_help_card.visible = false
		return
	_title.text = def.label if def else ""
	_chip.text = ("  " + cat.label.to_upper()) if cat else ""
	_help_button.visible = def != null
	_help_button.set_pressed_no_signal(help_open)
	_help_card.visible = help_open and def != null
	if def != null:
		_help_label.text = def.help if def.help != "" else "No help for this tool yet."
	_switch_button.visible = def != null and def.is_mode()
	if _switch_button.visible:
		var on: bool = manager.is_active(selected_tool_id)
		_switch_button.set_pressed_no_signal(on)
		_switch_button.text = "Tool: ON" if on else "Tool: off"


# --- Side panel source ------------------------------------------------------

func list_source() -> Dictionary:
	## What the side panel should show right now: {title, provider, empty} or {} for none.
	if history_open:
		return {"title": "History", "provider": _history_rows, "empty": "Nothing to undo yet."}
	if settings_open:
		return {}
	var def = registry.tool_def(selected_tool_id)
	if def != null and def.has_list():
		return {"title": def.label, "provider": def.list_provider, "empty": def.list_empty}
	return {}


func _history_rows() -> Array:
	var rows := []
	if command_stack == null:
		return rows
	var i := 0
	for label in command_stack.history_labels():
		rows.append({"id": "u%d" % i, "title": str(label), "subtitle": "", "state": "normal"})
		i += 1
	for label in command_stack.redo_labels():
		rows.append({"id": "r%d" % i, "title": str(label), "subtitle": "undone — Redo brings it back", "state": "warn"})
		i += 1
	return rows


# --- Status, toast, per-frame --------------------------------------------------

func toast(text: String, kind: String = "info", seconds: float = TOAST_SECONDS) -> void:
	_toast_text = text
	_toast_kind = kind
	_toast_until_ms = Time.get_ticks_msec() + int(seconds * 1000.0)
	# A brief pulse on the status bar (brightening, tinted red for an error: a cue that isn't
	# colour alone, the text itself says what went wrong), then a haptic via the host.
	var d: float = tokens.duration(0.3)
	if d > 0.0 and _status_panel:
		_status_panel.self_modulate = Color(1.9, 0.85, 0.85) if kind == "error" else (Color(0.9, 1.6, 1.1) if kind == "ok" else Color(1.7, 1.7, 1.7))
		create_tween().tween_property(_status_panel, "self_modulate", Color.WHITE, d).set_ease(Tween.EASE_OUT)
	if kind == "error":
		feedback.emit("error")
	elif kind == "ok":
		feedback.emit("confirm")
	activity.emit()


func _fade_in(page: Control) -> void:
	## The controls pane fades in when its content switches (150 ms; instant with Reduce motion).
	activity.emit()
	var d: float = tokens.duration(tokens.anim_medium * 0.85)
	if page == null or d <= 0.0:
		return
	page.modulate.a = 0.0
	create_tween().tween_property(page, "modulate:a", 1.0, d).set_ease(Tween.EASE_OUT)


func tick(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if command_stack:
		_undo_button.disabled = not command_stack.can_undo()
		_redo_button.disabled = not command_stack.can_redo()
	if _undo_down_ms >= 0 and not _long_press_fired and now - _undo_down_ms >= LONG_PRESS_MS:
		_long_press_fired = true
		history_open = not history_open
		selection_changed.emit()
	var text := ""
	var kind := "info"
	if now < _toast_until_ms:
		text = _toast_text
		kind = _toast_kind
	elif settings_open:
		text = "Settings"
	elif history_open:
		text = "History — pick a category or tool to close it"
	else:
		var def = registry.tool_def(selected_tool_id)
		if def != null:
			text = str(def.status_provider.call()) if def.status_provider.is_valid() else def.hint
	_status_label.text = "●  %s" % text if text != "" else ""
	if kind == "error":
		_status_label.add_theme_color_override("font_color", tokens.danger)
	elif kind == "ok":
		_status_label.add_theme_color_override("font_color", tokens.ok)
	else:
		_status_label.remove_theme_color_override("font_color")


func status_text() -> String:
	return _status_label.text


func _on_undo_pressed() -> void:
	if _long_press_fired:
		_long_press_fired = false # this release ended a long press that opened History: it must not also undo
		return
	if command_stack:
		command_stack.undo()
