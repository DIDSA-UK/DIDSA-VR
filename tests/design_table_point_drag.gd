extends SceneTree
## S10 of docs/dimension-constraint-parity-plan.md through the design table's real laser and trigger path (table_editor.gd) against the FAKE backend (a rectangle drawn
## first). With the Select tool (F6): a quick pull on a corner still only selects; the trigger held on it and the laser moved drags it (the projector runs, synchronous
## here), the corner and what hangs from it follow the laser with nothing sent yet; letting go sends ONE solve-and-refresh with the wish (`point_updates`) and the grabbed
## point as an anchor, and the backend's answer is what the sketch shows; Undo restores the positions; B during the drag puts the points back and sends nothing; a press on
## the origin starts no drag; with a label and a point both under the laser the nearer wins (a tie goes to the point) and a line beside a label still gives way to it.
## NOT checked: a real trigger held by a hand, the shake of a real laser, the feel of a constrained point sliding, the lag of a large group, the thread (sketch_point_drag.gd).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_point_drag.gd  (see tests/README.md)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const Session := preload("res://scripts/design_table/sketch_session.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")

var main
var table
var ed
var r: XRController3D
var fake
var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


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


func press_b() -> void:
	r.button_pressed.emit("by_button")
	await frames(1)
	r.button_released.emit("by_button")
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
	var copy: Node3D = table.table_copy
	var plane: Dictionary = ed.session.plane
	var world: Vector3 = copy.global_transform * SketchMath.from_sheet(uv, plane)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	await aim(world + normal * 0.45 + Vector3(0, 0, 0.12), world)


func option_pressed(id: String) -> bool:
	var b: Button = table.ui.option_button(id)
	return b != null and b.button_pressed



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
	table.editor.selection_first = false
	table.sketch_sheet_front = false
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
	table.open()
	table.seat(box)
	await settle(func() -> bool: return ed.state == "pick_plane")
	var pivot_world: Vector3 = table.pivot.global_position
	await aim(pivot_world + table.global_transform.basis * Vector3(0.0, 0.25, 0.45), pivot_world)
	await pull()
	var opened: bool = await settle(func() -> bool: return ed.state == "sketch")
	var centre_uv: Vector2 = ed.view.sheet_centre
	table.manager.activate("rectangle")
	await aim_uv(centre_uv + Vector2(-10, -10))
	await pull()
	await aim_uv(centre_uv + Vector2(12, 8))
	await pull()
	var drew: bool = await settle(func() -> bool: return not calls_to("/rectangles").is_empty() and not ed.session.busy)
	_check(opened and drew, "setup: a sketch is open with a rectangle drawn through the fake backend")

	ed.point_drag.synchronous = true
	table.manager.activate("select")
	await frames(3)
	var sess = ed.session
	var corner := ""
	var corner_uv := Vector2.ZERO
	for id in sess.points:
		if sess.points[id].distance_to(centre_uv + Vector2(12, 8)) < 0.5:
			corner = str(id)
			corner_uv = sess.points[id]
	_check(corner != "", "setup: the rectangle's far corner is a sketch point (%s)" % corner)
	var solves_before := calls_to("/solve-and-refresh").size()

	# --- a quick pull is the old pull
	await aim_uv(corner_uv)
	_check(str(ed._hover_entity.get("kind", "")) == "point" and str(ed._hover_entity.get("id", "")) == corner, "the laser on the corner picks the point")
	await pull()
	_check(sess.is_selected({"kind": "point", "id": corner}) and not ed.point_dragging() and calls_to("/solve-and-refresh").size() == solves_before, "a quick pull selects the point and sends nothing")
	sess.clear_selection()
	await frames(2)

	# --- a hold with a wobble is still a pull
	await aim_uv(corner_uv)
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(corner_uv + Vector2(0.3, 0.2))
	_check(not ed.point_dragging(), "a wobble inside a pick's reach does not start a drag")
	r.button_released.emit("trigger_click")
	await frames(3)
	_check(calls_to("/solve-and-refresh").size() == solves_before, "...and letting go sends nothing")
	sess.clear_selection()

	# --- a real drag
	var before := {}
	for id in sess.points:
		before[id] = sess.points[id]
	await aim_uv(corner_uv)
	var target := corner_uv + Vector2(9, 7)
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(corner_uv + Vector2(4, 3))
	await aim_uv(target)
	_check(ed.point_dragging() and not ed.label_dragging(), "the trigger held and the laser moved: it is a point drag")
	_check((sess.points[corner] as Vector2).distance_to(target) < 0.8 and calls_to("/solve-and-refresh").size() == solves_before, "the point follows the laser; nothing is sent yet")
	_check(ed.point_drag.frames_run >= 1, "the projector ran each frame (%d calls)" % ed.point_drag.frames_run)
	var moved_others := 0
	for id in sess.points:
		if str(id) != corner and (sess.points[id] as Vector2).distance_to(before[id]) > 0.01:
			moved_others += 1
	print("SMOKE the group followed with %d other points" % moved_others)
	r.button_released.emit("trigger_click")
	var sent: bool = await settle(func() -> bool: return calls_to("/solve-and-refresh").size() > solves_before and not sess.busy)
	var body: Variant = fake.last_solve_body
	var wish_ids: Array = []
	if body is Dictionary:
		for u in (body as Dictionary).get("point_updates", []):
			wish_ids.append(str(u["id"]))
	_check(sent and body is Dictionary and corner in wish_ids and (body as Dictionary).get("anchor_point_ids", []) == [corner], "letting go sends ONE solve-and-refresh: point_updates with the corner, anchor_point_ids [corner]")
	_check(calls_to("/solve-and-refresh").size() == solves_before + 1 or calls_to("/solve-and-refresh").size() == solves_before + 2, "...and a single solve for the drop")
	var truth_ok := true
	for id in sess.points:
		if (sess.points[id] as Vector2).distance_to(fake.points[id]) > 1e-4:
			truth_ok = false
	_check(truth_ok and (sess.points[corner] as Vector2).distance_to(target) < 0.8 and not ed.point_dragging(), "the sketch shows the backend's answer")
	_check(sess.can_undo() and sess.undo_label() == "point move", "the drop is one Undo step")
	await sess.undo()
	var restored := true
	for id in before:
		if (sess.points[id] as Vector2).distance_to(before[id]) > 1e-3:
			restored = false
	_check(restored, "Undo puts every point back")

	# --- B during a drag puts the points back and sends nothing
	var solves_now := calls_to("/solve-and-refresh").size()
	await aim_uv(corner_uv)
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(corner_uv + Vector2(12, -5))
	var dragging: bool = ed.point_dragging()
	var moved_live: bool = (sess.points[corner] as Vector2).distance_to(corner_uv) > 3.0
	r.button_pressed.emit("by_button")
	await frames(1)
	r.button_released.emit("by_button")
	r.button_released.emit("trigger_click")
	await frames(3)
	_check(dragging and moved_live and not ed.point_dragging() and calls_to("/solve-and-refresh").size() == solves_now and (sess.points[corner] as Vector2).distance_to(corner_uv) < 1e-3,
		"B during the drag puts the points back and sends nothing")

	# --- the origin does not move
	if sess.origin_id != "":
		await aim_uv(Vector2.ZERO)
		r.button_pressed.emit("trigger_click")
		await frames(2)
		await aim_uv(Vector2(9, 9))
		_check(not ed.point_dragging() and sess.points[sess.origin_id] == Vector2.ZERO, "a press on the origin starts no drag")
		r.button_released.emit("trigger_click")
		await frames(3)
		sess.clear_selection()

	# --- the nearer hit: a label and a point under the laser together
	table.manager.activate("dimension")
	await frames(2)
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	await settle(func() -> bool: return not sess.busy)
	var made_dim: Dictionary = await sess.confirm_ghost("length", 22.0)
	var cid := str(fake.cons.keys()[-1])
	table.manager.activate("select")
	await frames(3)
	sess.clear_selection()
	var item: Dictionary = {}
	for it in sess.dimension_items():
		if str(it["id"]) == cid:
			item = it
	var label_uv: Vector2 = ed.view._layout_for(item["spec"], str(item["text"]), sess)["text_uv"]
	sess.points["extra"] = label_uv + Vector2(2.5, 0)
	ed._refresh_view()
	await aim_uv(label_uv + Vector2(1.8, 0))
	_check(bool(made_dim["ok"]) and ed._hover_annotation.is_empty() and str(ed._hover_entity.get("id", "")) == "extra", "a point nearer the laser than the label's centre wins")
	await aim_uv(label_uv + Vector2(-0.8, 0))
	_check(not ed._hover_annotation.is_empty() and ed._hover_entity.is_empty(), "the label nearer than the point wins (a line beside it still gives way)")
	ed._hover_entity = {"kind": "point", "id": "x", "distance": 2.0}
	ed._hover_annotation = {"kind": "dimension", "id": "y", "distance": 2.0}
	var tie: bool = ed._point_beats_annotation()
	ed._hover_annotation = {"kind": "dimension", "id": "y", "distance": 1.9}
	var label_nearer: bool = not ed._point_beats_annotation()
	ed._hover_entity = {"kind": "line", "id": "l", "distance": 0.1}
	_check(tie and label_nearer and not ed._point_beats_annotation(), "a tie goes to the point; a farther point loses; a line never competes")
	# the hold follows the winner
	await aim_uv(label_uv + Vector2(1.8, 0))
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(label_uv + Vector2(1.8, 0) + Vector2(10, 8))
	_check(ed.point_dragging() and not ed.label_dragging(), "held on the point that is nearer: the point drags, not the label")
	r.button_pressed.emit("by_button")
	await frames(1)
	r.button_released.emit("by_button")
	r.button_released.emit("trigger_click")
	await frames(3)
	await aim_uv(label_uv + Vector2(-0.8, 0))
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(label_uv + Vector2(-0.8, 0) + Vector2(10, 8))
	_check(ed.label_dragging() and not ed.point_dragging(), "held on the label that is nearer: the label drags, not the point")
	r.button_pressed.emit("by_button")
	await frames(1)
	r.button_released.emit("by_button")
	r.button_released.emit("trigger_click")
	await frames(3)

	ed.point_drag.wait_all()
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
