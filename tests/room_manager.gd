extends SceneTree
## Assembly Rooms R1 (docs/assembly-rooms-plan.md): where a new room goes (in front, clear of others, never overlapping), a room built from a real glb
## (parts tagged and in the room_parts group, scaled to fit the 3 m cube with the content at its middle, the owner Part ids the world's copy is found
## by), the manager (opens, hides the world's copy of the sub-assembly and nothing else, closes and restores, respects the room limit, closes everything
## when the model is replaced) and that a room's parts stay out of the grab / select code. Headless; the HTTP fetch is the one thing not exercised.
## Run: "$GODOT" --headless --path . --script res://tests/room_manager.gd  (see tests/README.md)

const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomPlacement := preload("res://scripts/room/room_placement.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")


func _box_positions(size: Vector3) -> PackedVector3Array:
	## 12 triangles (unindexed), a box of `size` about the origin: the backend's glb has no indices either.
	var h := size * 0.5
	var corner := func(sx: float, sy: float, sz: float) -> Vector3: return Vector3(sx * h.x, sy * h.y, sz * h.z)
	var quads := [
		[corner.call(1, -1, -1), corner.call(1, 1, -1), corner.call(1, 1, 1), corner.call(1, -1, 1)],
		[corner.call(-1, -1, 1), corner.call(-1, 1, 1), corner.call(-1, 1, -1), corner.call(-1, -1, -1)],
		[corner.call(-1, 1, -1), corner.call(-1, 1, 1), corner.call(1, 1, 1), corner.call(1, 1, -1)],
		[corner.call(-1, -1, 1), corner.call(-1, -1, -1), corner.call(1, -1, -1), corner.call(1, -1, 1)],
		[corner.call(-1, -1, 1), corner.call(1, -1, 1), corner.call(1, 1, 1), corner.call(-1, 1, 1)],
		[corner.call(1, -1, -1), corner.call(-1, -1, -1), corner.call(-1, 1, -1), corner.call(1, 1, -1)],
	]
	var out := PackedVector3Array()
	for q in quads:
		for idx in [0, 1, 2, 0, 2, 3]:
			out.append(q[idx])
	return out


func glb_for(boxes: Array) -> PackedByteArray:
	## A glb in the backend's flat shape (mesh_identity.gd): one node per box, translation in millimetres, extras {owner_part_id, occurrence_id}, no
	## hierarchy, unindexed triangles. Hand-built like tests/mesh_identity.gd's, because Godot's own exporter nests everything under a root node.
	var bin := PackedByteArray()
	var views: Array = []
	var accessors: Array = []
	var meshes: Array = []
	var nodes: Array = []
	for i in boxes.size():
		var b: Dictionary = boxes[i]
		var data := StreamPeerBuffer.new()
		for v in _box_positions(b["size"]):
			data.put_float(v.x)
			data.put_float(v.y)
			data.put_float(v.z)
		views.append({"buffer": 0, "byteOffset": bin.size(), "byteLength": data.data_array.size(), "target": 34962})
		accessors.append({"bufferView": i, "componentType": 5126, "count": 36, "type": "VEC3"})
		bin.append_array(data.data_array)
		meshes.append({"primitives": [{"attributes": {"POSITION": i}, "mode": 4}]})
		var pos: Vector3 = b["pos"]
		nodes.append({"mesh": i, "translation": [pos.x, pos.y, pos.z], "extras": {"owner_part_id": b.get("owner", ""), "occurrence_id": b.get("occ", "")}})
	var gltf := {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": range(nodes.size())}], "nodes": nodes, "meshes": meshes,
		"accessors": accessors, "bufferViews": views, "buffers": [{"byteLength": bin.size()}]}
	var json_bytes := JSON.stringify(gltf).to_utf8_buffer()
	while json_bytes.size() % 4 != 0:
		json_bytes.append(0x20)
	while bin.size() % 4 != 0:
		bin.append(0)
	var out := StreamPeerBuffer.new()
	out.put_data("glTF".to_utf8_buffer())
	out.put_u32(2)
	out.put_u32(12 + 8 + json_bytes.size() + 8 + bin.size())
	out.put_u32(json_bytes.size())
	out.put_u32(0x4E4F534A)
	out.put_data(json_bytes)
	out.put_u32(bin.size())
	out.put_u32(0x004E4942)
	out.put_data(bin)
	return out.data_array


func world_node(parent: Node, owner: String, occ: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = BoxMesh.new()
	m.set_meta("owner_part_id", owner)
	m.set_meta("occurrence_id", occ)
	m.add_to_group("grabbable_parts")
	parent.add_child(m)
	return m


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	# --- placement
	var size := Vector3(3, 3, 3)
	var eye := Vector3(0, 1.6, 0)
	var ahead := Vector3(0, 0, -1)
	var first: Transform3D = RoomPlacement.find_spot(eye, ahead, size, [])
	print("SMOKE the first room is straight ahead, standing on the floor, its near wall about 1.2 m away: ", first.origin.is_equal_approx(Vector3(0, 1.5, -2.7)))
	print("SMOKE ...and it faces the way the user does: ", (first.basis * Vector3(0, 0, -1)).is_equal_approx(ahead))
	var turned: Transform3D = RoomPlacement.find_spot(eye, Vector3(1, -0.4, 0), size, [])
	print("SMOKE looking down or up does not tilt the room, the heading is flattened: ", turned.origin.y == 1.5 and absf(turned.origin.x - 2.7) < 0.001)
	var taken := RoomVolume.make(first, size)
	var second: Transform3D = RoomPlacement.find_spot(eye, ahead, size, [taken])
	print("SMOKE with that spot taken the next room goes beside it, not on it: ", not taken.overlaps(RoomVolume.make(second, size)) and absf(second.origin.z - first.origin.z) < 0.001)
	var wall: Array = []
	for step in range(-5, 6):
		wall.append(RoomVolume.make(Transform3D(first.basis, first.origin + Vector3(step * 3.5, 0, 0)), size))
	var third: Transform3D = RoomPlacement.find_spot(eye, ahead, size, wall)
	print("SMOKE with a whole row taken it goes further out (a second row), still not overlapping anything: ", third.origin.z < first.origin.z - 3.0 and wall.all(func(r): return not r.overlaps(RoomVolume.make(third, size))))
	var boxed_in: Array = []
	for ring in 5:
		for step in range(-6, 7):
			boxed_in.append(RoomVolume.make(Transform3D(first.basis, first.origin + Vector3(step * 3.5, 0, -ring * 3.5)), size))
	print("SMOKE with everything within reach taken there is no spot (null), not a bad one: ", RoomPlacement.find_spot(eye, ahead, size, boxed_in) == null)

	# --- a room built from a glb: two 100 mm cubes 400 mm apart, owned by a sub-assembly Part "S" and a nested one "N"
	var glb := glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "o1"},
		{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "N", "occ": "o2"},
	])
	print("SMOKE the test glb is a real, readable glb: ", glb.size() > 100)
	var room := Room.new()
	var built := room.build(glb, Transform3D(Basis.IDENTITY, Vector3(0, 1.5, -3)), size, "S", "Sub")
	print("SMOKE a room builds from the glb, with both meshes in the room_parts group and not the grabbable one: ", built and room.parts.size() == 2 and room.parts.all(func(p): return p.is_in_group("room_parts") and not p.is_in_group("grabbable_parts")))
	print("SMOKE ...tagged with the backend identity (owner and occurrence): ", str(room.parts[0].get_meta("owner_part_id")) == "S" and str(room.parts[1].get_meta("occurrence_id")) == "o2")
	print("SMOKE ...and the owner Part ids the world's copy is found by are S and N: ", room.owner_part_ids().keys().size() == 2 and room.owner_part_ids().has("S") and room.owner_part_ids().has("N"))
	var bounds := Room.content_bounds(room.content_root)
	print("SMOKE the content's bounds are 500 x 100 x 100 mm: ", bounds.size.is_equal_approx(Vector3(500, 100, 100)))
	var expected_scale := 0.7 * 3.0 / 500.0
	print("SMOKE opening scale fits the tightest axis to 70% of the room (0.0042 m per mm = 4.2:1): ", is_equal_approx(room.content_scale, expected_scale) and room.scale_text() == "4.2:1")
	var middle: Vector3 = room.content_root.position + room.content_root.scale * bounds.get_center()
	print("SMOKE the content's middle sits at the room's middle: ", middle.length() < 0.0001)
	print("SMOKE the scale can change and the middle stays put (1:1 here): ", (func() -> bool:
		room.set_content_scale(0.001)
		var m: Vector3 = room.content_root.position + room.content_root.scale * bounds.get_center()
		return m.length() < 0.0001 and room.scale_text() == "1:1").call())
	print("SMOKE the fit of an empty/flat thing falls back to 1:1: ", is_equal_approx(Room.fit_scale(AABB(), size), 0.001))
	room.free()

	# --- the manager
	var main_stand_in := Node3D.new()
	root.add_child(main_stand_in)
	var world := Node3D.new()
	root.add_child(world)
	var manager := RoomManager.new()
	main_stand_in.add_child(manager)
	manager.setup(main_stand_in, null)
	var messages: Array[String] = []
	manager.status.connect(func(t: String) -> void: messages.append(t))
	var changed := [0]
	manager.rooms_changed.connect(func() -> void: changed[0] += 1)

	# the world: the sub-assembly's two leaves (owned by S and N), the sub-assembly's own geometry (owner R, occurrence "sub"), and unrelated parts
	var leaf_s := world_node(world, "S", "o1")
	var leaf_n := world_node(world, "N", "o2")
	var own_geometry := world_node(world, "R", "sub")
	var unrelated := world_node(world, "R", "other")
	var elsewhere := world_node(world, "Z", "o9")
	await process_frame

	var opened = manager.open_from_bytes(glb, "S", "Sub", "R", "sub")
	print("SMOKE opening a room registers its box (slot 0) and is tracked: ", opened != null and RoomRegistry.room_count() == 1 and manager.rooms.size() == 1 and manager.room_for_part("S") == opened and manager.is_open_for("S"))
	print("SMOKE the world's copy is hidden: the leaves owned by the sub-assembly and by a nested Part, and the sub-assembly's own geometry: ", not leaf_s.visible and not leaf_n.visible and not own_geometry.visible)
	print("SMOKE ...and nothing else is: the same parent's other occurrence and an unrelated Part stay: ", unrelated.visible and elsewhere.visible)
	await process_frame
	await process_frame
	print("SMOKE after a frame the room's parts carry its slot and the world's parts carry -1: ", opened.parts.all(func(p): return int(p.get_meta("room_slot")) == opened.volume.slot) and int(unrelated.get_meta("room_slot")) == -1)
	print("SMOKE the world is cut inside the room and the room's parts are visible inside it: ", not RoomRegistry.part_visible_at(unrelated, opened.global_position) and RoomRegistry.part_visible_at(opened.parts[0], opened.global_position + Vector3(0.05, 0, 0)))
	manager.toggle_room("S", "Sub", "R", "sub") # a second press on an open Part's button closes its room (no fetch is needed to close)
	print("SMOKE toggling an open Part closes its room: ", manager.room_for_part("S") == null and manager.rooms.is_empty())
	opened = manager.open_from_bytes(glb, "S", "Sub", "R", "sub")
	manager.close_room(opened)
	print("SMOKE closing restores the world's copy and frees the box: ", leaf_s.visible and leaf_n.visible and own_geometry.visible and RoomRegistry.room_count() == 0 and manager.rooms.is_empty() and not manager.is_open_for("S"))
	await process_frame
	await process_frame
	print("SMOKE ...and with no rooms left the world's parts are given back their own materials: ", not unrelated.has_meta("room_slot") and unrelated.material_override == null)

	# the limit
	RoomRegistry.set_max_rooms(2)
	var a = manager.open_from_bytes(glb, "A", "A")
	var b = manager.open_from_bytes(glb, "B", "B")
	messages.clear()
	var c = manager.open_from_bytes(glb, "C", "C")
	print("SMOKE two rooms open side by side without overlapping: ", a != null and b != null and not a.volume.overlaps(b.volume))
	print("SMOKE the third is refused at the limit, with a message that names the limit: ", c == null and messages.size() > 0 and messages[0].contains("limit") and manager.rooms.size() == 2)
	RoomRegistry.set_max_rooms(4)
	var d = manager.open_from_bytes(glb, "D", "D")
	print("SMOKE raising the limit lets it in: ", d != null and manager.rooms.size() == 3)

	# a bad glb
	var bad = manager.open_from_bytes(PackedByteArray([1, 2, 3, 4]), "X", "Bad")
	print("SMOKE unreadable mesh bytes open nothing and say so: ", bad == null and manager.rooms.size() == 3 and messages.back().contains("read"))

	# the model being replaced closes every room and restores nothing (the nodes are going away)
	manager.on_model_replaced()
	print("SMOKE replacing the world's model closes every room and frees every box: ", manager.rooms.is_empty() and RoomRegistry.room_count() == 0)

	# a room's parts are not grabbable, selectable or pickable by the arena code
	var origin := XROrigin3D.new()
	world.add_child(origin)
	var hand := XRController3D.new()
	hand.tracker = &"left_hand"
	hand.set_script(load("res://scripts/controller.gd"))
	origin.add_child(hand)
	await process_frame
	var viewer = manager.open_from_bytes(glb, "V", "Viewer")
	hand.global_position = viewer.parts[0].global_position
	print("SMOKE a hand inside a room part does not grip it (room parts are not grabbable in R1): ", hand._find_grab_target() == null)
	manager.close_all()
	RoomRegistry.clear()
	quit()
