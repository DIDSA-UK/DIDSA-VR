extends SceneTree
## Assembly Rooms R4, the world preview ("push changes to world", scripts/room/world_preview.gd): where the room's Part sits in the world (found from the tree
## positions both sides carry, one placement per place it is used), the three states of the world copy (Hidden / Ghost / Preview), the preview following the
## room's parts live or showing the last Push, parts the edit moved or added tinted differently, the "mated in the world" warning, the tether, flying to the
## placement and back, the console buttons, and everything tidied away when the room closes. Headless; the backend is the fake document.
## Run: "$GODOT" --headless --path . --script res://tests/room_preview.gd  (see tests/README.md)

const GroupIndex := preload("res://scripts/group_index.gd")
const WorldPreview := preload("res://scripts/room/world_preview.gd")
const Room := preload("res://scripts/room/room.gd")
const RoomActions := preload("res://scripts/room/room_actions.gd")
const RoomEdit := preload("res://scripts/room/room_edit.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	# --- a stand-in main with a user (head and hands), the shared undo stack, a selection, the fake document
	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\nvar selected\nfunc current_selected_part():\n\treturn selected\nfunc current_root_part_id() -> String:\n\treturn \"R\"\nfunc mark_dirty() -> void:\n\tpass\nfunc refresh_assembly_tree() -> void:\n\tpass\nfunc reload_world_model(_d: bool = true) -> bool:\n\treturn true\n"
	main_script.reload()
	var main := Node3D.new()
	main.set_script(main_script)
	root.add_child(main)
	var stack := CommandStack.new()
	main.command_stack = stack
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	for hand_name in ["LeftController", "RightController"]:
		var hand := XRController3D.new()
		hand.name = hand_name
		hand.tracker = &"left_hand" if hand_name == "LeftController" else &"right_hand"
		hand.set_script(load("res://scripts/controller.gd"))
		hand.command_stack = stack
		origin.add_child(hand)
	var camera := XRCamera3D.new()
	camera.name = "XRCamera3D"
	origin.add_child(camera)
	camera.global_position = Vector3(0, 1.6, 4.0)

	var fake := FakeApi.new()
	fake.occurrences = {
		"R": [fake.row("s1", "S"), fake.row("s2", "S")],
		"S": [fake.row("k1", "K"), fake.row("k2", "K")],
		"K": [fake.row("kb", "B")],
		"B": [],
	}
	fake.names = {"R": "Root", "S": "Drive", "K": "Bracket", "B": "Bolt"}
	var manager := RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	manager.edit = RoomEdit.new(fake)
	await process_frame

	# --- the world: the root R places the sub-assembly S twice (s1 at 1000 mm, s2 at 3000 mm along x); each S holds two leaves (200 mm either side of its middle).
	var world := Node3D.new()
	world.scale = Vector3.ONE * 0.001 # (main.gd's assembly_root: millimetres to metres)
	main.add_child(world)
	var helper := RoomManagerTest.new()
	var leaves: Array = []
	for placement_x in [1000.0, 3000.0]:
		for dx in [-200.0, 200.0]:
			var n := helper.world_node(world, "K", "kb")
			n.mesh = BoxMesh.new()
			n.position = Vector3(placement_x + dx, 0, 0)
			leaves.append(n)
	await process_frame
	await GroupIndex.index(manager.edit_api(), "R", leaves)

	# --- the room: S opened on its first placement
	var glb := helper.glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(100, 100, 100), "owner": "K", "occ": "kb"},
		{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "K", "occ": "kb"},
	])
	var room = manager.open_from_bytes(glb, "S", "Drive", "R", "s1")
	manager.activate(room)
	for i in 4:
		await process_frame
	await GroupIndex.index(manager.edit_api(), "S", room.parts)
	var mates: Node = main.get("_mates_tool")
	var wp = manager.preview_of(room)
	print("SMOKE a room starts with its world copy hidden: ", wp.mode == WorldPreview.Mode.HIDDEN and room.parts.all(func(p): return p.has_meta("room_orig")))

	# --- the placements
	var found: Array = WorldPreview.find_instances(RoomRegistry.world_parts(self), room.parts)
	print("SMOKE the room's Part is found at both places it is placed in the world, one preview each: ", found.size() == 2 and found[0]["prefix"] == ["s1"] and found[1]["prefix"] == ["s2"])
	print("SMOKE ...each placement knows its parts in the world and where it is (1 m and 3 m along x): ", (found[0]["seeds"] as Array).size() == 2 and (found[1]["seeds"] as Array).size() == 2 and absf((found[0]["xform"] as Transform3D).origin.x - 1.0) < 0.001 and absf((found[1]["xform"] as Transform3D).origin.x - 3.0) < 0.001)
	print("SMOKE ...in the world's units (millimetres to metres): ", absf((found[0]["xform"] as Transform3D).basis.x.length() - 0.001) < 0.00001)

	# --- classification
	print("SMOKE a part nobody has touched is unchanged; moved is moved; one with no starting pose is added: ", WorldPreview.classify(room.parts[0], room.parts[0].transform) == 0 and WorldPreview.classify(room.parts[0], room.parts[0].transform.translated(Vector3(5, 0, 0))) == 1 and WorldPreview.classify(helper.world_node(main, "X", "y"), Transform3D.IDENTITY) == 2)

	# --- ghost
	var ok: bool = await manager.set_preview_mode(room, WorldPreview.Mode.GHOST)
	print("SMOKE Ghost shows the original: a faint copy of each of the four world parts, where they are: ", ok and wp.mode == WorldPreview.Mode.GHOST and wp._ghosts.size() == 4 and wp._ghosts.all(func(g): return g.get_parent() == wp) and absf(wp._ghosts[0].global_position.x - 0.8) < 0.001)
	print("SMOKE ...with a tether line from the room to the nearest placement: ", wp._tether != null and wp._tether.visible)
	print("SMOKE ...the ghosts obey the world's clip (hidden inside any room): ", int(wp._ghosts[0].get_instance_shader_parameter("room_slot")) == -1)
	await manager.set_preview_mode(room, WorldPreview.Mode.HIDDEN)
	print("SMOKE Hidden takes them all away again: ", wp._ghosts.is_empty() and wp._tether == null)

	# --- preview
	ok = await manager.set_preview_mode(room, WorldPreview.Mode.PREVIEW)
	print("SMOKE Preview puts the room's parts at each placement (2 places x 2 parts): ", ok and wp._proxies.size() == 4)
	var first: Dictionary = wp._proxies[0]
	var expected: Vector3 = (found[0]["xform"] as Transform3D) * room.parts[0].transform.origin
	print("SMOKE ...at the placed pose: the world copy's own place for that part (0.8 m): ", absf(first["node"].global_position.x - 0.8) < 0.001 and first["node"].global_position.distance_to(expected) < 0.001)
	var violet: Color = (first["node"].material_override as ShaderMaterial).get_shader_parameter("tint")
	print("SMOKE ...in the preview colour: ", violet.is_equal_approx(WorldPreview.PREVIEW_TINT))

	# the room's part moves 50 mm along y in the room's frame: the preview follows, both places, and is tinted as changed
	var moved_part: MeshInstance3D = room.parts[0]
	moved_part.transform = moved_part.transform.translated(Vector3(0, 50, 0))
	await process_frame
	await process_frame
	var by_inst := {}
	for e in wp._proxies:
		if e["src"] == moved_part:
			by_inst[e["inst"]] = e
	print("SMOKE moving a part in the room moves its preview at every placement, live (50 mm = 0.05 m up): ", absf(by_inst[0]["node"].global_position.y - 0.05) < 0.001 and absf(by_inst[1]["node"].global_position.y - 0.05) < 0.001)
	var changed_tint: Color = (by_inst[0]["node"].material_override as ShaderMaterial).get_shader_parameter("tint")
	var other_tint: Color = (wp._proxies.filter(func(e): return e["src"] != moved_part)[0]["node"].material_override as ShaderMaterial).get_shader_parameter("tint")
	print("SMOKE ...tinted differently from the parts the edit left alone: ", changed_tint.is_equal_approx(WorldPreview.CHANGED_TINT) and other_tint.is_equal_approx(WorldPreview.PREVIEW_TINT) and wp.changed_count() == 1)

	# live off: the preview shows the last push
	manager.set_preview_live(false)
	moved_part.transform = moved_part.transform.translated(Vector3(0, 100, 0))
	await process_frame
	await process_frame
	print("SMOKE with auto-update off the preview stays where the last push left it (still 0.05 m, not 0.15 m): ", absf(by_inst[0]["node"].global_position.y - 0.05) < 0.001)
	await manager.push_preview(room)
	by_inst.clear()
	for e in wp._proxies:
		if e["src"] == moved_part:
			by_inst[e["inst"]] = e
	print("SMOKE ...and Push brings it up to date (0.15 m), saying how many parts changed: ", absf(by_inst[0]["node"].global_position.y - 0.15) < 0.001 and manager.preview_message.begins_with("Pushed 1 changed part"))
	manager.set_preview_live(true)

	# a part added since the room opened
	var added: MeshInstance3D = helper.world_node(room.content_root, "K", "new")
	added.remove_from_group("grabbable_parts")
	added.remove_meta("room_orig") if added.has_meta("room_orig") else null
	room.parts.append(added)
	print("SMOKE a part that has no starting pose counts as added: ", WorldPreview.classify(added, added.transform) == 2)
	room.parts.erase(added)
	added.free()

	# the warning
	var stub := GDScript.new()
	stub.source_code = "extends Node\nvar state := 'ok'\nfunc group_state(_o, _c):\n\treturn state\n"
	stub.reload()
	var fake_mates := Node.new()
	fake_mates.set_script(stub)
	main.add_child(fake_mates)
	wp._mates = fake_mates
	wp.refresh()
	print("SMOKE no warning while the placement isn't mated: ", wp.warning == "")
	fake_mates.state = "mated"
	wp.refresh()
	print("SMOKE a mated placement says the mates may need enforcing after the edit: ", wp.warning.contains("Enforce"))
	wp._mates = mates

	# --- cycling
	await manager.set_preview_mode(room, WorldPreview.Mode.HIDDEN)
	await manager.cycle_preview(room)
	var m1: int = wp.mode
	await manager.cycle_preview(room)
	var m2: int = wp.mode
	await manager.cycle_preview(room)
	print("SMOKE the World button cycles Hidden, Ghost, Preview, Hidden: ", m1 == WorldPreview.Mode.GHOST and m2 == WorldPreview.Mode.PREVIEW and wp.mode == WorldPreview.Mode.HIDDEN)

	# --- fly to the placement and back
	var xr_origin: Node3D = main.get_node("XROrigin3D")
	await manager.set_preview_mode(room, WorldPreview.Mode.GHOST)
	var home := xr_origin.global_position
	print("SMOKE To world takes the user to the placement, standing back from it: ", manager.fly_to_world(room) and manager.is_away() and xr_origin.global_position.distance_to(home) > 0.5)
	print("SMOKE ...and the same button takes them back to exactly where they were: ", manager.fly_to_world(room) and not manager.is_away() and xr_origin.global_position.is_equal_approx(home))

	# --- the console
	var console = room.console
	manager.preview_changed.emit(room)
	await process_frame
	var world_button: Button = console.button_named("World: Ghost")
	print("SMOKE the console's World button shows the mode: ", world_button != null)
	world_button.pressed.emit()
	for i in 6:
		await process_frame
	print("SMOKE ...pressing it goes on to the next (Preview), and Push is then available: ", wp.mode == WorldPreview.Mode.PREVIEW and console.button_named("World: Preview") != null and not console.button_named("Push").disabled)

	# --- a room whose Part isn't placed in the world
	var lone_glb := helper.glb_for([{"pos": Vector3(0, 0, 0), "size": Vector3(100, 100, 100), "owner": "Z", "occ": "z1"}])
	var lone = manager.open_from_bytes(lone_glb, "Z", "Lone")
	manager.activate(lone)
	for i in 3:
		await process_frame
	var lone_ok: bool = await manager.set_preview_mode(lone, WorldPreview.Mode.PREVIEW)
	print("SMOKE a room whose Part isn't placed in the open world can't show a preview, and says so: ", not lone_ok and manager.preview_of(lone).mode == WorldPreview.Mode.HIDDEN and manager.preview_message.contains("isn't placed"))

	# --- closing tidies away
	var key: int = room.get_instance_id()
	manager.close_room(room)
	await process_frame
	await process_frame
	print("SMOKE closing the room takes its preview away: ", not manager.previews.has(key) and not is_instance_valid(wp))
	quit(0)
