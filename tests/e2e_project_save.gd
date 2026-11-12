extends SceneTree
## Talks to a real backend - LOCAL ONLY. V-9 (one file per Part, in place) end to end through main.tscn: a root file referencing a plate and a peg is opened; an edit is
## made on the backend (the peg's occurrence renamed, a NEW Part added); main.save_project() writes ONLY the changed files (the root, which records the new
## occurrence, and the new Part's own file), leaves the plate and the peg files alone; the files written by VR reopen in the backend with every reference
## resolved (native_compose and POST /import/native). Writes under user://e2e_project_save/.
## Run: DIDSA_NO_LANDING=1 DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_project_save.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend.

const BackendSession := preload("res://scripts/backend_session.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const DIR := "user://e2e_project_save"

var main
var url := ""
var key := ""


func _api(method: int, path: String, body: String = "") -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request(url + "/document" + path, BackendSession.headers(key, body != ""), method, body)
	var result: Array = await req.request_completed
	req.queue_free()
	var text := (result[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(result[1]), "json": JSON.parse_string(text) if text != "" else null, "text": text}


func _wait_for(cond: Callable, timeout_ms: int = 60000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func _write(name: String, text: String) -> String:
	var path := DIR.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	secrets.save("user://e2e_project_save_secrets.cfg")
	DirAccess.make_dir_recursive_absolute(DIR)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	var plate_text := FileAccess.get_file_as_string("res://tests/fixtures/Assy_Test_Plate.didsa")
	var peg_text := FileAccess.get_file_as_string("res://tests/fixtures/Assy_test_peg_2.DIDSAprt")
	var plate_path := _write("Plate.didsa", plate_text)
	var peg_path := _write("Peg.didsa", peg_text)
	var root_id := "e2e-save-root"
	var occ := func(id: String, ref: String, z: float) -> Dictionary:
		return {"id": id, "external_ref": ref, "resolved_part_id": null, "name_override": null, "transform": {"translation": [0, 0, z], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}, "suppressed": false, "hidden": false, "fixed": false, "color": null}
	var root_path := _write("Root.didsa", NativeCompose.to_json({"schema_version": 1, "document": {"id": "d", "root_part_id": root_id, "parts": [{"id": root_id, "name": "Save root", "features": [], "occurrences": [occ.call("occ-plate", "Plate.didsa", 0), occ.call("occ-peg", "Peg.didsa", 60)], "mates": []}]}, "sketches": []}))
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "user://e2e_project_save_secrets.cfg"
	main.native_file_path = root_path
	root.add_child(main)
	await process_frame
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"))
	check("the root loads with its two files (%s)" % main.status_text, main.status_text.begins_with("Loaded "))
	# the first save upgrades the fixtures (written by an older app: the backend's export adds defaults) and keeps their own client-only keys
	var first: Dictionary = await main.save_project()
	check("the first Save rewrites the older-format part files once, keeping their own client-only keys", first["ok"] and FileAccess.get_file_as_string(plate_path).contains("hidden_feature_ids"))
	var plate_mtime := FileAccess.get_modified_time(plate_path)
	var peg_mtime := FileAccess.get_modified_time(peg_path)
	var plate_before := FileAccess.get_file_as_string(plate_path)
	var peg_before := FileAccess.get_file_as_string(peg_path)
	var again: Dictionary = await main.save_project()
	check("with nothing edited a second Save writes nothing (every file is unchanged)", again["ok"] and (again["result"]["saved"] as Array).is_empty())
	# edit: rename the peg's placement, and add a NEW Part to the root
	var renamed: Dictionary = await _api(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/occ-peg" % root_id, "{\"name_override\": \"Pin A\"}")
	var made: Dictionary = await _api(HTTPClient.METHOD_POST, "/parts", "{\"name\": \"Spacer\"}")
	var spacer_id := str((made["json"] as Dictionary).get("id", "")) if made["json"] is Dictionary else ""
	var placed: Dictionary = await _api(HTTPClient.METHOD_POST, "/parts/%s/occurrences" % root_id, JSON.stringify({"id": "occ-spacer", "external_ref": null, "resolved_part_id": spacer_id, "transform": {"translation": [0, 0, 90], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}}))
	check("the backend took the edits (a rename and a new Part placed)", renamed["code"] < 300 and spacer_id != "" and placed["code"] < 300)
	var second: Dictionary = await main.save_project()
	var names: Array = (second["result"]["saved"] as Array).map(func(s): return str(s["name"]))
	names.sort()
	check("Save writes only what changed: the root (its occurrences) and the new Part's own file", second["ok"] and names == ["Save root", "Spacer"])
	check("...the plate's and the peg's files are untouched, byte for byte", FileAccess.get_file_as_string(plate_path) == plate_before and FileAccess.get_file_as_string(peg_path) == peg_before and FileAccess.get_modified_time(plate_path) == plate_mtime and FileAccess.get_modified_time(peg_path) == peg_mtime)
	var spacer_path := DIR.path_join("Spacer.didsa")
	check("the new Part got a file beside the root, named after it", FileAccess.file_exists(spacer_path))
	var root_text := FileAccess.get_file_as_string(root_path)
	check("the root records the new file, relative to its folder, and the rename", root_text.contains("\"external_ref\":\"Spacer.didsa\"") and root_text.contains("Pin A"))
	# reopen the files VR wrote in the backend: every reference resolves
	var composed := NativeCompose.compose(root_path)
	check("reopening from the root file resolves all three references", composed["ok"] and int(composed["resolved"]) == 3 and (composed["unresolved"] as Array).is_empty())
	var imported: Dictionary = await _api(HTTPClient.METHOD_POST, "/import/native", str(composed["text"]))
	var rows: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % root_id)
	var unresolved := 0
	for o in (rows["json"] as Array):
		if o.get("resolved_part_id") == null:
			unresolved += 1
	check("...and the backend has every occurrence resolved to a Part", imported["code"] < 300 and (rows["json"] as Array).size() == 3 and unresolved == 0)
	quit(0)
