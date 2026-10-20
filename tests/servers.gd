extends SceneTree
## Servers (docs/landing-scope.md L4), no network: the address rules (the headset's half of DIDSA-CAD's pairing checks), the server list file
## (user://servers.cfg: round trip, one entry per address, the cap, a hand-written file as `adb push` would leave it), and main.gd switching
## server WITHOUT a restart (every tool that talks to the backend follows; a loaded server model is unloaded, asking first when it has unsaved
## changes; going offline; forgetting; secrets.cfg as a read-only override that wins at start), and the launcher's Servers page.
## The Test button's real request is tests/server_probe.gd.
## Run: "$GODOT" --headless --path . --script res://tests/servers.gd

const ServerAddress := preload("res://scripts/landing/server_address.gd")
const ServerStore := preload("res://scripts/landing/server_store.gd")
const SERVERS := "user://servers_test.cfg"
const SECRETS := "user://secrets_test.cfg"

var main
var changes := 0


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func make_main(landing_on: bool = true, secrets: String = "res://__nonexistent__.cfg") -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = secrets
	main.landing_enabled = landing_on
	root.add_child(main)
	await frames(2)
	changes = 0
	main.server_changed.connect(func() -> void: changes += 1)


func close_main() -> void:
	main.queue_free()
	await frames(2)


func _initialize() -> void:
	OS.set_environment("DIDSA_SERVERS_PATH", SERVERS)
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://settings_servers_test.cfg")
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_servers_test.cfg")
	for path in [SERVERS, SECRETS, "user://settings_servers_test.cfg", "user://recent_servers_test.cfg"]:
		DirAccess.remove_absolute(path)

	# --- address rules ------------------------------------------------------------------------------------------------------
	var L := ServerAddress.Level
	var vectors := [
		["http://localhost:8000", L.REFUSED], ["http://127.0.0.1:8000", L.REFUSED], ["http://10.0.2.2:8000", L.REFUSED],
		["http://169.254.7.7", L.REFUSED], ["http://example.com", L.REFUSED], ["http://172.32.0.1", L.REFUSED], ["ftp://192.168.1.5", L.REFUSED],
		["not a url", L.REFUSED], ["https://", L.REFUSED], ["", L.REFUSED], ["http://user:pw@192.168.1.5", L.REFUSED], ["https://[::1]:8000", L.REFUSED],
		["http://192.168.1.5:8000", L.WARN], ["http://10.1.2.3", L.WARN], ["http://172.16.0.1", L.WARN], ["http://workshop-pc:8000", L.WARN],
		["http://cad.local", L.WARN], ["https://cad.local", L.WARN], ["https://100.100.1.1", L.WARN], ["https://machine.tail1234.ts.net", L.WARN],
		["https://192.168.1.5", L.WARN], ["https://cad.example.net", L.OK], ["HTTPS://CAD.EXAMPLE.NET/", L.OK], ["https://cad.example.net:8443/api", L.OK],
	]
	var wrong := []
	for v in vectors:
		if ServerAddress.check(v[0])["level"] != v[1]:
			wrong.append(v[0])
	print("SMOKE address vectors wrong: ", wrong)
	check("every address rule matches DIDSA-CAD's pairing checks (%d vectors)" % vectors.size(), wrong.is_empty())
	check("an address is stored without its trailing slash", ServerAddress.check("https://cad.example.net//")["url"] == "https://cad.example.net")
	check("the default name is the host, lower case", ServerAddress.default_name("HTTPS://Cad.Example.NET:8443/x") == "cad.example.net" and ServerAddress.default_name("junk") == "DIDSA server")
	check("plain http on the local network is a warning that says the key is unencrypted", "unencrypted" in ServerAddress.check("http://192.168.1.5:8000")["message"])

	# --- the store --------------------------------------------------------------------------------------------------------------
	var store := ServerStore.new()
	store.load_from_disk()
	check("no file: nothing listed, nothing current", store.servers.is_empty() and store.current().is_empty())
	check("a server needs an address and a key", store.add({"url": "https://a.example.net", "api_key": ""}).is_empty() and store.add({"url": "", "api_key": "k"}).is_empty())
	var first := store.add({"name": "Workshop PC", "url": "https://cad.example.net/", "api_key": " key one ", "relay_url": "https://relay.example.net", "relay_api_key": "rk"})
	check("the first server added becomes current, with its address tidied", store.current_id == first["id"] and first["url"] == "https://cad.example.net" and first["api_key"] == "key one")
	var same := store.add({"name": "Renamed", "url": "https://cad.example.net", "api_key": "key two"})
	check("the same address is one entry (a rescan updates it)", store.servers.size() == 1 and same["id"] == first["id"] and store.servers[0]["name"] == "Renamed" and store.servers[0]["api_key"] == "key two")
	check("an update that names no relay keeps the relay", store.servers[0]["relay_url"] == "https://relay.example.net")
	var second := store.add({"name": "", "url": "http://192.168.1.9:8000", "api_key": "k2"})
	check("a server with no name is named by its host and does not take over as current", second["name"] == "192.168.1.9:8000" and store.current_id == first["id"])
	var again := ServerStore.new()
	again.load_from_disk()
	check("round trip: both servers, the current one and every field come back", again.servers.size() == 2 and again.current_id == first["id"] and again.servers[0] == store.servers[0] and again.servers[1] == store.servers[1])
	check("set_current to an unknown id is refused", not again.set_current("nope") and again.current_id == first["id"])
	check("forgetting the current server leaves none current", again.remove(first["id"]) and again.current_id == "" and again.servers.size() == 1)
	var reloaded := ServerStore.new()
	reloaded.load_from_disk()
	check("a forget is saved", reloaded.servers.size() == 1 and reloaded.current_id == "")
	var many := ServerStore.new()
	for i in 20:
		many.add({"url": "https://s%d.example.net" % i, "api_key": "k"})
	check("the list holds at most %d servers" % ServerStore.MAX_SERVERS, many.servers.size() == ServerStore.MAX_SERVERS)
	DirAccess.remove_absolute(SERVERS)

	# --- a servers.cfg written by hand, as adb push leaves it (docs/servers.md) -----------------------------------------------------
	var f := FileAccess.open(SERVERS, FileAccess.WRITE)
	f.store_string('[servers]\ncurrent="demo"\n\n[server.demo]\nname="Workshop PC"\nurl="https://cad.example.net/"\napi_key="abc"\n\n[server.bad]\nname="No key"\nurl="https://x.example.net"\n')
	f.close()
	await make_main()
	check("a hand-written file: the current server is used at start, without a scan", main.active_server_id == "demo" and main.backend_url == "https://cad.example.net" and main.api_key == "abc")
	check("...and an entry with no key is ignored", main.server_store.servers.size() == 1)
	check("the connection text and the Servers tile say which server", main.connection_text() == "Server: cad.example.net" and main.server_note() == "cad.example.net")
	check("every tool that talks to the backend got it", main._mates_tool.backend_url == "https://cad.example.net" and main._measure_tool.api_key == "abc" and main._assembly_tree_window.backend_url == "https://cad.example.net" and main.room_manager._backend_url == "https://cad.example.net")
	await close_main()
	DirAccess.remove_absolute(SERVERS)

	# --- switching without a restart --------------------------------------------------------------------------------------------------
	await make_main()
	check("start: offline, nothing listed", not main.has_backend() and main.server_entries().is_empty() and main.connection_text() == "Offline: demo models only")
	var a: Dictionary = main.add_server({"name": "Workshop PC", "url": "https://cad.example.net/", "api_key": "ka"})
	check("adding a server uses it at once", main.active_server_id == a["id"] and main.has_backend() and main.backend_url == "https://cad.example.net" and changes == 1)
	check("every tool follows the switch (no restart)", main._mates_tool.backend_url == "https://cad.example.net" and main._measure_tool.api_key == "ka" and main._assembly_tree_window.backend_url == "https://cad.example.net" and main.room_manager._backend_url == "https://cad.example.net" and main.design_table.api.backend_url == "https://cad.example.net")
	var b: Dictionary = main.add_server({"name": "Phone", "url": "http://192.168.1.9:8000", "api_key": "kb", "relay_url": "http://192.168.1.9:9000", "relay_api_key": "rk"})
	check("a second server is switched to; the relay goes with it", main.active_server_id == b["id"] and main.api_key == "kb" and main.relay_url == "http://192.168.1.9:9000" and main._mates_tool.api_key == "kb" and changes == 2)
	var entries: Array = main.server_entries()
	check("the list shows both, the one in use marked", entries.size() == 2 and not entries[0]["current"] and entries[1]["current"])
	check("switching back to the first", main.switch_server(a["id"]) and main.backend_url == "https://cad.example.net" and main.server_store.current_id == a["id"] and changes == 3)
	check("switching to the server already in use does nothing", main.switch_server(a["id"]) and changes == 3)
	check("an unknown server is refused", not main.switch_server("nope") and main.backend_url == "https://cad.example.net")
	check("going offline clears every tool", main.switch_server("") and not main.has_backend() and main._mates_tool.backend_url == "" and main.room_manager._backend_url == "" and main.server_store.current_id == "" and changes == 4)
	check("a server can be forgotten while offline", main.forget_server(b["id"]) and main.server_entries().size() == 1)
	main.switch_server(a["id"])
	check("forgetting the server in use goes offline first", main.forget_server(a["id"]) and not main.has_backend() and main.server_entries().is_empty())
	check("an empty key or a refused address is not saved by the page's rules", main.add_server({"url": "https://x.example.net", "api_key": ""}).is_empty())

	# --- what the old server loaded is unloaded ---------------------------------------------------------------------------------------------
	main.add_server({"name": "One", "url": "https://one.example.net", "api_key": "k1"})
	var two: Dictionary = main.add_server({"name": "Two", "url": "https://two.example.net", "api_key": "k2"}, false)
	main._resolved_part_id = "PART_FROM_ONE" # as if a native file had been opened from server One
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	main.assembly_root.add_child(mesh)
	main._part_count = 1
	main.mark_dirty()
	changes = 0
	check("unsaved changes: switching asks first and changes nothing", not main.switch_server(two["id"]) and main.backend_url == "https://one.example.net" and main.assembly_root.get_child_count() == 1 and changes == 0 and "unsaved" in main.status_text.to_lower())
	check("...doing it again within the window goes ahead", main.switch_server(two["id"]) and main.backend_url == "https://two.example.net")
	await frames(2)
	check("the old server's model is unloaded: no part id, no meshes, clean", main._resolved_part_id == "" and main._part_count == 0 and main.assembly_root.get_child_count() == 0 and not main.document_dirty)
	main._load_busy = true
	check("a load in flight blocks the switch", not main.switch_server("") and main.has_backend())
	main._load_busy = false
	var bare := MeshInstance3D.new()
	bare.mesh = BoxMesh.new()
	main.assembly_root.add_child(bare) # a bare glb has no part id: it does not belong to a server
	main._part_count = 1
	check("a bare glb stays when the server changes", main.switch_server("") and main.assembly_root.get_child_count() == 1)
	await close_main()
	DirAccess.remove_absolute(SERVERS)

	# --- a restart remembers; secrets.cfg is the developer override -----------------------------------------------------------------------
	await make_main()
	var kept: Dictionary = main.add_server({"name": "Kept", "url": "https://kept.example.net", "api_key": "kk"})
	await close_main()
	await make_main()
	check("a restart starts on the server last used", main.active_server_id == kept["id"] and main.backend_url == "https://kept.example.net")
	await close_main()
	var secrets := ConfigFile.new()
	secrets.set_value("backend", "url", "https://dev.example.net")
	secrets.set_value("backend", "api_key", "devkey")
	secrets.save(SECRETS)
	await make_main(true, SECRETS)
	check("secrets.cfg wins at start, even with servers.cfg's current one set", main.active_server_id == "secrets" and main.backend_url == "https://dev.example.net")
	var listed: Array = main.server_entries()
	check("it is listed first as From secrets.cfg, read-only, then servers.cfg's", listed.size() == 2 and listed[0]["name"] == "From secrets.cfg" and listed[0]["readonly"] and listed[0]["current"] and listed[1]["id"] == kept["id"])
	check("secrets.cfg's entry cannot be forgotten", not main.forget_server("secrets") and main.has_backend())
	check("another server can be used meanwhile, and secrets.cfg switched back to", main.switch_server(kept["id"]) and main.backend_url == "https://kept.example.net" and main.switch_server("secrets") and main.backend_url == "https://dev.example.net")
	check("secrets.cfg is never written into servers.cfg", ServerStore.new().find("secrets").is_empty() and not FileAccess.get_file_as_string(SERVERS).contains("dev.example.net"))

	# --- the launcher's Servers page ----------------------------------------------------------------------------------------------------------
	await close_main()
	DirAccess.remove_absolute(SERVERS)
	await make_main(true)
	var launcher = main.landing.launcher
	launcher.show_page("servers")
	await frames(2)
	var body = launcher._body
	check("no servers: the page says none is set and offers the form", "No server is set" in _all_text(body) and body.find_child("Form_url", true, false) != null and body.find_child("Server_*", true, false) == null)
	check("Save and Test are off until there is an address and a key", body.find_child("SaveForm", true, false).disabled and body.find_child("TestForm", true, false).disabled)
	check("Scan is offered", body.find_child("Scan", true, false) != null and not body.find_child("Scan", true, false).disabled)
	body.find_child("Form_url", true, false).pressed.emit()
	await frames(1)
	check("tapping Address opens the full keyboard", main._keyboard.is_open())
	main._keyboard.close()
	launcher._form = {"name": "", "url": "http://example.com", "api_key": "k"}
	launcher.show_page("servers")
	await frames(2)
	check("a refused address shows why and cannot be saved", "https" in launcher._body.find_child("AddressNote", true, false).text and launcher._body.find_child("SaveForm", true, false).disabled)
	launcher._form = {"name": "Workshop PC", "url": "http://192.168.1.5:8000/", "api_key": "secretkey"}
	launcher.show_page("servers")
	await frames(2)
	check("a local http address warns but can be saved", "unencrypted" in launcher._body.find_child("AddressNote", true, false).text and not launcher._body.find_child("SaveForm", true, false).disabled)
	check("the key is never shown in the form", not ("secretkey" in launcher._body.find_child("Form_api_key", true, false).text))
	launcher._body.find_child("SaveForm", true, false).pressed.emit()
	await frames(3)
	check("Save and use switches, lists the server as in use and clears the form", main.backend_url == "http://192.168.1.5:8000" and launcher._body.find_child("Server_" + main.active_server_id, true, false) != null and launcher._form["api_key"] == "")
	check("the landing follows: the connection pill and the tiles that need a server", "192.168.1.5:8000" in launcher._pill.text)
	launcher.show_page("home")
	await frames(2)
	check("with a server the New assembly and Demo assemblies tiles are on", not launcher._body.find_child("Tile_new", true, false).disabled and not launcher._body.find_child("Tile_assemblies", true, false).disabled)
	check("...and the tips reel holds all 17", main.landing.reel.tip_count() == 17)
	launcher.show_page("servers")
	await frames(2)
	var use_offline: Button = null
	for child in launcher._body.get_children():
		if child is Button and child.text.begins_with("Use no server"):
			use_offline = child
	use_offline.pressed.emit()
	await frames(3)
	check("Use no server goes offline and the tiles grey out again", not main.has_backend() and launcher._body.find_child("Server_" + main.server_store.servers[0]["id"], true, false) != null)
	launcher.show_page("home")
	await frames(2)
	check("...New assembly greyed again, the reel back to the offline tips", launcher._body.find_child("Tile_new", true, false).disabled and main.landing.reel.tip_count() < 17)
	launcher.show_page("servers")
	await frames(2)
	var forget: Button = null
	for child in launcher._body.find_child("Server_" + main.server_store.servers[0]["id"], true, false).get_children():
		if child is Button and child.text == "Forget":
			forget = child
	forget.pressed.emit()
	await frames(3)
	check("Forget removes it from the list and the file", main.server_entries().is_empty() and ServerStore.new().servers.is_empty())

	await close_main()
	for path in [SERVERS, SECRETS, "user://settings_servers_test.cfg", "user://recent_servers_test.cfg"]:
		DirAccess.remove_absolute(path)
	print("SMOKE PASSED")
	quit()


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in node.get_children():
		out += _all_text(child)
	return out
