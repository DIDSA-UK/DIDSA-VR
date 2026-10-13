extends SceneTree
## Talks to a real backend - LOCAL ONLY (same caveat as e2e_assembly_tree.gd: never against a shared backend). Sub-assembly selection against the real thing: loads
## tests/data/groups_two_subs.didsa (the root places one sub-assembly TWICE, so the four leaves in the real assembly-mesh.glb carry identical tags in pairs) through
## the real main.tscn and checks what only a live backend can: the walk of the occurrence tree lines up with the real mesh order (each leaf is put in the right
## placement - checked against where it actually is), a grip + trigger click takes the whole sub-assembly it is in, moving it saves that occurrence's pose in the
## backend's own millimetres (and the other placement is untouched), and undo puts the stored pose back.
## Run: DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_groups.gd
## Needs secrets.cfg (backend url + api_key) pointing at a running backend, and assembly.didsa in the project root.

const BackendSession := preload("res://scripts/backend_session.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")

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


func _x_of(occurrences: Array, id: String) -> float:
	for occ in occurrences:
		if occ["id"] == id:
			return float(occ["transform"]["translation"][0])
	return NAN


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg") or not FileAccess.file_exists("res://assembly.didsa"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend) and assembly.didsa in the project root")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	url = str(secrets.get_value("backend", "url", ""))
	key = str(secrets.get_value("backend", "api_key", ""))
	var fixture_path := "res://tests/data/groups_two_subs.didsa"
	var source = JSON.parse_string(FileAccess.get_file_as_string(fixture_path))
	var root_id: String = source["document"]["root_part_id"]
	var occ_a := ""
	var occ_b := ""
	var s_id := ""
	for p in source["document"]["parts"]:
		if p["id"] == root_id:
			occ_a = p["occurrences"][0]["id"]
			occ_b = p["occurrences"][1]["id"]
			s_id = p["occurrences"][0]["resolved_part_id"]
	var secrets_path := "user://e2e_groups_secrets.cfg"
	secrets.save(secrets_path)
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = fixture_path
	root.add_child(main)
	await process_frame
	var loaded := await _wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 60000)
	if not loaded or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: the test document did not load - status: ", main.status_text)
		quit(1)
		return
	var leaves: Array = RoomRegistry.world_parts(main.get_tree())
	print("SMOKE the real mesh has the four leaves (two per placement): ", leaves.size() == 4)
	var indexed := await _wait_for(func() -> bool: return leaves.all(func(n): return n.has_meta("group_path")))
	print("SMOKE every leaf was placed in the occurrence tree (the walk lines up with the real glb): ", indexed)
	var in_a: Array = leaves.filter(func(n): return indexed and n.get_meta("group_path")[0] == occ_a)
	var in_b: Array = leaves.filter(func(n): return indexed and n.get_meta("group_path")[0] == occ_b)
	print("SMOKE ...two in each placement: ", in_a.size() == 2 and in_b.size() == 2)
	var mean_x := func(list: Array) -> float:
		var sum := 0.0
		for n in list:
			sum += n.global_position.x
		return sum / maxf(1.0, list.size())
	var gap_mm: float = (mean_x.call(in_b) - mean_x.call(in_a)) / main.assembly_root.scale.x
	print("SMOKE ...and each really is where its placement is: the second placement's leaves sit 600 mm further along x than the first's (", snappedf(gap_mm, 0.1), " mm): ", absf(gap_mm - 600.0) < 1.0)
	print("SMOKE a leaf's levels are the leaf, then the placement of the sub-assembly (both its leaves): ", indexed and GroupIndexLevels.sizes(in_a[0], leaves) == [1, 2])
	await _wait_for(func() -> bool: return not main._mates_tool.occurrence_state(root_id).is_empty())

	# --- grip a leaf, widen to the sub-assembly, carry it 10 cm along x
	var before = await _get_json("/parts/%s/occurrences" % root_id)
	var a0: float = _x_of(before, occ_a)
	var b0: float = _x_of(before, occ_b)
	var hand = main.get_node("XROrigin3D/RightController")
	hand.set_steadiness(0)
	hand.group_deadzone = 0.02
	var anchor: MeshInstance3D = in_a[0]
	var other_a: MeshInstance3D = in_a[1]
	var start_a: Vector3 = other_a.global_position
	var start_b: Vector3 = in_b[0].global_position
	hand.global_position = RoomRegistry.part_centre(anchor)
	hand._try_grab()
	var latched: bool = not hand._latch.is_empty() and hand.held_node == null
	hand._on_button_pressed("trigger_click")
	var move_m := 0.10
	hand.global_position += Vector3(move_m, 0, 0)
	await physics_frame
	await physics_frame
	hand.global_position += Vector3(move_m, 0.0, 0.0) # (the first move left the dead zone and took the group; this one carries it)
	await physics_frame
	await physics_frame
	var held_group: bool = hand._held_group != null and hand._held_group.members.size() == 2
	hand._try_release()
	print("SMOKE a grip on a leaf latches, the trigger click widens it, and moving out of the dead zone holds the sub-assembly (both its leaves): ", latched and held_group)
	var moved_a: float = other_a.global_position.x - start_a.x
	print("SMOKE the other leaf of the sub-assembly came along (", snappedf(moved_a, 0.001), " m), the other placement did not: ", moved_a > 0.05 and in_b[0].global_position.is_equal_approx(start_b))
	var saved_x := NAN
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var r = await _get_json("/parts/%s/occurrences" % root_id)
		if r != null and absf(_x_of(r, occ_a) - a0) > 0.01:
			saved_x = _x_of(r, occ_a)
			break
		await process_frame
	var after_b: float = _x_of(await _get_json("/parts/%s/occurrences" % root_id), occ_b)
	var delta_mm := saved_x - a0
	var expected: float = moved_a / main.assembly_root.scale.x
	print("SMOKE the move was saved on the sub-assembly's own occurrence, in millimetres (", snappedf(delta_mm, 0.1), " mm for ", snappedf(expected, 0.1), " expected): ", not is_nan(saved_x) and absf(delta_mm - expected) < maxf(0.5, expected * 0.02))
	print("SMOKE ...and the other placement's stored pose is untouched: ", absf(after_b - b0) < 0.001)

	# --- undo puts the stored pose back
	main.command_stack.undo()
	var restored := await _wait_for(func() -> bool: return true, 1)
	var back_x := NAN
	deadline = Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var r2 = await _get_json("/parts/%s/occurrences" % root_id)
		if r2 != null and absf(_x_of(r2, occ_a) - a0) < 0.01:
			back_x = _x_of(r2, occ_a)
			break
		await process_frame
	print("SMOKE undo moves the leaves back on screen and puts the stored pose back: ", restored and not is_nan(back_x) and absf(other_a.global_position.x - start_a.x) < 0.001)

	# --- the world preview: open the sub-assembly in a room and show its world copy at both placements
	var manager = main.room_manager
	var room = await manager.open_room(s_id, "Sub", root_id, occ_a)
	if room == null:
		print("SMOKE FAILED: the room did not open - status: ", main.status_text)
		quit(1)
		return
	await _wait_for(func() -> bool: return room.interactive and room.parts.all(func(p): return p.has_meta("group_path")))
	print("SMOKE the room's parts know their place in the sub-assembly (paths of one step, relative to its own root): ", room.parts.size() == 2 and room.parts.all(func(p): return p.get_meta("group_path").size() == 1))
	var ok: bool = await manager.set_preview_mode(room, 2) # Preview
	var wp = manager.preview_of(room)
	print("SMOKE Preview finds both placements of the sub-assembly in the real world (", wp.instances.size(), "): ", ok and wp.instances.size() == 2)
	var coincide := true
	for entry in wp._proxies:
		var seed_match: Node3D = null
		for inst_seed in wp.instances[entry["inst"]]["seeds"]:
			if str(inst_seed.get_meta("occurrence_id", "")) == str(entry["src"].get_meta("occurrence_id", "")):
				seed_match = inst_seed
		if seed_match == null or entry["node"].global_position.distance_to(seed_match.global_position) > 0.001:
			coincide = false
	print("SMOKE ...and with nothing edited every preview part sits exactly on its world twin (real units, both placements): ", coincide and wp._proxies.size() == 4)
	print("SMOKE ...none of them tinted as changed: ", wp.changed_count() == 0)
	quit(0)


class GroupIndexLevels:
	static func sizes(node: Node, scope: Array) -> Array:
		var out: Array = []
		for l in preload("res://scripts/group_index.gd").levels(node, scope):
			out.append((l["members"] as Array).size())
		return out
