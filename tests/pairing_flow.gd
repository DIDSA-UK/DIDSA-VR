extends SceneTree
## Pairing by QR code (docs/landing-scope.md L6), full scene (main.tscn, no backend), codes fed in by hand as the headset's scanner would deliver them
## and the server's answer stood in by `main.test_server_override` (a pairing code cannot name localhost, where a stub server would listen; the real
## request is tests/server_probe.gd): a good code raises "Connect to <name>?" and saves NOTHING until Connect; Connect asks the server first, then saves
## and switches (relay and document session carried, every tool re-pointed) and goes to the Servers page; a server that does not answer offers Save
## anyway / Cancel; Cancel (also while it is still asking) saves nothing; a refused or foreign code raises no card and does not wipe one being decided on;
## a newer code replaces it; rescanning a saved server updates its key; plain http on the LAN shows the unencrypted warning; the key is never on screen;
## a full list is reported. Cannot say a real scan works (that is the L5 headset spike).
## Run: "$GODOT" --headless --path . --script res://tests/pairing_flow.gd

const ServerStore := preload("res://scripts/landing/server_store.gd")
const SERVERS := "user://servers_flow_test.cfg"

var main
var launcher
var scanner
var asked: Array = []
var answer := {"ok": true, "message": "The server answers.", "code": 200}
var delay := 0.0


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(count: int = 3) -> void:
	for i in count:
		await process_frame


func code(name: String, url: String, key: String, extra: String = "") -> String:
	return "didsa-vr:1?n=%s&u=%s&k=%s%s" % [name.uri_encode().replace("%20", "+"), url.uri_encode(), key.uri_encode(), extra]


func card(node_name: String) -> Node:
	return launcher._scan_card.find_child(node_name, true, false)


func open_scan() -> void:
	launcher.show_page("servers")
	await frames(1)
	launcher._body.find_child("Scan", true, false).pressed.emit()
	await frames(2)


func _all_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for child in node.get_children():
		out += _all_text(child)
	return out


func _initialize() -> void:
	OS.set_environment("DIDSA_SETTINGS_PATH", "user://settings_flow_test.cfg")
	OS.set_environment("DIDSA_RECENT_PATH", "user://recent_flow_test.cfg")
	OS.set_environment("DIDSA_SERVERS_PATH", SERVERS)
	for path in [SERVERS, "user://settings_flow_test.cfg"]:
		DirAccess.remove_absolute(path)
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	main.landing_enabled = true
	root.add_child(main)
	await frames(2)
	main.get_node("XROrigin3D/XRCamera3D").position = Vector3(0.0, 1.6, 0.0)
	await frames(3)
	launcher = main.landing.launcher
	scanner = main.landing.scanner
	main.test_server_override = func(url: String, key: String) -> Dictionary:
		asked.append([url, key])
		if delay > 0.0:
			await create_timer(delay).timeout
		return answer

	# --- a good code raises the card, saves nothing -----------------------------------------------------------------------------
	await open_scan()
	check("no card before a code", launcher._scan_card.get_child_count() == 0)
	scanner.feed(code("Workshop PC", "https://cad.example.net", "TOPSECRETKEY", "&s=vr-shared&r=" + "https://relay.example.net".uri_encode() + "&rk=RELAYSECRET"))
	await frames(2)
	check("a good code raises 'Connect to Workshop PC?' with its address", card("CardTitle") != null and card("CardTitle").text == "Connect to Workshop PC?" and "https://cad.example.net" in card("CardDetail").text)
	check("it offers Connect and Cancel", card("CardConnect").text == "Connect" and card("CardCancel").text == "Cancel")
	check("nothing is saved or switched yet", main.server_store.servers.is_empty() and not main.has_backend() and asked.is_empty())
	check("neither the key nor the relay key is on screen", not ("TOPSECRETKEY" in _all_text(launcher._body)) and not ("RELAYSECRET" in _all_text(launcher._body)))
	var checks := _all_text(card("CardChecks"))
	check("the card lists what the code gave, with a tick each: read, server, address, the key received (its length, not its value), the session", "QR code read" in checks and "Server: Workshop PC" in checks and "Address: cad.example.net" in checks and "API key received (12 characters, kept hidden)" in checks and "Document session included" in checks and card("CardChecks").find_children("*", "TextureRect", true, false).size() == 5)
	check("the status line says the code was read with its key", "QR code read: Workshop PC, with its API key" in main.status_text)
	main.say("something else")
	scanner._last_seen_ms -= 5000
	scanner.feed(code("Workshop PC", "https://cad.example.net", "TOPSECRETKEY", "&s=vr-shared&r=" + "https://relay.example.net".uri_encode() + "&rk=RELAYSECRET"))
	await frames(2)
	check("the same code seen again does not repeat the status line (the tracker reports it many times a second)", main.status_text == "something else")

	# --- Connect: asks, saves, switches ------------------------------------------------------------------------------------------
	card("CardConnect").pressed.emit()
	await frames(3)
	check("Connect asked the server with the code's address and key", asked == [["https://cad.example.net", "TOPSECRETKEY"]])
	var entry: Dictionary = main.server_store.current()
	check("it saved the server and switched to it", entry.get("url", "") == "https://cad.example.net" and main.has_backend() and main.backend_url == "https://cad.example.net" and main.active_server_id == entry.get("id", "x"))
	check("the document session and the relay came with it", entry["document_session"] == "vr-shared" and entry["relay_url"] == "https://relay.example.net" and entry["relay_api_key"] == "RELAYSECRET" and main.relay_url == "https://relay.example.net")
	check("every tool follows (no restart)", main._mates_tool.api_key == "TOPSECRETKEY" and main._measure_tool.backend_url == "https://cad.example.net" and main.room_manager._backend_url == "https://cad.example.net")
	check("the Servers page says the server answered and accepted the key", "accepted the API key" in (launcher._body.find_child("TestResult", true, false) as Label).text)
	check("the Servers page is shown with it in use, the scanner stopped, and the status says connected", launcher.page == "servers" and not scanner.running and "Connected to Workshop PC" in main.status_text and launcher._body.find_child("Server_" + entry["id"], true, false) != null)
	var on_disk := ServerStore.new()
	on_disk.load_from_disk()
	check("it is in servers.cfg for the next start, as the current server", on_disk.find_by_url("https://cad.example.net").get("api_key", "") == "TOPSECRETKEY" and on_disk.current_id == entry["id"])

	# --- a server that does not answer ---------------------------------------------------------------------------------------------
	main.switch_server("")
	asked.clear()
	answer = {"ok": false, "message": "Could not reach the server. Is it running, and is the address right?", "code": 0}
	await open_scan()
	scanner.feed(code("Phone", "http://192.168.1.9:8000", "phonekey"))
	await frames(2)
	check("plain http on the LAN shows the unencrypted warning on the card", "unencrypted" in card("CardDetail").text and "http://192.168.1.9:8000" in card("CardDetail").text)
	check("...and its address line carries a warning sign, not a tick", card("CardChecks").get_child(2).get_child(0).modulate.r > 0.9)
	card("CardConnect").pressed.emit()
	await frames(3)
	check("a server that does not answer is not saved yet; the card says why and offers Save anyway", main.server_store.find_by_url("http://192.168.1.9:8000").is_empty() and "did not answer" in card("CardResult").text and card("CardConnect").text == "Save anyway")
	card("CardCancel").pressed.emit()
	await frames(2)
	check("Cancel saves nothing, clears the card and says so", launcher._scan_card.get_child_count() == 0 and main.server_store.find_by_url("http://192.168.1.9:8000").is_empty() and "Nothing was saved" in launcher._scan_read.text)
	scanner._last_seen_ms -= 5000
	scanner.feed(code("Phone", "http://192.168.1.9:8000", "phonekey"))
	await frames(2)
	card("CardConnect").pressed.emit()
	await frames(3)
	card("CardConnect").pressed.emit()
	await frames(3)
	check("Save anyway saves and switches without asking again", asked.size() == 2 and main.backend_url == "http://192.168.1.9:8000" and main.active_server_id != "")

	# --- cancelled while it is still asking -----------------------------------------------------------------------------------------
	main.switch_server("")
	answer = {"ok": true, "message": "The server answers.", "code": 200}
	delay = 0.6
	await open_scan()
	scanner.feed(code("Slow", "https://slow.example.net", "k"))
	await frames(2)
	card("CardConnect").pressed.emit()
	await frames(2)
	check("while it asks, the buttons are off (one request at a time)", card("CardConnect").disabled)
	launcher._cancel_pending()
	await create_timer(1.0).timeout
	check("cancelling while it was asking saves nothing when the answer arrives", main.server_store.find_by_url("https://slow.example.net").is_empty() and not main.has_backend())
	delay = 0.0

	# --- other codes, newer codes -----------------------------------------------------------------------------------------------------
	scanner.feed(code("First", "https://first.example.net", "k1"))
	await frames(2)
	scanner.feed("https://example.com/menu")
	scanner.feed("didsa-vr:1?u=http%3A%2F%2Fexample.com&k=k")
	scanner.feed("didsa-vr:2?u=https%3A%2F%2Fa.example.net&k=k")
	await frames(2)
	check("another QR code, a refused code and a newer version raise no card and do not wipe the one being decided on", card("CardTitle").text == "Connect to First?")
	check("...and the last one says why it was refused", "version 2" in launcher._scan_read.text)
	scanner.feed(code("Second", "https://second.example.net", "k2"))
	await frames(2)
	check("a newer good code replaces the card", card("CardTitle").text == "Connect to Second?" and "second.example.net" in card("CardDetail").text)

	# --- rescanning a saved server updates its key --------------------------------------------------------------------------------------
	card("CardConnect").pressed.emit()
	await frames(3)
	var count_before: int = main.server_store.servers.size()
	await open_scan()
	scanner.feed(code("Second renamed", "https://second.example.net/", "newkey"))
	await frames(2)
	check("a saved server says connecting updates its key", "already saved" in _all_text(launcher._scan_card))
	card("CardConnect").pressed.emit()
	await frames(3)
	check("it is one entry with the new key and name, and the tools use the new key", main.server_store.servers.size() == count_before and main.server_store.find_by_url("https://second.example.net")["api_key"] == "newkey" and main.server_store.find_by_url("https://second.example.net")["name"] == "Second renamed" and main._mates_tool.api_key == "newkey")

	# --- a full list --------------------------------------------------------------------------------------------------------------------
	for i in ServerStore.MAX_SERVERS:
		main.server_store.add({"url": "https://fill%d.example.net" % i, "api_key": "k"})
	var in_use: String = main.backend_url
	await open_scan()
	scanner.feed(code("One too many", "https://toomany.example.net", "k"))
	await frames(2)
	card("CardConnect").pressed.emit()
	await frames(3)
	check("a full list is reported, nothing switches", "full" in card("CardResult").text and main.backend_url == in_use and main.server_store.find_by_url("https://toomany.example.net").is_empty())

	main.queue_free()
	await frames(2)
	for path in [SERVERS, "user://settings_flow_test.cfg", "user://recent_flow_test.cfg"]:
		DirAccess.remove_absolute(path)
	print("SMOKE PASSED")
	quit()
