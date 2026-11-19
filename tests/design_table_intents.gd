extends SceneTree
## S7 of docs/dimension-constraint-parity-plan.md: the sketcher's INTENT layer (table_editor.gd `intent_*`) driven the way a hand source would, with no controller button,
## no stick and no `table_manip.drive_input`: only a pointing ray (`aim`, which every source has) and the intents. It must reach the results of S5's tests (pick, preview,
## cycle, drop, type, step back), S6's (label drag, saved, cancel) and S10's (point drag, drop payload, cancel, a pinned point); the options panel's kind buttons
## do what the stick does (the old Prev / Next / Back buttons are gone, F2) and the pad's Cancel and B step back; the hand's hit sizes are larger than the controller's.
## NOT checked: a real hand or controller, the feel, the thread (sketch_point_drag.gd). The ray is still the table's laser, aimed by moving the controller node.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_intents.gd  (see tests/README.md)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")
const Session := preload("res://scripts/design_table/sketch_session.gd")
const InputSource := preload("res://scripts/design_table/input_source.gd")

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

	table.manager.activate("dimension")
	await frames(2)
	var sess = ed.session
	ed.point_drag.synchronous = true

	# --- S5: pick, preview, cycle, drop, type, step back (intents only)
	await aim_uv(centre_uv + Vector2(1, -10))
	await ed.intent_select()
	await settle(func() -> bool: return not sess.busy)
	_check(sess.selection.size() == 1 and sess.selection[0]["kind"] == "line" and ed.dim_flow.live(), "intent_select on a line picks it and a preview goes live")
	var spot := centre_uv + Vector2(4, -22)
	await aim_uv(spot)
	_check(ed.view.dim_preview_uv != null and (ed.view.dim_preview_uv as Vector2).distance_to(ed._hover_uv) < 0.01 and option_pressed("dk:length"), "ONE candidate at the ray, Length lit")
	var pivot_basis: Basis = table.pivot.basis
	_check(ed.intent_step(1) and ed.dim_flow.chosen == "h" and option_pressed("dk:h"), "intent_step(+1): Length -> Horizontal length, the row lights it")
	_check(ed.intent_step(-1) and ed.dim_flow.chosen == "length", "intent_step(-1): back to Length")
	_check(ed.intent_adjust(0.9) and ed.dim_flow.chosen == "h" and not ed.intent_adjust(0.9) and ed.dim_flow.chosen == "h", "intent_adjust(0.9): one step per flick, held does not step again")
	_check(not ed.intent_adjust(0.0) and ed.intent_adjust(-0.9) and ed.dim_flow.chosen == "length", "intent_adjust back to the middle then -0.9: back to Length")
	_check(table.pivot.basis.is_equal_approx(pivot_basis), "...and the part did not turn")
	ed.on_option("dk:h") # F2: the kind buttons are the hand path (a press on a kind chooses it, as the stick does); Prev / Next / Back are gone
	var by_button: bool = ed.dim_flow.chosen == "h" and option_pressed("dk:h")
	ed.on_option("dk:length")
	_check(by_button and ed.dim_flow.chosen == "length" and table.ui.option_button("dk_prev") == null and table.ui.option_button("dk_next") == null and table.ui.option_button("dk_back") == null, "a kind button does what intent_step does, and there are no Prev / Next / Back buttons")
	await ed.intent_select()
	_check(table.keyboard_open() and ed.dim_flow.stage == "pad" and ed.dim_flow.frozen["key"] == "length", "intent_select on empty sheet drops it: the pad opens, the kind frozen")
	_check(table.ui.option_button("dk_back") == null and table.ui.option_button("dk:length") != null, "with the pad open the panel still lists the kinds (no Back button: the pad has its own Cancel, B steps back)")
	_check(ed.intent_back() and not table.keyboard_open() and ed.dim_flow.stage == "preview" and sess.selection.size() == 1, "intent_back: the pad closes, the preview is back, the pick kept")
	await ed.intent_select()
	main._keyboard._text = "33"
	main._keyboard._confirm()
	var made: bool = await settle(func() -> bool: return not calls_to("/label").is_empty() and not sess.busy)
	var post: Array = calls_to("/constraints").filter(func(c): return c[0].begins_with("POST"))
	var put: Array = calls_to("/label")
	var cid := str(put[0][0].get_base_dir().get_file()) if not put.is_empty() else ""
	_check(made and not post.is_empty() and float(post.back()[1]["distance"]) == 33.0 and (put[0][1] as Dictionary).has("offset") and fake.cons.has(cid), "a typed value makes the dimension (POST 33) and saves the dropped placement (PUT .../label)")
	_check(ed.dim_flow.stage == "picking" and sess.selection.is_empty(), "...and the tool is back to picking")
	await aim_uv(centre_uv + Vector2(12, -1))
	await ed.intent_select()
	await settle(func() -> bool: return not sess.busy)
	_check(not ed.intent_cancel_drag() and ed.intent_cancel() and sess.selection.is_empty() and ed.dim_flow.stage == "picking", "intent_cancel with nothing dragged is a step back: the pick is let go")
	_check(not ed.intent_step(1) and not ed.intent_back(true), "...and with nothing picked there is no step and nothing to go back to")

	# --- S6: a label dragged, saved, cancelled
	table.manager.activate("select")
	await frames(3)
	sess.clear_selection()
	var item: Dictionary = {}
	for it in sess.dimension_items():
		if str(it["id"]) == cid:
			item = it
	var label_uv: Vector2 = ed.view._layout_for(item["spec"], str(item["text"]), sess)["text_uv"]
	var puts_before := calls_to("/label").size()
	await aim_uv(label_uv)
	ed._last_pull = {"key": "", "ms": 0}
	await ed.intent_select()
	_check(sess.is_annotation_selected("dimension", cid) and str(ed._label_hold.get("kind", "")) == "label" and not ed.label_dragging(), "intent_select on a label selects it and starts a hold (nothing dragged yet)")
	ed.intent_drag_move(label_uv + Vector2(0.3, 0.2))
	_check(not ed.label_dragging(), "a wobble inside a pick's reach is not a drag")
	var target := label_uv + Vector2(14, 11)
	ed.intent_drag_move(label_uv + Vector2(6, 4))
	ed.intent_drag_move(target)
	var live: Dictionary = {}
	for it in sess.dimension_items():
		if str(it["id"]) == cid:
			live = it
	var drawn: Vector2 = ed.view._layout_for(live["spec"], str(live["text"]), sess)["text_uv"]
	_check(ed.label_dragging() and drawn.distance_to(target) < 0.5 and calls_to("/label").size() == puts_before, "intent_drag_move: the label follows, drawn where it would be saved; nothing sent")
	await ed.intent_drag_end()
	var saved: bool = await settle(func() -> bool: return calls_to("/label").size() > puts_before and not sess.busy)
	_check(saved and calls_to("/label").back()[0].contains(cid) and not sess.label_override.has(cid) and not ed.label_dragging(), "intent_drag_end saves PUT .../constraints/%s/label" % cid)
	await sess.undo()
	for it in sess.dimension_items():
		if str(it["id"]) == cid:
			live = it
	drawn = ed.view._layout_for(live["spec"], str(live["text"]), sess)["text_uv"]
	_check(drawn.distance_to(target) > 2.0, "Undo puts the label back")
	sess.annotations.clear()
	await aim_uv(label_uv)
	ed._last_pull = {"key": "", "ms": 0}
	var puts_now := calls_to("/label").size()
	await ed.intent_select()
	ed.intent_drag_move(label_uv + Vector2(16, -9))
	var was_dragging: bool = ed.label_dragging()
	_check(was_dragging and ed.intent_cancel() and not ed.label_dragging() and calls_to("/label").size() == puts_now and sess.label_override.is_empty(), "intent_cancel mid-drag puts the label back and saves nothing")
	await ed.intent_drag_end()
	sess.annotations.clear()

	# --- S10: a point dragged, the drop's payload, cancel, a pinned point
	sess.clear_selection()
	var corner := ""
	var corner_uv := Vector2.ZERO
	for id in sess.points:
		if sess.points[id].distance_to(centre_uv + Vector2(12, 8)) < 0.5:
			corner = str(id)
			corner_uv = sess.points[id]
	var before := {}
	for id in sess.points:
		before[id] = sess.points[id]
	var solves_before := calls_to("/solve-and-refresh").size()
	await aim_uv(corner_uv)
	await ed.intent_select()
	_check(sess.is_selected({"kind": "point", "id": corner}) and str(ed._label_hold.get("kind", "")) == "point" and not ed.point_dragging(), "intent_select on a corner selects it and starts a point hold")
	target = corner_uv + Vector2(9, 7)
	ed.intent_drag_move(corner_uv + Vector2(0.3, 0.2))
	_check(not ed.point_dragging(), "a wobble is not a drag")
	ed.intent_drag_move(corner_uv + Vector2(4, 3))
	ed.intent_drag_move(target)
	_check(ed.point_dragging() and not ed.label_dragging() and (sess.points[corner] as Vector2).distance_to(target) < 0.8 and calls_to("/solve-and-refresh").size() == solves_before, "intent_drag_move: the point follows; nothing sent yet")
	await ed.intent_drag_end()
	var sent: bool = await settle(func() -> bool: return calls_to("/solve-and-refresh").size() > solves_before and not sess.busy)
	var body: Variant = fake.last_solve_body
	var wish_ids: Array = []
	if body is Dictionary:
		for u in (body as Dictionary).get("point_updates", []):
			wish_ids.append(str(u["id"]))
	_check(sent and body is Dictionary and corner in wish_ids and (body as Dictionary).get("anchor_point_ids", []) == [corner], "intent_drag_end sends ONE solve-and-refresh: point_updates with the corner, anchor_point_ids [corner]")
	_check(sess.can_undo() and sess.undo_label() == "point move" and not ed.point_dragging(), "...one Undo step")
	await sess.undo()
	var restored := true
	for id in before:
		if (sess.points[id] as Vector2).distance_to(before[id]) > 1e-3:
			restored = false
	_check(restored, "Undo puts every point back")
	var solves_now := calls_to("/solve-and-refresh").size()
	sess.clear_selection()
	await aim_uv(corner_uv)
	await ed.intent_select()
	ed.intent_drag_move(corner_uv + Vector2(12, -5))
	var live_drag: bool = ed.point_dragging() and (sess.points[corner] as Vector2).distance_to(corner_uv) > 3.0
	_check(live_drag and ed.intent_cancel() and not ed.point_dragging() and calls_to("/solve-and-refresh").size() == solves_now and (sess.points[corner] as Vector2).distance_to(corner_uv) < 1e-3, "intent_cancel mid-drag puts the points back and sends nothing")
	await ed.intent_drag_end()
	if sess.origin_id != "":
		sess.clear_selection()
		await aim_uv(Vector2.ZERO)
		await ed.intent_select()
		ed.intent_drag_move(Vector2(9, 9))
		_check(not ed.point_dragging() and sess.points[sess.origin_id] == Vector2.ZERO, "a pinned point (the origin) starts no drag through the intents")
		await ed.intent_drag_end()

	# --- hit sizes per source
	var pick_c: float = ed._reach_mm("pick")
	var ghost_c: float = ed._reach_mm("ghost")
	ed.set_input_source("hand")
	_check(ed.input_source == "hand" and ed.view.input_source == "hand" and ed._reach_mm("pick") > pick_c and ed._reach_mm("ghost") > ghost_c
		and InputSource.value("hand", "glyph") > InputSource.value("controller", "glyph"), "the hand source has larger pick, ghost and glyph hit sizes")
	ed.set_input_source("nonsense")
	_check(ed.input_source == "hand", "an unknown source changes nothing")
	ed.set_input_source("controller")
	_check(is_equal_approx(ed._reach_mm("pick"), pick_c) and is_equal_approx(ed._reach_mm("ghost"), ghost_c) and is_equal_approx(InputSource.value("controller", "pick"), 0.014)
		and is_equal_approx(InputSource.value("controller", "ghost"), 0.030) and is_equal_approx(InputSource.value("controller", "glyph"), 0.007), "back to the controller: the old sizes (0.014, 0.030, 0.007)")

	ed.point_drag.wait_all()
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
