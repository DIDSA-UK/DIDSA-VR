extends Node3D
## What a sketch looks like on the design table: a translucent SHEET lying in the sketch plane, the sketch's points, lines,
## circles and arcs drawn on it, the snap cursor, a rubber-band preview of the shape being drawn, and the dimension labels.
##
## It is a child of the table's copy of the part, so everything is in the PART's own frame (millimetres) and follows the
## copy when it's moved, turned or scaled. Line widths and marker sizes are chosen in WORLD metres and divided by the
## copy's scale, so they look the same whatever size the part was fitted to. Geometry is rebuilt only when the sketch
## changes (rebuild()) and the small preview / cursor only when the laser moves, never every frame.
##
## Coordinates in and out are the sheet's (u, v) in mm: sketch_math.gd's from_sheet() puts them in the part's frame.

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")

const LINE_WIDTH := 0.0035 ## world metres
const POINT_SIZE := 0.0045
const LIFT := 0.0012 ## world metres the drawing floats off the sheet, so it never z-fights it
const CIRCLE_SEGMENTS := 56
const LABEL_PIXEL := 0.00035 ## world metres per label pixel
const LABEL_FONT := 44

var plane: Dictionary = {}
var scale_m_per_mm := 0.003 ## the copy's scale: world metres per part mm
var sheet_extent := 100.0 ## mm
var sheet_centre := Vector2.ZERO ## sheet uv of the sheet's middle

var _sheet: MeshInstance3D
var _geo: MeshInstance3D
var _preview: MeshInstance3D
var _cursor: MeshInstance3D
var _cursor_material: StandardMaterial3D
var _labels: Node3D
var _line_material: StandardMaterial3D
var _tokens: Resource
var _geo_state := {}


func setup(p_plane: Dictionary, p_extent: float, p_centre: Vector2, p_scale: float, tokens: Resource) -> void:
	plane = p_plane
	sheet_extent = p_extent
	sheet_centre = p_centre
	scale_m_per_mm = maxf(p_scale, 0.000001)
	_tokens = tokens
	_line_material = StandardMaterial3D.new()
	_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_material.vertex_color_use_as_albedo = true
	_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_line_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_line_material.render_priority = 2

	_sheet = MeshInstance3D.new()
	_sheet.name = "Sheet"
	var quad := QuadMesh.new()
	quad.size = Vector2(sheet_extent, sheet_extent)
	var sheet_material := StandardMaterial3D.new()
	sheet_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sheet_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sheet_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var accent: Color = tokens.accent
	sheet_material.albedo_color = Color(accent.r, accent.g, accent.b, 0.10)
	sheet_material.render_priority = 0
	quad.material = sheet_material
	_sheet.mesh = quad
	_sheet.transform = Transform3D(Basis(plane["x"], plane["y"], plane["n"]), SketchMath.from_sheet(sheet_centre, plane))
	add_child(_sheet)

	_geo = _new_mesh_node("Drawing")
	_preview = _new_mesh_node("Preview")
	_cursor = MeshInstance3D.new()
	_cursor.name = "Cursor"
	var ring := TorusMesh.new()
	ring.inner_radius = 0.006 / scale_m_per_mm
	ring.outer_radius = 0.0085 / scale_m_per_mm
	ring.rings = 24
	ring.ring_segments = 8
	_cursor_material = StandardMaterial3D.new()
	_cursor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cursor_material.render_priority = 3
	ring.material = _cursor_material
	_cursor.mesh = ring
	_cursor.basis = Basis(plane["x"], plane["n"], -(plane["y"] as Vector3)) # the ring lies in the sheet
	_cursor.visible = false
	add_child(_cursor)
	_labels = Node3D.new()
	_labels.name = "Labels"
	add_child(_labels)
	rebuild(null)


func _new_mesh_node(node_name: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.material_override = _line_material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


# --- Geometry helpers (sheet uv -> the part's frame) ---------------------------------

func local_point(uv: Vector2, lift: float = 1.0) -> Vector3:
	return SketchMath.from_sheet(uv, plane) + (plane["n"] as Vector3) * (LIFT * lift / scale_m_per_mm)


func _ribbon(verts: PackedVector3Array, colors: PackedColorArray, a: Vector2, b: Vector2, width_world: float, colour: Color, lift: float = 1.0) -> void:
	var dir := b - a
	if dir.length() < 0.00001:
		return
	var half := (width_world / scale_m_per_mm) * 0.5
	var side := Vector2(-dir.y, dir.x).normalized() * half
	var pa := local_point(a + side, lift)
	var pb := local_point(b + side, lift)
	var pc := local_point(b - side, lift)
	var pd := local_point(a - side, lift)
	verts.append_array([pa, pb, pc, pa, pc, pd])
	for i in 6:
		colors.append(colour)


func _polyline(verts: PackedVector3Array, colors: PackedColorArray, pts: Array, width_world: float, colour: Color, closed: bool, lift: float = 1.0) -> void:
	var n := pts.size()
	for i in n - 1:
		_ribbon(verts, colors, pts[i], pts[i + 1], width_world, colour, lift)
	if closed and n > 2:
		_ribbon(verts, colors, pts[n - 1], pts[0], width_world, colour, lift)


func _marker(verts: PackedVector3Array, colors: PackedColorArray, uv: Vector2, size_world: float, colour: Color, lift: float = 1.5) -> void:
	var h := (size_world / scale_m_per_mm) * 0.5
	var c := [uv + Vector2(-h, -h), uv + Vector2(h, -h), uv + Vector2(h, h), uv + Vector2(-h, h)]
	var p := c.map(func(q): return local_point(q, lift))
	verts.append_array([p[0], p[1], p[2], p[0], p[2], p[3]])
	for i in 6:
		colors.append(colour)


static func circle_points(centre: Vector2, radius: float, segments: int) -> Array:
	var out: Array = []
	for i in segments:
		var a := TAU * float(i) / float(segments)
		out.append(centre + Vector2(cos(a), sin(a)) * radius)
	return out


static func arc_points(centre: Vector2, start: Vector2, end: Vector2, segments: int) -> Array:
	## Counter-clockwise from start to end, on the circle through start (the backend's arcs).
	var r := centre.distance_to(start)
	var a0 := (start - centre).angle()
	var a1 := (end - centre).angle()
	var sweep := fposmod(a1 - a0, TAU)
	if sweep < 0.00001:
		sweep = TAU
	var out: Array = []
	for i in segments + 1:
		var a := a0 + sweep * float(i) / float(segments)
		out.append(centre + Vector2(cos(a), sin(a)) * r)
	return out


# --- The drawing ---------------------------------------------------------------------

func rebuild(session, highlight: Array = [], hover: Dictionary = {}) -> void:
	## The sheet's border and axes, then every entity of the session. `highlight` is a list of {kind, id} (the
	## picked entities); `hover` the one under the laser.
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var accent: Color = _tokens.accent
	var text: Color = _tokens.text
	var dim: Color = _tokens.text_dim
	var warn: Color = _tokens.warn
	var half := sheet_extent * 0.5
	var corners := [
		sheet_centre + Vector2(-half, -half), sheet_centre + Vector2(half, -half),
		sheet_centre + Vector2(half, half), sheet_centre + Vector2(-half, half)]
	_polyline(verts, colors, corners, LINE_WIDTH * 0.6, Color(accent.r, accent.g, accent.b, 0.55), true, 0.5)
	var axis := sheet_extent * 0.08
	_ribbon(verts, colors, Vector2.ZERO, Vector2(axis, 0), LINE_WIDTH * 0.8, Color(1.0, 0.35, 0.35, 0.9), 0.7) # u axis
	_ribbon(verts, colors, Vector2.ZERO, Vector2(0, axis), LINE_WIDTH * 0.8, Color(0.4, 0.95, 0.5, 0.9), 0.7) # v axis

	if session != null:
		var selected := {}
		for h in highlight:
			selected["%s:%s" % [h.get("kind", ""), h.get("id", "")]] = true
		var hovered := "%s:%s" % [hover.get("kind", ""), hover.get("id", "")] if not hover.is_empty() else ""
		for id in session.lines:
			var l: Dictionary = session.lines[id]
			if not session.points.has(l["a"]) or not session.points.has(l["b"]):
				continue
			var key: String = "line:" + id
			var colour: Color = warn if (selected.has(key) or key == hovered) else (dim if l.get("construction", false) else text)
			_ribbon(verts, colors, session.points[l["a"]], session.points[l["b"]], LINE_WIDTH, colour)
		for id in session.circles:
			var c: Dictionary = session.circles[id]
			if not session.points.has(c["c"]) or not session.points.has(c["p"]):
				continue
			var key: String = "circle:" + id
			var colour: Color = warn if (selected.has(key) or key == hovered) else text
			var centre: Vector2 = session.points[c["c"]]
			_polyline(verts, colors, circle_points(centre, centre.distance_to(session.points[c["p"]]), CIRCLE_SEGMENTS), LINE_WIDTH, colour, true)
		for id in session.arcs:
			var a: Dictionary = session.arcs[id]
			if not session.points.has(a["c"]) or not session.points.has(a["s"]) or not session.points.has(a["e"]):
				continue
			var key: String = "arc:" + id
			var colour: Color = warn if (selected.has(key) or key == hovered) else text
			_polyline(verts, colors, arc_points(session.points[a["c"]], session.points[a["s"]], session.points[a["e"]], 32), LINE_WIDTH, colour, false)
		for id in session.points:
			var key: String = "point:" + id
			var colour: Color = warn if (selected.has(key) or key == hovered) else (dim if session.point_locked.get(id, false) else accent.lightened(0.3))
			_marker(verts, colors, session.points[id], POINT_SIZE, colour)
	_set_surface(_geo, verts, colors)
	_rebuild_dimension_labels(session)


func _set_surface(node: MeshInstance3D, verts: PackedVector3Array, colors: PackedColorArray) -> void:
	if verts.is_empty():
		node.mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	node.mesh = mesh


# --- The cursor and the rubber band -----------------------------------------------------

func set_cursor(uv: Variant, kind: String = "free") -> void:
	if uv == null:
		_cursor.visible = false
		return
	_cursor.visible = true
	_cursor.position = local_point(uv, 2.0)
	var colour: Color = _tokens.text
	match kind:
		"point": colour = Color(0.45, 1.0, 0.6)
		"vertex", "midpoint", "curve": colour = _tokens.accent
		"hover": colour = _tokens.warn
	_cursor_material.albedo_color = colour


func set_preview(tool_id: String, taps: Array, cursor_uv: Variant, sides: int = 6) -> void:
	## The shape the next tap would finish, as a faint rubber band. `taps` are the sheet positions placed so far.
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	if cursor_uv != null and not taps.is_empty():
		var colour: Color = _tokens.accent
		colour.a = 0.85
		var c: Vector2 = cursor_uv
		var first: Vector2 = taps[0]
		match tool_id:
			"line":
				_ribbon(verts, colors, first, c, LINE_WIDTH, colour, 1.2)
			"rectangle":
				_polyline(verts, colors, [first, Vector2(c.x, first.y), c, Vector2(first.x, c.y)], LINE_WIDTH, colour, true, 1.2)
			"circle":
				_polyline(verts, colors, circle_points(first, first.distance_to(c), CIRCLE_SEGMENTS), LINE_WIDTH, colour, true, 1.2)
				_ribbon(verts, colors, first, c, LINE_WIDTH * 0.6, colour, 1.2)
			"arc":
				if taps.size() == 1:
					_ribbon(verts, colors, first, c, LINE_WIDTH * 0.6, colour, 1.2)
				else:
					var start: Vector2 = taps[1]
					var r := first.distance_to(start)
					var dir := c - first
					var end := first + (dir.normalized() * r if dir.length() > 0.0001 else Vector2(r, 0))
					_polyline(verts, colors, arc_points(first, start, end, 32), LINE_WIDTH, colour, false, 1.2)
					_ribbon(verts, colors, first, start, LINE_WIDTH * 0.5, colour, 1.2)
			"polygon":
				var r2 := first.distance_to(c)
				var a0 := (c - first).angle()
				var corners: Array = []
				for i in maxi(sides, 3):
					var a := a0 + TAU * float(i) / float(maxi(sides, 3))
					corners.append(first + Vector2(cos(a), sin(a)) * r2)
				_polyline(verts, colors, corners, LINE_WIDTH, colour, true, 1.2)
	_set_surface(_preview, verts, colors)


# --- Dimension labels ---------------------------------------------------------------------

var _ghost_keys: Array = []


func show_ghosts(ghosts: Array) -> void:
	## Candidate dimensions for the picked entities, floating on the sheet where you point to type a value.
	_ghost_keys = ghosts.map(func(g): return g["key"])
	_rebuild_dimension_labels(_last_session, ghosts)


var _last_session = null


func _rebuild_dimension_labels(session, ghosts: Array = []) -> void:
	_last_session = session
	for child in _labels.get_children():
		_labels.remove_child(child)
		child.queue_free()
	if session != null:
		for id in session.constraints:
			var c: Dictionary = session.constraints[id]
			if str(c.get("type", "")) == "distance" and not bool(c.get("provisional", false)) and session.points.has(str(c.get("point_a_id", ""))) and session.points.has(str(c.get("point_b_id", ""))):
				var mid: Vector2 = (session.points[c["point_a_id"]] + session.points[c["point_b_id"]]) * 0.5
				_label(mid, "%.2f" % float(c["distance"]), _tokens.accent.lightened(0.2), false)
	for g in ghosts:
		_label(g["uv"], "%s %.2f %s" % [g["label"], float(g["value"]), g["unit"]], _tokens.warn, true)


func _label(uv: Vector2, text: String, colour: Color, boxed: bool) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = LABEL_FONT
	label.pixel_size = LABEL_PIXEL / scale_m_per_mm
	label.modulate = colour
	label.outline_size = 10
	label.outline_modulate = Color(0.02, 0.04, 0.08, 0.95)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.render_priority = 5
	label.position = local_point(uv, 3.0)
	label.set_meta("boxed", boxed)
	_labels.add_child(label)


func ghost_near(ghosts: Array, uv: Vector2, radius: float) -> String:
	## The key of the dimension candidate whose label is nearest `uv` within `radius` (mm), or "".
	var best := ""
	var best_d := radius
	for g in ghosts:
		var d: float = uv.distance_to(g["uv"])
		if d <= best_d:
			best_d = d
			best = g["key"]
	return best


func label_texts() -> Array:
	return _labels.get_children().map(func(l): return (l as Label3D).text)
