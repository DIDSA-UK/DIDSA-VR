extends Node3D
## What a sketch looks like on the design table: a translucent SHEET lying in the sketch plane, the sketch's points, lines,
## circles and arcs drawn on it, the snap cursor, a rubber-band preview of the shape being drawn, and the dimension labels.
##
## It is a child of the table's copy of the part, so the sketch is in the PART's own frame and moves, zooms and turns WITH the part:
## the part's edges and corners and the sketch always line up, which is what dimensioning to existing geometry needs. What does not
## move with the part is the WINDOW: a rectangle fixed in the world (window_m, on the table), in the sketch plane. Pan and zoom move
## and scale the part (and with it the sketch) under that window, so the window is a viewport, and the drawing is clipped to it by
## the line shader. The table tells this view every frame where the window is on the plane (set_frame: the sketch uv at the window's
## middle) and how big the part is (world metres per sketch mm); only a change of scale rebuilds the drawing (widths are chosen in
## world metres), a pan is one pair of shader uniforms.
##
## Coordinates in and out of the drawing are the sketch's (u, v) in mm: sketch_math.gd's from_sheet() puts them in the part's frame.

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")

const GRID_SHADER := preload("res://shaders/sketch_grid.gdshader")
const LINE_SHADER := preload("res://shaders/sketch_lines.gdshader")
const DimensionLayout := preload("res://scripts/design_table/dimension_layout.gd")

const LINE_WIDTH := 0.0035 ## world metres: the rubber band, the cursor ring and the sheet's marks
const OBJECT_WIDTH := 0.0042 ## the visible outline of the sketch: the heaviest line, as on a drawing
const CONSTRUCTION_WIDTH := 0.0020 ## construction geometry: thin, in a chain (long dash, short dash) pattern
const DIM_WIDTH := 0.0016 ## dimension lines, extension lines, leaders: thinner still
const UNDERLAY_WIDTH := 0.0075 ## the dark edge under an object line, so it reads on a white part and on the dark slab alike
const UNDERLAY := Color(0.02, 0.05, 0.10, 0.85)
const THIN_UNDERLAY := Color(0.02, 0.05, 0.10, 0.55)
const CHAIN := [0.013, 0.004, 0.0035, 0.004] ## world metres: dash, gap, dot, gap
const ARROW_LENGTH := 0.011
const DIM_OFFSET := 0.030 ## how far a dimension line stands off the geometry
const DIM_GAP := 0.004 ## the small gap between the geometry and an extension line
const DIM_OVERSHOOT := 0.006
const REF_COLOUR := Color(0.62, 0.78, 0.98, 0.95) ## the part's own edges and corners, seen through the sketch: reference geometry, quieter than the sketch
const REF_FAR_COLOUR := Color(0.62, 0.78, 0.98, 0.50) ## ...those that lie off the sketch plane, projected onto it
const REF_WIDTH := 0.0018
const REF_POINT := 0.0034
const OBJECT_COLOUR := Color(0.96, 0.98, 1.0)
const CONSTRUCTION_COLOUR := Color(0.58, 0.70, 0.84)
const DIM_COLOUR := Color(0.55, 0.88, 1.0)
const ORIGIN_COLOUR := Color(1.0, 0.92, 0.45)
const POINT_SIZE := 0.0036
const LIFT := 0.0012 ## world metres the drawing floats off the sheet, so it never z-fights it
const CIRCLE_SEGMENTS := 56
const LABEL_PIXEL := 0.00035 ## world metres per label pixel
const LABEL_FONT := 40

var plane: Dictionary = {}
var window_m := Vector2(0.8, 0.4) ## the window's size in the world, metres: fixed
var canvas_scale := 0.003 ## the part's scale: world metres per sketch (= part) mm
var sheet_size := Vector2(100.0, 100.0) ## the window's size in sketch mm, u by v: window_m / canvas_scale
var sheet_centre := Vector2.ZERO ## the sketch uv at the window's middle: where the part is under the window
var grid_target_m := 0.016 ## the minor grid lines are about this far apart in the world

var _refs: RefCounted = null ## part_references.gd: the part's geometry projected onto the sketch plane (or null)
var _refs_node: MeshInstance3D
var _refs_hover: MeshInstance3D
var _refs_scale := 0.0 ## the scale and window the reference drawing was built for
var _refs_centre := Vector2(INF, INF)
var _canvas: Node3D
var _readout: Label3D
var _readout_text := ""
var _ring: TorusMesh
var _sheet: MeshInstance3D
var _sheet_material: ShaderMaterial
var _geo: MeshInstance3D
var _preview: MeshInstance3D
var _cursor: MeshInstance3D
var _cursor_material: StandardMaterial3D
var _dims: MeshInstance3D
var _labels: Node3D
var _ghost_text_uv := {} ## ghost key -> where its text sits on the drawing (what pointing at it means)
var _line_material: ShaderMaterial
var _tokens: Resource
var _geo_state := {}


func setup(p_plane: Dictionary, p_window_m: Vector2, p_centre: Vector2, p_scale: float, tokens: Resource) -> void:
	plane = p_plane
	window_m = p_window_m
	canvas_scale = maxf(p_scale, 0.000001)
	sheet_centre = p_centre
	sheet_size = window_m / canvas_scale
	_tokens = tokens
	_line_material = ShaderMaterial.new()
	_line_material.shader = LINE_SHADER
	_line_material.render_priority = 2

	_sheet = MeshInstance3D.new()
	_sheet.name = "Sheet"
	var quad := QuadMesh.new()
	quad.size = sheet_size
	_sheet_material = ShaderMaterial.new()
	_sheet_material.shader = GRID_SHADER
	_sheet_material.render_priority = 0
	var accent: Color = tokens.accent
	_sheet_material.set_shader_parameter("tint", Color(accent.r, accent.g, accent.b, 0.07))
	_sheet_material.set_shader_parameter("line_color", accent.lightened(0.45))
	quad.material = _sheet_material
	_sheet.mesh = quad
	add_child(_sheet)

	# everything drawn is in sketch uv (u, v, height off the sheet), and this node is the sketch plane's own frame
	_canvas = Node3D.new()
	_canvas.name = "Canvas"
	_canvas.transform = Transform3D(Basis(plane["x"], plane["y"], plane["n"]), plane["origin"])
	add_child(_canvas)
	_geo = _new_mesh_node("Drawing")
	_dims = _new_mesh_node("Dimensions")
	_preview = _new_mesh_node("Preview")
	_refs_node = _new_mesh_node("PartGeometry")
	_refs_hover = _new_mesh_node("PartGeometryHover")
	_cursor = MeshInstance3D.new()
	_cursor.name = "Cursor"
	_ring = TorusMesh.new()
	_ring.rings = 24
	_ring.ring_segments = 8
	_cursor_material = StandardMaterial3D.new()
	_cursor_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cursor_material.render_priority = 3
	_ring.material = _cursor_material
	_cursor.mesh = _ring
	_cursor.basis = Basis(Vector3.RIGHT, PI * 0.5) # the ring lies in the sheet (a torus's axis is its y)
	_cursor.visible = false
	_canvas.add_child(_cursor)
	_labels = Node3D.new()
	_labels.name = "Labels"
	_canvas.add_child(_labels)
	_readout = Label3D.new()
	_readout.name = "Readout"
	_readout.font_size = 32
	_readout.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_readout.double_sided = true
	_readout.shaded = false
	_readout.no_depth_test = true
	_readout.render_priority = 5
	_readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_readout.outline_size = 10
	_readout.outline_modulate = Color(0.02, 0.04, 0.08, 0.95)
	_readout.modulate = Color(accent.lightened(0.5), 0.9)
	add_child(_readout)
	_apply_frame()
	rebuild(null)


func set_frame(p_scale: float, p_centre: Vector2) -> bool:
	## The part was moved or scaled under the window: `p_centre` is the sketch uv now at the window's middle, `p_scale` the part's
	## world metres per mm. True if the scale changed (line widths and labels are sized for it, so the caller rebuilds the drawing).
	var scale := maxf(p_scale, 0.000001)
	var zoomed := not is_equal_approx(canvas_scale, scale)
	canvas_scale = scale
	sheet_centre = p_centre
	sheet_size = window_m / canvas_scale
	_apply_frame()
	return zoomed


func _apply_frame() -> void:
	if not (_sheet.mesh as QuadMesh).size.is_equal_approx(sheet_size):
		(_sheet.mesh as QuadMesh).size = sheet_size
	_sheet.transform = Transform3D(Basis(plane["x"], plane["y"], plane["n"]), SketchMath.from_sheet(sheet_centre, plane))
	_line_material.set_shader_parameter("clip_centre", sheet_centre)
	_line_material.set_shader_parameter("clip_half", sheet_size * 0.5)
	_ring.inner_radius = 0.006 / canvas_scale
	_ring.outer_radius = 0.0085 / canvas_scale
	for label in _labels.get_children():
		label.visible = contains(label.get_meta("uv"))
	_update_grid()
	_update_readout()


func _update_readout() -> void:
	## The line in the window's corner that says the grid spacing.
	var text := "Grid %s" % format_length(grid_step())
	var half := sheet_size * 0.5
	_readout.pixel_size = LABEL_PIXEL * 0.85 / canvas_scale
	_readout.position = SketchMath.from_sheet(sheet_centre + Vector2(-half.x * 0.97, -half.y * 0.9), plane) + (plane["n"] as Vector3) * (LIFT * 3.0 / canvas_scale)
	_readout.basis = Basis(plane["x"], plane["y"], plane["n"])
	if text != _readout_text:
		_readout_text = text
		_readout.text = text


func readout_text() -> String:
	return _readout_text


static func format_length(mm: float) -> String:
	if mm >= 1000.0:
		return "%s m" % _compact(mm / 1000.0)
	return "%s mm" % _compact(mm)


static func _compact(v: float) -> String:
	if v >= 100.0:
		return str(int(round(v)))
	if v >= 10.0:
		return "%.0f" % v
	if v >= 1.0:
		return ("%.1f" % v).rstrip("0").rstrip(".")
	return ("%.3f" % v).rstrip("0").rstrip(".")


# --- The part's own geometry, seen through the sketch ------------------------------------------------

func set_references(refs: RefCounted) -> void:
	## Shows the part's edges and corners (projected onto the sketch plane) as quiet reference lines under the sketch: what you aim at to dimension
	## to them or start a line on them.
	_refs = refs
	_refs_scale = 0.0
	_rebuild_references()


func refresh_references() -> void:
	## Called every frame by the editor: the reference drawing is built for a window a bit bigger than the one shown, so it only needs rebuilding
	## when the part has been slid a long way (a zoom rebuilds it with the rest of the drawing).
	if _refs == null:
		return
	if _refs_centre.distance_to(sheet_centre) > minf(sheet_size.x, sheet_size.y) * 0.3 or not is_equal_approx(_refs_scale, canvas_scale):
		_rebuild_references()


func _rebuild_references() -> void:
	_refs_scale = canvas_scale
	_refs_centre = sheet_centre
	if _refs == null or _refs.is_empty():
		_refs_node.mesh = null
		return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var lo := sheet_centre - sheet_size
	var hi := sheet_centre + sheet_size
	for e in _refs.edges_in(lo, hi):
		var colour: Color = REF_COLOUR if float(e["depth"]) < 0.05 else REF_FAR_COLOUR
		var segs: PackedVector2Array = e["segs"]
		for i in range(0, segs.size() - 1, 2):
			_ribbon(verts, colors, segs[i], segs[i + 1], REF_WIDTH + 0.0016, THIN_UNDERLAY, 0.3) # dark under the light, so it reads on a white part too
			_ribbon(verts, colors, segs[i], segs[i + 1], REF_WIDTH, colour, 0.4)
	for v in _refs.vertices_in(lo, hi):
		_marker(verts, colors, v["uv"], REF_POINT + 0.0018, UNDERLAY, 0.45)
		_marker(verts, colors, v["uv"], REF_POINT, REF_COLOUR if float(v["depth"]) < 0.05 else REF_FAR_COLOUR, 0.5)
	_set_surface(_refs_node, verts, colors)


func set_reference_hover(ref: Dictionary) -> void:
	## Lights the part vertex or edge under the laser (an empty dictionary clears it).
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var warn: Color = _tokens.warn
	match str(ref.get("kind", "")):
		"vertex":
			var v: Dictionary = _vertex_of(ref)
			if not v.is_empty():
				_marker(verts, colors, v["uv"], POINT_SIZE * 3.2, UNDERLAY, 1.3)
				_marker(verts, colors, v["uv"], POINT_SIZE * 2.2, warn, 1.6)
		"edge":
			_ribbon(verts, colors, ref["a"], ref["b"], OBJECT_WIDTH + (UNDERLAY_WIDTH - LINE_WIDTH), UNDERLAY, 1.0)
			_ribbon(verts, colors, ref["a"], ref["b"], OBJECT_WIDTH * 1.2, warn, 1.2)
	_set_surface(_refs_hover, verts, colors)


func _vertex_of(ref: Dictionary) -> Dictionary:
	if _refs == null:
		return {}
	for v in _refs.vertices:
		if v["body"] == ref["body"] and int(v["index"]) == int(ref["index"]):
			return v
	return {}


func grid_step() -> float:
	## The minor grid spacing now, mm.
	return SketchMath.grid_step(grid_target_m / canvas_scale)


func _update_grid() -> void:
	_sheet_material.set_shader_parameter("sheet_mm", sheet_size)
	_sheet_material.set_shader_parameter("centre_mm", sheet_centre)
	_sheet_material.set_shader_parameter("minor_mm", grid_step())
	_sheet_material.set_shader_parameter("fade_mm", 0.05 / canvas_scale)


func contains(uv: Vector2) -> bool:
	## True if a sketch position is inside the window (what the canvas shows now).
	var half := sheet_size * 0.5
	return absf(uv.x - sheet_centre.x) <= half.x and absf(uv.y - sheet_centre.y) <= half.y


func _new_mesh_node(node_name: String) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = node_name
	node.material_override = _line_material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_canvas.add_child(node)
	return node


# --- Geometry helpers (sketch uv -> the canvas's own space; the canvas node carries it to the part) ---------

func _u(world: float) -> float:
	## A size chosen in world metres, in sketch mm at the canvas's zoom.
	return world / canvas_scale


func canvas_point(uv: Vector2, lift: float = 1.0) -> Vector3:
	return Vector3(uv.x, uv.y, LIFT * lift / canvas_scale)


func _ribbon(verts: PackedVector3Array, colors: PackedColorArray, a: Vector2, b: Vector2, width_world: float, colour: Color, lift: float = 1.0) -> void:
	var dir := b - a
	if dir.length() < 0.00001:
		return
	var half := _u(width_world) * 0.5
	var side := Vector2(-dir.y, dir.x).normalized() * half
	var pa := canvas_point(a + side, lift)
	var pb := canvas_point(b + side, lift)
	var pc := canvas_point(b - side, lift)
	var pd := canvas_point(a - side, lift)
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
	var h := _u(size_world) * 0.5
	var c := [uv + Vector2(-h, -h), uv + Vector2(h, -h), uv + Vector2(h, h), uv + Vector2(-h, h)]
	var p := c.map(func(q): return canvas_point(q, lift))
	verts.append_array([p[0], p[1], p[2], p[0], p[2], p[3]])
	for i in 6:
		colors.append(colour)


func _dashed(verts: PackedVector3Array, colors: PackedColorArray, pts: Array, width_world: float, colour: Color, closed: bool, lift: float = 1.0) -> void:
	## A polyline drawn in the chain pattern (CHAIN): the construction-line style. The pattern runs on across the polyline's joints.
	var path := pts.duplicate()
	if closed and pts.size() > 2:
		path.append(pts[0])
	var k := 1.0 / canvas_scale
	var idx := 0
	var left: float = float(CHAIN[0]) * k
	for i in path.size() - 1:
		var a: Vector2 = path[i]
		var b: Vector2 = path[i + 1]
		var seg := a.distance_to(b)
		if seg < 0.000001:
			continue
		var dir := (b - a) / seg
		var pos := 0.0
		while pos < seg:
			var step := minf(left, seg - pos)
			if idx % 2 == 0:
				_ribbon(verts, colors, a + dir * pos, a + dir * (pos + step), width_world, colour, lift)
			pos += step
			left -= step
			if left <= 0.000000001:
				idx = (idx + 1) % CHAIN.size()
				left = float(CHAIN[idx]) * k


func _arrow(verts: PackedVector3Array, colors: PackedColorArray, tip: Vector2, dir: Vector2, colour: Color, lift: float = 1.2) -> void:
	## A filled arrowhead with its tip at `tip`, pointing along `dir`.
	var length := ARROW_LENGTH / canvas_scale
	var d := dir.normalized()
	var base := tip - d * length
	var side := Vector2(-d.y, d.x) * length * 0.26
	verts.append_array([canvas_point(tip, lift), canvas_point(base + side, lift), canvas_point(base - side, lift)])
	for i in 3:
		colors.append(colour)


func _stroke(verts: PackedVector3Array, colors: PackedColorArray, pts: Array, closed: bool, construction: bool, colour: Color, emphasised: bool) -> void:
	## One piece of the sketch's own geometry: an object line (heavy, solid, on a dark edge) or a construction line (thin, chain pattern).
	if construction:
		_dashed(verts, colors, pts, CONSTRUCTION_WIDTH * (1.6 if emphasised else 1.0), colour, closed, 1.0)
	else:
		var w := OBJECT_WIDTH * (1.35 if emphasised else 1.0)
		_polyline(verts, colors, pts, w + (UNDERLAY_WIDTH - LINE_WIDTH), UNDERLAY, closed, 0.8)
		_polyline(verts, colors, pts, w, colour, closed)


func _draw_dimension(verts: PackedVector3Array, colors: PackedColorArray, layout: Dictionary, colour: Color) -> void:
	for seg in layout["segments"]:
		_ribbon(verts, colors, seg[0], seg[1], DIM_WIDTH + 0.0014, THIN_UNDERLAY, 0.9)
		_ribbon(verts, colors, seg[0], seg[1], DIM_WIDTH, colour, 1.1)
	for arc in layout["arcs"]:
		_polyline(verts, colors, arc, DIM_WIDTH + 0.0014, THIN_UNDERLAY, false, 0.9)
		_polyline(verts, colors, arc, DIM_WIDTH, colour, false, 1.1)
	for ar in layout["arrows"]:
		_arrow(verts, colors, ar[0], ar[1], colour, 1.2)


static func circle_points(centre: Vector2, radius: float, segments: int) -> Array:
	var out: Array = []
	for i in segments:
		var a := TAU * float(i) / float(segments)
		out.append(centre + Vector2(cos(a), sin(a)) * radius)
	return out


static func slot_outline(a: Vector2, b: Vector2, radius: float, arc_segments: int) -> Array:
	## The closed outline of a slot: two straight sides and a half circle round each end centre.
	var out: Array = []
	var along := (b - a)
	if along.length() < 0.00001 or radius < 0.00001:
		return out
	var base := along.angle()
	for i in arc_segments + 1: # the half circle round b, from one side to the other
		var t := base - PI * 0.5 + PI * float(i) / float(arc_segments)
		out.append(b + Vector2(cos(t), sin(t)) * radius)
	for i in arc_segments + 1: # and round a
		var t2 := base + PI * 0.5 + PI * float(i) / float(arc_segments)
		out.append(a + Vector2(cos(t2), sin(t2)) * radius)
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
	## The origin's axes, then every entity of the session drawn as a drawing draws it: object lines heavy and solid, construction lines thin
	## and chained, a centre mark on every circle, and the sketch's dimensions with their extension lines, arrows and text. `highlight` is a list
	## of {kind, id} (the picked entities); `hover` the one under the laser.
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var accent: Color = _tokens.accent
	var warn: Color = _tokens.warn
	var origin_mark := 0.05 / canvas_scale ## the origin's cross reaches this far (about 5 cm of world) on each axis
	_ribbon(verts, colors, Vector2.ZERO, Vector2(origin_mark, 0), LINE_WIDTH * 0.8, Color(1.0, 0.35, 0.35, 0.9), 0.7) # u axis
	_ribbon(verts, colors, Vector2.ZERO, Vector2(0, origin_mark), LINE_WIDTH * 0.8, Color(0.4, 0.95, 0.5, 0.9), 0.7) # v axis

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
			var lit: bool = selected.has(key) or key == hovered
			var construction: bool = l.get("construction", false)
			var colour: Color = warn if lit else (CONSTRUCTION_COLOUR if construction else OBJECT_COLOUR)
			_stroke(verts, colors, [session.points[l["a"]], session.points[l["b"]]], false, construction, colour, lit)
		for id in session.circles:
			var c: Dictionary = session.circles[id]
			if not session.points.has(c["c"]) or not session.points.has(c["p"]):
				continue
			var key: String = "circle:" + id
			var lit: bool = selected.has(key) or key == hovered
			var construction: bool = c.get("construction", false)
			var colour: Color = warn if lit else (CONSTRUCTION_COLOUR if construction else OBJECT_COLOUR)
			var centre: Vector2 = session.points[c["c"]]
			var radius := centre.distance_to(session.points[c["p"]])
			_stroke(verts, colors, circle_points(centre, radius, CIRCLE_SEGMENTS), true, construction, colour, lit)
			# the centre mark: a pair of chain lines crossing at the centre and reaching a little past the circle
			var reach := radius + 0.007 / canvas_scale
			_dashed(verts, colors, [centre + Vector2(-reach, 0), centre + Vector2(reach, 0)], CONSTRUCTION_WIDTH, CONSTRUCTION_COLOUR, false, 0.9)
			_dashed(verts, colors, [centre + Vector2(0, -reach), centre + Vector2(0, reach)], CONSTRUCTION_WIDTH, CONSTRUCTION_COLOUR, false, 0.9)
		for id in session.arcs:
			var a: Dictionary = session.arcs[id]
			if not session.points.has(a["c"]) or not session.points.has(a["s"]) or not session.points.has(a["e"]):
				continue
			var key: String = "arc:" + id
			var lit: bool = selected.has(key) or key == hovered
			var construction: bool = a.get("construction", false)
			var colour: Color = warn if lit else (CONSTRUCTION_COLOUR if construction else OBJECT_COLOUR)
			var sweep := arc_points(session.points[a["c"]], session.points[a["s"]], session.points[a["e"]], 32)
			_stroke(verts, colors, sweep, false, construction, colour, lit)
			var arm := 0.005 / canvas_scale # an arc's centre is marked with a small cross
			var ac: Vector2 = session.points[a["c"]]
			_ribbon(verts, colors, ac + Vector2(-arm, 0), ac + Vector2(arm, 0), CONSTRUCTION_WIDTH, CONSTRUCTION_COLOUR, 0.9)
			_ribbon(verts, colors, ac + Vector2(0, -arm), ac + Vector2(0, arm), CONSTRUCTION_WIDTH, CONSTRUCTION_COLOUR, 0.9)
		for id in session.points:
			var key: String = "point:" + id
			if session.is_origin(id):
				# The sketch origin: a bigger, brighter marker than an ordinary point (it is where every dimension can start from).
				var origin_colour: Color = warn if (selected.has(key) or key == hovered) else ORIGIN_COLOUR
				_marker(verts, colors, session.points[id], POINT_SIZE * 3.2, UNDERLAY, 1.3)
				_marker(verts, colors, session.points[id], POINT_SIZE * 2.4, origin_colour, 1.6)
				_marker(verts, colors, session.points[id], POINT_SIZE * 1.0, UNDERLAY, 1.9)
				continue
			var colour: Color = warn if (selected.has(key) or key == hovered) else (CONSTRUCTION_COLOUR if session.point_locked.get(id, false) else accent.lightened(0.3))
			_marker(verts, colors, session.points[id], POINT_SIZE * 1.9, UNDERLAY, 1.3)
			_marker(verts, colors, session.points[id], POINT_SIZE, colour, 1.6)
	_set_surface(_geo, verts, colors)
	if _refs != null and not is_equal_approx(_refs_scale, canvas_scale):
		_rebuild_references()
	_rebuild_dimensions(session)


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
	_cursor.position = canvas_point(uv, 2.0)
	var colour: Color = _tokens.text
	match kind:
		"point": colour = Color(0.45, 1.0, 0.6)
		"vertex", "midpoint", "curve": colour = _tokens.accent
		"origin": colour = ORIGIN_COLOUR
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
			"slot":
				if taps.size() == 1:
					_ribbon(verts, colors, first, c, LINE_WIDTH * 0.6, colour, 1.2)
				else:
					var second: Vector2 = taps[1]
					var width: float = c.distance_to(Geometry2D.get_closest_point_to_segment(c, first, second))
					_polyline(verts, colors, slot_outline(first, second, width, 16), LINE_WIDTH, colour, true, 1.2)
					_ribbon(verts, colors, first, second, LINE_WIDTH * 0.5, colour, 1.2)
			"polygon":
				var r2 := first.distance_to(c)
				var a0 := (c - first).angle()
				var corners: Array = []
				for i in maxi(sides, 3):
					var a := a0 + TAU * float(i) / float(maxi(sides, 3))
					corners.append(first + Vector2(cos(a), sin(a)) * r2)
				_polyline(verts, colors, corners, LINE_WIDTH, colour, true, 1.2)
	_set_surface(_preview, verts, colors)


# --- Dimensions ---------------------------------------------------------------------------

var _last_session = null


func _dim_params(session) -> Dictionary:
	## The sizes and the "which side is outside" a dimension is laid out with, for the zoom the part has now.
	var k := 1.0 / canvas_scale
	var text_h := float(LABEL_FONT) * LABEL_PIXEL * k
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var obstacles: Array = []
	var segments: Array = []
	var interiors: Array = []
	if session != null:
		for lid in session.lines:
			var ln: Dictionary = session.lines[lid]
			if session.points.has(ln["a"]) and session.points.has(ln["b"]):
				segments.append([session.points[ln["a"]], session.points[ln["b"]]])
		for cid in session.circles:
			var cc: Dictionary = session.circles[cid]
			if session.points.has(cc["c"]) and session.points.has(cc["p"]):
				var ring_pts := circle_points(session.points[cc["c"]], session.points[cc["c"]].distance_to(session.points[cc["p"]]), 16)
				for i in ring_pts.size():
					segments.append([ring_pts[i], ring_pts[(i + 1) % ring_pts.size()]])
		for sid in session.shapes:
			var ring: Array = []
			for pid in session.shapes[sid].get("point_ids", []):
				if session.points.has(str(pid)):
					ring.append(session.points[str(pid)])
			if ring.size() >= 3:
				interiors.append(ring)
		for id in session.points:
			lo = lo.min(session.points[id])
			hi = hi.max(session.points[id])
			obstacles.append(session.points[id])
	var centroid := (lo + hi) * 0.5 if lo.x != INF else Vector2.ZERO
	return {"offset": DIM_OFFSET * k, "arrow": ARROW_LENGTH * k, "gap": DIM_GAP * k, "over": DIM_OVERSHOOT * k, "centroid": centroid, "obstacles": obstacles, "obstacle_segments": segments, "interiors": interiors, "text_h": text_h, "text_w": text_h * 0.6}


func _layout_for(spec: Dictionary, text: String, session) -> Dictionary:
	var params := _dim_params(session)
	params["text_w"] = float(params["text_h"]) * 0.6 * float(maxi(text.length(), 1))
	return DimensionLayout.layout(spec, params)


func _rebuild_dimensions(session, ghosts: Array = []) -> void:
	## The drawn dimensions: each existing one in the dimension colour, each candidate for the picked entities (ghosts) in the warning colour,
	## both with extension lines, a dimension line, arrowheads and the value written along the line.
	_last_session = session
	for child in _labels.get_children():
		_labels.remove_child(child)
		child.queue_free()
	_ghost_text_uv.clear()
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	if session != null:
		for item in session.dimension_items():
			var layout := _layout_for(item["spec"], str(item["text"]), session)
			if (layout["segments"] as Array).is_empty() and (layout["arcs"] as Array).is_empty() and (layout["arrows"] as Array).is_empty():
				continue
			_draw_dimension(verts, colors, layout, DIM_COLOUR)
			_label_on_sheet(str(item["text"]), layout, DIM_COLOUR)
	for g in ghosts:
		var spec: Dictionary = g.get("spec", {})
		if spec.is_empty():
			continue
		var kind := "radius" if g["key"] == "radius" else ("diameter" if g["key"] == "diameter" else ("angle" if g["key"] == "angle" else "linear"))
		var text: String = session.dimension_text(kind, float(g["value"])) if session != null else str(g["value"])
		var layout := _layout_for(spec, text, session)
		_draw_dimension(verts, colors, layout, _tokens.warn)
		_label_on_sheet(text, layout, _tokens.warn)
		_ghost_text_uv[str(g["key"])] = layout["text_uv"]
	_set_surface(_dims, verts, colors)


func _label_on_sheet(text: String, layout: Dictionary, colour: Color) -> void:
	## The value, lying IN the sketch plane along its dimension line (upright: left to right or bottom to top), not a sign turned to face you.
	var label := Label3D.new()
	label.text = text
	label.font_size = LABEL_FONT
	label.pixel_size = LABEL_PIXEL / canvas_scale
	label.modulate = colour
	label.outline_size = 12
	label.outline_modulate = Color(0.02, 0.04, 0.08, 0.95)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = true
	label.shaded = false
	label.no_depth_test = true
	label.render_priority = 5
	var angle: float = float(layout["text_angle"])
	# in the canvas's own space the sketch's u is x, v is y and the sheet's normal is z (the canvas node turns it onto the part's plane)
	label.transform = Transform3D(Basis(Vector3(cos(angle), sin(angle), 0.0), Vector3(-sin(angle), cos(angle), 0.0), Vector3(0, 0, 1)), canvas_point(layout["text_uv"], 3.0))
	label.set_meta("uv", layout["text_uv"])
	label.visible = contains(layout["text_uv"]) # a label can't be clipped by the line shader: it shows while its middle is in the window
	_labels.add_child(label)


func show_ghosts(ghosts: Array) -> void:
	## Candidate dimensions for the picked entities, drawn on the sheet where you point at the value to type it.
	_rebuild_dimensions(_last_session, ghosts)


func ghost_near(ghosts: Array, uv: Vector2, radius: float) -> String:
	## The key of the dimension candidate whose label is nearest `uv` within `radius` (mm), or "".
	var best := ""
	var best_d := radius
	for g in ghosts:
		var d: float = uv.distance_to(_ghost_text_uv.get(str(g["key"]), g["uv"]))
		if d <= best_d:
			best_d = d
			best = g["key"]
	return best


func label_texts() -> Array:
	return _labels.get_children().map(func(l): return (l as Label3D).text)
