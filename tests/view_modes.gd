extends SceneTree
## View modes (scripts/view_modes.gd, scripts/edge_overlay.gd, shaders/edge_lines.gdshader): Shaded / Shaded + edges / Wireframe.
## Pure: the edge list from a part's topology (the backend's real edges) and the sharp-edge fallback from a bare mesh. Scene
## (main.tscn, no backend, the box-and-cylinder fixture): edges are built lazily and only in the modes that show them, wireframe
## hides the faces but leaves the part grabbable, going back restores everything, a replaced mesh gets fresh edges, the table's copy
## follows the mode (and a blank new part never shows a fake cube's edges), the setting persists, and the tablet's Display page sets it.
## Run: "$GODOT" --headless --path . --script res://tests/view_modes.gd  (see tests/README.md)

const EdgeOverlay := preload("res://scripts/edge_overlay.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func _initialize() -> void:
	# --- pure
	var box_lines := EdgeOverlay.lines_from_mesh(BoxMesh.new())
	print("SMOKE a plain box's sharp edges are its 12 edges (24 endpoints; the coplanar diagonals are not edges): ", box_lines.size() == 24)
	var sphere_lines := EdgeOverlay.lines_from_mesh(SphereMesh.new())
	print("SMOKE a smooth sphere has no sharp edges at the default angle: ", sphere_lines.size() < 40)
	print("SMOKE an empty edge list builds no mesh, a real one builds a lines mesh: ", EdgeOverlay.build_mesh(PackedVector3Array()) == null and EdgeOverlay.build_mesh(box_lines) != null and EdgeOverlay.build_mesh(box_lines).get_surface_count() == 1)
	var topo := {"b1": {"edges": {0: PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0)]), 1: PackedVector3Array([Vector3(0, 0, 1), Vector3(0, 1, 1)])}}, "b2": {"edges": {0: PackedVector3Array([Vector3(5, 5, 5), Vector3(6, 5, 5)])}}}
	var from_topology := EdgeOverlay.lines_from_topology(topo)
	print("SMOKE the backend's topology edges become one flat list of segment endpoints, every body's: ", from_topology.size() == 8 and from_topology[0] == Vector3.ZERO and from_topology[6] == Vector3(5, 5, 5))

	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
	await frames(2)
	var vm = main.view_modes
	var parts: Array = get_nodes_in_group("grabbable_parts")
	var box: MeshInstance3D = parts.filter(func(p): return p.get_meta("occurrence_id", "") == "occ_box")[0]

	print("SMOKE it starts Shaded: faces drawn, no edge overlay built yet (nothing is paid for until an edge mode is used): ", vm.mode == vm.Mode.SHADED and parts.all(func(p): return vm.edge_lines_of(p) == null and p.layers == 1))

	vm.set_mode(vm.Mode.SHADED_EDGES)
	await frames(1)
	var lines: MeshInstance3D = vm.edge_lines_of(box)
	var topology_segments := EdgeOverlay.lines_from_topology(box.get_meta("topology")).size()
	print("SMOKE Shaded + edges builds each part's edges from its real topology and keeps the faces: ", parts.all(func(p): return vm.edge_lines_of(p) != null and vm.edge_lines_of(p).visible and p.layers == 1) and lines.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == topology_segments and topology_segments > 0)
	print("SMOKE ...as lines in the dark edge colour, through the shader that honours the section clip: ", lines.mesh.surface_get_primitive_type(0) == Mesh.PRIMITIVE_LINES and (lines.material_override as ShaderMaterial).shader.resource_path.ends_with("edge_lines.gdshader") and (lines.material_override as ShaderMaterial).get_shader_parameter("line_color").get_luminance() < 0.3 and (lines.material_override as ShaderMaterial).shader.code.contains("clip_common.gdshaderinc"))
	print("SMOKE ...and the overlay is a child with no collider, so the laser and grip still see only the part: ", lines.get_children().is_empty() and lines.get_parent() == box and box.get_children().any(func(c): return c is StaticBody3D))

	vm.set_mode(vm.Mode.WIREFRAME)
	await frames(1)
	print("SMOKE Wireframe hides the faces (layers 0) and keeps the edges, in the lighter colour: ", parts.all(func(p): return p.layers == 0 and vm.edge_lines_of(p).visible) and (lines.material_override as ShaderMaterial).get_shader_parameter("line_color").get_luminance() > 0.5)
	print("SMOKE ...the part is still pickable (its collider is untouched) and still counts as an arena part: ", box.get_children().any(func(c): return c is StaticBody3D) and box.is_in_group("grabbable_parts") and box.visible)

	var built_lines = lines
	vm.set_mode(vm.Mode.SHADED_EDGES)
	await frames(1)
	print("SMOKE going back to Shaded + edges restores the faces and reuses the edges already built: ", box.layers == 1 and vm.edge_lines_of(box) == built_lines)
	vm.set_mode(vm.Mode.SHADED)
	await frames(1)
	print("SMOKE going back to Shaded hides the edges (kept for next time) and restores everything: ", parts.all(func(p): return p.layers == 1 and not vm.edge_lines_of(p).visible))

	# --- a replaced mesh gets its own edges
	vm.set_mode(vm.Mode.SHADED_EDGES)
	await frames(1)
	var key_before: String = vm.edge_lines_of(box).get_meta("edge_key")
	main.swap_part_mesh([box], bytes) # a fresh parse: a new mesh resource
	var key_after: String = vm.edge_lines_of(box).get_meta("edge_key")
	print("SMOKE when a part's mesh is replaced (an edit on the table) its edges are rebuilt for the new shape: ", key_before != key_after and get_nodes_in_group("grabbable_parts").size() == 2 and box.get_children().filter(func(c): return c.name == "EdgeLines").size() == 1)

	# --- a bare model with no topology: sharp-angle edges from the mesh
	var bare := MeshInstance3D.new()
	bare.mesh = BoxMesh.new()
	bare.add_to_group("grabbable_parts")
	main.assembly_root.add_child(bare)
	vm.apply_to(bare)
	print("SMOKE a model with no topology falls back to the sharp edges of its mesh: ", vm.edge_lines_of(bare) != null and vm.edge_lines_of(bare).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 24)
	bare.queue_free()

	# --- the table's copy
	table.open()
	table.seat(box)
	await frames(2)
	print("SMOKE the table's copy follows the mode: edges on it in Shaded + edges, faces still drawn: ", vm.edge_lines_of(table.table_copy) != null and vm.edge_lines_of(table.table_copy).visible and table.table_copy.layers == 1)
	vm.set_mode(vm.Mode.WIREFRAME)
	await frames(1)
	print("SMOKE ...in Wireframe the copy's faces go and its edges stay: ", table.table_copy.layers == 0 and vm.edge_lines_of(table.table_copy).visible)
	vm.set_mode(vm.Mode.SHADED)
	await frames(1)
	print("SMOKE ...and in Shaded it is a plain solid again: ", table.table_copy.layers == 1 and not vm.edge_lines_of(table.table_copy).visible)
	table.return_to_arena()
	await frames(1)

	# --- a blank new part never shows the placeholder's edges
	var blank: MeshInstance3D = main.add_blank_part("root", "occ_blank", Transform3D.IDENTITY)
	table.seat(blank)
	vm.set_mode(vm.Mode.WIREFRAME)
	await frames(2)
	var blank_lines = vm.edge_lines_of(table.table_copy)
	print("SMOKE a blank new part on the table draws neither faces nor edges in any mode (there is no real shape yet): ", table.is_blank() and table.table_copy.layers == 0 and (blank_lines == null or not blank_lines.visible))
	table.return_to_arena()
	await frames(1)

	# --- persistence and the tablet's Display page
	var saved: int = main._settings.view_render_mode
	print("SMOKE the choice is saved with the other settings (and read back at start): ", saved == vm.Mode.WIREFRAME)
	var tablet = origin.get_node("LeftController/WristTablet")
	var page: Control = tablet.registry.tool_def("display").build.call()
	var buttons: Array = page.find_children("*", "Button", true, false)
	print("SMOKE the tablet's View > Display page has the three modes, the current one pressed: ", buttons.size() == 3 and buttons[2].button_pressed and buttons[0].text == "Shaded" and buttons[1].text == "Shaded + edges" and buttons[2].text == "Wireframe")
	buttons[1].pressed.emit()
	await frames(1)
	print("SMOKE ...and pressing one sets the mode everywhere: ", vm.mode == vm.Mode.SHADED_EDGES and main._settings.view_render_mode == 1 and box.layers == 1 and vm.edge_lines_of(box).visible)
	vm.set_mode(vm.Mode.SHADED)
	main._settings.set_view_render_mode(0)
	quit()
