extends Node3D
## The handles that let you shape and move an Assembly Room by hand (docs/assembly-rooms-scope.md, section 6):
##   * eight CORNER handles. Grip one with a hand, or aim the laser at it and grip, and that corner follows your hand while the OPPOSITE corner stays where it is
##     in the world; the faces that meet at the corner move with it, the content does not move or scale. A top corner moves the room's three dimensions at
##     once; a floor corner moves only the two along the floor (a room always stands on the floor), so there is no way to lift one. A side can't go under 0.5 m
##     (RoomVolume.MIN_DRAG_SIZE_M) and a drag that would overlap another room stops at the last size that didn't. Drag along one edge to change one dimension.
##   * a MOVE bar on the floor at the front edge. Grip it and the room goes where your hand goes on the floor and turns as your hand turns about the vertical,
##     content and all, like carrying a tray.
## Only the corner nearest a hand shows (and the one being held), so the room is not cluttered. The maths is in static functions (resize_corner, moved_transform)
## so it can be tested without hands; controller.gd asks every handle node in the "room_handles" group to try_grab / release, before a grip would go to a part.

const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")

const MAX_SIZE_M := 40.0
const SHOW_DISTANCE_M := 1.1 ## the corner nearest a hand shows when it is within this
const GRAB_REACH_M := 0.18 ## a hand's origin this near a handle takes it
const LASER_REACH_M := 0.12 ## or a laser passing this near it (within LASER_RANGE_M)
const LASER_RANGE_M := 8.0

## Corner index: bit 0 set = +x (clear = -x), bit 1 = +y (the top; clear = the floor), bit 2 = +z (the user's side; clear = -z). 0..7.
## Face index (the shader's `active_faces` bits): 0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z.
const CORNERS := [0, 1, 2, 3, 4, 5, 6, 7]
const MOVE := 99 ## the "corner" number of the move bar

var room: Node3D
var _handles: Dictionary = {} ## corner (or MOVE) -> MeshInstance3D
var _material: StandardMaterial3D
var _held := {} ## {hand, corner, grab_xform, grab_half, grab_point | grab_hand, grab_yaw} while a handle is held; empty otherwise


static func is_top(corner: int) -> bool:
	return corner & 2 != 0


static func corner_sign(corner: int) -> Vector3:
	## +1 / -1 on each axis: which corner of the box this is.
	return Vector3(1.0 if corner & 1 else -1.0, 1.0 if corner & 2 else -1.0, 1.0 if corner & 4 else -1.0)


static func faces_of(corner: int) -> Array:
	## The faces that move when this corner is dragged: its x and z faces always, its y face only for a top corner (the floor does not move).
	var faces := [0 if corner & 1 else 1, 4 if corner & 4 else 5]
	if is_top(corner):
		faces.append(2)
	return faces


static func faces_mask(corner: int) -> int:
	var mask := 0
	for f in faces_of(corner):
		mask |= 1 << f
	return mask


static func resize_corner(half: Vector3, corner: int, grab_point: Vector3, now_point: Vector3, min_size: float = RoomVolume.MIN_DRAG_SIZE_M, max_size: float = MAX_SIZE_M) -> Dictionary:
	## One corner dragged: the hand's position (in the room's frame at the moment of the grab) went from `grab_point` to `now_point`. Each moving axis is resized
	## the way one face is: the corner follows the hand on that axis, the opposite corner stays, clamped to the minimum and maximum size. A floor corner leaves
	## the height alone. {half: new half extents, shift: where the new middle is, as a vector in the old frame (metres)}.
	var signs := corner_sign(corner)
	var new_half := half
	var shift := Vector3.ZERO
	for axis in 3:
		if axis == 1 and not is_top(corner):
			continue
		var s: float = signs[axis]
		var f0: float = s * half[axis]
		var f: float = f0 + (now_point[axis] - grab_point[axis])
		var g := -f0
		var size := clampf((f - g) * s, min_size, max_size)
		f = g + s * size
		new_half[axis] = size * 0.5
		shift[axis] = (f + g) * 0.5
	return {"half": new_half, "shift": shift}


static func moved_transform(grab_xform: Transform3D, grab_hand: Vector3, grab_yaw: float, hand: Vector3, yaw: float) -> Transform3D:
	## The room carried on the floor: it goes where the hand went and turns about the vertical by how far the hand turned, about the hand (a tray). Stays
	## upright and at the same height.
	var turn := Basis(Vector3.UP, yaw - grab_yaw)
	var origin := hand + turn * (grab_xform.origin - grab_hand)
	origin.y = grab_xform.origin.y
	return Transform3D(turn * grab_xform.basis, origin)


static func hand_yaw(hand: Node3D) -> float:
	## Which way the hand points, flattened, as an angle about the vertical.
	var f := -hand.global_transform.basis.z
	return atan2(-f.x, -f.z)


func setup(p_room: Node3D) -> void:
	room = p_room
	add_to_group("room_handles")
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.albedo_color = Color(room.colour.r, room.colour.g, room.colour.b, 0.85)
	for corner in CORNERS:
		var ball := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.07
		sphere.height = 0.14
		sphere.radial_segments = 16
		sphere.rings = 8
		sphere.material = _material
		ball.mesh = sphere
		ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ball.visible = false
		add_child(ball)
		_handles[corner] = ball
	var bar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.025, 0.09)
	box.material = _material
	bar.mesh = box
	bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bar)
	_handles[MOVE] = bar
	refresh()


func refresh() -> void:
	## Puts every handle where the box's corners are now.
	var h: Vector3 = room.volume.half
	for corner in CORNERS:
		(_handles[corner] as Node3D).position = corner_sign(corner) * h
	(_handles[MOVE] as Node3D).position = Vector3(0.0, -h.y + 0.03, h.z + 0.14)


func handle_world_position(handle: int) -> Vector3:
	return (_handles[handle] as Node3D).global_position


func is_held() -> bool:
	return not _held.is_empty()


func held_by(hand: Node) -> bool:
	return not _held.is_empty() and _held["hand"] == hand


func candidate_for(hand: Node3D) -> int:
	## Which handle this hand would take now: the nearest within reach of the hand itself, else the one nearest the laser's line; -1 for none.
	var best := -1
	var best_d := INF
	for handle in _handles:
		var d: float = hand.global_position.distance_to(handle_world_position(handle))
		if d <= GRAB_REACH_M and d < best_d:
			best = handle
			best_d = d
	if best != -1:
		return best
	var origin := hand.global_position
	var dir := -hand.global_transform.basis.z.normalized()
	for handle in _handles:
		var p := handle_world_position(handle)
		var along := (p - origin).dot(dir)
		if along < 0.1 or along > LASER_RANGE_M:
			continue
		var d := (p - (origin + dir * along)).length()
		if d <= LASER_REACH_M and d < best_d:
			best = handle
			best_d = d
	return best


func try_grab(hand: Node3D) -> bool:
	## A grip: takes the handle this hand is at (or aiming at). True if it did, so the grip is not also a part grab or a whole-room move.
	if is_held() or room == null or not is_instance_valid(room):
		return false
	var handle := candidate_for(hand)
	if handle == -1:
		return false
	var v: RoomVolume = room.volume
	_held = {"hand": hand, "corner": handle, "grab_xform": v.xform, "grab_half": v.half}
	if handle == MOVE:
		_held["grab_hand"] = hand.global_position
		_held["grab_yaw"] = hand_yaw(hand)
	else:
		_held["grab_point"] = v.xform.affine_inverse() * hand.global_position
		room.set_active_faces(faces_mask(handle))
	hand.set_meta("room_handle_held", true) # two_hand_model.gd: this grip is not a whole-model / whole-room drag
	return true


func release(hand: Node3D) -> bool:
	if _held.is_empty() or _held["hand"] != hand:
		return false
	hand.set_meta("room_handle_held", false)
	room.set_active_faces(0)
	_held = {}
	return true


func update_drag() -> void:
	## Each frame while a handle is held: the box (or the whole room) follows the hand, unless that would overlap another room.
	if _held.is_empty():
		return
	var hand: Node3D = _held["hand"]
	if not is_instance_valid(hand) or not is_instance_valid(room):
		_held = {}
		return
	var v: RoomVolume = room.volume
	if _held["corner"] == MOVE:
		var moved := moved_transform(_held["grab_xform"], _held["grab_hand"], _held["grab_yaw"], hand.global_position, hand_yaw(hand))
		var probe := RoomVolume.make(moved, v.half * 2.0)
		if not RoomRegistry.would_overlap(probe, v):
			room.move_box(moved)
		return
	var grab_xform: Transform3D = _held["grab_xform"]
	var now_point: Vector3 = grab_xform.affine_inverse() * hand.global_position # in the frame the grab was made in, whatever the box has done since
	var result := resize_corner(_held["grab_half"], _held["corner"], _held["grab_point"], now_point)
	var new_xform := Transform3D(grab_xform.basis, grab_xform.origin + grab_xform.basis * (result["shift"] as Vector3))
	var probe2 := RoomVolume.make(new_xform, (result["half"] as Vector3) * 2.0)
	if not RoomRegistry.would_overlap(probe2, v):
		room.set_box(new_xform, result["half"])


func update_visibility(hand_positions: Array) -> void:
	## The corner nearest each hand shows when the hand is within reach of the room's corners (and the held one stays); the move bar always shows.
	var shown := {}
	if is_held() and _held["corner"] != MOVE:
		shown[_held["corner"]] = true
	for p in hand_positions:
		var best := -1
		var best_d: float = SHOW_DISTANCE_M
		for corner in CORNERS:
			var d: float = (p as Vector3).distance_to((_handles[corner] as Node3D).global_position)
			if d <= best_d:
				best = corner
				best_d = d
		if best != -1:
			shown[best] = true
	for corner in CORNERS:
		(_handles[corner] as Node3D).visible = shown.has(corner)


func _process(_delta: float) -> void:
	update_drag()
