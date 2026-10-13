extends SceneTree
## Assembly Rooms R2, interaction parity (docs/assembly-rooms-plan.md): a room is a world within the world. Headless.
##   * an activated room's parts are grabbable, have collision, and are found by the grip and the laser only inside the walls;
##   * a part moved inside its room stays (and is one undo step); put down outside the room it goes back; a world part left inside a room goes back;
##   * the mates tool knows a room's Part as a root: its parts are managed, saved to THEIR owner's path, fixed / mated / locked / constrained from its own
##     state, found beside the right copy (the room's or the hidden world one), forgotten when the room closes;
##   * a grip on empty space is claimed by the room the hand is in (else the world), latched until release; a room's whole-room gesture moves, and scales its
##     content; group operations are scoped to a room by its parts;
##   * closing a room lets go of anything held from it.
## Not covered (needs a real grip / backend / headset): the HTTP calls themselves, feel.
## Run: "$GODOT" --headless --path . --script res://tests/room_interaction.gd  (see tests/README.md)

const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const RoomManager := preload("res://scripts/room/room_manager.gd")
const MatesTool := preload("res://scripts/mates_tool.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)
	var helper := RoomManagerTest.new()

	# a stand-in for main.gd: the controllers under an XROrigin3D, the shared undo stack, the mates tool
	var main_script := GDScript.new()
	main_script.source_code = "extends Node3D\nvar command_stack\nvar _mates_tool\nvar quality := 0.5\nvar include_hidden := false\nvar tier := \"\"\n"
	main_script.reload()
	var main := Node3D.new()
	main.set_script(main_script)
	root.add_child(main)
	var stack := CommandStack.new()
	main.command_stack = stack
	var mates := MatesTool.new()
	main.add_child(mates)
	mates.configure_backend("http://127.0.0.1:1", "key") # nothing listens: no call can succeed, which is fine, only the state is under test
	main._mates_tool = mates
	var origin := XROrigin3D.new()
	origin.name = "XROrigin3D"
	main.add_child(origin)
	var hands := []
	for hand_name in ["LeftController", "RightController"]:
		var hand := XRController3D.new()
		hand.name = hand_name
		hand.tracker = &"left_hand" if hand_name == "LeftController" else &"right_hand"
		hand.set_script(load("res://scripts/controller.gd"))
		hand.command_stack = stack
		hand.mates_tool = mates
		origin.add_child(hand)
		hands.append(hand)
	var left: XRController3D = hands[0]
	var right: XRController3D = hands[1]
	var manager := RoomManager.new()
	main.add_child(manager)
	manager.setup(main, null)
	var messages: Array[String] = []
	manager.status.connect(func(t: String) -> void: messages.append(t))
	await process_frame

	# the world: the root Part "R" with one placed occurrence, and the hidden copy of the sub-assembly "S"'s two leaves
	var world_part := RoomManagerTest.new().world_node(main, "R", "w1")
	world_part.mesh = BoxMesh.new()
	(world_part.mesh as BoxMesh).size = Vector3(0.2, 0.2, 0.2)
	world_part.position = Vector3(8, 1, -4)
	world_part.create_trimesh_collision()
	var seed_o1 := RoomManagerTest.new().world_node(main, "S", "o1")
	seed_o1.visible = false

	# a room holding S: two 100 mm cubes (owner S, occurrences o1 and o2), opened but not yet interactive
	var glb := helper.glb_for([
		{"pos": Vector3(-200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "o1"},
		{"pos": Vector3(200, 0, 0), "size": Vector3(100, 100, 100), "owner": "S", "occ": "o2"},
	])
	var room = manager.open_from_bytes(glb, "S", "Sub")
	await process_frame
	var o1: MeshInstance3D = room.parts[0]
	var o2: MeshInstance3D = room.parts[1]
	print("SMOKE a freshly opened room's parts are not touchable yet (nothing to save moves to until its state is read): ", not o1.is_in_group("grabbable_parts") and not room.interactive)
	manager.activate(room)
	await physics_frame
	await physics_frame
	print("SMOKE activating makes them grabbable with collision, and gives the room its own whole-room gesture: ", room.interactive and o1.is_in_group("grabbable_parts") and o1.get_children().any(func(c): return c is StaticBody3D) and room.two_hand != null)
	print("SMOKE the world's part list does not include the room's parts: ", RoomRegistry.world_parts(self).has(world_part) and not RoomRegistry.world_parts(self).has(o1) and RoomRegistry.parts_in_room(self, room.get_instance_id()).size() == 2)
	var centre: Vector3 = RoomRegistry.part_centre(o1)
	print("SMOKE ...and the room is in front of the user, the part inside its walls: ", room.volume.contains(centre))

	# --- grip and laser find a room part, inside the walls only
	left.global_position = centre
	left.set_steadiness(0)
	print("SMOKE a hand on a room part can take it: ", left._find_grab_target() == o1)
	var ray: Dictionary = left._raycast_part(centre + Vector3(0, 0, 1.0), Vector3(0, 0, -1), 5.0)
	print("SMOKE ...and the laser pointed at it picks it: ", ray.get("part") == o1)

	# --- a move inside the room stays and is one undo step
	var before: Transform3D = o1.global_transform
	left._try_grab()
	left.global_position = centre + Vector3(0.12, 0.05, 0.0)
	await physics_frame
	left._try_release()
	var after: Transform3D = o1.global_transform
	print("SMOKE a part moved by hand inside its room stays where it was put: ", not before.is_equal_approx(after) and room.volume.contains(RoomRegistry.part_centre(o1)) and absf(after.origin.x - before.origin.x - 0.12) < 0.01)
	print("SMOKE ...as one undo step: ", stack.can_undo())
	stack.undo()
	print("SMOKE ...which puts it back: ", o1.global_transform.is_equal_approx(before))
	stack.redo()

	# --- put down outside the room: back to where it was picked up, nothing recorded
	messages.clear()
	var steps_before := stack.history_labels().size()
	var held_from: Transform3D = o1.global_transform
	left.global_position = RoomRegistry.part_centre(o1)
	left._try_grab()
	left.global_position += Vector3(6.0, 0.0, 0.0)
	await physics_frame
	var carried_out: bool = not room.volume.contains(RoomRegistry.part_centre(o1))
	left._try_release()
	print("SMOKE carried out of the room (it was clipped away on the way): ", carried_out)
	print("SMOKE ...and put down outside it, the part goes back to where it was picked up: ", o1.global_transform.is_equal_approx(held_from))
	print("SMOKE ...with no undo step, and a message that says why: ", stack.history_labels().size() == steps_before and messages.size() > 0 and messages.back().contains("stay in the room"))

	# --- a world part carried into the room and put down there goes back
	messages.clear()
	var world_start: Transform3D = world_part.global_transform
	left.global_position = world_part.global_position
	left._try_grab()
	left.global_position = room.global_position
	await physics_frame
	left._try_release()
	print("SMOKE a world part put down inside a room goes back to where it was picked up (the drop becomes a copy added to the room: tests/room_drop.gd; here there is no backend to add with, so it only says so): ", world_part.global_transform.is_equal_approx(world_start) and messages.size() > 0 and messages.back().contains("needs the backend"))
	left.global_position = world_part.global_position
	left._try_grab()
	left.global_position += Vector3(0.0, 0.5, 0.0)
	await physics_frame
	left._try_release()
	print("SMOKE ...but a world part moved in the world is as before: ", absf(world_part.global_position.y - world_start.origin.y - 0.5) < 0.01)

	# --- the mates tool and a room's Part
	mates.refresh_state("R") # the world's root becomes the active one (the request fails; the state it registers is what matters)
	print("SMOKE before the room's state is registered, its parts are not managed (nothing is saved for them): ", not mates.is_managed(o1))
	mates.set_owner_state("S", {"o1": {"fixed": false}, "o2": {"fixed": true}}, {"o1": true, "o2": true})
	print("SMOKE once the room's Part is registered its top-level occurrences are managed: ", mates.is_managed(o1) and mates.is_managed(o2))
	print("SMOKE ...the world's root is still managed too, and an unknown Part is not: ", mates.is_managed(world_part) and not mates.is_managed(helper.world_node(main, "X", "q1")))
	print("SMOKE a room part's pose is saved under ITS owner Part, the world's under the root: ", mates.persist_path(o1) == "/parts/S/occurrences/o1" and mates.persist_path(world_part) == "/parts/R/occurrences/w1")
	print("SMOKE grounded and mated come from the room's own state: o2 is fixed and mated, o1 mated and free: ", mates.is_fixed(o2) and not mates.is_fixed(o1) and mates.is_mated(o1) and mates.is_mated(o2))
	print("SMOKE ...so o2 is the locked anchor and o1 is steered by its mates: ", mates.is_locked(o2) and not mates.is_locked(o1) and mates.is_constrained(o1) and not mates.is_constrained(o2))
	await mates.refresh_mates("S") # (a mate was just made in the room: the request fails here, and either way the active root must not move)
	print("SMOKE making or deleting a mate in a room refreshes the room's state and leaves the world's root the active one (its parts stay managed): ", mates.is_managed(world_part) and mates.is_managed(o1) and mates.persist_path(world_part) == "/parts/R/occurrences/w1")
	mates.set_relaxed(true)
	print("SMOKE Relax all frees them (as in the world): ", not mates.is_locked(o2) and not mates.is_constrained(o1))
	mates.set_relaxed(false)
	print("SMOKE the same occurrence ids in the world's hidden copy resolve to the room's node, and beside the hidden copy to that copy: ", mates._find_loaded_part("S", "o1") == o1 and mates._find_loaded_part("S", "o1", seed_o1) == seed_o1 and mates._find_loaded_part("S", "o1", o1) == o1)
	print("SMOKE a grounded room part can't be moved by hand while mates are enforced (the grip is refused like in the world): ", (func() -> bool:
		left.global_position = RoomRegistry.part_centre(o2)
		left._try_grab()
		return left.held_node == null).call())

	# --- a grip on empty space is claimed by the room the hand is in
	var world_gesture := TwoHandModel.new()
	main.add_child(world_gesture)
	var empty_root := Node3D.new()
	main.add_child(empty_root)
	world_gesture.setup(empty_root, left, right, 0.001)
	world_gesture.focus = func(hand: Node3D) -> bool: return RoomRegistry.room_at(hand.global_position) == -1
	var inside: Vector3 = room.global_position
	var outside: Vector3 = room.global_position + Vector3(12.0, 0.0, 0.0)
	right.global_position = inside
	left.global_position = outside
	print("SMOKE a grip on empty space inside a room is the room's, not the world's: ", room.two_hand._claims(right, true) and not world_gesture._claims(right, true))
	print("SMOKE ...and one outside every room is the world's, not the room's: ", world_gesture._claims(left, true) and not room.two_hand._claims(left, true))
	right.global_position = outside
	print("SMOKE the claim is latched while the grip stays down (a drag that carries the hand out of the room keeps the gesture): ", room.two_hand._claims(right, true) and not world_gesture._claims(right, true))
	room.two_hand._claims(right, false)
	world_gesture._claims(right, false)
	print("SMOKE ...and released, the next grip is decided afresh: ", not room.two_hand._claims(right, true) and world_gesture._claims(right, true))

	# --- the whole-room gesture moves and scales the content
	var content_before: Vector3 = room.content_root.global_position
	var scale_before: float = room.content_scale
	room.two_hand.set_steadiness(0)
	right.global_position = inside
	room.two_hand._update_one_hand(right, inside)
	room.two_hand._update_one_hand(right, inside + Vector3(0.0, 0.0, -0.1))
	print("SMOKE one hand on empty space inside the room drags its content (translation only): ", room.content_root.global_position.distance_to(content_before + Vector3(0.0, 0.0, -0.1)) < 0.001 or room.content_root.global_position.distance_to(content_before) > 0.01)
	var mid: Vector3 = inside
	left.global_position = mid + Vector3(-0.3, 0, 0)
	right.global_position = mid + Vector3(0.3, 0, 0)
	room.two_hand._mode = 0
	room.two_hand._update_two_hand(left.global_position, right.global_position)
	left.global_position = mid + Vector3(-0.33, 0, 0)
	right.global_position = mid + Vector3(0.33, 0, 0)
	room.two_hand._update_two_hand(left.global_position, right.global_position)
	print("SMOKE two hands spreading 10%% scale the room's content by x1.331 (the room's scale, walls untouched): ", absf(room.content_scale / scale_before - 1.331) < 0.01 and room.volume.half.is_equal_approx(Vector3(1.5, 1.5, 1.5)))
	print("SMOKE the room's scale limits are wider than the world's (a 10 mm part fits a 3 m room): ", room.two_hand.max_multiple >= 1000.0 and room.two_hand.min_multiple <= 0.02)
	var bounds_world: AABB = world_gesture._model_bounds()
	print("SMOKE a model's bounds count only its own parts: a model with none under it has empty bounds even though the scene is full of parts, and the room's are its content's: ", bounds_world.size == Vector3.ZERO and room.two_hand._model_bounds().size.length() > 0.1)

	# --- group operations are scoped by room
	print("SMOKE a group operation anchored on a room part acts on that room's parts only: ", manager.scope_parts(o1).size() == 2 and manager.scope_parts(o1).all(func(p): return RoomRegistry.is_room_part(p)))
	print("SMOKE ...on a world part, or with nothing selected and nobody standing in a room, on the world's: ", manager.scope_parts(world_part).has(world_part) and not manager.scope_parts(world_part).has(o1) and not manager.scope_parts(null).has(o1))

	# --- closing a room lets go of what is held from it, and forgets its Part
	left.global_position = RoomRegistry.part_centre(o1)
	left.set_steadiness(0)
	mates.set_owner_state("S", {"o1": {"fixed": false}, "o2": {"fixed": false}}, {})
	left._try_grab()
	var was_held: bool = left.held_node == o1
	manager.close_room(room)
	await process_frame
	print("SMOKE closing a room lets go of a part still held from it: ", was_held and left.held_node == null)
	print("SMOKE ...and the mates tool stops managing its Part: ", not mates.is_managed(helper.world_node(main, "S", "o9")))
	RoomRegistry.clear()
	quit()
