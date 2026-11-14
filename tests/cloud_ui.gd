extends SceneTree
## S3: the screens of server projects, full scene (main.tscn, no backend; the project store is tests/fake_project_store.gd): Files > Server projects on the wrist tablet (the store's
## projects with a sync-state SYMBOL each, a project's files, a clash with Keep mine / Take theirs / Save mine as a copy, Sync now, a save waiting offline), the Models page's line,
## main.gd following the open server project (search folders, where saves go, the Files header, a save written into the mirror and sent), the landing's "waiting to sync" row, the
## Servers page's project store form and device name, and the pairing card naming the store.
## NOT covered: how any of it looks or feels in the headset, a real laser press (the buttons are pressed directly), a real permission prompt.
## Run: "$GODOT" --headless --path . --script res://tests/cloud_ui.gd  (see tests/README.md)

const Rig := preload("res://tests/cloud_rig.gd")
const FakeStore := preload("res://tests/fake_project_store.gd")
const Payload := preload("res://scripts/landing/pairing_payload.gd")
const ProjectSave := preload("res://scripts/project_save.gd")

var main
var tab
var fake


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _frames(n: int = 3) -> void:
	for i in n:
		await process_frame


func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button and node.is_visible_in_tree():
		out.append(node)
	for child in node.get_children():
		_buttons(child, out)
	return out


func _button(node: Node, text: String) -> Button:
	for b in _buttons(node):
		if b.text == text:
			return b
	return null


func _icons(node: Node, out: Array = []) -> Array:
	if node is TextureRect and node.name == "RowIcon":
		out.append(node)
	for child in node.get_children():
		_icons(child, out)
	return out


func _texts(node: Node, out: Array = []) -> Array:
	if node is Label or node is Button:
		out.append(node.text)
	for child in node.get_children():
		_texts(child, out)
	return out


func _row(id: String) -> Dictionary:
	tab._refresh_side() # (the tablet polls its list four times a second; headless frames are shorter than that)
	for row in tab.pages._cloud_rows():
		if row["id"] == id:
			return row
	return {}


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://settings_cloud_ui_test.cfg")
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_cloud_ui_test.cfg")
	OS.set_environment("DIDSA_SERVERS_PATH", "user://servers_cloud_ui_test.cfg")
	for path in ["user://settings_cloud_ui_test.cfg", "user://recent_cloud_ui_test.cfg", "user://servers_cloud_ui_test.cfg"]:
		DirAccess.remove_absolute(path)
	var base := ProjectSettings.globalize_path("user://cloud_test/ui")
	Rig.wipe(base)
	fake = FakeStore.new()
	fake.add_project("Gearbox")
	fake.add_project("Frames")
	fake.put_direct("Gearbox", "Asm.didsa", Rig.native("p-asm", ""), "Desktop")
	fake.put_direct("Gearbox", "notes.txt", "x", "Desktop")
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = false
	main._settings.folder_asked = true
	root.add_child(main)
	await _frames(3)
	main.cloud.transport = fake
	main.cloud.state_root = base + "/state"
	main._settings.cloud_folder = base + "/DIDSA-Cloud"
	main._settings.device_name = "Quest 3"
	tab = main._tablet

	# --- nothing set up
	main.open_tablet_at("files", "cloud")
	await _frames(4)
	_check(tab.ui.selected_tool_id == "cloud" and main.cloud.is_configured() == false, "Files has a Server projects tool, and with no store set it says how to set one up")
	_check("No project store is set up" in "\n".join(_texts(tab._viewport)), "...in words on the page")

	# --- a store is set (as a server entry would give it)
	main.cloud.configure("http://store.test", fake.key)
	main.open_tablet_at("files", "cloud")
	tab.ui.select_tool("models")
	tab.ui.select_tool("cloud")
	await _frames(6)
	tab._refresh_side()
	var ids: Array = tab.pages._cloud_rows().map(func(r: Dictionary) -> String: return r["id"])
	ids.sort()
	_check(ids == ["project:Frames", "project:Gearbox"], "the store's projects are listed, each with an Open button (%s)" % str(ids))
	_check(_row("project:Gearbox")["icon"] == "cloud" and _icons(tab._side_viewport).size() >= 2, "...each with a symbol (a plain cloud: not downloaded yet)")
	var open_buttons := _buttons(tab._side_viewport).filter(func(b: Button) -> bool: return b.text == "Open")
	_check(open_buttons.size() == 2, "...two Open buttons in the side list")
	# Open Gearbox
	tab.pages._cloud_open_project("Gearbox")
	await _frames(10)
	_check(main.cloud.active != null and main.cloud.active.project == "Gearbox" and tab.pages._cloud_view == "project", "Open makes the project active and shows its files")
	var file_ids: Array = tab.pages._cloud_rows().map(func(r: Dictionary) -> String: return r["id"])
	_check(file_ids.has("file:Asm.didsa") and file_ids.has("file:notes.txt") and file_ids[0] == "head", "...its header row, then every file")
	_check(_row("file:Asm.didsa")["icon"] == "cloud" and _row("head")["icon"] == "cloud_done", "...files not downloaded show the cloud symbol, a synced project the tick")
	_check(_row("file:Asm.didsa")["actions"].size() >= 1 and _row("file:Asm.didsa")["actions"][0]["label"] == "Open" and _row("file:notes.txt")["actions"].is_empty(), "...a model file has Open, a text file none")
	# main follows the project
	var mirror: String = main.cloud.active.mirror_dir
	_check(main.native_search_dirs()[0] == mirror and main.save_dir() == mirror and main.folder_label().begins_with("Server project Gearbox"), "main.gd follows the open server project: its mirror is the project folder, where saves go, and the Files header")
	# download a file
	var got: Dictionary = await main.cloud.open_file("Gearbox", "Asm.didsa")
	await _frames(4)
	_check(got["ok"] and FileAccess.file_exists(mirror + "/Asm.didsa") and _row("file:Asm.didsa").get("icon", "") in ["cloud_done", "cloud"], "opening a file downloads it into the mirror")
	main.cloud.active.changed.emit()
	await _frames(6)
	_check(_row("file:Asm.didsa")["icon"] == "cloud_done", "...and its symbol becomes the tick")

	# --- a save written into the mirror: to send, then sent
	var text := Rig.native("p-asm", "saved in VR")
	ProjectSave.write_atomic(mirror + "/Asm.didsa", text)
	main.cloud.active.scan()
	main.cloud.active.changed.emit()
	await _frames(6)
	_check(_row("file:Asm.didsa")["icon"] == "cloud_up" and _row("head")["icon"] == "cloud_up" and "1 to send" in _row("head")["subtitle"], "a changed file shows the 'to send' symbol and the project says 1 to send")
	var report: Dictionary = await main.cloud.sync_active()
	await _frames(6)
	_check(report["sent"] == ["Asm.didsa"] and fake.file_bytes("Gearbox", "Asm.didsa").get_string_from_utf8() == text and _row("file:Asm.didsa")["icon"] == "cloud_done", "...and after the sync it is on the server and ticked")
	# --- a clash: three buttons
	ProjectSave.write_atomic(mirror + "/Asm.didsa", Rig.native("p-asm", "mine"))
	fake.put_direct("Gearbox", "Asm.didsa", Rig.native("p-asm", "theirs"), "Phone")
	await main.cloud.sync_active()
	await _frames(6)
	var clash_row := _row("clash:Asm.didsa")
	var labels: Array = clash_row.get("actions", []).map(func(a: Dictionary) -> String: return a["label"])
	_check(not clash_row.is_empty() and labels == ["Keep mine", "Take theirs", "Save mine as a copy"] and clash_row["subtitle"].begins_with("Changed by Phone") and clash_row["icon"] == "cloud_clash", "a clash is a row with who changed it and Keep mine / Take theirs / Save mine as a copy, and the clash symbol")
	_check(_row("head")["icon"] == "cloud_clash" and main.cloud.waiting_text() == "1 clash to settle", "...the project's symbol is the clash, and the landing's line counts it")
	tab._refresh_side()
	var visible_keep := _button(tab._side_viewport, "Keep mine")
	_check(visible_keep != null, "...the three buttons are in the side list")
	visible_keep.pressed.emit()
	await _frames(12)
	_check(fake.file_bytes("Gearbox", "Asm.didsa").get_string_from_utf8() == Rig.native("p-asm", "mine") and _row("clash:Asm.didsa").is_empty() and main.cloud.waiting_text() == "", "Keep mine sends mine as the next version at once, and the clash is gone")
	_check(tab.pages._cloud_status().begins_with("Synced"), "...and the status line says it (%s)" % tab.pages._cloud_status())
	# --- offline
	fake.offline = true
	ProjectSave.write_atomic(mirror + "/Asm.didsa", Rig.native("p-asm", "offline"))
	await tab.pages._cloud_sync_now()
	await _frames(6)
	_check(_row("head")["icon"] == "cloud_off" and "not connected" in _row("head")["subtitle"] and "1 to send" in _row("head")["subtitle"] and main.cloud.waiting_text() == "1 save waiting to sync", "offline: the project shows the 'not connected' symbol with 1 to send, and the landing line counts it")
	fake.offline = false
	await tab.pages._cloud_sync_now()
	await _frames(4)
	_check(main.cloud.waiting_text() == "" and fake.file_bytes("Gearbox", "Asm.didsa").get_string_from_utf8() == Rig.native("p-asm", "offline"), "back online, Sync now sends it")

	# --- the Models page has its line
	tab.ui.select_tool("models")
	await _frames(4)
	var models_text := "\n".join(_texts(tab._viewport))
	_check("Server projects are under Files > Server projects." in models_text, "the Models page points to Server projects")
	_check(tab.pages._files_cloud_label.text.begins_with("Server projects are under Files > Server projects.") and main.cloud.waiting_text() == "", "...and has nothing waiting to say once everything is sent")

	# --- a local file ends the server project
	main.cloud.note_path("/tmp/local/Other.didsa")
	_check(main.cloud.active == null and main.native_search_dirs()[0] != mirror and main.save_dir() != mirror and not main.folder_label().begins_with("Server project"), "opening a file outside the mirror ends the server project: the local folder is the project folder again")

	# --- the launcher: Servers page and pairing card
	main.landing_enabled = true
	main.landing.enter()
	await _frames(4)
	var launcher = main.landing.launcher
	launcher.show_page("servers")
	await _frames(3)
	var servers_text := "\n".join(_texts(launcher._body))
	_check("Server projects are copied to" in servers_text and "This device is called: Quest 3" in servers_text and "Project store address (optional)" in servers_text and "Project store key" in servers_text, "the Servers page shows where server projects are copied, this device's name, and the store's address and key fields")
	launcher._form["name"] = "Workshop"
	launcher._form["url"] = "https://cad.example.net"
	launcher._form["api_key"] = "cadkey"
	launcher._form["store_url"] = "https://store.example.net"
	launcher._form["store_key"] = "storekey"
	launcher._save_form()
	await _frames(3)
	var saved: Dictionary = main.server_store.current()
	_check(saved["store_url"] == "https://store.example.net" and saved["store_key"] == "storekey" and main.store_url == "https://store.example.net" and main.cloud.store_url == "https://store.example.net" and main.cloud.store_key == "storekey", "typing the store with the server saves it and the manager follows")
	var bad: Dictionary = main.set_server_store(str(saved["id"]), "http://store.example.com", "k")
	_check(not bad["ok"] and bad["message"] != "", "a store address the headset refuses (plain http to the internet) is refused with the reason")
	var nokey: Dictionary = main.set_server_store(str(saved["id"]), "https://store2.example.net", "")
	_check(not nokey["ok"] and nokey["message"].contains("key"), "a store with no key is refused")
	var cleared: Dictionary = main.set_server_store(str(saved["id"]), "", "")
	_check(cleared["ok"] and main.cloud.store_url == "" and not main.cloud.is_configured(), "the store can be removed; the manager follows")
	main.set_server_store(str(saved["id"]), "https://store.example.net", "storekey")
	main.set_device_name("Workshop Quest")
	_check(main.cloud.device_name() == "Workshop Quest" and main._settings.device_name == "Workshop Quest", "the device name is a setting the manager sends")
	launcher._pending = Payload.parse(Payload.build("Shop", "https://cad2.example.net", "k", "https://store2.example.net", "sk2"))
	launcher.show_page("scan")
	await _frames(2)
	launcher._refresh_card()
	_check("Project store: https://store2.example.net" in "\n".join(_texts(launcher._scan_card)), "the pairing card names the project store from the code")
	launcher._pending = Payload.parse(Payload.build("Shop", "https://cad2.example.net", "k", "https://store2.example.net", "sk2"))
	main.test_server_override = func(_url: String, _key: String) -> Dictionary: return {"ok": true, "message": "ok", "code": 200}
	await launcher._connect_pending()
	await _frames(3)
	var paired: Dictionary = main.server_store.find_by_url("https://cad2.example.net")
	_check(paired.get("store_url", "") == "https://store2.example.net" and paired.get("store_key", "") == "sk2" and main.cloud.store_url == "https://store2.example.net", "Connect saves the store from the code with the server, and uses it")

	# --- the landing's row when something is waiting
	main.cloud.configure("http://store.test", fake.key)
	var waiting_project = main.cloud.project("Gearbox")
	ProjectSave.write_atomic(waiting_project.abs_path("Asm.didsa"), Rig.native("p-asm", "waiting"))
	waiting_project.scan()
	launcher.show_page("home")
	launcher._build_home()
	await _frames(3)
	var alert = launcher._home_root.find_child("CloudWaiting", true, false)
	_check(alert != null and "1 save waiting to sync" in alert.note, "the landing shows what is waiting to sync")
	main.cloud.active = null
	fake.put_direct("Gearbox", "Asm.didsa", "clash", "Phone")
	fake.offline = false
	main.cloud.active = waiting_project
	await main.cloud.sync_active()
	await _frames(3)
	alert = launcher._home_root.find_child("CloudWaiting", true, false)
	_check(alert != null and "clash" in alert.note and alert.title() == "Clash to settle", "...and any clash (the home view redraws when it changes)")
	alert.pressed.emit()
	await _frames(4)
	_check(tab.is_open() and tab.ui.selected_tool_id == "cloud", "pressing it opens Files > Server projects")
	quit(0)
