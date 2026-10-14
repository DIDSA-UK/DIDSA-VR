extends Node3D
## The design table's side of "push changes to world" (the room's is scripts/room/world_preview.gd, the same three states and colours). While a part is on the
## table its place in the world is empty (the real node is hidden). Every OTHER placement of the same Part is updated as the edit goes in (table_editor.gd swaps
## their mesh), so what is missing is this one:
##   HIDDEN   nothing
##   GHOST    the part as it was when it went on the table, faint, where it sits in the world
##   PREVIEW  the part as it is NOW (the table's edits), in the preview colour where it sits in the world, in the "changed" tint once an edit has changed it
## A stand-in sharing the mesh (so no copy of the geometry), drawn with shaders/world_preview.gdshader, following the hidden node's pose and mesh.

const WorldPreview := preload("res://scripts/room/world_preview.gd")

var table: Node3D
var mode := WorldPreview.Mode.HIDDEN
var pulse := false

var _orig_mesh: Mesh
var _proxy: MeshInstance3D
var _tether: MeshInstance3D
var _class := -1


func setup(p_table: Node3D) -> void:
	table = p_table
	name = "TableWorldPreview"
	top_level = true
	set_process(false)


func on_seated() -> void:
	## A part has just gone on the table: remember how it looked, and start with nothing shown.
	var node: MeshInstance3D = table.seated
	_orig_mesh = node.mesh if is_instance_valid(node) else null
	mode = WorldPreview.Mode.HIDDEN
	_clear()


func on_cleared() -> void:
	mode = WorldPreview.Mode.HIDDEN
	_orig_mesh = null
	_clear()


func available() -> bool:
	return table != null and is_instance_valid(table.seated) and table.seated is MeshInstance3D and not bool(table.seated.get_meta("blank", false))


func set_mode(m: int) -> bool:
	if m != WorldPreview.Mode.HIDDEN and not available():
		return false
	mode = m as WorldPreview.Mode
	_clear()
	if mode != WorldPreview.Mode.HIDDEN:
		_build()
	set_process(mode != WorldPreview.Mode.HIDDEN)
	return true


func cycle() -> int:
	set_mode((int(mode) + 1) % 3)
	return int(mode)


func is_changed() -> bool:
	return available() and _orig_mesh != null and table.seated.mesh != _orig_mesh


func _clear() -> void:
	if is_instance_valid(_proxy):
		_proxy.queue_free()
	_proxy = null
	if is_instance_valid(_tether):
		_tether.queue_free()
	_tether = null
	_class = -1


func _build() -> void:
	var seated: MeshInstance3D = table.seated
	_proxy = MeshInstance3D.new()
	_proxy.mesh = _orig_mesh if mode == WorldPreview.Mode.GHOST and _orig_mesh != null else seated.mesh
	var m := ShaderMaterial.new()
	m.shader = WorldPreview.PreviewShader
	m.set_shader_parameter("pulse", 0.12 if pulse else 0.0)
	_proxy.material_override = m
	_proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_proxy.set_instance_shader_parameter("room_slot", -1)
	add_child(_proxy)
	_tether = MeshInstance3D.new()
	_tether.mesh = ImmediateMesh.new()
	var tm := StandardMaterial3D.new()
	tm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	tm.albedo_color = WorldPreview.TETHER_COLOUR
	tm.no_depth_test = true
	_tether.material_override = tm
	_tether.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tether)
	refresh()


func _process(_delta: float) -> void:
	refresh()


func refresh() -> void:
	if mode == WorldPreview.Mode.HIDDEN or not is_instance_valid(_proxy):
		return
	if not available():
		set_mode(WorldPreview.Mode.HIDDEN)
		return
	var seated: MeshInstance3D = table.seated
	_proxy.global_transform = seated.global_transform
	var mat := _proxy.material_override as ShaderMaterial
	if mode == WorldPreview.Mode.GHOST:
		if _class != 10:
			_class = 10
			_proxy.mesh = _orig_mesh if _orig_mesh != null else seated.mesh
			mat.set_shader_parameter("tint", WorldPreview.GHOST_TINT)
			mat.set_shader_parameter("alpha", 0.18)
	else:
		_proxy.mesh = seated.mesh # (an edit replaces the mesh: the preview follows)
		var cls := 1 if is_changed() else 0
		if cls != _class:
			_class = cls
			mat.set_shader_parameter("tint", WorldPreview.CHANGED_TINT if cls == 1 else WorldPreview.PREVIEW_TINT)
			mat.set_shader_parameter("alpha", 0.7 if cls == 1 else 0.55)
	var centre: Vector3 = seated.global_transform * seated.get_aabb().get_center()
	var from: Vector3 = (table.table_copy as Node3D).global_position if is_instance_valid(table.table_copy) else table.global_position
	var im := _tether.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(from)
	im.surface_add_vertex(centre)
	im.surface_end()
