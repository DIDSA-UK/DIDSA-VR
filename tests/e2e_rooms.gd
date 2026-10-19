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

	var moved_local: Vector3 = target.transform.origin # (read now: later reloads of the room replace its part nodes)

	# --- a colour painted on a room part (the Appearance tool's Part row) is an override in the room's Part, mirrored into its occurrence's colour
	var at: Node = main._appearance_tool
	print("SMOKE a room part is painted in the room's own Part: ", at.root_of(target, main.current_root_part_id()) == s_id, " (%s, group_root %s)" % [at.root_of(target, main.current_root_part_id()), str(target.get_meta("group_root", "-"))])
	await at.ensure_loaded(s_id)
	at.brush = {"colour": "#CC3322"}
	var part_row: Array = at.rows_for(target, 0, main.get_tree().get_nodes_in_group("grabbable_parts"), main.current_root_part_id()).filter(func(row) -> bool: return row["id"] == "part")
	var colour_result: Dictionary = await at.apply(part_row[0], s_id, main.get_tree().get_nodes_in_group("grabbable_parts"), main.current_root_part_id()) if not part_row.is_empty() else {"ok": false}
	var after_colour = await _get_json("/parts/%s/occurrences" % s_id)
	var coloured := false
	for occ in after_colour:
		if occ["id"] == occ_id and str(occ.get("color", "")).to_lower() == "#cc3322":
			coloured = true
	print("SMOKE a colour painted on a room part is saved in the room (its occurrence's colour mirrors it): ", colour_result.get("ok", false) and coloured)

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

	# --- drop-to-add against the real backend: a copy of one leaf, let go inside the room, is a new occurrence in S, in S's mesh and (shared definition) the world's
	var leaf_defs := {}
	for occ in after_fix:
		leaf_defs[occ["id"]] = occ["resolved_part_id"]
	var source_node: MeshInstance3D = room.parts[0]
	var source_definition: String = leaf_defs[str(source_node.get_meta("occurrence_id"))]
	var members_before: int = room.parts.size()
	var dropped := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), room.global_position + Vector3(0.4, -0.3, 0.2))
	var added: bool = await manager.add_to_room(room, source_node, dropped)
	var s_after_add = await _get_json("/parts/%s/occurrences" % s_id)
	var new_occ := {}
	for occ in s_after_add:
		if not leaf_defs.has(occ["id"]):
			new_occ = occ
	print("SMOKE letting a copy go inside the room adds a new occurrence of the same Part to S in the backend: ", added and not new_occ.is_empty() and new_occ["resolved_part_id"] == source_definition and s_after_add.size() == leaf_defs.size() + 1)
	var wanted: Dictionary = preload("res://scripts/room/room_edit.gd").pose_in_room(dropped, room.content_root)
	var got_t: Array = new_occ["transform"]["translation"]
	var want_t: Array = wanted["translation"]
	print("SMOKE ...at the pose it was let go at, in millimetres (", snappedf(got_t[0], 0.1), ", ", snappedf(got_t[1], 0.1), ", ", snappedf(got_t[2], 0.1), "): ", absf(got_t[0] - want_t[0]) < 0.01 and absf(got_t[1] - want_t[1]) < 0.01 and absf(got_t[2] - want_t[2]) < 0.01)
	print("SMOKE ...and the room now shows it (one part more, read back from the backend's own mesh): ", room.parts.size() == members_before + 1 and room.members_changed)
	var cycle_result: Dictionary = await manager.edit_api().add_copy(s_id, _fake_node("", ""), dropped, room.content_root, "")
	var self_node := _fake_node(root_id, sub_occurrence_id) # the node that shows S itself (S's placement under the root)
	var into_itself: Dictionary = await manager.edit_api().add_copy(s_id, self_node, dropped, room.content_root, "")
	var s_still = await _get_json("/parts/%s/occurrences" % s_id)
	print("SMOKE adding S to S is refused (the real server would accept it): ", not into_itself["ok"] and into_itself["error"].contains("can't hold itself") and s_still.size() == leaf_defs.size() + 1)
	print("SMOKE ...and an occurrence with no source Part is refused too: ", not cycle_result["ok"])

	# --- undo the add, redo it, then delete the added part (and undo that), all against the real backend
	main.command_stack.undo()
	await _wait_for(func() -> bool: return room.parts.size() == members_before and not manager._busy_edit)
	var s_undone = await _get_json("/parts/%s/occurrences" % s_id)
	print("SMOKE undo of the add removes it from the backend and from the room: ", s_undone.size() == leaf_defs.size() and room.parts.size() == members_before)
	main.command_stack.redo()
	await _wait_for(func() -> bool: return room.parts.size() == members_before + 1 and not manager._busy_edit)
	var s_redone = await _get_json("/parts/%s/occurrences" % s_id)
	print("SMOKE redo puts the same occurrence back (same id): ", s_redone.size() == leaf_defs.size() + 1 and s_redone.any(func(o): return o["id"] == new_occ["id"]))
	var deleted: Dictionary = await manager.delete_occurrence(s_id, str(new_occ["id"]), "Copy")
	var s_deleted = await _get_json("/parts/%s/occurrences" % s_id)
	print("SMOKE deleting the added part removes it from the backend and the room: ", deleted["ok"] and s_deleted.size() == leaf_defs.size() and room.parts.size() == members_before)
	main.command_stack.undo()
	await _wait_for(func() -> bool: return room.parts.size() == members_before + 1 and not manager._busy_edit)
	var s_restored = await _get_json("/parts/%s/occurrences" % s_id)
	var restored_row := {}
	for o in s_restored:
		if o["id"] == new_occ["id"]:
			restored_row = o
	print("SMOKE undoing the delete puts it back with everything it had (id, Part, pose): ", not restored_row.is_empty() and restored_row["resolved_part_id"] == source_definition and absf(restored_row["transform"]["translation"][0] - want_t[0]) < 0.01)
	main.command_stack.undo() # the add again: leaves S as it was found
	await _wait_for(func() -> bool: return not manager._busy_edit)
	await _wait_for(func() -> bool: return room.parts.size() == members_before)

	# --- close and reopen: the moved part is where it was left
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


func _fake_node(owner: String, occurrence: String) -> MeshInstance3D:
	## A bare node carrying only the backend identity a placed part has (owner Part, occurrence): what room_edit.gd reads to find which Part it shows.
	var n := MeshInstance3D.new()
	n.set_meta("owner_part_id", owner)
	n.set_meta("occurrence_id", occurrence)
	root.add_child(n)
	return n


func _stored_differs(list: Array, occ_id: String, start_mm: Vector3, out: Dictionary) -> bool:
	for occ in list:
		if occ["id"] == occ_id:
			var t: Array = occ["transform"]["translation"]
			var now := Vector3(t[0], t[1], t[2])
			if now.distance_to(start_mm) > 0.5:
				out["mm"] = now
				return true
	return false
