extends RefCounted
## The tool wheel's pure geometry (tool_wheel.gd draws and drives it): which wedge a hand offset points
## at, where a wedge's centre sits, and the wedge outlines. Nothing here touches the scene tree, so
## tests/tool_wheel.gd checks all of it headless.
##
## Offsets are in the wheel's own plane: x to the user's right, y up. Wedge 0 is centred straight up and
## the wedges run clockwise, like a clock face.

const DEAD_ZONE := 0.045 ## metres: inside this the hand is "at the centre" = nothing chosen (release here to cancel)
const DRILL_DISTANCE := 0.16 ## metres: a sub-wheel wedge opens its ring once the hand is this far out
const OUTER_RADIUS := 0.17 ## metres: drawn radius of the ring
const INNER_RADIUS := 0.065 ## metres: drawn inner radius (a little bigger than the dead zone, so the centre reads as a hole)
const GAP := 0.012 ## metres: visual gap between neighbouring wedges


static func wedge_for(offset: Vector2, count: int, dead_zone: float = DEAD_ZONE) -> int:
	## The wedge the offset points at, or -1 inside the dead zone (or with nothing to point at).
	if count <= 0 or offset.length() < dead_zone:
		return -1
	var angle := atan2(offset.x, offset.y) # 0 = up, clockwise positive
	var step := TAU / float(count)
	return int(floor(fposmod(angle + step * 0.5, TAU) / step)) % count


static func centre_angle(index: int, count: int) -> float:
	## Clockwise angle from straight up to the middle of wedge `index`.
	return TAU * float(index) / float(maxi(count, 1))


static func centre_direction(index: int, count: int) -> Vector2:
	var a := centre_angle(index, count)
	return Vector2(sin(a), cos(a))


static func wedge_outline(index: int, count: int, inner: float = INNER_RADIUS, outer: float = OUTER_RADIUS, gap: float = GAP, steps: int = 10) -> PackedVector2Array:
	## A closed polygon for the wedge (counter-clockwise), with `gap` metres trimmed off each side so the wedges don't touch.
	var pts := PackedVector2Array()
	if count <= 0:
		return pts
	var centre := centre_angle(index, count)
	var half := TAU / float(count) * 0.5
	var inner_half := maxf(half - gap / maxf(inner, 0.001) * 0.5, 0.01)
	var outer_half := maxf(half - gap / maxf(outer, 0.001) * 0.5, 0.01)
	# outer arc, anticlockwise on screen = decreasing clockwise-angle
	for i in steps + 1:
		var a := centre + outer_half - (outer_half * 2.0) * float(i) / float(steps)
		pts.append(Vector2(sin(a), cos(a)) * outer)
	for i in steps + 1:
		var a := centre - inner_half + (inner_half * 2.0) * float(i) / float(steps)
		pts.append(Vector2(sin(a), cos(a)) * inner)
	return pts


static func project_offset(hand: Vector3, anchor: Vector3, right: Vector3) -> Vector2:
	## Hand movement since the wheel opened, as (right, up) in the wheel's vertical plane. `right` is the
	## flattened unit vector that faced the user's right when the wheel opened.
	var d := hand - anchor
	return Vector2(d.dot(right), d.y)


static func is_drilling(offset: Vector2, drill_distance: float = DRILL_DISTANCE) -> bool:
	return offset.length() >= drill_distance
