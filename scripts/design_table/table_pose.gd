extends RefCounted
## The numbers behind handling the part that is on the design table: moving it, turning and
## scaling it with two hands, spinning it with the stick, pushing it nearer or farther, and
## deciding whether letting go keeps it on the table. Pure functions over vectors and bases,
## no scene tree, so tests can pin them. Everything is in the CONSOLE's own frame (origin the
## middle of the slab, +X right, +Y up out of the slab, +Z towards you), so moving or turning the
## console itself never changes a thing here, and none of it touches the arena.

const MIN_SCALE := 0.4 ## the part can be scaled down to this multiple of its fitted size...
const MAX_SCALE := 3.0 ## ...and up to this
const SKETCH_MAX_SCALE := 8.0 ## while a sketch is open the top is higher: scaling the part is how you zoom into the sketch
const SPREAD_GAIN := 1.0 ## hands twice as far apart = twice the size (the arena's own two-hand scale uses 3: far too twitchy for a part you're sketching on)


static func clamp_scale(scale: float, top: float = MAX_SCALE) -> float:
	return clampf(scale, MIN_SCALE, top)


static func swing(from_vec: Vector3, to_vec: Vector3) -> Basis:
	## The turn that carries one hand-to-hand line onto the next: shortest arc, so it never rolls about the line.
	var a := from_vec.normalized()
	var b := to_vec.normalized()
	if a.length() < 0.5 or b.length() < 0.5:
		return Basis.IDENTITY
	var d := a.dot(b)
	if d > 0.99999:
		return Basis.IDENTITY
	if d < -0.9999:
		var axis := a.cross(Vector3.UP)
		if axis.length() < 0.001:
			axis = a.cross(Vector3.RIGHT)
		return Basis(axis.normalized(), PI)
	return Basis(Quaternion(a, b))


static func two_hand(prev_left: Vector3, prev_right: Vector3, left: Vector3, right: Vector3, centre: Vector3, rotation: Basis, scale: float, allow_turn: bool = true, top: float = MAX_SCALE) -> Dictionary:
	## One frame of a two-hand grip on the part: it moves with the midpoint between your hands, turns as the line between them
	## swings and grows as they spread, all about the midpoint, as if it were pinned between your fists. Returns the new
	## {centre, rotation, scale}; the scale is clamped, and a spread blocked by the clamp neither moves nor turns it oddly.
	var prev_vec := prev_right - prev_left
	var vec := right - left
	if prev_vec.length() < 0.02 or vec.length() < 0.02:
		return {"centre": centre + ((left + right) - (prev_left + prev_right)) * 0.5, "rotation": rotation, "scale": scale}
	var turn := swing(prev_vec, vec) if allow_turn else Basis.IDENTITY ## a locked part (a sketch is open) only moves and scales
	var wanted := scale * pow(vec.length() / prev_vec.length(), SPREAD_GAIN)
	var new_scale := clamp_scale(wanted, top)
	var factor := new_scale / scale
	var prev_mid := (prev_left + prev_right) * 0.5
	var mid := (left + right) * 0.5
	return {
		"centre": mid + (turn * (centre - prev_mid)) * factor,
		"rotation": (turn * rotation).orthonormalized(),
		"scale": new_scale,
	}


static func stick_turn(rotation: Basis, stick: Vector2, delta: float, degrees_per_second: float) -> Basis:
	## The right stick: left/right spins the part about the slab's up axis, up/down tips it away from / towards you about the
	## slab's right axis (the same directions as turning a selected part in the arena).
	var step := deg_to_rad(degrees_per_second) * delta
	var spin := Basis(Vector3.UP, stick.x * step)
	var tip := Basis(Vector3.RIGHT, -stick.y * step)
	return (spin * tip * rotation).orthonormalized()


static func clamp_to_zone(point: Vector3, slab_size: Vector2, floor_y: float, ceiling_y: float) -> Vector3:
	## Pulls a point back over the slab's footprint and between the two heights (a nudge never walks the part off the table).
	return Vector3(
		clampf(point.x, -slab_size.x * 0.5, slab_size.x * 0.5),
		clampf(point.y, floor_y, ceiling_y),
		clampf(point.z, -slab_size.y * 0.5, slab_size.y * 0.5))


static func nudge(centre: Vector3, hand: Vector3, aim: Vector3, direction: float, speed: float, delta: float, min_distance: float) -> Vector3:
	## A (direction -1) pulls the part towards your hand, B (+1) pushes it away, along the line from your hand through the part
	## (or along where you point when the part is right at your hand). Stops `min_distance` short of the hand when pulling.
	var offset := centre - hand
	var dist := offset.length()
	var dir := offset / dist if dist > 0.02 else aim.normalized()
	var new_dist := dist + direction * speed * delta
	if direction < 0.0:
		if dist <= min_distance:
			return centre
		new_dist = maxf(new_dist, min_distance)
	return hand + dir * new_dist


static func fit_scale(bounds_mm: Vector2, window_m: Vector2, fill: float, fitted: float, top: float) -> float:
	## The user_scale (a multiple of the fitted size) at which a sketch `bounds_mm` big fills `fill` (0..1) of a window `window_m` metres across, clamped.
	var need := minf(window_m.x * fill / maxf(bounds_mm.x, 0.001), window_m.y * fill / maxf(bounds_mm.y, 0.001)) # metres per mm
	return clamp_scale(need / maxf(fitted, 0.000001), top)


static func ray_near_sphere(origin: Vector3, dir: Vector3, centre: Vector3, radius: float) -> bool:
	## True if the laser passes within `radius` of `centre`, in front of the hand: the cheap "am I pointing at the part" test.
	var to_centre := centre - origin
	var along := to_centre.dot(dir.normalized())
	if along < 0.0:
		return false
	var closest := origin + dir.normalized() * along
	return closest.distance_to(centre) <= radius

