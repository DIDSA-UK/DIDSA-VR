extends RefCounted
## One Assembly Room's volume: an oriented box in world space (metres), set by where the room is (`xform`, orthonormal: position and
## orientation only, a room's scale is a display transform on its content, never on its walls) and its half extents. Pure maths, no nodes:
## room_registry.gd keeps the list, the shader (shaders/clip_common.gdshaderinc) and the picking code (laser_pick.gd, controller.gd) test against it.
## See docs/assembly-rooms-scope.md.

const MIN_SPAWN_SIZE_M := 3.0 ## a NEW room is at least a 3 m cube (larger if its content needs it)
const MIN_DRAG_SIZE_M := 0.5 ## the smallest a wall drag may leave a side (a minimised "snow globe" room is smaller than a spawn room)
const SPAWN_MARGIN_M := 0.25 ## space left round the content when a room is fitted to it

var xform := Transform3D.IDENTITY: ## room-box centre and orientation -> world
	set(value):
		xform = Transform3D(value.basis.orthonormalized(), value.origin)
		_inverse = xform.affine_inverse()
var half := Vector3(MIN_SPAWN_SIZE_M * 0.5, MIN_SPAWN_SIZE_M * 0.5, MIN_SPAWN_SIZE_M * 0.5)
var slot := -1 ## the row this room occupies in the shader's texture (set by room_registry.gd)

var _inverse := Transform3D.IDENTITY


static func spawn_size(content_size: Vector3) -> Vector3:
	## Full size (not half) of a newly opened room: the content plus a margin each side, but never under the 3 m cube.
	var fitted := content_size + Vector3.ONE * (SPAWN_MARGIN_M * 2.0)
	return Vector3(maxf(fitted.x, MIN_SPAWN_SIZE_M), maxf(fitted.y, MIN_SPAWN_SIZE_M), maxf(fitted.z, MIN_SPAWN_SIZE_M))


static func clamp_drag_size(size: Vector3) -> Vector3:
	return Vector3(maxf(size.x, MIN_DRAG_SIZE_M), maxf(size.y, MIN_DRAG_SIZE_M), maxf(size.z, MIN_DRAG_SIZE_M))


static func make(box_xform: Transform3D, full_size: Vector3) -> RefCounted:
	var v := new()
	v.xform = box_xform
	v.half = full_size * 0.5
	return v


func to_local(world_point: Vector3) -> Vector3:
	return _inverse * world_point


func contains(world_point: Vector3, margin: float = 0.0) -> bool:
	## The shader's test in GDScript (room_contains in clip_common.gdshaderinc).
	var l := _inverse * world_point
	return absf(l.x) <= half.x + margin and absf(l.y) <= half.y + margin and absf(l.z) <= half.z + margin


func overlaps(other: RefCounted) -> bool:
	## True if the two boxes share any volume (separating-axis test over both boxes' face normals and the nine edge cross products).
	## Rooms may not overlap (docs/assembly-rooms-scope.md): spawn and wall-drag refuse or push apart on this.
	var ca: Vector3 = xform.origin
	var cb: Vector3 = other.xform.origin
	var axes: Array[Vector3] = []
	for i in 3:
		axes.append(xform.basis[i].normalized())
		axes.append(other.xform.basis[i].normalized())
	for i in 3:
		for j in 3:
			var c := xform.basis[i].cross(other.xform.basis[j])
			if c.length() > 0.0001:
				axes.append(c.normalized())
	for axis in axes:
		var ra := _extent_on(axis)
		var rb: float = other._extent_on(axis)
		if absf((cb - ca).dot(axis)) > ra + rb:
			return false
	return true


func _extent_on(axis: Vector3) -> float:
	## Half the box's width projected onto a unit axis.
	var b := xform.basis
	return absf(b[0].dot(axis)) * half.x + absf(b[1].dot(axis)) * half.y + absf(b[2].dot(axis)) * half.z
