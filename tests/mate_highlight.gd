extends SceneTree
## T3 (docs/test-report-30-oct-plan.md): selecting a mate on the wrist tablet lights the two things it mates. Pure: mates_tool.gd's highlight_for() turns a mate's
## references into face_highlight entries (face + edge, the two pick colours; a plane or point side skipped with its reason; a Width mate's four faces in pairs; a
## part that is not on screen skipped; a visible copy preferred), direction_hint() ("behind you", left, right, above). side_panel_ui.gd: a selectable row is
## selected by a tap on its body (not on its buttons), drawn in the accent, a second tap clears it. Full scene (main.tscn, no backend): highlight_mate() lights two
## pick nodes with the right keys, pulses the two bodies for a moment then lets go, clears on a new pick, on a mate that is gone, and the tablet's row tap reaches it.
## NOT checked: how the highlight reads on a headset, and a live mate (tests/e2e_mate_highlight.gd).
## Run: "$GODOT" --headless --path . --script res://tests/mate_highlight.gd  (see tests/README.md)

const MatesTool := preload("res://scripts/mates_tool.gd")
const SidePanelUI := preload("res://scripts/ui/side_panel_ui.gd")

var main


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await process_frame
		await physics_frame


func cube_part(parent: Node, pos: Vector3, body: String, occ: String) -> MeshInstance3D:
	var h := 0.25
	var faces := [
		[Vector3(0, 0, 1), Vector3(-h, -h, h), Vector3(h, -h, h), Vector3(h, h, h), Vector3(-h, h, h)],
		[Vector3(0, 0, -1), Vector3(h, -h, -h), Vector3(-h, -h, -h), Vector3(-h, h, -h), Vector3(h, h, -h)],
		[Vector3(0, 1, 0), Vector3(-h, h, h), Vector3(h, h, h), Vector3(h, h, -h), Vector3(-h, h, -h)],
		[Vector3(0, -1, 0), Vector3(-h, -h, -h), Vector3(h, -h, -h), Vector3(h, -h, h), Vector3(-h, -h, h)],
		[Vector3(1, 0, 0), Vector3(h, -h, h), Vector3(h, -h, -h), Vector3(h, h, -h), Vector3(h, h, h)],
		[Vector3(-1, 0, 0), Vector3(-h, -h, -h), Vector3(-h, -h, h), Vector3(-h, h, h), Vector3(-h, h, -h)],
	]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var face_ids := []
	var body_ids := []
	var f := 0
	for q in faces:
		for tri in [[1, 3, 2], [1, 4, 3]]:
			for k in tri:
				verts.append(q[k])
				normals.append(q[0])
			face_ids.append(f)
			body_ids.append(body)
		f += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.name = "Part_" + occ
	parent.add_child(m)
	m.position = pos
	m.add_to_group("grabbable_parts")
	m.set_meta("occurrence_id", occ)
	m.set_meta("owner_part_id", "root")
	m.set_meta("face_ids", face_ids)
	m.set_meta("body_ids", body_ids)
	return m


func face_ref(body: String, index: int, kind: String = "face") -> Dictionary:
	return {"body_id": body, "shape_type": kind, "index": index}


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var a := cube_part(main.assembly_root, Vector3(0, 1, -1.5), "bodyA", "oA")
	var b := cube_part(main.assembly_root, Vector3(1.0, 1, -1.5), "bodyB", "oB")
	await frames(2)
	var nodes := [a, b]

	# --- highlight_for: pure
	var coincident := {"id": "m1", "type": "coincident", "references": [
		{"occurrence_id": "oA", "subshape_ref": face_ref("bodyA", 3)}, {"occurrence_id": "oB", "subshape_ref": face_ref("bodyB", 5, "edge")}]}
	var res := MatesTool.highlight_for(coincident, nodes)
	var keys := []
	var slots := []
	for e in res["entries"]:
		keys.append(e["key"])
		slots.append(e["colour_slot"])
	check("a face and an edge reference light two entities with the right keys (face: body:index, edge: edge:body:index)", keys == ["bodyA:3", "edge:bodyB:5"])
	check("...in the two pick colours (slot 0 and slot 1) and on the two parts", slots == [0, 1] and res["parts"].size() == 2 and res["skipped"].is_empty())
	var with_plane := {"id": "m2", "type": "distance", "references": [
		{"occurrence_id": "oA", "subshape_ref": face_ref("bodyA", 1)}, {"occurrence_id": "oB", "plane_ref": {"reference_plane": "XY"}}]}
	res = MatesTool.highlight_for(with_plane, nodes)
	check("a plane side is skipped (with its reason) and the face side still lights", res["entries"].size() == 1 and res["skipped"] == ["a plane"])
	var with_point := {"references": [{"occurrence_id": "oA", "point_ref": {"x": 0}}, {"occurrence_id": "oB", "subshape_ref": face_ref("bodyB", 0, "vertex")}]}
	res = MatesTool.highlight_for(with_point, nodes)
	check("a point side is skipped, a vertex side lights", res["entries"].size() == 1 and res["entries"][0]["kind"] == "vertex" and res["skipped"] == ["a point"])
	var width := {"id": "m3", "type": "coincident", "references": [
		{"occurrence_id": "oA", "midplane": {"a": {"face_ref": face_ref("bodyA", 0)}, "b": {"face_ref": face_ref("bodyA", 1)}}},
		{"occurrence_id": "oB", "midplane": {"a": {"face_ref": face_ref("bodyB", 2)}, "b": {"face_ref": face_ref("bodyB", 3)}}}]}
	res = MatesTool.highlight_for(width, nodes)
	slots = []
	for e in res["entries"]:
		slots.append(e["colour_slot"])
	check("a Width mate lights its four faces, the gap's two in one colour and the part's two in the other", res["entries"].size() == 4 and slots == [0, 0, 1, 1])
	var cross := {"references": [{"occurrence_id": "oA", "midplane": {"a": {"face_ref": face_ref("bodyA", 0)}, "b": {"face_ref": face_ref("bodyB", 1)}, "b_occurrence_id": "oB"}},
		{"occurrence_id": "oA", "subshape_ref": face_ref("bodyA", 4)}]}
	res = MatesTool.highlight_for(cross, nodes)
	check("a Symmetric mid-plane's second face is looked for on b_occurrence_id", res["entries"].size() == 3 and res["entries"][1]["part"] == b and res["entries"][1]["colour_slot"] == 0 and res["entries"][2]["colour_slot"] == 1)
	res = MatesTool.highlight_for({"references": [{"occurrence_id": "gone", "subshape_ref": face_ref("bodyA", 0)}]}, nodes)
	check("a reference to a part that is not on screen is skipped, not guessed", res["entries"].is_empty() and res["skipped"] == ["a part that is not on screen"])
	var copy := cube_part(main.assembly_root, Vector3(3, 1, -1.5), "bodyA", "oA") # a second node for the same occurrence (a room's copy)
	a.visible = false
	check("with two nodes for one occurrence the visible one is used", MatesTool.highlight_for({"references": [{"occurrence_id": "oA", "subshape_ref": face_ref("bodyA", 2)}]}, [a, copy])["entries"][0]["part"] == copy)
	a.visible = true
	copy.queue_free()
	var cam := Transform3D(Basis.IDENTITY, Vector3.ZERO) # looking down -Z
	check("direction hint: ahead is silent, behind says behind, the sides say which", MatesTool.direction_hint(cam, Vector3(0, 0, -3), "P") == "" and MatesTool.direction_hint(cam, Vector3(0, 0, 3), "P") == "P is behind you." and MatesTool.direction_hint(cam, Vector3(3, 0, -0.5), "P") == "P is off to your right." and MatesTool.direction_hint(cam, Vector3(-3, 0, -0.5), "P") == "P is off to your left." and MatesTool.direction_hint(cam, Vector3(0, 3, -0.5), "P") == "P is above you.")

	# --- the full scene: the tool, the highlighter
	var tool = main._mates_tool
	var fh = main.face_highlight
	var two_faces := {"id": "m1", "type": "coincident", "references": [
		{"occurrence_id": "oA", "subshape_ref": face_ref("bodyA", 3)}, {"occurrence_id": "oB", "subshape_ref": face_ref("bodyB", 5)}]} # (the test cubes have no edge topology to draw an edge from)
	coincident = two_faces
	tool.mates = [coincident, with_plane]
	var lit: bool = tool.highlight_mate("m1")
	await frames(2)
	check("selecting a mate lights two pick nodes on the two parts, one on each", lit and fh.pick_nodes().size() == 2 and (fh.pick_nodes()[0] as Node).get_parent() == a and (fh.pick_nodes()[1] as Node).get_parent() == b)
	tool.highlight_mate("")
	await frames(1)
	check("clearing (an empty id) puts them out", fh.pick_nodes().size() == 0 and tool.highlight_id == "")
	tool.highlight_mate("m1")
	await frames(1)
	check("the two parts' bodies are outlined for a moment", fh.hover_key(tool._pulse_sources[0]) == "solid:bodyA" and fh.hover_key(tool._pulse_sources[1]) == "solid:bodyB" if tool._pulse_sources.size() == 2 else false)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < int(MatesTool.PULSE_SECONDS * 1000.0) + 400:
		await process_frame
	check("...and the outline lets go after the pulse, the picks stay", tool._pulse_sources.is_empty() and fh.pick_nodes().size() == 2)
	tool.set_active(true)
	await frames(1)
	check("starting the tool's own picking clears the highlight", fh.pick_nodes().size() == 0 and tool.highlight_id == "")
	tool.set_active(false)
	tool.highlight_mate("m1")
	tool.mates = [with_plane] # the selected mate was deleted: a refresh drops it
	tool._current_owner_part_id = ""
	tool.highlight_mate("nope")
	check("a mate id that is not in the list lights nothing", fh.pick_nodes().size() == 0 and tool.highlight_id == "")
	tool.mates = [coincident]
	var camera: XRCamera3D = main.get_node("XROrigin3D/XRCamera3D")
	camera.global_transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0, 1.6, 0)) # turned to look at +Z: both parts are behind
	tool.highlight_mate("m1", camera)
	check("a mate whose part is out of view says so in the status line", "behind you" in tool.status_text())
	tool.highlight_mate("")

	# --- the side panel: tap a selectable row
	var side := SidePanelUI.new()
	root.add_child(side)
	side.setup(load("res://ui/didsa_ui_theme.tres"), Vector2(400, 600))
	var selected := []
	side.row_selected.connect(func(id: String) -> void: selected.append(id))
	var rows := [
		{"id": "m1", "title": "Coincident", "subtitle": "", "state": "normal", "selectable": true, "actions": [{"label": "Delete", "callback": func() -> void: pass}]},
		{"id": "m2", "title": "Distance", "subtitle": "", "state": "normal", "selectable": true},
		{"id": "x", "title": "Not selectable", "subtitle": "", "state": "normal"},
	]
	side.set_list("Mates", rows)
	await frames(1)
	var cards: Array = side._rows.get_children()
	var tap := func(card: Control) -> void:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		card.gui_input.emit(ev)
	tap.call(cards[0])
	check("a tap on a selectable row selects it and says which", selected == ["m1"] and side.selected_id == "m1")
	check("...and draws it with an accent border (the card's panel style is overridden)", side._rows.get_child(0).has_theme_stylebox_override("panel") and not side._rows.get_child(1).has_theme_stylebox_override("panel"))
	tap.call(cards[1])
	check("another row moves the selection", selected == ["m1", "m2"] and side.selected_id == "m2" and not side._rows.get_child(0).has_theme_stylebox_override("panel"))
	tap.call(cards[1])
	check("a second tap on the selected row clears it (id is empty)", selected == ["m1", "m2", ""] and side.selected_id == "")
	check("a row that is not selectable has no tap handler", not (cards[2] as Control).has_meta("row_id"))
	var presses := []
	var delete_button: Button = cards[0].find_children("*", "Button", true, false)[0]
	side.row_selected.connect(func(_id: String) -> void: presses.append(1))
	delete_button.pressed.emit()
	check("a press on a row's own button is not a row tap", presses.is_empty())
	side.set_list("Mates", rows)
	side.selected_id = "m1"
	side.set_list("Mates", rows)
	await frames(1)
	check("the selection survives the list being polled and redrawn", side._rows.get_child(0).has_theme_stylebox_override("panel"))
	side.clear_selection(true)
	check("clear_selection(true) tells the host", selected.back() == "" and side.selected_id == "")
	quit()
