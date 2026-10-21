extends Control
## A chamfered, translucent panel with corner ticks, drawn directly: the deck's outer frame and its ticker strip. Takes no mouse input.

const CYAN := Color(0.30, 0.88, 1.0)

var cut := 22.0
var fill := Color(0.012, 0.030, 0.075, 0.84)
var edge := Color(0.30, 0.88, 1.0, 0.70)
var edge_width := 2.5
var ticks := true ## small bracket marks at the corners, like a drawing sheet


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var w := size.x
	var h := size.y
	var points := PackedVector2Array([Vector2(0, 0), Vector2(w - cut, 0), Vector2(w, cut), Vector2(w, h), Vector2(cut, h), Vector2(0, h - cut)])
	draw_colored_polygon(points, fill)
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, edge, edge_width, true)
	if ticks:
		var t := Color(CYAN.r, CYAN.g, CYAN.b, 0.95)
		for corner in [Vector2(0, 0), Vector2(w, h)]:
			var sx := 1.0 if corner.x == 0.0 else -1.0
			var sy := 1.0 if corner.y == 0.0 else -1.0
			draw_line(corner + Vector2(sx * -6.0, sy * -6.0), corner + Vector2(sx * 22.0, sy * -6.0), t, 3.0)
			draw_line(corner + Vector2(sx * -6.0, sy * -6.0), corner + Vector2(sx * -6.0, sy * 22.0), t, 3.0)
