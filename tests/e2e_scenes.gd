extends SceneTree
## Talks to a real backend - LOCAL ONLY (never against a shared backend). Scenes in VR end to end through main.tscn (DIDSA-CAD
## docs/scenes-scope.md S2), on one bundle file: a root placing a Frame sub-assembly (no geometry of its own; two pegs, barA / barB)
## and a third peg (bolt).
##   * the glb's sub-assembly comes in as a plain node named by its instance_path (mesh_identity.gd tags it), in glb order;
##   * a scene made on the backend (the frame lifted and turned, barB hidden, the bolt blue) shows as it says: poses composed down
##     the tree, barB hidden, the bolt blue; and captures back to itself (nothing unsaved);
##   * a move is unsaved; Update PATCHes it (the bolt's move and its paint in one override) and the backend keeps it;
##   * Back to default puts everything back; Save as new from the plain sandbox writes a group move of both bars as one override on
##     the frame, which the backend resolves (nothing unresolved); delete removes both.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_scenes.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running DIDSA-CAD backend with scenes. Writes under user://e2e_scenes/.

const BackendSession := preload("res://scripts/backend_session.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")
const DIR := "user://e2e_scenes"
const BLUE := "#3498DB"
const ROOT_ID := "e2e-scenes-root"
const FRAME_ID := "e2e-scenes-frame"

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


func _occ(id: String, ref: String, part_id: String, translation: Array) -> Dictionary:
	return {"id": id, "external_ref": ref, "resolved_part_id": part_id, "name_override": null,
		"transform": {"translation": translation, "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0},
		"suppressed": false, "hidden": false, "fixed": false, "color": null}


func _override(scene: Dictionary, path: String) -> Dictionary:
	for o in scene.get("overrides", []):
		if str(o["path"]) == path and o.get("body_id") == null and o.get("face") == null:
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
	var secrets_path := "user://e2e_scenes_secrets.cfg"
	secrets.save(secrets_path)

	DirAccess.make_dir_recursive_absolute(DIR)
	var peg_doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/Assy_test_peg_2.DIDSAprt"))
	var peg: Dictionary = peg_doc["document"]["parts"][0]
	var peg_id: String = peg["id"]
	var frame := {"id": FRAME_ID, "name": "Frame", "features": [], "mates": [],
		"occurrences": [_occ("barA", "Peg.didsa", peg_id, [0, 0, 0]), _occ("barB", "Peg.didsa", peg_id, [80, 0, 0])]}
	var rig := {"id": ROOT_ID, "name": "Rig", "features": [], "mates": [],
		"occurrences": [_occ("frame", "Frame.didsa", FRAME_ID, [0, 0, 0]), _occ("bolt", "Peg.didsa", peg_id, [0, 0, 90])]}
	var bundle := {"schema_version": peg_doc["schema_version"], "document": {"id": "doc-e2e-scenes", "root_part_id": ROOT_ID, "parts": [rig, frame, peg]}, "sketches": peg_doc["sketches"]}
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
	_check(main.status_text.begins_with("Loaded "), "the bundle loads (%s)" % main.status_text)
	var scenes = main.scenes_tool
	main._mates_tool.return_glide_s = 0.0
	var nodes: Dictionary = scenes.nodes_of(ROOT_ID)
	_check(nodes.has("frame") and not (nodes["frame"] is MeshInstance3D) and nodes.has("frame/barA") and nodes.has("frame/barB") and nodes.has("bolt"),
		"the frame (no geometry) is a plain node named by its instance_path; the pegs are meshes (%s)" % str(nodes.keys()))
	if not (nodes.has("frame/barA") and nodes.has("frame/barB") and nodes.has("bolt")):
		print("SMOKE FAILED: the parts are not there to test the rest")
		quit(1)
		return
	var bar_a: Node3D = nodes["frame/barA"]
	var bar_b: Node3D = nodes["frame/barB"]
	var bolt: MeshInstance3D = nodes["bolt"]
	_check(bar_b.position.is_equal_approx(Vector3(80, 0, 0)) and bolt.position.is_equal_approx(Vector3(0, 0, 90)), "the glb's nodes sit at their poses in the root's frame, mm")
	var home := {}
	for p in nodes:
		home[p] = (nodes[p] as Node3D).transform

	# --- a scene made on the backend shows as it says
	var made: Dictionary = await _api(HTTPClient.METHOD_POST, "/parts/%s/scenes" % ROOT_ID, JSON.stringify({"name": "Lifted", "overrides": [
		{"path": "frame", "transform": {"translation": [0, 0, 100], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 90}},
		{"path": "frame/barB", "hidden": true},
		{"path": "bolt", "appearance": {"colour": BLUE}},
	]}))
	_check(made["code"] == 201, "the backend makes the scene (201)")
	var lifted_id := str((made["json"] as Dictionary).get("id", "")) if made["json"] is Dictionary else ""
	await scenes.refresh()
	_check(scenes.scenes_of().any(func(s) -> bool: return str(s["id"]) == lifted_id), "the Scenes tool lists it")
	var shown: String = await scenes.show_scene(lifted_id)
	_check(shown == "shown" and main._mates_tool.relaxed, "Show relaxes the mates and shows it")
	_check(bar_a.position.distance_to(Vector3(0, 0, 100)) < 0.01 and bar_b.position.distance_to(Vector3(0, 80, 100)) < 0.01,
		"the frame's move carries both bars (turned 90 deg: barB at (0, 80, 100)) (%s, %s)" % [bar_a.position, bar_b.position])
	_check(not bar_b.visible and bar_a.visible, "barB is hidden, barA isn't")
	var bolt_look := bolt.material_override as BaseMaterial3D
	_check(bolt_look != null and bolt_look.albedo_color.is_equal_approx(Color.html(BLUE)), "the bolt is blue (the scene's look, the top layer)")
	_check(not scenes.scene_unsaved(), "what shows captures back to the scene: nothing unsaved")

	# --- a move is unsaved; Update keeps it
	bolt.position += Vector3(30, 0, 0)
	_check(scenes.scene_unsaved(), "moving the bolt makes the scene unsaved")
	var updated: Dictionary = await scenes.update_scene()
	var got: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/scenes/%s" % [ROOT_ID, lifted_id])
	var bolt_o := _override(got["json"], "bolt") if got["json"] is Dictionary else {}
	_check(updated["ok"] and bolt_o.get("transform") is Dictionary and absf(float(bolt_o["transform"]["translation"][0]) - 30.0) < 0.01 and absf(float(bolt_o["transform"]["translation"][2]) - 90.0) < 0.01
		and bolt_o.get("appearance") is Dictionary and str(bolt_o["appearance"].get("colour", "")).to_upper() == BLUE, "Update PATCHes it: the bolt's move and its paint in one override, kept by the backend")
	_check(_override(got["json"], "frame/barB").get("hidden") == true and (got["json"]["overrides"] as Array).size() == 3, "...the frame's move and barB's hidden kept (3 overrides)")
	_check(not scenes.scene_unsaved(), "after Update nothing is unsaved")

	# --- Back to default
	var back: String = await scenes.back_to_default()
	var all_home := true
	for p in nodes:
		if not (nodes[p] as Node3D).transform.is_equal_approx(home[p]):
			all_home = false
	_check(back == "returned" and all_home and bar_b.visible and not main._mates_tool.relaxed and scenes.shown_id() == "", "Back to default: every node home, barB shown, no scene")

	# --- Save as new from the plain sandbox: a group move of both bars is one override on the frame
	main._mates_tool.set_relaxed(true)
	bar_a.position += Vector3(0, 50, 0)
	bar_b.position += Vector3(0, 50, 0)
	var saved: Dictionary = await scenes.save_as_new("Bars up", false)
	var new_id := str(saved.get("scene", {}).get("id", ""))
	got = await _api(HTTPClient.METHOD_GET, "/parts/%s/scenes/%s" % [ROOT_ID, new_id])
	var frame_o := _override(got["json"], "frame") if got["json"] is Dictionary else {}
	_check(saved["ok"] and (got["json"]["overrides"] as Array).size() == 1 and frame_o.get("transform") is Dictionary and absf(float(frame_o["transform"]["translation"][1]) - 50.0) < 0.01,
		"Save as new: both bars moved alike is one override on the frame (50 mm)")
	_check((got["json"].get("unresolved", []) as Array).is_empty(), "the backend resolves every override (nothing unresolved)")
	await scenes.back_to_default("discard")

	# --- clean up
	var d1: Dictionary = await scenes.delete_scene(lifted_id)
	var d2: Dictionary = await scenes.delete_scene(new_id)
	var left: Dictionary = await _api(HTTPClient.METHOD_GET, "/parts/%s/scenes" % ROOT_ID)
	_check(d1["ok"] and d2["ok"] and (left["json"] as Array).is_empty(), "both scenes delete")

	_check(failures == 0, "no failures")
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
