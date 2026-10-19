extends SceneTree
## Talks to a real backend - LOCAL ONLY (never against a shared backend). The Appearance tool end to end through main.tscn (DIDSA-CAD
## docs/appearance-tool-scope.md V2), on one bundle file: a root placing a Frame sub-assembly (two pegs, barA / barB) and a third peg (bolt).
##   * a CLICK with the tool on paints the body under the laser: one override in the ROOT (path frame/barA, that body), none in the peg's file;
##   * a HOLD opens the breadcrumb; letting go on the Frame row paints the frame (path "frame"), and bar B shows it at once;
##   * a reload shows the same looks from the backend's glb materials (nothing painted by the client then);
##   * mates relaxed: a paint is temporary (nothing sent) and goes back on Return parts;
##   * undo takes the paints off the backend again.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_appearance.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running DIDSA-CAD backend with the Appearance tool. Writes under user://e2e_appearance/.

const BackendSession := preload("res://scripts/backend_session.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const Breadcrumb := preload("res://scripts/group_breadcrumb.gd")
const DIR := "user://e2e_appearance"
const RED := "#E63946"
const BLUE := "#3498DB"
const ROOT_ID := "e2e-appearance-root"
const FRAME_ID := "e2e-appearance-frame"

var main
var url := ""
var key := ""
var r: XRController3D


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


func _occ(id: String, ref: String, part_id: String, translation: Array) -> Dictionary:
	return {"id": id, "external_ref": ref, "resolved_part_id": part_id, "name_override": null,
		"transform": {"translation": translation, "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0},
		"suppressed": false, "hidden": false, "fixed": false, "color": null}


func _node(path: String) -> MeshInstance3D:
	for n in get_nodes_in_group("grabbable_parts"):
		if n.is_inside_tree() and str(n.get_meta("instance_path", "?")) == path:
			return n
	return null


func _overrides() -> Array:
	var got: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/appearance-overrides" % ROOT_ID)
	return got["json"]["overrides"] if got["json"] is Dictionary else []


func _aim_at_node(n: Node3D) -> void:
	var target: Vector3 = n.global_transform * n.get_aabb().get_center()
	var from := target + Vector3(0.0, 0.25, 0.45)
	r.global_transform = Transform3D(Basis.looking_at(target - from, Vector3.UP), from)


func _row_point(crumb, row: int) -> Vector3:
	var y := Breadcrumb.MARGIN_M + Breadcrumb.ROW_H * (row + 1) + Breadcrumb.ROW_H * 0.5
	return crumb.global_transform * Vector3(Breadcrumb.WIDTH * 0.5, -y, 0.0)


func _shows(n: MeshInstance3D, hex: String) -> bool:
	## The part's look has this colour somewhere: its override, or one of its surfaces (a glb split by appearance).
	var want := Color.html(hex)
	var o := n.material_override as BaseMaterial3D
	if o != null:
		return o.albedo_color.is_equal_approx(want)
	for s in n.mesh.get_surface_count():
		var m := n.mesh.surface_get_material(s) as BaseMaterial3D
		if m != null and Color(m.albedo_color.r, m.albedo_color.g, m.albedo_color.b).is_equal_approx(want):
			return true
	return false


func _frames(count: int) -> void:
	for i in count:
		await physics_frame


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend)")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	var secrets_path := "user://e2e_appearance_secrets.cfg"
	secrets.save(secrets_path)

	# --- one bundle file: the root, the Frame (two pegs) and the peg itself
	DirAccess.make_dir_recursive_absolute(DIR)
	var peg_doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/Assy_test_peg_2.DIDSAprt"))
	var peg: Dictionary = peg_doc["document"]["parts"][0]
	var peg_id: String = peg["id"]
	var frame := {"id": FRAME_ID, "name": "Frame", "features": [], "mates": [],
		"occurrences": [_occ("barA", "Peg.didsa", peg_id, [0, 0, 0]), _occ("barB", "Peg.didsa", peg_id, [80, 0, 0])]}
	var rig := {"id": ROOT_ID, "name": "Rig", "features": [], "mates": [],
		"occurrences": [_occ("frame", "Frame.didsa", FRAME_ID, [0, 0, 0]), _occ("bolt", "Peg.didsa", peg_id, [0, 0, 90])]}
	var bundle := {"schema_version": peg_doc["schema_version"], "document": {"id": "doc-e2e-appearance", "root_part_id": ROOT_ID, "parts": [rig, frame, peg]}, "sketches": peg_doc["sketches"]}
	var path := DIR.path_join("Rig.didsa")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(NativeCompose.to_json(bundle))
	f.close()

	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = path
	root.add_child(main)
	await process_frame
	await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 90000)
	print("SMOKE the bundle loads: ", main.status_text.begins_with("Loaded "), " (", main.status_text, ")")
	await _wait_for(func() -> bool: return _node("frame/barA") != null and _node("frame/barA").has_meta("group_path"), 20000)
	var bar_a := _node("frame/barA")
	var bar_b := _node("frame/barB")
	var bolt := _node("bolt")
	print("SMOKE every placed peg is named by the glb's instance_path: ", bar_a != null and bar_b != null and bolt != null)
	if bar_a == null or bar_b == null or bolt == null:
		print("SMOKE FAILED: the parts are not there to test the rest")
		quit(1)
		return
	r = main.get_node("XROrigin3D/RightController")
	main._tablet.manager.activate("paint")
	main._tablet.pages.set_paint_colour(RED)

	# --- a click paints the body under the laser, in the root
	_aim_at_node(bar_a)
	await _frames(2)
	r._on_button_pressed("trigger_click")
	await _frames(1)
	r._select_down = false
	await r._finish_paint()
	var listed: Array = await _overrides()
	var body_ok: bool = listed.size() == 1 and listed[0]["path"] == "frame/barA" and listed[0].get("body_id") != null and listed[0].get("face") == null and listed[0]["appearance"] == {"colour": RED}
	print("SMOKE a click paints bar A's body: one body override in the root: ", body_ok, " (%s; %s)" % [str(listed), main.status_text])
	var peg_part: Dictionary = (await _api(HTTPClient.METHOD_GET, "/parts/%s" % peg_id))["json"]
	print("SMOKE ...and the peg's own file is untouched: ", peg_part.get("appearance") == null and (peg_part.get("body_appearances", {}) as Dictionary).is_empty())
	print("SMOKE ...bar A shows it at once, bar B doesn't: ", _shows(bar_a, RED) and not _shows(bar_b, RED))

	# --- a hold opens the breadcrumb; letting go on the Frame row paints the frame
	main._tablet.pages.set_paint_colour(BLUE)
	_aim_at_node(bar_b)
	await _frames(2)
	r._on_button_pressed("trigger_click")
	r._paint_press["ms"] = int(r._paint_press["ms"]) - 600 # stands in for holding the trigger 0.45 s
	await _frames(1)
	var crumb = r._paint_crumb
	var frame_row := -1
	if crumb != null:
		for i in crumb.labels.size():
			if str(crumb.labels[i]).begins_with("Frame"):
				frame_row = i
	print("SMOKE holding opens the paint breadcrumb with a Frame row: ", crumb != null and frame_row >= 0, " (%s)" % (str(crumb.labels) if crumb != null else "no panel"))
	if crumb != null and frame_row >= 0:
		r.global_transform = Transform3D(Basis.looking_at(_row_point(crumb, frame_row) - r.global_position, Vector3.UP), r.global_position)
		await _frames(2)
	print("SMOKE ...pointing at it previews the frame blue on bar B before anything is sent: ", _shows(bar_b, BLUE) and (await _overrides()).size() == 1)
	r._select_down = false
	await r._finish_paint()
	listed = await _overrides()
	print("SMOKE letting go on the Frame row stores the frame's paint: ", listed.any(func(o) -> bool: return o["path"] == "frame" and o.get("body_id") == null and o["appearance"] == {"colour": BLUE}), " (%s)" % str(listed))

	# --- a reload: the looks now come from the backend's glb materials
	await main.reload_world_model(false)
	await _wait_for(func() -> bool: return _node("frame/barB") != null, 20000)
	bar_a = _node("frame/barA")
	bar_b = _node("frame/barB")
	bolt = _node("bolt")
	print("SMOKE after a reload the glb itself paints bar B blue (no client override): ", bar_b.material_override == null and _shows(bar_b, BLUE))
	print("SMOKE ...bar A keeps its own red body (the peg is one body: the whole bar) inside the blue frame: ", bar_a.material_override == null and _shows(bar_a, RED) and not _shows(bar_a, BLUE))
	print("SMOKE ...and the bolt outside the frame is unpainted: ", not _shows(bolt, BLUE) and not _shows(bolt, RED))

	# --- mates relaxed: painting is temporary
	await _wait_for(func() -> bool: return bolt.has_meta("group_path"), 20000)
	main._mates_tool.set_relaxed(true)
	main._tablet.pages.set_paint_colour("#2ECC71")
	_aim_at_node(bolt)
	await _frames(2)
	r._on_button_pressed("trigger_click")
	await _frames(1)
	r._select_down = false
	await r._finish_paint()
	var during: Array = await _overrides()
	print("SMOKE relaxed: a paint shows on screen but nothing is sent: ", _shows(bolt, "#2ECC71") and during.size() == listed.size(), " (%d overrides)" % during.size())
	await main._mates_tool.set_relaxed(false)
	await _frames(2)
	print("SMOKE ...Return parts takes the temporary paint off again: ", not _shows(bolt, "#2ECC71"))

	# --- undo takes the real paints off the backend (the reload cleared the history, so the overrides are cleared through the tool)
	main._appearance_tool.brush = {}
	var rows: Array = main._appearance_tool.rows_for(bar_b, 0, get_nodes_in_group("grabbable_parts"), ROOT_ID)
	await main._appearance_tool.apply(rows.filter(func(row) -> bool: return str(row["label"]).begins_with("Frame"))[0], ROOT_ID, get_nodes_in_group("grabbable_parts"), ROOT_ID)
	print("SMOKE painting Clear on the Frame row removes its paint (one override left): ", (await _overrides()).size() == 1)
	main.command_stack.undo()
	await _wait_for(func() -> bool: return not main._appearance_tool.is_busy(), 10000)
	await create_timer(0.5).timeout
	print("SMOKE undo puts the frame's paint back: ", (await _overrides()).any(func(o) -> bool: return o["path"] == "frame"))
	main._tablet.manager.deactivate()
	print("SMOKE done")
	quit()
