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
	fake.origin = true
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
	print("SMOKE ...and the part is turned so that face stands up at the sketch tilt: ", (table.pivot.basis * (plane["n"] as Vector3)).normalized().is_equal_approx(Basis(Vector3.RIGHT, deg_to_rad(table.sketch_tilt_degrees)) * Vector3.UP))
	print("SMOKE ...the chosen face stays lit, the sheet is shown, the plane squares are put away: ", ed.highlight.pick_nodes().size() == 1 and ed.view != null and not ed.markers.visible)
	print("SMOKE ...and the user is told what the tool does: ", table.status().length() > 0)

	# --- the sheet: a snapped cursor, two pulls draw a rectangle
	# --- a sketch opens ready to select, on a big sheet with a grid, and the origin is a snap point
	print("SMOKE a sketch opens with the Select tool already on, shown pressed in the Sketch row: ", table.active_tool == "select" and ed.session.tool == "select" and table.ui.tool_button("select") != null and table.ui.tool_button("select").button_pressed)
	print("SMOKE ...Select is the first slot of the Sketch tool list, and the other tools follow it (no More button; the list scrolls if it overflows): ", table.ui.shown_tool_ids()[0] == "select" and table.ui.shown_tool_ids().size() == 20)
	var world_size: Vector2 = ed.view.sheet_size * table.effective_scale()
	print("SMOKE the sheet is a fixed window in the world, 0.8 x 0.4 m, whatever size the part is: ", world_size.is_equal_approx(table.sheet_window_m))
	var step_world: float = ed.view.grid_step() * table.effective_scale()
	print("SMOKE ...with a faint grid, 1-2-5 mm lines about 16 mm apart on screen: ", step_world >= 0.0159 and step_world < 0.0161 * 2.6 and is_equal_approx(ed.view.grid_step(), SketchMath.grid_step(0.016 / table.effective_scale())))
	await aim_uv(ed.view.sheet_centre + Vector2(ed.view.sheet_size.x * 0.45, 0.0))
	print("SMOKE the laser anywhere on the big sheet (90% of the way to its edge) is on the sheet: ", ed.hovering and ed._hover_uv != null)
	await aim_uv(ed.view.sheet_centre + Vector2(ed.view.sheet_size.x * 0.6, 0.0))
	print("SMOKE ...and past the edge it is not: ", not ed.hovering)
	print("SMOKE the sketch's origin was read from the backend, a real point at (0, 0): ", ed.session.origin_id != "" and ed.session.points.get(ed.session.origin_id) == Vector2.ZERO)
	table.manager.activate("line")
	await aim_uv(Vector2(0.8, -0.6))
	print("SMOKE with a drawing tool, aiming near the origin snaps the cursor to it ('origin', its point id): ", ed._snap["kind"] == "origin" and ed._snap["id"] == ed.session.origin_id and (ed._snap["uv"] as Vector2) == Vector2.ZERO)
	table.manager.deactivate()

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

	# --- Infer: the switch beside Snap
	print("SMOKE the deck has an Infer switch beside Snap, on by default: ", table.ui.infer_button() != null and table.ui.infer_on() and table.infer_enabled and table.ui.infer_button().text == "Infer")
	table.manager.activate("line")
	await aim_uv(centre_uv + Vector2(-40, 25))
	await pull()
	await aim_uv(centre_uv + Vector2(30, 26.5))
	print("SMOKE with Infer on, a second end near horizontal is pulled onto the axis and carries horizontal: ", ed._snap["infer"].get("kind", "") == "horizontal")
	table.ui.infer_button().button_pressed = false # (the switch pressed: it emits infer_toggled)
	await frames(2)
	print("SMOKE switching Infer off reaches the table, and the status line says nothing is added by itself: ", not table.infer_enabled and table.status().contains("Infer off: nothing is added automatically"))
	await aim_uv(centre_uv + Vector2(31, 26.5))
	print("SMOKE ...and the same aim is then a plain free position: no axis snap, nothing inferred: ", ed._snap["infer"].is_empty() and (ed._snap["uv"] as Vector2).distance_to(centre_uv + Vector2(31, 26.5)) < 0.5)
	table.manager.activate("rectangle")
	await frames(2)
	table.manager.activate("line")
	await frames(2)
	print("SMOKE ...it stays off across tools (a switch, not a hold): ", not table.infer_enabled and not table.ui.infer_on())
	table.ui.infer_button().button_pressed = true
	await frames(2)
	print("SMOKE ...and on again when switched back: ", table.infer_enabled and not table.status().contains("Infer off"))
	table.manager.deactivate()
	ed.session.finish_chain()

	# --- alignment guides on the sheet
	table.manager.activate("point")
	var align_radius: float = ed.SNAP_RADIUS / ed.view.canvas_scale
	await aim_uv(centre_uv + Vector2(-10 + align_radius * 0.3, 40))
	var guided: Array = ed._snap.get("guides", [])
	print("SMOKE a Point tool aimed a little off the x of a corner is pulled to it, and a dashed guide is drawn on the sheet: ", guided.size() == 1 and absf((ed._snap["uv"] as Vector2).x - (centre_uv.x - 10)) < 0.001 and ed.view._aids.mesh != null)
	table.ui.infer_button().button_pressed = false
	await frames(2)
	await aim_uv(centre_uv + Vector2(-10 + align_radius * 0.3, 40))
	print("SMOKE ...Infer off: no guide, no pull: ", ed._snap.get("guides", []).is_empty() and ed.view._aids.mesh == null)
	table.ui.infer_button().button_pressed = true
	await frames(2)
	table.manager.deactivate()
	await frames(2)
	print("SMOKE ...and the guide goes when the tool does: ", ed.view._aids.mesh == null)

	# --- Select: pick things with the laser, a menu of what applies, and the grips with a sketch open
	table.manager.activate("select")
	await aim_uv(centre_uv + Vector2(1, -10))
	print("SMOKE with Select the laser finds the line under it: ", ed._hover_entity.get("kind") == "line")
	await pull()
	print("SMOKE ...the pull selects it and the menu appears in the options row (Length, Horizontal, Vertical, Fix, Construction): ", ed.session.selection.size() == 1 and ["dim:length", "horizontal", "vertical", "fix", "construction"].all(func(o): return table.ui.option_button(o) != null))
	print("SMOKE ...the menu is longer than the row, so it shows five and More: ", table.ui.option_button("menu_more") != null and table.ui.option_button("delete") == null)
	await ed.on_option("menu_more")
	print("SMOKE ...More turns to the rest (Delete, Clear): ", table.ui.option_button("delete") != null and table.ui.option_button("clear") != null)
	await aim_uv(centre_uv + Vector2(30, 30))
	await pull()
	print("SMOKE a pull on empty sheet lets go of the selection, and the menu goes: ", ed.session.selection.is_empty() and table.ui.option_button("horizontal") == null)
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	print("SMOKE ...selecting again starts the menu on its first page: ", table.ui.option_button("horizontal") != null and table.ui.option_button("delete") == null)
	await ed.on_option("construction")
	var patched: Array = calls_to("PATCH /sketch/sketches/sk1/lines/")
	print("SMOKE Construction makes the selected line construction geometry through the backend: ", patched.size() == 1 and patched[0][1] == {"construction": true} and ed.session.selection.is_empty())
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	print("SMOKE ...and the menu then offers Solid for it: ", table.ui.option_button("construction") != null and table.ui.option_button("construction").text == "Solid")
	await ed.on_option("construction")
	print("SMOKE ...which puts it back: ", calls_to("PATCH /sketch/sketches/sk1/lines/").size() == 2 and calls_to("PATCH /sketch/sketches/sk1/lines/")[1][1] == {"construction": false})
	await aim_uv(centre_uv + Vector2(-10, -10))
	print("SMOKE a corner point under the laser wins over the lines that meet there: ", ed._hover_entity.get("kind") == "point")
	await pull()
	print("SMOKE ...selected, it offers Fix (a point alone); a pull on empty sheet clears the selection: ", ed.session.selection.size() == 1 and table.ui.option_button("fix") != null)
	await aim_uv(centre_uv + Vector2(30, 30))
	await pull()
	print("SMOKE ...and the empty pull clears it: ", ed.session.selection.is_empty() and table.ui.option_button("fix") == null)

	var plane_g: Dictionary = ed.session.plane
	var rot_locked: Basis = table.sketch_rotation(plane_g)
	table.apply_pose(Vector3(0.0, table.sketch_hover_height, 0.0), rot_locked, 1.0)
	table.window_anchor = Vector3(0.0, table.sketch_hover_height, 0.0)
	table.pin_sketch_plane()
	var far_world: Vector3 = table.table_copy.global_transform * SketchMath.from_sheet(ed.view.sheet_centre + Vector2(ed.view.sheet_size.x * 0.4, 0.0), plane_g)
	print("SMOKE the far side of the big sheet is well away from the part's own bounding sphere: ", far_world.distance_to(table.pivot.global_position) > table.part_radius() + table.lift_reach)
	l.global_position = far_world
	await physics_frame
	l.button_pressed.emit("grip_click")
	print("SMOKE a grip anywhere on the sheet takes hold (with a sketch open the sheet is the thing to grab): ", table.manip.is_gripping())
	l.button_released.emit("grip_click")
	await process_frame
	print("SMOKE ...and letting go leaves the sketch open: ", ed.session != null and table.seated != null)

	# --- the part (and its sketch) pans and zooms UNDER a sketch window that stays where it is in the world
	await frames(3)
	var anchor_world: Vector3 = table.to_global(table.window_anchor)
	print("SMOKE the sketch window sits on the sketch plane at the anchor, and the sheet is drawn there: ", absf(table.window_anchor_normal.dot(table.pivot.position + table.pivot.basis * (table.table_copy.transform * (plane_g["origin"] as Vector3)) - table.window_anchor)) < 0.001 and ed.view._sheet.global_position.distance_to(anchor_world) < 0.002)
	var c1: Vector3 = table.pivot.position
	var centre_start: Vector2 = ed.view.sheet_centre
	l.global_position = table.to_global(c1)
	await physics_frame
	l.button_pressed.emit("grip_click")
	await process_frame
	var spot: Vector2 = ed.plane_uv_at(l.global_position) # the sketch spot under the hand when it took hold
	l.global_position = table.to_global(c1 + Vector3(0.12, 0.05, 0.0)) # across, and a little off the plane
	await frames(20)
	print("SMOKE one hand on the sheet (Orbit lock) slides the PART under the window: the sketch spot that was under the hand stays under it: ", ed.plane_uv_at(l.global_position).distance_to(spot) < 0.15 * 0.3 / table.effective_scale() * 0.01 + 0.5 and ed.view.sheet_centre.distance_to(centre_start) > 1.0)
	print("SMOKE ...in the plane only (the off-plane part of the hand's movement is not followed), with no turn and no scale: ", absf(table.window_anchor_normal.dot(table.pivot.position + table.pivot.basis * (table.table_copy.transform * (plane_g["origin"] as Vector3)) - table.window_anchor)) < 0.002 and table.pivot.basis.orthonormalized().is_equal_approx(rot_locked) and is_equal_approx(table.user_scale, 1.0))
	print("SMOKE ...the window itself did not move: the sheet is still where it was in the world, now over a different spot of the sketch: ", ed.view._sheet.global_position.distance_to(anchor_world) < 0.002)
	l.button_released.emit("grip_click")
	await process_frame

	var c2: Vector3 = table.pivot.position
	l.global_position = table.to_global(c2 + Vector3(-0.10, 0.0, 0.0))
	r.global_position = table.to_global(c2 + Vector3(0.10, 0.0, 0.0))
	await physics_frame
	l.button_pressed.emit("grip_click")
	r.button_pressed.emit("grip_click")
	await frames(3)
	print("SMOKE two hands on the sheet with a sketch open (Orbit lock): ", table.manip.grip_count() == 2 and table.sketch_locked())
	r.global_position = table.to_global(c2 + Vector3(0.10, 0.0, -0.20)) # swing the line between the hands
	await frames(20)
	print("SMOKE swinging the hands turns nothing: the part keeps its tilt: ", table.pivot.basis.orthonormalized().is_equal_approx(rot_locked))
	r.global_position = table.to_global(c2 + Vector3(0.10, 0.0, 0.0))
	await frames(20)
	var scale_before: float = table.user_scale
	var mid_spot: Vector2 = ed.plane_uv_at((l.global_position + r.global_position) * 0.5)
	r.global_position = table.to_global(c2 + Vector3(0.10, 0.0, 0.0) + Vector3(0.2, 0.0, 0.0)) # twice the spread
	await frames(20)
	print("SMOKE spreading the hands zooms the PART about the spot between them, here 2x: ", absf(table.user_scale / scale_before - 2.0) < 0.05)
	print("SMOKE ...the sketch zooms with it, so the part's edges and the sketch still line up (the sketch is the part's child), and the window stays 0.8 x 0.4 m of world: ", (ed.view.sheet_size * table.effective_scale()).is_equal_approx(table.sheet_window_m) and is_equal_approx(ed.view.canvas_scale, table.effective_scale()))
	print("SMOKE ...still in the plane, still not turned, and the window did not move: ", absf(table.window_anchor_normal.dot(table.pivot.position + table.pivot.basis * (table.table_copy.transform * (plane_g["origin"] as Vector3)) - table.window_anchor)) < 0.002 and table.pivot.basis.orthonormalized().is_equal_approx(rot_locked.orthonormalized()) and ed.view._sheet.global_position.distance_to(anchor_world) < 0.002)
	print("SMOKE ...the grid is re-spaced for the new zoom and the drawing is rebuilt at it (line widths are world sizes): ", is_equal_approx(ed.view.grid_step(), SketchMath.grid_step(0.016 / table.effective_scale())) and await settle(func() -> bool: return not ed._canvas_stale))
	var clip_half: Vector2 = (ed.view._line_material as ShaderMaterial).get_shader_parameter("clip_half")
	var clip_centre: Vector2 = (ed.view._line_material as ShaderMaterial).get_shader_parameter("clip_centre")
	print("SMOKE ...and the drawing is clipped to the window (the line shader's rectangle is the window in sketch mm): ", clip_half.is_equal_approx(ed.view.sheet_size * 0.5) and clip_centre.is_equal_approx(ed.view.sheet_centre))
	r.button_released.emit("grip_click")
	l.button_released.emit("grip_click")
	await process_frame
	table.manip.drive_input(Vector2.ZERO, true, false, 0.5) # A pulls the part towards the hand
	print("SMOKE A / B cannot pull a locked sketch off its plane: ", absf(table.window_anchor_normal.dot(table.pivot.position + table.pivot.basis * (table.table_copy.transform * (plane_g["origin"] as Vector3)) - table.window_anchor)) < 0.002)

	# --- Fit slides and zooms the part so the sketch fills the window
	table.ui.fit_button().pressed.emit()
	await frames(60)
	var bounds: Rect2 = ed.sketch_bounds()
	var fit_scale_w: float = minf(table.sheet_window_m.x * 0.8 / bounds.size.x, table.sheet_window_m.y * 0.8 / bounds.size.y)
	print("SMOKE Fit zooms the part so the sketch fills most of the window, and slides it so the sketch is in the middle: ", absf(table.effective_scale() / fit_scale_w - 1.0) < 0.03 and ed.view.sheet_centre.distance_to(bounds.get_center()) < 1.0 and table.pivot.basis.orthonormalized().is_equal_approx(rot_locked))

	# --- Orbit lock Off hands the grips to the part again
	table.ui.lock_button().button_pressed = false
	print("SMOKE Orbit lock Off unlocks it: ", not table.part_locked and not table.sketch_locked() and table.ui.lock_button().text == "Orbit lock: Off")
	var c3: Vector3 = table.pivot.position
	l.global_position = table.to_global(c3)
	await physics_frame
	l.button_pressed.emit("grip_click")
	await process_frame
	l.global_position = table.to_global(c3 + Vector3(0.10, 0.2, 0.0))
	await frames(20)
	print("SMOKE ...then one hand moves the part anywhere, off the plane too: ", table.pivot.position.distance_to(c3) > 0.05 and absf(table.window_anchor_normal.dot(table.pivot.position + table.pivot.basis * (table.table_copy.transform * (plane_g["origin"] as Vector3)) - table.window_anchor)) > 0.01)
	table.pivot.position = Vector3(1.5, 0.3, 0.0) # carried far past the slab
	l.button_released.emit("grip_click")
	await process_frame
	print("SMOKE letting go far beyond the slab does NOT send the real part away while a sketch is open; it is held back over the slab: ", table.seated != null and ed.session != null and absf(table.pivot.position.x) <= table.slab_size.x * 0.5 + 0.001)
	var basis_now: Basis = table.pivot.basis.orthonormalized()
	r.global_position = Vector3(5.0, 5.0, 5.0) # the laser off the sheet, so the stick is the table's
	await frames(2)
	table.manip.drive_input(Vector2(1.0, 0.0), false, false, 1.0)
	print("SMOKE ...and the stick turns it again: ", not table.pivot.basis.orthonormalized().is_equal_approx(basis_now))
	table.ui.lock_button().button_pressed = true
	table.reset_pose()
	await frames(60)
	print("SMOKE Reset puts the sketch tilt back and the window back on the plane at the part's middle: ", table.pivot.basis.orthonormalized().is_equal_approx(rot_locked) and is_equal_approx(table.user_scale, 1.0) and absf(table.window_anchor_normal.dot(table.pivot.position + table.pivot.basis * (table.table_copy.transform * (plane_g["origin"] as Vector3)) - table.window_anchor)) < 0.002)
	table.manager.deactivate()

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
	print("SMOKE Dimension offers the picked line's length, floating on the sheet: ", ghosted and ed.session.ghosts[0]["key"] == "length" and ed.view.label_texts().has(ed.session.format_value(float(ed.session.ghosts[0]["value"]))))
	var ghost: Dictionary = ed.session.ghosts[0]
	await aim_uv(ed.view._ghost_text_uv[ghost["key"]]) # the value's text, which sits off the geometry on the dimension line
	await pull()
	var pad_open: bool = await settle(func() -> bool: return main._keyboard.is_open())
	print("SMOKE pointing at the label opens the numeric pad, pre-filled with the value: ", pad_open and main._keyboard._text == "%.2f" % float(ghost["value"]))
	main._keyboard.close()
	var dims_before := calls_to("/constraints").size()
	await ed.dimension_typed("length", "25")
	var dimension_call: Array = calls_to("/constraints").back()
	print("SMOKE a typed 25 reaches the backend as a distance of 25: ", calls_to("/constraints").size() == dims_before + 1 and dimension_call[1]["type"] == "distance" and dimension_call[1]["distance"] == 25.0)
	await settle(func() -> bool: return ed.view.label_texts().has("25"))
	var dim_label: Label3D = ed.view._labels.get_children().filter(func(l): return (l as Label3D).text == "25")[0]
	print("SMOKE the typed dimension is drawn as a dimension: its value, written in the sketch plane (not a sign turned to face you), with graphics (extension lines, a dimension line, arrowheads) beside it: ", dim_label.billboard == BaseMaterial3D.BILLBOARD_DISABLED and (dim_label.transform.basis.z as Vector3).is_equal_approx(ed.session.plane["n"]) and ed.view._dims.mesh != null and ed.view._dims.mesh.get_surface_count() == 1)
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
	var extrude_call: Array = calls_to("/extrude-features").back() # the preview made the feature early; Apply PATCHes the final settings onto it
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
	var fillet_call: Array = calls_to("/fillet-features").back()
	print("SMOKE Fillet sends the picked edges as edge refs with the radius: ", fillet_call[1]["edge_refs"] == [{"body_id": body_id, "shape_type": "edge", "index": edge_index}] and fillet_call[1]["radius"] == 2.0)
	print("SMOKE ...and keeps the sketch features list for Undo: ", ed.feature_stack.size() == 2)

	# --- Undo takes the last feature back
	table.ui.undo_pressed.emit()
	var undone: bool = await settle(func() -> bool: return ed.feature_stack.size() == 1)
	print("SMOKE the deck's Undo deletes the last feature on the backend and refreshes the part: ", undone and not calls_to("DELETE /document/parts/PART_BOX/features/").is_empty())

	# --- Shell: pick the faces to open, then the wall thickness
	table.reset_pose() # (the part was zoomed up for the grip tests: back to its fitted size, so the laser starts outside it)
	table.manager.activate("shell")
	pivot_world = table.pivot.global_position
	print("SMOKE Shell switches to face picking and shows Wall, Inward, Outward, Clear and Apply: ", ed.state == "pick_faces" and ["thickness", "shell_in", "shell_out", "clear_faces", "apply"].all(func(o): return table.ui.option_button(o) != null) and table.ui.option_button("apply").disabled)
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	print("SMOKE aiming at the part lights a FACE (not an edge): ", ed.hovering and ed._hover_face.get("kind") == "face")
	var shell_face: Dictionary = ed._hover_face.duplicate()
	await pull()
	print("SMOKE a pull adds it to the faces to open, lit, and Apply counts it: ", ed.faces.size() == 1 and table.ui.option_button("apply").text == "Apply (1)" and not table.ui.option_button("apply").disabled and ed.highlight.set_nodes().size() == 1)
	await pull()
	print("SMOKE a second pull on the same face takes it out again: ", ed.faces.is_empty() and ed.highlight.set_nodes().is_empty())
	await pull()
	ed.option_typed("thickness", "1.5")
	await ed.on_option("shell_out")
	print("SMOKE Outward and a typed wall are kept: ", ed.options["shell_direction"] == "outward" and ed.options["thickness"] == 1.5 and table.ui.option_button("thickness").text == "Wall 1.50 mm")
	await ed.on_option("shell_in")
	await ed.apply_feature()
	var shell_call: Array = calls_to("/shell-features").back() if not calls_to("/shell-features").is_empty() else []
	print("SMOKE Apply sends the body, the opened face as a face ref, the wall and the direction (inward): ", not shell_call.is_empty() and shell_call[1]["body_id"] == shell_face["body_id"] and shell_call[1]["faces_to_remove"] == [{"body_id": shell_face["body_id"], "shape_type": "face", "index": shell_face["index"]}] and shell_call[1]["thickness"] == 1.5 and shell_call[1]["thickness_direction"] == "inward")
	print("SMOKE ...the faces are forgotten (the new shape renumbers them) and the feature is on Undo's stack: ", ed.faces.is_empty() and ed.feature_stack.size() >= 2)
	table.manager.deactivate()

	# --- Mirror: one pull on a plane (or a flat face) mirrors the whole part across it
	table.manager.activate("mirror")
	print("SMOKE Mirror goes back to plane picking and offers Fuse into one (off): ", ed.state == "pick_plane" and table.ui.option_button("mirror_fuse") != null and not table.ui.option_button("mirror_fuse").button_pressed)
	var mirror_xy := {"origin": Vector3.ZERO, "x": Vector3(1, 0, 0), "y": Vector3(0, 1, 0), "n": Vector3(0, 0, 1)}
	var mirror_centre: Vector3 = table.table_copy.get_aabb().get_center()
	var mirror_beside: Vector3 = mirror_centre - (mirror_xy["n"] as Vector3) * mirror_centre.dot(mirror_xy["n"]) + Vector3(80, 0, 0)
	var mirror_world: Vector3 = table.table_copy.global_transform * mirror_beside
	var mirror_normal: Vector3 = (table.table_copy.global_transform.basis * Vector3(0, 0, 1)).normalized()
	await aim(mirror_world + mirror_normal * 0.4 + Vector3(0, 0, 0.001), mirror_world)
	var feature_count: int = ed.feature_stack.size()
	await pull()
	var mirrored: bool = await settle(func() -> bool: return not calls_to("/mirror-features").is_empty() )
	var mirror_call: Array = calls_to("/mirror-features")[0] if not calls_to("/mirror-features").is_empty() else []
	print("SMOKE a pull on the XY plane mirrors every body of the part across it (keep separate): ", not mirror_call.is_empty() and mirror_call[1]["mirror_plane"] == {"fixed_plane": "XY"} and mirror_call[1]["source_body_ids"] == ed.body_ids() and mirror_call[1]["merge"] == "keep_separate")
	print("SMOKE ...and no sketch was opened for it: ", ed.state == "pick_plane" and ed.session == null and ed.feature_stack.size() == feature_count + 1)
	await ed.on_option("mirror_fuse")
	await ed.mirror_across({"face": {"body_id": "B1", "index": 3}})
	var last_mirror: Array = calls_to("/mirror-features").back()
	print("SMOKE ...with Fuse on it asks for fuse_into_one, and a flat face can be the plane: ", last_mirror[1]["merge"] == "fuse_into_one" and last_mirror[1]["mirror_plane"] == {"face_ref": {"body_id": "B1", "shape_type": "face", "index": 3}})
	table.manager.deactivate()

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
	var sketch_calls := calls_to("/features/sketch").filter(func(c): return str(c[0]).begins_with("POST"))
	print("SMOKE the trigger opens a sketch on the plane BY NAME (no plane feature needed): ", on_plane and sketch_calls.back()[1] == {"plane": "XY"} and ed.chosen_plane == "XY" and ed.markers.chosen == "XY")
	var tilt_basis := Basis(Vector3.RIGHT, deg_to_rad(60.0))
	print("SMOKE ...and the part turns to stand that plane up at 60 degrees from the slab, x to the right, y away and up: ", (table.pivot.basis * Vector3(0, 0, 1)).normalized().is_equal_approx(tilt_basis * Vector3.UP) and (table.pivot.basis * Vector3(1, 0, 0)).normalized().is_equal_approx(Vector3.RIGHT) and (table.pivot.basis * Vector3(0, 1, 0)).normalized().is_equal_approx(tilt_basis * Vector3(0, 0, -1)))
	print("SMOKE ...and floats high enough that the tilted sheet's lower edge clears the slab: ", table.pivot.position.y >= table.sketch_hover_height - 0.0001)

	# --- the animation on sketch start: with motion on, the turn is a tween that ends exactly on the target
	UiFeedback.reduce_motion = false
	table.apply_pose(Vector3(0, table.hover_height, 0), Basis.IDENTITY, 1.0)
	table.orient_to_plane(xy)
	await process_frame
	await process_frame
	var mid_up: Vector3 = (table.pivot.basis * Vector3(0, 0, 1)).normalized()
	print("SMOKE with motion on the turn is gradual: a frame or two in, the part is neither at its start nor at its tilted end: ", not mid_up.is_equal_approx(Vector3(0, 0, 1)) and not mid_up.is_equal_approx(tilt_basis * Vector3.UP))
	var arrived: bool = false
	for i in 120:
		await process_frame
		if (table.pivot.basis * Vector3(0, 0, 1)).is_equal_approx(tilt_basis * Vector3.UP):
			arrived = true
			break
	print("SMOKE ...and it ends exactly on the tilted pose, the sheet and the picker following the live transform: ", arrived and ed.view != null and ed.view.get_parent() == table.table_copy)
	UiFeedback.reduce_motion = true
	table.apply_pose(Vector3(0, table.hover_height, 0), Basis.IDENTITY, 1.0)
	table.orient_to_plane(xy)
	print("SMOKE with Reduce motion on, the turn is instant: ", (table.pivot.basis * Vector3(0, 0, 1)).is_equal_approx(tilt_basis * Vector3.UP))
	table.reset_pose()
	print("SMOKE Reset while a sketch is open goes back to the tilted sketch pose (not flat): ", (table.pivot.basis * Vector3(0, 0, 1)).is_equal_approx(tilt_basis * Vector3.UP) and is_equal_approx(table.user_scale, 1.0))

	# --- Revolve: the axis is a line of the open sketch, picked with the laser
	var rev_line: String = ed.session.lines.keys()[0]
	var rev_mid: Vector2 = (ed.session.points[ed.session.lines[rev_line]["a"]] + ed.session.points[ed.session.lines[rev_line]["b"]]) * 0.5
	table.manager.activate("revolve")
	print("SMOKE Revolve shows Boss, Cut, Angle 360 deg, Axis: pick, and an Apply that waits for the axis: ", ["boss", "cut", "angle", "axis", "apply"].all(func(o): return table.ui.option_button(o) != null) and table.ui.option_button("angle").text == "Angle 360 deg" and table.ui.option_button("axis").text == "Axis: pick" and table.ui.option_button("apply").disabled)
	print("SMOKE ...and the sketch stays live (state sketch) so the laser can pick the axis: ", ed.state == "sketch" and ed.session.tool == "revolve")
	await aim_uv(rev_mid)
	print("SMOKE aiming at the sketch finds only LINES for the axis: ", ed._hover_entity.get("kind") == "line")
	await pull()
	print("SMOKE a pull makes that line the axis (lit), the button says so and Apply is on: ", ed.revolve_axis != "" and ed.session.selection.size() == 1 and table.ui.option_button("axis").text == "Axis: set" and not table.ui.option_button("apply").disabled)
	ed.option_typed("angle", "400")
	print("SMOKE an angle over 360 or zero is refused: ", ed.options["angle"] == 360.0)
	ed.option_typed("angle", "90")
	print("SMOKE ...90 is kept and shown: ", ed.options["angle"] == 90.0 and table.ui.option_button("angle").text == "Angle 90 deg")
	var gets_rev: int = calls_to("/assembly-mesh.glb").size()
	await ed.apply_feature()
	var revolve_call: Array = calls_to("/revolve-features").back() if not calls_to("/revolve-features").is_empty() else []
	print("SMOKE Apply sends the sketch feature, the axis as a LINE ref of the sketch, the angle and Boss: ", not revolve_call.is_empty() and revolve_call[1]["sketch_feature_id"] == "feat1" and revolve_call[1]["axis_ref"] == {"sketch_id": "sk1", "entity_type": "line", "entity_id": rev_line} and revolve_call[1]["angle"] == 90.0 and revolve_call[1]["mode"] == "boss")
	print("SMOKE ...fetches the new mesh, spends the sketch (back to choosing a plane) and forgets the axis: ", calls_to("/assembly-mesh.glb").size() > gets_rev and ed.state == "pick_plane" and ed.session == null and ed.revolve_axis == "")

	# --- lifting while editing, and the part closing it all down
	table.close()
	print("SMOKE closing the table ends the session and returns the part: ", ed.state == "idle" and ed.session == null and table.seated == null and box.visible)
	quit()
