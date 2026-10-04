extends SceneTree
## The design table's BUILD tree (scripts/design_table/table_build.gd, build_tree.gd and the tree window's Build tab), with a FAKE
## backend (tests/helpers/fake_cad.gd) and the box-and-cylinder fixture. The window has two tabs (Build | Parts) and opens on Build
## when a part goes on the table; the Build tab lists the part's features in order with names / summaries; selecting a row lights up
## what it made on the table's copy; Edit changes an extrude's depth (a PATCH, taken back by Undo); Hide / Show and Roll back change
## only the table's COPY (a second glb fetch with the two query params; the arena node is never touched) and Roll back refuses new
## features; Delete is two presses and cascades; hidden ids are the flat app's `hidden_feature_ids` extra.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_build_tree.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var fake
var box: MeshInstance3D


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func pick_line_toggle_construction(sess) -> void:
	sess.set_tool("select")
	await sess.select({"kind": "line", "id": "lnA"})
	await sess.apply_menu("construction")


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await process_frame
	return false


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func find_button(root_node: Node, text: String) -> Button:
	for n in root_node.find_children("*", "Button", true, false):
		if (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


func row_button(prefix: String) -> Button:
	for n in table.tree._build_rows.find_children("*", "Button", true, false):
		if (n as Button).text.begins_with(prefix):
			return n
	return null


func rows() -> Array:
	return table.tree._build_rows.get_children().filter(func(c): return c is Button and not c.text.begins_with("Body ")).map(func(b): return b.text)


func empty_glb() -> PackedByteArray:
	var json := '{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"extras":{"owner_part_id":"root","occurrence_id":""}}]}'.to_utf8_buffer()
	while json.size() % 4 != 0:
		json.append(0x20)
	var out := PackedByteArray()
	out.resize(20 + json.size())
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, out.size())
	out.encode_u32(12, json.size())
	out.encode_u32(16, 0x4E4F534A)
	for i in json.size():
		out[20 + i] = json[i]
	return out


func seed_rows() -> void:
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk_box", "sketch_id": "s1", "plane_feature_id": null, "locked": true, "has_lost_reference": false},
		{"type": "extrude", "id": "body_box", "sketch_feature_id": "sk_box", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 12.0, "target_body_ids": [], "locked": true},
		{"type": "fillet", "id": "fil_box", "edge_refs": [{"body_id": "body_box", "shape_type": "edge", "index": 0}], "radius": 2.0, "locked": false},
	]}


func _initialize() -> void:
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
	table.surface.settle_seconds = 0.0
	var box_bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(box_bytes, "", 0.001)
	await frames(3)
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var owner_id := str(box.get_meta("owner_part_id", ""))
	if owner_id == "":
		owner_id = "ASM"
		for p in get_nodes_in_group("grabbable_parts"):
			p.set_meta("owner_part_id", owner_id)
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = box_bytes
	fake.filtered_mesh_bytes = empty_glb()
	seed_rows()
	table.api = fake
	table.editor.api = fake

	# --- pure: names, summaries, edits, dependents
	var rows_pure: Array = fake.feature_rows["PART_BOX"]
	print("SMOKE rows are named by type and count, like the flat app: ", BuildTree.names(rows_pure + [{"type": "sketch", "id": "x"}]) == ["Sketch 1", "Extrude 1", "Fillet 1", "Sketch 2"])
	print("SMOKE ...with a short second line: ", BuildTree.summary(rows_pure, 0) == "on a reference plane" and BuildTree.summary(rows_pure, 1) == "Boss 12 mm" and BuildTree.summary(rows_pure, 2) == "R 2 mm, 1 edge(s)")
	print("SMOKE an extrude's edit keeps its start and direction, a fillet's replaces its radius: ", BuildTree.edit_payload(rows_pure[1], 20.0) == {"start_distance": 0.0, "end_distance": 20.0} and BuildTree.edit_payload({"type": "extrude", "start_distance": 0.0, "end_distance": -5.0}, 8.0) == {"start_distance": 0.0, "end_distance": -8.0} and BuildTree.edit_payload(rows_pure[2], 3.0) == {"radius": 3.0})
	print("SMOKE a cascade preview names what is built on the feature (the sketch takes the extrude and the fillet): ", BuildTree.dependents(rows_pure, "sk_box") == ["body_box", "fil_box"] and BuildTree.dependents(rows_pure, "fil_box").is_empty())
	var more_rows := [{"type": "revolve", "id": "rv", "sketch_feature_id": "sk_box", "angle": 270.0, "mode": "cut"}, {"type": "shell", "id": "sh", "body_id": "rv", "faces_to_remove": [{"body_id": "rv", "shape_type": "face", "index": 1}], "thickness": 1.5}, {"type": "mirror", "id": "mi", "source_body_ids": ["sh"], "mirror_plane": {"fixed_plane": "YZ"}}]
	print("SMOKE revolve, shell and mirror have one-line summaries (a cut revolve with its angle, a wall with the faces opened, the plane mirrored across): ", BuildTree.summary(more_rows, 0) == "Cut 270 deg" and BuildTree.summary(more_rows, 1) == "1.5 mm, 1 face(s) open" and BuildTree.summary(more_rows, 2) == "across YZ plane")
	print("SMOKE ...revolve and shell are editable (angle, wall) with the right PATCH, mirror is not: ", BuildTree.EDITABLE.has("revolve") and BuildTree.EDITABLE.has("shell") and not BuildTree.EDITABLE.has("mirror") and BuildTree.value_of(more_rows[0]) == 270.0 and BuildTree.edit_payload(more_rows[0], 90.0) == {"angle": 90.0} and BuildTree.edit_payload(more_rows[1], 3.0) == {"thickness": 3.0} and BuildTree.value_title("revolve") == "Angle (deg)" and BuildTree.value_title("shell") == "Thickness (mm)")
	print("SMOKE ...a cascade through them: deleting the sketch takes the revolve, the shell on its body and the mirror of the shell: ", BuildTree.dependents([rows_pure[0], more_rows[0], more_rows[1], more_rows[2]], "sk_box") == ["rv", "sh", "mi"])
	print("SMOKE rolling back to a row skips every later one: ", BuildTree.rolled_back_ids(rows_pure, 0) == ["body_box", "fil_box"] and BuildTree.rolled_back_ids(rows_pure, 2).is_empty())

	# --- the window: two tabs, opens on Build when a part is seated
	table.open()
	print("SMOKE with nothing on the table the tree window is on Parts: ", table.tree.current_tab() == "parts" and table.tree._tab_parts.button_pressed)
	table.seat(box)
	var ready: bool = await settle(func() -> bool: return table.build.features.size() == 3)
	print("SMOKE putting a part on the table opens the tree on its Build tab and reads its features: ", ready and table.tree.current_tab() == "build" and table.tree._build_pane.visible and not table.tree._parts_pane.visible and calls_to("GET /document/parts/PART_BOX/features").size() >= 1)
	print("SMOKE the Build tab lists them in order with names and summaries: ", rows().size() == 3 and rows()[0].begins_with("Sketch 1") and rows()[1].begins_with("Extrude 1") and rows()[1].contains("Boss 12 mm") and rows()[2].begins_with("Fillet 1"))
	print("SMOKE ...under a title naming the part and the count: ", table.tree._build_title.text.contains("3 feature(s)") and table.tree._build_title.text.begins_with(box.name))
	var bodies_listed: bool = table.tree._build_rows.find_children("*", "Button", true, false).any(func(b): return b.text == "Body 1")
	print("SMOKE ...and the part's bodies below: ", bodies_listed)
	table.tree.show_tab("parts")
	print("SMOKE the Parts tab is the assembly list as before (and Build comes back): ", table.tree._parts_pane.visible and not table.tree._build_pane.visible and table.tree.scroll_target == table.tree._parts_scroll)
	table.tree.show_tab("build")
	print("SMOKE ...the stick scrolls whichever pane shows: ", table.tree.scroll_target == table.tree._build_scroll)

	# --- rename the part (G16): the Build tab's Rename opens the full keyboard; confirming renames the part and every instance
	var rename_btn: Button = table.tree._rename_button
	print("SMOKE the Build tab has a Rename button while a part is on the table: ", rename_btn != null and rename_btn.visible)
	rename_btn.pressed.emit()
	await frames(2)
	print("SMOKE ...it opens the FULL keyboard on the current name: ", main._keyboard.is_open() and main._keyboard.current_mode() == "full")
	main._keyboard.close()
	fake.calls.clear()
	var renamed: bool = await table.rename_part_to("  Bracket  ")
	var patched_name: Array = calls_to("PATCH /document/parts/PART_BOX")
	print("SMOKE a confirmed name is trimmed and sent as a PATCH of the PART (so every placed instance follows): ", renamed and patched_name.size() == 1 and patched_name[0][1] == {"name": "Bracket"})
	print("SMOKE ...the arena node takes the name, the title and the status say so, and the document counts as unsaved: ", str(box.name).begins_with("Bracket") and table.tree._build_title.text.begins_with("Bracket") and table.status() == "Renamed to Bracket." and main.document_dirty)
	fake.calls.clear()
	print("SMOKE an empty name or the same name sends nothing: ", not (await table.rename_part_to("   ")) and (await table.rename_part_to("Bracket")) and calls_to("PATCH").is_empty())

	# --- select and light up
	row_button("Extrude 1").pressed.emit()
	await frames(2)
	print("SMOKE selecting the extrude lights up the faces of the body it made, and says what it is: ", table.build.selected_id == "body_box" and table.editor.highlight.set_nodes().size() > 0 and table.status().contains("Extrude 1") and table.status().contains("Boss 12 mm"))
	print("SMOKE ...and its row gets the action strip (Edit, Hide, Roll back, Delete): ", ["Edit", "Hide", "Roll back", "Delete"].all(func(t): return find_button(table.tree._build_rows, t) != null))
	row_button("Fillet 1").pressed.emit()
	await frames(2)
	print("SMOKE selecting the fillet lights its edge instead: ", table.build.selected_id == "fil_box" and table.editor.highlight.set_nodes().size() == 1 and find_button(table.tree._build_rows, "Edit") != null)
	row_button("Sketch 1").pressed.emit()
	await frames(2)
	print("SMOKE a sketch on a reference plane says so, and its Edit now opens the sketch: ", table.status().contains("reference plane") and not find_button(table.tree._build_rows, "Edit").disabled)

	# --- reopening the part's existing sketch (G7): its entities are read, the part turns to it, Select is on, Done closes it
	fake.sketch_plane = "XY"
	fake.origin = true
	fake.points = {"pA": Vector2(0, 0), "pB": Vector2(40, 0), "pC": Vector2(40, 30)}
	fake.entities = [{"type": "line", "id": "lnA", "start_point_id": "pA", "end_point_id": "pB", "construction": false}, {"type": "line", "id": "lnB", "start_point_id": "pB", "end_point_id": "pC", "construction": false}]
	fake.calls.clear()
	find_button(table.tree._build_rows, "Edit").pressed.emit()
	var reopened: bool = await settle(func() -> bool: return table.editor.state == "sketch" and table.editor.session != null and table.editor.session.lines.size() == 2)
	print("SMOKE Edit on a sketch row opens THAT sketch: its own id is read (nothing is made), its two lines and points arrive: ", reopened and table.editor.session.sketch_id == "s1" and table.editor.session.feature_id == "sk_box" and calls_to("POST /document/parts/PART_BOX/features/sketch").is_empty() and table.editor.session.lines.size() == 2)
	print("SMOKE ...the part stands the sketch's plane up at the tilt, the sketch's origin is read, and Select is on: ", table.pivot.basis.orthonormalized().is_equal_approx(table.sketch_rotation(table.editor.session.plane)) and table.editor.session.origin_id != "" and table.active_tool == "select" and table.ui.done_button() != null and not table.ui.done_button().disabled)
	var glb_fetches: int = calls_to("assembly-mesh.glb").size()
	table.ui.done_button().pressed.emit()
	await frames(3)
	print("SMOKE Done on an untouched sketch just closes it (no rebuild, nothing flagged): ", table.editor.session == null and table.editor.state == "pick_plane" and calls_to("assembly-mesh.glb").size() == glb_fetches and table.ui.done_button().disabled)
	find_button(table.tree._build_rows, "Edit").pressed.emit()
	await settle(func() -> bool: return table.editor.session != null and table.editor.session.lines.size() == 2)
	var sess = table.editor.session
	await pick_line_toggle_construction(sess)
	glb_fetches = calls_to("assembly-mesh.glb").size()
	var edited_parts: Array = []
	table.part_edited.connect(func(id: String) -> void: edited_parts.append(id))
	table.ui.done_button().pressed.emit()
	await settle(func() -> bool: return table.editor.session == null and calls_to("assembly-mesh.glb").size() > glb_fetches)
	print("SMOKE Done after a change rebuilds the part from the new sketch (the part's own glb is fetched) and flags its mates like any edit: ", calls_to("assembly-mesh.glb").size() > glb_fetches and edited_parts == ["PART_BOX"])
	fake.points.clear()
	fake.entities.clear()
	fake.sketch_plane = null
	row_button("Sketch 1").pressed.emit()
	await frames(2)
	table.build.select("sk_box")
	await frames(2)


	# --- an older backend: the glb ignores hidden / rollback, so Hide and Roll back are switched off and the tree says why
	print("SMOKE the backend was asked once whether it can hide and roll back, and said yes: ", table.build.view_filters_ok and table.build._probed)
	fake.view_filters = false
	table.build._probed = false
	await table.build.probe_backend()
	row_button("Extrude 1").pressed.emit()
	await frames(2)
	var hide_btn: Button = find_button(table.tree._build_rows, "Hide")
	var back_btn: Button = find_button(table.tree._build_rows, "Roll back")
	print("SMOKE an older backend switches Hide and Roll back off, with a note saying why: ", not table.build.view_filters_ok and hide_btn != null and hide_btn.disabled and back_btn.disabled and table.tree._build_rows.find_children("*", "Label", true, false).any(func(l): return l.text.contains("older than DIDSA-CAD 2026-10-03")))
	var calls_before: int = fake.calls.size()
	await table.build.toggle_hidden_selected()
	await table.build.toggle_rollback_selected()
	print("SMOKE ...and pressing them anyway does nothing (no glb fetch, nothing hidden): ", fake.calls.size() == calls_before and table.build.hidden_ids().is_empty() and table.build.rollback_to == "")
	fake.view_filters = true
	table.build.view_filters_ok = true
	table.build.changed.emit()
	await frames(2)

	# --- Edit values
	row_button("Extrude 1").pressed.emit()
	await frames(2)
	find_button(table.tree._build_rows, "Edit").pressed.emit()
	await frames(2)
	print("SMOKE Edit opens the numeric pad on the current value: ", main._keyboard.is_open())
	main._keyboard.close()
	fake.calls.clear()
	await table.build.edit_typed("body_box", "abc")
	await table.build.edit_typed("body_box", "0")
	print("SMOKE a typed value that is not a number bigger than zero is refused with no call: ", calls_to("PATCH").is_empty() and table.status().contains("bigger than zero"))
	await table.build.edit_typed("body_box", "20")
	var patched: Array = calls_to("PATCH /document/parts/PART_BOX/extrude-features/body_box")
	print("SMOKE a good value PATCHes the extrude (start kept, end moved) and fetches the new shape: ", patched.size() == 1 and patched[0][1] == {"start_distance": 0.0, "end_distance": 20.0} and calls_to("assembly-mesh.glb").size() >= 1)
	print("SMOKE ...the tree shows the new depth: ", rows()[1].contains("Boss 20 mm") and table.status().contains("20"))
	print("SMOKE ...and Undo puts the old value back with a PATCH (no delete): ", table.editor.can_undo())
	fake.calls.clear()
	await table.editor.undo()
	var undone: Array = calls_to("PATCH /document/parts/PART_BOX/extrude-features/body_box")
	print("SMOKE ...exactly that: ", undone.size() == 1 and undone[0][1] == {"start_distance": 0.0, "end_distance": 12.0} and calls_to("DELETE").is_empty() and rows()[1].contains("Boss 12 mm"))

	# --- Hide / Show: only the table's copy
	var arena_mesh_before = box.mesh
	var copy_mesh_full = table.table_copy.mesh
	fake.calls.clear()
	find_button(table.tree._build_rows, "Hide").pressed.emit()
	await settle(func() -> bool: return table.table_copy.layers == 0)
	var fetch: Array = calls_to("hidden_feature_ids=body_box")
	print("SMOKE Hide asks for a second picture with the hidden id: ", fetch.size() == 1 and main.hidden_feature_ids() == ["body_box"])
	print("SMOKE ...the table's copy shows nothing (the filtered picture was empty) and cannot be picked, while the arena's real part keeps its mesh: ", table.table_copy.layers == 0 and not table.table_copy.get_children().any(func(c): return c is StaticBody3D) and box.mesh == arena_mesh_before and box.has_meta("face_ids"))
	print("SMOKE ...the row says hidden and the strip offers Show: ", rows()[1].contains("hidden") and find_button(table.tree._build_rows, "Show") != null)
	print("SMOKE ...and the id is saved in the file's hidden_feature_ids extra, as the flat app keeps it: ", main.native_extras_to_add({}).get("hidden_feature_ids") == ["body_box"])
	fake.calls.clear()
	find_button(table.tree._build_rows, "Show").pressed.emit()
	await settle(func() -> bool: return table.table_copy.layers == 1)
	print("SMOKE Show puts the whole part back on the table with no second fetch: ", table.table_copy.layers == 1 and table.table_copy.mesh == arena_mesh_before and calls_to("hidden_feature_ids").is_empty() and main.hidden_feature_ids().is_empty() and not main.native_extras_to_add({}).has("hidden_feature_ids"))

	# --- Roll back / forward
	row_button("Sketch 1").pressed.emit()
	await frames(2)
	fake.calls.clear()
	find_button(table.tree._build_rows, "Roll back").pressed.emit()
	await settle(func() -> bool: return table.build.is_rolled_back_any())
	await frames(2)
	var rb: Array = calls_to("rollback_excluded_feature_ids=")
	print("SMOKE Roll back to the sketch skips the two later features and asks for the picture without them: ", table.build.rollback_excluded() == ["body_box", "fil_box"] and rb.size() == 1 and rb[0][0].contains("rollback_excluded_feature_ids=body_box") and rb[0][0].contains("rollback_excluded_feature_ids=fil_box"))
	print("SMOKE ...the later rows say rolled back and the title says so: ", rows()[1].contains("rolled back") and rows()[2].contains("rolled back") and not rows()[0].contains("rolled back") and table.tree._build_title.text.contains("rolled back"))
	fake.calls.clear()
	table.manager.activate("extrude")
	table.editor.options["boss"] = true
	await table.editor.apply_feature()
	print("SMOKE adding to a rolled-back part is refused until it is rolled forward: ", calls_to("POST").is_empty() and table.status().contains("rolled back"))
	table.manager.deactivate()
	find_button(table.tree._build_rows, "Roll forward").pressed.emit()
	await settle(func() -> bool: return not table.build.is_rolled_back_any())
	print("SMOKE Roll forward builds the whole part again: ", table.build.rollback_excluded().is_empty() and table.table_copy.layers == 1 and not rows()[1].contains("rolled back"))
	var last_row_button := row_button("Fillet 1")
	last_row_button.pressed.emit()
	await frames(2)
	print("SMOKE the last row has nothing after it to roll back: ", find_button(table.tree._build_rows, "Roll back").disabled)

	# --- Delete: two presses, cascade
	row_button("Sketch 1").pressed.emit()
	await frames(2)
	fake.calls.clear()
	find_button(table.tree._build_rows, "Delete").pressed.emit()
	await frames(2)
	print("SMOKE the first Delete press only arms it and names what will go: ", calls_to("DELETE").is_empty() and table.status().contains("Sure?") and table.status().contains("Extrude 1") and table.status().contains("Fillet 1") and find_button(table.tree._build_rows, "Sure?") != null)
	table.build._armed_until_ms = Time.get_ticks_msec() - 1
	find_button(table.tree._build_rows, "Sure?") if false else null
	table.build.delete_selected()
	await frames(2)
	print("SMOKE a press after the few seconds are up arms it again instead of deleting: ", calls_to("DELETE").is_empty() and table.status().contains("Sure?"))
	table.build.delete_selected()
	await settle(func() -> bool: return not calls_to("/cascade").is_empty())
	await settle(func() -> bool: return table.build.features.is_empty())
	var cascades: Array = calls_to("DELETE /document/parts/PART_BOX/features/sk_box/cascade")
	print("SMOKE the second press cascades: one DELETE, the sketch and what was built on it go from the tree: ", cascades.size() == 1 and table.build.features.is_empty() and rows().is_empty())
	print("SMOKE ...Undo has nothing stale to take back: ", not table.editor.can_undo())
	print("SMOKE ...and the user is told how many went: ", table.status().contains("3"))

	# --- a part seated with something already hidden shows it that way
	seed_rows()
	main.set_feature_hidden("body_box", true)
	table.return_to_arena()
	await frames(2)
	fake.calls.clear()
	table.seat(box)
	await settle(func() -> bool: return not calls_to("hidden_feature_ids=body_box").is_empty())
	print("SMOKE a part seated while one of its features is hidden is fetched with it hidden: ", not calls_to("hidden_feature_ids=body_box").is_empty() and table.table_copy.layers == 0)
	main.set_feature_hidden("body_box", false)

	# --- the part leaves: back to Parts
	table.return_to_arena()
	await frames(3)
	print("SMOKE when the part leaves the table the tree goes back to Parts and the Build state is empty: ", table.tree.current_tab() == "parts" and table.build.features.is_empty() and table.build.selected_id == "" and table.build.rollback_to == "")
	# --- a normal part that loses every solid goes blank, like a new one (it used to keep its last shape in the arena)
	table.seat(box)
	await settle(func() -> bool: return table.editor.part_id == "PART_BOX" and table.editor.state == "pick_plane")
	var had_mesh: bool = box.mesh != null and not box.get_meta("blank", false)
	fake.mesh_bytes = empty_glb()
	await table.editor.refresh_geometry()
	print("SMOKE a normal part whose last solid is gone becomes the blank placeholder in the arena and on the table: ", had_mesh and box.get_meta("blank", false) and table.is_blank() and not box.has_meta("topology"))
	fake.mesh_bytes = box_bytes
	await table.editor.refresh_geometry()
	print("SMOKE ...and a feature put back (undo, or a new one) makes it a real part again: ", not box.get_meta("blank", false) and not table.is_blank() and box.has_meta("topology"))
	quit()
