extends RefCounted
## The servers this headset knows: user://servers.cfg, a list of {id, name, url, api_key, document_session, relay_url, relay_api_key, store_url, store_key, hub_url, hub_key} and which one
## is current. `user://` is writable on the Quest and survives reinstalling over the top. res://secrets.cfg stays a developer override: main.gd reads it
## first and lists it as "From secrets.cfg"; it is never written here. docs/landing-scope.md, "Where servers are kept".
##
## The file is plain text with the API key in it, in the app's private storage. To pre-load a headset without typing, write this file (see
## docs/servers.md, "Pre-loading a headset").

const PATH := "user://servers.cfg"
const PATH_ENV := "DIDSA_SERVERS_PATH" ## set to read and write a different file (tests/run_all.sh does, so a test run never touches the real one)
const MAX_SERVERS := 12
const FIELDS: Array[String] = ["name", "url", "api_key", "document_session", "relay_url", "relay_api_key", "store_url", "store_key", "hub_url", "hub_key"] ## store_*: the project store (DIDSA-CAD project-store/, S3): its address and its own key, not the backend's. hub_*: the session hub (session-hub/, P2): ws:// or wss://, and its own key

var servers: Array[Dictionary] = []
var current_id := ""


static func path() -> String:
	var override := OS.get_environment(PATH_ENV)
	return override if override != "" else PATH


func load_from_disk() -> void:
	servers.clear()
	current_id = ""
	var config := ConfigFile.new()
	if config.load(path()) != OK:
		return
	current_id = str(config.get_value("servers", "current", ""))
	for section in config.get_sections():
		if not section.begins_with("server."):
			continue
		var entry := {"id": section.trim_prefix("server.")}
		for field in FIELDS:
			entry[field] = str(config.get_value(section, field, ""))
		if str(entry["url"]) != "" and str(entry["api_key"]) != "" and servers.size() < MAX_SERVERS:
			entry["url"] = normalise_url(str(entry["url"]))
			entry["store_url"] = normalise_url(str(entry["store_url"]))
			servers.append(entry)
	if find(current_id).is_empty():
		current_id = ""


func save_to_disk() -> bool:
	var config := ConfigFile.new()
	config.set_value("servers", "current", current_id)
	for entry in servers:
		var section := "server." + str(entry["id"])
		for field in FIELDS:
			config.set_value(section, field, str(entry.get(field, "")))
	var err := config.save(path())
	if err != OK:
		push_warning("DIDSA VR: couldn't save %s (error %d)" % [path(), err])
	return err == OK


func find(id: String) -> Dictionary:
	for entry in servers:
		if entry["id"] == id:
			return entry
	return {}


func find_by_url(url: String) -> Dictionary:
	var wanted := normalise_url(url)
	for entry in servers:
		if entry["url"] == wanted:
			return entry
	return {}


func current() -> Dictionary:
	return find(current_id)


func add(fields: Dictionary, make_current: bool = false) -> Dictionary:
	## Adds a server, or updates the one with the same address (so scanning the same code twice does not list it twice). Returns the stored entry,
	## or {} when the url or key is empty or the list is full. Saves.
	var url := normalise_url(str(fields.get("url", "")))
	var key := str(fields.get("api_key", "")).strip_edges()
	if url == "" or key == "":
		return {}
	var entry := find_by_url(url)
	if entry.is_empty():
		if servers.size() >= MAX_SERVERS:
			return {}
		entry = {"id": _new_id()}
		servers.append(entry)
	for field in FIELDS:
		if fields.has(field) or not entry.has(field):
			entry[field] = str(fields.get(field, "")).strip_edges()
	entry["url"] = url
	entry["store_url"] = normalise_url(str(entry.get("store_url", "")))
	if str(entry["name"]) == "":
		entry["name"] = url.get_slice("://", 1).get_slice("/", 0)
	if make_current or current_id == "":
		current_id = str(entry["id"])
	save_to_disk()
	return entry


func set_relay(id: String, relay_url: String, relay_api_key: String) -> Dictionary:
	## Sets (or, with "", clears) a saved server's Browser relay. Returns the updated entry, or {} if there is no such server. Saves.
	var entry := find(id)
	if entry.is_empty():
		return {}
	entry["relay_url"] = relay_url.strip_edges()
	entry["relay_api_key"] = relay_api_key.strip_edges()
	save_to_disk()
	return entry


func set_store(id: String, store_url: String, store_key: String) -> Dictionary:
	## Sets (or, with "", clears) a saved server's project store. Returns the updated entry, or {} if there is no such server. Saves.
	var entry := find(id)
	if entry.is_empty():
		return {}
	entry["store_url"] = normalise_url(store_url)
	entry["store_key"] = store_key.strip_edges()
	save_to_disk()
	return entry


func set_hub(id: String, hub_url: String, hub_key: String) -> Dictionary:
	## Sets (or, with "", clears) a saved server's session hub. Returns the updated entry, or {} if there is no such server. Saves.
	var entry := find(id)
	if entry.is_empty():
		return {}
	entry["hub_url"] = normalise_url(hub_url)
	entry["hub_key"] = hub_key.strip_edges()
	save_to_disk()
	return entry


func remove(id: String) -> bool:
	## Forget a server. If it was current, nothing is (the app falls back to offline).
	for i in servers.size():
		if servers[i]["id"] == id:
			servers.remove_at(i)
			if current_id == id:
				current_id = ""
			save_to_disk()
			return true
	return false


func set_current(id: String) -> bool:
	if id != "" and find(id).is_empty():
		return false
	current_id = id
	save_to_disk()
	return true


static func normalise_url(url: String) -> String:
	var out := url.strip_edges()
	while out.ends_with("/"):
		out = out.substr(0, out.length() - 1)
	return out


func _new_id() -> String:
	var crypto := Crypto.new()
	var id := crypto.generate_random_bytes(4).hex_encode()
	return _new_id() if not find(id).is_empty() else id
