extends Control
## The monolith's face, drawn: near-black glass that is a little lighter towards the foot, faint horizontal seams, bright rim lines down both edges and across the
## top (the edge you see silhouetted against the sky), and a hairline under the logo's zone. Opaque: a slab, not a window. Takes no mouse input.

const CYAN := Color(0.30, 0.88, 1.0)

var logo_zone := 360.0 ## pixels at the top left clear for the logo, which hangs in front of the face


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var w := size.x
	var h := size.y
	var top := Color(0.004, 0.008, 0.020)
	var foot := Color(0.016, 0.034, 0.075)
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, h), Vector2(0, h)]), PackedColorArray([top, top, foot, foot]))
	var seam := Color(CYAN.r, CYAN.g, CYAN.b, 0.045)
	var y := logo_zone + 70.0
	while y < h:
		draw_line(Vector2(0, y), Vector2(w, y), seam, 1.0)
		y += 140.0
	# rim light: the two edges fade in from the top, the top edge is the brightest
	var steps := 24
	for i in steps:
		var a := 0.95 * (1.0 - float(i) / steps)
		var y0 := h * float(i) / steps
		var y1 := h * float(i + 1) / steps
		var col := Color(CYAN.r, CYAN.g, CYAN.b, 0.25 + a * 0.6)
		draw_line(Vector2(2, y0), Vector2(2, y1), col, 4.0)
		draw_line(Vector2(w - 2, y0), Vector2(w - 2, y1), col, 4.0)
	draw_line(Vector2(0, 2), Vector2(w, 2), Color(0.75, 0.95, 1.0, 0.95), 5.0)
	# the logo zone's foot: a hairline with end ticks (the logo sits above it, a plain crown above the logo)
	draw_line(Vector2(56, logo_zone), Vector2(w - 56, logo_zone), Color(CYAN.r, CYAN.g, CYAN.b, 0.40), 2.0)
	for x in [56.0, w - 56.0]:
		draw_line(Vector2(x, logo_zone - 10), Vector2(x, logo_zone + 10), Color(CYAN.r, CYAN.g, CYAN.b, 0.85), 3.0)
