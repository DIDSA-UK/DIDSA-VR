extends SceneTree
## LOCAL REAL BACKEND AND REAL HUB, in `e2e_ci_list.txt` (tests/ci_e2e.sh starts a throwaway hub from DIDSA-CAD session-hub/ when DIDSA_HUB_URL is not set). P2, the HEADSET AS PRESENTER:
## the real main.tscn hosts a session through the real WebSocketPeer to the real hub, with a real view token from the real backend, while a PYTHON observer (tests/e2e/session_observer_stub.py:
## the scripted_session.py style, started by this test) joins by the code, fetches the glb with only the token (200, then 304), is refused everything else (401), and records what the hub relays.
## The test then moves a part (a real PATCH through the controller's _sync_pose), hides it, cuts, scales the model, makes a REAL document change (the occurrence hidden in the backend, the world
## refetched: doc_changed carries the revision the backend answered), and ends: the hub forgets the room, the token is revoked (the observer's next fetch is 401).
## Run by hand: DIDSA_NO_LANDING=1 DIDSA_HUB_URL=ws://127.0.0.1:8300 DIDSA_HUB_KEY=... DIDSA_SESSION_PYTHON=/path/to/python-with-httpx-and-websockets "$GODOT" --headless --path . --script res://tests/e2e_session_presenter.gd
## (secrets.cfg pointing at a running backend; a hub: cd ../DIDSA-CAD/session-hub && SESSION_HUB_API_KEY=... python -m uvicorn app.main:app --port 8300 --workers 1).
## NOT covered: a Cloudflare tunnel (wss:// through it), a Quest, more than one observer, voice.

const DocumentRevision := preload("res://scripts/session/document_revision.gd")
const P := preload("res://scripts/session/session_protocol.gd")

var main: Node
var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _wait_for(cond: Callable, timeout_ms: int = 30000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _model_mm(node: Node3D) -> Vector3:
	return (main.session_scene_root().global_transform.affine_inverse() * node.global_transform).origin


func _initialize() -> void:
	var python := OS.get_environment("DIDSA_SESSION_PYTHON")
	var hub_url := OS.get_environment("DIDSA_HUB_URL")
	var hub_key := OS.get_environment("DIDSA_HUB_KEY")
	if not FileAccess.file_exists("res://secrets.cfg") or hub_url == "" or hub_key == "" or python == "":
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend), DIDSA_HUB_URL, DIDSA_HUB_KEY and DIDSA_SESSION_PYTHON (a running hub and a python with httpx and websockets)")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await _wait_for(func() -> bool: return main._part_count > 0 and not main._load_busy, 90000)
	_check(main._part_count > 0 and main.current_root_part_id() != "" and main.has_backend(), "the start-up import loaded a real document from the real backend")
	main.hub_url = hub_url
	main.hub_key = hub_key
	main.session.allow_loopback = true
	var hosted: Dictionary = await main.session.host_session()
	_check(hosted["ok"] and main.session.is_presenter(), "Host Session through the real WebSocketPeer to the real hub (%s)" % str(hosted["error"]))
	if not hosted["ok"]:
		quit()
		return
	var code: String = main.session.code()
	_check(P.code_is_valid(code), "the real hub gave a well-formed code (%s)" % code)
	var result_path := ProjectSettings.globalize_path("user://e2e_session_presenter_result.json")
	DirAccess.remove_absolute(result_path)
	var stub := ProjectSettings.globalize_path("res://tests/e2e/session_observer_stub.py")
	var pid := OS.create_process(python, [stub, "--hub", hub_url, "--code", code, "--out", result_path, "--seconds", "90"])
	_check(pid > 0, "the Python observer was started")
	await _wait_for(func() -> bool: return main.session.client.participants.size() >= 2, 40000)
	var roster: Array = main.session.client.others()
	_check(roster.size() == 1 and str(roster[0]["name"]) == "Python observer" and str(roster[0]["role"]) == "observer", "the observer joined by the code and is on the presenter's roster")
	await _wait(2.5) # (it fetches the glb, checks what a token may not do)
	# the parts to play with: a placed instance (it has an instance path)
	var world: Array = main.session_world_parts()
	var moving: Node3D = null
	for node in world:
		if str(node.get_meta("instance_path", "")) != "" and str(node.get_meta("occurrence_id", "")) != "":
			moving = node
			break
	_check(moving != null, "the document has a placed instance to move (%d parts)" % world.size())
	var key := str(moving.get_meta("instance_path"))
	var occurrence := str(moving.get_meta("occurrence_id"))
	var before := _model_mm(moving)
	var puts_before: int = main._mates_tool.stat_requests
	moving.global_position += Vector3(0.02, 0.0, 0.0) # 20 mm at the model's scale of 0.001
	main.session_hands()[1]._sync_pose(moving) # the controller's own call at the end of a grab: a real PATCH to the backend, and the part is read at the fast rate
	await _wait(2.0)
	_check(main._mates_tool.stat_requests > puts_before, "the move was saved to the real backend (the pose PATCH went out)")
	var after_move := _model_mm(moving)
	moving.visible = false
	await _wait(1.5)
	var plane_origin: Vector3 = main.session_scene_root().global_transform * Vector3(before.x + 5.0, before.y, before.z)
	main._section_tool.set_remote_plane(true, plane_origin, Vector3(1, 0, 0), main.get_node("XROrigin3D/XRCamera3D"))
	await _wait(1.5)
	main._section_tool.set_active(false)
	var place_before: Transform3D = main.assembly_root.transform
	main.assembly_root.transform = Transform3D(place_before.basis.scaled(Vector3.ONE * 2.0), place_before.origin)
	await _wait(1.5)
	moving.visible = true
	# a REAL document change: the occurrence hidden in the backend, the world refetched (the glb loses that part)
	var edit: Dictionary = await main.design_table.api.request(HTTPClient.METHOD_PATCH, "/document/parts/%s/occurrences/%s" % [main.current_root_part_id(), occurrence], {"hidden": true})
	_check(edit["ok"], "the real backend accepted the edit (the occurrence hidden)")
	var revision_after_edit: int = DocumentRevision.latest
	var reloaded: bool = await main.reload_world_model()
	_check(reloaded and main.session_world_parts().size() == world.size() - 1, "the world was refetched without that part (%d parts)" % main.session_world_parts().size())
	var revision_seen_by_reload: int = DocumentRevision.latest
	_check(revision_seen_by_reload > 0 and revision_seen_by_reload >= revision_after_edit, "the presenter learned the revision from the responses it already got (%d)" % revision_seen_by_reload)
	await _wait(2.5)
	# End
	await main.session.end_session()
	await _wait_for(func() -> bool: return not OS.is_process_running(pid) or FileAccess.file_exists(result_path), 30000)
	await _wait(1.0)
	_check(not main.session.is_active() and main.session.role == "", "End: the app is no longer hosting")
	var health := HTTPRequest.new()
	root.add_child(health)
	health.request(hub_url.replace("ws://", "http://").replace("wss://", "https://") + "/health", ["X-API-Key: " + hub_key])
	var answer: Array = await health.request_completed
	var hub_stats = JSON.parse_string((answer[3] as PackedByteArray).get_string_from_utf8())
	_check(int(answer[1]) == 200 and hub_stats is Dictionary and int((hub_stats as Dictionary).get("rooms", -1)) == 0, "the real hub has forgotten the room")
	# what the Python observer saw
	_check(FileAccess.file_exists(result_path), "the observer wrote what it saw")
	var seen = JSON.parse_string(FileAccess.get_file_as_string(result_path)) if FileAccess.file_exists(result_path) else {}
	if not (seen is Dictionary) or (seen as Dictionary).is_empty():
		quit()
		return
	_check(seen["joined"] == true and seen["errors"].is_empty() or seen["errors"].all(func(e: String) -> bool: return e.contains("ConnectionClosed")), "the observer joined and had no errors beyond the hub closing the socket at the end (%s)" % str(seen["errors"]))
	_check(str(seen["snapshot"]["model"]["root_part_id"]) == main.current_root_part_id() and seen["snapshot"]["model"]["kind"] == "backend", "the snapshot names the document")
	_check(seen["snapshot_pose_paths"].size() == world.size() and seen["snapshot_pose_paths"].has(key), "the first pose table has every part (%d) under its instance path" % seen["snapshot_pose_paths"].size())
	var first_xf: Array = seen["snapshot_poses"][key]
	_check(absf(float(first_xf[9]) - before.x) < 0.05 and absf(float(first_xf[11]) - before.z) < 0.05, "...in model-space millimetres: the part's origin is (%.2f, %.2f, %.2f) and the observer was told (%.2f, %.2f)" % [before.x, before.y, before.z, float(first_xf[9]), float(first_xf[11])])
	_check(seen["glb_first"]["status"] == 200 and seen["glb_first"]["magic"] == "glTF" and seen["glb_first"]["etag"] != "" and seen["glb_first"]["paths"].has(key), "the observer fetched the real glb with only the token (200, %d bytes, an ETag)" % int(seen["glb_first"]["bytes"]))
	_check(seen["glb_again_status"] == 304, "...and a refetch with If-None-Match was a real 304")
	var refused_all := true
	for route in seen["forbidden"]:
		refused_all = refused_all and int(seen["forbidden"][route]) == 401
	_check(refused_all and seen["forbidden"].size() == 4, "the token is refused every other route: the part, export/native, occurrences, a PATCH (401 each)")
	_check(seen["view_state"]["status"] == 200 and int(seen["view_state"]["rev"]) == int(seen["view_state"]["header_rev"]), "view-state answers the observer with a revision equal to the header's")
	var kinds := {}
	for message in seen["messages"]:
		kinds[message["t"]] = int(kinds.get(message["t"], 0)) + 1
	_check(kinds.has("poses") and kinds.has("visibility") and kinds.has("section") and kinds.has("place") and kinds.has("doc_changed") and kinds.get("end", 0) == 1, "the observer was relayed poses, visibility, section, place, doc_changed and the end (%s)" % str(kinds))
	var moved_message: Dictionary = {}
	for message in seen["messages"]:
		if message["t"] == "poses" and not message.get("full", false) and message["item_paths"] == [key]:
			moved_message = message
	_check(not moved_message.is_empty() and absf(float(moved_message["items"][0]["xf"][9]) - after_move.x) < 0.1, "a moved part arrived as a partial table of just that part, at its new place (%.2f mm)" % (float(moved_message["items"][0]["xf"][9]) if not moved_message.is_empty() else -1.0))
	var hides: Array = seen["messages"].filter(func(m: Dictionary) -> bool: return m["t"] == "visibility" and m["hidden"].has(key))
	_check(not hides.is_empty(), "hiding the part reached the observer")
	var cuts: Array = seen["messages"].filter(func(m: Dictionary) -> bool: return m["t"] == "section" and m["on"] == true)
	_check(cuts.size() == 1 and absf(float(cuts[0]["point"][0]) - (before.x + 5.0)) < 0.1 and absf(float(cuts[0]["normal"][0]) - 1.0) < 1e-3, "the cut arrived in model space (5 mm past the part, facing +x)")
	var places: Array = seen["messages"].filter(func(m: Dictionary) -> bool: return m["t"] == "place")
	_check(not places.is_empty() and absf(float(places[-1]["xf"][0]) - 0.002) < 1e-6, "the model's new scale arrived (0.002)")
	var changes: Array = seen["messages"].filter(func(m: Dictionary) -> bool: return m["t"] == "doc_changed")
	_check(changes.size() == 1 and changes[0].get("all", false) == true and int(changes[0]["rev"]) == revision_seen_by_reload, "ONE doc_changed (all) with the revision the backend answered the presenter (%d)" % revision_seen_by_reload)
	_check(seen["refetches"].size() == 1 and seen["refetches"][0]["status"] == 200 and seen["refetches"][0]["differs"] and not seen["refetches"][0]["paths"].has(key), "the observer's refetch got the changed glb (without the hidden occurrence)")
	_check(seen.get("end_reason", "") == "ended" and int(seen.get("after_end_glb_status", 0)) == 401, "End: the observer was told, and the revoked token reads nothing (401)")
	print("SMOKE e2e_session_presenter failures: ", failures)
	quit()
