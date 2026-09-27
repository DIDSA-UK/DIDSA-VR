extends SceneTree
## Needs a real running backend, same exception as e2e_backend.gd/
## e2e_step_import.gd. Drives the real add-component flow this session
## built to close the "no in-VR way to open a different native file, or to
## add parts to the currently-loaded assembly" gap DIDSA-VR's docs/status.md
## ("Real-headset testing round 2") flagged as blocking Mates testing: no
## amount of client-side picking logic matters if there's nothing but a
## single, occurrence-less test file loaded.
##
## Creates two bare (geometry-free — this test only cares about the
## Occurrence graph, not rendering) Parts directly against the backend,
## writes each one's own real `export/native` payload to user://models,
## then drives main.gd's new open_native_file() (full-replace open of an
## arbitrary native file at runtime) and add_component_file() (merges a
## second file's Part in as a new Occurrence, backend/app/document/
## add_component.py) through the real HTTP round trip, and confirms via a
## fresh GET /document/parts/{root}/occurrences that the Occurrence
## genuinely persisted server-side - not just an optimistic local update.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_add_component.gd

var main
var _http: HTTPRequest


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return

	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://secrets.cfg" # the one test allowed to, same as e2e_backend.gd
	main.native_file_path = "res://__nonexistent__.didsa" # skip the startup native-import flow; this test drives its own two files
	root.add_child(main)
	await process_frame

	if main.backend_url.is_empty() or main.api_key.is_empty():
		print("SMOKE FAILED: secrets.cfg present but backend_url/api_key empty after load")
		quit()
		return

	_http = HTTPRequest.new()
	root.add_child(_http)

	DirAccess.make_dir_recursive_absolute("user://models")
	var root_part_id: String = await _make_fixture_file("Root", "user://models/e2e_root.didsa")
	var component_part_id: String = await _make_fixture_file("Component", "user://models/e2e_component.didsa")
	if root_part_id.is_empty() or component_part_id.is_empty():
		print("SMOKE FAILED: couldn't create the two fixture Parts")
		quit(1)
		return

	main.open_native_file("user://models/e2e_root.didsa")
	await _wait_for_status(func(s): return s.begins_with("Opened ") or s.contains("failed") or s.contains("Couldn't"))
	print("SMOKE open status: ", main.status_text)
	print("SMOKE current_root_part_id matches the opened file: ", main.current_root_part_id() == root_part_id)

	main.add_component_file("user://models/e2e_component.didsa")
	await _wait_for_status(func(s): return s.begins_with("Added ") or s.contains("failed") or s.contains("Couldn't"))
	print("SMOKE add-component status: ", main.status_text)

	var occurrences = await _request(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % root_part_id, "")
	var ok: bool = occurrences is Array and occurrences.size() == 1 and occurrences[0].get("resolved_part_id") == component_part_id and occurrences[0].get("fixed") == true and main.status_text.begins_with("Added ")
	print("SMOKE occurrence persisted server-side, resolved to the component, and is fixed (first Occurrence): ", ok)

	if ok:
		print("SMOKE PASSED: open a different native file at runtime, then add a component to it, both round-tripped for real")
	else:
		print("SMOKE FAILED: add-component did not produce the expected server-side Occurrence")
	quit()


func _make_fixture_file(name: String, path: String) -> String:
	var create_result = await _request(HTTPClient.METHOD_POST, "/document/parts", JSON.stringify({"name": name}))
	if not (create_result is Dictionary) or not create_result.has("id"):
		return ""
	var part_id: String = create_result["id"]
	var exported = await _request(HTTPClient.METHOD_GET, "/document/export/native?part_id=%s" % part_id, "")
	if not (exported is Dictionary):
		return ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(exported))
	f.close()
	return part_id


func _request(method: HTTPClient.Method, path: String, body: String) -> Variant:
	var headers := ["X-API-Key: %s" % main.api_key, "Content-Type: application/json"]
	_http.request(main.backend_url + path, headers, method, body)
	var result: Array = await _http.request_completed
	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]
	if response_code < 200 or response_code >= 300:
		push_error("e2e_add_component: %s %s failed: HTTP %d body=%s" % [method, path, response_code, response_body.get_string_from_utf8()])
		return null
	return JSON.parse_string(response_body.get_string_from_utf8())


func _wait_for_status(is_done: Callable, timeout_ms: int = 60000) -> void:
	var started_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_ms < timeout_ms:
		await process_frame
		if is_done.call(main.status_text):
			return
