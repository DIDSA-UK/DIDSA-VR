extends "res://scripts/landing/launcher_window.gd"
## The landing's own menu: a monolith. A tall dark slab standing on the pad in front of you, the logo at its head against the sky and the menu down its face: the
## connection status, one big call to action (Demo models), a column of menu lines (Continue, Open, New assembly, Demo assemblies, Servers; the ones that need a
## server are dimmed with a padlock when there is none), the tips ticker and Settings / About at the foot. It is fixed where it stands (no grab handle, no resize
## corners). Everything is drawn by deck_button.gd and monolith_face.gd: none of the tablet's theme shows. The inner pages (the demo lists, Servers, Scan, Settings,
## About) are still launcher_window.gd's, shown on the same face until they are given the same treatment.

const DeckButton := preload("res://scripts/landing/deck_button.gd")
const MonolithFace := preload("res://scripts/landing/monolith_face.gd")
const ChamferBox := preload("res://scripts/landing/chamfer_box.gd")
const CYAN := Color(0.30, 0.88, 1.0)
const INK := Color(0.94, 0.98, 1.0)
const DIM := Color(0.56, 0.68, 0.82)
const AMBER := Color(1.0, 0.66, 0.30)
const WIDTH := 1.9 ## metres
const HEIGHT := 2.6 ## a tall slab: a plain crown, the menu, then 0.3 m of plinth. The logo does not sit on it: it floats above the top edge
const DISTANCE := 1.9 ## metres in front of you
const LOGO_RISE := 1.25 ## the logo's centre this far above the slab's top edge (clear air between them, the logo against the sky)
const LOGO_ZONE_PX := 70.0 ## from the top: the plain crown
const PLINTH_PX := 182.0 ## at the foot, clear of the menu
const PX_PER_METRE := 606.0
const THICKNESS := 0.14
const LOGO_STANDOFF := 0.0 ## metres the logo floats in front of the slab's plane (it is above the slab, so it can sway freely)
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
	launcher_panel_size = Vector2(WIDTH, HEIGHT)
	launcher_viewport_size = Vector2i(roundi(WIDTH * PX_PER_METRE), roundi(HEIGHT * PX_PER_METRE))
	corner_hit_reach = -1.0 # a monolith is not resized by its corners


func _build_corners() -> void:
	pass # and shows no resize brackets


static func logo_position(eye: Vector3, forward: Vector3, floor_y: float) -> Vector3:
	## Where the logo hangs: above the slab, separate from it, in the slab's plane. (landing.gd places the logo and its halo from this.)
	var at := eye + forward * (DISTANCE - LOGO_STANDOFF)
	return Vector3(at.x, floor_y + HEIGHT + LOGO_RISE, at.z)


func _place_in_front_of_camera() -> void:
	## Standing on the pad, square to you, DISTANCE ahead: the slab's foot on the floor.
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	var floor_y: float = _camera.get_parent().global_position.y
	var eye := _camera.global_position
	global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), Vector3(eye.x, floor_y + HEIGHT * 0.5, eye.z) + forward * DISTANCE)


func handle_in_reach(_hand: Node3D) -> bool:
	return false # no grab handle: the monolith stays where it stands


# --- Chrome: no tablet theme, a drawn frame ---------------------------------------------------------------------------

func _build_quad() -> void:
	super._build_quad()
	# a slab has depth: a dark body behind the face so it reads as a solid from the side, and glowing rim posts down both edges and across the top
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(WIDTH, HEIGHT, THICKNESS)
	var body_material := StandardMaterial3D.new()
	body_material.albedo_color = Color(0.006, 0.010, 0.022)
	body_material.roughness = 0.35
	body_material.metallic = 0.6
	body_mesh.material = body_material
	var body := MeshInstance3D.new()
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.0, -THICKNESS * 0.5 - 0.002)
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(body)
	var rim_material := StandardMaterial3D.new()
	rim_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rim_material.albedo_color = Color(0.45, 0.92, 1.0)
	rim_material.disable_fog = true
	for spec in [[Vector3(0.012, HEIGHT, 0.02), Vector3(-WIDTH * 0.5, 0.0, 0.004)], [Vector3(0.012, HEIGHT, 0.02), Vector3(WIDTH * 0.5, 0.0, 0.004)], [Vector3(WIDTH, 0.014, 0.02), Vector3(0.0, HEIGHT * 0.5, 0.004)]]:
		var rim_mesh := BoxMesh.new()
		rim_mesh.size = spec[0]
		rim_mesh.material = rim_material
		var rim := MeshInstance3D.new()
		rim.mesh = rim_mesh
		rim.position = spec[1]
		rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(rim)
	var foot_material := StandardMaterial3D.new() # a soft light strip along the floor at its foot
	foot_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foot_material.albedo_color = Color(0.30, 0.82, 1.0, 0.55)
	foot_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foot_material.disable_fog = true
	var foot_mesh := BoxMesh.new()
	foot_mesh.size = Vector3(WIDTH + 0.3, 0.008, 0.10)
	foot_mesh.material = foot_material
	var foot := MeshInstance3D.new()
	foot.mesh = foot_mesh
	foot.position = Vector3(0.0, -HEIGHT * 0.5 + 0.005, 0.07)
	foot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(foot)


func _build_root_ui() -> Control:
	var root := Control.new()
	root.theme = tokens.build_theme() # only for the plain Labels and the keyboard-less pages: the deck's own parts draw themselves
	root.theme.default_font_size = 26
	root.size = Vector2(viewport_size)
	var face := MonolithFace.new()
	face.logo_zone = LOGO_ZONE_PX
	face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(face)
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
	margin.add_theme_constant_override("margin_top", int(LOGO_ZONE_PX) + 30)
	margin.add_theme_constant_override("margin_bottom", int(PLINTH_PX))
	margin.theme = _page_theme()
	var old := super._build_content()
	old.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(old)
	_page_view = margin
	_page_view.visible = false
	stack.add_child(_page_view)
	return stack


func _page_theme() -> Theme:
	## The inner pages (models, servers, scan, settings, about) keep their controls but wear the monolith's look: dark glass buttons with a cyan hairline.
	var theme: Theme = tokens.build_theme()
	theme.default_font_size = 26
	var states := {"normal": [Color(0.02, 0.06, 0.13, 0.92), Color(0.30, 0.88, 1.0, 0.40)], "hover": [Color(0.04, 0.12, 0.24, 0.96), Color(0.30, 0.88, 1.0, 0.95)],
		"pressed": [Color(0.30, 0.88, 1.0, 0.28), Color(1.0, 0.66, 0.30, 1.0)], "focus": [Color(0.04, 0.12, 0.24, 0.96), Color(0.30, 0.88, 1.0, 0.95)],
		"disabled": [Color(0.015, 0.03, 0.07, 0.85), Color(0.56, 0.68, 0.82, 0.18)]}
	for state in states:
		var box := StyleBoxFlat.new()
		box.bg_color = states[state][0]
		box.border_color = states[state][1]
		box.set_border_width_all(2)
		box.set_corner_radius_all(4)
		box.content_margin_left = 18
		box.content_margin_right = 18
		box.content_margin_top = 8
		box.content_margin_bottom = 8
		theme.set_stylebox(state, "Button", box)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", AMBER)
	theme.set_color("font_disabled_color", "Button", DIM)
	theme.set_color("font_color", "Label", INK)
	theme.set_type_variation(&"LabelDim", &"Label")
	theme.set_color("font_color", "LabelDim", DIM)
	theme.set_type_variation(&"LabelSmall", &"Label")
	theme.set_color("font_color", "LabelSmall", DIM)
	theme.set_font_size("font_size", "LabelSmall", 22)
	theme.set_type_variation(&"LabelTitle", &"Label")
	theme.set_color("font_color", "LabelTitle", CYAN)
	theme.set_font_size("font_size", "LabelTitle", 32)
	return theme


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
	margin.add_theme_constant_override("margin_left", 58)
	margin.add_theme_constant_override("margin_right", 58)
	margin.add_theme_constant_override("margin_top", int(LOGO_ZONE_PX) + 26)
	margin.add_theme_constant_override("margin_bottom", int(PLINTH_PX))
	_home_root.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	margin.add_child(column)

	# top: the name, the connection, close
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	column.add_child(top)
	var brand := Label.new()
	brand.text = "DESIGN TOOLS  ·  VR"
	brand.add_theme_font_size_override("font_size", 28)
	brand.add_theme_color_override("font_color", CYAN)
	brand.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(brand)
	_home_pill = DeckButton.new()
	_home_pill.setup("pill", main.connection_text())
	_home_pill.custom_minimum_size = Vector2(520, 56)
	_home_pill.pressed.connect(show_page.bind("servers"))
	top.add_child(_home_pill)
	var close_button := DeckButton.new()
	close_button.setup("close", "Close")
	close_button.custom_minimum_size = Vector2(56, 56)
	close_button.pressed.connect(close)
	top.add_child(close_button)

	# the call to action, then the menu lines, one under the other
	var hero := DeckButton.new()
	hero.name = "Tile_models"
	hero.setup("hero", "Demo models", "Stand a rocket beside you at full size, or set one on your desk.", "models")
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hero.size_flags_stretch_ratio = 2.2
	hero.custom_minimum_size = Vector2(0, 300)
	hero.pressed.connect(press_tile.bind("models"))
	column.add_child(hero)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	rows.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.size_flags_stretch_ratio = 3.0
	column.add_child(rows)
	for id in ROW_IDS:
		var tile: Dictionary = tile_by_id[id]
		var row := DeckButton.new()
		row.name = "Tile_" + id
		row.setup("row", str(tile["label"]), str(tile["note"]), ROW_ICONS[id])
		row.disabled = not tile["enabled"]
		row.locked = not tile["enabled"] and "server" in str(tile["note"]).to_lower()
		row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 72)
		row.pressed.connect(press_tile.bind(id))
		rows.add_child(row)

	# the status line, the tips ticker, and Settings / About at the foot
	_home_status = Label.new()
	_home_status.text = main.status_text
	_home_status.add_theme_font_size_override("font_size", 22)
	_home_status.add_theme_color_override("font_color", DIM)
	_home_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_home_status.custom_minimum_size = Vector2(0, 56)
	column.add_child(_home_status)
	_ticker = _build_ticker()
	_ticker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_ticker)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 14)
	column.add_child(bottom)
	for id in ["settings", "about"]:
		var tile: Dictionary = tile_by_id[id]
		var corner := DeckButton.new()
		corner.name = "Tile_" + id
		corner.setup("corner", str(tile["label"]), str(tile["note"]), "settings" if id == "settings" else "help")
		corner.custom_minimum_size = Vector2(0, 66)
		corner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	box.custom_minimum_size = Vector2(0, 104)
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
	_ticker_kicker.add_theme_font_size_override("font_size", 21)
	_ticker_kicker.add_theme_color_override("font_color", AMBER)
	text_box.add_child(_ticker_kicker)
	_ticker_text = Label.new()
	_ticker_text.add_theme_font_size_override("font_size", 27)
	_ticker_text.add_theme_color_override("font_color", INK)
	_ticker_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ticker_text.max_lines_visible = 2
	text_box.add_child(_ticker_text)
	for spec in [["prev", "Previous"], ["pause", "Pause"], ["next", "Next"]]:
		var button := DeckButton.new()
		button.setup("mini", spec[1], "", spec[0])
		button.custom_minimum_size = Vector2(62, 62)
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
