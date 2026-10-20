extends "res://scripts/diegetic_panel.gd"
## The landing's launcher: a window of big tiles (Continue, Open, New assembly, Demo models, Demo assemblies, Servers, Settings, About)
## that opens pages inside itself (the demo lists, Settings, About) and acts on the world through landing.gd. Built on
## diegetic_panel.gd like the other windows, so it is carried by its handle and shows the status line in the headset.
## What it needs from a server is greyed with "Needs a server" when none is configured (main.has_backend()).

const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const ServerAddress := preload("res://scripts/landing/server_address.gd")

const LOWER_BY := 0.28 ## metres below where a window opens (10 cm under the eyes)

signal page_changed(page: String)

var page := "home" ## home | models | assemblies | servers | settings | about
var landing: Node ## landing.gd
var main: Node ## main.gd
var _body: VBoxContainer
var _status: Label
var _pill: Button
var _scroll: ScrollContainer
var _back: Button
var _server_result: Label
var _form := {"name": "", "url": "https://", "api_key": ""} ## the typed-server form: kept while the page redraws


func setup_launcher(left: XRController3D, right: XRController3D, camera: XRCamera3D, p_landing: Node) -> void:
	landing = p_landing
	main = p_landing.main
	panel_title = "DIDSA Design Tools VR"
	panel_size = Vector2(0.88, 0.66)
	viewport_size = Vector2i(880, 660)
	open_distance = 0.85
	open_lateral_offset = 0.0
	super.setup(left, right, camera)


func _place_in_front_of_camera() -> void:
	## Arm's reach and BELOW eye level, so the logo 2.5 m ahead at eye height is seen over the top of it.
	super._place_in_front_of_camera()
	global_position.y -= LOWER_BY


func _build_content() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	column.add_child(top)
	_back = Button.new()
	_back.text = "Back"
	_back.icon = UiIcons.texture("back", 32)
	_back.custom_minimum_size = Vector2(130, 52)
	_back.pressed.connect(show_page.bind("home"))
	top.add_child(_back)
	_pill = Button.new() # the connection pill: which server, or Offline; a tap opens Servers
	_pill.custom_minimum_size = Vector2(0, 52)
	_pill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pill.pressed.connect(show_page.bind("servers"))
	top.add_child(_pill)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scroll)
	scroll_target = _scroll
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	_scroll.add_child(_body)
	_status = Label.new() # what main.gd's _set_status() says: in the headset, not only on the console
	_status.theme_type_variation = &"LabelSmall"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 44)
	column.add_child(_status)
	call_deferred("show_page", "home")
	return column


func _on_opened() -> void:
	show_page("home")
	set_status(main.status_text if main != null else "")


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func show_page(name: String) -> void:
	page = name
	if _body == null:
		return
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_scroll.scroll_vertical = 0
	_back.visible = name != "home"
	_refresh_pill()
	match name:
		"models":
			_build_models()
		"assemblies":
			_build_assemblies()
		"servers":
			_build_servers()
		"settings":
			_build_settings()
		"about":
			_build_about()
		_:
			page = "home"
			_build_home()
	set_title({"home": "DIDSA Design Tools VR", "models": "Demo models", "assemblies": "Demo assemblies", "servers": "Servers",
		"settings": "Settings", "about": "About"}.get(page, "DIDSA Design Tools VR"))
	page_changed.emit(page)


func _refresh_pill() -> void:
	if _pill == null or main == null:
		return
	_pill.text = main.connection_text()
	_pill.icon = UiIcons.texture("browser", 28)


# --- Home -----------------------------------------------------------------------------------------

func tiles() -> Array[Dictionary]:
	## The home screen's tiles in order: {id, label, icon, note, enabled}. A tile that needs a server says so when there is none.
	var online: bool = main.has_backend()
	var last := RecentFile.last()
	var continue_note := "Nothing yet"
	var continue_ok := false
	if not last.is_empty():
		continue_note = str(last["name"])
		continue_ok = online or not RecentFile.needs_server(str(last["path"]))
		if not continue_ok:
			continue_note = "%s: needs a server" % last["name"]
	var needs := "Needs a server"
	return [
		{"id": "continue", "label": "Continue", "icon": "history", "note": continue_note, "enabled": continue_ok},
		{"id": "open", "label": "Open...", "icon": "files", "note": "Pick a file", "enabled": true},
		{"id": "new", "label": "New assembly", "icon": "assembly", "note": "" if online else needs, "enabled": online},
		{"id": "models", "label": "Demo models", "icon": "models", "note": "Rockets, craft", "enabled": true},
		{"id": "assemblies", "label": "Demo assemblies", "icon": "tree", "note": "" if online else needs, "enabled": online},
		{"id": "servers", "label": "Servers", "icon": "browser", "note": main.server_note(), "enabled": true},
		{"id": "settings", "label": "Settings", "icon": "settings", "note": "Tips, comfort", "enabled": true},
		{"id": "about", "label": "About", "icon": "help", "note": "Credits", "enabled": true},
	]


func _build_home() -> void:
	var intro := Label.new()
	intro.text = "Design and assemble parts at full size. The same files as DIDSA-CAD."
	intro.theme_type_variation = &"LabelDim"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(intro)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(grid)
	for tile in tiles():
		grid.add_child(_tile_button(tile))


func _tile_button(tile: Dictionary) -> Button:
	var button := Button.new()
	button.name = "Tile_" + str(tile["id"])
	button.text = str(tile["label"]) if tile["note"] == "" else "%s\n%s" % [tile["label"], tile["note"]]
	button.icon = UiIcons.texture(str(tile["icon"]), 48)
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.expand_icon = false
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 22)
	button.custom_minimum_size = Vector2(180, 140)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.disabled = not tile["enabled"]
	button.pressed.connect(press_tile.bind(str(tile["id"])))
	return button


func press_tile(id: String) -> void:
	match id:
		"continue":
			landing.continue_last()
		"open":
			landing.open_files()
		"new":
			landing.new_assembly()
		"models", "assemblies", "servers", "settings", "about":
			show_page(id)


# --- Demo models ------------------------------------------------------------------------------------

func _build_models() -> void:
	_body.add_child(_hint("Full size stands the model in front of you at 1:1. On the desk puts a small copy on a plinth at waist height that you can grab and turn."))
	for model in DemoCatalog.models():
		var row := HBoxContainer.new()
		row.name = "Model_" + str(model["id"])
		row.add_theme_constant_override("separation", 10)
		_body.add_child(row)
		var label := Label.new()
		label.text = str(model["name"]) if model["height"] <= 0.0 else "%s  (%.1f m)" % [model["name"], model["height"]]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		row.add_child(_action("Full size", landing.show_demo.bind(model, false), 170))
		row.add_child(_action("On the desk", landing.show_demo.bind(model, true), 190))


# --- Demo assemblies ----------------------------------------------------------------------------------

func _build_assemblies() -> void:
	var online: bool = main.has_backend()
	_body.add_child(_hint("These are DIDSA-CAD files, meshed by the server." if online else "These are DIDSA-CAD files, meshed by a server. Needs a server: add one under Servers."))
	for entry in DemoCatalog.assemblies():
		var row := HBoxContainer.new()
		row.name = "Assembly_" + str(entry["path"]).get_file().get_basename()
		row.add_theme_constant_override("separation", 10)
		_body.add_child(row)
		var label := Label.new()
		label.text = str(entry["name"])
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var button := _action("Open" if online else "Needs a server", landing.open_assembly.bind(str(entry["path"])), 240)
		button.disabled = not online or not entry["exists"]
		row.add_child(button)


# --- Servers -----------------------------------------------------------------------------------------------------

func _build_servers() -> void:
	_body.add_child(_info(main.connection_text()))
	_body.add_child(_hint(main.server_detail()))
	_server_result = Label.new() # what Test said
	_server_result.name = "TestResult"
	_server_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_server_result.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(_server_result)
	for entry in main.server_entries():
		_body.add_child(_server_row(entry))
	if main.active_server_id != "":
		_body.add_child(_action("Use no server (offline, demo models only)", func() -> void:
			main.switch_server("")
			show_page("servers"), 0))
	_body.add_child(_hint("Add a server. Point the headset at the QR code DIDSA-CAD shows (Connect a VR headset), or type it."))
	_body.add_child(_scan_button())
	for field in [["name", "Name"], ["url", "Address"], ["api_key", "Key"]]:
		_body.add_child(_form_button(field[0], field[1]))
	var check := ServerAddress.check(str(_form["url"])) if str(_form["url"]) not in ["", "https://"] else {}
	if not check.is_empty():
		var note := _hint(check["message"])
		note.name = "AddressNote"
		_body.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_body.add_child(row)
	var test := _action("Test these", _test_form, 0)
	test.name = "TestForm"
	test.disabled = check.is_empty() or check["level"] == ServerAddress.Level.REFUSED or str(_form["api_key"]) == ""
	row.add_child(test)
	var save := _action("Save and use", _save_form, 0)
	save.name = "SaveForm"
	save.disabled = test.disabled
	row.add_child(save)
	_body.add_child(_hint("The list is kept in %s on this headset. To load it without typing, see docs/servers.md." % OS.get_user_data_dir()))


func _server_row(entry: Dictionary) -> Control:
	var box := HBoxContainer.new()
	box.name = "Server_" + str(entry["id"])
	box.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = "%s\n%s" % [entry["name"], entry["url"]]
	label.theme_type_variation = &"LabelSmall"
	label.clip_text = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(label)
	var use := _action("In use" if entry["current"] else "Use", func() -> void:
		if main.switch_server(str(entry["id"])):
			show_page("servers"), 120)
	use.disabled = entry["current"]
	box.add_child(use)
	box.add_child(_action("Test", func() -> void: _run_test(str(entry["url"]), str(entry["api_key"])), 100))
	if not entry.get("readonly", false):
		box.add_child(_action("Forget", func() -> void:
			if main.forget_server(str(entry["id"])):
				show_page("servers"), 110))
	return box


func _scan_button() -> Button:
	var button := _action("Scan a QR code (coming soon)", func() -> void: pass, 0)
	button.name = "Scan"
	button.disabled = true
	return button


func _form_button(field: String, title: String) -> Button:
	var value := str(_form[field])
	var shown := "•".repeat(mini(value.length(), 12)) if field == "api_key" else value
	var button := _action("%s: %s" % [title, shown if shown != "" else "tap to type"], func() -> void:
		main.open_keyboard_for(str(_form[field]), func(text: String) -> void:
			_form[field] = text.strip_edges()
			if field == "url" and str(_form["name"]) == "":
				_form["name"] = ServerAddress.default_name(text)
			show_page("servers"), {"mode": "full", "title": title}), 0)
	button.name = "Form_" + field
	return button


func _run_test(url: String, key: String) -> void:
	if _server_result != null:
		_server_result.text = "Testing %s ..." % url
	var result: Dictionary = await main.test_server(url, key)
	if _server_result != null and is_instance_valid(_server_result):
		_server_result.text = ("OK: " if result["ok"] else "Not working: ") + str(result["message"])


func _test_form() -> void:
	_run_test(ServerAddress.normalise(str(_form["url"])), str(_form["api_key"]))


func _save_form() -> void:
	var check := ServerAddress.check(str(_form["url"]))
	if check["level"] == ServerAddress.Level.REFUSED:
		return
	var entry: Dictionary = main.add_server({"name": _form["name"], "url": check["url"], "api_key": _form["api_key"]}, true)
	if entry.is_empty():
		main.say("Couldn't save that server (is the list full?).")
		return
	_form = {"name": "", "url": "https://", "api_key": ""}
	show_page("servers")


# --- Settings ---------------------------------------------------------------------------------------------

func _build_settings() -> void:
	_body.add_child(_toggle("Show the landing on start", main.show_landing_on_start(), func(on: bool) -> void: main.set_show_landing_on_start(on)))
	_body.add_child(_toggle("Show tips", main.show_tips(), func(on: bool) -> void: main.set_show_tips(on)))
	_body.add_child(_toggle("Reduce motion (logo sway and pulse)", main.reduce_motion(), func(on: bool) -> void: main.set_reduce_motion(on)))
	_body.add_child(_action("More settings on the wrist tablet", landing.open_tablet_settings, 0))


# --- About ------------------------------------------------------------------------------------------------

func _build_about() -> void:
	_body.add_child(_info("%s %s" % [ProjectSettings.get_setting("application/config/name", "DIDSA Design Tools VR"), ProjectSettings.get_setting("application/config/version", "")]))
	_body.add_child(_hint("A VR client for DIDSA-CAD. Your parts at full size, in the same files as the flat app."))
	var credits := DemoCatalog.credits_plain()
	var label := Label.new()
	label.name = "Credits"
	label.text = credits if credits != "" else "The credits file (demo/CREDITS.md) is missing from this build."
	label.theme_type_variation = &"LabelSmall"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(label)


# --- Small builders ------------------------------------------------------------------------------------------

func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"LabelDim"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _info(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"LabelTitle"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _action(text: String, callback: Callable, min_width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(min_width, 56)
	if min_width == 0.0:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	return button


func _toggle(label: String, on: bool, apply: Callable) -> Button:
	var button := Button.new()
	button.toggle_mode = true
	button.button_pressed = on
	button.custom_minimum_size = Vector2(0, 56)
	button.text = "%s: %s" % [label, "ON" if on else "off"]
	button.toggled.connect(func(now: bool) -> void:
		button.text = "%s: %s" % [label, "ON" if now else "off"]
		apply.call(now))
	return button
