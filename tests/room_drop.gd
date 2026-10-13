extends SceneTree
## Assembly Rooms, drop-to-add and delete the seed, end to end in the headless scene with a fake document (tests/fake_room_api.gd): a hand lets go of a
## part inside a room and a COPY is added to that room's assembly (a new occurrence, the room reloaded, one undo step, the original back where it was
## picked up); a part carried from one room into another is copied the same way; the guards (a Part into itself, a room not ready) refuse with a message
## and no call; the corner-bracket cue shows while it is over a room; Delete removes a part (counting its Mates), refreshes the room or the world, and
## undoes; the Files tab's Add goes to the room you stand in; closing a room whose assembly changed reloads the world.
## Run: "$GODOT" --headless --path . --script res://tests/room_drop.gd  (see tests/README.md)

const RoomManager := preload("res://scripts/room/room_manager.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomEdit := preload("res://scripts/room/room_edit.gd")
const DropCue := preload("res://scripts/room/drop_cue.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")

var main
var manager
var fake
var stack
var messages: Array[String] = []


func settle() -> void:
	for i in 40:
		await process_frame
		if not manager._busy_edit and i > 3:
			return


func glb_of(ids: Array, owner: String) -> PackedByteArray:
	var boxes: Array = []
	for i in ids.size():
		boxes.append({"pos": Vector3(-200 + 200 * i, 0, 0), "size": Vector3(100, 100, 100), "owner": owner, "occ": ids[i]})
	return RoomManagerTest.new().glb_for(boxes)


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\nvar dirty_count := 0\nvar tree_refreshes := 0\nvar world_reloads := 0\nfunc mark_dirty() -> void:\n\tdirty_count += 1\nfunc refresh_assembly_tree() -> void:\n\ttree_refreshes += 1\nfunc reload_world_model(_dirty: bool = true) -> bool:\n\tworld_reloads += 1\n\treturn true\n"
	main_script.reload()
	main = Node3D.new()
	main.set_script(main_script)
	root.add_child(main)
	stack = CommandStack.new()
	main.command_stack = stack
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	var hand := XRController3D.new()
	hand.name = "LeftController"
	hand.tracker = &"left_hand"
	hand.set_script(load("res://scripts/controller.gd"))
	hand.command_stack = stack
	origin.add_child(hand)
	hand.set_steadiness(0)

	fake = FakeApi.new()
	fake.occurrences = {
		"R": [fake.row("b1", "B"), fake.row("s1", "S")],
		"S": [fake.row("k1", "K"), fake.row("k2", "K")],
		"T": [fake.row("t1", "C")],
		"K": [], "B": [], "C": [],
	}
	fake.mates = {"S": [{"references": [{"occurrence_id": "k1"}, {"occurrence_id": "k2"}]}]}
	manager = RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	manager.edit = RoomEdit.new(fake)
	manager.status.connect(func(t: String) -> void: messages.append(t))
	await process_frame

	# the world's parts: a bolt (Part B) and the sub-assembly's own placement (Part S), far from where the rooms go
	var helper := RoomManagerTest.new()
	var bolt: MeshInstance3D = helper.world_node(main, "R", "b1")
	(bolt.mesh as BoxMesh).size = Vector3(0.1, 0.1, 0.1)
	bolt.position = Vector3(9.0, 1.0, -4.0)
	bolt.create_trimesh_collision()
	var sub_placement: MeshInstance3D = helper.world_node(main, "R", "s1")
	(sub_placement.mesh as BoxMesh).size = Vector3(0.1, 0.1, 0.1)
	sub_placement.position = Vector3(9.0, 1.0, -5.0)
	sub_placement.create_trimesh_collision()

	# room S (parts k1, k2) and room T (part t1), both opened and made touchable
	var room_s = manager.open_from_bytes(glb_of(["k1", "k2"], "S"), "S", "Sub")
	var room_t = manager.open_from_bytes(glb_of(["t1"], "T"), "T", "Other")
	manager.activate(room_s)
	await process_frame
	await physics_frame
	await physics_frame
	print("SMOKE two rooms open side by side, S with two parts and T with one: ", room_s != null and room_t != null and room_s.parts.size() == 2 and room_t.parts.size() == 1 and not room_s.volume.overlaps(room_t.volume))
	print("SMOKE a room that is not interactive yet is a room whose parts can't be touched: ", not room_t.interactive and room_s.interactive)

	# --- the cue and the add: carry the bolt into room S and let go
	fake.glb = glb_of(["k1", "k2", "NEW"], "S") # what the backend will answer when the room is reloaded after the add
	var start := bolt.global_transform
	hand.global_position = bolt.global_position
	hand._try_grab()
	hand.global_position = room_s.global_position + Vector3(0.3, -0.2, 0.1)
	await physics_frame
	await physics_frame
	manager._update_drop_cues()
	var cue := bolt.get_node_or_null("DropCue")
	print("SMOKE carried over a room that can take it, the part shows the drop cue (corner brackets) in that room's colour: ", cue != null and cue.visible and (cue.mesh.surface_get_material(0) as StandardMaterial3D).albedo_color.is_equal_approx(Color(room_s.colour.r, room_s.colour.g, room_s.colour.b, 0.95)))
	hand.global_position = Vector3(9.0, 1.0, -4.0)
	await physics_frame
	await physics_frame
	manager._update_drop_cues()
	print("SMOKE ...and the cue goes again when it is carried out of the room: ", not bolt.get_node("DropCue").visible)
	hand.global_position = room_s.global_position + Vector3(0.3, -0.2, 0.1)
	await physics_frame
	await physics_frame
	var dropped_at := bolt.global_transform
	messages.clear()
	hand._try_release()
	await settle()
	var post: Dictionary = fake.last(HTTPClient.METHOD_POST, "/parts/S/occurrences")
	print("SMOKE letting go inside room S adds a copy of the bolt (Part B) to S with a new occurrence id: ", not post.is_empty() and post["body"]["resolved_part_id"] == "B" and str(post["body"]["id"]).begins_with("occ_"))
	print("SMOKE ...at the pose it was let go at, in the room's millimetres: ", (func() -> bool:
		var expected := RoomEdit.pose_in_room(dropped_at, room_s.content_root)
		var a: Array = post["body"]["transform"]["translation"]
		var b: Array = expected["translation"]
		return absf(a[0] - b[0]) < 0.01 and absf(a[1] - b[1]) < 0.01 and absf(a[2] - b[2]) < 0.01).call())
	print("SMOKE the original is back where it was picked up (it's a copy), the cue is gone: ", bolt.global_transform.is_equal_approx(start) and not bolt.get_node("DropCue").visible)
	print("SMOKE the room reloaded from the backend: three parts now, the room marked as changed, the document dirty, the tree stale: ", room_s.parts.size() == 3 and room_s.members_changed and main.dirty_count > 0 and main.tree_refreshes > 0)
	print("SMOKE the reloaded parts are touchable and under the clip (the room stays a world within the world): ", room_s.parts.all(func(p): return p.is_in_group("grabbable_parts") and int(p.get_meta("room_slot")) == room_s.volume.slot))
	print("SMOKE ...and a message says it was added and was a copy: ", messages.any(func(m): return m.contains("Added") and m.contains("copy")))

	# --- undo and redo
	var added_id := str(post["body"]["id"])
	fake.glb = glb_of(["k1", "k2"], "S")
	stack.undo()
	await settle()
	print("SMOKE undo deletes the added occurrence and the room shows two parts again: ", fake.count(HTTPClient.METHOD_DELETE, "/occurrences/" + added_id) == 1 and room_s.parts.size() == 2)
	fake.glb = glb_of(["k1", "k2", "NEW"], "S")
	stack.redo()
	await settle()
	var again: Dictionary = fake.last(HTTPClient.METHOD_POST, "/parts/S/occurrences")
	print("SMOKE redo puts the same occurrence back (same id) and the room shows three: ", again["body"]["id"] == added_id and room_s.parts.size() == 3)

	# --- guards: a Part into itself, a room that is not ready
	var posts: int = fake.count(HTTPClient.METHOD_POST, "/occurrences")
	messages.clear()
	var s_start := sub_placement.global_transform
	hand.global_position = sub_placement.global_position
	hand._try_grab()
	hand.global_position = room_s.global_position
	await physics_frame
	await physics_frame
	hand._try_release()
	await settle()
	print("SMOKE carrying S's own placement into S is refused with the reason, no call made, the part back: ", fake.count(HTTPClient.METHOD_POST, "/occurrences") == posts and messages.any(func(m): return m.contains("can't hold itself")) and sub_placement.global_transform.is_equal_approx(s_start))
	messages.clear()
	hand.global_position = bolt.global_position
	hand._try_grab()
	hand.global_position = room_t.global_position
	await physics_frame
	await physics_frame
	hand._try_release()
	await settle()
	print("SMOKE letting go in a room that isn't ready (T) sends the part back and says why: ", fake.count(HTTPClient.METHOD_POST, "/occurrences") == posts and messages.any(func(m): return m.contains("isn't ready")))

	# --- a part carried from one room into another is copied there
	manager.activate(room_t)
	await physics_frame
	await physics_frame
	var t_part: MeshInstance3D = room_t.parts[0]
	fake.glb = glb_of(["k1", "k2", "NEW2"], "S")
	hand.global_position = RoomRegistry.part_centre(t_part)
	hand._try_grab()
	var held_ok: bool = hand.held_node == t_part
	hand.global_position = room_s.global_position + Vector3(-0.4, 0.0, 0.0)
	await physics_frame
	await physics_frame
	hand._try_release()
	await settle()
	var cross: Dictionary = fake.last(HTTPClient.METHOD_POST, "/parts/S/occurrences")
	print("SMOKE a part carried out of room T and let go inside room S is copied into S (the Part T's part shows: C): ", held_ok and cross["body"]["resolved_part_id"] == "C" and room_s.parts.size() == 3 + 0 and room_t.parts.size() == 1)

	# --- delete
	messages.clear()
	var world_reloads: int = main.world_reloads
	fake.glb = glb_of(["k2"], "S")
	var deleted: Dictionary = await manager.delete_occurrence("S", "k1", "Bracket")
	print("SMOKE deleting a part inside S says how many Mates went with it and reloads that room, not the world: ", deleted["ok"] and deleted["mates_removed"] == 1 and messages.any(func(m): return m.contains("Deleted Bracket") and m.contains("1 mate")) and room_s.parts.size() == 1 and main.world_reloads == world_reloads)
	fake.glb = glb_of(["k1", "k2"], "S")
	stack.undo()
	await settle()
	print("SMOKE undoing the delete posts the occurrence back with its old id: ", fake.last(HTTPClient.METHOD_POST, "/parts/S/occurrences")["body"]["id"] == "k1" and room_s.parts.size() == 2)
	fake.glb = glb_of(["k2"], "S")
	stack.redo()
	await settle()
	print("SMOKE ...and redo deletes it again: ", fake.count(HTTPClient.METHOD_DELETE, "/occurrences/k1") == 2 and room_s.parts.size() == 1)
	var before_world: int = main.world_reloads
	await manager.delete_occurrence("R", "b1", "Bolt")
	print("SMOKE deleting a part of the world's own assembly (no room for its Part) reloads the world, and the undo step is pushed after it so the reload can't wipe it: ", main.world_reloads == before_world + 1 and stack.can_undo() and stack.undo_label() == "delete Bolt")
	var missing: Dictionary = await manager.delete_occurrence("R", "b1", "Bolt again")
	print("SMOKE deleting something already gone says so and changes nothing: ", not missing["ok"] and messages.back().contains("not in the backend"))

	# --- the Files tab's Add, standing in a room
	var file_path := "user://room_drop_component.didsa"
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	f.store_string('{"schema_version": 1, "document": {"root_part_id": "x", "parts": []}}')
	f.close()
	fake.glb = glb_of(["k2", "ADDED"], "S")
	var ok_file: bool = await manager.add_file_to_room(room_s, file_path)
	var add_call: Dictionary = fake.last(HTTPClient.METHOD_POST, "/parts/S/add-component")
	print("SMOKE Add from the Files tab while in a room adds the file's Part to that room's assembly (the file's own text), and the room shows it: ", ok_file and add_call["body"] is String and (add_call["body"] as String).contains('"root_part_id": "x"') and room_s.parts.size() == 2)
	var unreadable: bool = await manager.add_file_to_room(room_s, "user://does_not_exist.didsa")
	print("SMOKE ...and a file that can't be read adds nothing and says so: ", not unreadable and messages.back().contains("Couldn't read"))

	# --- re-reading the world keeps the rooms open and hides their NEW world copies; replacing it for a different file closes them
	var fresh_copy: MeshInstance3D = helper.world_node(main, "S", "k2") # the re-read world's copy of S's part k2 (the old node was replaced)
	print("SMOKE before reseeding, a freshly re-read world copy of a room's part is visible: ", fresh_copy.visible)
	manager.on_model_replaced(true)
	manager.reseed_rooms()
	print("SMOKE a world re-read (same document) keeps every room open and hides the new world copies of what each room holds: ", manager.rooms.size() == 2 and not fresh_copy.visible)
	manager.on_model_replaced(false)
	print("SMOKE ...whereas replacing the model for a different file closes them all: ", manager.rooms.is_empty() and RoomRegistry.room_count() == 0)
	manager.open_from_bytes(glb_of(["k1", "k2"], "S"), "S", "Sub")
	manager.activate(manager.rooms[0])
	manager.rooms[0].members_changed = true
	room_s = manager.rooms[0]
	room_t = manager.open_from_bytes(glb_of(["t1"], "T"), "T", "Other")

	# --- closing a room whose assembly changed reloads the world
	var reloads: int = main.world_reloads
	manager.close_room(room_s)
	await process_frame
	print("SMOKE closing a room whose assembly changed reloads the world (its copies of that Part are out of date): ", main.world_reloads == reloads + 1)
	reloads = main.world_reloads
	manager.close_room(room_t)
	await process_frame
	print("SMOKE ...but closing one that wasn't changed does not: ", main.world_reloads == reloads)
	RoomRegistry.clear()
	quit()
