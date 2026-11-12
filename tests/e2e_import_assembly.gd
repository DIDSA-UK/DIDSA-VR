extends SceneTree
## Talks to a real backend (needs the DIDSA-CAD branch with F-6) - LOCAL ONLY. F-6 through main.tscn: a STEP file holding a two-level assembly (a repeated part, a mirrored
## placement, a colour; made with the backend's own XCAF writer: tests/fixtures/assembly_two_level.step) is opened from the Files path: the choice waits ("as an assembly
## or as one part?"), "as an assembly" imports a Part per product and shows the world, the backend holds one Occurrence per placement, and a Save (V-9) writes one file
## per Part into a folder named after the file with the top's references relative to its own folder; the folder reopens with every reference resolved. "As one part" imports
## the lump as before. Writes under the project / app save folder (removed at the end).
## Run: DIDSA_NO_LANDING=1 DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_import_assembly.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend of the F-6 branch.

const BackendSession := preload("res://scripts/backend_session.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const FIXTURE := "res://tests/fixtures/assembly_two_level.step"

var main
var url := ""
var key := ""


func _api(method: int, path: String) -> Dictionary:
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request(url + "/document" + path, BackendSession.headers(key), method)
	var result: Array = await req.request_completed
	req.queue_free()
	var text := (result[3] as PackedByteArray).get_string_from_utf8()
	return {"code": int(result[1]), "json": JSON.parse_string(text) if text != "" else null}


func _wait_for(cond: Callable, timeout_ms: int = 90000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


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
	secrets.save("user://e2e_import_assembly_secrets.cfg")
	await process_frame
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "user://e2e_import_assembly_secrets.cfg"
	root.add_child(main)
	await process_frame
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed")) # (the start-up import of assembly.didsa first)
	var step_path := ProjectSettings.globalize_path(FIXTURE)
	main.load_model_file(step_path) if main.has_method("load_model_file") else main._import_external_file(step_path, "step")
	await _wait_for(func() -> bool: return not main.pending_import.is_empty())
	check("a STEP file with several parts waits on the choice and says how many parts and sub-assemblies", not main.pending_import.is_empty() and main.pending_import_text().contains("2 parts") and main.pending_import_text().contains("2 sub-assemblies"))
	await main.resolve_import_choice("assembly")
	await _wait_for(func() -> bool: return main.status_text.contains("Imported ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"))
	check("as an assembly it imports a Part per product (%s)" % main.status_text, main.status_text.begins_with("Imported 3 of 3 parts as an assembly"))
	var rows: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % main.current_root_part_id())
	var top_rows: Array = rows["json"] if rows["json"] is Array else []
	check("the backend holds one Occurrence per placement under the top (Box, Sub, Sub, the baked mirrored Box)", top_rows.size() == 4 and top_rows.all(func(o): return o.get("resolved_part_id") != null))
	check("the world shows the parts and the document is unsaved (the new Parts have no files)", main._part_count >= 1 and main.document_dirty)
	var saved: Dictionary = await main.save_project()
	var folder: String = main.save_dir().path_join("assembly_two_level")
	var names := DirAccess.get_files_at(folder)
	check("Save writes one file per Part into a folder named after the file", saved["ok"] and names.size() == 5 and names.has("Top.didsa") and names.has("Pin.didsa") and names.has("Sub.didsa"))
	var top_text := FileAccess.get_file_as_string(folder.path_join("Top.didsa"))
	check("the top's references are relative to its own folder", top_text.contains("\"external_ref\":\"Sub.didsa\"") and not top_text.contains("assembly_two_level/"))
	var composed := NativeCompose.compose(folder.path_join("Top.didsa"))
	check("the folder reopens with every reference resolved", composed["ok"] and (composed["unresolved"] as Array).is_empty() and int(composed["resolved"]) >= 4)
	for f in names:
		DirAccess.remove_absolute(folder.path_join(f))
	DirAccess.remove_absolute(folder)
	# as one part: the lump, as before
	main.document_dirty = false
	main._import_one_part_chosen = step_path
	await main._import_external_file(step_path, "step")
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed"))
	var lump: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % main.current_root_part_id())
	check("as one part it imports one Body with no occurrences, as before", main.status_text.begins_with("Loaded ") and lump["json"] is Array and (lump["json"] as Array).is_empty())
	quit(0)
