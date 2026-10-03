extends SceneTree
## New assembly and New part (scripts/design_table/new_document.gd, main.gd new_assembly() / add_blank_part(),
## design_table.gd new_part()), with a FAKE backend (tests/helpers/fake_cad.gd): the call sequences the backend needs (a fresh
## document, one root part; a part and an occurrence of it with a client id and the transform), the empty assembly showing
## nothing, a new part appearing on the table as a hidden placeholder with no collider and only the reference planes to pick,
## its first feature swapping the real mesh in (and taking that back restoring the placeholder), an empty part being taken off
## the assembly again when it leaves the table, the table being busy / closed / cold, and the three buttons (the tree's +, the
## tablet's New part, Files > New assembly with its two-press confirm).
## Run: "$GODOT" --headless --path . --script res://tests/new_document.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const NewDocument := preload("res://scripts/design_table/new_document.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var fake
var l: XRController3D


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await process_frame
	return false


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func empty_glb() -> PackedByteArray:
	## A glb like the backend's for an assembly with nothing in it: one mesh-less node, no buffers.
	var json := '{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"extras":{"owner_part_id":"root","occurrence_id":""}}]}'.to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(0x20)
	var out := PackedByteArray()
	out.resize(12 + 8 + json.size())
	out.encode_u32(0, 0x46546C67) # "glTF"
	out.encode_u32(4, 2)
	out.encode_u32(8, out.size())
	out.encode_u32(12, json.size())
	out.encode_u32(16, 0x4E4F534A) # "JSON"
	for i in json.size():
		out[20 + i] = json[i]
	return out


func find_button(root_node: Node, text: String) -> Button:
	for n in root_node.find_children("*", "Button", true, false):
		if (n as Button).text == text:
			return n
	return null


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	l = origin.get_node("LeftController")
	l.position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(0, 1.0, -1.0))
	fake = Fake.new()
	fake.mesh_bytes = empty_glb()
	table.api = fake
	table.editor.api = fake
	var box_bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(box_bytes, "", 0.001)
	await frames(2)

	# --- the backend sequences, no scene
	var doc := NewDocument.new(Callable(fake, "request"))
	var started: Dictionary = await doc.start_assembly()
	print("SMOKE a new assembly is a fresh document, then ONE root part named Assembly: ", started["ok"] and started["root_id"] == "part1" and fake.paths() == ["POST /document/new", "POST /document/parts"] and fake.created_parts[0]["name"] == "Assembly")
	print("SMOKE the next part is numbered from what the root already holds: ", await doc.next_part_name("part1") == "Part 1")
	var pose := {"translation": [10.0, 20.0, 30.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}
	var added: Dictionary = await doc.add_part("part1", "Part 1", pose)
	var occ_call: Array = calls_to("/occurrences").filter(func(c): return c[0].begins_with("POST"))[0]
	print("SMOKE a new part is a part, then an occurrence of it on the root with a client id, its name and the pose: ", added["ok"] and added["part_id"] == "part2" and str(added["occurrence_id"]).begins_with("occ_") and str(added["occurrence_id"]).length() == 36 and occ_call[0] == "POST /document/parts/part1/occurrences" and occ_call[1]["resolved_part_id"] == "part2" and occ_call[1]["name_override"] == "Part 1" and occ_call[1]["transform"] == pose and occ_call[1]["id"] == added["occurrence_id"])
	print("SMOKE ...the root then holds it, so the next part is Part 2: ", await doc.next_part_name("part1") == "Part 2")
	print("SMOKE two new occurrence ids are different: ", NewDocument.new_occurrence_id() != NewDocument.new_occurrence_id())
	print("SMOKE taking it off again removes the occurrence: ", await doc.remove_occurrence("part1", added["occurrence_id"]) and await doc.next_part_name("part1") == "Part 1")
	fake.fail = "/document/parts"
	var refused: Dictionary = await doc.add_part("part1", "Part X", pose)
	print("SMOKE a refused part comes back as a failure with the reason, and nothing is placed: ", not refused["ok"] and calls_to("/occurrences").filter(func(c): return c[0].begins_with("POST")).size() == 1)
	fake.fail = ""
	fake.calls.clear()
	fake.occurrences.clear()
	fake.created_parts.clear()
	fake.n = 0

	# --- New assembly in the arena
	main.backend_url = "http://fake"
	main.api_key = "k"
	main._resolved_part_id = "OLD_ROOT"
	main._native_extras = {"hidden_feature_ids": ["x"]}
	print("SMOKE before it, the arena holds the loaded parts: ", get_nodes_in_group("grabbable_parts").size() == 2)
	var made: bool = await main.new_assembly()
	print("SMOKE New assembly throws the loaded parts away and shows an empty assembly: ", made and get_nodes_in_group("grabbable_parts").size() == 0 and main._part_count == 0)
	print("SMOKE ...asking the backend for a fresh document, a root part and its (empty) view, in that order: ", fake.paths().slice(0, 3) == ["POST /document/new", "POST /document/parts", "GET /document/parts/part1/assembly-mesh.glb?quality=0.5&include_hidden=false"])
	print("SMOKE ...the new root is the loaded assembly, the old file's extras are gone and a save will not be named after it: ", main.current_root_part_id() == "part1" and main._native_extras.is_empty() and main.native_file_path == "" and main.status_text.contains("New empty assembly"))
	main.backend_url = ""
	var no_backend: bool = await main.new_assembly()
	print("SMOKE with no backend it says so and does nothing: ", not no_backend and main.status_text.contains("needs a backend"))
	main.backend_url = "http://fake"
	fake.calls.clear()

	# --- New part: the table opens, the part appears blank
	print("SMOKE the table starts closed: ", not table.is_open())
	await table.new_part()
	var node: MeshInstance3D = table.seated
	print("SMOKE New part opens the table and puts a new part on it: ", table.is_open() and node != null and node.name == "Part 1")
	print("SMOKE ...asking the backend for the name, the part and its occurrence on the root: ", fake.paths().slice(0, 3) == ["GET /document/parts/part1/occurrences", "POST /document/parts", "POST /document/parts/part1/occurrences"])
	print("SMOKE ...the arena node is a hidden placeholder tagged like a loaded node, flagged blank: ", node != null and not node.visible and node.is_in_group("grabbable_parts") and node.get_meta("blank", false) and node.get_meta("new_part", false) and node.get_meta("owner_part_id") == "part1" and str(node.get_meta("occurrence_id")).begins_with("occ_") and node.get_meta("on_table", false))
	var placed: Dictionary = calls_to("/occurrences").filter(func(c): return c[0].begins_with("POST"))[0][1]
	var local_origin := Vector3(placed["transform"]["translation"][0], placed["transform"]["translation"][1], placed["transform"]["translation"][2])
	print("SMOKE ...placed where the backend was told (in the assembly's own millimetres): ", node != null and node.transform.origin.is_equal_approx(local_origin) and main.assembly_root.to_global(local_origin).distance_to(table._camera.global_position) < 1.5)
	var settled: bool = await settle(func() -> bool: return table.editor.state == "pick_plane")
	print("SMOKE its definition is looked up through the new occurrence and plane picking opens: ", settled and table.editor.part_id == "part2")
	print("SMOKE the copy shows nothing and has no collider (a fake cube is never drawn or picked): ", table.is_blank() and table.table_copy.layers == 0 and not table.table_copy.get_children().any(func(c): return c is StaticBody3D))
	print("SMOKE ...but the reference planes are there to pick, and the user is told: ", table.editor.markers != null and table.editor.markers.get_child_count() == 3 and table.status().contains("is empty") and table.status().contains("reference planes"))
	print("SMOKE the arena's tools do not see it (hidden, on the table): ", main._arena_parts().filter(func(p): return p.visible).is_empty())

	# --- first feature: the real mesh replaces the placeholder
	var placeholder_mesh = node.mesh
	var markers_before = table.editor.markers
	fake.mesh_bytes = box_bytes
	var refreshed: bool = await table.editor.refresh_geometry()
	print("SMOKE the first geometry swaps the real mesh in and the part stops being blank: ", refreshed and node.mesh != placeholder_mesh and not node.get_meta("blank", true) and node.has_meta("face_ids"))
	print("SMOKE ...the copy now shows it, with a collider on the table layer, refitted to its real size: ", not table.is_blank() and table.table_copy.layers == 1 and table.table_copy.get_children().any(func(c): return c is StaticBody3D and c.collision_layer == table.TABLE_LAYER) and absf(node.get_aabb().size.length() * 0.5 * table.fit_scale - table.fit_radius) < 0.002)
	print("SMOKE ...and the plane squares are rebuilt to fit it: ", table.editor.markers != markers_before and table.editor.markers.get_child_count() == 3)

	# --- taking that back: the placeholder returns
	fake.mesh_bytes = empty_glb()
	var undone: bool = await table.editor.refresh_geometry()
	print("SMOKE taking the first feature back (no geometry again) restores the placeholder and the blank state: ", undone and node.get_meta("blank", false) and node.mesh is BoxMesh and not node.has_meta("face_ids") and table.is_blank() and table.table_copy.layers == 0 and not table.table_copy.get_children().any(func(c): return c is StaticBody3D))

	# --- an empty part leaving the table is taken off the assembly again
	fake.calls.clear()
	table.return_to_arena()
	await frames(2)
	print("SMOKE giving back a part nothing was drawn on discards it: the occurrence is deleted, the node is gone, the table is free: ", table.seated == null and calls_to("DELETE /document/parts/part1/occurrences/").size() == 1 and (not is_instance_valid(node) or node.is_queued_for_deletion()))
	print("SMOKE ...and says so: ", table.status().contains("discarded"))

	# --- a second New part while one is on the table: the first goes back first
	await table.new_part()
	var first: MeshInstance3D = table.seated
	fake.mesh_bytes = box_bytes
	await settle(func() -> bool: return table.editor.state == "pick_plane")
	await table.editor.refresh_geometry() # this one has geometry now
	fake.calls.clear()
	await table.new_part()
	var second: MeshInstance3D = table.seated
	print("SMOKE New part with a part already on the table sends that one back where it came from first and puts the new one on: ", second != first and first.visible and not first.has_meta("on_table") and second.name == "Part 2" and calls_to("DELETE").is_empty())
	print("SMOKE ...the first one is a real placed part in the arena (it has geometry, so it stays): ", first.is_in_group("grabbable_parts") and not first.get_meta("blank", true))

	# --- closing the table with an empty part on it
	fake.calls.clear()
	table.close()
	await frames(2)
	print("SMOKE closing the table discards an empty part the same way: ", calls_to("DELETE /document/parts/part1/occurrences/").size() == 1 and table.seated == null)

	# --- cold start: no assembly loaded yet
	main._resolved_part_id = ""
	fake.calls.clear()
	await table.new_part()
	print("SMOKE New part with no assembly loaded starts one first: ", fake.paths().slice(0, 2) == ["POST /document/new", "POST /document/parts"] and table.seated != null and main.current_root_part_id() == fake.created_parts[0]["id"] and table.seated.get_meta("owner_part_id") == fake.created_parts[0]["id"])

	# --- the buttons
	var plus: Button = table.tree._new_part_button
	print("SMOKE the tree window has a + beside its close button: ", plus != null and plus.get_parent() == table.tree._header and plus.get_index() == table.tree._header.get_child_count() - 2)
	var seated_before: Node = table.seated
	fake.calls.clear()
	plus.pressed.emit()
	await settle(func() -> bool: return table.seated != seated_before and table.seated != null)
	print("SMOKE ...and pressing it starts another new part: ", table.seated != seated_before and calls_to("/occurrences").any(func(c): return c[0].begins_with("POST")))
	var tablet = l.get_node("WristTablet")
	var table_page: Control = tablet.registry.tool_def("table").build.call()
	var new_part_button: Button = find_button(table_page, "New part")
	print("SMOKE the tablet's Table page has a New part button: ", new_part_button != null)
	var before_press: Node = table.seated
	new_part_button.pressed.emit()
	await settle(func() -> bool: return table.seated != before_press and table.seated != null)
	print("SMOKE ...that does the same: ", table.seated != before_press)

	fake.mesh_bytes = empty_glb() # (the fake's view of a new, empty assembly again)
	var files_page: Control = tablet.registry.tool_def("models").build.call()
	var new_assembly_button: Button = find_button(files_page, "New assembly")
	print("SMOKE Files has a New assembly button: ", new_assembly_button != null)
	fake.calls.clear()
	new_assembly_button.pressed.emit()
	await frames(2)
	print("SMOKE the first press only arms it (it asks to be pressed again, and nothing is discarded): ", new_assembly_button.text == "Press again to discard" and calls_to("/document/new").is_empty())
	new_assembly_button.pressed.emit()
	await settle(func() -> bool: return not calls_to("/document/new").is_empty() and get_nodes_in_group("grabbable_parts").size() == 0)
	await frames(2)
	print("SMOKE the second press within a few seconds starts the empty assembly and the button is back to normal: ", calls_to("/document/new").size() == 1 and new_assembly_button.text == "New assembly" and get_nodes_in_group("grabbable_parts").size() == 0)
	new_assembly_button.pressed.emit()
	await frames(1)
	print("SMOKE an armed button that is left alone disarms itself: ", await _disarms(tablet, new_assembly_button))
	quit()


func _disarms(tablet, button: Button) -> bool:
	## Armed, then the few seconds pass and the tablet's own refresh tick runs: the label returns to normal.
	var pages = tablet.pages
	if button.text != "Press again to discard":
		return false
	pages._new_assembly_armed_until_ms = Time.get_ticks_msec() - 1
	pages.refresh()
	return button.text == "New assembly"
