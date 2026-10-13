extends Node
## How models are drawn: SHADED (faces only, as always), SHADED + EDGES (faces plus the part's real CAD edges drawn over them) and
## WIREFRAME (the edges only, faces not drawn). The flat app has the same three (`ViewportRenderMode`) and persists the choice; so does
## this (app_settings.gd `view_render_mode`). Set from the wrist tablet: View > Display.
##
## Edges come from the part's "topology" meta (the backend's real B-rep edges, scripts/edge_overlay.gd) as one `EdgeLines` child per part
## node, built lazily the first time an edge mode needs it and rebuilt only when the part's mesh is replaced (the cache key is the mesh's
## instance id, so swap_part_mesh / the table's copy refresh pick up a new shape by just calling apply_to again). A model without topology
## gets sharp-angle edges found from its mesh instead. Wireframe hides the faces with `layers = 0` on the part (its children keep their
## own layers), so colliders, grips and the laser still work. The design table's copy follows the same mode (design_table.apply_view_mode).

signal changed(mode: int)

enum Mode { SHADED, SHADED_EDGES, WIREFRAME }

const NAMES: Array[String] = ["Shaded", "Shaded + edges", "Wireframe"]
const ClipGlobals := preload("res://scripts/clip_globals.gd")
const EdgeOverlay := preload("res://scripts/edge_overlay.gd")
const RoomClip := preload("res://scripts/room/room_clip.gd")
const EDGE_SHADER := preload("res://shaders/edge_lines.gdshader")
const EDGE_COLOUR := Color(0.14, 0.14, 0.15) ## over faces: dark, like the flat app's #333
const WIRE_COLOUR := Color(0.62, 0.74, 0.86) ## alone: light, so it reads against the dark rooms too

var mode: int = Mode.SHADED

var _main: Node
var _material := ShaderMaterial.new()
var _clip_material := ShaderMaterial.new() ## the same lines for a part clipped to the sketch window (sketch_clip.gd): its `window_clip` switch on


func setup(main: Node, initial_mode: int) -> void:
	ClipGlobals.ensure() # the edge shader reads the clip globals
	_main = main
	_material.shader = EDGE_SHADER
	_clip_material.shader = EDGE_SHADER
	_clip_material.set_shader_parameter("window_clip", true)
	mode = clampi(initial_mode, 0, 2)
	_style()


func shows_faces() -> bool:
	return mode != Mode.WIREFRAME


func shows_edges() -> bool:
	return mode != Mode.SHADED


func mode_name() -> String:
	return NAMES[mode]


func set_mode(new_mode: int) -> void:
	new_mode = clampi(new_mode, 0, 2)
	if new_mode == mode:
		return
	mode = new_mode
	_style()
	apply_all()
	if _main != null and _main.has_method("save_view_mode"):
		_main.save_view_mode(mode)
	changed.emit(mode)


func _style() -> void:
	var colour := WIRE_COLOUR if mode == Mode.WIREFRAME else EDGE_COLOUR
	_material.set_shader_parameter("line_color", colour)
	_clip_material.set_shader_parameter("line_color", colour)


func apply_all() -> void:
	## Every arena part, and the table's copy, in the current mode.
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		apply_to(node)
	for node in get_tree().get_nodes_in_group("room_parts"): # the parts in Assembly Rooms follow the same mode (interactive ones are grabbable too: done above)
		if not node.is_in_group("grabbable_parts"):
			apply_to(node)
	if _main != null and _main.get("design_table") != null:
		_main.design_table.apply_view_mode()


func apply_to(node: Node) -> void:
	## One node in the current mode: its edges built / shown / hidden, and (arena parts) its faces shown or not. The table's copy is
	## given here only for its edges; design_table.apply_view_mode() decides its faces (a blank part has none either way).
	if not (node is MeshInstance3D) or not is_instance_valid(node):
		return
	var part := node as MeshInstance3D
	var wanted := shows_edges() and not bool(part.get_meta("no_edges", false))
	var lines := part.get_node_or_null("EdgeLines") as MeshInstance3D
	if wanted:
		lines = _ensure_edges(part)
		if lines != null:
			lines.visible = true
			lines.material_override = edge_material(part)
	elif lines != null:
		lines.visible = false
	RoomClip.sync_children(part) # the edge lines are cut by the same room walls as the part
	if part.is_in_group("grabbable_parts") or part.is_in_group("room_parts"):
		part.layers = 1 if shows_faces() else 0


func edge_material(part: Node) -> ShaderMaterial:
	## The line material for a part: the switched-on one while the part is clipped to the sketch window (its `window_clip` meta, sketch_clip.gd).
	return _clip_material if bool(part.get_meta("window_clip", false)) else _material


func edge_lines_of(part: Node) -> MeshInstance3D:
	## The part's edge overlay node, if one has been built (tests, and anything that wants to know).
	return part.get_node_or_null("EdgeLines") as MeshInstance3D


func _ensure_edges(part: MeshInstance3D) -> MeshInstance3D:
	var key := "%d:%d" % [part.mesh.get_instance_id() if part.mesh != null else 0, 1 if part.has_meta("topology") else 0]
	var lines := part.get_node_or_null("EdgeLines") as MeshInstance3D
	if lines != null and lines.get_meta("edge_key", "") == key:
		return lines
	if lines != null:
		part.remove_child(lines)
		lines.free()
	if part.mesh == null:
		return null
	var segments: PackedVector3Array = EdgeOverlay.lines_from_topology(part.get_meta("topology")) if part.has_meta("topology") else EdgeOverlay.lines_from_mesh(part.mesh)
	var mesh := EdgeOverlay.build_mesh(segments)
	if mesh == null:
		return null
	lines = MeshInstance3D.new()
	lines.name = "EdgeLines"
	lines.mesh = mesh
	lines.material_override = _material
	lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	lines.set_meta("edge_key", key)
	part.add_child(lines)
	return lines
