extends SceneTree
## Talks to a real backend - LOCAL ONLY (never against a shared backend). The headset bug report of 17 Oct 2026, end to end through main.tscn:
##   * Multi-file assemblies (native_compose.gd): a root file whose two occurrences point at the plate and the peg under the OTHER native extension
##     (written `Plate.DIDSAprt` / `Peg.didsa`, on disk `Plate.didsa` / `Peg.DIDSAprt`) plus a missing file. First what the old client sent (the root
##     file alone) is imported straight, to show it gave no parts; then the app loads the root at startup and must show both parts, with the
##     backend's own occurrences resolved, and name the missing file.
##   * Measure: a real two-face measurement, then the whole model is turned; the drawn dimension must follow the picked faces.
##   * Paint: the right laser aimed at the peg, the trigger's paint shot PATCHes the peg's occurrence colour and colours it locally; undo puts it back.
##   * Open with unsaved changes: the Open waits on a choice; Cancel keeps the document, Discard and open really re-opens.
##   * Add of a multi-file sub-assembly file (it references the peg): the sub-assembly's own occurrence is resolved on the backend.
##   * New room: an empty "Sub-assembly N" Part placed on the root, a room opened on the real (mesh-less) glb, Bring to me, a file added into it.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_bug_report.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend. Writes its files under user://e2e_bug_report/.

const BackendSession := preload("res://scripts/backend_session.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const DIR := "user://e2e_bug_report"

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
	return {"code": int(result[1]), "json": JSON.parse_string(text) if text != "" else null, "bytes": result[3]}


func _wait_for(cond: Callable, timeout_ms: int = 30000) -> bool:
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


func _occ(id: String, ref: String, translation: Array) -> Dictionary:
	return {"id": id, "external_ref": ref, "resolved_part_id": null, "name_override": null,
		"transform": {"translation": translation, "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0},
		"suppressed": false, "hidden": false, "fixed": false, "color": null}


func _root_file(root_id: String, name: String, occurrences: Array) -> String:
	var part := {"id": root_id, "name": name, "features": [], "occurrences": occurrences, "mates": []}
	return NativeCompose.to_json({"schema_version": 1, "document": {"id": "doc-" + root_id, "root_part_id": root_id, "parts": [part]}, "sketches": []})


func _occurrence_parts() -> Array:
	return get_nodes_in_group("grabbable_parts").filter(func(n): return n.is_inside_tree() and str(n.get_meta("occurrence_id", "")) != "" and not str(n.get_meta("owner_part_id", "")).is_empty())


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	var secrets_path := "user://e2e_bug_report_secrets.cfg"
	secrets.save(secrets_path)

	# --- the files: the plate and the peg on disk under the extensions their references DON'T use
	DirAccess.make_dir_recursive_absolute(DIR)
	for f in DirAccess.get_files_at(DIR):
		DirAccess.remove_absolute(DIR.path_join(f))
	var plate_text := FileAccess.get_file_as_string("res://tests/fixtures/Assy_Test_Plate.didsa")
	var peg_text := FileAccess.get_file_as_string("res://tests/fixtures/Assy_test_peg_2.DIDSAprt")
	var plate_id: String = JSON.parse_string(plate_text)["document"]["root_part_id"]
	var peg_id: String = JSON.parse_string(peg_text)["document"]["root_part_id"]
	_write("Plate.didsa", plate_text)
	var peg_path := _write("Peg.DIDSAprt", peg_text)
	var root_id := "e2e-bug-root"
	var root_path := _write("Root.didsa", _root_file(root_id, "Bug report root", [
		_occ("occ-plate", "Plate.DIDSAprt", [0, 0, 0]),
		_occ("occ-peg", "Peg.didsa", [0, 0, 60]),
		_occ("occ-missing", "Missing.didsa", [0, 0, 0]),
	]))

	await process_frame # (an HTTPRequest needs the tree running)
	# --- before: what the old client sent (the root file's own text) gives the backend nothing to show
	var raw: Dictionary = await _api(HTTPClient.METHOD_POST, "/import/native", FileAccess.get_file_as_string(root_path))
	var raw_occ: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % root_id)
	var unresolved_before := 0
	if raw_occ["json"] is Array:
		for o in raw_occ["json"]:
			if o.get("resolved_part_id") == null:
				unresolved_before += 1
	print("SMOKE before the fix: the root file alone imports, but none of its three occurrences resolves to a Part: ", raw["code"] >= 200 and raw["code"] < 300 and unresolved_before == 3, " (import %d, unresolved %d)" % [raw["code"], unresolved_before])

	# --- the app opens the root file at startup
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = root_path
	root.add_child(main)
	await process_frame
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 90000)
	print("SMOKE the multi-file root loads: ", main.status_text.begins_with("Loaded "), " (", main.status_text, ")")
	print("SMOKE ...and the status names the one missing file: ", main.status_text.contains("1 referenced file not loaded: Missing.didsa (not found)"))
	var occ_rows: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % root_id)
	var resolved := {}
	for o in occ_rows["json"]:
		resolved[o["id"]] = o.get("resolved_part_id")
	print("SMOKE the backend's occurrences are resolved to the plate and the peg (found under the other extension): ", resolved.get("occ-plate") == plate_id and resolved.get("occ-peg") == peg_id and resolved.get("occ-missing") == null)
	var shown := _occurrence_parts()
	var shown_occs := {}
	for n in shown:
		shown_occs[str(n.get_meta("occurrence_id"))] = true
	print("SMOKE the world shows the plate and the peg as placed parts: ", shown_occs.has("occ-plate") and shown_occs.has("occ-peg"), " (%d part meshes)" % shown.size())
	var plate_node: Node3D = null
	var peg_node: Node3D = null
	for n in shown:
		if str(n.get_meta("occurrence_id")) == "occ-plate" and plate_node == null:
			plate_node = n
		if str(n.get_meta("occurrence_id")) == "occ-peg" and peg_node == null:
			peg_node = n
	if plate_node == null or peg_node == null:
		print("SMOKE FAILED: the parts are not there to test the rest")
		quit(1)
		return

	# --- Measure: a real two-face measurement, then the whole model is turned
	var mt = main._measure_tool
	main._tablet.manager.activate("measure")
	var plate_hit: Vector3 = plate_node.global_transform * plate_node.get_aabb().get_center()
	var peg_hit: Vector3 = peg_node.global_transform * peg_node.get_aabb().get_center()
	mt.try_pick(plate_node, 0, {}, plate_hit)
	mt.try_pick(peg_node, 0, {}, peg_hit)
	await _wait_for(func() -> bool: return not mt.is_busy() and not mt.result.is_empty(), 30000)
	var dims = main._measure_dimensions
	await process_frame
	print("SMOKE a real two-face measurement draws a dimension in the world: ", mt.result.get("distance") != null and dims.items().size() == 1, " (distance %s mm)" % str(mt.result.get("distance")))
	var a_before: Vector3 = dims.items()[0]["a"] if not dims.items().is_empty() else Vector3.ZERO
	var model: Node3D = main.assembly_root
	model.rotate_y(deg_to_rad(40.0))
	model.global_position += Vector3(0.2, 0.0, -0.1)
	for i in 3:
		await process_frame
	var expected: Vector3 = mt.picked_points()[0]
	print("SMOKE turning and moving the model carries the dimension with it: ", not dims.items().is_empty() and (dims.items()[0]["a"] as Vector3).is_equal_approx(expected) and not (dims.items()[0]["a"] as Vector3).is_equal_approx(a_before))
	main._tablet.manager.deactivate()

	# --- Paint (the Appearance tool): aim the right laser at the peg and click - the BODY under the laser is painted, as an override in the
	# root (never in the peg's own file), on release
	var r: XRController3D = main.get_node("XROrigin3D/RightController")
	main._tablet.manager.activate("paint")
	main._tablet.pages.set_paint_colour("#3498db")
	var target: Vector3 = peg_node.global_transform * peg_node.get_aabb().get_center()
	var from := target + Vector3(0.0, 0.25, 0.45)
	r.global_transform = Transform3D(Basis.looking_at(target - from, Vector3.UP), from)
	await physics_frame
	await physics_frame
	await r._arm_paint()
	await r._finish_paint() # (a click: up well inside the 0.45 s hold)
	var listed: Array = (await _api(HTTPClient.METHOD_GET, "/parts/%s/appearance-overrides" % root_id))["json"]["overrides"]
	var peg_body := listed.filter(func(o) -> bool: return o["path"] == "occ-peg" and o.get("body_id") != null and o.get("face") == null)
	var painted_local: bool = peg_node.material_override is StandardMaterial3D and (peg_node.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color.html("#3498DB")) \
		or (peg_node.has_meta("room_clip_prior") and peg_node.get_meta("room_clip_prior") is StandardMaterial3D)
	print("SMOKE a paint click on the peg saves a body override in the root and colours it here: ", peg_body.size() == 1 and str(peg_body[0]["appearance"].get("colour")) == "#3498DB" and painted_local, " (overrides %s; status: %s)" % [str(listed), main.status_text])
	var peg_part_id := ""
	for o in (await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % root_id))["json"]:
		if o["id"] == "occ-peg":
			peg_part_id = str(o.get("resolved_part_id", ""))
	var peg_file: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s" % peg_part_id)
	print("SMOKE ...and leaves the peg's own file alone (no part / body appearance): ", int(peg_file["code"]) == 200 and (peg_file["json"] as Dictionary).get("appearance") == null and (peg_file["json"] as Dictionary).get("body_appearances", {}).is_empty())
	main.command_stack.undo()
	await _wait_for(func() -> bool: return not main._appearance_tool.is_busy(), 10000)
	await create_timer(0.5).timeout
	listed = (await _api(HTTPClient.METHOD_GET, "/parts/%s/appearance-overrides" % root_id))["json"]["overrides"]
	print("SMOKE undo takes the paint off again on the backend: ", listed.is_empty(), " (overrides %s)" % str(listed))
	main._tablet.manager.deactivate()

	# --- Open with unsaved changes
	print("SMOKE the paint left the document with unsaved changes: ", main.document_dirty)
	main.open_native_file(root_path)
	await process_frame
	print("SMOKE an Open with unsaved changes waits on the choice: ", main.pending_discard() == "Open Root.didsa")
	main.cancel_discard()
	print("SMOKE Cancel leaves the document as it was: ", main.document_dirty and main.pending_discard() == "")
	main.open_native_file(root_path)
	await process_frame
	await main.discard_and_continue()
	await _wait_for(func() -> bool: return main.status_text.begins_with("Opened ") or main.status_text.contains("failed"), 60000)
	print("SMOKE Discard and open re-opens the file through the backend, clean: ", main.status_text.begins_with("Opened Root.didsa") and not main.document_dirty and _occurrence_parts().size() == shown.size(), " (", main.status_text, ")")

	# --- Add a multi-file sub-assembly file (it references the peg, under the other extension again)
	var sub_id := "e2e-bug-sub"
	var sub_path := _write("SubAssy.didsa", _root_file(sub_id, "Sub with peg", [_occ("occ-sub-peg", "Peg.didsa", [30, 0, 0])]))
	await main.add_component_file(sub_path)
	await _wait_for(func() -> bool: return not main._load_busy and (main.status_text.contains("dded") or main.status_text.contains("failed") or main.status_text.contains("Couldn't")), 60000)
	var sub_rows: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % sub_id)
	var sub_ok: bool = sub_rows["json"] is Array and (sub_rows["json"] as Array).size() == 1 and sub_rows["json"][0].get("resolved_part_id") == peg_id
	print("SMOKE Add of a sub-assembly file brings the file it references: its occurrence is resolved to the peg on the backend: ", sub_ok, " (status: %s)" % main.status_text)
	var root_rows: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % root_id)
	print("SMOKE ...and the sub-assembly is placed on the root: ", (root_rows["json"] as Array).any(func(o): return o.get("resolved_part_id") == sub_id))

	# --- New room, Bring to me, a file added into it
	var rm = main.room_manager
	var before_count: int = (root_rows["json"] as Array).size()
	var made: bool = await rm.new_room()
	await _wait_for(func() -> bool: return not rm.rooms.is_empty(), 30000)
	root_rows = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % root_id)
	var new_row: Dictionary = (root_rows["json"] as Array).back()
	print("SMOKE New room places a new empty Part on the root, named as the next sub-assembly: ", made and (root_rows["json"] as Array).size() == before_count + 1 and str(new_row.get("name_override")) == "Sub-assembly %d" % (before_count + 1))
	var room = rm.rooms.back() if not rm.rooms.is_empty() else null
	print("SMOKE ...and a room opens on its real (mesh-less) glb: ", room != null and room.part_id == str(new_row.get("resolved_part_id")) and room.parts.is_empty(), " (status: %s)" % main.status_text)
	if room != null:
		var cam: Camera3D = main.get_viewport().get_camera_3d()
		cam.global_transform = Transform3D(Basis.looking_at(Vector3(1, 0, 0), Vector3.UP), Vector3(30, 1.6, 0))
		print("SMOKE Bring to me puts it in front of the user: ", rm.bring_to_me(room) and room.volume.xform.origin.x > 30.0 and room.volume.xform.origin.x < 40.0)
		var added: bool = await rm.add_file_to_room(room, peg_path)
		var in_room: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % room.part_id)
		print("SMOKE a file added into the new room becomes its first part, on the backend and in the room: ", added and in_room["json"] is Array and (in_room["json"] as Array).size() == 1 and in_room["json"][0].get("resolved_part_id") == peg_id and room.parts.size() > 0, " (added %s, rows %s, room parts %d, status: %s)" % [added, str(in_room["json"]).left(300), room.parts.size(), main.status_text])
		print("SMOKE the room's tile picture is not rendered headless (no error): ", (await rm.thumbnail(room)) == null)
	quit()
