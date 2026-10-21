extends "res://scripts/landing/launcher_window.gd"
## The landing's own menu: a launch deck, not the tablet. A wide console tilted back towards you below the logo: one big call to action (Demo models), a column of
## menu lines (Continue, Open, New assembly, Demo assemblies, Servers; the ones that need a server are dimmed with a padlock when there is none), the connection
## status top right, the tips ticker along the bottom and Settings / About in the corner. Everything is drawn by deck_button.gd and chamfer_box.gd: none of the
## tablet's theme shows. The inner pages (the demo lists, Servers, Scan, Settings, About) are still launcher_window.gd's, shown in the same frame until they are
## given the same treatment.

const DeckButton := preload("res://scripts/landing/deck_button.gd")
const ChamferBox := preload("res://scripts/landing/chamfer_box.gd")
const CYAN := Color(0.30, 0.88, 1.0)
const INK := Color(0.94, 0.98, 1.0)
const DIM := Color(0.56, 0.68, 0.82)
const AMBER := Color(1.0, 0.66, 0.30)
const TILT_BACK_DEGREES := 22.0
const ROW_IDS: Array[String] = ["continue", "open", "new", "assemblies", "servers"]
const ROW_ICONS := {"continue": "history", "open": "files", "new": "assembly", "assemblies": "tree", "servers": "browser"}

var _home_root: Control
var _page_view: Control
var _home_pill: Button
var _home_status: Label
var _ticker: Control
var _ticker_kicker: Label
var _ticker_text: Label
var _ticker_pause: Button
var _shown_tip := -1
var _ticker_on := true


func _init() -> void:
	launcher_panel_size = Vector2(1.04, 0.56)
	launcher_viewport_size = Vector2i(1456, 784)
	corner_hit_reach = -1.0 # the deck is not resized by its corners


func _build_corners() -> void:
	pass # and shows no resize brackets


func _place_in_front_of_camera() -> void:
	## Below the logo and tilted back so its face meets your eyes: a console, not a wall.
	super._place_in_front_of_camera()
	rotate_object_local(Vector3.RIGHT, -deg_to_rad(TILT_BACK_DEGREES))


# --- Chrome: no tablet theme, a drawn frame ---------------------------------------------------------------------------

func _build_viewport() -> void:
	super._build_viewport()
	_viewport.transparent_bg = true # the frame is chamfered and translucent: what is behind it shows


func _build_quad() -> void:
	super._build_quad()
	var material := (_quad.mesh as QuadMesh).material as StandardMaterial3D
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


func _build_root_ui() -> Control:
	var root := Control.new()
	root.theme = tokens.build_theme() # only for the plain Labels and the keyboard-less pages: the deck's own parts draw themselves
	root.theme.default_font_size = 26
	root.size = Vector2(viewport_size)
	var frame := ChamferBox.new()
	frame.cut = 38.0
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(frame)
	_header = HBoxContainer.new() # the base class keeps these: nothing here is shown
	_title_label = Label.new()
	_content_holder = Control.new()
	_content_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(_content_holder)
	var content := _build_content()
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content_holder.add_child(content)
	_fx = preload("res://scripts/ui/fx_overlay.gd").new() # the tablet's glass overlay: kept for the base class, not shown
	root.add_child(_fx)
	_fx.setup(tokens)
	_fx.visible = false
	_cursor = preload("res://scripts/ui/laser_surface.gd").make_cursor()
	root.add_child(_cursor)
	return root


func _build_content() -> Control:
	var stack := Control.new()
	_home_root = Control.new()
	_home_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_child(_home_root)
	var margin := MarginContainer.new() # the old pages, inside the same frame
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 46)
	margin.add_theme_constant_override("margin_top", 34)
	margin.add_theme_constant_override("margin_bottom", 34)
	var old := super._build_content()
	old.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(old)
	_page_view = margin
	_page_view.visible = false
	stack.add_child(_page_view)
	return stack


func show_page(page_name: String) -> void:
	super.show_page(page_name)
	if _home_root != null:
		_home_root.visible = page == "home"
		_page_view.visible = page != "home"


func set_status(text: String) -> void:
	super.set_status(text)
	if _home_status != null and is_instance_valid(_home_status):
		_home_status.text = text


func _refresh_pill() -> void:
	super._refresh_pill()
	if _home_pill != null and is_instance_valid(_home_pill) and main != null:
		_home_pill.text = main.connection_text()
		_home_pill.dot_colour = CYAN if main.has_backend() else AMBER


# --- Home ----------------------------------------------------------------------------------------------------------------------

func _build_home() -> void:
	## Replaces the tablet-style tile grid: built into the deck's own home view, not the pages' scroll body.
	for child in _home_root.get_children():
		_home_root.remove_child(child)
		child.queue_free()
	var tile_by_id := {}
	for tile in tiles():
		tile_by_id[tile["id"]] = tile
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 50)
	margin.add_theme_constant_override("margin_right", 50)
	margin.add_theme_constant_override("margin_top", 38)
	margin.add_theme_constant_override("margin_bottom", 36)
	_home_root.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	margin.add_child(column)

	# top: the name, the connection, close
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	column.add_child(top)
	var brand := Label.new()
	brand.text = "DESIGN TOOLS  ·  VR"
	brand.add_theme_font_size_override("font_size", 24)
	brand.add_theme_color_override("font_color", CYAN)
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(brand)
	_home_pill = DeckButton.new()
	_home_pill.setup("pill", main.connection_text())
	_home_pill.custom_minimum_size = Vector2(420, 52)
	_home_pill.pressed.connect(show_page.bind("servers"))
	top.add_child(_home_pill)
	var close_button := DeckButton.new()
	close_button.setup("close", "Close")
	close_button.custom_minimum_size = Vector2(52, 52)
	close_button.pressed.connect(close)
	top.add_child(close_button)

	# body: the call to action, and the menu lines
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 26)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	var hero_tile: Dictionary = tile_by_id["models"]
	var hero := DeckButton.new()
	hero.name = "Tile_models"
	hero.setup("hero", "Demo models", "Stand a Saturn V beside you at full size, or set one on your desk to turn in your hands.", "models")
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.size_flags_stretch_ratio = 1.15
	hero.custom_minimum_size = Vector2(560, 0)
	hero.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hero.pressed.connect(press_tile.bind("models"))
	body.add_child(hero)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 12)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(rows)
	for id in ROW_IDS:
		var tile: Dictionary = tile_by_id[id]
		var row := DeckButton.new()
		row.name = "Tile_" + id
		row.setup("row", str(tile["label"]), str(tile["note"]), ROW_ICONS[id])
		row.disabled = not tile["enabled"]
		row.locked = not tile["enabled"] and "server" in str(tile["note"]).to_lower()
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(500, 64)
		row.pressed.connect(press_tile.bind(id))
		rows.add_child(row)

	# status line
	_home_status = Label.new()
	_home_status.text = main.status_text
	_home_status.add_theme_font_size_override("font_size", 20)
	_home_status.add_theme_color_override("font_color", DIM)
	_home_status.clip_text = true
	column.add_child(_home_status)

	# bottom: tips ticker, Settings, About
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 14)
	column.add_child(bottom)
	_ticker = _build_ticker()
	_ticker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(_ticker)
	for id in ["settings", "about"]:
		var tile: Dictionary = tile_by_id[id]
		var corner := DeckButton.new()
		corner.name = "Tile_" + id
		corner.setup("corner", str(tile["label"]), str(tile["note"]), "settings" if id == "settings" else "help")
		corner.custom_minimum_size = Vector2(190, 84)
		corner.pressed.connect(press_tile.bind(id))
		bottom.add_child(corner)
	_ticker.visible = _ticker_on
	_shown_tip = -1
	_refresh_ticker()
	_refresh_pill()


func _build_ticker() -> Control:
	var box := ChamferBox.new()
	box.cut = 16.0
	box.ticks = false
	box.fill = Color(0.02, 0.05, 0.11, 0.70)
	box.edge = Color(0.30, 0.88, 1.0, 0.40)
	box.edge_width = 2.0
	box.custom_minimum_size = Vector2(0, 84)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 22
	row.offset_right = -14
	row.offset_top = 8
	row.offset_bottom = -8
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.alignment = BoxContainer.ALIGNMENT_CENTER
	text_box.add_theme_constant_override("separation", 0)
	row.add_child(text_box)
	_ticker_kicker = Label.new()
	_ticker_kicker.add_theme_font_size_override("font_size", 18)
	_ticker_kicker.add_theme_color_override("font_color", AMBER)
	text_box.add_child(_ticker_kicker)
	_ticker_text = Label.new()
	_ticker_text.add_theme_font_size_override("font_size", 22)
	_ticker_text.add_theme_color_override("font_color", INK)
	_ticker_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ticker_text.max_lines_visible = 2
	text_box.add_child(_ticker_text)
	for spec in [["prev", "Previous"], ["pause", "Pause"], ["next", "Next"]]:
		var button := DeckButton.new()
		button.setup("mini", spec[1], "", spec[0])
		button.custom_minimum_size = Vector2(54, 54)
		button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		match spec[0]:
			"prev":
				button.pressed.connect(func() -> void: landing.reel.previous())
			"next":
				button.pressed.connect(func() -> void: landing.reel.next())
			_:
				_ticker_pause = button
				button.pressed.connect(func() -> void: landing.reel.toggle_pause())
		row.add_child(button)
	return box


func set_ticker_visible(on: bool) -> void:
	## Settings > Show tips.
	_ticker_on = on
	if _ticker != null and is_instance_valid(_ticker):
		_ticker.visible = on


func _refresh_ticker() -> void:
	if _ticker == null or not is_instance_valid(_ticker) or landing == null:
		return
	var reel = landing.reel
	if reel.tip_count() == 0:
		reel.set_connected(main.has_backend())
	if reel.tip_count() == 0:
		return
	var tip: Dictionary = reel.current()
	_ticker_kicker.text = "TIP %d / %d  ·  %s" % [reel.index + 1, reel.tip_count(), str(tip["title"]).to_upper()]
	_ticker_text.text = str(tip["text"])
	_shown_tip = reel.index
	if _ticker_pause != null:
		_ticker_pause.icon_name = "play" if reel.paused else "pause"
		_ticker_pause.queue_redraw()


func _process(delta: float) -> void:
	super._process(delta)
	if not is_open() or page != "home" or landing == null or not _ticker_on:
		return
	landing.reel.tick(delta) # the reel's own panel is not shown: the deck's ticker runs the clock
	if landing.reel.index != _shown_tip or (_ticker_pause != null and (_ticker_pause.icon_name == "play") != landing.reel.paused):
		_refresh_ticker()
