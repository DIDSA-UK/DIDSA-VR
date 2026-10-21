extends Button
## A button that draws itself, for the landing deck: chamfered, blueprint-cyan on near-black, nothing from the tablet's theme. Kinds:
##   "hero"   the big call to action (icon, title, a line of text, an ENTER chip)
##   "row"    a menu line (icon, title, a note on the right, a padlock when it needs a server and there is none)
##   "pill"   the connection status (a dot and the words)
##   "corner" a small icon and a label (Settings, About)
##   "mini"   a round-cornered control glyph (previous, next, pause, play) named by `icon_name`
##   "close"  the cross
## `text` is "Title" or "Title\nnote" (so a test or a screen reader sees the same words); the button's own drawing is switched off and replaced.

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const CYAN := Color(0.30, 0.88, 1.0)
const AMBER := Color(1.0, 0.66, 0.30)
const INK := Color(0.94, 0.98, 1.0)
const DIM := Color(0.56, 0.68, 0.82)
const PANEL := Color(0.030, 0.070, 0.150)

var kind := "row"
var icon_name := ""
var note := ""
var accent := CYAN
var locked := false ## needs a server and there is none: dimmed, with a padlock
var dot_colour := CYAN ## the pill's dot
var _hover := 0.0:
	set(value):
		_hover = value
		queue_redraw()
var _tween: Tween


func _init() -> void:
	flat = true
	clip_text = true # the transparent button text must not set the button's minimum width: the layout decides
	focus_mode = Control.FOCUS_NONE
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		add_theme_stylebox_override(state, empty)
	var clear := Color(0, 0, 0, 0)
	for colour in ["font_color", "font_hover_color", "font_pressed_color", "font_disabled_color", "font_focus_color", "font_hover_pressed_color", "font_outline_color"]:
		add_theme_color_override(colour, clear)


func _ready() -> void:
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))


func setup(p_kind: String, title: String, p_note: String = "", p_icon: String = "") -> void:
	kind = p_kind
	note = p_note
	icon_name = p_icon
	text = title if p_note == "" else "%s\n%s" % [title, p_note]


func title() -> String:
	return text.get_slice("\n", 0)


func _set_hover(on: bool) -> void:
	if disabled and on:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	var seconds := 0.0 if UiFeedback.reduce_motion else 0.12
	if seconds <= 0.0:
		_hover = 1.0 if on else 0.0
		return
	_tween = create_tween()
	_tween.tween_property(self, "_hover", 1.0 if on else 0.0, seconds)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DISABLED or what == NOTIFICATION_ENABLED:
		queue_redraw()


func _draw() -> void:
	match kind:
		"hero":
			_draw_hero()
		"pill":
			_draw_pill()
		"corner":
			_draw_corner()
		"mini":
			_draw_mini()
		"close":
			_draw_close()
		_:
			_draw_row()


static func chamfer(rect: Rect2, cut: float) -> PackedVector2Array:
	## A rectangle with its top-right and bottom-left corners cut off.
	var x := rect.position.x
	var y := rect.position.y
	var w := rect.size.x
	var h := rect.size.y
	return PackedVector2Array([Vector2(x, y), Vector2(x + w - cut, y), Vector2(x + w, y + cut), Vector2(x + w, y + h), Vector2(x + cut, y + h), Vector2(x, y + h - cut)])


func _outline(points: PackedVector2Array, colour: Color, width: float) -> void:
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, colour, width, true)


func _lit_edge(base_alpha: float) -> Color:
	var edge := accent.lerp(Color.WHITE, _hover * 0.35)
	edge.a = clampf(base_alpha + 0.5 * _hover, 0.0, 1.0)
	return edge


func _font() -> Font:
	return get_theme_default_font()


func _draw_row() -> void:
	var w := size.x
	var h := size.y
	var dim := disabled or locked
	var points := chamfer(Rect2(0, 0, w, h), 14.0)
	var fill := PANEL
	fill.a = (0.42 if dim else 0.62) + 0.22 * _hover
	draw_colored_polygon(points, fill)
	_outline(points, _lit_edge(0.28 if dim else 0.55), 2.0)
	var bar := _lit_edge(0.35 if dim else 0.95)
	draw_rect(Rect2(0, 12, 5, h - 24), bar)
	var tint := (DIM if dim else INK)
	if icon_name != "":
		var icon_tint := (DIM * 0.8 if dim else accent.lerp(Color.WHITE, _hover * 0.4))
		draw_texture_rect(UiIcons.texture(icon_name, 64), Rect2(26, (h - 42.0) * 0.5, 42, 42), false, icon_tint)
	var font := _font()
	var title_size := 30
	draw_string(font, Vector2(88, h * 0.5 + 10.0), title(), HORIZONTAL_ALIGNMENT_LEFT, w - 120.0, title_size, tint)
	var detail := note if note != "" else text.get_slice("\n", 1) if text.contains("\n") else ""
	if detail != "":
		var right := w - 30.0
		if locked:
			_padlock(Vector2(right - 12.0, h * 0.5 - 2.0), DIM)
			right -= 34.0
		var note_colour := DIM if dim else Color(accent.r, accent.g, accent.b, 0.9)
		draw_string(font, Vector2(0, h * 0.5 + 8.0), detail, HORIZONTAL_ALIGNMENT_RIGHT, right, 21, note_colour)


func _draw_hero() -> void:
	var w := size.x
	var h := size.y
	var points := chamfer(Rect2(0, 0, w, h), 34.0)
	var left := Color(0.020, 0.075, 0.180, 0.88 + 0.08 * _hover)
	var right := Color(0.035, 0.150, 0.300, 0.90 + 0.08 * _hover)
	draw_polygon(points, PackedColorArray([left, right, right, right, left, left]))
	# blueprint grid inside the card, very faint
	var grid := Color(accent.r, accent.g, accent.b, 0.05 + 0.04 * _hover)
	var gx := 40.0
	while gx < w:
		draw_line(Vector2(gx, 0), Vector2(gx, h), grid, 1.0)
		gx += 40.0
	var gy := 40.0
	while gy < h:
		draw_line(Vector2(0, gy), Vector2(w, gy), grid, 1.0)
		gy += 40.0
	_outline(points, _lit_edge(0.80), 3.0)
	draw_rect(Rect2(0, 34, 7, h - 68), _lit_edge(1.0))
	# the icon in a ring of ticks, then START HERE and the title across the top
	var centre := Vector2(104, h * 0.22)
	for i in 3:
		draw_arc(centre, 40.0 + i * 11.0, 0.0, TAU, 64, Color(accent.r, accent.g, accent.b, 0.50 - i * 0.14 + 0.2 * _hover), 2.0 if i == 0 else 1.2, true)
	draw_texture_rect(UiIcons.texture(icon_name if icon_name != "" else "models", 128), Rect2(centre - Vector2(30, 30), Vector2(60, 60)), false, INK)
	var font := _font()
	draw_string(font, Vector2(190, h * 0.22 - 14.0), "START HERE", HORIZONTAL_ALIGNMENT_LEFT, w - 220.0, 20, Color(AMBER.r, AMBER.g, AMBER.b, 0.95))
	draw_string(font, Vector2(190, h * 0.22 + 32.0), title().to_upper(), HORIZONTAL_ALIGNMENT_LEFT, w - 220.0, 52, INK)
	# the line of text bottom left, the ENTER chip under it, the garden in miniature bottom right
	var detail := note if note != "" else text.get_slice("\n", 1) if text.contains("\n") else ""
	if detail != "":
		draw_multiline_string(font, Vector2(52, h * 0.52), detail, HORIZONTAL_ALIGNMENT_LEFT, w * 0.50, 25, 4, Color(0.78, 0.88, 1.0, 0.95))
	_draw_lineup(Rect2(w * 0.60, h * 0.40, w * 0.34, h * 0.50))
	var chip := Rect2(52.0, h - 84.0, 170.0, 54.0)
	var chip_points := chamfer(chip, 12.0)
	var amber := AMBER.lerp(Color.WHITE, _hover * 0.25)
	draw_colored_polygon(chip_points, amber)
	draw_string(font, Vector2(chip.position.x, chip.position.y + 36.0), "ENTER", HORIZONTAL_ALIGNMENT_CENTER, chip.size.x - 22.0, 28, Color(0.05, 0.07, 0.12))
	var ax := chip.position.x + chip.size.x - 34.0
	var ay := chip.position.y + chip.size.y * 0.5
	draw_colored_polygon(PackedVector2Array([Vector2(ax, ay - 9), Vector2(ax + 14, ay), Vector2(ax, ay + 9)]), Color(0.05, 0.07, 0.12))


func _draw_lineup(area: Rect2) -> void:
	## The garden in miniature: the rockets as blueprint silhouettes on a common baseline, to scale with each other (heights in metres), the tallest filling the box.
	if area.size.x < 80.0 or area.size.y < 80.0:
		return
	var rockets: Array = [[110.6, 0.098, 0.30], [98.1, 0.15, 0.55], [40.5, 0.17, 0.35], [21.2, 0.09, 0.30]] # height, width / height, fin
	var scale := area.size.y / 110.6
	var gap := 18.0
	var total := 0.0
	for r in rockets:
		total += maxf(r[0] * scale * r[1], 12.0) + gap
	var x := area.position.x + (area.size.x - (total - gap)) * 0.5 + 0.0
	var base := area.position.y + area.size.y
	var col := Color(accent.r, accent.g, accent.b, 0.30 + 0.18 * _hover)
	var edge := Color(accent.r, accent.g, accent.b, 0.85)
	for r in rockets:
		var ht: float = r[0] * scale
		var bw: float = maxf(ht * float(r[1]), 12.0)
		var cx := x + bw * 0.5
		var shoulder := base - ht * 0.80
		var body := PackedVector2Array([Vector2(cx - bw * 0.5, base), Vector2(cx + bw * 0.5, base), Vector2(cx + bw * 0.5, shoulder), Vector2(cx, base - ht), Vector2(cx - bw * 0.5, shoulder)])
		draw_colored_polygon(body, col)
		var closed := body.duplicate()
		closed.append(body[0])
		draw_polyline(closed, edge, 1.6, true)
		var fin: float = bw * 0.5 * float(r[2]) * 2.0
		draw_colored_polygon(PackedVector2Array([Vector2(cx - bw * 0.5, base), Vector2(cx - bw * 0.5 - fin, base), Vector2(cx - bw * 0.5, base - ht * 0.12)]), col)
		draw_colored_polygon(PackedVector2Array([Vector2(cx + bw * 0.5, base), Vector2(cx + bw * 0.5 + fin, base), Vector2(cx + bw * 0.5, base - ht * 0.12)]), col)
		x += bw + gap
	draw_line(Vector2(area.position.x - 6.0, base), Vector2(area.end.x + 6.0, base), edge, 2.0)
	# a dimension line on the tallest, to say what the picture is about
	var dx := area.position.x - 14.0
	draw_line(Vector2(dx, base), Vector2(dx, area.position.y), Color(accent.r, accent.g, accent.b, 0.7), 1.5)
	draw_line(Vector2(dx - 6.0, area.position.y), Vector2(dx + 6.0, area.position.y), Color(accent.r, accent.g, accent.b, 0.7), 1.5)
	draw_line(Vector2(dx - 6.0, base), Vector2(dx + 6.0, base), Color(accent.r, accent.g, accent.b, 0.7), 1.5)


func _draw_pill() -> void:
	var w := size.x
	var h := size.y
	var points := chamfer(Rect2(0, 0, w, h), 10.0)
	var fill := PANEL
	fill.a = 0.60 + 0.2 * _hover
	draw_colored_polygon(points, fill)
	_outline(points, _lit_edge(0.55), 2.0)
	var dot := dot_colour
	draw_circle(Vector2(26, h * 0.5), 7.0, dot)
	draw_arc(Vector2(26, h * 0.5), 12.0, 0.0, TAU, 24, Color(dot.r, dot.g, dot.b, 0.45), 1.5, true)
	draw_string(_font(), Vector2(50, h * 0.5 + 8.0), text.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, w - 64.0, 21, INK)


func _draw_corner() -> void:
	var w := size.x
	var h := size.y
	var points := chamfer(Rect2(0, 0, w, h), 10.0)
	var fill := PANEL
	fill.a = 0.55 + 0.25 * _hover
	draw_colored_polygon(points, fill)
	_outline(points, _lit_edge(0.45), 2.0)
	if icon_name != "":
		draw_texture_rect(UiIcons.texture(icon_name, 64), Rect2(16, (h - 30.0) * 0.5, 30, 30), false, accent.lerp(Color.WHITE, _hover * 0.4))
	draw_string(_font(), Vector2(58, h * 0.5 + 8.0), title().to_upper(), HORIZONTAL_ALIGNMENT_LEFT, w - 66.0, 20, INK)


func _draw_mini() -> void:
	var w := size.x
	var h := size.y
	var points := chamfer(Rect2(0, 0, w, h), 8.0)
	var fill := PANEL
	fill.a = 0.55 + 0.25 * _hover
	draw_colored_polygon(points, fill)
	_outline(points, _lit_edge(0.45), 2.0)
	var c := Vector2(w * 0.5, h * 0.5)
	var col := accent.lerp(Color.WHITE, _hover * 0.5)
	match icon_name:
		"prev":
			draw_colored_polygon(PackedVector2Array([c + Vector2(7, -11), c + Vector2(-7, 0), c + Vector2(7, 11)]), col)
		"next":
			draw_colored_polygon(PackedVector2Array([c + Vector2(-7, -11), c + Vector2(7, 0), c + Vector2(-7, 11)]), col)
		"pause":
			draw_rect(Rect2(c + Vector2(-9, -11), Vector2(6, 22)), col)
			draw_rect(Rect2(c + Vector2(3, -11), Vector2(6, 22)), col)
		_:
			draw_colored_polygon(PackedVector2Array([c + Vector2(-6, -12), c + Vector2(10, 0), c + Vector2(-6, 12)]), col)


func _draw_close() -> void:
	var w := size.x
	var h := size.y
	var points := chamfer(Rect2(0, 0, w, h), 8.0)
	var fill := Color(0.20, 0.04, 0.06, 0.55 + 0.3 * _hover)
	draw_colored_polygon(points, fill)
	_outline(points, Color(1.0, 0.42, 0.45, 0.55 + 0.4 * _hover), 2.0)
	var c := Vector2(w * 0.5, h * 0.5)
	draw_line(c + Vector2(-9, -9), c + Vector2(9, 9), Color(1.0, 0.6, 0.62), 3.0, true)
	draw_line(c + Vector2(-9, 9), c + Vector2(9, -9), Color(1.0, 0.6, 0.62), 3.0, true)


func _padlock(at: Vector2, colour: Color) -> void:
	draw_rect(Rect2(at + Vector2(-9, -2), Vector2(18, 14)), colour)
	draw_arc(at + Vector2(0, -2), 6.0, PI, TAU, 14, colour, 2.5, true)
