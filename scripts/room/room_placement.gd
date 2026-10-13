extends RefCounted
## Where a new room goes: in front of the user, standing on the floor, turned to the way they face, clear of every other room. Pure maths (no nodes),
## so tests/room_manager.gd can check it. A room never overlaps another (docs/assembly-rooms-scope.md); if the spot straight ahead is taken it tries
## further along the user's right and left, then further out.

const RoomVolume := preload("res://scripts/room/room_volume.gd")

const NEAR_GAP_M := 1.2 ## from the user to the room's near wall
const SIDE_GAP_M := 0.5 ## left between neighbouring rooms
const RINGS := 4 ## how many steps further out to try
const SIDE_STEPS := 4 ## and how many rooms' widths to either side of straight ahead


static func find_spot(eye: Vector3, forward: Vector3, size: Vector3, others: Array) -> Variant:
	## A Transform3D for the room's centre and orientation (floor at y = 0), or null if nothing was clear.
	var heading := Vector3(forward.x, 0.0, forward.z)
	if heading.length() < 0.001:
		heading = Vector3(0, 0, -1)
	heading = heading.normalized()
	var right := heading.cross(Vector3.UP).normalized()
	var basis := Basis.looking_at(heading, Vector3.UP)
	for ring in RINGS:
		var ahead := NEAR_GAP_M + size.z * 0.5 + ring * (size.z + SIDE_GAP_M)
		for step in range(0, SIDE_STEPS * 2 + 1):
			var side := 0 if step == 0 else (step + 1) / 2 * (1 if step % 2 == 1 else -1)
			var centre := Vector3(eye.x, 0.0, eye.z) + heading * ahead + right * (side * (size.x + SIDE_GAP_M))
			centre.y = size.y * 0.5
			var candidate := Transform3D(basis, centre)
			var volume := RoomVolume.make(candidate, size)
			var clear := true
			for other in others:
				if other != null and other.overlaps(volume):
					clear = false
					break
			if clear:
				return candidate
	return null
