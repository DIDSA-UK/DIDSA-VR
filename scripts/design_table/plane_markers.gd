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
var _part_centre := Vector3.ZERO
var _custom := {} ## key ("plane:<feature id>") -> basis: the planes the user made with Create Plane, offered like the three fixed ones
const CUSTOM_COLOUR := Color(1.0, 0.82, 0.30)
## Two reasons for a square to be drawn: the editor is PICKING a plane (every square shows), or the Visibility drawer has it on AT REST (the three
## reference planes with one switch, each made plane with its own). Picking is set_markers_visible(); rest is set_rest_fixed / set_rest_custom.
var picking := true
var _rest_fixed := false
var _rest_custom := {} ## key -> bool
var _fixed_hidden := false ## the user switched the reference planes off: not even plane picking draws them (until they are switched on again)


func setup(p_extent: float, part_centre: Vector3, scale_m_per_mm: float) -> void:
	extent = p_extent
	_part_centre = part_centre
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
	for name in _plane_names():
		if not shows(name):
			continue # a square the user hid cannot be pointed at either
		var b: Dictionary = _basis_of(name)
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


func _plane_names() -> Array:
	var names: Array = SketchMath.FIXED.keys()
	names.append_array(_custom.keys())
	return names


func _basis_of(name: String) -> Dictionary:
	return _custom[name] if _custom.has(name) else SketchMath.fixed_basis(name)


func _colour_of(name: String) -> Color:
	return CUSTOM_COLOUR if _custom.has(name) else COLOURS[name]


func clear_custom() -> void:
	for key in _custom.keys():
		if _quads.has(key):
			(_quads[key] as Node).queue_free()
			_quads.erase(key)
			_materials.erase(key)
			_centres.erase(key)
	_custom.clear()
	_rest_custom.clear()
	if hovered.begins_with("plane:"):
		hovered = ""
	if chosen.begins_with("plane:"):
		chosen = ""


func add_plane(key: String, basis: Dictionary, label_text: String) -> void:
	## A made plane (origin / x / y / n in the part's frame), a square as big as the fixed ones, centred where the plane is nearest the part's middle.
	if _custom.has(key) or basis.is_empty():
		return
	_custom[key] = basis
	var centre: Vector3 = _part_centre - (basis["n"] as Vector3) * (_part_centre - (basis["origin"] as Vector3)).dot(basis["n"])
	_centres[key] = centre
	var node := MeshInstance3D.new()
	node.name = "Plane_" + key.replace(":", "_")
	var quad := QuadMesh.new()
	quad.size = Vector2(extent, extent)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = mat
	node.mesh = quad
	node.transform = Transform3D(Basis(basis["x"], basis["y"], basis["n"]), centre)
	add_child(node)
	var label := Label3D.new()
	label.text = label_text
	label.font_size = 40
	label.pixel_size = 0.0004 / _scale_m_per_mm
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.outline_size = 8
	label.modulate = CUSTOM_COLOUR
	label.position = Vector3(extent * 0.42, extent * 0.42, 0.0)
	node.add_child(label)
	_quads[key] = node
	_materials[key] = mat
	_restyle()
	_apply_visibility()


func has_plane(key: String) -> bool:
	return _custom.has(key)


func set_hover(plane_name: String) -> void:
	if hovered != plane_name:
		hovered = plane_name
		_restyle()


func set_chosen(plane_name: String) -> void:
	chosen = plane_name
	_restyle()


func set_markers_visible(on: bool) -> void:
	## Plane picking is on (or off): while it is on every square shows.
	picking = on
	_apply_visibility()


func set_rest_fixed(on: bool) -> void:
	_rest_fixed = on
	_apply_visibility()


func set_fixed_hidden(hidden: bool) -> void:
	_fixed_hidden = hidden
	_apply_visibility()


func set_rest_custom(key: String, on: bool) -> void:
	_rest_custom[key] = on
	_apply_visibility()


func shows(plane_name: String) -> bool:
	if picking:
		# Picking shows every square, unless the user hid it on purpose (the reference planes' switch, a made plane's eye).
		return bool(_rest_custom.get(plane_name, true)) if _custom.has(plane_name) else not _fixed_hidden
	return bool(_rest_custom.get(plane_name, false)) if _custom.has(plane_name) else _rest_fixed


func _apply_visibility() -> void:
	var any := false
	for name in _quads:
		var shown := shows(name)
		(_quads[name] as Node3D).visible = shown
		any = any or shown
	visible = any


func _restyle() -> void:
	for name in _materials:
		var c: Color = _colour_of(name)
		var alpha := IDLE_ALPHA
		if name == hovered or name == chosen:
			alpha = HOT_ALPHA
		(_materials[name] as StandardMaterial3D).albedo_color = Color(c.r, c.g, c.b, alpha)
