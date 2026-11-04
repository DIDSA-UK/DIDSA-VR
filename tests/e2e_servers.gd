extends SceneTree
## Talks to a real backend - LOCAL ONLY (never against a shared backend). The landing's servers and demos end to end through main.tscn (L4, L6 and the demo
## assemblies of L2), starting from an app with NO server: the Test button against the real /health (a wrong key is refused), adding the server and
## switching to it with no restart, the Demo assemblies tiles opening the table and the plate and peg on the real backend, Continue reopening the last file,
## going offline unloading what the server gave, New assembly from its tile, and pairing by QR code (a code fed to the Scan page) against the real server:
## Connect tests it for real and saves it, a wrong key is refused and Save anyway / Cancel work. The pairing part needs an address the headset rules accept
## for this backend (a bare machine name, a private address): it tries this machine's host name and says so (`SMOKE pairing part not run`) if none answers: set DIDSA_E2E_PAIR_HOST to a bare name of 4 or more letters that reaches the backend.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg DIDSA_SERVERS_PATH=user://servers_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_servers.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend; it is only READ here (the app under test is started with no secrets).

const ServerStore := preload("res://scripts/landing/server_store.gd")
const ServerAddress := preload("res://scripts/landing/server_address.gd")
const RecentFile := preload("res://scripts/landing/recent_file.gd")
const SERVERS := "user://servers_e2e_servers.cfg"

var main
var landing
var launcher
var scanner
var url := ""
var key := ""


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func _wait_for(cond: Callable, timeout_ms: int = 40000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func _open_demo_assembly(file_base: String) -> void:
	launcher.show_page("assemblies")
	await frames(2)
	for row in launcher._body.get_children():
		if row.name == "Assembly_" + file_base:
			for c in row.get_children():
				if c is Button:
					c.pressed.emit()


func _code(name: String, u: String, k: String) -> String:
	return "didsa-vr:1?n=%s&u=%s&k=%s" % [name.uri_encode().replace("%20", "+"), u.uri_encode(), k.uri_encode()]


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", "")).rstrip("/")
	key = str(secrets.get_value("backend", "api_key", ""))
	OS.set_environment("DIDSA_SERVERS_PATH", SERVERS)
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_e2e_servers.cfg")
	for path in [SERVERS, "user://recent_e2e_servers.cfg"]:
		DirAccess.remove_absolute(path)

	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # the app under test starts with no server of its own
	main.landing_enabled = true
	main._settings.folder_asked = true # the first-run "where to save" page (T1) is tests/project_folder.gd's; here the launcher opens on Home
	root.add_child(main)
	await frames(2)
	main._settings.folder_asked = true # (again, after _ready: the test settings file may say "not asked") so the launcher opens on Home
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)
	landing = main.landing
	launcher = landing.launcher
	scanner = landing.scanner
	check("the app starts on the landing with no server", landing.is_active() and not main.has_backend())

	# --- Test against the real server -------------------------------------------------------------------------------------------------
	var good: Dictionary = await main.test_server(url, key)
	check("Test: the real /health answers with the right key", good["ok"] and good["code"] == 200)
	var bad: Dictionary = await main.test_server(url, "definitely-not-the-key")
	check("Test: a wrong key is refused, in words", not bad["ok"] and (bad["code"] == 401 or bad["code"] == 403) and "refused the API key" in bad["message"])
	var nobody: Dictionary = await main.test_server("http://127.0.0.1:1", key)
	check("Test: nothing listening is 'could not reach'", not nobody["ok"] and "Could not reach" in nobody["message"])

	# --- add the server and switch, no restart ------------------------------------------------------------------------------------------
	var entry: Dictionary = main.add_server({"name": "Local backend", "url": url, "api_key": key})
	await frames(3)
	check("adding the server switches to it with no restart", main.has_backend() and main.backend_url == url and main.active_server_id == entry["id"])
	launcher.show_page("home")
	await frames(2)
	check("the tiles that need a server come on", not launcher._home_root.find_child("Tile_new", true, false).disabled and not launcher._home_root.find_child("Tile_assemblies", true, false).disabled)

	# --- the demo table --------------------------------------------------------------------------------------------------------------------
	await _open_demo_assembly("Top_and_frame")
	var loaded: bool = await _wait_for(func() -> bool: return main._part_count >= 3 and not main._load_busy)
	check("Demo assemblies: the table opens on the real backend (several parts)", loaded)
	print("SMOKE table: ", main._part_count, " part meshes, status: ", main.status_text)
	check("...the landing was left and the part id is the file's root", not landing.is_active() and main._resolved_part_id != "")
	check("...and it is remembered for Continue", RecentFile.last().get("path", "") == "res://demo/assemblies/table/Top_and_frame.didsa")
	var table_parts: int = main._part_count

	# --- Home, Continue ------------------------------------------------------------------------------------------------------------------
	main.go_home()
	await frames(3)
	var cont: Button = launcher._home_root.find_child("Tile_continue", true, false)
	check("Home: Continue offers the table and is on (a native file with a server)", landing.is_active() and not cont.disabled and "Top_and_frame.didsa" in cont.note)
	cont.pressed.emit()
	var again: bool = await _wait_for(func() -> bool: return not landing.is_active() and main._part_count == table_parts and not main._load_busy)
	check("Continue reopens the same file", again)

	# --- offline unloads what the server gave -------------------------------------------------------------------------------------------------
	check("going offline unloads the server's model", main.switch_server("") and main._part_count == 0 and main.assembly_root.get_child_count() == 0 and main._resolved_part_id == "")
	main.go_home()
	await frames(3)
	launcher.show_page("home")
	await frames(2)
	check("offline again: the tiles grey out and Continue says it needs a server", launcher._home_root.find_child("Tile_new", true, false).disabled and launcher._home_root.find_child("Tile_continue", true, false).disabled and "needs a server" in launcher._home_root.find_child("Tile_continue", true, false).note.to_lower())
	check("switching back to the server", main.switch_server(entry["id"]) and main.has_backend())

	# --- plate and peg, New assembly -----------------------------------------------------------------------------------------------------------
	await _open_demo_assembly("Plate_and_peg")
	var plate: bool = await _wait_for(func() -> bool: return main._part_count >= 2 and not main._load_busy)
	check("Demo assemblies: the plate and peg open (two parts)", plate)
	main.go_home()
	await frames(2)
	launcher.show_page("home")
	await frames(2)
	launcher._home_root.find_child("Tile_new", true, false).pressed.emit()
	var fresh: bool = await _wait_for(func() -> bool: return "New empty assembly" in main.status_text and not main._load_busy)
	check("the New assembly tile starts an empty assembly on the real backend", fresh and not landing.is_active())

	# --- pairing by QR code, against the real server ------------------------------------------------------------------------------------------
	main.switch_server("")
	main.go_home()
	await frames(3)
	var host := ""
	var out: Array = []
	OS.execute("hostname", [], out)
	var port := int(url.get_slice(":", 2).get_slice("/", 0))
	var names: Array = [OS.get_environment("DIDSA_E2E_PAIR_HOST"), str(out[0]).strip_edges() if not out.is_empty() else ""]
	var candidate := ""
	var address_ok := false
	for n in names:
		if str(n) == "" or str(n).length() < 4: # (HTTPRequest refuses a host name shorter than 4 characters)
			continue
		candidate = "http://%s:%d" % [n, port]
		if ServerAddress.check(candidate)["level"] != ServerAddress.Level.REFUSED:
			var probe: Dictionary = await main.test_server(candidate, key)
			if probe["ok"]:
				address_ok = true
				break
	if not address_ok:
		print("SMOKE pairing part not run (it needs a host name the headset rules accept and that reaches the backend: set DIDSA_E2E_PAIR_HOST: a bare name of 4+ letters, not an address; tried ", names, ")")
	else:
		host = candidate
		launcher.show_page("servers")
		await frames(2)
		launcher._body.find_child("Scan", true, false).pressed.emit()
		await frames(2)
		scanner.feed(_code("Paired PC", host, "wrong-key"))
		await frames(2)
		launcher._scan_card.find_child("CardConnect", true, false).pressed.emit()
		var refused: bool = await _wait_for(func() -> bool: return launcher._scan_card.find_child("CardConnect", true, false) != null and launcher._scan_card.find_child("CardConnect", true, false).text == "Save anyway")
		check("pairing with a wrong key: the real server refuses it and the card offers Save anyway / Cancel", refused and "refused the API key" in launcher._scan_card.find_child("CardResult", true, false).text and main.server_store.find_by_url(host).is_empty())
		launcher._scan_card.find_child("CardCancel", true, false).pressed.emit()
		await frames(2)
		check("Cancel saved nothing", main.server_store.find_by_url(host).is_empty() and not main.has_backend())
		scanner._last_seen_ms -= 5000
		scanner.feed(_code("Paired PC", host, key))
		await frames(2)
		launcher._scan_card.find_child("CardConnect", true, false).pressed.emit()
		var paired: bool = await _wait_for(func() -> bool: return main.has_backend() and main.backend_url == host)
		check("pairing with the right key: the real server answers, it is saved and in use", paired and main.server_store.find_by_url(host).get("name", "") == "Paired PC" and launcher.page == "servers")
		await _open_demo_assembly("Plate_and_peg")
		var via_pair: bool = await _wait_for(func() -> bool: return main._part_count >= 2 and not main._load_busy)
		check("the paired credentials open a file on the real backend", via_pair)

	main.queue_free()
	await frames(2)
	for path in [SERVERS, "user://recent_e2e_servers.cfg"]:
		DirAccess.remove_absolute(path)
	print("SMOKE PASSED")
	quit()
