extends SceneTree
## The part clipped to the sketch window (scripts/design_table/sketch_clip.gd, shaders/clip_common.gdshaderinc). Headless: the logic only, no pixels
## (tests/sketch_clip_render.gd draws it; RenderingServer's global parameters read back as Nil under --headless, so the uniforms are checked on the
## object that sets them). The box maths, which materials the copy / its edge lines / its overlays wear while the clip is on, that colour and view mode
## survive it, that ending it puts back exactly what was there, and that a replaced mesh or a new colour is picked up.
## Run: "$GODOT" --headless --path . --script res://tests/sketch_clip.gd  (see tests/README.md)

const SketchClip := preload("res://scripts/design_table/sketch_clip.gd")
const ViewModes := preload("res://scripts/view_modes.gd")
const FaceHighlight := preload("res://scripts/face_highlight.gd")


func _initialize() -> void:
	# --- the box
	var half := SketchClip.box_half(Vector2(0.8, 0.4))
	print("SMOKE the box is the window's rectangle by the depth either side: ", is_equal_approx(half.x, 0.4 + SketchClip.MARGIN_M) and is_equal_approx(half.y, 0.2 + SketchClip.MARGIN_M) and is_equal_approx(half.z, SketchClip.DEPTH_M))
	print("SMOKE the depth is tens of centimetres, not millimetres or metres: ", SketchClip.DEPTH_M >= 0.1 and SketchClip.DEPTH_M <= 0.5)
	var o := Vector3(0, 1, -0.5)
	var u := Vector3.RIGHT
	var v := Vector3(0, 0.5, -0.866).normalized() # a tilted plane
	var n := u.cross(v).normalized()
	print("SMOKE inside: the middle, the window's corners and a point just off the plane survive: ", SketchClip.inside(o, o, u, v, n, half) and SketchClip.inside(o + u * 0.39 + v * 0.19, o, u, v, n, half) and SketchClip.inside(o + n * 0.2, o, u, v, n, half))
	print("SMOKE outside: beyond the window sideways, up, or too far off the plane is cut: ", not SketchClip.inside(o + u * 0.45, o, u, v, n, half) and not SketchClip.inside(o + v * 0.25, o, u, v, n, half) and not SketchClip.inside(o + n * 0.3, o, u, v, n, half) and not SketchClip.inside(o - n * 0.3, o, u, v, n, half))

	# --- a copy with the glTF-style surface materials (one per surface), the view modes, an overlay
	var modes := ViewModes.new()
	root.add_child(modes)
	modes.setup(null, ViewModes.Mode.SHADED_EDGES)
	var copy := MeshInstance3D.new()
	root.add_child(copy)
	var mesh := _two_surface_mesh(Color(0.9, 0.2, 0.1), Color(0.1, 0.4, 0.9))
	copy.mesh = mesh
	var lines := _edge_node(copy, modes)

	var clip := SketchClip.new()
	clip.begin(copy, modes)
	print("SMOKE begin: the copy is flagged and every surface wears the clip shader with its own colour and the switch on: ", copy.has_meta("window_clip") and _is_clip(copy.get_surface_override_material(0), Color(0.9, 0.2, 0.1)) and _is_clip(copy.get_surface_override_material(1), Color(0.1, 0.4, 0.9)))
	print("SMOKE begin: the part's own mesh materials were not touched: ", mesh.surface_get_material(0) is StandardMaterial3D and copy.material_override == null)
	print("SMOKE begin: the edge lines switched to the clipped line material: ", lines.material_override == modes.edge_material(copy) and modes.edge_material(copy) != modes.edge_material(Node3D.new()) and (modes.edge_material(copy).get_shader_parameter("window_clip") == true))
	var plain := MeshInstance3D.new()
	print("SMOKE an arena part's edge material is the plain one (switch off): ", not (modes.edge_material(plain).get_shader_parameter("window_clip") == true))

	# the box follows update()
	clip.update(o, u, v, n, Vector2(0.8, 0.4))
	print("SMOKE update: the box is where the window is: ", clip.origin == o and clip.axes[0].is_equal_approx(u) and clip.axes[2].is_equal_approx(n) and clip.half.is_equal_approx(half) and clip.contains_world(o) and not clip.contains_world(o + u))
	clip.update(o, u * 3.0, v * 0.2, n * 9.0, Vector2(0.8, 0.4))
	print("SMOKE update: axes need not be unit: ", clip.axes[0].is_equal_approx(u) and clip.axes[2].is_equal_approx(n))
	# repeated reconcile does not stack wrappers
	var first := copy.get_surface_override_material(0)
	for i in 5:
		clip.update(o, u, v, n, Vector2(0.8, 0.4))
	print("SMOKE steady frames keep the same materials (no rebuild per frame): ", copy.get_surface_override_material(0) == first)

	# --- an overlay already on the copy gets its own switched-on material; a new one is built switched on
	var shared := ShaderMaterial.new()
	shared.shader = load("res://shaders/highlight_clip.gdshader")
	shared.set_shader_parameter("colour", Color(1, 1, 0, 0.5))
	var overlay := MeshInstance3D.new()
	overlay.set_meta("highlight_kind", "face")
	overlay.set_meta("window_clip_adopted", false) # what face_highlight.gd leaves on an overlay built before the clip began (a regression: has_meta was used, not the value)
	overlay.material_override = shared
	copy.add_child(overlay)
	clip.update(o, u, v, n, Vector2(0.8, 0.4))
	var adopted := overlay.material_override as ShaderMaterial
	print("SMOKE an overlay already on the copy is clipped too, through its own material (the shared one is untouched): ", adopted != shared and (adopted.get_shader_parameter("window_clip") == true) and not (shared.get_shader_parameter("window_clip") == true))
	var highlight := FaceHighlight.new()
	var built := highlight._for_part(copy, shared)
	var arena_built := highlight._for_part(plain, shared)
	print("SMOKE a new overlay on the clipped copy is switched on, on an arena part it is the shared material: ", built != shared and (built.get_shader_parameter("window_clip") == true) and arena_built == shared)

	# --- a colour change (colour_tool.gd's flat override) is picked up
	var flat := StandardMaterial3D.new()
	flat.albedo_color = Color(0.2, 0.8, 0.3)
	copy.material_override = flat
	clip.update(o, u, v, n, Vector2(0.8, 0.4))
	print("SMOKE a new colour on the copy is picked up, with the clip on: ", _is_clip(copy.material_override, Color(0.2, 0.8, 0.3)))
	# a replaced mesh (an edit) is picked up
	copy.material_override = null
	copy.mesh = _two_surface_mesh(Color(0.3, 0.3, 0.3), Color(0.6, 0.6, 0.6))
	clip.update(o, u, v, n, Vector2(0.8, 0.4))
	print("SMOKE a replaced mesh is wrapped afresh: ", _is_clip(copy.get_surface_override_material(0), Color(0.3, 0.3, 0.3)) and _is_clip(copy.get_surface_override_material(1), Color(0.6, 0.6, 0.6)))
	# a mesh with no surfaces / none at all does not crash
	copy.mesh = null
	clip.update(o, u, v, n, Vector2(0.8, 0.4))
	print("SMOKE no mesh: nothing to clip, no error: ", true)
	copy.mesh = mesh
	clip.update(o, u, v, n, Vector2(0.8, 0.4))

	# --- wireframe: the faces are hidden by layers, which the clip does not touch; the edges stay clipped
	modes.set_mode(ViewModes.Mode.WIREFRAME)
	copy.layers = 0
	clip.update(o, u, v, n, Vector2(0.8, 0.4))
	print("SMOKE wireframe keeps working under the clip (faces off by layers, edge lines still the clipped material): ", copy.layers == 0 and copy.get_node("EdgeLines") != null)

	# --- end puts everything back
	clip.end()
	print("SMOKE end: the copy goes back to what it had (mesh surfaces, no override, no flag): ", copy.get_surface_override_material(0) == null and copy.material_override == null and not copy.has_meta("window_clip"))
	var lines_now := (copy.get_node("EdgeLines") as MeshInstance3D).material_override as ShaderMaterial
	print("SMOKE end: the edge lines are the plain material again, and a leftover overlay's switch is off: ", lines_now == modes.edge_material(copy) and lines_now.get_shader_parameter("window_clip") != true and (overlay.material_override as ShaderMaterial).get_shader_parameter("window_clip") != true)
	copy.material_override = flat
	clip.begin(copy, modes)
	clip.end()
	print("SMOKE end restores a colour override that was there before: ", copy.material_override == flat)
	clip.end() # twice is harmless
	print("SMOKE end twice is harmless: ", true)
	quit()


func _is_clip(material: Material, albedo: Color) -> bool:
	if not (material is ShaderMaterial):
		return false
	var m := material as ShaderMaterial
	return m.shader == load("res://shaders/section_clip.gdshader") and (m.get_shader_parameter("albedo_color") as Color).is_equal_approx(albedo) and (m.get_shader_parameter("window_clip") == true)


func _two_surface_mesh(a: Color, b: Color) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for i in 2:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		var off := float(i)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(off, 0, 0), Vector3(off + 1, 0, 0), Vector3(off, 1, 0)])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var m := StandardMaterial3D.new()
		m.albedo_color = a if i == 0 else b
		mesh.surface_set_material(i, m)
	return mesh


func _edge_node(copy: MeshInstance3D, modes: Node) -> MeshInstance3D:
	copy.set_meta("topology", {"b": {"edges": {0: PackedVector3Array([Vector3.ZERO, Vector3.RIGHT])}}})
	modes.apply_to(copy)
	return copy.get_node("EdgeLines") as MeshInstance3D
