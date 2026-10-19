extends Control
## The redesigned tablet's 2D shell: a phone-style HOME screen of tiles, and the
## tool screens behind them. Pure 2D Controls: no XR, no scene-tree dependency
## beyond itself, so it runs in a plain window (the UI Lab) and on a SubViewport
## quad (wrist_tablet.gd) alike. It never names a specific tool: everything comes
## from the registry (tablet_registry.gd), and the one-active-tool rule from the
## tool manager (tool_manager.gd).
##
## Screens (selected_category_id / hub_open say which one is showing):
##   Home        every registry category as a tile (6 x 2). A tile either does its thing
##               straight away (an "action" category: the window tiles, Design) or opens...
##   Hub         a screen of tiles, one per tool, for a category registered with hub: true
##               (View, Settings). Tap a tile to open that tool's page; Back returns here.
##   Tool view   a chip strip across the top (only for a plain category with more than one
##               tool, e.g. Inspect), the tool header (name, on/off switch for mode tools,
##               "?" help) and the tool's controls.
## A top bar on every screen but Home carries Back and the category's name; on every
## screen it carries the status chips (what is switched on / unsaved) and the utility
## cluster (undo, redo, settings, close).
##
## Selecting:
##  * opening a category shows its last-viewed (else first) tool WITHOUT switching any
##    mode tool on -- browsing must never change what the laser does;
##  * a strip chip or hub tile on a "page" tool just shows it;
##  * a strip chip or hub tile on a "mode" tool shows it AND turns it on (turning any other
##    mode tool off); pressing the selected, active chip again turns it off;
##  * going Home never touches the active mode tool; a chip says it is still on.
##
## The host polls list_source() for the side panel and calls tick(delta) each frame.

signal close_requested
signal selection_changed ## screen/tool/history changed: re-read list_source()
signal feedback(event: String) ## "error" / "confirm": the host turns it into a haptic pulse and/or a sound
signal activity ## anything on screen changed that the host's render gate should know about (a toast, a page switch)

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const FxOverlay := preload("res://scripts/ui/fx_overlay.gd")
const LONG_PRESS_MS := 600
const TOAST_SECONDS := 3.0
const SETTINGS_CATEGORY := "settings" ## the utility cluster's gear opens this category

var tokens: Resource
var registry
var manager
var command_stack = null ## duck-typed: can_undo/can_redo/undo/redo/history_labels/redo_labels
var chips_provider: Callable = Callable() ## () -> Array of {text, kind: "info"|"ok"|"warn"|"accent", tap: Callable}, shown beside the active mode tool's own chip

var selected_category_id := "" ## "" = the home screen
var selected_tool_id := ""
var hub_open := false ## the selected category's tile screen is showing instead of a tool
var history_open := false
var help_open := false

var pages_scroll: ScrollContainer ## the host hands this to its LaserSurface as scroll_target
var sliders: Array = [] ## every HSlider in every page, and every control in the "laser_draggable" group, for LaserSurface.add_slider()

var _panel: PanelContainer
var _back_button: Button
var _cat_title: Label
var _chips_box: HBoxContainer
var _chip_signature := ""
var _home_view: Control
var _home_grid: GridContainer
var _hub_view: Control
var _hub_grid: GridContainer
var _tool_view: Control
var _tiles: Array = [] ## [{button, icon, name, caption, accent, category_id}] for the home and hub tiles on screen
var _strip_scroll: ScrollContainer
var _strip_box: HBoxContainer
var _strip_group := ButtonGroup.new()
var _strip_buttons := {}
var _holder: VBoxContainer
var _pages := {}
var _title: Label
var _chip: Label
var _help_button: Button
var _switch_button: Button
var _help_card: PanelContainer
var _help_label: Label
var _status_label: Label
var _status_panel: PanelContainer
var _fx: ColorRect ## the glass overlay (fx_overlay.gd)
var _seen_revision := -1 ## ui_themes.gd's revision this UI was last themed at
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
	chips_provider = options.get("chips", Callable())
	theme = tokens.build_theme()
	_seen_revision = UiThemes.revision
	_build_shell()
	rebuild()
	manager.active_changed.connect(func(_id: String) -> void:
		_refresh_strip_visuals()
		_refresh_chips()
	)
	registry.changed.connect(rebuild, CONNECT_DEFERRED)


# --- Shell ---------------------------------------------------------------

func _build_shell() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap + 4)
	_panel.add_child(column)

	# Top bar: Back + category name (not on Home) | status chips | utility cluster
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", tokens.gap)
	column.add_child(top)
	_back_button = Button.new()
	_back_button.text = "Back"
	_back_button.icon = UiIcons.texture("back", 28)
	_back_button.custom_minimum_size = Vector2(0, 64)
	_back_button.pressed.connect(go_back)
	top.add_child(_back_button)
	_cat_title = Label.new()
	_cat_title.theme_type_variation = &"LabelTitle"
	_cat_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(_cat_title)
	_chips_box = HBoxContainer.new()
	_chips_box.add_theme_constant_override("separation", tokens.gap)
	_chips_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_chips_box)
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
	_settings_button.pressed.connect(func() -> void:
		if selected_category_id == SETTINGS_CATEGORY:
			go_home()
		else:
			select_category(SETTINGS_CATEGORY)
	)
	utility.add_child(_settings_button)
	var close := _utility_button("close", false)
	close.theme_type_variation = &"ButtonDanger"
	close.pressed.connect(func() -> void: close_requested.emit())
	utility.add_child(close)

	# Body: one of three screens
	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	_home_view = _full_rect_box(body)
	_home_grid = _tile_grid()
	_home_view.add_child(_home_grid)
	_hub_view = _full_rect_box(body)
	_hub_grid = _tile_grid()
	_hub_view.add_child(_hub_grid)
	_tool_view = _full_rect_box(body)
	_build_tool_view(_tool_view)

	# Status bar
	var status := PanelContainer.new()
	status.theme_type_variation = &"PanelRaised"
	_status_panel = status
	_status_label = Label.new()
	_status_label.theme_type_variation = &"LabelDim"
	_status_label.clip_text = true
	status.add_child(_status_label)
	column.add_child(status)

	_fx = FxOverlay.new() # last child of the root, so the glass sits over everything but the laser cursor the host adds after
	add_child(_fx)
	_fx.setup(tokens)


func _full_rect_box(parent: Control) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", tokens.gap)
	parent.add_child(box)
	return box


func _tile_grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", tokens.gap + 4)
	grid.add_theme_constant_override("v_separation", tokens.gap + 4)
	return grid


func _build_tool_view(view: VBoxContainer) -> void:
	_strip_scroll = ScrollContainer.new()
	_strip_scroll.custom_minimum_size = Vector2(0, 76)
	_strip_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	view.add_child(_strip_scroll)
	_strip_box = HBoxContainer.new()
	_strip_box.add_theme_constant_override("separation", tokens.gap)
	_strip_scroll.add_child(_strip_box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", tokens.gap)
	view.add_child(header)
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
	view.add_child(_help_card)

	pages_scroll = ScrollContainer.new()
	pages_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	view.add_child(pages_scroll)
	_holder = VBoxContainer.new()
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages_scroll.add_child(_holder)


func _utility_button(icon_name: String, toggle: bool) -> Button:
	var b := Button.new()
	b.icon = UiIcons.texture(icon_name, 32)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.toggle_mode = toggle
	b.custom_minimum_size = Vector2(64, 64)
	return b


# --- Tiles -----------------------------------------------------------------

func _make_tile(label: String, caption: String, icon_name: String, accent: Color, on_press: Callable, category_id: String = "", tool_id: String = "") -> Button:
	## A big launcher tile: an icon over a name over one small line. The Button draws the
	## frame and the press; its children are only a layout (they ignore the mouse).
	var b := Button.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 120)
	b.clip_contents = true
	b.pressed.connect(on_press)
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	box.offset_left = 10 # (room either side, so a long caption wraps to a second line instead of touching the frame)
	box.offset_right = -10
	b.add_child(box)
	var icon := TextureRect.new()
	icon.texture = UiIcons.texture(icon_name, 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.modulate = accent
	box.add_child(icon)
	var name_label := Label.new()
	name_label.text = label
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)
	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.theme_type_variation = &"LabelSmall"
	caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	caption_label.custom_minimum_size = Vector2(0, ceilf(tokens.font_tiny * 3.4)) # two lines tall for every tile, so the icons and names line up whether it wraps or not
	caption_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption_label.visible = caption != "" # (a tile with nothing to say centres its icon and name)
	box.add_child(caption_label)
	_style_tile(b, accent)
	_tiles.append({"button": b, "icon": icon, "caption": caption_label, "accent": accent, "category_id": category_id, "tool_id": tool_id})
	return b


func _style_tile(b: Button, accent: Color) -> void:
	## A tile's frame in its category's accent colour (per-button overrides on top of the theme, so
	## they are re-applied when the theme changes).
	b.add_theme_stylebox_override("normal", tokens.box(tokens.bg_raised, accent.darkened(0.3), tokens.radius_panel, 8))
	b.add_theme_stylebox_override("hover", tokens.glow(tokens.box(tokens.surface_hover, accent, tokens.radius_panel, 8), accent, 0.6))
	var on: StyleBoxFlat = tokens.selected_box(accent)
	on.set_corner_radius_all(tokens.radius_panel)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)


func _on_home_tile(cat_id: String) -> void:
	var cat = registry.category(cat_id)
	if cat == null:
		return
	if cat.is_action():
		cat.action.call()
		_refresh_tile_captions()
		activity.emit()
		return
	select_category(cat_id)


func _refresh_tile_captions() -> void:
	var changed := false
	for entry in _tiles:
		var cat_id: String = entry["category_id"]
		if cat_id == "":
			continue
		var cat = registry.category(cat_id)
		if cat == null or not cat.caption.is_valid():
			continue
		var label: Label = entry["caption"]
		var text := str(cat.caption.call())
		if label.text != text:
			label.text = text
			label.visible = text != ""
			changed = true
	if changed:
		activity.emit()


# --- Building from the registry ---------------------------------------------

func rebuild() -> void:
	for child in _home_grid.get_children():
		_home_grid.remove_child(child); child.queue_free()
	for child in _hub_grid.get_children():
		_hub_grid.remove_child(child); child.queue_free()
	for child in _holder.get_children():
		_holder.remove_child(child); child.queue_free()
	_tiles.clear()
	_pages.clear()

	var cats = registry.categories()
	_home_grid.columns = clampi(cats.size(), 1, registry.GRID_COLUMNS)
	for cat in cats:
		_home_grid.add_child(_make_tile(cat.label, cat.subtitle, cat.icon, cat.accent, _on_home_tile.bind(cat.id), cat.id))
		for t in cat.tools:
			var page: Control = t.build.call() if t.build.is_valid() else Control.new()
			page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			page.size_flags_vertical = Control.SIZE_SHRINK_BEGIN # a BoxContainer would otherwise balloon the one visible page to the whole pane (the old tablet's "buttons below the clip" bug)
			page.visible = false
			_holder.add_child(page)
			_pages[t.id] = page
	sliders = _holder.find_children("*", "HSlider", true, false)
	for node in _holder.find_children("*", "Control", true, false):
		if node.is_in_group("laser_draggable") and not sliders.has(node):
			sliders.append(node) # a control that is dragged like a slider (the Appearance page's colour picker)
	_refresh_tile_captions()

	# Come back to where we were if that screen still exists, otherwise Home.
	var cat = registry.category(selected_category_id)
	if cat == null or registry.tool_def(selected_tool_id) == null and not hub_open:
		selected_category_id = ""
		selected_tool_id = ""
		hub_open = false
	elif hub_open:
		_rebuild_hub(cat)
	_rebuild_strip()
	_apply_view()


func _rebuild_hub(cat) -> void:
	for child in _hub_grid.get_children():
		_hub_grid.remove_child(child); child.queue_free()
	_tiles = _tiles.filter(func(e) -> bool: return e["category_id"] != "") # the previous hub's tiles go; home tiles carry a category id
	_hub_grid.columns = clampi(ceili(cat.tools.size() / 2.0), 3, 5)
	for t in cat.tools:
		_hub_grid.add_child(_make_tile(t.label, t.caption, t.icon, cat.accent, _on_hub_tile.bind(t.id), "", t.id))


func _on_hub_tile(tool_id: String) -> void:
	select_tool(tool_id, true)


func _rebuild_strip() -> void:
	for child in _strip_box.get_children():
		_strip_box.remove_child(child); child.queue_free()
	_strip_buttons.clear()
	_strip_group = ButtonGroup.new()
	var cat = registry.category(selected_category_id)
	if cat == null:
		return
	for t in cat.tools:
		var b := Button.new()
		b.text = t.label
		b.icon = UiIcons.texture(t.icon, 28)
		b.toggle_mode = true
		b.button_group = _strip_group
		b.custom_minimum_size = Vector2(0, 64)
		b.theme_type_variation = &"ButtonRail"
		b.add_theme_font_size_override("font_size", tokens.font_small + 2)
		_style_selected(b, cat.accent, false)
		b.pressed.connect(_on_strip_pressed.bind(t.id))
		_strip_box.add_child(b)
		_strip_buttons[t.id] = b
	_refresh_strip_visuals()


func _style_selected(b: Button, accent: Color, both_icon_states: bool) -> void:
	## A strip chip's "selected" look in its category's accent colour (a per-button
	## override on top of the theme, so it has to be re-applied when the theme changes).
	var on_style: StyleBoxFlat = tokens.selected_box(accent)
	b.add_theme_stylebox_override("pressed", on_style)
	b.add_theme_stylebox_override("hover_pressed", on_style)
	b.add_theme_color_override("icon_pressed_color", accent)
	if both_icon_states:
		b.add_theme_color_override("icon_hover_pressed_color", accent)


func apply_theme() -> void:
	## Re-themes in place after ui_themes.gd changed the shared theme or the effects switch: new
	## Theme, the per-button accent overrides, the glass overlay. Nothing is rebuilt, so
	## the selected tool, scroll position and every toggle stay exactly as they were.
	_seen_revision = UiThemes.revision
	theme = tokens.build_theme()
	for entry in _tiles:
		_style_tile(entry["button"], entry["accent"])
	var current = registry.category(selected_category_id)
	if current != null:
		for id in _strip_buttons:
			_style_selected(_strip_buttons[id], current.accent, false)
	_chip_signature = "" # chips are styled from the theme too
	_refresh_chips()
	_fx.refresh(tokens)
	_refresh_strip_visuals()
	activity.emit()


func _process(_delta: float) -> void:
	if _seen_revision != UiThemes.revision:
		apply_theme()


func _refresh_strip_visuals() -> void:
	for id in _strip_buttons:
		var b: Button = _strip_buttons[id]
		var def = registry.tool_def(id)
		var live: bool = def != null and def.is_mode() and manager.is_active(id)
		b.theme_type_variation = &"ButtonRailLive" if (live and id != selected_tool_id) else &"ButtonRail"
		b.set_pressed_no_signal(id == selected_tool_id)
	_refresh_header()


# --- Accessors (tests and the host find a control without knowing the layout) ------------

func home_tile(category_id: String) -> Button:
	for entry in _tiles:
		if entry["category_id"] == category_id:
			return entry["button"]
	return null


func tile_caption(category_id: String) -> String:
	for entry in _tiles:
		if entry["category_id"] == category_id:
			return (entry["caption"] as Label).text
	return ""


func hub_tile(tool_id: String) -> Button:
	for entry in _tiles:
		if entry["tool_id"] == tool_id and is_instance_valid(entry["button"]) and not entry["button"].is_queued_for_deletion():
			return entry["button"]
	return null


func strip_button(tool_id: String) -> Button:
	return _strip_buttons.get(tool_id)


func chip_texts() -> Array:
	var out: Array = []
	for child in _chips_box.get_children():
		if not child.is_queued_for_deletion():
			out.append((child as Button).text)
	return out


# --- Status chips ---------------------------------------------------------------

func _refresh_chips() -> void:
	var items: Array = []
	if manager.active_id != "":
		var def = registry.tool_def(manager.active_id)
		if def != null:
			items.append({"text": "%s on" % def.label, "kind": "accent", "tap": select_tool.bind(def.id, false)})
	if chips_provider.is_valid():
		items.append_array(chips_provider.call())
	var signature := ""
	for item in items:
		signature += "%s|%s;" % [item["text"], item.get("kind", "info")]
	if signature == _chip_signature:
		return
	_chip_signature = signature
	for child in _chips_box.get_children():
		_chips_box.remove_child(child); child.queue_free()
	for item in items:
		var colour := _chip_colour(str(item.get("kind", "info")))
		var b := Button.new()
		b.text = "●  %s" % item["text"]
		b.custom_minimum_size = Vector2(0, 44)
		b.add_theme_font_size_override("font_size", tokens.font_small)
		b.add_theme_stylebox_override("normal", tokens.box(tokens.bg_raised, tokens.border, 22, 14, 1))
		b.add_theme_stylebox_override("hover", tokens.box(tokens.surface_hover, colour, 22, 14, 1))
		b.add_theme_stylebox_override("pressed", tokens.box(tokens.surface_hover, colour, 22, 14, 1))
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(state, colour)
		var tap: Callable = item.get("tap", Callable())
		if tap.is_valid():
			b.pressed.connect(tap)
		_chips_box.add_child(b)
	activity.emit()


func _chip_colour(kind: String) -> Color:
	match kind:
		"ok":
			return tokens.ok
		"warn":
			return tokens.warn
		"accent":
			return tokens.accent
	return tokens.text_dim


# --- Selection --------------------------------------------------------------

func select_category(category_id: String) -> void:
	## Opens a category: its hub screen if it has one, otherwise its last-viewed (else first) tool.
	## An "action" category has no screen; use the home tile (or its action) for those.
	var cat = registry.category(category_id)
	if cat == null or cat.is_action():
		return
	history_open = false
	help_open = false
	selected_category_id = category_id
	_rebuild_strip()
	if cat.hub:
		hub_open = true
		selected_tool_id = ""
		_rebuild_hub(cat)
		_apply_view()
		_fade_in(_hub_view)
		return
	hub_open = false
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
		_rebuild_strip()
	hub_open = false
	history_open = false
	_show_tool(tool_id)
	if activate_mode and def.is_mode():
		manager.activate(tool_id)


func go_home() -> void:
	## Back to the tile screen. Never touches the active mode tool.
	selected_category_id = ""
	selected_tool_id = ""
	hub_open = false
	history_open = false
	help_open = false
	_apply_view()
	_fade_in(_home_view)


func go_back() -> void:
	## One step up: from a hub category's tool to its hub, otherwise to Home.
	var cat = registry.category(selected_category_id)
	if cat != null and cat.hub and not hub_open:
		selected_tool_id = ""
		hub_open = true
		history_open = false
		help_open = false
		_rebuild_hub(cat)
		_apply_view()
		_fade_in(_hub_view)
		return
	go_home()


func _on_strip_pressed(tool_id: String) -> void:
	var def = registry.tool_def(tool_id)
	if def == null:
		return
	if def.is_mode() and tool_id == selected_tool_id:
		manager.toggle(tool_id)
		_refresh_strip_visuals()
		return
	select_tool(tool_id, true)


func _show_tool(tool_id: String) -> void:
	selected_tool_id = tool_id
	if tool_id != "":
		_last_tool[selected_category_id] = tool_id
	help_open = false
	pages_scroll.scroll_vertical = 0
	var def = registry.tool_def(tool_id)
	if def != null and def.on_select.is_valid():
		def.on_select.call() # refresh the tool's data first: _apply_view announces the selection and the side list reads it
	_apply_view()
	_fade_in(_pages.get(tool_id))


func _apply_view() -> void:
	## Shows exactly one of the three screens and sets the top bar to match.
	var cat = registry.category(selected_category_id)
	var home: bool = cat == null
	_home_view.visible = home
	_hub_view.visible = not home and hub_open
	_tool_view.visible = not home and not hub_open
	_back_button.visible = not home
	_cat_title.visible = not home
	if cat != null:
		_cat_title.text = cat.label
		_cat_title.add_theme_color_override("font_color", cat.accent)
	for id in _pages:
		(_pages[id] as Control).visible = _tool_view.visible and id == selected_tool_id
	_strip_scroll.visible = _tool_view.visible and cat != null and not cat.hub and cat.tools.size() > 1
	_settings_button.set_pressed_no_signal(selected_category_id == SETTINGS_CATEGORY)
	_refresh_strip_visuals()
	selection_changed.emit()


func set_help_open(on: bool) -> void:
	help_open = on
	_refresh_header()


func _refresh_header() -> void:
	var def = registry.tool_def(selected_tool_id)
	var cat = registry.category(selected_category_id)
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
	var def = registry.tool_def(selected_tool_id)
	if def != null and def.has_list() and _tool_view.visible:
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
	_refresh_chips()
	_refresh_tile_captions()
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
	elif history_open:
		text = "History — pick a tile or tool to close it"
	else:
		# On Home and hub screens the status line speaks for the tool that is switched on, if any.
		var def = registry.tool_def(selected_tool_id if selected_tool_id != "" else manager.active_id)
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
