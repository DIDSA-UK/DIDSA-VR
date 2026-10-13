extends SceneTree
## Assembly Rooms R3, shaping and moving a room by hand (scripts/room/room_handles.gd): the resize and carry maths, where the handles are, which one a hand or a
## laser would take, a face dragged by a hand (its opposite face and the content stay where they are in the world), the floor staying the floor, the 0.5 m
## minimum, overlap stopping a drag, the move bar carrying the room, the grip going to a handle before a part, and the handle showing only near a hand.
## Run: "$GODOT" --headless --path . --script res://tests/room_handles.gd  (see tests/README.md)

const Room := preload("res://scripts/room/room.gd")
const RoomHandles := preload("res://scripts/room/room_handles.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")


func hand_at(parent: Node, pos: Vector3, aim_at: Vector3 = Vector3.INF) -> Node3D:
	var h := Node3D.new()
	parent.add_child(h)
	h.global_position = pos
	if aim_at != Vector3.INF:
		h.global_transform = Transform3D(Basis.looking_at((aim_at - pos).normalized(), Vector3.UP), pos)
	return h


func _initialize() -> void:
	RoomRegistry.clear()
	# --- the maths
	var half := Vector3(1.5, 1.5, 1.5)
	var grown := RoomHandles.resize_face(half, 0, 1.5, 2.0)
	print("SMOKE the +x face dragged 0.5 m out: the room is 0.5 m longer and its middle moves 0.25 m that way: ", (grown["half"] as Vector3).is_equal_approx(Vector3(1.75, 1.5, 1.5)) and is_equal_approx(grown["shift"], 0.25))
	var pinched := RoomHandles.resize_face(half, 0, 1.5, -1.2)
	print("SMOKE ...dragged in past the other side it stops at the 0.5 m minimum (the opposite face stays): ", is_equal_approx((pinched["half"] as Vector3).x, 0.25) and is_equal_approx(pinched["shift"], -1.25))
	var minus := RoomHandles.resize_face(half, 1, -1.5, -2.5)
	print("SMOKE the -x face dragged out works the same way round (4 m, its middle 0.5 m the other way): ", (minus["half"] as Vector3).is_equal_approx(Vector3(2.0, 1.5, 1.5)) and is_equal_approx(minus["shift"], -0.5))
	print("SMOKE faces are numbered +x -x +y -y +z -z, two to an axis: ", RoomHandles.axis_of(0) == 0 and RoomHandles.axis_of(3) == 1 and RoomHandles.axis_of(5) == 2 and RoomHandles.sign_of(2) == 1.0 and RoomHandles.sign_of(3) == -1.0)
	print("SMOKE there is a limit on size too: ", is_equal_approx((RoomHandles.resize_face(half, 0, 1.5, 500.0)["half"] as Vector3).x, RoomHandles.MAX_SIZE_M * 0.5))
	var start := Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0))
	var carried := RoomHandles.moved_transform(start, Vector3(0, 1, 2), 0.0, Vector3(1, 1.3, 3), 0.0)
	print("SMOKE carrying the room: it goes where the hand goes on the floor and stays upright at the same height: ", carried.origin.is_equal_approx(Vector3(1, 1.5, 1)) and carried.basis.is_equal_approx(Basis.IDENTITY))
	var turned := RoomHandles.moved_transform(start, Vector3(0, 1, 2), 0.0, Vector3(0, 1, 2), PI / 2.0)
	print("SMOKE ...and turning the hand turns the room about the hand: ", (turned.basis * Vector3(0, 0, -1)).is_equal_approx(Basis(Vector3.UP, PI / 2.0) * Vector3(0, 0, -1)) and turned.origin.is_equal_approx(Vector3(-2, 1.5, 2)))

	# --- a room with its handles
	var holder := Node3D.new()
	root.add_child(holder)
	var glb := RoomManagerTest.new().glb_for([{"pos": Vector3.ZERO, "size": Vector3(100, 100, 100), "owner": "S", "occ": "k1"}])
	var room := Room.new()
	room.build(glb, Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), Vector3(3, 3, 3), "S", "Sub")
	holder.add_child(room)
	room.register(RoomRegistry.add_room(room.volume))
	await process_frame
	var handles: Node3D = room.handles
	print("SMOKE a room has handles on its five sides and roof, none on the floor, plus the move bar: ", handles != null and handles._handles.size() == 6 and not handles._handles.has(3) and handles._handles.has(RoomHandles.MOVE))
	print("SMOKE the +x handle is just outside the +x wall at its middle, the roof's above the roof: ", handles.handle_world_position(0).is_equal_approx(Vector3(1.53, 1.5, 0)) and handles.handle_world_position(2).is_equal_approx(Vector3(0, 3.03, 0)))
	print("SMOKE the move bar is on the floor at the front edge, outside the +z wall (the user's side): ", handles.handle_world_position(RoomHandles.MOVE).is_equal_approx(Vector3(0, 0.03, 1.64)))
	var content_before := room.content_root.global_transform

	# --- which handle a hand or a laser would take
	var near_x := hand_at(holder, Vector3(1.55, 1.5, 0.05))
	var near_z := hand_at(holder, Vector3(0.0, 1.5, 1.6))
	var nowhere := hand_at(holder, Vector3(0.0, 1.5, 0.0), Vector3(1.4, 1.0, 1.4)) # (its laser points at a corner, between the handles)
	print("SMOKE a hand at a handle takes it, a hand in the middle of the room takes nothing: ", handles.candidate_for(near_x) == 0 and handles.candidate_for(near_z) == 4 and handles.candidate_for(nowhere) == -1)
	var lasering := hand_at(holder, Vector3(0.0, 1.4, 6.0), Vector3(0.0, 3.03, 0.0))
	var missing := hand_at(holder, Vector3(0.0, 1.4, 6.0), Vector3(0.9, 3.03, 0.0))
	print("SMOKE a laser aimed at a handle takes it from across the room; one aimed beside it doesn't: ", handles.candidate_for(lasering) == 2 and handles.candidate_for(missing) == -1)

	# --- dragging a face
	var hand := hand_at(holder, Vector3(1.53, 1.5, 0.0))
	var minus_x_world: Vector3 = room.volume.xform * Vector3(-1.5, 0, 0)
	print("SMOKE gripping a handle takes it, marks the hand (so a whole-room drag stays out of it) and lights that face: ", handles.try_grab(hand) and handles.held_by(hand) and hand.get_meta("room_handle_held") == true and (room.get_node("Glass").material_override as ShaderMaterial).get_shader_parameter("active_face") == 0)
	var other := hand_at(holder, Vector3(-1.53, 1.5, 0.0))
	print("SMOKE ...and a second hand can't take another while one is held: ", not handles.try_grab(other))
	hand.global_position = Vector3(2.03, 1.5, 0.0)
	handles.update_drag()
	print("SMOKE dragging it 0.5 m out makes the room 3.5 m long, middle 0.25 m along: ", room.volume.half.is_equal_approx(Vector3(1.75, 1.5, 1.5)) and room.volume.xform.origin.is_equal_approx(Vector3(0.25, 1.5, 0)))
	print("SMOKE ...the opposite wall has not moved in the world and nor has the content: ", (room.volume.xform * Vector3(-1.75, 0, 0)).is_equal_approx(minus_x_world) and room.content_root.global_transform.is_equal_approx(content_before))
	print("SMOKE ...the walls, the glass and the shader follow, the handle stays on the wall, and the clip's rows are updated: ", (room.get_node("Glass").mesh as BoxMesh).size.is_equal_approx(Vector3(3.5, 3, 3)) and handles.handle_world_position(0).is_equal_approx(Vector3(2.03, 1.5, 0)) and absf(RoomRegistry.pack_image().get_pixel(3, room.volume.slot).r - 1.75) < 0.0001)
	handles.release(hand)
	print("SMOKE letting go frees the hand and unlights the face: ", not handles.is_held() and hand.get_meta("room_handle_held") == false and (room.get_node("Glass").material_override as ShaderMaterial).get_shader_parameter("active_face") == -1)

	# --- the roof: the floor stays the floor
	var roof_hand := hand_at(holder, handles.handle_world_position(2))
	handles.try_grab(roof_hand)
	roof_hand.global_position += Vector3(0, 1.0, 0)
	handles.update_drag()
	print("SMOKE dragging the roof up 1 m makes the room 4 m tall with its floor still on the floor (middle 2 m up): ", absf(room.volume.half.y - 2.0) < 0.001 and absf(room.volume.xform.origin.y - 2.0) < 0.001)
	roof_hand.global_position += Vector3(0, -9.0, 0)
	handles.update_drag()
	print("SMOKE ...and dragged right down it stops at 0.5 m (the floor and its middle at 0.25 m): ", absf(room.volume.half.y - 0.25) < 0.001 and absf(room.volume.xform.origin.y - 0.25) < 0.001)
	handles.release(roof_hand)

	# --- overlap stops a drag
	room.set_box(Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), Vector3(1.5, 1.5, 1.5))
	var neighbour := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(3.2, 1.5, 0)), Vector3(3, 3, 3))
	RoomRegistry.add_room(neighbour)
	var pusher := hand_at(holder, handles.handle_world_position(0))
	handles.try_grab(pusher)
	pusher.global_position += Vector3(0.1, 0, 0)
	handles.update_drag()
	var ok_half: float = room.volume.half.x
	pusher.global_position += Vector3(0.6, 0, 0)
	handles.update_drag()
	print("SMOKE a drag that would overlap the next room stops at the last size that didn't (0.1 m out was fine, 0.7 m is held): ", is_equal_approx(ok_half, 1.55) and is_equal_approx(room.volume.half.x, 1.55))
	handles.release(pusher)
	RoomRegistry.remove_room(neighbour)

	# --- the move bar
	room.set_box(Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), Vector3(1.5, 1.5, 1.5))
	var mover := hand_at(holder, handles.handle_world_position(RoomHandles.MOVE))
	var content_offset: Vector3 = room.content_root.global_position - room.global_position
	handles.try_grab(mover)
	mover.global_position += Vector3(2.0, 0.4, -1.0)
	handles.update_drag()
	print("SMOKE carrying the room by the bar moves it along the floor (not up) and the content goes with it: ", room.volume.xform.origin.is_equal_approx(Vector3(2.0, 1.5, -1.0)) and room.content_root.global_position.is_equal_approx(room.global_position + content_offset))
	mover.global_transform = Transform3D(Basis(Vector3.UP, PI / 2.0), mover.global_position)
	handles.update_drag()
	print("SMOKE ...and turning the hand turns the room, which stays upright: ", absf(room.volume.xform.basis.get_euler().x) < 0.001 and absf(room.volume.xform.basis.get_euler().z) < 0.001 and absf(absf(room.volume.xform.basis.get_euler().y) - PI / 2.0) < 0.01)
	handles.release(mover)

	# --- the grip goes to a handle before anything else
	var controller := XRController3D.new()
	controller.tracker = &"right_hand"
	controller.set_script(load("res://scripts/controller.gd"))
	holder.add_child(controller)
	await process_frame
	controller.global_position = handles.handle_world_position(5)
	controller._on_button_pressed("grip_click") # the real press path: handles are asked before a part
	print("SMOKE a real controller's grip at a handle takes the handle, not a part: ", handles.held_by(controller) and controller.held_node == null and controller.get_meta("room_handle_held") == true)
	var gesture := TwoHandModel.new()
	holder.add_child(gesture)
	print("SMOKE ...and the whole-model / whole-room gesture treats that hand as busy: ", not gesture._hand_free_ignoring_button(controller))
	controller._on_button_released("grip_click")
	print("SMOKE letting go of the grip lets go of the handle: ", not handles.is_held() and gesture._hand_free_ignoring_button(controller))

	# --- handles show near hands
	handles.update_visibility([handles.handle_world_position(0) + Vector3(0.3, 0, 0)])
	print("SMOKE a face handle shows when a hand is near it and hides otherwise (the move bar always shows): ", handles._handles[0].visible and not handles._handles[1].visible and not handles._handles[4].visible and handles._handles[RoomHandles.MOVE].visible)
	handles.update_visibility([])
	print("SMOKE ...and with no hand near they all hide: ", not handles._handles[0].visible)
	RoomRegistry.clear()
	quit()
