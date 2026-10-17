extends Node3D
## The hint panel on the right wrist: the tool wheel's tool tips, and the line that says what the trigger does now.
##
## It hangs from the right wrist (its top edge at the wrist, facing you, leaning a little so it reads from above), because
## the hand is what moves round the wheel: the panel travels with it, below and in front of the hand (the ring opens centred
## on the hand, tool_wheel.gd's ring_lift), so it sits under the tile being pointed at rather than over it. While the wheel is up it names what the hand is pointing
## at and what that does (or why a greyed wedge cannot be chosen); with a mode tool in hand and the wheel down it says
## what the trigger will do next (pick the first face, a mate was created...). Hidden when there is nothing to say.
##
## Drawn like the tablet's panels from the live theme: a rounded panel in bg_panel with an accent border, the theme font and
## text colours, corner radius and border width, rebuilt on a theme change. wheel_flows.gd decides what it says.

const Math := preload("res://scripts/ui/tool_wheel_math.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")

const WIDTH := 0.26 ## metres
const MIN_HEIGHT := 0.05
const PAD := 0.012
const PX := 1.0 / 2667.0 ## metres per tablet pixel: the theme's shape tokens are in these
const PIXEL_SIZE := 0.0006 ## metres per label pixel
const BORDER_PER_PX := 0.0012
const MOUNT := Vector3(0.0, -0.025, 0.12) ## the panel's TOP edge, relative to the right controller: just behind and below the tracking ring
const TILT_DEGREES := 22.0 ## leans it so its face tips up towards you (its top edge away), the way you see it looking down at your hand

var tokens: Resource
var _root: Node3D ## everything drawn; hung below the wrist by its top edge
var _fill: MeshInstance3D
var _border: MeshInstance3D
var _title: Label3D
var _body: Label3D
var _title_text := ""
var _body_text := ""
var _accent := Color.WHITE
var _tone := "normal"
var _height := MIN_HEIGHT
var _seen_revision := -1


func setup(hand: Node3D, p_tokens: Resource) -> void:
	tokens = p_tokens
	hand.add_child(self)
	position = MOUNT
	rotation_degrees = Vector3(-TILT_DEGREES, 0.0, 0.0) # the quad faces +Z (towards you); this tips its face up
	_root = Node3D.new()
	add_child(_root)
	_border = _node(9)
	_fill = _node(10)
	_title = _label(false)
	_body = _label(true)
	visible = false


func show_text(title: String, body: String, accent: Color, tone: String = "normal") -> void:
	## `tone` "warn" is for a reason something cannot be done (amber border); "normal" otherwise.
	if title == _title_text and body == _body_text and tone == _tone and accent == _accent and _seen_revision == UiThemes.revision and visible:
		return
	_title_text = title
	_body_text = body
	_accent = accent
	_tone = tone
	_layout()
	visible = title != "" or body != ""


func clear() -> void:
	_title_text = ""
	_body_text = ""
	visible = false


func is_showing() -> bool:
	return visible


func title_text() -> String:
	return _title_text


func body_text() -> String:
	return _body_text


func panel_height() -> float:
	return _height


func _process(_delta: float) -> void:
	if visible and _seen_revision != UiThemes.revision:
		_layout() # the theme changed while it is up: re-skin in place


func _layout() -> void:
	_seen_revision = UiThemes.revision
	var corner := clampf(float(tokens.radius_control) * PX * 1.6, 0.003, 0.02)
	var border := maxf(float(tokens.border_width) * BORDER_PER_PX, 0.0006)
	var title_px := int(float(tokens.font_title) * 1.15)
	var body_px := int(float(tokens.font_small) * 1.7)
	_title.font_size = title_px
	_body.font_size = body_px
	var font: Font = _title.font if _title.font != null else ThemeDB.fallback_font
	var text_w := WIDTH - 2.0 * PAD
	_body.width = text_w / PIXEL_SIZE
	var title_h := float(title_px) * PIXEL_SIZE * 1.25 if _title_text != "" else 0.0
	var body_h := 0.0
	if _body_text != "":
		var size := font.get_multiline_string_size(_body_text, HORIZONTAL_ALIGNMENT_LEFT, text_w / PIXEL_SIZE, body_px)
		body_h = size.y * PIXEL_SIZE * 1.1
	_height = maxf(MIN_HEIGHT, PAD * 2.0 + title_h + (0.006 if body_h > 0.0 and title_h > 0.0 else 0.0) + body_h)
	# built upwards from y = 0, then hung by its top edge below the wrist
	_root.position = Vector3(0.0, -_height, 0.0)
	var rect := PackedVector2Array([Vector2(-WIDTH * 0.5, 0.0), Vector2(WIDTH * 0.5, 0.0), Vector2(WIDTH * 0.5, _height), Vector2(-WIDTH * 0.5, _height)])
	var fill_poly := Math.rounded(rect, corner)
	_fill.mesh = _mesh(fill_poly)
	_border.mesh = _mesh(Math.grown(fill_poly, border))
	var fill_colour: Color = tokens.bg_panel
	var edge: Color = tokens.warn if _tone == "warn" else _accent
	(_fill.material_override as StandardMaterial3D).albedo_color = Color(fill_colour.r, fill_colour.g, fill_colour.b, 0.95)
	(_border.material_override as StandardMaterial3D).albedo_color = Color(edge.r, edge.g, edge.b, 0.85)
	var outline: Color = Color(fill_colour.r, fill_colour.g, fill_colour.b, 0.9)
	for l in [_title, _body]:
		l.outline_modulate = outline
		if tokens.get("font") != null:
			l.font = tokens.get("font")
	_title.text = _title_text
	_title.modulate = tokens.text
	_title.position = Vector3(-WIDTH * 0.5 + PAD, _height - PAD, 0.002)
	_body.text = _body_text
	_body.modulate = tokens.warn if _tone == "warn" else tokens.text_dim
	_body.position = Vector3(-WIDTH * 0.5 + PAD, _height - PAD - title_h - (0.006 if title_h > 0.0 else 0.0), 0.002)


func _node(priority: int) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = priority
	n.material_override = m
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_root.add_child(n)
	return n


func _label(wrapped: bool) -> Label3D:
	var l := Label3D.new()
	l.pixel_size = PIXEL_SIZE
	l.shaded = false
	l.double_sided = true
	l.outline_size = 4
	l.render_priority = 12
	l.outline_render_priority = 11
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	if wrapped:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(l)
	return l


func _mesh(outline: PackedVector2Array) -> ArrayMesh:
	var indices := Geometry2D.triangulate_polygon(outline)
	var mesh := ArrayMesh.new()
	if indices.is_empty():
		return mesh
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for p in outline:
		verts.append(Vector3(p.x, p.y, 0.0))
		normals.append(Vector3.BACK)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
