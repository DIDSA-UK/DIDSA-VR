extends "res://scripts/diegetic_panel.gd"
## The landing's launcher: a window of big tiles (Continue, Open, New assembly, Demo models, Demo assemblies, Servers, Settings, About)
## that opens pages inside itself (the demo lists, Settings, About) and acts on the world through landing.gd. Built on
## diegetic_panel.gd like the other windows, so it is carried by its handle and shows the status line in the headset.
## What it needs from a server is greyed with "Needs a server" when none is configured (main.has_backend()).

const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const PairingPayload := preload("res://scripts/landing/pairing_payload.gd")
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
var scanner: Node ## qr_scanner.gd, from landing.gd
var _scan_report: Label
var _scan_read: Label
var _scan_passthrough: Button
var _pending: Dictionary = {} ## a pairing code that was read and is waiting for Connect / Cancel (PairingPayload.parse's result)
var _scan_card: VBoxContainer
var _card_test_failed := false
var _scan_last := "Nothing read yet." ## what the last QR code was, in words (never the code itself: it carries the key)
var _scan_restore_scene := ""
var launcher_panel_size := Vector2(0.88, 0.66) ## metres (the landing deck sets its own in _init)
var launcher_viewport_size := Vector2i(880, 660)
var _form := {"name": "", "url": "https://", "api_key": ""} ## the typed-server form: kept while the page redraws
var _page_before_discard := "" ## the page the "Unsaved changes" choice replaced, to go back to once it is decided


func setup_launcher(left: XRController3D, right: XRController3D, camera: XRCamera3D, p_landing: Node) -> void:
	landing = p_landing
	main = p_landing.main
	panel_title = "DIDSA Design Tools VR"
	panel_size = launcher_panel_size
	viewport_size = launcher_viewport_size
	open_distance = 0.85
	open_lateral_offset = 0.0
	super.setup(left, right, camera)
	main.discard_prompt_changed.connect(_on_discard_prompt)


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


func _on_closed() -> void:
	if page == "scan":
		_leave_scan()


func _on_opened() -> void:
	show_page("home")
	set_status(main.status_text if main != null else "")


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func show_page(name: String) -> void:
	if page == "scan" and name != "scan":
		_leave_scan()
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
		"scan":
			_build_scan()
		"about":
			_build_about()
		"graphics":
			_build_graphics()
		"discard":
			_build_discard()
		"open":
			_build_open()
		_:
			page = "home"
			_build_home()
	set_title({"home": "DIDSA Design Tools VR", "models": "Demo models", "assemblies": "Demo assemblies", "servers": "Servers", "scan": "Scan a QR code",
		"settings": "Settings", "about": "About", "graphics": "Graphics check", "discard": "Unsaved changes", "open": "Open a file"}.get(page, "DIDSA Design Tools VR"))
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
			show_page("open") # the file list is on the monolith itself (Quest 3 report: Open used to throw you onto the wrist tablet)
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
	var button := _action("Scan a QR code", func() -> void: show_page("scan"), 0)
	button.name = "Scan"
	return button


func _form_button(field: String, title: String) -> Button:
	var value := str(_form[field])
	var shown := ("set, %d characters (hidden)" % value.length() if value != "" else "") if field == "api_key" else value
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


# --- Scan a QR code (L5: the headset spike; L6: pairing) --------------------------------------------------------------------

func attach_scanner(p_scanner: Node) -> void:
	scanner = p_scanner
	scanner.report_changed.connect(_refresh_scan)
	scanner.code_seen.connect(_on_code_seen)


func _build_scan() -> void:
	_body.add_child(_hint("On your PC or phone open DIDSA-CAD and choose Connect a VR headset. Turn passthrough on so you can see the screen, then look at the code, close enough that it fills a good part of your view."))
	_scan_passthrough = _action("", _toggle_scan_passthrough, 0)
	_scan_passthrough.name = "Passthrough"
	_body.add_child(_scan_passthrough)
	_scan_report = Label.new()
	_scan_report.name = "ScanReport"
	_scan_report.theme_type_variation = &"LabelSmall"
	_scan_report.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_scan_report)
	_scan_read = Label.new()
	_scan_read.name = "ScanRead"
	_scan_read.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_scan_read)
	_scan_card = VBoxContainer.new()
	_scan_card.name = "ConnectCard"
	_scan_card.add_theme_constant_override("separation", 8)
	_body.add_child(_scan_card)
	_refresh_card()
	_body.add_child(_hint("Quest 3 or later, up to date. Nothing is saved until you say Connect. This page also says exactly what the headset answered at each step, so a scan that does nothing explains itself."))
	scanner.start()
	_refresh_scan()


func _leave_scan() -> void:
	_pending = {}
	_card_test_failed = false
	if scanner != null:
		scanner.stop()
	if _scan_restore_scene != "":
		main.set_scene(_scan_restore_scene)
		_scan_restore_scene = ""


func _toggle_scan_passthrough() -> void:
	if _scan_restore_scene == "":
		_scan_restore_scene = main.current_scene() if main.current_scene() != "Passthrough" else "Mid"
		main.set_scene("Passthrough")
	else:
		main.set_scene(_scan_restore_scene)
		_scan_restore_scene = ""
	_refresh_scan()


func _refresh_scan() -> void:
	if page != "scan" or _scan_report == null or not is_instance_valid(_scan_report):
		return
	var status: String = main.passthrough_status()
	_scan_passthrough.text = "Passthrough: %s" % ("ON (tap to turn off)" if main.current_scene() == "Passthrough" else "off (tap to turn on)")
	_scan_report.text = scanner.report() + ("\n" + status if status != "" else "")
	_scan_read.text = _scan_last


func _on_code_seen(text: String) -> void:
	## A QR code was read. What it is, in words: the code carries the API key, so it is never shown.
	_scan_last = describe_code(text)
	if PairingPayload.looks_like_pairing(text):
		var parsed := PairingPayload.parse(text)
		if parsed["ok"]:
			var fresh: bool = _pending.is_empty() or _pending["url"] != parsed["url"] or _pending["api_key"] != parsed["api_key"]
			_pending = parsed # waits for Connect: nothing is saved or switched until then
			_card_test_failed = false
			_refresh_card()
			if fresh: # the tracker reports the same code many times a second: one tick and one status line per new code
				UiFeedback.haptic(_right, "confirm")
				UiFeedback.play("confirm", self)
				main.say("QR code read: %s, with its API key. Check the card and press Connect." % parsed["name"])
		else:
			UiFeedback.haptic(_right, "error")
	_refresh_scan()


func _refresh_card() -> void:
	## "Connect to <name>?": what the code names (never its key), a warning when the address is plain http, and the two choices. Connect asks the
	## server first; if it does not answer the choice becomes Save anyway / Cancel.
	if _scan_card == null or not is_instance_valid(_scan_card):
		return
	for child in _scan_card.get_children():
		_scan_card.remove_child(child)
		child.queue_free()
	if _pending.is_empty():
		return
	var title := _info("Connect to %s?" % _pending["name"])
	title.name = "CardTitle"
	_scan_card.add_child(title)
	var checks := VBoxContainer.new() # what the code gave, line by line, so it is plain that the read worked and the key came with it
	checks.name = "CardChecks"
	checks.add_child(_check_row(true, "QR code read"))
	checks.add_child(_check_row(true, "Server: %s" % _pending["name"]))
	checks.add_child(_check_row(str(_pending["warning"]) == "", "Address: %s" % ServerAddress.default_name(str(_pending["url"]))))
	checks.add_child(_check_row(true, "API key received (%d characters, kept hidden)" % str(_pending["api_key"]).length()))
	if str(_pending.get("document_session", "")) != "":
		checks.add_child(_check_row(true, "Document session included"))
	_scan_card.add_child(checks)
	var detail := _hint(str(_pending["url"]) + ("\n" + str(_pending["warning"]) if _pending["warning"] != "" else ""))
	detail.name = "CardDetail"
	_scan_card.add_child(detail)
	if not main.server_store.find_by_url(str(_pending["url"])).is_empty():
		_scan_card.add_child(_hint("This server is already saved: connecting updates its key."))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_scan_card.add_child(row)
	var connect := _action("Save anyway" if _card_test_failed else "Connect", _connect_pending, 0)
	connect.name = "CardConnect"
	row.add_child(connect)
	var cancel := _action("Cancel", _cancel_pending, 0)
	cancel.name = "CardCancel"
	row.add_child(cancel)
	var result := Label.new()
	result.name = "CardResult"
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scan_card.add_child(result)


func _cancel_pending() -> void:
	_pending = {}
	_card_test_failed = false
	_scan_last = "Cancelled. Nothing was saved."
	_refresh_card()
	_refresh_scan()


func _connect_pending() -> void:
	if _pending.is_empty():
		return
	var chosen := _pending
	var result_label: Label = _scan_card.find_child("CardResult", true, false)
	if not _card_test_failed:
		for button in _scan_card.find_children("Card*", "Button", true, false):
			(button as Button).disabled = true # one request at a time
		if result_label != null:
			result_label.text = "Testing the server and the API key at %s ..." % chosen["url"]
		var answer: Dictionary = await main.test_server(str(chosen["url"]), str(chosen["api_key"]))
		if not is_instance_valid(self) or _pending != chosen:
			return # cancelled, or another code arrived, while it was asking
		if not answer["ok"]:
			_card_test_failed = true
			_refresh_card()
			var failed_label: Label = _scan_card.find_child("CardResult", true, false)
			if failed_label != null:
				failed_label.text = "The server did not answer: %s Save it anyway, or cancel." % answer["message"]
			UiFeedback.haptic(_right, "error")
			main.say("Pairing: the server did not answer. %s" % answer["message"])
			return
	var entry: Dictionary = main.add_server({"name": chosen["name"], "url": chosen["url"], "api_key": chosen["api_key"],
		"document_session": chosen["document_session"], "relay_url": chosen["relay_url"], "relay_api_key": chosen["relay_api_key"]}, true)
	if entry.is_empty():
		if result_label != null:
			result_label.text = "Couldn't save that server (is the list full? Forget one under Servers)."
		return
	var tested := not _card_test_failed # false: the user chose Save anyway after a failed test
	_pending = {}
	_card_test_failed = false
	show_page("servers")
	if _server_result != null and is_instance_valid(_server_result):
		_server_result.text = ("Connected to %s: the server answered and accepted the API key." if tested else "Saved %s without a working test: it may not connect.") % entry["name"]
	UiFeedback.haptic(_right, "confirm")
	UiFeedback.play("confirm", self)
	main.say("Connected to %s." % entry["name"])


static func describe_code(text: String) -> String:
	if not PairingPayload.looks_like_pairing(text):
		return "Read a QR code that is not a DIDSA pairing code (%d characters). Ignored." % text.length()
	var parsed := PairingPayload.parse(text)
	if not parsed["ok"]:
		return "Read a DIDSA pairing code, but it was refused: %s" % parsed["error"]
	return "Read a DIDSA pairing code for %s (%s)." % [parsed["name"], ServerAddress.default_name(parsed["url"])]


# --- Open a file: the same list as the tablet's Files page, on the monolith -----------------------------------------------------

const OPEN_ROWS_MAX := 40 ## more than this and the rest are on the wrist tablet's Files page (the page scrolls with the stick)


func _build_open() -> void:
	var last := RecentFile.last()
	if not last.is_empty():
		_body.add_child(_hint("Last opened"))
		_body.add_child(_file_row(str(last["path"]), "Recent"))
	var files: PackedStringArray = main.list_model_files() # scanned once, when the page opens (a project folder may be a network mount)
	_body.add_child(_hint("%d model file(s) in the models folders and your project folder." % files.size() if files.size() > 0 else "No model files found. Put .glb, .didsa or STEP files in the models folder, or set a project folder on the wrist tablet (Settings)."))
	for i in mini(files.size(), OPEN_ROWS_MAX):
		_body.add_child(_file_row(files[i], ""))
	if files.size() > OPEN_ROWS_MAX:
		_body.add_child(_hint("And %d more: see the wrist tablet's Files page." % (files.size() - OPEN_ROWS_MAX)))
	if not main.has_backend():
		_body.add_child(_hint(".didsa and STEP files need a server (Servers); .glb files open offline."))
	var more := _action("Save, references and the project folder: on the wrist tablet", landing.open_files, 0)
	more.name = "OpenOnTablet"
	_body.add_child(more)


func _file_row(path: String, note: String) -> Control:
	var box := HBoxContainer.new()
	box.name = "File_" + path.get_file().validate_node_name()
	box.add_theme_constant_override("separation", 8)
	var label := Label.new()
	label.text = "%s\n%s" % [path.get_file(), (note + "  " if note != "" else "") + path.get_extension().to_upper()]
	label.theme_type_variation = &"LabelSmall"
	label.clip_text = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(label)
	var needs_server: bool = path.get_extension().to_lower() not in ["glb", "gltf"] and not main.has_backend()
	var open := _action("Needs a server" if needs_server else "Open", func() -> void: main.load_model_file(path), 200)
	open.name = "Open"
	open.disabled = needs_server
	box.add_child(open)
	return box


# --- Unsaved changes: the choice is made where you are (Quest 3 report: it was only on the wrist tablet) ---------------------------

func _on_discard_prompt() -> void:
	## main.gd has a replace waiting on unsaved changes (or no longer has one). While this menu is open the choice is shown here.
	if main.pending_discard() != "":
		if is_open():
			if page != "discard":
				_page_before_discard = page
			show_page("discard")
	elif page == "discard":
		var back := _page_before_discard if _page_before_discard != "" else "home"
		_page_before_discard = ""
		show_page(back)


func _build_discard() -> void:
	var what: String = main.pending_discard()
	_body.add_child(_info("You have unsaved changes"))
	_body.add_child(_hint("\"%s\" would replace what is open and lose them." % what))
	var discard := _action("Discard them and continue", func() -> void: main.discard_and_continue(), 0)
	discard.name = "DiscardContinue"
	discard.theme_type_variation = &"ButtonDanger"
	_body.add_child(discard)
	var save := _action("Save first, then continue", func() -> void: main.save_and_continue(), 0)
	save.name = "DiscardSave"
	save.disabled = not main.has_backend()
	_body.add_child(save)
	if save.disabled:
		_body.add_child(_hint("Saving needs a server (Servers)."))
	var cancel := _action("Cancel: keep my changes", func() -> void: main.cancel_discard(), 0)
	cancel.name = "DiscardCancel"
	_body.add_child(cancel)


# --- Settings ---------------------------------------------------------------------------------------------

func _build_settings() -> void:
	_body.add_child(_toggle("Show the landing on start", main.show_landing_on_start(), func(on: bool) -> void: main.set_show_landing_on_start(on)))
	_body.add_child(_toggle("Show tips", main.show_tips(), func(on: bool) -> void: main.set_show_tips(on)))
	_body.add_child(_toggle("Reduce motion (logo sway and pulse)", main.reduce_motion(), func(on: bool) -> void: main.set_reduce_motion(on)))
	_body.add_child(_action("Graphics check (for a flicker)", show_page.bind("graphics"), 0))
	_body.add_child(_action("More settings on the wrist tablet", landing.open_tablet_settings, 0))


# --- Graphics check: switch the flicker suspects off one at a time on the headset (docs/quest-first-run-fixes.md B2) ---------------

func _build_graphics() -> void:
	_body.add_child(_hint("If the picture flickers (black, orange or light in either eye), turn these off one at a time and note which one stops it. Each change is written to the log (adb logcat -s godot). Nothing here is saved: a restart puts it all back."))
	var stage: Node = landing.stage
	_body.add_child(_toggle("Night sky shader (off: a flat colour)", not stage.plain_sky, func(on: bool) -> void:
		stage.set_look(not on, stage.fog_on)
		_log_graphics("night sky shader", on)))
	_body.add_child(_toggle("Fog", stage.fog_on, func(on: bool) -> void:
		stage.set_look(stage.plain_sky, on)
		_log_graphics("fog", on)))
	_body.add_child(_toggle("Glow behind the logo", landing.halo_on, func(on: bool) -> void:
		landing.set_halo_on(on)
		_log_graphics("logo glow", on)))
	_body.add_child(_toggle("Rockets", landing.rockets_on, func(on: bool) -> void:
		landing.set_rockets_on(on)
		_log_graphics("rockets", on)))
	var msaa_on_level: int = main.msaa_level() if main.msaa_level() > 0 else clampi(int(ProjectSettings.get_setting("rendering/anti_aliasing/quality/msaa_3d", 2)), 1, 2) # what "on" goes back to
	_body.add_child(_toggle("Anti-aliasing (MSAA %dx)" % [2 if msaa_on_level == 1 else 4], main.msaa_level() > 0, func(on: bool) -> void:
		main.set_msaa(msaa_on_level if on else 0)
		_log_graphics("MSAA", on)))
	var foveation: int = main.foveation_level()
	if foveation >= 0:
		_body.add_child(_toggle("Foveated rendering", foveation > 0, func(on: bool) -> void:
			main.set_foveation_level(2 if on else 0)
			_log_graphics("foveation", on)))
	else:
		_body.add_child(_hint("Foveated rendering: no headset, so not offered."))
	var status := _hint(main.passthrough_status())
	status.name = "PassthroughStatus"
	var button := _toggle("Passthrough", main.current_scene() == "Passthrough", func(on: bool) -> void:
		main.set_scene("Passthrough" if on else "Mid")
		status.text = main.passthrough_status()
		_log_graphics("passthrough", on))
	button.name = "Passthrough"
	_body.add_child(button)
	_body.add_child(status)


func _log_graphics(what: String, on: bool) -> void:
	main.say("Graphics check: %s %s" % [what, "on" if on else "off"]) # the status line is printed too, so it is in the log


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

func _check_row(ok: bool, text: String) -> HBoxContainer:
	## One line of a checklist: a tick (or a warning sign) and the words.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var icon := TextureRect.new()
	icon.texture = UiIcons.texture("check" if ok else "warn", 32)
	icon.modulate = Color(0.45, 0.95, 0.55) if ok else Color(1.0, 0.72, 0.30)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.custom_minimum_size = Vector2(36, 36)
	row.add_child(icon)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	return row


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
