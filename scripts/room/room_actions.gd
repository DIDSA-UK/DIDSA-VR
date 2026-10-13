extends RefCounted
## What the room console's buttons do, as plain logic on a Room (so it is testable without a panel): scale the content about the room's middle, fit the scale
## to the room, fit the walls to the content, put the walls back to the 3 m cube. Each returns {ok, message}; none talks to the backend (a room's scale and
## walls are how it is viewed, not the document). Scale changes are undoable on the shared stack, like the world's Scale page.

const Room := preload("res://scripts/room/room.gd")
const RoomVolume := preload("res://scripts/room/room_volume.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")

const MIN_MULTIPLE := 0.01 ## the same limits as the room's whole-room gesture (room_manager.gd)
const MAX_MULTIPLE := 2000.0
const FIT_MARGIN_M := 0.25 ## space left round the content when the walls are fitted to it


static func scale_by(room: Node3D, factor: float, stack = null) -> Dictionary:
	## The content scaled by `factor` about the room's middle (so what is in the middle stays there), within the room's limits.
	var current: float = room.content_scale / 0.001
	var wanted := clampf(current * factor, MIN_MULTIPLE, MAX_MULTIPLE)
	if is_equal_approx(wanted, current):
		return {"ok": false, "message": "That is as %s as a room's content goes (%s)." % ["big" if factor > 1.0 else "small", room.scale_text()]}
	return _scale_to_multiple(room, wanted, stack)


static func one_to_one(room: Node3D, stack = null) -> Dictionary:
	if is_equal_approx(room.content_scale, 0.001):
		return {"ok": true, "message": "Already 1:1."}
	return _scale_to_multiple(room, 1.0, stack)


static func fit_scale(room: Node3D, stack = null) -> Dictionary:
	## The content scaled and centred so it fills 70% of the room, as when the room opened.
	var bounds := Room.content_bounds(room.content_root)
	var multiple := clampf(Room.fit_scale(bounds, room.volume.half * 2.0) / 0.001, MIN_MULTIPLE, MAX_MULTIPLE)
	var before: Transform3D = room.content_root.global_transform
	room.refit(multiple * 0.001)
	_push_scale(room, before, room.content_root.global_transform, "fit room scale", stack)
	return {"ok": true, "message": "Fitted to the room: %s." % room.scale_text()}


static func fit_walls(room: Node3D) -> Dictionary:
	## The walls shrink-wrapped to the content with a margin: around it sideways, from the floor to just above it (the floor stays the floor). The content does
	## not move. Refused if that would overlap another room.
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	var inverse: Transform3D = room.volume.xform.affine_inverse()
	for p in room.parts:
		if not is_instance_valid(p) or not (p is MeshInstance3D):
			continue
		var box: AABB = (p as MeshInstance3D).global_transform * (p as MeshInstance3D).get_aabb()
		for i in 8:
			var corner := inverse * box.get_endpoint(i) # in the room's frame
			low = low.min(corner)
			high = high.max(corner)
	if low.x == INF:
		return {"ok": false, "message": "Nothing in the room to fit the walls to."}
	var margin := FIT_MARGIN_M
	var min_size := RoomVolume.MIN_DRAG_SIZE_M
	var width := maxf(high.x - low.x + margin * 2.0, min_size)
	var depth := maxf(high.z - low.z + margin * 2.0, min_size)
	var centre_x := (low.x + high.x) * 0.5
	var centre_z := (low.z + high.z) * 0.5
	# height: from the world floor (y = 0) to just above the content's top, in world terms
	var top_world: float = (room.volume.xform * Vector3(0, high.y, 0)).y + margin
	var height := maxf(top_world, min_size)
	var centre_world: Vector3 = room.volume.xform * Vector3(centre_x, 0.0, centre_z)
	centre_world.y = height * 0.5
	var new_xform := Transform3D(room.volume.xform.basis, centre_world)
	var half := Vector3(width, height, depth) * 0.5
	if RoomRegistry.would_overlap(RoomVolume.make(new_xform, half * 2.0), room.volume):
		return {"ok": false, "message": "The fitted walls would overlap another room."}
	room.set_box(new_xform, half)
	return {"ok": true, "message": "Walls fitted to the content."}


static func reset_walls(room: Node3D) -> Dictionary:
	## Back to the 3 m cube, centred where the room is now, on the floor.
	var size := RoomVolume.spawn_size(Vector3.ZERO)
	var centre: Vector3 = room.volume.xform.origin
	centre.y = size.y * 0.5
	var new_xform := Transform3D(room.volume.xform.basis, centre)
	if RoomRegistry.would_overlap(RoomVolume.make(new_xform, size), room.volume):
		return {"ok": false, "message": "A 3 m cube there would overlap another room."}
	room.set_box(new_xform, size * 0.5)
	return {"ok": true, "message": "Walls back to a 3 m cube."}


static func _scale_to_multiple(room: Node3D, multiple: float, stack) -> Dictionary:
	var before: Transform3D = room.content_root.global_transform
	var pivot: Vector3 = room.volume.xform.origin
	var factor: float = multiple / (room.content_scale / 0.001)
	room.content_root.global_transform = Transform3D(before.basis * factor, pivot + (before.origin - pivot) * factor)
	_push_scale(room, before, room.content_root.global_transform, "room scale", stack)
	return {"ok": true, "message": "Room scale %s." % room.scale_text()}


static func _push_scale(room: Node3D, before: Transform3D, after: Transform3D, label: String, stack) -> void:
	if stack == null or before.is_equal_approx(after):
		return
	var target: Node3D = room.content_root
	stack.push(label,
		func() -> void:
			if is_instance_valid(target):
				target.global_transform = before,
		func() -> void:
			if is_instance_valid(target):
				target.global_transform = after)
