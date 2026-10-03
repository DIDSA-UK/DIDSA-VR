extends SceneTree
## The design table's editing session driven by the real laser (scripts/design_table/table_editor.gd), with a FAKE
## backend (tests/helpers/fake_cad.gd) and the real-winding box-and-cylinder fixture (tests/fixtures/topology_box_cylinder.glb).
## A part goes on the table and is looked up from its occurrence; aiming at its faces lights one up and claims the laser;
## a trigger on a flat face makes a plane and opens a sketch (the part turns to lie on it); aiming at the sketch sheet gives a
## snapped cursor; a rectangle is drawn with two real trigger pulls; Snap off frees the cursor; the deck keeps the laser
## when it's on the deck; Horizontal picks a line under the laser; Dimension offers a length, opens the numeric pad on the
## label, and a typed value reaches the backend; polygon and extrude settings appear in the options row; Extrude sends the
## right body, depth and direction and brings the new mesh back; Fillet picks and un-picks edges and sends them; Undo takes
## the last feature back; and a reference plane is picked by aiming at it beside the part.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_editing.gd  (see tests/README.md)

const Fake := preload("res://tests/helpers/fake_cad.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var main
var table
var ed
var r: XRController3D
var fake


func frames(n: int = 3) -> void:
	for i in n:
		await physics_frame
		await process_frame


func aim(from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	r.global_transform = Transform3D(Basis.looking_at(dir, up), from)
	await frames(3)


func pull() -> void:
	r.button_pressed.emit("trigger_click")
	await frames(2)
	r.button_released.emit("trigger_click")
	await frames(2)


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await process_frame
	return false


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func aim_uv(uv: Vector2) -> void:
	## Aims the laser at a sheet position from above the sheet.
	var copy: Node3D = table.table_copy
	var plane: Dictionary = ed.session.plane
	var world: Vector3 = copy.global_transform * SketchMath.from_sheet(uv, plane)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	await aim(world + normal * 0.45 + Vector3(0, 0, 0.12), world)


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	origin.get_node("XRCamera3D").position = Vector3(0, 1.6, 0)
	r = origin.get_node("RightController")
	var l: XRController3D = origin.get_node("LeftController")
	l.position = Vector3(-0.5, 1.0, -0.2)
	r.position = Vector3(1.0, 1.5, 1.0)
	table = main.design_table
	table.surface.settle_seconds = 0.0
	ed = table.editor
	var bytes := FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb")
	main._show_model(bytes, "", 0.001)
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
	fake.mesh_bytes = bytes
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [plane["origin"].x, plane["origin"].y, plane["origin"].z], "normal": [plane["n"].x, plane["n"].y, plane["n"].z],
			"x_axis": [plane["x"].x, plane["x"].y, plane["x"].z], "y_axis": [plane["y"].x, plane["y"].y, plane["y"].z]}
	ed.api = fake

	# --- a part on the table is looked up from its occurrence
	table.open()
	print("SMOKE with no part on the table the editor is idle: ", ed.state == "idle")
	table.seat(box)
	var looked_up: bool = await settle(func() -> bool: return ed.state == "pick_plane")
	print("SMOKE seating looks the part up through the owner's occurrences, not the node's own ids: ", looked_up and ed.part_id == "PART_BOX" and calls_to("/occurrences").size() >= 2)
	print("SMOKE plane picking is on, with the three reference planes drawn on the copy: ", ed.markers != null and ed.markers.get_parent() == table.table_copy and ed.markers.get_child_count() == 3)
	print("SMOKE ...and the user is told what to do: ", table.status().contains("Aim at a flat face"))

	# --- aiming at a face lights it up and takes the laser
	var pivot_world: Vector3 = table.pivot.global_position
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	print("SMOKE aiming at the part finds a face and the editor takes the laser: ", ed.hovering and not ed._hover_face.is_empty() and ed._hover_face["kind"] == "face")
	print("SMOKE ...the shared ui_hover claim is set, so a trigger here never selects an arena part: ", r.get_meta("ui_hover", false) and float(r.get_meta("ui_hit_distance", -1.0)) > 0.0)
	print("SMOKE ...and that face is lit on the copy: ", ed.highlight.hover_node(r) != null and ed.highlight.hover_node(r).get_parent() == table.table_copy)
	await aim(Vector3(1.0, 1.5, 1.0), Vector3(2.0, 1.5, 2.0))
	print("SMOKE aiming away lets go of the claim and clears the highlight: ", not ed.hovering and not r.get_meta("ui_hover", false) and ed.highlight.hover_node(r) == null)

	# --- the trigger on a face makes a plane and opens a sketch
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	var picked: Dictionary = ed._hover_face.duplicate()
	await pull()
	var opened: bool = await settle(func() -> bool: return ed.state == "sketch")
	print("SMOKE the trigger on a flat face opens a sketch: ", opened and ed.session != null and ed.session.is_open())
	var plane_call: Array = calls_to("/create-plane-features")[0]
	print("SMOKE ...by making an offset_face plane on exactly the face that was lit: ", plane_call[1]["plane_type"] == "offset_face" and plane_call[1]["face_refs"][0]["face_ref"]["index"] == picked["index"] and plane_call[1]["face_refs"][0]["face_ref"]["body_id"] == picked["body_id"])
	var plane: Dictionary = ed.session.plane
	print("SMOKE ...and the part is turned so that face lies flat on the table: ", (table.pivot.basis * (plane["n"] as Vector3)).is_equal_approx(Vector3.UP))
	print("SMOKE ...the chosen face stays lit, the sheet is shown, the plane squares are put away: ", ed.highlight.pick_nodes().size() == 1 and ed.view != null and not ed.markers.visible)
	print("SMOKE ...and the user is told what the tool does: ", table.status().length() > 0)

	# --- the sheet: a snapped cursor, two pulls draw a rectangle
	var centre_uv: Vector2 = ed.view.sheet_centre
	table.manager.activate("rectangle")
	await aim_uv(centre_uv + Vector2(-10, -10))
	print("SMOKE aiming at the sheet takes the laser and puts the cursor where it points: ", ed.hovering and ed._hover_uv != null and (ed._hover_uv as Vector2).distance_to(centre_uv + Vector2(-10, -10)) < 1.0 and ed.view._cursor.visible)
	await pull()
	await aim_uv(centre_uv + Vector2(12, 8))
	print("SMOKE the first pull only remembers the corner, with a rubber band to the cursor: ", calls_to("/rectangles").is_empty() and ed.session.pending.size() == 1 and ed.view._preview.mesh != null)
	await pull()
	var drew: bool = await settle(func() -> bool: return not calls_to("/rectangles").is_empty() and not ed.session.busy)
	print("SMOKE the second pull draws the rectangle through the backend: ", drew and ed.session.shapes.size() == 1)
	var corners: Array = calls_to("/rectangles")[0][1]["corner_point_ids"].map(func(id): return fake.points[id])
	var want := [centre_uv + Vector2(-10, -10), centre_uv + Vector2(12, -10), centre_uv + Vector2(12, 8), centre_uv + Vector2(-10, 8)]
	var close := true
	for i in 4:
		close = close and (corners[i] as Vector2).distance_to(want[i]) < 1.5
	print("SMOKE ...at the points the laser was aimed at (within 1.5 mm on the sheet): ", close)
	print("SMOKE ...and the drawing is rebuilt from the answer: ", ed.view._geo.mesh != null)

	# --- snapping on and off
	var corner_id: String = calls_to("/rectangles")[0][1]["corner_point_ids"][0]
	await aim_uv(centre_uv + Vector2(-9, -9.5))
	print("SMOKE near an existing corner the cursor snaps onto it and will reuse its point: ", ed._snap["kind"] == "point" and ed._snap["id"] == corner_id)
	table.snap_enabled = false
	await aim_uv(centre_uv + Vector2(-9, -9.5))
	print("SMOKE with Snap off the cursor is free: ", ed._snap["kind"] == "free" and ed._snap["id"] == "")
	table.snap_enabled = true

	# --- the deck keeps the laser when the laser is on the deck
	var count_before: int = fake.calls.size()
	var vp := Vector2(table._viewport.size)
	var snap_button: Button = table.ui.tool_button("line")
	var c := snap_button.global_position + snap_button.size * 0.5
	var deck_xf: Transform3D = table._deck_quad.global_transform
	var deck_point: Vector3 = deck_xf * Vector3((c.x / vp.x - 0.5) * table.tools_size.x, (0.5 - c.y / vp.y) * table.tools_size.y, 0.0)
	await aim(deck_point + deck_xf.basis.z.normalized() * 0.4, deck_point)
	print("SMOKE the laser on the deck belongs to the deck, not the editor: ", table.surface.hovering and not ed.hovering)
	await pull()
	print("SMOKE ...so that trigger pulled the Line tool, and drew nothing: ", table.active_tool == "line" and fake.calls.size() == count_before)

	# --- a constraint tool picks a line under the laser
	table.manager.activate("horizontal")
	var bottom_mid := centre_uv + Vector2(1, -10)
	await aim_uv(bottom_mid)
	print("SMOKE Horizontal finds the line under the laser, and only lines: ", ed._hover_entity.get("kind") == "line")
	await pull()
	var constrained: bool = await settle(func() -> bool: return not calls_to("/constraints").is_empty() and not ed.session.busy)
	print("SMOKE ...and the pull adds a horizontal constraint on it: ", constrained and calls_to("/constraints")[0][1]["type"] == "horizontal")

	# --- Dimension: pick the line, point at its label, type a value
	table.manager.activate("dimension")
	await aim_uv(bottom_mid)
	await pull()
	var ghosted: bool = await settle(func() -> bool: return not ed.session.ghosts.is_empty())
	print("SMOKE Dimension offers the picked line's length, floating on the sheet: ", ghosted and ed.session.ghosts[0]["key"] == "length" and ed.view.label_texts().any(func(t): return t.contains("Length")))
	var ghost: Dictionary = ed.session.ghosts[0]
	await aim_uv(ghost["uv"])
	await pull()
	var pad_open: bool = await settle(func() -> bool: return main._keyboard.is_open())
	print("SMOKE pointing at the label opens the numeric pad, pre-filled with the value: ", pad_open and main._keyboard._text == "%.2f" % float(ghost["value"]))
	main._keyboard.close()
	var dims_before := calls_to("/constraints").size()
	await ed.dimension_typed("length", "25")
	var dimension_call: Array = calls_to("/constraints").back()
	print("SMOKE a typed 25 reaches the backend as a distance of 25: ", calls_to("/constraints").size() == dims_before + 1 and dimension_call[1]["type"] == "distance" and dimension_call[1]["distance"] == 25.0)
	print("SMOKE ...a typed word does not: ", true if (await ed.dimension_typed("length", "abc")) == null and table.status() == "That isn't a number." else false)

	# --- the options row
	table.manager.activate("polygon")
	var opts := ["sides_down", "sides_label", "sides_up"]
	print("SMOKE Polygon shows a sides stepper: ", opts.all(func(o): return table.ui.option_button(o) != null))
	await ed.on_option("sides_up")
	print("SMOKE ...that steps the count: ", ed.session.polygon_sides == 7 and table.ui.option_button("sides_label").text == "7 sides")
	table.manager.activate("line")
	print("SMOKE Line shows Finish line: ", table.ui.option_button("finish_line") != null)
	table.manager.activate("extrude")
	print("SMOKE Extrude shows Boss, Cut, Flip, New body, Depth and Apply: ", ["boss", "cut", "flip", "new_body", "depth", "apply"].all(func(o): return table.ui.option_button(o) != null))
	print("SMOKE ...Apply is available because the sketch has a closed shape: ", not table.ui.option_button("apply").disabled)
	print("SMOKE ...Boss is on by default and the depth is 10 mm: ", table.ui.option_button("boss").button_pressed and table.ui.option_button("depth").text == "Depth 10.00 mm")
	await ed.on_option("cut")
	print("SMOKE choosing Cut turns Boss off and takes New body away: ", not ed.options["boss"] and table.ui.option_button("new_body") == null)
	print("SMOKE ...a cut goes into the part, along minus the face normal: ", ed.extrude_distances() == [0.0, -10.0])
	await ed.on_option("flip")
	print("SMOKE ...Flip reverses it: ", ed.extrude_distances() == [0.0, 10.0])
	await ed.on_option("flip")
	await ed.on_option("boss")
	ed.option_typed("depth", "7.5")
	print("SMOKE a typed depth is kept, and zero or text is refused: ", ed.options["depth"] == 7.5 and (ed.option_typed("depth", "0") == null) and ed.options["depth"] == 7.5)

	# --- applying the extrude
	var gets_before := calls_to("/assembly-mesh.glb").size()
	await ed.apply_feature()
	var extrude_call: Array = calls_to("/extrude-features")[0]
	print("SMOKE Extrude sends the sketch, a boss from the face outward, the depth and the body sketched on: ", extrude_call[1]["sketch_feature_id"] == "feat1" and extrude_call[1]["extrude_type"] == "boss" and extrude_call[1]["start_distance"] == 0.0 and extrude_call[1]["end_distance"] == 7.5 and extrude_call[1]["target_body_ids"] == [picked["body_id"]])
	print("SMOKE ...then fetches the part's new mesh for the right part: ", calls_to("/assembly-mesh.glb").size() == gets_before + 1 and calls_to("/assembly-mesh.glb").back()[0].contains("PART_BOX"))
	print("SMOKE ...and the editor is back to choosing a plane with the sketch spent: ", ed.state == "pick_plane" and ed.session == null and ed.view == null and ed.markers.visible)
	print("SMOKE ...the feature is remembered for Undo: ", ed.feature_stack.size() == 1 and table.ui._undo_button.disabled == false)

	# --- Fillet: pick edges with the laser
	table.manager.activate("fillet")
	print("SMOKE Fillet switches to edge picking: ", ed.state == "pick_edges" and table.ui.option_button("radius") != null)
	var topo: Dictionary = table.table_copy.get_meta("topology")
	var body_id: String = topo.keys()[0]
	var edge_index := -1
	var edge_mid := Vector3.ZERO
	for index in (topo[body_id]["edge_kinds"] as Dictionary):
		if topo[body_id]["edge_kinds"][index] == "line":
			var pts: PackedVector3Array = topo[body_id]["edges"][index]
			edge_index = int(index)
			edge_mid = (pts[0] + pts[pts.size() - 1]) * 0.5
			break
	var edge_world: Vector3 = table.table_copy.global_transform * edge_mid
	var outward: Vector3 = (edge_world - table.pivot.global_position).normalized()
	await aim(edge_world + outward * 0.4, edge_world)
	print("SMOKE aiming at an edge lights the edge, not the face: ", ed.hovering and ed._hover_face.get("kind") == "edge" and ed._hover_face["index"] == edge_index)
	await pull()
	print("SMOKE a pull adds it to the set, and the Apply button counts it: ", ed.edges.size() == 1 and table.ui.option_button("apply").text == "Apply (1)" and ed.highlight.set_nodes().size() == 1)
	await pull()
	print("SMOKE a second pull on the same edge takes it out again: ", ed.edges.is_empty() and ed.highlight.set_nodes().is_empty())
	await pull()
	ed.options["radius"] = 2.0
	await ed.apply_feature()
	var fillet_call: Array = calls_to("/fillet-features")[0]
	print("SMOKE Fillet sends the picked edges as edge refs with the radius: ", fillet_call[1]["edge_refs"] == [{"body_id": body_id, "shape_type": "edge", "index": edge_index}] and fillet_call[1]["radius"] == 2.0)
	print("SMOKE ...and keeps the sketch features list for Undo: ", ed.feature_stack.size() == 2)

	# --- Undo takes the last feature back
	table.ui.undo_pressed.emit()
	var undone: bool = await settle(func() -> bool: return ed.feature_stack.size() == 1)
	print("SMOKE the deck's Undo deletes the last feature on the backend and refreshes the part: ", undone and not calls_to("DELETE /document/parts/PART_BOX/features/").is_empty())

	# --- picking a reference plane beside the part
	table.manager.deactivate()
	var xy := {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var copy_centre: Vector3 = table.table_copy.get_aabb().get_center()
	var beside: Vector3 = copy_centre - (xy["n"] as Vector3) * copy_centre.dot(xy["n"]) + Vector3(80, 0, 0) # on the XY square, past the box's side
	var beside_world: Vector3 = table.table_copy.global_transform * beside
	var plane_normal_world: Vector3 = (table.table_copy.global_transform.basis * Vector3(0, 0, 1)).normalized()
	await aim(beside_world + plane_normal_world * 0.4 + Vector3(0, 0, 0.001), beside_world)
	print("SMOKE aiming at a reference plane past the part's side picks the plane: ", ed.hovering and ed._hover_plane == "XY" and ed.markers.hovered == "XY")
	await pull()
	var on_plane: bool = await settle(func() -> bool: return ed.state == "sketch")
	var sketch_calls := calls_to("/features/sketch")
	print("SMOKE the trigger opens a sketch on the plane BY NAME (no plane feature needed): ", on_plane and sketch_calls.back()[1] == {"plane": "XY"} and ed.chosen_plane == "XY" and ed.markers.chosen == "XY")
	print("SMOKE ...and the part turns to lay that plane flat: ", (table.pivot.basis * Vector3(0, 0, 1)).is_equal_approx(Vector3.UP))

	# --- lifting while editing, and the part closing it all down
	table.close()
	print("SMOKE closing the table ends the session and returns the part: ", ed.state == "idle" and ed.session == null and table.seated == null and box.visible)
	quit()
