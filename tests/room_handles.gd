extends SceneTree
## Assembly Rooms R3, shaping and moving a room by hand (scripts/room/room_handles.gd): eight CORNER handles and the move bar. The resize and carry maths, where the
## handles are, which one a hand or a laser would take, a corner dragged by a hand (its opposite corner and the content stay where they are in the world), a floor
## corner leaving the height alone, the 0.5 m minimum, overlap stopping a drag, the move bar carrying the room, the grip going to a handle before a part, and
## only the corner nearest a hand showing.
## Run: "$GODOT" --headless --path . --script res://tests/room_handles.gd  (see tests/README.md)

const Room := preload("res://scripts/room/room.gd")
const RoomHandles := preload("res://scripts/room/room_handles.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd")
const RoomManagerTest := preload("res://tests/room_manager.gd")

const TOP_PX := 0b111 ## corner 7: +x, +y (top), +z
const FLOOR_PX := 0b101 ## corner 5: +x, floor, +z


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
	print("SMOKE corners are numbered by bits: +x, top, +z (so 7 is the top corner on the user's side, 5 the floor corner under it): ", RoomHandles.corner_sign(7) == Vector3(1, 1, 1) and RoomHandles.corner_sign(0) == Vector3(-1, -1, -1) and RoomHandles.corner_sign(5) == Vector3(1, -1, 1) and RoomHandles.is_top(7) and not RoomHandles.is_top(5))
	print("SMOKE a top corner moves three faces, a floor corner two (the floor never moves): ", RoomHandles.faces_of(7).size() == 3 and RoomHandles.faces_of(5).size() == 2 and RoomHandles.faces_mask(7) == (1 | 4 | 16) and RoomHandles.faces_mask(0) == (2 | 32))
	var out := RoomHandles.resize_corner(half, TOP_PX, Vector3(1.5, 1.5, 1.5), Vector3(2.0, 2.5, 1.0))
	print("SMOKE a top corner dragged out 0.5 m, up 1 m and in 0.5 m: 3.5 long, 4 tall, 2.5 deep, the middle shifted half of each: ", (out["half"] as Vector3).is_equal_approx(Vector3(1.75, 2.0, 1.25)) and (out["shift"] as Vector3).is_equal_approx(Vector3(0.25, 0.5, -0.25)))
	var floor_drag := RoomHandles.resize_corner(half, FLOOR_PX, Vector3(1.5, -1.5, 1.5), Vector3(2.0, 3.0, 2.0))
	print("SMOKE a floor corner leaves the height alone however the hand moves up or down (two floor axes only): ", (floor_drag["half"] as Vector3).is_equal_approx(Vector3(1.75, 1.5, 1.75)) and is_equal_approx(floor_drag["shift"].y, 0.0))
	var minus := RoomHandles.resize_corner(half, 0, Vector3(-1.5, -1.5, -1.5), Vector3(-2.5, -1.5, -2.0))
	print("SMOKE the far-side floor corner works the other way round (the -x, -z sides grow, the room's middle shifts that way): ", (minus["half"] as Vector3).is_equal_approx(Vector3(2.0, 1.5, 1.75)) and (minus["shift"] as Vector3).is_equal_approx(Vector3(-0.5, 0.0, -0.25)))
	var pinched := RoomHandles.resize_corner(half, TOP_PX, Vector3(1.5, 1.5, 1.5), Vector3(-5.0, -5.0, 1.5))
	print("SMOKE dragged in past the opposite corner each axis stops at the 0.5 m minimum, and an axis the hand did not move is unchanged: ", (pinched["half"] as Vector3).is_equal_approx(Vector3(0.25, 0.25, 1.5)))
	print("SMOKE there is a limit on size too: ", is_equal_approx((RoomHandles.resize_corner(half, 7, Vector3(1.5, 1.5, 1.5), Vector3(500, 1.5, 1.5))["half"] as Vector3).x, RoomHandles.MAX_SIZE_M * 0.5))
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
	print("SMOKE a room has a handle on each of its eight corners and the move bar, and no handles on the faces: ", handles != null and handles._handles.size() == 9 and handles._handles.has(RoomHandles.MOVE) and RoomHandles.CORNERS.size() == 8)
	print("SMOKE each handle is at its corner: top +x +z at (1.5, 3, 1.5), floor -x -z at (-1.5, 0, -1.5): ", handles.handle_world_position(7).is_equal_approx(Vector3(1.5, 3.0, 1.5)) and handles.handle_world_position(0).is_equal_approx(Vector3(-1.5, 0.0, -1.5)))
	print("SMOKE the move bar is on the floor at the front edge, outside the +z wall (the user's side): ", handles.handle_world_position(RoomHandles.MOVE).is_equal_approx(Vector3(0, 0.03, 1.64)))
	var content_before := room.content_root.global_transform

	# --- which handle a hand or a laser would take
	var near_top := hand_at(holder, Vector3(1.55, 2.95, 1.5))
	var near_floor := hand_at(holder, Vector3(-1.5, 0.05, 1.55))
	var nowhere := hand_at(holder, Vector3(0.0, 1.5, 0.0), Vector3(1.4, 1.0, 0.2)) # (its laser points at the middle of a wall, between the corners)
	print("SMOKE a hand at a corner takes it, a hand in the middle of the room takes nothing: ", handles.candidate_for(near_top) == 7 and handles.candidate_for(near_floor) == 4 and handles.candidate_for(nowhere) == -1)
	var lasering := hand_at(holder, Vector3(0.0, 1.4, 7.0), Vector3(-1.5, 3.0, 1.5))
	var missing := hand_at(holder, Vector3(0.0, 1.4, 7.0), Vector3(-0.5, 3.0, 1.5))
	print("SMOKE a laser aimed at a corner takes it from across the room; one aimed beside it doesn't: ", handles.candidate_for(lasering) == 6 and handles.candidate_for(missing) == -1)

	# --- dragging a top corner
	var hand := hand_at(holder, Vector3(1.5, 3.0, 1.5))
	var opposite_world: Vector3 = room.volume.xform * Vector3(-1.5, -1.5, -1.5)
	print("SMOKE gripping a corner takes it, marks the hand (so a whole-room drag stays out of it) and lights the three faces that meet there: ", handles.try_grab(hand) and handles.held_by(hand) and hand.get_meta("room_handle_held") == true and int((room.get_node("Glass").material_override as ShaderMaterial).get_shader_parameter("active_faces")) == (1 | 4 | 16))
	var other := hand_at(holder, Vector3(-1.5, 0.0, -1.5))
	print("SMOKE ...and a second hand can't take another while one is held: ", not handles.try_grab(other))
	hand.global_position = Vector3(2.0, 4.0, 1.0)
	handles.update_drag()
	print("SMOKE dragging it out 0.5 m, up 1 m, in 0.5 m makes the room 3.5 x 4 x 2.5 with its floor still on the floor: ", room.volume.half.is_equal_approx(Vector3(1.75, 2.0, 1.25)) and absf(room.volume.xform.origin.y - 2.0) < 0.001 and room.volume.xform.origin.is_equal_approx(Vector3(0.25, 2.0, -0.25)))
	print("SMOKE ...the opposite corner has not moved in the world and nor has the content: ", (room.volume.xform * Vector3(-1.75, -2.0, -1.25)).is_equal_approx(opposite_world) and room.content_root.global_transform.is_equal_approx(content_before))
	print("SMOKE ...the walls, the glass, the handles and the clip's rows follow (the held handle is under the hand): ", (room.get_node("Glass").mesh as BoxMesh).size.is_equal_approx(Vector3(3.5, 4, 2.5)) and handles.handle_world_position(7).is_equal_approx(Vector3(2.0, 4.0, 1.0)) and absf(RoomRegistry.pack_image().get_pixel(3, room.volume.slot).r - 1.75) < 0.0001 and absf(RoomRegistry.pack_image().get_pixel(3, room.volume.slot).g - 2.0) < 0.0001)
	handles.release(hand)
	print("SMOKE letting go frees the hand and unlights the faces: ", not handles.is_held() and hand.get_meta("room_handle_held") == false and int((room.get_node("Glass").material_override as ShaderMaterial).get_shader_parameter("active_faces")) == 0)
	room.set_box(Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), Vector3(1.5, 1.5, 1.5))

	# --- a floor corner: the height stays
	var floor_hand := hand_at(holder, handles.handle_world_position(5))
	handles.try_grab(floor_hand)
	floor_hand.global_position += Vector3(0.5, 2.0, 0.5) # (up as well: ignored)
	handles.update_drag()
	print("SMOKE dragging a floor corner changes the two floor dimensions only, whatever the hand does in height: ", room.volume.half.is_equal_approx(Vector3(1.75, 1.5, 1.75)) and absf(room.volume.xform.origin.y - 1.5) < 0.001)
	floor_hand.global_position += Vector3(-9.0, 0.0, -9.0)
	handles.update_drag()
	print("SMOKE ...and dragged right across, each floor dimension stops at 0.5 m: ", absf(room.volume.half.x - 0.25) < 0.001 and absf(room.volume.half.z - 0.25) < 0.001 and absf(room.volume.half.y - 1.5) < 0.001)
	handles.release(floor_hand)

	# --- overlap stops a drag
	room.set_box(Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)), Vector3(1.5, 1.5, 1.5))
	var neighbour := RoomVolume.make(Transform3D(Basis.IDENTITY, Vector3(3.2, 1.5, 0)), Vector3(3, 3, 3))
	RoomRegistry.add_room(neighbour)
	var pusher := hand_at(holder, handles.handle_world_position(7))
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
	room.move_box(Transform3D(Basis.IDENTITY, Vector3(0, 1.5, 0)))

	# --- the grip goes to a handle before anything else
	var controller := XRController3D.new()
	controller.tracker = &"right_hand"
	controller.set_script(load("res://scripts/controller.gd"))
	holder.add_child(controller)
	await process_frame
	controller.global_position = handles.handle_world_position(6)
	controller._on_button_pressed("grip_click") # the real press path: handles are asked before a part
	print("SMOKE a real controller's grip at a corner takes the handle, not a part: ", handles.held_by(controller) and controller.held_node == null and controller.get_meta("room_handle_held") == true)
	var gesture := TwoHandModel.new()
	holder.add_child(gesture)
	print("SMOKE ...and the whole-model / whole-room gesture treats that hand as busy: ", not gesture._hand_free_ignoring_button(controller))
	controller._on_button_released("grip_click")
	print("SMOKE letting go of the grip lets go of the handle: ", not handles.is_held() and gesture._hand_free_ignoring_button(controller))

	# --- only the corner nearest a hand shows
	handles.update_visibility([handles.handle_world_position(7) + Vector3(0.3, 0.2, 0.1)])
	var shown := 0
	for c in RoomHandles.CORNERS:
		shown += 1 if handles._handles[c].visible else 0
	print("SMOKE only the corner nearest a hand shows (one of eight), and the move bar always does: ", shown == 1 and handles._handles[7].visible and handles._handles[RoomHandles.MOVE].visible)
	handles.update_visibility([handles.handle_world_position(7) + Vector3(0.3, 0.2, 0.1), handles.handle_world_position(0) + Vector3(-0.2, 0.0, 0.0)])
	print("SMOKE ...two hands near two corners show both: ", handles._handles[7].visible and handles._handles[0].visible)
	handles.update_visibility([Vector3(50, 50, 50)])
	print("SMOKE ...and with no hand near, none shows: ", not handles._handles[7].visible and not handles._handles[0].visible)
	RoomRegistry.clear()
	quit()
