extends Node3D
## The three fixed reference planes (XY, XZ, YZ) drawn as faint squares through the part's origin, so a sketch can be started
## on one by pointing the laser at it — "pick a sketch plane by lasering a face or plane in the table space". Faces of the part
## are picked by the ordinary ray test; these planes have no collider (they'd shield the part), so they're hit-tested by hand
## here with the same ray-plane maths the sketch sheet uses. A child of the table's copy of the part: its frame is the part's
## own, in millimetres, and the colours match DIDSA-CAD's (XY blue, XZ green, YZ red).

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")

const COLOURS := {"XY": Color(0.35, 0.55, 1.0), "XZ": Color(0.40, 0.90, 0.50), "YZ": Color(1.0, 0.45, 0.45)}
const IDLE_ALPHA := 0.13
const HOT_ALPHA := 0.42

var extent := 100.0 ## mm, each square's side
var hovered := ""
var chosen := ""

var _quads := {}
var _materials := {}
var _centres := {} ## plane name -> the square's middle in the part's frame
var _scale_m_per_mm := 0.003


func setup(p_extent: float, part_centre: Vector3, scale_m_per_mm: float) -> void:
	extent = p_extent
	_scale_m_per_mm = maxf(scale_m_per_mm, 0.000001)
	for name in SketchMath.FIXED:
		var b := SketchMath.fixed_basis(name)
		# Centre each square on the part: its middle projected onto the plane.
		var centre: Vector3 = part_centre - (b["n"] as Vector3) * (part_centre - (b["origin"] as Vector3)).dot(b["n"])
		_centres[name] = centre
		var node := MeshInstance3D.new()
		node.name = "Plane" + name
		var quad := QuadMesh.new()
		quad.size = Vector2(extent, extent)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 0
		quad.material = mat
		node.mesh = quad
		node.transform = Transform3D(Basis(b["x"], b["y"], b["n"]), centre)
		add_child(node)
		var label := Label3D.new()
		label.text = name
		label.font_size = 40
		label.pixel_size = 0.0004 / _scale_m_per_mm
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.outline_size = 8
		label.modulate = COLOURS[name]
		label.position = Vector3(extent * 0.42, extent * 0.42, 0.0)
		node.add_child(label)
		_quads[name] = node
		_materials[name] = mat
	_restyle()


func intersect(origin_local: Vector3, dir_local: Vector3) -> Dictionary:
	## The nearest plane square the ray meets, in the part's frame: {plane, t, point} or {} (t in part-mm along dir_local,
	## so only comparable between planes of this ray).
	var best := {}
	var best_t := INF
	var half := extent * 0.5
	for name in SketchMath.FIXED:
		var b := SketchMath.fixed_basis(name)
		var denom: float = dir_local.dot(b["n"])
		if absf(denom) < 0.000001:
			continue
		var t: float = ((b["origin"] as Vector3) - origin_local).dot(b["n"]) / denom
		if t < 0.0 or t >= best_t:
			continue
		var point: Vector3 = origin_local + dir_local * t
		var rel: Vector3 = point - (_centres[name] as Vector3)
		if absf(rel.dot(b["x"])) <= half and absf(rel.dot(b["y"])) <= half:
			best_t = t
			best = {"plane": name, "t": t, "point": point}
	return best


func set_hover(plane_name: String) -> void:
	if hovered != plane_name:
		hovered = plane_name
		_restyle()


func set_chosen(plane_name: String) -> void:
	chosen = plane_name
	_restyle()


func set_markers_visible(on: bool) -> void:
	visible = on


func _restyle() -> void:
	for name in _materials:
		var c: Color = COLOURS[name]
		var alpha := IDLE_ALPHA
		if name == hovered or name == chosen:
			alpha = HOT_ALPHA
		(_materials[name] as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, alpha)
