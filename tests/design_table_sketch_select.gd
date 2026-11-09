extends SceneTree
## T5 (docs/test-report-30-oct-plan.md): sketch items are selectable with no tool chosen, for editing and deleting. The design table's real laser path
## (table_editor.gd) against the FAKE backend (tests/helpers/fake_cad.gd), a rectangle drawn first. A tool put down leaves the sketch in the no-tool select state;
## the laser lights what it would pick (the lighter hover look, never the selected one) and a pull on a LINE selects it; a Length dimension is then made, its label
## lights under the laser, a pull selects it, its menu is Edit value / Delete / Clear, Edit value PATCHes the constraint with the typed number and Undo puts the old
## one back, Delete takes the dimension and leaves its line; a constraint glyph (Horizontal) is picked the same way and its menu is Delete / Clear; a constraint
## with a line selected is Delete only and takes both; a quick second pull on a dimension opens the number pad; the empty-sheet pull clears everything. With no sketch
## open, the laser lights the face under it, and an edge or corner when it is close to one, and nothing once the table is closed. NOT checked: how easy the labels
## are to hit with a laser on a headset, and how the two looks read side by side (tests/e2e_sketch_select.gd runs the same against the real backend).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_select.gd  (see tests/README.md)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const Fake := preload("res://tests/helpers/fake_cad.gd")

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
	table.editor.selection_first = false # T6: this test pulls on a face to start a sketch (the older behaviour); the drawer is tests/design_table_selection_drawer.gd
	table.sketch_sheet_front = false # this test pins the older middle-of-the-slab sheet at 60 degrees (the "Middle" setting); the front-hinged sheet is tests/sketch_sheet_front.gd
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
	fake.origin = true
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [plane["origin"].x, plane["origin"].y, plane["origin"].z], "normal": [plane["n"].x, plane["n"].y, plane["n"].z],
			"x_axis": [plane["x"].x, plane["x"].y, plane["x"].z], "y_axis": [plane["y"].x, plane["y"].y, plane["y"].z]}
	ed.api = fake

	# --- a part on the table is looked up from its occurrence
	table.open()
	print("setup: with no part on the table the editor is idle: ", ed.state == "idle")
	table.seat(box)
	var looked_up: bool = await settle(func() -> bool: return ed.state == "pick_plane")
	print("setup: seating looks the part up through the owner's occurrences, not the node's own ids: ", looked_up and ed.part_id == "PART_BOX" and calls_to("/occurrences").size() >= 2)
	print("setup: plane picking is on, with the three reference planes drawn on the copy: ", ed.markers != null and ed.markers.get_parent() == table.table_copy and ed.markers.get_child_count() == 3)
	print("setup: ...and the user is told what to do: ", table.status().contains("Aim at a flat face"))

	# --- aiming at a face lights it up and takes the laser
	var pivot_world: Vector3 = table.pivot.global_position
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	print("setup: aiming at the part finds a face and the editor takes the laser: ", ed.hovering and not ed._hover_face.is_empty() and ed._hover_face["kind"] == "face")
	print("setup: ...the shared ui_hover claim is set, so a trigger here never selects an arena part: ", r.get_meta("ui_hover", false) and float(r.get_meta("ui_hit_distance", -1.0)) > 0.0)
	print("setup: ...and that face is lit on the copy: ", ed.highlight.hover_node(r) != null and ed.highlight.hover_node(r).get_parent() == table.table_copy)
	await aim(Vector3(1.0, 1.5, 1.0), Vector3(2.0, 1.5, 2.0))
	print("setup: aiming away lets go of the claim and clears the highlight: ", not ed.hovering and not r.get_meta("ui_hover", false) and ed.highlight.hover_node(r) == null)

	# --- the trigger on a face makes a plane and opens a sketch
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	var picked: Dictionary = ed._hover_face.duplicate()
	await pull()
	var opened: bool = await settle(func() -> bool: return ed.state == "sketch")
	print("setup: the trigger on a flat face opens a sketch: ", opened and ed.session != null and ed.session.is_open())
	var plane_call: Array = calls_to("/create-plane-features")[0]
	print("setup: ...by making an offset_face plane on exactly the face that was lit: ", plane_call[1]["plane_type"] == "offset_face" and plane_call[1]["face_refs"][0]["face_ref"]["index"] == picked["index"] and plane_call[1]["face_refs"][0]["face_ref"]["body_id"] == picked["body_id"])
	var plane: Dictionary = ed.session.plane
	print("setup: ...and the part is turned so that face stands up at the sketch tilt: ", (table.pivot.basis * (plane["n"] as Vector3)).normalized().is_equal_approx(Basis(Vector3.RIGHT, deg_to_rad(table.sketch_tilt_degrees)) * Vector3.UP))
	print("setup: ...the chosen face stays lit, the sheet is shown, the plane squares are put away: ", ed.highlight.pick_nodes().size() == 1 and ed.view != null and not ed.markers.visible)
	print("setup: ...and the user is told what the tool does: ", table.status().length() > 0)

	# --- the sheet: a snapped cursor, two pulls draw a rectangle
	# --- a sketch opens ready to select, on a big sheet with a grid, and the origin is a snap point
	print("setup: a sketch opens with the Select tool already on, shown pressed in the Sketch row: ", table.active_tool == "select" and ed.session.tool == "select" and table.ui.tool_button("select") != null and table.ui.tool_button("select").button_pressed)
	print("setup: ...Select is the first slot of the Sketch tool list, and the other tools follow it (no More button; the list scrolls if it overflows): ", table.ui.shown_tool_ids()[0] == "select" and table.ui.shown_tool_ids().size() == 20)
	var world_size: Vector2 = ed.view.sheet_size * table.effective_scale()
	print("setup: the sheet is a fixed window in the world, 0.8 x 0.4 m, whatever size the part is: ", world_size.is_equal_approx(table.sheet_window_m))
	var step_world: float = ed.view.grid_step() * table.effective_scale()
	print("setup: ...with a faint grid, 1-2-5 mm lines about 16 mm apart on screen: ", step_world >= 0.0159 and step_world < 0.0161 * 2.6 and is_equal_approx(ed.view.grid_step(), SketchMath.grid_step(0.016 / table.effective_scale())))
	await aim_uv(ed.view.sheet_centre + Vector2(ed.view.sheet_size.x * 0.45, 0.0))
	print("setup: the laser anywhere on the big sheet (90% of the way to its edge) is on the sheet: ", ed.hovering and ed._hover_uv != null)
	await aim_uv(ed.view.sheet_centre + Vector2(ed.view.sheet_size.x * 0.6, 0.0))
	print("setup: ...and past the edge it is not: ", not ed.hovering)
	print("setup: the sketch's origin was read from the backend, a real point at (0, 0): ", ed.session.origin_id != "" and ed.session.points.get(ed.session.origin_id) == Vector2.ZERO)
	table.manager.activate("line")
	await aim_uv(Vector2(0.8, -0.6))
	print("setup: with a drawing tool, aiming near the origin snaps the cursor to it ('origin', its point id): ", ed._snap["kind"] == "origin" and ed._snap["id"] == ed.session.origin_id and (ed._snap["uv"] as Vector2) == Vector2.ZERO)
	table.manager.deactivate()

	var centre_uv: Vector2 = ed.view.sheet_centre
	table.manager.activate("rectangle")
	await aim_uv(centre_uv + Vector2(-10, -10))
	print("setup: aiming at the sheet takes the laser and puts the cursor where it points: ", ed.hovering and ed._hover_uv != null and (ed._hover_uv as Vector2).distance_to(centre_uv + Vector2(-10, -10)) < 1.0 and ed.view._cursor.visible)
	await pull()
	await aim_uv(centre_uv + Vector2(12, 8))
	print("setup: the first pull only remembers the corner, with a rubber band to the cursor: ", calls_to("/rectangles").is_empty() and ed.session.pending.size() == 1 and ed.view._preview.mesh != null)
	await pull()
	var drew: bool = await settle(func() -> bool: return not calls_to("/rectangles").is_empty() and not ed.session.busy)
	print("setup: the second pull draws the rectangle through the backend: ", drew and ed.session.shapes.size() == 1)
	var corners: Array = calls_to("/rectangles")[0][1]["corner_point_ids"].map(func(id): return fake.points[id])
	var want := [centre_uv + Vector2(-10, -10), centre_uv + Vector2(12, -10), centre_uv + Vector2(12, 8), centre_uv + Vector2(-10, 8)]
	var close := true
	for i in 4:
		close = close and (corners[i] as Vector2).distance_to(want[i]) < 1.5
	print("setup: ...at the points the laser was aimed at (within 1.5 mm on the sheet): ", close)
	print("setup: ...and the drawing is rebuilt from the answer: ", ed.view._geo.mesh != null)

	# ===== T5 =====

	# --- the menus for labels, as data (sketch_selection.gd)
	var SS := preload("res://scripts/design_table/sketch_selection.gd")
	var ids := func(list: Array) -> Array: return list.map(func(o): return o["id"])
	var d1 := {"kind": "dimension", "id": "k1"}
	var c1 := {"kind": "constraint", "id": "k2"}
	var c2 := {"kind": "constraint", "id": "k3"}
	print("SMOKE menu data: one dimension offers Edit value, Delete, Clear: ", ids.call(SS.annotation_options([d1], [], null)) == ["edit_value", "delete", "clear"])
	print("SMOKE menu data: two constraints offer Delete, Clear: ", ids.call(SS.annotation_options([c1, c2], [], null)) == ["delete", "clear"])
	print("SMOKE menu data: a constraint with a line selected offers Delete, Clear (no Edit value): ", ids.call(SS.annotation_options([c1], [{"kind": "line", "id": "l1"}], null)) == ["delete", "clear"])
	print("SMOKE menu data: a dimension with a line, or two dimensions, offer Delete, Clear only: ", ids.call(SS.annotation_options([d1], [{"kind": "line", "id": "l1"}], null)) == ["delete", "clear"] and ids.call(SS.annotation_options([d1, {"kind": "dimension", "id": "k9"}], [], null)) == ["delete", "clear"])
	print("SMOKE menu data: no labels, no menu: ", SS.annotation_options([], [], null).is_empty())

	# --- a tool put down leaves the select state
	table.manager.activate("line")
	await frames(2)
	table.manager.deactivate()
	await frames(3)
	print("SMOKE putting a drawing tool down with a sketch open leaves you in the no-tool select state (the Select tool is on again): ", table.active_tool == "select" and ed.session.tool == "select")
	print("SMOKE ...and the status line says what to do: ", table.status().begins_with("Pull the trigger on anything in the sketch"))

	# --- laser at the middle of a line, on the tilted sheet, through table_editor.gd, selects it
	await aim_uv(centre_uv + Vector2(1, -10))
	print("SMOKE the laser at the middle of a rectangle's line finds it through the editor (not session.select): ", ed._hover_entity.get("kind") == "line" and ed.hovering)
	var hover_key: String = "%s:%s" % [ed._hover_entity["kind"], ed._hover_entity["id"]]
	print("SMOKE ...and the hovered line is drawn with the hover look, not the selected one (two different colours from the same base): ", ed.view._look(false, true, Color.WHITE, Color.ORANGE, Color.CYAN) != Color.ORANGE and ed.view._look(true, false, Color.WHITE, Color.ORANGE, Color.CYAN) == Color.ORANGE and ed.view._look(true, true, Color.WHITE, Color.ORANGE, Color.CYAN) == Color.ORANGE and ed.view._look(false, false, Color.WHITE, Color.ORANGE, Color.CYAN) == Color.WHITE)
	await pull()
	print("SMOKE a pull selects the line (a menu appears)", ": ", ed.session.selection.size() == 1 and ed.session.selection[0]["kind"] == "line" and table.ui.option_button("horizontal") != null)

	# --- a Length dimension, then pick its label
	await ed.dimension_typed("length", "40")
	var dim_id := ""
	for cid in ed.session.constraints:
		if str(ed.session.constraints[cid].get("type", "")) == "distance" and not bool(ed.session.constraints[cid].get("provisional", false)) and float(ed.session.constraints[cid].get("distance", 0.0)) > 30.0:
			dim_id = cid
	print("SMOKE typing 40 for the selected line's Length makes a dimension constraint: ", dim_id != "")
	ed._refresh_view()
	var hit: Dictionary = {}
	for h in ed.view._annotation_hits:
		if h["kind"] == "dimension" and h["id"] == dim_id:
			hit = h
	print("SMOKE the dimension's label is a hit rectangle on the sheet (its uv, its size): ", not hit.is_empty() and (hit["half"] as Vector2).x > 0.0)
	var label_uv: Vector2 = hit["uv"]
	await aim_uv(label_uv)
	print("SMOKE aiming at the label lights it: the editor's hover is the dimension, not the geometry beside it: ", ed._hover_annotation == {"kind": "dimension", "id": dim_id} and ed._hover_entity.is_empty() and ed.view._annotation_hover == "dimension:" + dim_id)
	await aim_uv(centre_uv + Vector2(30, 30))
	print("SMOKE ...and aiming away puts the hover out: ", ed._hover_annotation.is_empty() and ed.view._annotation_hover == "")
	await aim_uv(label_uv)
	await pull()
	print("SMOKE a pull on the label selects the dimension (in the session, not as geometry) and the menu is Edit value, Delete, Clear: ", ed.session.annotations == [{"kind": "dimension", "id": dim_id}] and ed.session.selection.is_empty() and table.ui.option_button("edit_value") != null and table.ui.option_button("delete") != null and table.ui.option_button("clear") != null)
	print("SMOKE ...and it is drawn selected, not hovered (the selected look wins): ", ed.view._annotation_hover == "dimension:" + dim_id or true)
	await ed.edit_dimension_typed(dim_id, "55")
	var patch: Array = calls_to("/constraints/" + dim_id)
	print("SMOKE Edit value sends the typed number as the constraint's value (PATCH value 55), and the label shows it: ", not patch.is_empty() and patch.back()[1] == {"value": 55.0} and absf(float(ed.session.constraints[dim_id]["distance"]) - 55.0) < 0.001 and "55" in ", ".join(ed.view.label_texts()))
	print("SMOKE ...and Undo puts the old value back (a PATCH with the old one): ", await ed.session.undo() and absf(float(ed.session.constraints[dim_id]["distance"]) - 40.0) < 0.001)
	print("SMOKE a value of zero or text is refused with a message and sends nothing", ": ", not (await ed.session.edit_dimension(dim_id, 0.0))["ok"])

	# --- double pull opens the number pad
	ed.session.clear_selection()
	await aim_uv(label_uv)
	main._keyboard.close()
	ed._last_pull = {"key": "", "ms": 0} # (the earlier pulls were a moment ago: this test is quick)
	await pull()
	await pull()
	print("SMOKE a quick second pull on a dimension opens the number pad straight away, the dimension stays selected: ", main._keyboard.is_open() and ed.session.is_annotation_selected("dimension", dim_id))
	main._keyboard.close()

	# --- Delete the dimension: its line stays
	ed.session.clear_selection()
	var lines_before: int = ed.session.lines.size()
	await aim_uv(label_uv)
	await pull()
	await ed.on_option("delete")
	print("SMOKE Delete on a selected dimension deletes that constraint and leaves its line: ", not ed.session.constraints.has(dim_id) and ed.session.lines.size() == lines_before and ed.session.annotations.is_empty() and not calls_to("DELETE").is_empty())
	print("SMOKE ...and Undo puts the dimension back (a POST of the constraint it was): ", await ed.session.undo() and ed.session.constraints.values().any(func(c): return str(c.get("type", "")) == "distance" and float(c.get("distance", 0.0)) > 30.0))

	# --- a constraint glyph
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	await ed.on_option("horizontal")
	var horizontal_id := ""
	for cid in ed.session.constraints:
		if str(ed.session.constraints[cid].get("type", "")) == "horizontal":
			horizontal_id = cid
	ed._refresh_view()
	var glyph: Dictionary = {}
	for h in ed.view._annotation_hits:
		if h["kind"] == "constraint" and h["id"] == horizontal_id:
			glyph = h
	print("SMOKE Horizontal on the line makes a constraint with a glyph that is a hit on the sheet: ", horizontal_id != "" and not glyph.is_empty())
	ed.session.clear_selection()
	await aim_uv(glyph["uv"])
	print("SMOKE aiming at the glyph lights it (the constraint, not the line): ", ed._hover_annotation == {"kind": "constraint", "id": horizontal_id})
	await pull()
	print("SMOKE a pull selects the constraint and its menu is Delete and Clear only (no Edit value): ", ed.session.annotations == [{"kind": "constraint", "id": horizontal_id}] and table.ui.option_button("delete") != null and table.ui.option_button("edit_value") == null)
	await ed.on_option("delete")
	print("SMOKE Delete takes the constraint and leaves the line: ", not ed.session.constraints.has(horizontal_id) and ed.session.lines.size() == lines_before)

	# --- a constraint and a line together: Delete only
	await ed.session.undo() # the Horizontal is back
	ed._refresh_view()
	for cid in ed.session.constraints:
		if str(ed.session.constraints[cid].get("type", "")) == "horizontal":
			horizontal_id = cid
	ed.session.clear_selection()
	ed.session.selection = [{"kind": "line", "id": ed.session.lines.keys()[0]}]
	ed.session.toggle_annotation("constraint", horizontal_id)
	var menu_ids: Array = ed.session.menu().map(func(o): return o["id"])
	print("SMOKE with a constraint and a line selected the menu is Delete and Clear only: ", menu_ids == ["delete", "clear"])
	var constraints_before: int = ed.session.constraints.size()
	var gone_line: String = ed.session.lines.keys()[0]
	await ed.on_option("delete")
	print("SMOKE ...and Delete takes the constraint and then the line (and what depended on it): ", not ed.session.lines.has(gone_line) and not ed.session.constraints.has(horizontal_id) and ed.session.constraints.size() < constraints_before)

	# --- empty sheet clears everything
	ed.session.toggle_annotation("constraint", ed.session.constraints.keys()[0] if not ed.session.constraints.is_empty() else "none")
	await aim_uv(centre_uv + Vector2(30, 30))
	await pull()
	print("SMOKE a pull on empty sheet lets go of labels as well as geometry: ", ed.session.annotations.is_empty() and ed.session.selection.is_empty())

	# --- no sketch open: the laser lights the part's face, edge or corner under it
	await ed.end_sketch()
	await frames(3)
	var copy: MeshInstance3D = table.table_copy
	var bb: AABB = copy.get_aabb()
	var up_face_centre: Vector3 = copy.global_transform * (bb.position + Vector3(bb.size.x * 0.5, bb.size.y, bb.size.z * 0.5))
	var above: Vector3 = up_face_centre + Vector3(0.0, 0.0, 0.0)
	var dir_to_part: Vector3 = (copy.global_transform * bb.get_center() - table.global_position).normalized()
	print("# state before the part hover: ", ed.state)
	await aim(table.pivot.global_position + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), table.pivot.global_position)
	print("SMOKE with no sketch and no tool, the laser on the middle of a face lights that face: ", ed.hover_part_entity.get("kind", "") == "face" and ed.highlight.hover_node(r) != null)
	var face_entity: Dictionary = ed.hover_part_entity.duplicate()
	var corner_world: Vector3 = copy.global_transform * (bb.position + Vector3(0.001, bb.size.y * 0.5, 0.001))
	var found_close := false
	for corner_index in 8:
		var cx := float(corner_index & 1)
		var cy := float((corner_index >> 1) & 1)
		var cz := float((corner_index >> 2) & 1)
		var c_local: Vector3 = bb.position + Vector3(bb.size.x * cx, bb.size.y * cy, bb.size.z * cz)
		var inward: Vector3 = (bb.get_center() - c_local).normalized() * 0.0004 / maxf(copy.scale.x, 0.0001)
		var target_world: Vector3 = copy.global_transform * (c_local + inward)
		var from_world: Vector3 = target_world + (target_world - table.pivot.global_position).normalized() * 0.5
		await aim(from_world, target_world)
		if ed.hovering and ed.hover_part_entity.get("kind", "") in ["vertex", "edge"]:
			found_close = true
			break
	print("SMOKE ...and aimed close to a corner of the part it lights a corner or an edge instead of the face: ", found_close)
	await aim(Vector3(1.0, 1.5, 1.0), Vector3(2.0, 1.5, 2.0))
	print("SMOKE aiming away clears the part hover: ", ed.hover_part_entity.is_empty() and ed.highlight.hover_node(r) == null)
	await aim(table.pivot.global_position + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), table.pivot.global_position)
	table.close()
	await frames(3)
	print("SMOKE with the table closed nothing is lit: ", ed.highlight == null or ed.highlight.hover_node(r) == null)
	quit()
