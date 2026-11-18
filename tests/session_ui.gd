extends SceneTree
## P2: the landing's monolith for live sessions, in the real main.tscn with the fake hub and fake backend: the Host Session and Join Session rows (and the one Session row while
## a session runs), the Host page (what will be shared, why it cannot start), Start session through to the Session page (the code, the QR code that says the same thing, the
## people with Remove, Lock, End), the Join page (code and hub, the Join button), a scanned join code and its card (Join / Cancel; a pairing code still works; a bad join code is
## ignored), the Servers page's Hub form per saved server (refused addresses, a missing key, saved and applied, cleared), and an observer's pages (every file or server page leads to
## the session). Headless: it cannot judge how any of it looks. The text of each page is read back, not rendered.
## Run: "$GODOT" --headless --path . --script res://tests/session_ui.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const P := preload("res://scripts/session/session_protocol.gd")
const DEMO := "res://demo/spacecraft/Pioneer_10.glb"
const SETTINGS := "user://settings_session_ui_test.cfg"
const RECENT := "user://recent_session_ui_test.cfg"
const SERVERS := "user://servers_session_ui_test.cfg"

var main: Node
var hub: RefCounted
var backend: RefCounted
var launcher: Node


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _page_text() -> String:
	var lines: PackedStringArray = []
	for node in launcher._body.find_children("*", "", true, false):
		if node is Label:
			lines.append((node as Label).text)
		elif node is Button:
			lines.append("[%s]" % (node as Button).text)
	return "\n".join(lines)


func _row(id: String) -> Button:
	return launcher._home_root.find_child("Tile_" + id, true, false) as Button


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", SETTINGS)
	OS.set_environment("DIDSA_RECENT_PATH", RECENT)
	OS.set_environment("DIDSA_SERVERS_PATH", SERVERS)
	for f in [SETTINGS, RECENT, SERVERS]:
		DirAccess.remove_absolute(f)
	hub = Hub.new()
	backend = Backend.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	main._settings.folder_asked = true
	root.add_child(main)
	await process_frame
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await process_frame
	await process_frame
	main.session.use_transport(hub.make_transport)
	main.session.http.transport = backend.handle
	launcher = main.landing.launcher
	main.landing.enter()
	await process_frame
	await process_frame
	# --- the home rows
	_check(_row("host") != null and _row("join") != null and _row("session") == null, "the monolith has Host Session and Join Session rows, and no Session row yet")
	_check(not _row("host").disabled and not _row("join").disabled, "...both enabled (a session needs a hub, not a server, to be joined)")
	# --- the Host page: nothing to share
	launcher.show_page("host")
	await process_frame
	var text := _page_text()
	_check(text.contains("Host a live session") and text.contains("Open a model first") and launcher._body.find_child("HostStart", true, false).disabled, "the Host page says what to open first, and Start is off")
	_check(text.contains("No hub is set"), "...and that no hub is set")
	# --- with a demo open, a hub set
	main.load_glb_file(DEMO)
	main.hub_url = "wss://hub.test"
	main.hub_key = hub.key
	launcher.show_page("host")
	await process_frame
	text = _page_text()
	_check(text.contains("Sharing: the demo model Pioneer 10") and text.contains("Hub: wss://hub.test") and not launcher._body.find_child("HostStart", true, false).disabled, "with a demo open and a hub set: it says what it will share and where, and Start is on")
	# --- Start session
	launcher._start_host()
	await _wait(0.8)
	var code: String = main.session.code()
	_check(main.session.is_presenter() and launcher.page == "session", "Start session: hosting, and the page is the Session page")
	_check(launcher._body.find_child("SessionCode", true, false).text == P.code_for_display(code), "the code is shown big, in two groups")
	var qr: TextureRect = launcher._body.find_child("SessionQr", true, false)
	var scanned := P.parse_join(str(qr.get_meta("text")))
	_check(qr != null and qr.texture != null and qr.texture.get_width() > 100 and scanned["ok"] and scanned["code"] == code and scanned["hub_url"] == "wss://hub.test", "the QR code is there and says the same code and hub (didsa-join:1?h=&c=)")
	launcher.show_page("home")
	await process_frame
	_check(_row("session") != null and _row("host") == null and _row("join") == null and str(_row("session").text).length() > 0, "the home menu now has the one Session row (not Host and Join)")
	_row("session").pressed.emit()
	await process_frame
	_check(launcher.page == "session", "...which opens the Session page")
	_check(_page_text().contains("Hosting %s with 1 person" % P.code_for_display(code)), "the page says how many are in")
	# --- people arrive
	var guest := Client.new()
	guest.transport_factory = hub.make_transport
	root.add_child(guest)
	guest.join("wss://hub.test", code, {"name": "Blake", "device": "phone", "client": "test"})
	await _wait(0.5)
	var person: Node = launcher._body.find_child("Person_2", true, false)
	_check(person != null and _page_text().contains("Blake") and _page_text().contains("with 2 people"), "an arrival appears in the list at once")
	var remove_button: Button = launcher._body.find_child("Remove_2", true, false)
	_check(remove_button != null and launcher._body.find_child("Remove_1", true, false) == null, "the presenter can Remove an observer, not themselves")
	launcher._body.find_child("SessionLock", true, false).pressed.emit()
	await _wait(0.4)
	_check(hub.only_room()["locked"] == true and _page_text().contains("Unlock the session"), "Lock locks the room (and the button turns into Unlock)")
	var late := Client.new()
	late.transport_factory = hub.make_transport
	root.add_child(late)
	var late_closed: Array = []
	late.closed.connect(func(kind: String, _t: String) -> void: late_closed.append([kind, late.last_code]))
	late.join("wss://hub.test", code, {"name": "Casey", "device": "quest", "client": "test"})
	await _wait(0.4)
	_check(late_closed == [["error", "room_locked"]], "...so a newcomer is turned away")
	launcher._body.find_child("SessionLock", true, false).pressed.emit()
	var guest_closed: Array = []
	guest.closed.connect(func(kind: String, _t: String) -> void: guest_closed.append([kind, guest.last_code]))
	(launcher._body.find_child("Remove_2", true, false) as Button).pressed.emit()
	await _wait(0.4)
	_check(guest_closed == [["error", "removed"]] and launcher._body.find_child("Person_2", true, false) == null, "Remove: the person is out and gone from the list")
	var table_page: Control = main._tablet.pages._build_settings_session()
	var gather_button: Button = null
	for button in table_page.find_children("*", "Button", true, false):
		if (button as Button).text == "Gather everyone":
			gather_button = button
	_check(gather_button != null and table_page.find_children("*", "Button", true, false).any(func(b: Button) -> bool: return b.text == "End the session"), "the wrist tablet's Settings > Session has Gather everyone and End for a presenter")
	table_page.free()
	launcher._body.find_child("SessionEnd", true, false).pressed.emit()
	await _wait(0.5)
	_check(not main.session.is_active() and launcher.page == "home" and _row("host") != null and _row("session") == null, "End: the session is over and the menu is Host and Join again")
	# --- the Join page
	launcher.show_page("join")
	await process_frame
	var join_button: Button = launcher._body.find_child("JoinStart", true, false)
	_check(_page_text().contains("Hub address: wss://hub.test") and join_button.disabled, "the Join page starts from the hub this headset knows, and Join is off until there is a code")
	launcher._join_form["code"] = "K7XQ4"
	launcher.show_page("join")
	_check(launcher._body.find_child("JoinStart", true, false).disabled, "five characters: still off")
	launcher._join_form["code"] = "K7XQ4M"
	launcher._join_form["hub"] = "ws://hub.example.com"
	launcher.show_page("join")
	_check(launcher._body.find_child("JoinStart", true, false).disabled and launcher._body.find_child("JoinHubNote", true, false) != null, "a plain ws:// hub on the internet: off, with the reason")
	launcher._join_form["hub"] = "wss://hub.test"
	launcher.show_page("join")
	_check(not launcher._body.find_child("JoinStart", true, false).disabled, "a good code and hub: Join is on")
	# a real presenter to join
	backend.tokens["tok-1"] = true
	var presenter := Client.new()
	presenter.transport_factory = hub.make_transport
	root.add_child(presenter)
	presenter.host("wss://hub.test", hub.key, {"name": "Alex", "device": "pcvr", "client": "test", "model": {"kind": "demo", "path": DEMO, "title": "Pioneer 10"}})
	await _wait(0.3)
	launcher._join_form["code"] = str(presenter.room["code"])
	launcher.show_page("join")
	launcher._start_join()
	await _wait(1.5)
	_check(main.session.is_observer() and launcher.page == "session" and _page_text().contains("Watching Alex") and launcher._body.find_child("SessionLeave", true, false) != null and launcher._body.find_child("SessionCode", true, false) == null, "Join: an observer, on the Session page with Leave (no code or QR: that is the presenter's)")
	var watch_page: Control = main._tablet.pages._build_settings_session()
	var labels: Array = watch_page.find_children("*", "Button", true, false).map(func(b: Button) -> String: return b.text)
	_check(labels.has("Go to the presenter") and labels.has("Leave the session") and labels.any(func(t: String) -> bool: return t.begins_with("Follow the presenter")) and not labels.has("Gather everyone"), "...and Go to the presenter, Follow and Leave for an observer (no Gather)")
	watch_page.free()
	var ids: Array = main._tablet.registry.categories().map(func(c) -> String: return c.id)
	_check(ids.has("settings"), "...which an observer's tablet still has (Settings is one of its tiles)")
	# --- an observer's pages
	for page_name in ["servers", "open", "assemblies", "models", "folder", "scan"]:
		launcher.show_page(page_name)
		_check(launcher.page == "session", "an observer asking for the %s page is shown the session instead" % page_name)
	launcher._body.find_child("SessionLeave", true, false).pressed.emit()
	await _wait(0.5)
	_check(not main.is_observer() and launcher.page == "home", "Leave: back to the menu")
	# --- scanning a join code
	launcher.show_page("scan")
	await process_frame
	launcher._on_code_seen("didsa-join:2?c=K7XQ4M")
	_check(launcher._pending_join.is_empty(), "a join code of a version this app does not know is not offered")
	launcher._on_code_seen("didsa-join:1?h=wss%3A%2F%2Fhub.test&c=" + str(presenter.room["code"]))
	await process_frame
	var title: Label = launcher._scan_card.find_child("CardTitle", true, false)
	_check(title != null and title.text == "Join session %s?" % P.code_for_display(str(presenter.room["code"])) and launcher._scan_card.find_child("CardConnect", true, false) != null, "a scanned join code asks 'Join session K7X Q4M?' (nothing happens until it is pressed)")
	_check(not main.session.is_active() and main.status_text.contains("a live session"), "...the status line says what was read, and no connection was made")
	launcher._on_code_seen("didsa-vr:1?n=Pi&u=https%3A%2F%2Fcad.example.net&k=secret")
	await process_frame
	_check(launcher._pending_join.is_empty() and not launcher._pending.is_empty() and launcher._scan_card.find_child("CardTitle", true, false).text.begins_with("Connect to"), "a pairing code scanned next replaces it: the server card, as before")
	launcher._cancel_pending()
	launcher._on_code_seen("didsa-join:1?h=wss%3A%2F%2Fhub.test&c=" + str(presenter.room["code"]))
	await process_frame
	(launcher._scan_card.find_child("CardConnect", true, false) as Button).pressed.emit()
	await _wait(1.5)
	_check(main.session.is_observer() and launcher._pending_join.is_empty(), "pressing Join on the card joins")
	main.session.leave_session()
	await _wait(0.4)
	# --- the Hub form on the Servers page
	var entry: Dictionary = main.add_server({"name": "Workshop", "url": "https://cad.example.net", "api_key": "k1"}, true)
	launcher.show_page("servers")
	await process_frame
	var hub_button: Button = launcher._body.find_child("Hub_" + str(entry["id"]), true, false)
	_check(hub_button != null and hub_button.text == "Hub", "each saved server has a Hub button on the Servers page")
	hub_button.pressed.emit()
	await process_frame
	_check(launcher._body.find_child("HubForm", true, false) != null and launcher._body.find_child("HubForm_hub_url", true, false) != null and launcher._body.find_child("HubForm_hub_key", true, false) != null, "it opens the form: the hub's address and its own key")
	var refused: Dictionary = main.set_server_hub(str(entry["id"]), "ws://hub.example.com", "key")
	_check(not refused["ok"] and str(refused["message"]).contains("ws://"), "a plain ws:// hub on the internet is refused with the reason")
	var local_hub: Dictionary = main.set_server_hub(str(entry["id"]), "ws://127.0.0.1:8300", "key")
	_check(not local_hub["ok"] and str(local_hub["message"]).contains("localhost"), "a hub on localhost is refused (the headset is not the hub)")
	var no_key: Dictionary = main.set_server_hub(str(entry["id"]), "wss://sessions.example.net", "")
	_check(not no_key["ok"] and str(no_key["message"]).contains("key"), "an address with no key is refused: the hub needs its key")
	var saved: Dictionary = main.set_server_hub(str(entry["id"]), "wss://sessions.example.net/ws/", " the-hub-key ")
	_check(saved["ok"] and main.hub_url == "wss://sessions.example.net" and main.hub_key == "the-hub-key", "a good hub is saved (no /ws, no spaces) and applied at once to the server in use")
	_check(main.server_store.find(str(entry["id"]))["hub_url"] == "wss://sessions.example.net" and main.server_store.find(str(entry["id"]))["hub_key"] == "the-hub-key", "...and kept with the server")
	var reloaded := preload("res://scripts/landing/server_store.gd").new()
	reloaded.load_from_disk()
	_check(reloaded.find(str(entry["id"]))["hub_url"] == "wss://sessions.example.net" and reloaded.find(str(entry["id"]))["hub_key"] == "the-hub-key", "...and survives a restart (servers.cfg)")
	launcher.show_page("servers")
	await process_frame
	_check(launcher._body.find_child("Hub_" + str(entry["id"]), true, false).text == "Hub on", "the button says Hub on")
	var cleared: Dictionary = main.set_server_hub(str(entry["id"]), "", "")
	_check(cleared["ok"] and main.hub_url == "" and main.hub_key == "", "an empty address clears it")
	_check(main.set_server_hub("nope", "wss://x.example.net", "k")["ok"] == false, "a server that is not in the list: refused")
	for f in [SETTINGS, RECENT, SERVERS]:
		DirAccess.remove_absolute(f)
	quit()
