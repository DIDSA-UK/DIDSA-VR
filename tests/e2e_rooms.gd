extends SceneTree
## Talks to a real backend - LOCAL ONLY (same caveat as e2e_assembly_tree.gd: never against a shared backend). Assembly Rooms against the real thing:
## builds a document with a SUB-ASSEMBLY (the repo's assembly.didsa becomes the sub-assembly "S"; a new root part holds it), loads it through the real
## main.tscn, opens a room for S through the real mesh fetch, and checks what only a live backend can: the room really holds S's two leaves, the world's copy is
## hidden, the room's Part state was read, a part moved by hand inside the room is SAVED under S (the backend's own stored pose changes by the right number of
## millimetres, and S's placement in the world is untouched), a colour set on a room part and Fix / Float are saved on its occurrence, and closing and reopening shows
## the moved part where it was left.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_rooms.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend, and assembly.didsa in the project root.

const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const BackendSession := preload("res://scripts/backend_session.gd") ## the API key and the app's own X-Document-Session: the backend keeps one document per session

var main
var url := ""
var key := ""


func _get_json(path: String) -> Variant:
	var req := HTTPRequest.new()
	root.add_child(req)
	req.request(url + "/document" + path, BackendSession.headers(key), HTTPClient.METHOD_GET)
	var result: Array = await req.request_completed
	req.queue_free()
	return JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8()) if int(result[1]) == 200 else null


func _wait_for(cond: Callable, timeout_ms: int = 15000) -> bool:
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < timeout_ms:
		if cond.call():
			return true
		await process_frame
	return false


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg") or not FileAccess.file_exists("res://assembly.didsa"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend) and assembly.didsa in the project root")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))

	# --- the document: tests/data/make_rooms_fixture.py turns assembly.didsa's own root (two leaf parts) into a sub-assembly "S" under a new root
	var fixture_path := "res://tests/data/rooms_sub_assembly.didsa"
	var source = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	var root_id: String = source["document"]["root_part_id"]
	var sub_occurrence_id: String = ""
	var s_id: String = ""
	for p in source["document"]["parts"]:
		if p["id"] == root_id:
			sub_occurrence_id = p["occurrences"][0]["id"]
			s_id = p["occurrences"][0]["resolved_part_id"]
	var native_path := fixture_path
	var secrets_path := "user://e2e_rooms_secrets.cfg"
	secrets.save(secrets_path)

	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = native_path
	root.add_child(main)
	await process_frame
	var loaded := await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 60000)
	if not loaded or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: the test document did not load - status: ", main.status_text)
		quit(1)
		return
	print("SMOKE the test document loads with the new root: ", main.current_root_part_id() == root_id)
	var world_leaves: Array = RoomRegistry.world_parts(main.get_tree())
	print("SMOKE the world shows S's two leaves (owned by S): ", world_leaves.size() == 2 and world_leaves.all(func(n): return str(n.get_meta("owner_part_id", "")) == s_id))

	# --- open the room through the real mesh fetch
	var manager = main.room_manager
	var room = await manager.open_room(s_id, "Sub", root_id, sub_occurrence_id)
	if room == null:
		print("SMOKE FAILED: the room did not open - status: ", main.status_text)
		quit(1)
		return
	await _wait_for(func() -> bool: return room.interactive)
	print("SMOKE the room opened with S's two leaves, tagged with S as their owner: ", room.parts.size() == 2 and room.parts.all(func(p): return str(p.get_meta("owner_part_id", "")) == s_id and str(p.get_meta("occurrence_id", "")) != ""))
	print("SMOKE the world's copy of them is hidden while it is open: ", world_leaves.all(func(n): return not n.visible))
	print("SMOKE the room's Part state was read from the backend and the room is interactive: ", room.interactive and main._mates_tool.is_managed(room.parts[0]))
	print("SMOKE the room fits its content: a scale was chosen and its walls are the 3 m cube: ", room.content_scale > 0.0001 and room.volume.half.is_equal_approx(Vector3(1.5, 1.5, 1.5)))

	# --- move a part by hand inside the room: it must be SAVED under S
	var before_list = await _get_json("/parts/%s/occurrences" % s_id)
	var target: MeshInstance3D = null
	for p in room.parts:
		for occ in before_list:
			if occ["id"] == str(p.get_meta("occurrence_id")) and not bool(occ.get("fixed", false)):
				target = p
	if target == null:
		target = room.parts[0] # (every leaf grounded: the grip still moves it; the saver floats and re-grounds it)
	var occ_id := str(target.get_meta("occurrence_id"))
	var start_mm := Vector3.ZERO
	for occ in before_list:
		if occ["id"] == occ_id:
			var t: Array = occ["transform"]["translation"]
			start_mm = Vector3(t[0], t[1], t[2])
	var hand = main.get_node("XROrigin3D/RightController")
	hand.set_steadiness(0)
	hand.global_position = RoomRegistry.part_centre(target)
	hand._try_grab()
	var grabbed: bool = hand.held_node == target
	var move_m := 0.10
	hand.global_position += Vector3(move_m, 0.0, 0.0)
	await physics_frame
	await physics_frame
	hand._try_release()
	print("SMOKE the hand took the room part, and it stayed inside the room when put down: ", grabbed and room.volume.contains(RoomRegistry.part_centre(target)))
	var expected_mm: float = move_m / room.content_scale # metres in the room's frame -> the backend's millimetres
	var saved := {"mm": Vector3.ZERO}
	var changed := false
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var r = await _get_json("/parts/%s/occurrences" % s_id)
		if r != null and _stored_differs(r, occ_id, start_mm, saved):
			changed = true
			break
		await process_frame
	var delta_mm: Vector3 = (saved["mm"] as Vector3) - start_mm
	print("SMOKE the move was saved to the backend under S: its stored translation changed: ", changed)
	print("SMOKE ...by the distance the hand moved, in the backend's millimetres (", snappedf(delta_mm.x, 0.1), " mm for ", snappedf(expected_mm, 0.1), " expected): ", changed and absf(delta_mm.x - expected_mm) < maxf(0.5, expected_mm * 0.02) and absf(delta_mm.y) < 0.5)
	var root_occs = await _get_json("/parts/%s/occurrences" % root_id)
	var sub_t: Array = root_occs[0]["transform"]["translation"]
	print("SMOKE ...and S's own placement in the world is untouched (still 300 mm along x): ", root_occs.size() == 1 and absf(float(sub_t[0]) - 300.0) < 0.001 and absf(float(sub_t[1])) < 0.001)

	# --- a colour set on a room part is saved on its occurrence
	var colour_result: Dictionary = await main._colour_tool.set_color(target, "#cc3322")
	var after_colour = await _get_json("/parts/%s/occurrences" % s_id)
	var coloured := false
	for occ in after_colour:
		if occ["id"] == occ_id and str(occ.get("color", "")).to_lower() == "#cc3322":
			coloured = true
	print("SMOKE a colour set on a room part is saved on its occurrence: ", colour_result.get("ok", false) and coloured)

	# --- Fix / Float on a room part is saved on its occurrence (and read back through the room's own state)
	var was_fixed: bool = main._mates_tool.is_fixed(target)
	await main._mates_tool.toggle_fixed(target)
	var after_fix = await _get_json("/parts/%s/occurrences" % s_id)
	var fixed_now := false
	for occ in after_fix:
		if occ["id"] == occ_id:
			fixed_now = bool(occ.get("fixed", false))
	print("SMOKE grounding a room part is saved on its occurrence, and the room's state follows: ", fixed_now == (not was_fixed) and main._mates_tool.is_fixed(target) == fixed_now)
	await main._mates_tool.toggle_fixed(target) # and back

	# --- close and reopen: the moved part is where it was left
	var moved_local: Vector3 = target.transform.origin
	manager.close_room(room)
	await process_frame
	print("SMOKE closing the room brings the world's copy back and frees the box: ", world_leaves.all(func(n): return n.visible) and RoomRegistry.room_count() == 0 and manager.rooms.is_empty())
	var again = await manager.open_room(s_id, "Sub", root_id, sub_occurrence_id)
	await _wait_for(func() -> bool: return again != null and again.interactive)
	var again_part: MeshInstance3D = null
	for p in again.parts:
		if str(p.get_meta("occurrence_id")) == occ_id:
			again_part = p
	print("SMOKE reopened, the moved part is where it was left (the backend's stored pose, read back through a fresh mesh): ", again_part != null and again_part.transform.origin.distance_to(moved_local) < 0.5)
	manager.close_all()
	quit()


func _stored_differs(list: Array, occ_id: String, start_mm: Vector3, out: Dictionary) -> bool:
	for occ in list:
		if occ["id"] == occ_id:
			var t: Array = occ["transform"]["translation"]
			var now := Vector3(t[0], t[1], t[2])
			if now.distance_to(start_mm) > 0.5:
				out["mm"] = now
				return true
	return false
