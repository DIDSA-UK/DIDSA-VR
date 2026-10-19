extends RefCounted
## Clips the design table's copy of the part to the sketch window while a sketch is open, so zooming right in (up to 200x) does not fill the room
## with the part: only the box in front of the window survives, the window's rectangle in the sketch plane with a depth either side of it.
##
## It is the section tool's mechanism, generalised, not a second system: the same shader (shaders/section_clip.gdshader) and the same kind of global
## uniforms (`window_clip_*`, next to `section_plane_*`, both declared in shaders/clip_common.gdshaderinc, which edge_lines.gdshader and
## highlight_clip.gdshader include too). What differs is WHO is clipped: the section plane cuts every part, the window box only materials that have
## their per-material `window_clip` switch on, which is the table's copy, its edge lines and its overlays, never the arena's parts (they are across
## the room and must not vanish). So the box is one set of global uniforms, set each frame from where the window is (`update`), and `reconcile`
## makes sure the copy and what hangs on it are wearing a switched-on material:
##   * the copy's faces: a section_clip ShaderMaterial carrying the colour it had (appearance_tool.gd's flat override, or the glTF surface's own albedo,
##     per surface), installed as `material_override` when the copy had an override and as per-surface overrides otherwise, and taken off again by
##     `end()` (the copy goes back to exactly what it had);
##   * its edge lines (view_modes.gd picks the switched-on line material for a part with the `window_clip` meta);
##   * its hover / selection overlays (face_highlight.gd duplicates its material switched on for such a part).
## View modes keep working because they act on nodes, not materials: wireframe hides the copy by `layers`, edges are a child node.
##
## The numbers that depend on feel are constants here: how deep the box is either side of the sketch plane, and any margin around the window.

const ClipGlobals := preload("res://scripts/clip_globals.gd")
const ClipShader := preload("res://shaders/section_clip.gdshader")

const DEPTH_M := 0.25 ## world metres of the box either side of the sketch plane ("a few tens of centimetres"); the part is cut away beyond this
const MARGIN_M := 0.0 ## world metres the box is wider / taller than the window rectangle (0: exactly the window)
const META := "window_clip" ## on the copy while the clip is on; view_modes.gd and face_highlight.gd read it

var active := false
var origin := Vector3.ZERO ## the box as last set, world space
var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
var half := Vector3.ZERO

var _copy: MeshInstance3D = null
var _view_modes: Node = null
var _wrapped_mesh := 0 ## the mesh the copy's wrappers were made for
var _saved_override: Material = null
var _wrapped: Array[ShaderMaterial] = []
var _surface_overrides: Array = [] ## the copy's own per-surface overrides before we put ours on (Material or null each)
var _overlay_dupes: Array[ShaderMaterial] = []


func _init() -> void:
	ClipGlobals.ensure()


static func box_half(window_m: Vector2) -> Vector3:
	## Half the box along the window's across, up and off-plane axes: the window's size plus the margin, and the depth.
	return Vector3(window_m.x * 0.5 + MARGIN_M, window_m.y * 0.5 + MARGIN_M, DEPTH_M)


static func inside(point: Vector3, box_origin: Vector3, u: Vector3, v: Vector3, n: Vector3, box_half_size: Vector3) -> bool:
	## The shader's test in GDScript (clip_common.gdshaderinc): true if a world point survives the window clip.
	var d := point - box_origin
	return absf(d.dot(u)) <= box_half_size.x and absf(d.dot(v)) <= box_half_size.y and absf(d.dot(n)) <= box_half_size.z


func begin(copy: MeshInstance3D, view_modes: Node) -> void:
	## Starts clipping `copy` (the table's copy of the part).
	if active and copy == _copy:
		return
	end()
	_copy = copy
	_view_modes = view_modes
	active = true
	copy.set_meta(META, true)
	reconcile()
	_apply_edges()
	RenderingServer.global_shader_parameter_set("window_clip_enabled", true)


func end() -> void:
	## Stops clipping and puts the copy back exactly as it was.
	if not active:
		return
	active = false
	RenderingServer.global_shader_parameter_set("window_clip_enabled", false)
	if is_instance_valid(_copy):
		_unwrap()
		_copy.remove_meta(META)
		_apply_edges()
		for dupe in _overlay_dupes:
			dupe.set_shader_parameter("window_clip", false)
	_overlay_dupes.clear()
	_copy = null
	_view_modes = null


func update(window_origin: Vector3, u: Vector3, v: Vector3, n: Vector3, window_m: Vector2) -> void:
	## Where the window is now (world space; its axes need not be unit). Call every frame while a sketch is open: the part slides under a fixed
	## window, so the box only moves with the console, but it is cheap and keeps the box right after any move of the table.
	origin = window_origin
	axes = [u.normalized(), v.normalized(), n.normalized()]
	half = box_half(window_m)
	if not active:
		return
	RenderingServer.global_shader_parameter_set("window_clip_origin", origin)
	RenderingServer.global_shader_parameter_set("window_clip_u", axes[0])
	RenderingServer.global_shader_parameter_set("window_clip_v", axes[1])
	RenderingServer.global_shader_parameter_set("window_clip_n", axes[2])
	RenderingServer.global_shader_parameter_set("window_clip_half", half)
	reconcile()


func contains_world(point: Vector3) -> bool:
	return inside(point, origin, axes[0], axes[1], axes[2], half)


func reconcile() -> void:
	## Makes sure the copy wears clipping materials: after the mesh was replaced (an edit, the Build tree's filtered view) or its override changed.
	if not active or not is_instance_valid(_copy) or _copy.mesh == null:
		return
	if _needs_wrap():
		_unwrap()
		_wrap()
	_adopt_overlays()


func _needs_wrap() -> bool:
	if _wrapped.is_empty() or _copy.mesh.get_instance_id() != _wrapped_mesh:
		return true
	if _saved_override != null:
		return _copy.material_override != _wrapped[0]
	return _copy.material_override != null or not _surfaces_are_ours()


func _surfaces_are_ours() -> bool:
	for i in _copy.mesh.get_surface_count():
		if not (_copy.get_surface_override_material(i) in _wrapped):
			return false
	return true


func _wrap() -> void:
	if _copy.mesh == null:
		return
	_wrapped_mesh = _copy.mesh.get_instance_id()
	_saved_override = _copy.material_override
	if _saved_override != null:
		var mat := _make_material(_albedo(_saved_override))
		_copy.material_override = mat
		_wrapped.append(mat)
		return
	_surface_overrides.clear()
	for i in _copy.mesh.get_surface_count():
		_surface_overrides.append(_copy.get_surface_override_material(i))
		var base: Material = _copy.get_surface_override_material(i)
		if base == null:
			base = _copy.mesh.surface_get_material(i)
		var mat := _make_material(_albedo(base))
		_copy.set_surface_override_material(i, mat)
		_wrapped.append(mat)


func _unwrap() -> void:
	if _wrapped.is_empty():
		return
	if is_instance_valid(_copy):
		if _saved_override != null:
			if _copy.material_override in _wrapped:
				_copy.material_override = _saved_override
		elif _copy.mesh != null:
			for i in mini(_surface_overrides.size(), _copy.mesh.get_surface_count()):
				if _copy.get_surface_override_material(i) in _wrapped:
					_copy.set_surface_override_material(i, _surface_overrides[i])
	_wrapped.clear()
	_surface_overrides.clear()
	_saved_override = null


func _make_material(albedo: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = ClipShader
	mat.set_shader_parameter("albedo_color", albedo)
	mat.set_shader_parameter("window_clip", true)
	return mat


static func _albedo(material: Material) -> Color:
	## The colour a material shows: appearance_tool.gd's flat override and the glTF surfaces are both StandardMaterial3D (mesh_export.py only ever
	## sets a base colour); the neutral grey appearance_tool.gd uses for a part with no colour otherwise.
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).albedo_color
	return Color(0.7, 0.7, 0.7, 1.0)


func _apply_edges() -> void:
	if _view_modes != null and is_instance_valid(_view_modes) and is_instance_valid(_copy):
		_view_modes.apply_to(_copy)


func _adopt_overlays() -> void:
	## Hover / selection overlays already hanging on the copy (face_highlight.gd makes new ones switched on by itself): each gets its own
	## switched-on copy of its material, so the material shared with the arena's overlays is never changed.
	for child in _copy.get_children():
		if not (child is MeshInstance3D) or not child.has_meta("highlight_kind") or bool(child.get_meta("window_clip_adopted", false)):
			continue
		var node := child as MeshInstance3D
		var mat := node.material_override as ShaderMaterial
		if mat == null:
			continue
		var dupe := mat.duplicate() as ShaderMaterial
		dupe.set_shader_parameter("window_clip", true)
		node.material_override = dupe
		node.set_meta("window_clip_adopted", true)
		_overlay_dupes.append(dupe)
