extends SceneTree
## Phase 4 of docs/implementation-plan.md: mending a flagged NON-sketch feature from its Build row (scripts/design_table/build_tree.gd fix_target / fix_payload,
## table_build.gd fix_selected, table_editor.gd begin_fix / _finish_fix / _end_fix), with the FAKE backend and the box-and-cylinder fixture.
## Pure: which features and which flagged paths are fixable (a fillet / chamfer's edges, a shell's faces, a mirror's plane face, a create-plane's face or edge;
## a sketch, an unflagged row and a mix of edges and faces are not), and the PATCH body each one makes (only the flagged references are replaced, the rest kept).
## Scene: a flagged chamfer's row offers Fix; Fix rolls the table's copy back to the row BEFORE it (a glb fetch with the chamfer and everything after left out) and
## lets the laser pick edges; the deck offers Apply fix (counting the picks), Clear and Cancel; Cancel changes nothing; Apply fix sends the PATCH with the kept and
## the new edge, rolls forward, clears the flag and takes no Undo entry (the old reference was lost, putting it back would fail); a refused PATCH keeps the mode.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_fix_references.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var fake


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


func find_button(root_node: Node, text: String) -> Button:
	for n in root_node.find_children("*", "Button", true, false):
		if (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


func edge_hover(body: String, index: int) -> Dictionary:
	return {"kind": "edge", "body_id": body, "index": index, "face_index": 0, "key": TopologyPick.entity_key("edge", body, index)}


func _initialize() -> void:
	# --- pure
	var chamfer := {"type": "chamfer", "id": "c1", "edge_refs": [{"body_id": "b", "shape_type": "edge", "index": 3}, {"body_id": "b", "shape_type": "edge", "index": 7}], "distance": 2.0, "lost_references": ["edge_refs[1]"], "moved_references": []}
	var fix: Dictionary = BuildTree.fix_target(chamfer)
	print("SMOKE a chamfer with one lost edge needs one edge re-picked: ", fix == {"type": "chamfer", "kind": "edge", "paths": ["edge_refs[1]"]})
	print("SMOKE its PATCH replaces only that edge and keeps the other: ", BuildTree.fix_payload(chamfer, ["edge_refs[1]"], [{"body_id": "b", "index": 9}]) == {"edge_refs": [{"body_id": "b", "shape_type": "edge", "index": 3}, {"body_id": "b", "shape_type": "edge", "index": 9}]})
	var moved_and_lost := chamfer.duplicate(true)
	moved_and_lost["moved_references"] = ["edge_refs[0]"]
	print("SMOKE lost ones come first, then the ones that may have moved (a pick for each, in that order): ", BuildTree.fix_target(moved_and_lost)["paths"] == ["edge_refs[1]", "edge_refs[0]"] and BuildTree.fix_payload(moved_and_lost, ["edge_refs[1]", "edge_refs[0]"], [{"body_id": "b", "index": 9}, {"body_id": "b", "index": 4}])["edge_refs"][0]["index"] == 4)
	print("SMOKE an unflagged row, a sketch and a type with no fix are not fixable: ", BuildTree.fix_target({"type": "fillet", "edge_refs": []}).is_empty() and BuildTree.fix_target({"type": "sketch", "lost_references": ["x"], "has_lost_reference": true}).is_empty() and BuildTree.fix_target({"type": "extrude", "lost_references": ["x"]}).is_empty())
	var shell := {"type": "shell", "id": "s1", "body_id": "b", "faces_to_remove": [{"body_id": "b", "shape_type": "face", "index": 1}, {"body_id": "b", "shape_type": "face", "index": 4}], "thickness": 1.0, "lost_references": ["faces_to_remove[0]"]}
	print("SMOKE a shell's lost face is a FACE pick and its PATCH keeps the other face: ", BuildTree.fix_target(shell)["kind"] == "face" and BuildTree.fix_payload(shell, ["faces_to_remove[0]"], [{"body_id": "b", "index": 2}]) == {"faces_to_remove": [{"body_id": "b", "shape_type": "face", "index": 2}, {"body_id": "b", "shape_type": "face", "index": 4}]})
	var mirror := {"type": "mirror", "id": "m1", "mirror_plane": {"face_ref": {"body_id": "b", "shape_type": "face", "index": 1}}, "lost_references": ["mirror_plane.face_ref"]}
	print("SMOKE a mirror's plane face: ", BuildTree.fix_target(mirror)["kind"] == "face" and BuildTree.fix_payload(mirror, ["mirror_plane.face_ref"], [{"body_id": "b", "index": 2}]) == {"mirror_plane": {"face_ref": {"body_id": "b", "shape_type": "face", "index": 2}}})
	var plane := {"type": "create_plane", "id": "p1", "plane_type": "offset_face", "face_refs": [{"face_ref": {"body_id": "b", "shape_type": "face", "index": 1}}], "lost_references": ["face_refs[0].face_ref"]}
	print("SMOKE a create-plane's face: ", BuildTree.fix_target(plane)["kind"] == "face" and BuildTree.fix_payload(plane, ["face_refs[0].face_ref"], [{"body_id": "b", "index": 5}]) == {"face_refs": [{"face_ref": {"body_id": "b", "shape_type": "face", "index": 5}}]})
	print("SMOKE a mix of edges and faces, or the wrong number of picks, is refused: ", BuildTree.fix_target({"type": "create_plane", "lost_references": ["edge_ref", "face_refs[0].face_ref"]}).is_empty() and BuildTree.fix_payload(chamfer, ["edge_refs[1]"], []).is_empty())

	# --- the scene
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
	var box: MeshInstance3D = null
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
	fake.filtered_mesh_bytes = box_bytes # the part "as the chamfer saw it": the fixture box, with its edges to pick
	fake.feature_rows = {"PART_BOX": [
		{"type": "sketch", "id": "sk_box", "sketch_id": "s1", "plane_feature_id": null, "locked": true, "has_lost_reference": false},
		{"type": "extrude", "id": "body_box", "sketch_feature_id": "sk_box", "extrude_type": "boss", "start_distance": 0.0, "end_distance": 12.0, "target_body_ids": [], "locked": true},
		{"type": "fillet", "id": "fil_box", "edge_refs": [{"body_id": "body_box", "shape_type": "edge", "index": 0}], "radius": 2.0, "locked": false},
		{"type": "chamfer", "id": "ch_box", "edge_refs": [{"body_id": "body_box", "shape_type": "edge", "index": 3}, {"body_id": "body_box", "shape_type": "edge", "index": 7}], "distance": 2.0, "locked": false,
			"has_lost_reference": true, "lost_references": ["edge_refs[1]"], "moved_references": [], "followed_references": []},
	]}
	table.api = fake
	table.editor.api = fake
	var ed = table.editor
	table.open()
	table.seat(box)
	await settle(func() -> bool: return table.build.features.size() == 4)
	await settle(func() -> bool: return ed.state == "pick_plane")
	table.build.select("ch_box")
	table.tree._rebuild_rows()
	await frames(2)
	print("SMOKE the flagged chamfer's row carries the note and its action strip offers Fix (an unflagged row's does not): ", BuildTree.reference_note(table.build.row("ch_box")) == "lost reference" and find_button(table.tree._build_rows, "Fix") != null)
	table.build.select("fil_box")
	table.tree._rebuild_rows()
	await frames(2)
	print("SMOKE ...an unflagged fillet's strip has no Fix: ", find_button(table.tree._build_rows, "Fix") == null)
	table.build.select("ch_box")
	table.tree._rebuild_rows()
	await frames(2)

	# --- Fix, then Cancel
	fake.calls.clear()
	find_button(table.tree._build_rows, "Fix").pressed.emit()
	await settle(func() -> bool: return not ed.fixing.is_empty())
	await settle(func() -> bool: return not calls_to("assembly-mesh.glb").is_empty())
	var fetches := calls_to("assembly-mesh.glb")
	print("SMOKE Fix shows the part as the chamfer saw it: a glb fetch with the chamfer left out, and the laser picks edges: ", ed.state == "pick_edges" and table.build.rollback_to == "fil_box" and fetches.size() >= 1 and fetches.back()[0].contains("rollback_excluded_feature_ids=ch_box"))
	print("SMOKE ...the deck offers Apply fix (0 of 1, off), Clear and Cancel in place of the tool's own settings: ", table.ui.option_button("fix_apply") != null and table.ui.option_button("fix_apply").disabled and table.ui.option_button("fix_apply").text == "Apply fix (0 of 1)" and table.ui.option_button("fix_clear") != null and table.ui.option_button("fix_cancel") != null)
	fake.calls.clear()
	await ed.on_option("fix_cancel")
	await settle(func() -> bool: return not table.build.is_rolled_back_any())
	print("SMOKE Cancel rolls forward, leaves the mode and sends no PATCH: ", ed.fixing.is_empty() and table.build.rollback_to == "" and ed.state == "pick_plane" and calls_to("PATCH").is_empty() and (table.build.row("ch_box")["lost_references"] as Array).size() == 1)

	# --- Fix, pick, Apply
	find_button(table.tree._build_rows, "Fix").pressed.emit()
	await settle(func() -> bool: return not ed.fixing.is_empty() and ed.state == "pick_edges")
	ed._hover_face = edge_hover("body_box", 9)
	ed._toggle_edge()
	print("SMOKE one pick fills the one flagged reference and Apply fix comes on: ", ed.edges.size() == 1 and not table.ui.option_button("fix_apply").disabled and table.ui.option_button("fix_apply").text == "Apply fix (1 of 1)")
	ed._hover_face = edge_hover("body_box", 11)
	ed._toggle_edge()
	print("SMOKE a second pick replaces the first (one replacement per flagged reference): ", ed.edges.size() == 1 and ed.edges[0]["index"] == 11)
	var undo_before: int = ed.feature_stack.size()
	fake.calls.clear()
	await ed.on_option("fix_apply")
	await settle(func() -> bool: return ed.fixing.is_empty())
	var patches := calls_to("PATCH /document/parts/PART_BOX/chamfer-features/ch_box")
	print("SMOKE Apply fix PATCHes the chamfer with the kept edge and the new one: ", patches.size() == 1 and patches[0][1] == {"edge_refs": [{"body_id": "body_box", "shape_type": "edge", "index": 3}, {"body_id": "body_box", "shape_type": "edge", "index": 11}]}, " ", patches[0][1] if not patches.is_empty() else "-")
	await settle(func() -> bool: return (table.build.row("ch_box").get("lost_references", []) as Array).is_empty())
	print("SMOKE ...the flag is gone, the Build row has no note, the part is rolled forward and the mode is left: ", BuildTree.reference_note(table.build.row("ch_box")) == "" and table.build.rollback_to == "" and ed.state == "pick_plane" and not ed.view_is_filtered())
	print("SMOKE ...and it takes no Undo entry (the old reference was lost: putting it back would fail): ", ed.feature_stack.size() == undo_before)

	# --- a refused PATCH keeps the mode so another edge can be tried
	fake.feature_rows["PART_BOX"][3]["lost_references"] = ["edge_refs[1]"]
	fake.feature_rows["PART_BOX"][3]["has_lost_reference"] = true
	await table.build.reload()
	table.build.select("ch_box")
	await table.build.fix_selected()
	await settle(func() -> bool: return not ed.fixing.is_empty() and ed.state == "pick_edges")
	ed._hover_face = edge_hover("body_box", 5)
	ed._toggle_edge()
	fake.fail = "chamfer-features"
	fake.calls.clear()
	await ed.on_option("fix_apply")
	await frames(3)
	print("SMOKE a PATCH the backend refuses keeps fix mode (and says why) so another edge can be picked: ", not ed.fixing.is_empty() and ed.state == "pick_edges" and table.status().begins_with("Couldn't use that"))
	table.close()
	quit()
