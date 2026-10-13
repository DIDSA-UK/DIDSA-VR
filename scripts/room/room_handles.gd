extends Node3D
## The handles that let you shape and move an Assembly Room by hand (docs/assembly-rooms-scope.md, section 6):
##   * five FACE handles, at the middle of the sides and the roof (there is deliberately none on the floor: a room always stands on the floor). Grip one with a
##     hand, or aim the laser at it and grip, and that face follows your hand along its axis while the opposite face stays where it is in the world; the
##     content does not move or scale. A side can't go under 0.5 m (RoomVolume.MIN_DRAG_SIZE_M) and a drag that would overlap another room stops at the
##     last size that didn't.
##   * a MOVE bar on the floor at the front edge. Grip it and the room goes where your hand goes on the floor and turns as your hand turns about the vertical,
##     content and all, like carrying a tray.
## Handles show when a hand is near them, so the room is not cluttered. The maths is in static functions (resize_face, moved_transform) so it can be tested
## without hands; controller.gd asks every handle node in the "room_handles" group to try_grab / release, before a grip would go to a part.

const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")

const MAX_SIZE_M := 40.0
const SHOW_DISTANCE_M := 1.1 ## a face handle shows when a hand is this near it
const GRAB_REACH_M := 0.18 ## a hand's origin this near a handle takes it
const LASER_REACH_M := 0.12 ## or a laser passing this near it (within LASER_RANGE_M)
const LASER_RANGE_M := 8.0
const FACE_NAMES := ["+x", "-x", "+y", "-y", "+z", "-z"]

## Face index: 0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z (the shader's `active_face` uses the same).
## The floor face (3) has no handle.
const HANDLED_FACES := [0, 1, 2, 4, 5]
const MOVE := 99 ## the "face" number of the move bar

var room: Node3D
var _handles: Dictionary = {} ## face (or MOVE) -> MeshInstance3D
var _material: StandardMaterial3D
var _held := {} ## {hand, face, grab_xform, grab_half, grab_coord | grab_hand_pos, grab_yaw} while a handle is held; empty otherwise


static func axis_of(face: int) -> int:
	return face / 2


static func sign_of(face: int) -> float:
	return 1.0 if face % 2 == 0 else -1.0


static func resize_face(half: Vector3, face: int, grab_coord: float, now_coord: float, min_size: float = RoomVolume.MIN_DRAG_SIZE_M, max_size: float = MAX_SIZE_M) -> Dictionary:
	## One face dragged: the hand's coordinate along the face's axis (in the room's frame at the moment of the grab) went from `grab_coord` to `now_coord`.
	## The face follows it, the opposite face stays; {half: new half extents, shift: where the new middle is along the axis, in the old frame (metres)}.
	var axis := axis_of(face)
	var s := sign_of(face)
	var f0 := s * half[axis]
	var f := f0 + (now_coord - grab_coord)
	var g := -f0
	var size := clampf((f - g) * s, min_size, max_size)
	f = g + s * size
	var new_half := half
	new_half[axis] = size * 0.5
	return {"half": new_half, "shift": (f + g) * 0.5}


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
	for face in HANDLED_FACES:
		var disc := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.09
		cyl.bottom_radius = 0.09
		cyl.height = 0.012
		cyl.material = _material
		disc.mesh = cyl
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		disc.visible = false
		add_child(disc)
		_handles[face] = disc
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
	## Puts every handle where the box's faces are now.
	var h: Vector3 = room.volume.half
	for face in HANDLED_FACES:
		var axis := axis_of(face)
		var normal := Vector3.ZERO
		normal[axis] = sign_of(face)
		var node: MeshInstance3D = _handles[face]
		node.position = normal * (h[axis] + 0.03)
		node.basis = Basis(Quaternion(Vector3.UP, normal)) # the disc lies flat on the face
	var bar: MeshInstance3D = _handles[MOVE]
	bar.position = Vector3(0.0, -h.y + 0.03, h.z + 0.14)


func handle_world_position(face: int) -> Vector3:
	return (_handles[face] as Node3D).global_position


func is_held() -> bool:
	return not _held.is_empty()


func held_by(hand: Node) -> bool:
	return not _held.is_empty() and _held["hand"] == hand


func candidate_for(hand: Node3D) -> int:
	## Which handle this hand would take now: the nearest within reach of the hand itself, else the one nearest the laser's line; -1 for none.
	var best := -1
	var best_d := INF
	for face in _handles:
		var d: float = hand.global_position.distance_to(handle_world_position(face))
		if d <= GRAB_REACH_M and d < best_d:
			best = face
			best_d = d
	if best != -1:
		return best
	var origin := hand.global_position
	var dir := -hand.global_transform.basis.z.normalized()
	for face in _handles:
		var p := handle_world_position(face)
		var along := (p - origin).dot(dir)
		if along < 0.1 or along > LASER_RANGE_M:
			continue
		var d := (p - (origin + dir * along)).length()
		if d <= LASER_REACH_M and d < best_d:
			best = face
			best_d = d
	return best


func try_grab(hand: Node3D) -> bool:
	## A grip: takes the handle this hand is at (or aiming at). True if it did, so the grip is not also a part grab or a whole-room move.
	if is_held() or room == null or not is_instance_valid(room):
		return false
	var face := candidate_for(hand)
	if face == -1:
		return false
	var v: RoomVolume = room.volume
	_held = {"hand": hand, "face": face, "grab_xform": v.xform, "grab_half": v.half}
	if face == MOVE:
		_held["grab_hand"] = hand.global_position
		_held["grab_yaw"] = hand_yaw(hand)
	else:
		_held["grab_coord"] = _coord_along(face, hand.global_position)
		room.set_active_face(face)
	hand.set_meta("room_handle_held", true) # two_hand_model.gd: this grip is not a whole-model / whole-room drag
	return true


func release(hand: Node3D) -> bool:
	if _held.is_empty() or _held["hand"] != hand:
		return false
	hand.set_meta("room_handle_held", false)
	room.set_active_face(-1)
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
	if _held["face"] == MOVE:
		var moved := moved_transform(_held["grab_xform"], _held["grab_hand"], _held["grab_yaw"], hand.global_position, hand_yaw(hand))
		var probe := RoomVolume.make(moved, v.half * 2.0)
		if not RoomRegistry.would_overlap(probe, v):
			room.move_box(moved)
		return
	var face: int = _held["face"]
	var result := resize_face(_held["grab_half"], face, _held["grab_coord"], _coord_along(face, hand.global_position))
	var axis := axis_of(face)
	var grab_xform: Transform3D = _held["grab_xform"]
	var new_origin: Vector3 = grab_xform.origin + grab_xform.basis[axis] * float(result["shift"])
	var new_xform := Transform3D(grab_xform.basis, new_origin)
	var probe2 := RoomVolume.make(new_xform, (result["half"] as Vector3) * 2.0)
	if not RoomRegistry.would_overlap(probe2, v):
		room.set_box(new_xform, result["half"])


func update_visibility(hand_positions: Array) -> void:
	## Face handles show when a hand is near them (or one is held); the move bar always shows.
	for face in HANDLED_FACES:
		var node: MeshInstance3D = _handles[face]
		var show: bool = is_held() and _held["face"] == face
		if not show:
			for p in hand_positions:
				if (p as Vector3).distance_to(node.global_position) <= SHOW_DISTANCE_M:
					show = true
					break
		node.visible = show


func _process(_delta: float) -> void:
	update_drag()


func _coord_along(face: int, world_point: Vector3) -> float:
	## The point's coordinate along the face's axis, in the box's frame as it was when the handle was grabbed (while grabbing: as it is now).
	var xf: Transform3D = _held["grab_xform"] if not _held.is_empty() else room.volume.xform
	return (xf.affine_inverse() * world_point)[axis_of(face)]
