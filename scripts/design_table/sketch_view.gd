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
const SketchSession := preload("res://scripts/design_table/sketch_session.gd")

const LINE_WIDTH := 0.00245 ## world metres: the rubber band, the cursor ring and the sheet's marks
const OBJECT_WIDTH := 0.00294 ## the visible outline of the sketch: the heaviest line, as on a drawing
const CONSTRUCTION_WIDTH := 0.0014 ## construction geometry: thin, in a chain (long dash, short dash) pattern
const DIM_WIDTH := 0.00112 ## dimension lines, extension lines, leaders: thinner still
const UNDERLAY_WIDTH := 0.00525 ## the dark edge under an object line, so it reads on a white part and on the dark slab alike
const UNDERLAY := Color(0.02, 0.05, 0.10, 0.85)
const PREVIEW_EDGE := Color(0.02, 0.05, 0.10, 0.95) ## the dark edge under the rubber band
const PREVIEW_EDGE_EXTRA := 0.0025 ## ...this much wider than the band, so it shows on either side
const THIN_UNDERLAY := Color(0.02, 0.05, 0.10, 0.55)
const CHAIN := [0.013, 0.004, 0.0035, 0.004] ## world metres: dash, gap, dot, gap
const ARROW_LENGTH := 0.011
const DIM_OFFSET := 0.030 ## how far a dimension line stands off the geometry
const DIM_GAP := 0.004 ## the small gap between the geometry and an extension line
const DIM_OVERSHOOT := 0.006
const REF_COLOUR := Color(0.62, 0.78, 0.98, 0.95) ## the part's own edges and corners, seen through the sketch: reference geometry, quieter than the sketch
const REF_FAR_COLOUR := Color(0.62, 0.78, 0.98, 0.50) ## ...those that lie off the sketch plane, projected onto it
const REF_WIDTH := 0.00126
const REF_USED_COLOUR := Color(0.55, 0.85, 1.0, 1.0) ## a part corner / edge / hole the sketch actually uses (a dimension or constraint goes to it): the part's own geometry, lit a little
const REF_POINT := 0.0034
const OBJECT_COLOUR := Color(0.96, 0.98, 1.0)
const FULL_COLOUR := Color(0.70, 0.98, 0.76) ## object lines of a fully constrained sketch (nothing left to move, tied to the origin)
const FAILED_COLOUR := Color(1.0, 0.36, 0.36) ## what a constraint the solve could not satisfy holds (a conflict that came later; the sketch is over-constrained)
const CONSTRUCTION_COLOUR := Color(0.58, 0.70, 0.84)
const GUIDE_COLOUR := Color(0.45, 1.0, 0.6, 0.9) ## an alignment guide: the snap green
const GUIDE_WIDTH := 0.0014
const KEEP_COLOUR := Color(0.3, 0.92, 1.0, 1.0) ## the ring round the point Merge keeps: the snap-candidate cyan of the flat app
const WOKEN_COLOUR := Color(0.75, 0.88, 1.0, 0.5) ## a line the laser has woken (parallel / perpendicular may be inferred against it): lit faintly
const WOKEN_WIDTH := 0.0030
const DIM_COLOUR := Color(0.55, 0.88, 1.0)
const DRIVEN_COLOUR := Color(0.72, 0.76, 0.82, 0.9) ## a reference (driven) dimension: it measures, it does not drive, so it is quieter and in brackets
const ORIGIN_COLOUR := Color(1.0, 0.92, 0.45)
const LOST_COLOUR := Color(1.0, 0.36, 0.36, 0.95) ## a reference point whose corner of the part can no longer be found
const MOVED_COLOUR := Color(1.0, 0.72, 0.25, 0.95) ## ...one that may have moved to a different corner (confirm it or re-pick)
const POINT_SIZE := 0.0036
const LIFT := 0.0012 ## world metres the drawing floats off the sheet, so it never z-fights it
const CIRCLE_SEGMENTS := 56
const GLYPH_OFFSET := 0.008 ## how far a constraint glyph stands off the entity it holds, in world metres
const GLYPH_STEP := 0.007 ## and the extra for each further glyph on the same entity
const CONSTRAINT_GLYPH_COLOUR := Color(0.55, 0.95, 0.80, 1.0)
const LABEL_PIXEL := 0.00035 ## world metres per label pixel
const LABEL_FONT := 40
const GLYPH_HIT_MM := 0.007 ## world metres: half the side of the square a constraint glyph can be pointed at in (a glyph is small, so this is generous)

var plane: Dictionary = {}
var repick_point := "" ## the flagged reference point the user is choosing a replacement for: drawn extra large
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
var _aids: MeshInstance3D ## the woken lines and the alignment guides
var _keep: MeshInstance3D ## the ring round the point Merge would keep
var _inference_label: Label3D ## the glyph of the relationship the line being drawn would get (H, //, |_, T, on...)
var _cursor: MeshInstance3D
var _cursor_material: StandardMaterial3D
var _dims: MeshInstance3D
var _labels: Node3D
var _constraint_labels: Node3D
var show_dimensions := true ## the Visibility drawer's Dims / Constr. tiles: the open sketch's existing dimensions and constraint glyphs (a dimension candidate of the Dimension tool always shows)
var show_constraints := true
var _annotation_hits: Array = [] ## T5: what a laser can pick among the labels: [{kind: "dimension" | "constraint", id, uv, angle, half: Vector2}] (sketch mm)
var _annotation_hover := "" ## "kind:id" of the label under the laser
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
	_aids = _new_mesh_node("Aids")
	_keep = _new_mesh_node("KeepRing")
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
	_constraint_labels = Node3D.new()
	_constraint_labels.name = "ConstraintGlyphs"
	_canvas.add_child(_constraint_labels)
	_inference_label = Label3D.new()
	_inference_label.name = "InferenceGlyph"
	_inference_label.font_size = LABEL_FONT
	_inference_label.pixel_size = LABEL_PIXEL * 0.9 / canvas_scale
	_inference_label.modulate = CONSTRAINT_GLYPH_COLOUR
	_inference_label.outline_size = 12
	_inference_label.outline_modulate = Color(0.02, 0.04, 0.08, 0.95)
	_inference_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_inference_label.double_sided = true
	_inference_label.shaded = false
	_inference_label.no_depth_test = true
	_inference_label.render_priority = 6
	_inference_label.visible = false
	_canvas.add_child(_inference_label)
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
	for glyph in _constraint_labels.get_children():
		glyph.visible = contains(glyph.get_meta("uv"))
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
			_ribbon(verts, colors, segs[i], segs[i + 1], REF_WIDTH + 0.00112, THIN_UNDERLAY, 0.3) # dark under the light, so it reads on a white part too
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
		"circle_edge":
			_hover_edge_of(verts, colors, ref, warn)
		"edge_midpoint", "edge_point":
			_hover_edge_of(verts, colors, ref["edge"], warn)
		"circle_centre":
			var e := _edge_entry(ref)
			if not e.is_empty() and not (e.get("circle", {}) as Dictionary).is_empty():
				var c: Vector2 = e["circle"]["c"]
				_marker(verts, colors, c, POINT_SIZE * 3.2, UNDERLAY, 1.3)
				_marker(verts, colors, c, POINT_SIZE * 2.2, warn, 1.6)
				_hover_edge_of(verts, colors, ref, warn, 0.6)
	_set_surface(_refs_hover, verts, colors)


func _edge_entry(ref: Dictionary) -> Dictionary:
	## The part's projected edge a reference names (by body and edge index), or {}.
	if _refs == null:
		return {}
	for e in _refs.edges:
		if e["body"] == ref.get("body", "") and int(e["index"]) == int(ref.get("index", -1)):
			return e
	return {}


func _hover_edge_of(verts: PackedVector3Array, colors: PackedColorArray, ref: Dictionary, colour: Color, weight := 1.0) -> void:
	## Lights an edge of the part (a straight one by its two ends, a round one along its whole curve).
	if str(ref.get("kind", "")) == "edge":
		_ribbon(verts, colors, ref["a"], ref["b"], OBJECT_WIDTH + (UNDERLAY_WIDTH - LINE_WIDTH), UNDERLAY, 1.0)
		_ribbon(verts, colors, ref["a"], ref["b"], OBJECT_WIDTH * 1.2 * weight, colour, 1.2)
		return
	var e := _edge_entry(ref)
	if e.is_empty():
		return
	var segs: PackedVector2Array = e["segs"]
	for i in range(0, segs.size() - 1, 2):
		_ribbon(verts, colors, segs[i], segs[i + 1], OBJECT_WIDTH + (UNDERLAY_WIDTH - LINE_WIDTH), UNDERLAY, 1.0)
		_ribbon(verts, colors, segs[i], segs[i + 1], OBJECT_WIDTH * 1.2 * weight, colour, 1.2)


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
		_ribbon(verts, colors, seg[0], seg[1], DIM_WIDTH + 0.00098, THIN_UNDERLAY, 0.9)
		_ribbon(verts, colors, seg[0], seg[1], DIM_WIDTH, colour, 1.1)
	for arc in layout["arcs"]:
		_polyline(verts, colors, arc, DIM_WIDTH + 0.00098, THIN_UNDERLAY, false, 0.9)
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
	_last_highlight = highlight
	_last_hover = hover
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
		# a picked or hovered glyph / dimension lights what it holds
		for a in session.annotations:
			selected.merge(session.constraint_held(str(a["id"])))
		if _annotation_hover != "":
			selected.merge(session.constraint_held(_annotation_hover.substr(_annotation_hover.find(":") + 1)))
		# the sketch's state: fully constrained geometry is tinted, what the solver says conflicts is red
		var base_obj: Color = FULL_COLOUR if session.constraint_state() == "full" else OBJECT_COLOUR
		var failed_e: Dictionary = session.failed_entity_ids()
		var failed_p: Dictionary = session.failed_point_ids()
		for id in session.lines:
			var l: Dictionary = session.lines[id]
			if not session.points.has(l["a"]) or not session.points.has(l["b"]):
				continue
			if session.is_reference(id):
				# the sketch's plumbing to the part's own edge: no line of its own is drawn, the part's edge is lit instead
				_ribbon(verts, colors, session.points[l["a"]], session.points[l["b"]], REF_WIDTH + 0.00056, REF_USED_COLOUR, 0.6)
				continue
			var key: String = "line:" + id
			var sel: bool = selected.has(key)
			var hov: bool = key == hovered and not sel
			var lit: bool = sel
			var construction: bool = l.get("construction", false)
			var colour: Color = _look(sel, hov, FAILED_COLOUR if failed_e.has(id) else (CONSTRUCTION_COLOUR if construction else base_obj), warn, accent)
			_stroke(verts, colors, [session.points[l["a"]], session.points[l["b"]]], false, construction, colour, lit)
		for id in session.circles:
			var c: Dictionary = session.circles[id]
			if not session.points.has(c["c"]) or not session.points.has(c["p"]):
				continue
			if session.is_reference(id):
				var rim_centre: Vector2 = session.points[c["c"]]
				_stroke(verts, colors, circle_points(rim_centre, rim_centre.distance_to(session.points[c["p"]]), CIRCLE_SEGMENTS), true, false, REF_USED_COLOUR, false)
				continue # the part's hole is lit; no construction circle, no centre cross of its own
			var key: String = "circle:" + id
			var sel: bool = selected.has(key)
			var hov: bool = key == hovered and not sel
			var lit: bool = sel
			var construction: bool = c.get("construction", false)
			var colour: Color = _look(sel, hov, FAILED_COLOUR if failed_e.has(id) else (CONSTRUCTION_COLOUR if construction else base_obj), warn, accent)
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
			if session.is_reference(id):
				_stroke(verts, colors, arc_points(session.points[a["c"]], session.points[a["s"]], session.points[a["e"]], 32), false, false, REF_USED_COLOUR, false)
				continue
			var key: String = "arc:" + id
			var sel: bool = selected.has(key)
			var hov: bool = key == hovered and not sel
			var lit: bool = sel
			var construction: bool = a.get("construction", false)
			var colour: Color = _look(sel, hov, FAILED_COLOUR if failed_e.has(id) else (CONSTRUCTION_COLOUR if construction else base_obj), warn, accent)
			var sweep := arc_points(session.points[a["c"]], session.points[a["s"]], session.points[a["e"]], 32)
			_stroke(verts, colors, sweep, false, construction, colour, lit)
			var arm := 0.005 / canvas_scale # an arc's centre is marked with a small cross
			var ac: Vector2 = session.points[a["c"]]
			_ribbon(verts, colors, ac + Vector2(-arm, 0), ac + Vector2(arm, 0), CONSTRUCTION_WIDTH, CONSTRUCTION_COLOUR, 0.9)
			_ribbon(verts, colors, ac + Vector2(0, -arm), ac + Vector2(0, arm), CONSTRUCTION_WIDTH, CONSTRUCTION_COLOUR, 0.9)
		for kind in ["ellipse", "ellipse_arc", "spline"]:
			var source: Dictionary = {"ellipse": session.ellipses, "ellipse_arc": session.ellipse_arcs, "spline": session.splines}[kind]
			for id in source:
				var outline: Array = session.outline_of(kind, id)
				if outline.size() < 2:
					continue
				if session.is_reference(id):
					_stroke(verts, colors, outline, kind == "ellipse", false, REF_USED_COLOUR, false) # the part's own elliptical edge: quiet, like a hole's rim
					continue
				var okey: String = "%s:%s" % [kind, id]
				var osel: bool = selected.has(okey)
				var ohov: bool = okey == hovered and not osel
				var olit: bool = osel
				var oconstruction: bool = source[id].get("construction", false)
				var ocolour: Color = _look(osel, ohov, FAILED_COLOUR if failed_e.has(id) else (CONSTRUCTION_COLOUR if oconstruction else base_obj), warn, accent)
				_stroke(verts, colors, outline, kind == "ellipse", oconstruction, ocolour, olit)
		for id in session.texts:
			var tkey: String = "text:" + id
			var tsel: bool = selected.has(tkey)
			var thov: bool = tkey == hovered and not tsel
			var tlit: bool = tsel
			var tconstruction: bool = session.texts[id].get("construction", false)
			var tcolour: Color = _look(tsel, thov, FAILED_COLOUR if failed_e.has(id) else (CONSTRUCTION_COLOUR if tconstruction else base_obj), warn, accent)
			for poly in session.text_outlines.get(id, []):
				_stroke(verts, colors, poly, true, tconstruction, tcolour, tlit)
		for id in session.points:
			var key: String = "point:" + id
			if session.is_reference(id) and not session.is_origin(id):
				# a corner or hole centre of the part the sketch uses: the part's own corner is lit; no sketch point of its own to see or pick
				var flagged: String = session.reference_status(id)
				if flagged != "lost" and flagged != "potentially_moved":
					_marker(verts, colors, session.points[id], REF_POINT + 0.0018, UNDERLAY, 0.45)
					_marker(verts, colors, session.points[id], REF_POINT, REF_USED_COLOUR, 0.5)
					continue
			if session.is_origin(id):
				# The sketch origin: a bigger, brighter marker than an ordinary point (it is where every dimension can start from).
				var origin_colour: Color = _look(selected.has(key), key == hovered and not selected.has(key), ORIGIN_COLOUR, warn, accent)
				_marker(verts, colors, session.points[id], POINT_SIZE * 3.2, UNDERLAY, 1.3)
				_marker(verts, colors, session.points[id], POINT_SIZE * 2.4, origin_colour, 1.6)
				_marker(verts, colors, session.points[id], POINT_SIZE * 1.0, UNDERLAY, 1.9)
				continue
			var colour: Color = _look(selected.has(key), key == hovered and not selected.has(key), FAILED_COLOUR if failed_p.has(id) else (CONSTRUCTION_COLOUR if session.point_locked.get(id, false) else accent.lightened(0.3)), warn, accent)
			var ref_state: String = session.reference_status(id)
			if ref_state == "lost" or ref_state == "potentially_moved":
				var flag: Color = LOST_COLOUR if ref_state == "lost" else MOVED_COLOUR
				var big := 3.4 if id == repick_point else 2.6
				_marker(verts, colors, session.points[id], POINT_SIZE * (big + 0.9), UNDERLAY, 1.0)
				_marker(verts, colors, session.points[id], POINT_SIZE * big, flag, 1.1)
			_marker(verts, colors, session.points[id], POINT_SIZE * 1.9, UNDERLAY, 1.3)
			_marker(verts, colors, session.points[id], POINT_SIZE, colour, 1.6)
	_set_surface(_geo, verts, colors)
	if _refs != null and not is_equal_approx(_refs_scale, canvas_scale):
		_rebuild_references()
	_rebuild_dimensions(session)


func _look(selected: bool, hovered: bool, base: Color, warn: Color, accent: Color) -> Color:
	## T5: selected is the warning colour, solid; hovered ("about to pick") is the thing's own colour pulled towards the accent, and drawn thinner
	## (the callers pass only `selected` as the heavy flag), so the two never look alike. Both: selected.
	if selected:
		return warn
	return base.lerp(accent, 0.65) if hovered else base


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
		"vertex", "midpoint", "curve", "centre", "edge_midpoint", "edge_point", "face_axis", "parallel", "perpendicular", "collinear", "tangent", "on_curve", "concentric": colour = _tokens.accent
		"origin": colour = ORIGIN_COLOUR
		"hover": colour = _tokens.warn
	_cursor_material.albedo_color = colour


func set_aids(woken: Array, guides: Array) -> void:
	## `woken`: [[a, b]] sheet positions of the lines to light faintly; `guides`: [{from, to}] alignment guides, dashed from the point aligned with to the
	## snapped cursor. Both are drawn on the sheet like the rest of the sketch (so the window clips them), at a constant width on screen.
	if woken.is_empty() and guides.is_empty() and _aids.mesh == null:
		return
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	for seg in woken:
		_ribbon(verts, colors, seg[0], seg[1], WOKEN_WIDTH, WOKEN_COLOUR, 0.9)
	for g in guides:
		_dashed(verts, colors, [g["from"], g["to"]], GUIDE_WIDTH, GUIDE_COLOUR, false, 1.3)
	_set_surface(_aids, verts, colors)


func set_keep_ring(uv: Variant) -> void:
	## A ring round the point Merge would keep (null: none), so the rule is never a surprise.
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	if uv != null:
		var ring := circle_points(uv, _u(POINT_SIZE * 3.6), CIRCLE_SEGMENTS)
		_polyline(verts, colors, ring, LINE_WIDTH + PREVIEW_EDGE_EXTRA, PREVIEW_EDGE, true, 2.2)
		_polyline(verts, colors, ring, LINE_WIDTH, KEEP_COLOUR, true, 2.4)
	_set_surface(_keep, verts, colors)


func set_inference(end_uv: Variant, marker: Variant, infer: Dictionary) -> void:
	## The glyph of the relationship the line being drawn is about to get, at the marker (the tangent point, the nearest point on the curve, the middle of the
	## target line), or beside the end when there is none (an axis). Hidden when there is none.
	if end_uv == null or infer.is_empty():
		_inference_label.visible = false
		return
	var glyph: String = SketchSession.CONSTRAINT_GLYPHS.get(str(infer.get("kind", "")).replace("on_curve", "point_on_line"), "")
	if glyph == "":
		_inference_label.visible = false
		return
	var at: Vector2 = marker if marker != null else (end_uv as Vector2) + Vector2(_u(GLYPH_OFFSET), _u(GLYPH_OFFSET))
	_inference_label.text = glyph
	_inference_label.transform = Transform3D(Basis.IDENTITY, canvas_point(at + Vector2(0, _u(GLYPH_OFFSET)), 4.0))
	_inference_label.visible = contains(at)


func inference_text() -> String:
	return _inference_label.text if _inference_label != null and _inference_label.visible else ""


func set_preview(tool_id: String, taps: Array, cursor_uv: Variant, sides: int = 6) -> void:
	## The shape the next tap would finish, as a rubber band. `taps` are the sheet positions placed so far. Drawn twice, a dark edge wider than
	## the line and the line itself on top, so it reads on a white or pale part as well as on the dark slab (the plain accent line vanished on a body).
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	if cursor_uv != null and not taps.is_empty():
		_preview_pass(verts, colors, tool_id, taps, cursor_uv, sides, PREVIEW_EDGE, PREVIEW_EDGE_EXTRA, 1.1)
		var colour: Color = _tokens.accent.lightened(0.25)
		colour.a = 1.0
		_preview_pass(verts, colors, tool_id, taps, cursor_uv, sides, colour, 0.0, 1.2)
	_set_surface(_preview, verts, colors)


func _preview_pass(verts: PackedVector3Array, colors: PackedColorArray, tool_id: String, taps: Array, cursor_uv: Vector2, sides: int, colour: Color, extra: float, lift: float) -> void:
	var w := LINE_WIDTH + extra
	var c: Vector2 = cursor_uv
	var first: Vector2 = taps[0]
	match tool_id:
		"line":
			_ribbon(verts, colors, first, c, w, colour, lift)
		"rectangle":
			_polyline(verts, colors, [first, Vector2(c.x, first.y), c, Vector2(first.x, c.y)], w, colour, true, lift)
		"circle":
			_polyline(verts, colors, circle_points(first, first.distance_to(c), CIRCLE_SEGMENTS), w, colour, true, lift)
			_ribbon(verts, colors, first, c, w * 0.6, colour, lift)
		"circle3":
			var fit := {"ok": false}
			if taps.size() >= 2:
				fit = SketchMath.circumcircle(first, taps[1], c)
			if bool(fit["ok"]):
				_polyline(verts, colors, circle_points(fit["centre"], float(fit["radius"]), CIRCLE_SEGMENTS), w, colour, true, lift)
			else:
				_ribbon(verts, colors, first, c if taps.size() < 2 else taps[1], w * 0.6, colour, lift)
		"rect_centre":
			var corners := SketchMath.rect_from_centre(first, c)
			if not corners.is_empty():
				_polyline(verts, colors, corners, w, colour, true, lift)
		"rect3":
			var turned := SketchMath.rect_from_three(first, taps[1], c) if taps.size() >= 2 else []
			if not turned.is_empty():
				_polyline(verts, colors, turned, w, colour, true, lift)
			else:
				_ribbon(verts, colors, first, c if taps.size() < 2 else taps[1], w * 0.6, colour, lift)
		"line_mid":
			_ribbon(verts, colors, SketchMath.mirrored_end(first, c), c, w, colour, lift)
		"arc":
			if taps.size() == 1:
				_ribbon(verts, colors, first, c, w * 0.6, colour, lift)
			else:
				var start: Vector2 = taps[1]
				var r := first.distance_to(start)
				var dir := c - first
				var end := first + (dir.normalized() * r if dir.length() > 0.0001 else Vector2(r, 0))
				_polyline(verts, colors, arc_points(first, start, end, 32), w, colour, false, lift)
				_ribbon(verts, colors, first, start, w * 0.5, colour, lift)
		"slot":
			if taps.size() == 1:
				_ribbon(verts, colors, first, c, w * 0.6, colour, lift)
			else:
				var second: Vector2 = taps[1]
				var width: float = c.distance_to(Geometry2D.get_closest_point_to_segment(c, first, second))
				_polyline(verts, colors, slot_outline(first, second, width, 16), w, colour, true, lift)
				_ribbon(verts, colors, first, second, w * 0.5, colour, lift)
		"ellipse", "ellipse_arc":
			if taps.size() == 1:
				_ribbon(verts, colors, first, c, w * 0.6, colour, lift)
			else:
				var major: Vector2 = taps[1]
				var a_len := first.distance_to(major)
				var u := (major - first) / maxf(a_len, 0.0001)
				var b_len := clampf(absf((c - first).cross(u)), a_len * 0.02, a_len) if taps.size() == 2 else clampf(absf(((taps[2] as Vector2) - first).cross(u)), a_len * 0.02, a_len)
				var minor_pt := first + Vector2(-u.y, u.x) * b_len
				_polyline(verts, colors, session_ellipse_points(first, major, minor_pt), w, colour, true, lift)
				_ribbon(verts, colors, first, major, w * 0.5, colour, lift)
		"spline":
			var through: Array = taps.duplicate()
			through.append(c)
			_polyline(verts, colors, through, w, colour, false, lift)
		"polygon":
			var r2 := first.distance_to(c)
			var a0 := (c - first).angle()
			var corners: Array = []
			for i in maxi(sides, 3):
				var a := a0 + TAU * float(i) / float(maxi(sides, 3))
				corners.append(first + Vector2(cos(a), sin(a)) * r2)
			_polyline(verts, colors, corners, w, colour, true, lift)


static func session_ellipse_points(centre: Vector2, major: Vector2, minor: Vector2) -> Array:
	return preload("res://scripts/design_table/sketch_session.gd").ellipse_points(centre, major, minor, 0.0, TAU, 48)


# --- Dimensions ---------------------------------------------------------------------------

var _last_session = null
var _last_highlight: Array = []
var _last_hover: Dictionary = {}


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
	_annotation_hits.clear()
	var selected_labels := {}
	if session != null:
		for a in session.annotations:
			selected_labels["%s:%s" % [a["kind"], a["id"]]] = true
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	for child in _constraint_labels.get_children():
		_constraint_labels.remove_child(child)
		child.queue_free()
	if session != null and show_constraints:
		_draw_constraint_glyphs(session, selected_labels)
	if session != null and show_dimensions:
		for item in session.dimension_items():
			var layout := _layout_for(item["spec"], str(item["text"]), session)
			if (layout["segments"] as Array).is_empty() and (layout["arcs"] as Array).is_empty() and (layout["arrows"] as Array).is_empty():
				continue
			var item_colour: Color = DRIVEN_COLOUR if bool(item.get("driven", false)) else DIM_COLOUR
			if session.failed_constraint_ids.has(str(item["id"])):
				item_colour = FAILED_COLOUR
			var akey := "dimension:%s" % str(item["id"])
			var asel: bool = selected_labels.has(akey)
			var ahov: bool = akey == _annotation_hover and not asel
			if asel:
				item_colour = _tokens.warn
			elif ahov:
				item_colour = DIM_COLOUR.lerp(_tokens.accent, 0.65)
			_draw_dimension(verts, colors, layout, item_colour)
			var dim_label := _label_on_sheet(str(item["text"]), layout, item_colour)
			if ahov or asel:
				dim_label.outline_modulate = _tokens.accent if ahov else _tokens.warn # an outline in the accent: hovered; warn: selected
				dim_label.outline_size = 18
			var text_h: float = float(LABEL_FONT) * LABEL_PIXEL / canvas_scale # (_dim_params' own text height, without its obstacle scan)
			_annotation_hits.append({"kind": "dimension", "id": str(item["id"]), "uv": layout["text_uv"], "angle": float(layout["text_angle"]),
				"half": Vector2(text_h * 0.6 * float(maxi(str(item["text"]).length(), 1)) * 0.5, text_h * 0.5)})
	for g in ghosts:
		var spec: Dictionary = g.get("spec", {})
		if spec.is_empty():
			continue
		var kind: String = str(g.get("text_kind", "linear"))
		var text: String = session.dimension_text(kind, float(g["value"])) if session != null else str(g["value"])
		if bool(g.get("driven", false)):
			text = "(%s)" % text
		var layout := _layout_for(spec, text, session)
		_draw_dimension(verts, colors, layout, _tokens.warn)
		_label_on_sheet(text, layout, _tokens.warn)
		_ghost_text_uv[str(g["key"])] = layout["text_uv"]
	_set_surface(_dims, verts, colors)


func _draw_constraint_glyphs(session, selected_labels: Dictionary = {}) -> void:
	## A short letter beside what each constraint holds (H, V, //, |_, =, T, F...), flat in the sketch plane, stacked when an entity has several.
	var stacked := {}
	var k := 1.0 / canvas_scale
	for item in session.constraint_items():
		var owner := str(item["owner"])
		var n: int = int(stacked.get(owner, 0))
		stacked[owner] = n + 1
		var uv: Vector2 = item["uv"] + (item["normal"] as Vector2) * (GLYPH_OFFSET + GLYPH_STEP * n) * k
		var label := Label3D.new()
		label.text = str(item["text"])
		label.font_size = LABEL_FONT
		label.pixel_size = LABEL_PIXEL * 0.7 / canvas_scale
		var gkey := "constraint:%s" % str(item["id"])
		var gsel: bool = selected_labels.has(gkey)
		var ghov: bool = gkey == _annotation_hover and not gsel
		var glyph_colour: Color = FAILED_COLOUR if session.failed_constraint_ids.has(str(item["id"])) else CONSTRAINT_GLYPH_COLOUR
		label.modulate = _tokens.warn if gsel else (glyph_colour.lerp(_tokens.accent, 0.65) if ghov else glyph_colour)
		label.outline_size = 18 if (gsel or ghov) else 10
		label.outline_modulate = Color(0.02, 0.04, 0.08, 0.95)
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label.double_sided = true
		label.shaded = false
		label.no_depth_test = true
		label.render_priority = 4
		label.transform = Transform3D(Basis.IDENTITY, canvas_point(uv, 3.0))
		label.set_meta("uv", uv)
		label.visible = contains(uv)
		if gsel or ghov:
			label.outline_modulate = _tokens.warn if gsel else _tokens.accent
		_constraint_labels.add_child(label)
		_annotation_hits.append({"kind": "constraint", "id": str(item["id"]), "uv": uv, "angle": 0.0, "half": Vector2(GLYPH_HIT_MM, GLYPH_HIT_MM) / canvas_scale})


func constraint_glyph_texts() -> Array:
	return _constraint_labels.get_children().map(func(l): return (l as Label3D).text)


func _label_on_sheet(text: String, layout: Dictionary, colour: Color) -> Label3D:
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
	return label


func annotation_near(uv: Vector2, reach_mm: float) -> Dictionary:
	## T5: the dimension label or constraint glyph the laser is on at `uv` (sketch mm), within `reach_mm` of its box: {kind, id}, or {}. A label wins over
	## a glyph, the nearer centre over a farther one.
	var best := {}
	var best_d := INF
	for hit in _annotation_hits:
		var delta: Vector2 = uv - (hit["uv"] as Vector2)
		var angle: float = float(hit["angle"])
		var local := Vector2(delta.x * cos(angle) + delta.y * sin(angle), -delta.x * sin(angle) + delta.y * cos(angle))
		var half: Vector2 = hit["half"]
		if absf(local.x) <= half.x + reach_mm and absf(local.y) <= half.y + reach_mm:
			var d := delta.length() - (1000.0 if hit["kind"] == "dimension" else 0.0)
			if d < best_d:
				best_d = d
				best = {"kind": hit["kind"], "id": hit["id"]}
	return best


func set_annotation_hover(kind_id: String) -> void:
	## "kind:id" of the label under the laser ("" = none): drawn with an accent outline, not the selected look. Redraws only when it changes.
	if kind_id == _annotation_hover:
		return
	_annotation_hover = kind_id
	if _last_session != null:
		rebuild(_last_session, _last_highlight, _last_hover) # the geometry the label holds is lit too (and the labels redrawn)
		_rebuild_dimensions(_last_session, _last_session.ghosts)
	else:
		_rebuild_dimensions(_last_session, [])


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
