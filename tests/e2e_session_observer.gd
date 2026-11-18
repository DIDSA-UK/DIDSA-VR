extends SceneTree
## LOCAL REAL BACKEND AND REAL HUB, in `e2e_ci_list.txt` (tests/ci_e2e.sh starts a throwaway hub from DIDSA-CAD session-hub/ when DIDSA_HUB_URL is not set). P2, the HEADSET AS OBSERVER:
## a PYTHON presenter (tests/e2e/session_presenter_stub.py, started by this test) builds a small assembly in the real backend, mints a real view token and hosts on the real hub. The real
## main.tscn, with NO server of its own, joins by the code through the real WebSocketPeer and shows the model fetched from the real backend with the token only. The Python presenter then plays a
## script the test steps through (files, no timing): the place, section, hidden parts and status of the snapshot, a part moving, a part hidden, a REAL document change (a refetch of the changed glb),
## a doc_changed for a revision with nothing new (a real 304), the presenter dropping its socket and resuming, then P4's marks (the headset shares what its drone cursor picked, pings, asks the presenter
## to look and raises a hand, all through the real hub: the Python presenter reports what it was relayed; it sends its own share and ping and then clears marks, which the headset draws and drops),
## and End (the token revoked).
## Run by hand: as e2e_session_presenter.gd, and DIDSA_NO_LANDING=1; secrets.cfg is read only for the backend's address and key, which the PYTHON side uses.
## NOT covered: a Cloudflare tunnel, a Quest, more than one observer, voice.

const P := preload("res://scripts/session/session_protocol.gd")
const Nav := preload("res://scripts/session/session_navigation.gd")
const Avatars := preload("res://scripts/session/session_avatars.gd")

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


func _state(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _step(out: String, n: int) -> void:
	var f := FileAccess.open("%s.step%d" % [out, n], FileAccess.WRITE)
	f.store_string("go")
	f.close()


func _part(path: String) -> Node3D:
	for node in main.session_world_parts():
		if str(node.get_meta("instance_path", "?")) == path:
			return node
	return null


func _mm(node: Node3D) -> Vector3:
	return (main.session_scene_root().global_transform.affine_inverse() * node.global_transform).origin


func _initialize() -> void:
	var python := OS.get_environment("DIDSA_SESSION_PYTHON")
	var hub_url := OS.get_environment("DIDSA_HUB_URL")
	var hub_key := OS.get_environment("DIDSA_HUB_KEY")
	var secrets := ConfigFile.new()
	if secrets.load("res://secrets.cfg") != OK or hub_url == "" or hub_key == "" or python == "":
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend), DIDSA_HUB_URL, DIDSA_HUB_KEY and DIDSA_SESSION_PYTHON (a running hub and a python with httpx and websockets)")
		quit()
		return
	var cad_url := str(secrets.get_value("backend", "url", ""))
	var cad_key := str(secrets.get_value("backend", "api_key", ""))
	# the app under test has NO server: an observer needs none (it is given the address and a token)
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.allow_loopback = true
	_check(not main.has_backend() and main.api_key == "" and main.backend_url == "", "the headset app has no server of its own")
	var out := ProjectSettings.globalize_path("user://e2e_session_observer_state.json")
	for suffix in ["", ".step1", ".step2", ".step3", ".step4", ".step5", ".step6", ".step7", ".step8"]:
		DirAccess.remove_absolute(out + suffix)
	var stub := ProjectSettings.globalize_path("res://tests/e2e/session_presenter_stub.py")
	var pid := OS.create_process(python, [stub, "--cad", cad_url, "--cad-key", cad_key, "--hub", hub_url, "--hub-key", hub_key, "--out", out])
	_check(pid > 0, "the Python presenter was started")
	await _wait_for(func() -> bool: return _state(out).get("code", "") != "", 120000)
	var state := _state(out)
	_check(P.code_is_valid(str(state.get("code", ""))), "it built an assembly in the real backend, minted a token and hosted: code %s" % str(state.get("code", "")))
	if str(state.get("code", "")) == "":
		quit()
		return
	var paths: Array = state["paths"]
	var bolt: String = state["bolt_path"]
	# --- a wrong code on the real hub: the hub's own words arrive (the hub waits a moment before it closes, so Godot's WebSocketPeer does not lose the message)
	var wrong: Dictionary = await main.session.join_session(hub_url, "ZZZZZZ")
	_check(not wrong["ok"] and str(wrong["error"]).contains("No session has that code") and main.session.client.last_code == "bad_code", "a wrong code on the real hub: 'No session has that code' (%s)" % str(wrong["error"]))
	# --- join
	var joined: Dictionary = await main.session.join_session(hub_url, str(state["code"]))
	_check(joined["ok"] and main.is_observer(), "Join through the real WebSocketPeer to the real hub (%s)" % str(joined["error"]))
	await _wait_for(func() -> bool: return main.session_world_parts().size() == paths.size(), 30000)
	await _wait(1.0)
	var observer: Node = main.session.observer
	_check(main.session_world_parts().size() == paths.size() and observer.fetch_count >= 1, "the model is on show, fetched from the real backend (%d parts)" % main.session_world_parts().size())
	var first: Dictionary = observer.requests[0]
	var carried_key := false
	for header in first["headers"]:
		carried_key = carried_key or str(header).to_lower().begins_with("x-api-key") or str(header).to_lower().begins_with("x-document-session")
	_check(not carried_key and str(first["headers"][0]).begins_with("X-View-Token: ") and str(first["url"]).begins_with(cad_url), "it asked with X-View-Token only, at the backend address the hub gave it")
	_check(is_equal_approx(main.assembly_root.transform.basis.get_scale().x, 0.002) and main.assembly_root.transform.origin.is_equal_approx(Vector3(1, 1, -2)), "the presenter's place and scale were applied")
	_check(main._section_tool.active, "the presenter's section is on here")
	_check(observer.status_text == "Python presenter is at the design table: Mount", "the status line: '%s'" % observer.status_text)
	var presenter_id: int = int(main.session.client.presenter().get("id", 0))
	var drawn: bool = await _wait_for(func() -> bool: return main.session.avatars.heads.has(presenter_id), 15000)
	var expect_head: Vector3 = main.session_scene_root().global_transform * Vector3(1000.0, 1500.0, 500.0)
	_check(drawn and (main.session.avatars.heads[presenter_id] as Transform3D).origin.distance_to(expect_head) < 0.01 and (main.session.avatars.avatar_of(presenter_id)["tag"] as Label3D).text == "★ Python presenter", "the presenter is an avatar at its model-space spot, with the star")
	var bolt_node := _part(bolt)
	_check(bolt_node != null and _mm(bolt_node).distance_to(Vector3(15.0, 0.0, 10.0)) < 0.05, "the bolt is where the presenter said (15, 0, 10 mm)")
	# --- a part moves
	var samples: Array = []
	_step(out, 1)
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 3500:
		samples.append(_mm(bolt_node).x)
		await process_frame
	var distinct := {}
	for x in samples:
		distinct[snappedf(x, 0.5)] = true
	_check(absf(_mm(bolt_node).x - float(state.get("moved_to", 39.0))) < 0.1 or absf(_mm(bolt_node).x - 39.0) < 0.1, "the moved part arrived where the presenter put it (%.2f mm)" % _mm(bolt_node).x)
	var monotonic := true
	for i in range(1, samples.size()):
		monotonic = monotonic and samples[i] >= samples[i - 1] - 0.001
	_check(monotonic and distinct.size() >= 4, "...travelling there in steps, never backwards (%d distinct positions, smoothed)" % distinct.size())
	# --- hide
	_step(out, 2)
	await _wait_for(func() -> bool: return not bolt_node.visible, 15000)
	_check(not bolt_node.visible, "the hidden part is hidden")
	# --- a real change
	var parts_before: int = main.session_world_parts().size()
	var rev_before: int = observer.loaded_rev
	_step(out, 3)
	await _wait_for(func() -> bool: return main.session_world_parts().size() == parts_before - 1, 30000)
	await _wait(1.0)
	state = _state(out)
	_check(main.session_world_parts().size() == parts_before - 1 and _part(bolt) == null, "a real document change: the observer refetched the glb and the hidden occurrence is gone (%d parts)" % main.session_world_parts().size())
	_check(observer.loaded_rev == int(state["new_rev"]) and observer.loaded_rev > rev_before, "...and shows the revision the backend answered (%d)" % observer.loaded_rev)
	_check(is_equal_approx(main.assembly_root.transform.basis.get_scale().x, 0.002), "the presenter's place was kept through the refetch")
	# --- a 304
	var not_modified: int = observer.not_modified_count
	_step(out, 4)
	await _wait_for(func() -> bool: return observer.not_modified_count > not_modified, 30000)
	_check(observer.not_modified_count == not_modified + 1 and main.session_world_parts().size() == parts_before - 1, "a doc_changed with nothing new behind it: a real 304, nothing changed")
	var gathered: bool = await _wait_for(func() -> bool: return main.session.navigation.jumps >= 1, 20000)
	var gather_head := Transform3D(Basis.IDENTITY, main.session_scene_root().global_transform * Vector3(0.0, 1600.0, 0.0))
	var arc: Dictionary = Nav.gather_spot(gather_head, 0, 1)
	_check(gathered and main.session_camera().global_position.distance_to(arc["position"]) < 0.01, "Gather everyone: the observer was moved in front of the presenter, through the real hub")
	# --- the presenter drops and comes back
	var saw_drop := [false]
	main.session.client.roster_changed.connect(func() -> void: saw_drop[0] = saw_drop[0] or not main.session.client.presenter_connected())
	_step(out, 5)
	await _wait_for(func() -> bool: return saw_drop[0], 30000)
	_check(saw_drop[0] and main.is_observer(), "the presenter's socket dropped: the observer saw it and stayed")
	await _wait_for(func() -> bool: return main.session.client.presenter_connected(), 30000)
	await _wait(1.5)
	_check(main.session.client.presenter_connected() and main.session.status_line() == "Watching Python presenter", "the presenter resumed")
	_check(is_equal_approx(main.assembly_root.transform.basis.get_scale().x, 0.002) and main._section_tool.active, "...and its state (place, section) was sent again and is still applied")
	var sent_head: Array = main.session.presence.build()["head"]
	await _wait(1.3)
	# --- P4: marks through the real hub
	var marks: Node3D = main.session.marks
	var cursor: Node3D = main.session.cursor
	var me: int = int(main.session.client.me["id"])
	var target_node: Node3D = main.session_world_parts()[0]
	var centre: Vector3 = (target_node.global_transform * target_node.get_aabb()).get_center()
	cursor.aim = func() -> Dictionary: return {"origin": centre + Vector3(0.0, 0.0, 0.3), "direction": Vector3(0, 0, -1)}
	cursor.stick = func() -> Vector2: return Vector2.ZERO
	cursor.distance = 0.3
	cursor.set_enabled(true)
	var picked: bool = await _wait_for(func() -> bool: return not cursor.selection().is_empty(), 10000)
	var picked_target: Dictionary = cursor.selection().get("target", {})
	_check(picked and picked_target.has("path"), "the drone cursor picked a part of the real model (%s)" % str(picked_target))
	_check(marks.share_selection() and marks.ping() and marks.look_here() and marks.set_hand(true), "Share, Ping, Look here and Raise hand were sent")
	await _wait(1.5)
	_step(out, 7)
	await _wait_for(func() -> bool: return _state(out).has("presenter_share_path"), 30000)
	state = _state(out)
	var seen_marks: Array = state.get("marks_seen", [])
	var by_kind := {}
	for m in seen_marks:
		if int(m.get("from", 0)) == me:
			by_kind[str(m["kind"])] = m
	_check(by_kind.has("share") and by_kind.has("ping") and by_kind.has("look_here") and by_kind["share"]["target"] == picked_target and not by_kind["share"].has("seq"), "the Python presenter was relayed the headset's share (the same target), ping and look-here, none of them state (no seq)")
	_check(str(by_kind["share"]["colour"]) == str(main.session.client.me["colour"]) and float(by_kind["ping"]["ttl_s"]) == 3.0 and float(by_kind["look_here"]["ttl_s"]) == 10.0 and by_kind["ping"]["target"].has("point"), "...in the colour the real hub gave the headset, with a ping's point and the times (3 s, 10 s)")
	_check(bool(state.get("roster_hands", {}).get(str(me), {}).get("hand", false)), "the real hub's roster told the presenter the headset's hand is up")
	var presenter_mark: bool = await _wait_for(func() -> bool: return not marks.shared_by(presenter_id).is_empty() and not marks.marks_of("ping").filter(func(k: Dictionary) -> bool: return int(k["from"]) == presenter_id).is_empty(), 15000)
	marks.refresh()
	var theirs: Dictionary = marks.shared_by(presenter_id)
	_check(presenter_mark and _part(str(state["presenter_share_path"])) != null and theirs["visuals"].get("brackets") != null and theirs["name"] == "Python presenter", "the presenter's share and ping, sent through the real hub, are drawn here (brackets round the named part, their name)")
	_step(out, 8)
	await _wait_for(func() -> bool: return marks.marks.is_empty(), 15000)
	_check(marks.marks.is_empty() and main.status_text.contains("cleared the marks"), "the presenter's `marks_clear` through the real hub cleared every mark here, the headset's own included")
	# --- end
	var ended_text: Array = []
	main.session.ended_for_me.connect(func(t: String) -> void: ended_text.append(t))
	_step(out, 6)
	await _wait_for(func() -> bool: return not ended_text.is_empty(), 30000)
	_check(not ended_text.is_empty() and ended_text[0] == "The presenter ended the session." and not main.is_observer() and main.session_world_parts().is_empty(), "End: told in words, the shared model put away (%s, observer=%s, parts=%d)" % [str(ended_text), str(main.is_observer()), main.session_world_parts().size()])
	await _wait_for(func() -> bool: return _state(out).has("finished_at"), 30000)
	state = _state(out)
	var presence_seen: Array = state.get("presence_seen", [])
	_check(int(state.get("presence_count", 0)) >= 4 and not presence_seen.is_empty() and Vector3(presence_seen[-1]["head"][0], presence_seen[-1]["head"][1], presence_seen[-1]["head"][2]).distance_to(Vector3(sent_head[0], sent_head[1], sent_head[2])) < 0.5, "the presenter was sent this headset's presence (%d messages), the head where the headset computed it" % int(state.get("presence_count", 0)))
	_check(int(state.get("revoke_status", 0)) == 204 and int(state.get("after_end_glb_status", 0)) == 401, "the presenter revoked the token at the real backend (204) and it reads nothing now (401)")
	if OS.is_process_running(pid):
		OS.kill(pid)
	print("SMOKE e2e_session_observer failures: ", failures)
	quit()
