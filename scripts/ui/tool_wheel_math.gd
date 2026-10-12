extends RefCounted
## The tool wheel's pure geometry (tool_wheel.gd draws and drives it): which wedge a hand offset points
## at, where a wedge's centre sits, and the wedge outlines. Nothing here touches the scene tree, so
## tests/tool_wheel.gd checks all of it headless.
##
## Offsets are in the wheel's own plane: x to the user's right, y up. Wedge 0 is centred straight up and
## the wedges run clockwise, like a clock face.

const DEAD_ZONE := 0.045 ## metres: inside this the hand is "at the centre" = nothing chosen (release here to cancel)
const DRILL_DISTANCE := 0.20 ## metres: a sub-wheel wedge opens its ring once the hand is this far out
const OUTER_RADIUS := 0.22 ## metres: drawn radius of the ring
const INNER_RADIUS := 0.075 ## metres: drawn inner radius (a little bigger than the dead zone, so the centre reads as a hole)
const CONTENT_RADIUS := 0.168 ## metres: where a tile's icon and name are centred. A wedge is narrower at the hub, so this sits outside the middle of the radius (0.1475), near the tile's area centre
const PILL_HALF_ANGLE := PI / 6.0 ## the pill under the ring spans 60 degrees: 30 either side of straight down
const PILL_GAP := 0.018 ## metres between the ring's outer edge and the pill
const PILL_DEPTH := 0.058 ## metres: how thick the pill is
const GAP := 0.014 ## metres: visual gap between neighbouring wedges
const CORNER := 0.009 ## metres: how round a wedge's corners are (the tablet's tiles are rounded the same way)


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


static func wedge_outline(index: int, count: int, inner: float = INNER_RADIUS, outer: float = OUTER_RADIUS, gap: float = GAP, steps: int = 14, corner: float = CORNER) -> PackedVector2Array:
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
	return rounded(pts, corner)


static func rounded(poly: PackedVector2Array, radius: float) -> PackedVector2Array:
	## Rounds a convex polygon's corners: shrink it by `radius`, then grow it back with round joins.
	if radius <= 0.0 or poly.size() < 3:
		return poly
	var shrunk := Geometry2D.offset_polygon(poly, -radius, Geometry2D.JOIN_ROUND)
	if shrunk.is_empty():
		return poly
	var grown := Geometry2D.offset_polygon(shrunk[0], radius, Geometry2D.JOIN_ROUND)
	return grown[0] if not grown.is_empty() else poly


static func grown(poly: PackedVector2Array, delta: float) -> PackedVector2Array:
	## The polygon pushed out (or in, negative) by `delta` metres, round joins: a border or glow layer behind a wedge.
	var out := Geometry2D.offset_polygon(poly, delta, Geometry2D.JOIN_ROUND)
	return out[0] if not out.is_empty() else poly


static func circle(radius: float, steps: int = 40) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var a := TAU * float(i) / float(steps)
		pts.append(Vector2(sin(a), cos(a)) * radius)
	return pts


static func project_offset(hand: Vector3, anchor: Vector3, right: Vector3) -> Vector2:
	## Hand movement since the wheel opened, as (right, up) in the wheel's vertical plane. `right` is the
	## flattened unit vector that faced the user's right when the wheel opened.
	var d := hand - anchor
	return Vector2(d.dot(right), d.y)


static func is_drilling(offset: Vector2, drill_distance: float = DRILL_DISTANCE) -> bool:
	return offset.length() >= drill_distance


static func tile_width(count: int, radius: float = CONTENT_RADIUS, gap: float = GAP, padding: float = 0.012) -> float:
	## How wide a tile is at `radius` (the chord across its wedge, less the gap between tiles and some padding): the room a name has.
	## Capped for rings of just two or three wedges, whose chords are huge.
	if count <= 0:
		return 0.0
	var chord := 2.0 * radius * sin(PI / float(maxi(count, 2)))
	return clampf(chord - gap - padding, 0.02, 0.13)


static func horizontal_room(poly: PackedVector2Array, y_top: float, y_bottom: float, centre_x: float) -> float:
	## How wide a horizontal line of text centred on `centre_x` can be and stay inside a convex tile, over the text's whole height:
	## the tightest of the slices at its top, middle and bottom. Text is horizontal and tiles slant, so this is the real room,
	## not the chord across the wedge. 0 if the text falls outside the tile.
	var room := INF
	for y: float in [y_top, (y_top + y_bottom) * 0.5, y_bottom]:
		var left := INF
		var right := -INF
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			if (a.y - y) * (b.y - y) > 0.0 or is_equal_approx(a.y, b.y):
				continue
			var x := a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
			left = minf(left, x)
			right = maxf(right, x)
		if left > right:
			return 0.0
		room = minf(room, 2.0 * minf(centre_x - left, right - centre_x))
	return maxf(room, 0.0)


static func horizontal_span(poly: PackedVector2Array, y_top: float, y_bottom: float) -> Vector2:
	## The widest horizontal interval (left, right) that is inside a convex tile over a whole band of height: the tightest
	## of the slices at the band's top, middle and bottom. Text centred on the interval's middle gets all the room the tile
	## has at that height, which on a slanted tile is not centred on the wedge's own axis. (left > right = outside the tile.)
	var left := -INF
	var right := INF
	for y: float in [y_top, (y_top + y_bottom) * 0.5, y_bottom]:
		var lo := INF
		var hi := -INF
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			if (a.y - y) * (b.y - y) > 0.0 or is_equal_approx(a.y, b.y):
				continue
			var x := a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)
			lo = minf(lo, x)
			hi = maxf(hi, x)
		if lo > hi:
			return Vector2(0.0, -1.0)
		left = maxf(left, lo)
		right = minf(right, hi)
	return Vector2(left, right)


static func pill_outline(steps: int = 24, corner: float = CORNER) -> PackedVector2Array:
	## The pill under the ring: an arc band 60 degrees wide centred on straight down, just outside the ring, with the same
	## rounded corners as the ring's tiles. (Wedge 0 is straight up, so "down" is an angle of PI.)
	var inner := OUTER_RADIUS + PILL_GAP
	var outer := inner + PILL_DEPTH
	var pts := PackedVector2Array()
	for i in steps + 1:
		var a := PI + PILL_HALF_ANGLE - (PILL_HALF_ANGLE * 2.0) * float(i) / float(steps)
		pts.append(Vector2(sin(a), cos(a)) * outer)
	for i in steps + 1:
		var a := PI - PILL_HALF_ANGLE + (PILL_HALF_ANGLE * 2.0) * float(i) / float(steps)
		pts.append(Vector2(sin(a), cos(a)) * inner)
	return rounded(pts, corner)


static func pill_centre() -> Vector2:
	return Vector2(0.0, -(OUTER_RADIUS + PILL_GAP + PILL_DEPTH * 0.5))


static func in_pill(offset: Vector2) -> bool:
	## The hand has gone out past the ring, into the 60 degrees straight below it.
	if offset.length() < OUTER_RADIUS + 0.004:
		return false
	return absf(atan2(offset.x, offset.y)) >= PI - PILL_HALF_ANGLE
