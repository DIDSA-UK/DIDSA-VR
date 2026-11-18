extends "res://scripts/diegetic_panel.gd"
## The landing's launcher: a window of big tiles (Continue, Open, New assembly, Demo models, Demo assemblies, Servers, Settings, About)
## that opens pages inside itself (the demo lists, Settings, About) and acts on the world through landing.gd. Built on
## diegetic_panel.gd like the other windows, so it is carried by its handle and shows the status line in the headset.
## What it needs from a server is greyed with "Needs a server" when none is configured (main.has_backend()).

const DemoCatalog := preload("res://scripts/landing/demo_catalog.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const ThumbnailStore := preload("res://scripts/thumbnail_store.gd")
const FolderChooser := preload("res://scripts/ui/folder_chooser.gd")
const ProjectFolder := preload("res://scripts/project_folder.gd")
const PairingPayload := preload("res://scripts/landing/pairing_payload.gd")
const ServerAddress := preload("res://scripts/landing/server_address.gd")
const StorageProbe := preload("res://scripts/storage_probe.gd")
const SessionProtocol := preload("res://scripts/session/session_protocol.gd")
const QrEncoder := preload("res://scripts/session/qr_encoder.gd")

const LOWER_BY := 0.28 ## metres below where a window opens (10 cm under the eyes)

signal page_changed(page: String)

var page := "home" ## home | models | assemblies | servers | settings | about | folder | graphics | scan | open | discard | host | join | session
var _choosing_folder := false ## the folder page is showing the chooser instead of the first-run card
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
var _scan_step: Label ## the Scan page's one-line "what to do now": passthrough on, look at the code, confirm it
var _scan_passthrough: Button
var _pending: Dictionary = {} ## a pairing code that was read and is waiting for Connect / Cancel (PairingPayload.parse's result)
var _scan_card: VBoxContainer
var _card_test_failed := false
var _scan_last := "Nothing read yet." ## what the last QR code was, in words (never the code itself: it carries the key)
var _scan_restore_scene := ""
var launcher_panel_size := Vector2(0.88, 0.66) ## metres (the landing deck sets its own in _init)
var launcher_viewport_size := Vector2i(880, 660)
var _form := {"name": "", "url": "https://", "api_key": "", "store_url": "", "store_key": ""} ## the typed-server form: kept while the page redraws
var _store_for := "" ## the saved server whose project store is being typed ("" = none): its form shows under the list
var _store_form := {"store_url": "", "store_key": ""}
var _store_note := "" ## what the last project store Save said
var _relay_for := "" ## the saved server whose Browser relay is being typed ("" = none): its form shows under the list
var _relay_form := {"relay_url": "", "relay_api_key": ""}
var _join_form := {"code": "", "hub": ""} ## the Join page's typed code and hub address: kept while the page redraws
var _pending_join: Dictionary = {} ## a join code that was scanned and waits for Join / Cancel (SessionProtocol.parse_join's result)
var _host_result: Label
var _join_result: Label
var _hub_for := "" ## the saved server whose session hub is being typed ("" = none): its form shows under the list
var _hub_form := {"hub_url": "", "hub_key": ""}
var _hub_note := "" ## what the last hub Save said
var _storage_report := "" ## the last "Check storage" result (S0 spike), shown under the button while the page redraws
var _relay_note := "" ## what the last relay Save said
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
	main.cloud.changed.connect(_on_cloud_changed)
	main.session.changed.connect(on_session_changed)


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


func _on_cloud_changed() -> void:
	pass # (landing_monolith.gd redraws its home view when what is waiting to sync changes)


func _on_closed() -> void:
	if page == "scan":
		_leave_scan()


func _on_opened() -> void:
	show_page("folder" if main != null and main.folder_needs_asking() else "home") # the first run asks where projects are saved, once
	set_status(main.status_text if main != null else "")


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func show_page(name: String) -> void:
	if main.is_observer() and name in ["servers", "open", "assemblies", "models", "folder", "scan"]:
		name = "session" # an observer has no files, servers or models of its own (scope section 3): the pill and every such page lead to the session
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
		"folder":
			_build_folder()
		"host":
			_build_host()
		"join":
			_build_join()
		"session":
			_build_session()
		_:
			page = "home"
			_build_home()
	set_title({"home": "DIDSA Design Tools VR", "models": "Demo models", "assemblies": "Demo assemblies", "servers": "Servers", "scan": "Scan a QR code",
		"settings": "Settings", "about": "About", "graphics": "Graphics check", "discard": "Unsaved changes", "open": "Open a file", "folder": "Where to save your projects",
		"host": "Host a session", "join": "Join a session", "session": "Live session"}.get(page, "DIDSA Design Tools VR"))
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
	var watching: bool = main.is_observer()
	var in_session: bool = main.session.is_active()
	var continue_tile := {"id": "continue", "label": "Continue", "icon": "history", "note": continue_note, "enabled": continue_ok}
	if not last.is_empty():
		var picture: Texture2D = ThumbnailStore.load_texture(str(last["path"]), 96) # a picture of the last file, kept when it was opened (S4); none yet: the symbol
		if picture != null:
			continue_tile["thumb"] = picture
	var watching_note := "Not while watching"
	if watching:
		continue_tile["enabled"] = false
		continue_tile["note"] = watching_note
	return [
		continue_tile,
		{"id": "open", "label": "Open...", "icon": "files", "note": watching_note if watching else "Pick a file", "enabled": not watching},
		{"id": "new", "label": "New assembly", "icon": "assembly", "note": watching_note if watching else ("" if online else needs), "enabled": online and not watching},
		{"id": "models", "label": "Demo models", "icon": "models", "note": watching_note if watching else "Rockets, craft", "enabled": not watching},
		{"id": "assemblies", "label": "Demo assemblies", "icon": "tree", "note": watching_note if watching else ("" if online else needs), "enabled": online and not watching},
		{"id": "servers", "label": "Servers", "icon": "browser", "note": watching_note if watching else main.server_note(), "enabled": not watching},
		{"id": "host", "label": "Host Session", "icon": "windows", "note": "Show this to others", "enabled": not in_session},
		{"id": "join", "label": "Join Session", "icon": "view", "note": "With a code or a QR", "enabled": not in_session},
		{"id": "session", "label": "Session", "icon": "navigate", "note": main.session.status_line(), "enabled": true},
		{"id": "settings", "label": "Settings", "icon": "settings", "note": "Tips, comfort", "enabled": true},
		{"id": "about", "label": "About", "icon": "help", "note": "Credits", "enabled": true},
	]


func _build_home() -> void:
	var intro := Label.new()
	intro.text = "Design and assemble parts at full size. The same files as DIDSA-CAD."
	intro.theme_type_variation = &"LabelDim"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(intro)
	var waiting: Dictionary = main.cloud.waiting() # S3: saves not yet on the project store, and any clash (from the saved sync state, no network)
	if int(waiting["to_send"]) > 0 or int(waiting["clash"]) > 0:
		var alert := Button.new()
		alert.name = "CloudWaiting"
		alert.text = main.cloud.waiting_text()
		alert.icon = UiIcons.texture("cloud_clash" if int(waiting["clash"]) > 0 else "cloud_up", 32)
		alert.custom_minimum_size = Vector2(0, 56)
		alert.pressed.connect(func() -> void: landing.open_server_projects())
		_body.add_child(alert)
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
	button.icon = tile["thumb"] if tile.has("thumb") else UiIcons.texture(str(tile["icon"]), 48)
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
		"models", "assemblies", "servers", "settings", "about", "host", "join", "session":
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
		if str(entry["id"]) == _relay_for and not entry.get("readonly", false):
			_build_relay_form(entry)
		if str(entry["id"]) == _store_for and not entry.get("readonly", false):
			_build_store_form(entry)
		if str(entry["id"]) == _hub_for and not entry.get("readonly", false):
			_build_hub_form(entry)
	if main.active_server_id != "":
		_body.add_child(_action("Use no server (offline, demo models only)", func() -> void:
			main.switch_server("")
			show_page("servers"), 0))
	_body.add_child(_hint("Add a server. Point the headset at the QR code DIDSA-CAD shows (Connect a VR headset), or type it."))
	_body.add_child(_scan_button())
	for field in [["name", "Name"], ["url", "Address"], ["api_key", "Key"], ["store_url", "Project store address (optional)"], ["store_key", "Project store key"]]:
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
	_build_store_info()
	# S0 spike (DIDSA-CAD docs/shared-storage-scope.md): where this app's own storage is and how much room it has, for the owner to read off
	# the headset (docs/android-build.md, "Storage for server projects").
	var storage := _action("Check storage", _check_storage, 0)
	storage.name = "CheckStorage"
	_body.add_child(storage)
	if _storage_report != "":
		var result := _hint(_storage_report)
		result.name = "StorageReport"
		_body.add_child(result)


func _check_storage() -> void:
	var report := StorageProbe.report()
	_storage_report = StorageProbe.text(report)
	print(StorageProbe.log_line(report))
	show_page("servers")


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
		var relay := _action("Relay on" if str(entry.get("relay_url", "")) != "" else "Relay", func() -> void:
			_relay_for = "" if _relay_for == str(entry["id"]) else str(entry["id"])
			_relay_form = {"relay_url": str(entry.get("relay_url", "")), "relay_api_key": str(entry.get("relay_api_key", ""))}
			if _relay_form["relay_url"] == "":
				_relay_form["relay_url"] = "ws://"
			_relay_note = ""
			show_page("servers"), 110)
		relay.name = "Relay_" + str(entry["id"])
		box.add_child(relay)
		var hub := _action("Hub on" if str(entry.get("hub_url", "")) != "" else "Hub", func() -> void:
			_hub_for = "" if _hub_for == str(entry["id"]) else str(entry["id"])
			_hub_form = {"hub_url": str(entry.get("hub_url", "")), "hub_key": str(entry.get("hub_key", ""))}
			if _hub_form["hub_url"] == "":
				_hub_form["hub_url"] = "wss://"
			_hub_note = ""
			show_page("servers"), 90)
		hub.name = "Hub_" + str(entry["id"])
		box.add_child(hub)
		var store := _action("Store on" if str(entry.get("store_url", "")) != "" else "Store", func() -> void:
			_store_for = "" if _store_for == str(entry["id"]) else str(entry["id"])
			_store_form = {"store_url": str(entry.get("store_url", "")), "store_key": str(entry.get("store_key", ""))}
			if _store_form["store_url"] == "":
				_store_form["store_url"] = "https://"
			_store_note = ""
			show_page("servers"), 110)
		store.name = "Store_" + str(entry["id"])
		box.add_child(store)
		box.add_child(_action("Forget", func() -> void:
			if main.forget_server(str(entry["id"])):
				show_page("servers"), 110))
	return box


func _build_relay_form(entry: Dictionary) -> void:
	## The Browser window's relay for this server (DIDSA-CAD browser-relay/, docs/servers.md): its ws:// or wss:// address and its own key.
	var box := VBoxContainer.new()
	box.name = "RelayForm"
	_body.add_child(box)
	box.add_child(_hint("Browser relay for %s: the Browser window's own service (port 8100 by default), with its own key, not the CAD key." % entry["name"]))
	for field in [["relay_url", "Relay address"], ["relay_api_key", "Relay key"]]:
		var value := str(_relay_form[field[0]])
		var shown := ("set, %d characters (hidden)" % value.length() if value != "" else "") if field[0] == "relay_api_key" else value
		var f: String = field[0]
		var title: String = field[1]
		var button := _action("%s: %s" % [title, shown if shown not in ["", "ws://"] else "tap to type"], func() -> void:
			main.open_keyboard_for(str(_relay_form[f]), func(text: String) -> void:
				_relay_form[f] = text.strip_edges()
				show_page("servers"), {"mode": "full", "title": title}), 0)
		button.name = "RelayForm_" + f
		box.add_child(button)
	var typed := str(_relay_form["relay_url"])
	if typed not in ["", "ws://"]:
		box.add_child(_hint(str(ServerAddress.check_relay(typed)["message"])))
	if _relay_note != "":
		var note := _hint(_relay_note)
		note.name = "RelayNote"
		box.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var save := _action("Save relay", func() -> void:
		var url := str(_relay_form["relay_url"])
		var answer: Dictionary = main.set_server_relay(str(entry["id"]), "" if url == "ws://" else url, str(_relay_form["relay_api_key"]))
		_relay_note = str(answer["message"])
		if answer["ok"]:
			_relay_for = ""
			main.say(_relay_note)
		show_page("servers"), 0)
	save.name = "RelaySave"
	row.add_child(save)
	if str(entry.get("relay_url", "")) != "":
		var clear := _action("Remove relay", func() -> void:
			main.set_server_relay(str(entry["id"]), "", "")
			_relay_for = ""
			show_page("servers"), 0)
		clear.name = "RelayClear"
		row.add_child(clear)


func _build_hub_form(entry: Dictionary) -> void:
	## The session hub for this server (DIDSA-CAD session-hub/, P2): its ws:// or wss:// address and its own key, not the CAD key. Host Session uses it; Join Session needs neither.
	var box := VBoxContainer.new()
	box.name = "HubForm"
	_body.add_child(box)
	box.add_child(_hint("Session hub for %s: the service that runs live sessions (port 8300 by default), with its own key (SESSION_HUB_API_KEY), not the CAD key. Only needed to HOST a session." % entry["name"]))
	for field in [["hub_url", "Hub address"], ["hub_key", "Hub key"]]:
		var value := str(_hub_form[field[0]])
		var shown := ("set, %d characters (hidden)" % value.length() if value != "" else "") if field[0] == "hub_key" else value
		var f: String = field[0]
		var title: String = field[1]
		var button := _action("%s: %s" % [title, shown if shown not in ["", "wss://"] else "tap to type"], func() -> void:
			main.open_keyboard_for(str(_hub_form[f]), func(text: String) -> void:
				_hub_form[f] = text.strip_edges()
				show_page("servers"), {"mode": "full", "title": title}), 0)
		button.name = "HubForm_" + f
		box.add_child(button)
	var typed := str(_hub_form["hub_url"])
	if typed not in ["", "wss://"]:
		box.add_child(_hint(str(ServerAddress.check_relay(typed)["message"])))
	if _hub_note != "":
		var note := _hint(_hub_note)
		note.name = "HubNote"
		box.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var save := _action("Save hub", func() -> void:
		var url := str(_hub_form["hub_url"])
		var answer: Dictionary = main.set_server_hub(str(entry["id"]), "" if url == "wss://" else url, str(_hub_form["hub_key"]))
		_hub_note = str(answer["message"])
		if answer["ok"]:
			_hub_for = ""
			main.say(_hub_note)
		show_page("servers"), 0)
	save.name = "HubSave"
	row.add_child(save)
	if str(entry.get("hub_url", "")) != "":
		var clear := _action("Remove hub", func() -> void:
			main.set_server_hub(str(entry["id"]), "", "")
			_hub_for = ""
			show_page("servers"), 0)
		clear.name = "HubClear"
		row.add_child(clear)


func _build_store_form(entry: Dictionary) -> void:
	## The project store for this server (DIDSA-CAD project-store/, S3): its address and its own key, not the CAD key. Server projects use it.
	var box := VBoxContainer.new()
	box.name = "StoreForm"
	_body.add_child(box)
	box.add_child(_hint("Project store for %s: the service that keeps your server projects (port 8200 by default), with its own key (PROJECT_STORE_API_KEY), not the CAD key." % entry["name"]))
	for field in [["store_url", "Store address"], ["store_key", "Store key"]]:
		var value := str(_store_form[field[0]])
		var shown := ("set, %d characters (hidden)" % value.length() if value != "" else "") if field[0] == "store_key" else value
		var f: String = field[0]
		var title: String = field[1]
		var button := _action("%s: %s" % [title, shown if shown not in ["", "https://"] else "tap to type"], func() -> void:
			main.open_keyboard_for(str(_store_form[f]), func(text: String) -> void:
				_store_form[f] = text.strip_edges()
				show_page("servers"), {"mode": "full", "title": title}), 0)
		button.name = "StoreForm_" + f
		box.add_child(button)
	var typed := str(_store_form["store_url"])
	if typed not in ["", "https://"]:
		box.add_child(_hint(str(ServerAddress.check(typed)["message"])))
	if _store_note != "":
		var note := _hint(_store_note)
		note.name = "StoreNote"
		box.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var save := _action("Save store", func() -> void:
		var url := str(_store_form["store_url"])
		var answer: Dictionary = main.set_server_store(str(entry["id"]), "" if url == "https://" else url, str(_store_form["store_key"]))
		_store_note = str(answer["message"])
		if answer["ok"]:
			_store_for = ""
			main.say(_store_note)
		show_page("servers"), 0)
	save.name = "StoreSave"
	row.add_child(save)
	if str(entry.get("store_url", "")) != "":
		var clear := _action("Remove store", func() -> void:
			main.set_server_store(str(entry["id"]), "", "")
			_store_for = ""
			show_page("servers"), 0)
		clear.name = "StoreClear"
		row.add_child(clear)


func _build_store_info() -> void:
	## Server projects: where the local copy lives (and why not Documents, if so) and what this device calls itself to the store.
	var cloud: Node = main.cloud
	var lines: PackedStringArray = []
	if cloud.is_configured():
		lines.append("Project store: %s" % cloud.store_url)
	else:
		lines.append("No project store for the server in use: add one with Store (saved servers) or in the form above, or scan DIDSA-CAD's code.")
	var root: Dictionary = cloud.root_info()
	lines.append("Server projects are copied to %s" % (ProjectSettings.globalize_path(str(root["path"])) if str(root["path"]).begins_with("user://") else str(root["path"])))
	if bool(root["fallback"]):
		lines.append(str(root["note"]))
	var info := _hint("\n".join(lines))
	info.name = "StoreInfo"
	_body.add_child(info)
	var named := _action("This device is called: %s" % cloud.device_name(), func() -> void:
		main.open_keyboard_for(cloud.device_name(), func(text: String) -> void:
			main.set_device_name(text)
			show_page("servers"), {"mode": "full", "title": "Name of this device"}), 0)
	named.name = "DeviceName"
	_body.add_child(named)
	_body.add_child(_hint("Other devices see this name next to a change you made (\"changed by Quest 3\"). It is sent to the store and trusted for nothing else."))
	if cloud.is_configured():
		_build_cloud_space(cloud)


const CACHE_CHOICES_MB := [1024, 2048, 5120, 10240, 0] ## the sizes the button cycles through (0 = no limit)


static func cache_text(mb: int) -> String:
	return "no limit" if mb <= 0 else ("%d GB" % (mb / 1024) if mb % 1024 == 0 else "%d MB" % mb)


static func next_cache_mb(current: int) -> int:
	## The next size in CACHE_CHOICES_MB after `current`; a value that is not in the list (set by hand in settings.cfg) goes to the first.
	var i: int = CACHE_CHOICES_MB.find(current)
	return int(CACHE_CHOICES_MB[0]) if i < 0 else int(CACHE_CHOICES_MB[(i + 1) % CACHE_CHOICES_MB.size()])


func _build_cloud_space(cloud: Node) -> void:
	## S4: where the local copies are kept (the one folder setting) and how much room they may take.
	var folder := _action("Local copy folder: %s" % (str(main._settings.cloud_folder) if str(main._settings.cloud_folder) != "" else "default (Documents/DIDSA-Cloud)"), func() -> void:
		main.open_keyboard_for(str(main._settings.cloud_folder), func(text: String) -> void:
			main.set_cloud_folder(text)
			show_page("servers"), {"mode": "full", "title": "Folder for server projects (empty = the default)"}), 0)
	folder.name = "CloudFolder"
	_body.add_child(folder)
	_body.add_child(_hint("Changing it does not move files already copied: the new folder starts empty and fills as you open projects. A folder outside the app needs All files access."))
	var used_mb: float = float(cloud.cache_used_bytes()) / 1048576.0
	var limit_mb := int(main._settings.cloud_cache_mb)
	var cache := _action("Room for local copies: %s (using %d MB)" % [cache_text(limit_mb), int(round(used_mb))], func() -> void:
		main.set_cloud_cache_mb(next_cache_mb(int(main._settings.cloud_cache_mb)))
		show_page("servers"), 0)
	cache.name = "CloudCache"
	_body.add_child(cache)
	var free := _action("Free up space now: remove copies that are safe on the server", func() -> void:
		var result: Dictionary = cloud.cleanup_cache(1) # (a limit of one byte: everything that may go, goes)
		var removed: int = (result["removed"] as Array).size()
		main.say("Removed %d local cop%s (%d MB). They are still on the server." % [removed, "y" if removed == 1 else "ies", int(round(float(result["freed"]) / 1048576.0))] if removed > 0 else "Nothing to remove: every local copy is either waiting to send, open, or inside the limit.")
		show_page("servers"), 0)
	free.name = "CloudFree"
	_body.add_child(free)
	_body.add_child(_hint("Only copies that are exactly what the server has, not open and not waiting to send are ever removed, least recently used first; opening one downloads it again. A save waiting to send is never removed, however much room it takes."))


func _scan_button() -> Button:
	var button := _action("Scan a QR code", func() -> void: show_page("scan"), 0)
	button.name = "Scan"
	return button


func _form_button(field: String, title: String) -> Button:
	var value := str(_form.get(field, ""))
	var shown := ("set, %d characters (hidden)" % value.length() if value != "" else "") if field in ["api_key", "store_key"] else value
	var button := _action("%s: %s" % [title, shown if shown != "" else "tap to type"], func() -> void:
		main.open_keyboard_for(str(_form.get(field, "")), func(text: String) -> void:
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
	var store_check := ServerAddress.check(str(_form.get("store_url", ""))) if str(_form.get("store_url", "")) not in ["", "https://"] else {}
	if not store_check.is_empty() and store_check["level"] == ServerAddress.Level.REFUSED:
		main.say("The project store address is not allowed: %s" % store_check["message"])
		return
	if not store_check.is_empty() and str(_form.get("store_key", "")) == "":
		main.say("The project store needs its key too (PROJECT_STORE_API_KEY).")
		return
	var entry: Dictionary = main.add_server({"name": _form["name"], "url": check["url"], "api_key": _form["api_key"],
		"store_url": "" if store_check.is_empty() else store_check["url"], "store_key": "" if store_check.is_empty() else _form.get("store_key", "")}, true)
	if entry.is_empty():
		main.say("Couldn't save that server (is the list full?).")
		return
	_form = {"name": "", "url": "https://", "api_key": "", "store_url": "", "store_key": ""}
	show_page("servers")


# --- Scan a QR code (L5: the headset spike; L6: pairing) --------------------------------------------------------------------

func attach_scanner(p_scanner: Node) -> void:
	scanner = p_scanner
	scanner.report_changed.connect(_refresh_scan)
	scanner.code_seen.connect(_on_code_seen)


func _build_scan() -> void:
	_scan_step = _info("")
	_scan_step.name = "ScanStep"
	_body.add_child(_scan_step)
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
		if _pending.is_empty():
			main.say("Now look at the QR code on your screen.")
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
	var in_view: int = scanner.codes_in_view() if scanner.running else 0
	_scan_step.text = scan_step_text(main.current_scene() == "Passthrough", not _pending.is_empty(), in_view)
	if _scan_step.text.ends_with("Searching"):
		_scan_step.text += ".".repeat(1 + (Time.get_ticks_msec() / 500) % 3) # moving dots: it is looking (the page refreshes twice a second)
	_scan_step.add_theme_color_override("font_color", Color(0.45, 0.95, 0.55) if not _pending.is_empty() else AMBER_PROMPT)


const AMBER_PROMPT := Color(1.0, 0.78, 0.35)


static func scan_step_text(passthrough_on: bool, code_read: bool, codes_in_view: int = 0) -> String:
	## What to do now on the Scan page, in one line (pure, for the test).
	if code_read:
		return "Step 3 of 3: code read. Check the details below, then press Connect."
	if not passthrough_on:
		return "Step 1 of 3: turn passthrough on (the button below) so you can see your screen."
	if codes_in_view > 0:
		return "Step 2 of 3: a code is in view (it has brackets round it). Reading it: hold still."
	return "Step 2 of 3: look at the QR code on your screen now, about an arm's length away, and hold still until it is read. Searching"


func _on_code_seen(text: String) -> void:
	## A QR code was read. What it is, in words: the code carries the API key, so it is never shown.
	_scan_last = describe_code(text)
	if SessionProtocol.looks_like_join(text):
		var join := SessionProtocol.parse_join(text)
		if join["ok"]:
			var fresh_join: bool = _pending_join.is_empty() or _pending_join["code"] != join["code"]
			_pending_join = join
			_pending = {}
			_refresh_card()
			if fresh_join:
				UiFeedback.haptic(_right, "confirm")
				UiFeedback.play("confirm", self)
				main.say("QR code read: a live session, code %s. Check the card and press Join." % SessionProtocol.code_for_display(str(join["code"])))
		else:
			UiFeedback.haptic(_right, "error")
	elif PairingPayload.looks_like_pairing(text):
		var parsed := PairingPayload.parse(text)
		if parsed["ok"]:
			var fresh: bool = _pending.is_empty() or _pending["url"] != parsed["url"] or _pending["api_key"] != parsed["api_key"]
			_pending = parsed # waits for Connect: nothing is saved or switched until then
			_pending_join = {} # (a join code scanned earlier is replaced by this card)
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
	if not _pending_join.is_empty():
		_build_join_card()
		return
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
	if str(_pending.get("store_url", "")) != "":
		checks.add_child(_check_row(str(_pending.get("store_api_key", "")) != "", "Project store: %s" % _pending["store_url"] + ("" if str(_pending.get("store_api_key", "")) != "" else " (no key: server projects will not connect)")))
	if str(_pending.get("hub_url", "")) != "":
		checks.add_child(_check_row(str(_pending.get("hub_api_key", "")) != "", "Session hub: %s" % _pending["hub_url"] + ("" if str(_pending.get("hub_api_key", "")) != "" else " (no key: Host Session will not connect)")))
	if str(_pending.get("relay_url", "")) != "":
		checks.add_child(_check_row(str(_pending.get("relay_api_key", "")) != "", "Browser relay: %s" % _pending["relay_url"] + ("" if str(_pending.get("relay_api_key", "")) != "" else " (no key: the Browser will not connect)")))
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
	_pending_join = {}
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
		"document_session": chosen["document_session"], "relay_url": chosen["relay_url"], "relay_api_key": chosen["relay_api_key"],
		"store_url": chosen.get("store_url", ""), "store_key": chosen.get("store_api_key", ""),
		"hub_url": chosen.get("hub_url", ""), "hub_key": chosen.get("hub_api_key", "")}, true)
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
	if SessionProtocol.looks_like_join(text):
		var join := SessionProtocol.parse_join(text)
		return "Read a DIDSA join code for session %s." % SessionProtocol.code_for_display(str(join["code"])) if join["ok"] else "Read a DIDSA join code, but it was refused: %s" % join["error"]
	if not PairingPayload.looks_like_pairing(text):
		return "Read a QR code that is not a DIDSA pairing code (%d characters). Ignored." % text.length()
	var parsed := PairingPayload.parse(text)
	if not parsed["ok"]:
		return "Read a DIDSA pairing code, but it was refused: %s" % parsed["error"]
	return "Read a DIDSA pairing code for %s (%s)." % [parsed["name"], ServerAddress.default_name(parsed["url"])]


# --- Live sessions: Host, Join, the session itself (P2; scripts/session/) --------------------------------------------------------------

func on_session_changed() -> void:
	## The session started, changed or ended: the home view and the session pages redraw.
	if page == "session" and not main.session.is_active():
		show_page("home")
	elif page in ["home", "host", "join", "session"]:
		show_page(page)


func _build_host() -> void:
	var session: Node = main.session
	_body.add_child(_info("Host a live session"))
	_body.add_child(_hint("Others join with a short code or a QR code and watch what you show: the model, its parts as you move them, the cut, where you put it. They cannot change anything. They are given a read-only link that stops working when you end the session; your keys are never shared."))
	var offered: Dictionary = session.hostable_model()
	var what := _hint(("Sharing: %s" % ("the model on your server" if offered["source"]["kind"] == "backend" else "the demo model %s" % offered["title"])) if offered["ok"] else str(offered["error"]))
	what.name = "HostWhat"
	_body.add_child(what)
	var hub_text := "No hub is set for this server."
	if str(main.hub_url) != "":
		hub_text = "Hub: %s" % main.hub_url
	elif main.has_backend():
		hub_text = "Hub: the one your server advertises, if it has one (its key is needed, under Servers > Hub)."
	var hub := _hint(hub_text)
	hub.name = "HostHub"
	_body.add_child(hub)
	_body.add_child(_hint("You appear as %s (Servers > This device is called)." % session.display_name()))
	var start := _action("Start session", _start_host, 0)
	start.name = "HostStart"
	start.disabled = not offered["ok"]
	_body.add_child(start)
	_host_result = Label.new()
	_host_result.name = "HostResult"
	_host_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_host_result.text = str(session.last_error)
	_body.add_child(_host_result)
	_body.add_child(_action("Set up the hub (Servers)", func() -> void: show_page("servers"), 0))


func _start_host() -> void:
	_host_result.text = "Starting ..."
	var answer: Dictionary = await main.session.host_session()
	if not is_instance_valid(self):
		return
	if answer["ok"]:
		show_page("session")
	elif _host_result != null and is_instance_valid(_host_result):
		_host_result.text = str(answer["error"])


func _build_join() -> void:
	_body.add_child(_info("Join a live session"))
	_body.add_child(_hint("Type the code the presenter shows, or scan their QR code. You will see what they show. You cannot change it, and what you have open here is put away while you watch."))
	if str(_join_form["hub"]) == "":
		_join_form["hub"] = main.last_session_hub() if main.last_session_hub() != "" else str(main.hub_url)
	for field in [["code", "Session code"], ["hub", "Hub address"]]:
		var f: String = field[0]
		var title: String = field[1]
		var value := str(_join_form[f])
		var shown := SessionProtocol.code_for_display(value) if f == "code" else value
		var button := _action("%s: %s" % [title, shown if shown != "" else "tap to type"], func() -> void:
			main.open_keyboard_for(str(_join_form[f]), func(text: String) -> void:
				_join_form[f] = SessionProtocol.normalise_code(text) if f == "code" else text.strip_edges()
				show_page("join"), {"mode": "full", "title": title}), 0)
		button.name = "Join_" + f
		_body.add_child(button)
	var hub_check := SessionProtocol.hub_address(str(_join_form["hub"]), main.session.allow_loopback) if str(_join_form["hub"]) != "" else {}
	if not hub_check.is_empty():
		var note := _hint(str(hub_check["message"]) if not hub_check["ok"] else str(hub_check["warning"]))
		note.name = "JoinHubNote"
		_body.add_child(note)
	_body.add_child(_hint("A scanned join code carries the hub address, so you need only that."))
	_body.add_child(_scan_button())
	var join := _action("Join", _start_join, 0)
	join.name = "JoinStart"
	join.disabled = not SessionProtocol.code_is_valid(str(_join_form["code"])) or hub_check.is_empty() or not hub_check["ok"]
	_body.add_child(join)
	_join_result = Label.new()
	_join_result.name = "JoinResult"
	_join_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_join_result.text = str(main.session.last_error)
	_body.add_child(_join_result)


func _start_join() -> void:
	_join_result.text = "Joining ..."
	var answer: Dictionary = await main.session.join_session(str(_join_form["hub"]), str(_join_form["code"]))
	if not is_instance_valid(self):
		return
	if answer["ok"]:
		show_page("session")
	elif _join_result != null and is_instance_valid(_join_result):
		_join_result.text = str(answer["error"])


func _build_join_card() -> void:
	## "Join session K7X Q4M?" for a scanned join code: where, and the two choices.
	var title := _info("Join session %s?" % SessionProtocol.code_for_display(str(_pending_join["code"])))
	title.name = "CardTitle"
	_scan_card.add_child(title)
	var hub: String = str(_pending_join["hub_url"]) if str(_pending_join["hub_url"]) != "" else str(main.last_session_hub())
	if hub == "":
		hub = str(main.hub_url)
	var detail := _hint("Hub: %s" % hub if hub != "" else "This code has no hub address and none is known here: type it on the Join page.")
	detail.name = "CardDetail"
	_scan_card.add_child(detail)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_scan_card.add_child(row)
	var join := _action("Join", func() -> void: _connect_join(hub), 0)
	join.name = "CardConnect"
	join.disabled = hub == ""
	row.add_child(join)
	var cancel := _action("Cancel", _cancel_pending, 0)
	cancel.name = "CardCancel"
	row.add_child(cancel)
	var result := Label.new()
	result.name = "CardResult"
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scan_card.add_child(result)


func _connect_join(hub: String) -> void:
	var chosen := _pending_join
	var answer: Dictionary = await main.session.join_session(hub, str(chosen["code"]))
	if not is_instance_valid(self):
		return
	if answer["ok"]:
		_pending_join = {}
		show_page("session")
	else:
		var result_label: Label = _scan_card.find_child("CardResult", true, false) if _scan_card != null and is_instance_valid(_scan_card) else null
		if result_label != null:
			result_label.text = str(answer["error"])


func _build_session() -> void:
	var session: Node = main.session
	if not session.is_active():
		_body.add_child(_info("No session is running."))
		return
	var presenting: bool = session.is_presenter()
	_body.add_child(_info(session.status_line()))
	if presenting:
		var code: String = session.code()
		var big := Label.new()
		big.name = "SessionCode"
		big.text = SessionProtocol.code_for_display(code)
		big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		big.add_theme_font_size_override("font_size", 84)
		big.add_theme_color_override("font_color", CYAN_TEXT)
		_body.add_child(big)
		var uri: String = session.join_uri
		if not uri.contains("h=") and str(session.hub_in_use) != "":
			uri = SessionProtocol.build_join_uri(str(session.hub_in_use), code) # the hub did not know its public address: this app adds the one it used
		var qr := QrEncoder.encode(uri)
		if qr["ok"]:
			var picture := TextureRect.new()
			picture.name = "SessionQr"
			picture.set_meta("text", uri) # what the code says (a test reads it back)
			picture.texture = ImageTexture.create_from_image(QrEncoder.to_image(qr, 10))
			picture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			picture.custom_minimum_size = Vector2(440, 440)
			_body.add_child(picture)
		_body.add_child(_hint("Others: Join Session on the landing, then type the code or scan this. People near you can scan it with the headset's camera."))
	else:
		var status := _hint(str(main.session.observer.status_text) if str(main.session.observer.status_text) != "" else "You see what the presenter shows. You cannot change it.")
		status.name = "SessionStatus"
		_body.add_child(status)
	_body.add_child(_info("In the session"))
	for person in session.client.participants.values():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var label := Label.new()
		var note := "" if bool(person.get("connected", true)) else " (reconnecting)"
		label.text = "%s%s%s%s" % [person["name"], " (presenter)" if person["role"] == "presenter" else "", " (you)" if int(person["id"]) == int(session.client.me.get("id", -1)) else "", note + (" ✋" if bool(person.get("hand", false)) else "")]
		label.add_theme_color_override("font_color", SessionProtocol.colour_of(str(person["colour"]), Color.WHITE))
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if presenting and person["role"] != "presenter":
			var who: int = int(person["id"])
			var remove := _action("Remove", func() -> void: session.client.send({"t": "remove", "id": who}), 0)
			remove.name = "Remove_%d" % who
			row.add_child(remove)
		row.name = "Person_%d" % int(person["id"])
		_body.add_child(row)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	_body.add_child(buttons)
	if presenting:
		var locked := bool(session.client.room.get("locked", false))
		var lock := _action("Unlock the session" if locked else "Lock the session (no new people)", func() -> void:
			session.client.send({"t": "lock", "locked": not locked})
			session.client.room["locked"] = not locked
			show_page("session"), 0)
		lock.name = "SessionLock"
		buttons.add_child(lock)
		var end := _action("End the session", func() -> void: session.end_session(), 0)
		end.name = "SessionEnd"
		buttons.add_child(end)
	else:
		var leave := _action("Leave the session", func() -> void: session.leave_session(), 0)
		leave.name = "SessionLeave"
		buttons.add_child(leave)


const CYAN_TEXT := Color(0.30, 0.88, 1.0)


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
	_body.add_child(_action("Project folder: %s" % ProjectFolder.short_name(main.project_folder()), func() -> void:
		_choosing_folder = false
		show_page("folder"), 0))
	_body.add_child(_action("Graphics check (for a flicker)", show_page.bind("graphics"), 0))
	_body.add_child(_action("More settings on the wrist tablet", landing.open_tablet_settings, 0))


# --- Where to save your projects (T1): asked once on the first run, and from Settings ----------------------------------------------

func _build_folder() -> void:
	## The first-run card (or Settings > Project folder): use Documents/DIDSA, choose another folder, or keep files in the app's own storage.
	if _choosing_folder:
		var chooser := FolderChooser.new()
		chooser.name = "FolderChooser"
		_body.add_child(chooser)
		chooser.setup(main, main.project_folder())
		chooser.chosen.connect(func(_path: String) -> void: _folder_answered())
		chooser.cancelled.connect(func() -> void:
			_choosing_folder = false
			show_page("folder"))
		return
	var proposed := ProjectFolder.default_folder()
	var real := ProjectFolder.full_path(proposed)
	_body.add_child(_info("Your projects will be saved in %s" % ProjectFolder.short_name(proposed)))
	_body.add_child(_hint("That is %s. The headset's Files app and a USB cable can see it, and it stays if the app is removed. Files another app put there (a USB copy, the flat app) may need All files access: Settings on the wrist tablet, Project folder." % real))
	var use := _action("Use this", func() -> void:
		var result: Dictionary = main.use_default_project_folder()
		if result["ok"]:
			_folder_answered()
		else:
			set_status("Can't use %s: %s" % [real, result["error"]]), 0)
	use.name = "FolderUse"
	_body.add_child(use)
	var other := _action("Choose another...", func() -> void:
		_choosing_folder = true
		show_page("folder"), 0)
	other.name = "FolderChoose"
	_body.add_child(other)
	var keep := _action("Keep in app storage", func() -> void:
		main.keep_in_app_storage()
		_folder_answered(), 0)
	keep.name = "FolderKeep"
	_body.add_child(keep)
	_body.add_child(_hint("App storage is private to this app: the Files app may not show it, and it goes if the app is removed."))


func _folder_answered() -> void:
	_choosing_folder = false
	show_page("home")


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
