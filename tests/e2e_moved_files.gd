extends SceneTree
## Live backend: finding moved files (DIDSA-CAD docs/moved-files-scope.md, F2) through main.gd. An assembly whose part file moved to a
## subfolder opens with the part found by its id, its corrected path in the backend's session (and its `ref_part_id`), the unsaved
## flag up and the move listed for Files > References; Save as new file writes the corrected path. With a second copy of the part
## present nothing is loaded and the two are listed; picking one (choose_reference) opens the assembly again with it.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_moved_files.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running DIDSA-CAD backend with `ref_part_id` (F1). Writes under
## user://e2e_moved_files/.

const NativeCompose := preload("res://scripts/native_compose.gd")
const BackendSession := preload("res://scripts/backend_session.gd")
const DIR := "user://e2e_moved_files"
const ROOT_ID := "e2e-moved-root"

var main
var url := ""
var key := ""
var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _api(method: int, path: String, body: String = "") -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request(url + "/document" + path, BackendSession.headers(key, body != ""), method, body)
	var result: Array = await req.request_completed
	req.queue_free()
	var text := (result[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(result[1]), "json": JSON.parse_string(text) if text != "" else null}


func _wait_for(cond: Callable, timeout_ms: int = 30000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func _store(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _remove_tree(folder: String) -> void:
	var d := DirAccess.open(folder)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_tree(folder.path_join(sub))
	for file in d.get_files():
		d.remove(file)
	DirAccess.remove_absolute(folder)


func _peg_occurrence() -> Dictionary:
	var got: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % ROOT_ID)
	if got["json"] is Array:
		for o in got["json"]:
			if o["id"] == "peg":
				return o
	return {}


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	var secrets_path := "user://e2e_moved_files_secrets.cfg"
	secrets.save(secrets_path)

	_remove_tree(DIR)
	var peg_text := FileAccess.get_file_as_string("res://tests/fixtures/Assy_test_peg_2.DIDSAprt")
	var peg_id: String = JSON.parse_string(peg_text)["document"]["parts"][0]["id"]
	_store(DIR.path_join("parts/moved/Peg.didsa"), peg_text) # the part file was moved after the assembly was saved
	var root_part := {"id": ROOT_ID, "name": "Moved", "features": [], "mates": [], "occurrences": [
		{"id": "peg", "external_ref": "Peg.didsa", "resolved_part_id": null, "ref_part_id": peg_id, "name_override": null,
			"transform": {"translation": [0, 0, 0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0}, "suppressed": false, "hidden": false, "fixed": true, "color": null}]}
	var schema: int = int(JSON.parse_string(peg_text)["schema_version"])
	var root_path := DIR.path_join("Moved.didsa")
	_store(root_path, NativeCompose.to_json({"schema_version": schema, "document": {"id": "doc-e2e-moved", "root_part_id": ROOT_ID, "parts": [root_part]}, "sketches": []}))

	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = root_path
	root.add_child(main)
	await process_frame
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 90000)
	_check(main.status_text.begins_with("Loaded 1 part mesh") and main.status_text.contains("1 moved file found in its new place: Peg.didsa -> parts/moved/Peg.didsa"),
		"the assembly opens with the moved part found by its id (%s)" % main.status_text)
	var review: Dictionary = main.reference_review()
	_check(review["root"] == root_path and review["relinked"].size() == 1 and review["relinked"][0]["via"] == "id" and review["review"].is_empty(), "Files > References lists the move")
	_check(main.document_dirty, "the corrected path is an unsaved change")
	var peg: Dictionary = await _peg_occurrence()
	_check(peg.get("external_ref") == "parts/moved/Peg.didsa" and peg.get("resolved_part_id") == peg_id and peg.get("ref_part_id") == peg_id,
		"the backend's session has the corrected path, resolved, with its ref_part_id (%s)" % str(peg))

	var saved_path := DIR.path_join("saved/Moved saved.didsa")
	DirAccess.make_dir_recursive_absolute(saved_path.get_base_dir())
	var saved: String = await main.save_native_snapshot(saved_path)
	var saved_doc = JSON.parse_string(FileAccess.get_file_as_string(saved_path)) if saved != "" else null
	var saved_occ := {}
	if saved_doc is Dictionary:
		for p in saved_doc["document"]["parts"]:
			if p["id"] == ROOT_ID:
				saved_occ = p["occurrences"][0]
	_check(saved_occ.get("external_ref") == "parts/moved/Peg.didsa" and saved_occ.get("ref_part_id") == peg_id and not main.document_dirty,
		"Save as new file writes the corrected path and the id, and clears the flag")

	# A second copy of the part: nothing is loaded until the user picks one.
	_store(DIR.path_join("parts/copy/Peg.didsa"), peg_text)
	await main.open_native_file(root_path)
	review = main.reference_review()
	var item: Dictionary = review["review"][0] if not review["review"].is_empty() else {}
	_check(item.get("result") == "ask" and item["candidates"].map(func(c): return c["path"]) == ["parts/copy/Peg.didsa", "parts/moved/Peg.didsa"] and review["relinked"].is_empty(),
		"with two copies the reference is listed with both (%s)" % main.status_text)
	peg = await _peg_occurrence()
	_check(peg.get("resolved_part_id") == null and peg.get("ref_part_id") == peg_id and main.status_text.contains("moved; 2 copies found"),
		"...and not loaded, its id kept")
	_check(not main.document_dirty, "nothing was changed, so nothing is unsaved")

	main.choose_reference(str(item.get("key", "")), DIR.path_join("parts/copy/Peg.didsa"))
	await _wait_for(func() -> bool: return main.status_text.begins_with("Opened ") and main.reference_review()["review"].is_empty(), 60000)
	review = main.reference_review()
	_check(main.status_text.begins_with("Opened Moved.didsa: 1 part mesh") and review["relinked"].size() == 1 and review["relinked"][0]["via"] == "choice",
		"picking a copy opens the assembly again with it (%s)" % main.status_text)
	peg = await _peg_occurrence()
	_check(peg.get("external_ref") == "parts/copy/Peg.didsa" and peg.get("resolved_part_id") == peg_id, "the backend has the picked file's path")
	_check(main.document_dirty, "the picked path is an unsaved change too")
	main.choose_reference(str(item.get("key", "")), DIR.path_join("parts/moved/Peg.didsa"))
	await _wait_for(func() -> bool: return main.status_text.contains("-> parts/moved/Peg.didsa") or main.pending_discard() != "", 60000)
	_check(main.pending_discard() == "" and main.status_text.contains("-> parts/moved/Peg.didsa"),
		"picking again when the only unsaved change is a corrected path re-opens without asking (%s)" % main.status_text)
	main.leave_reference_missing("nothing")
	_check(main.reference_review()["review"].is_empty(), "leaving a reference missing only hides it")

	main.queue_free()
	await process_frame
	_remove_tree(DIR)
	print("SMOKE no failures: ", failures == 0)
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
