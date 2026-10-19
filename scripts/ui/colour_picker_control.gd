extends Control
## The Appearance page's full colour picker (DIDSA-CAD `docs/appearance-tool-scope.md` D4): a hue ring round a saturation /
## value square, driven by the laser like the tablet's sliders (it is in the "laser_draggable" group, so laser_surface.gd keeps
## sending it motion while the trigger is held). A press on the ring sets the hue, on the square the saturation and value; the
## drag keeps changing the one the press started on. `colour_changed` fires on every change, `colour_committed` on release.

signal colour_changed(colour: Color)
signal colour_committed(colour: Color)

const RING_SEGMENTS := 72
const SQUARE_STEPS := 12
const RING_WIDTH := 0.16 ## of the radius

var hue := 0.0
var saturation := 0.8
var value := 0.85
var _dragging := "" ## "", "ring" or "square"


func _init() -> void:
	custom_minimum_size = Vector2(300, 300)
	add_to_group("laser_draggable")
	mouse_filter = Control.MOUSE_FILTER_STOP


func colour() -> Color:
	return Color.from_hsv(hue, saturation, value)


func set_colour(c: Color) -> void:
	## Shows `c` (no signal). A grey keeps the hue it had.
	if c.s > 0.001:
		hue = c.h
	saturation = c.s
	value = c.v
	queue_redraw()


func _geometry() -> Dictionary:
	var side := minf(size.x, size.y)
	var centre := size * 0.5
	var outer := side * 0.5
	var inner := outer * (1.0 - RING_WIDTH)
	var half := inner * 0.70710678 * 0.94 # the square sits inside the ring with a small gap
	return {"centre": centre, "outer": outer, "inner": inner, "square": Rect2(centre - Vector2(half, half), Vector2(half, half) * 2.0)}


static func region_at(local: Vector2, centre: Vector2, inner: float, outer: float, square: Rect2) -> String:
	var r := local.distance_to(centre)
	if r >= inner and r <= outer:
		return "ring"
	if square.has_point(local):
		return "square"
	return ""


static func hue_at(local: Vector2, centre: Vector2) -> float:
	## 0 at the top, going clockwise (screen y is down).
	var a := atan2(local.x - centre.x, -(local.y - centre.y))
	return fposmod(a / TAU, 1.0)


static func sv_at(local: Vector2, square: Rect2) -> Vector2:
	## (saturation across, value up), each 0-1, clamped to the square.
	var t := ((local - square.position) / square.size).clamp(Vector2.ZERO, Vector2.ONE)
	return Vector2(t.x, 1.0 - t.y)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var g := _geometry()
		if (event as InputEventMouseButton).pressed:
			_dragging = region_at(event.position, g["centre"], g["inner"], g["outer"], g["square"])
			_apply(event.position)
		elif _dragging != "":
			_dragging = ""
			colour_committed.emit(colour())
		accept_event()
	elif event is InputEventMouseMotion and _dragging != "":
		_apply(event.position)
		accept_event()


func _apply(local: Vector2) -> void:
	var g := _geometry()
	if _dragging == "ring":
		hue = hue_at(local, g["centre"])
	elif _dragging == "square":
		var sv := sv_at(local, g["square"])
		saturation = sv.x
		value = sv.y
	else:
		return
	queue_redraw()
	colour_changed.emit(colour())


func _draw() -> void:
	var g := _geometry()
	var centre: Vector2 = g["centre"]
	var outer: float = g["outer"]
	var inner: float = g["inner"]
	for i in RING_SEGMENTS:
		var a0 := float(i) / RING_SEGMENTS * TAU
		var a1 := float(i + 1) / RING_SEGMENTS * TAU
		var d0 := Vector2(sin(a0), -cos(a0))
		var d1 := Vector2(sin(a1), -cos(a1))
		var c0 := Color.from_hsv(float(i) / RING_SEGMENTS, 1.0, 1.0)
		var c1 := Color.from_hsv(float(i + 1) / RING_SEGMENTS, 1.0, 1.0)
		draw_polygon(PackedVector2Array([centre + d0 * inner, centre + d0 * outer, centre + d1 * outer, centre + d1 * inner]),
			PackedColorArray([c0, c0, c1, c1]))
	var sq: Rect2 = g["square"]
	var step := sq.size / SQUARE_STEPS
	for x in SQUARE_STEPS:
		for y in SQUARE_STEPS:
			var p := sq.position + Vector2(x, y) * step
			var corners := PackedVector2Array([p, p + Vector2(step.x, 0), p + step, p + Vector2(0, step.y)])
			var cols := PackedColorArray()
			for k in [Vector2(x, y), Vector2(x + 1, y), Vector2(x + 1, y + 1), Vector2(x, y + 1)]:
				cols.append(Color.from_hsv(hue, k.x / SQUARE_STEPS, 1.0 - k.y / SQUARE_STEPS))
			draw_polygon(corners, cols)
	# where the colour is: a mark on the ring and a ring on the square
	var hd := Vector2(sin(hue * TAU), -cos(hue * TAU))
	draw_line(centre + hd * inner, centre + hd * outer, Color.WHITE, 4.0)
	var at := sq.position + Vector2(saturation, 1.0 - value) * sq.size
	draw_arc(at, 10.0, 0.0, TAU, 24, Color.BLACK, 4.0)
	draw_arc(at, 10.0, 0.0, TAU, 24, Color.WHITE, 2.0)
