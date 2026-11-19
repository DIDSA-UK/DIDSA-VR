extends SceneTree
## S6 of docs/dimension-constraint-parity-plan.md through the design table's real laser and trigger path (table_editor.gd) against the FAKE backend, a rectangle
## drawn first and one dimension made on a line. With the Select tool (F5): a quick pull on the label selects it and nothing is saved; a second quick pull opens the
## pad (as before); the trigger held on the label while the laser moves drags it: the label follows the laser (drawn at the placement it would be saved with, nothing sent
## yet), letting go saves it (PUT .../label) and Undo puts it back; a short wobble inside a pick's reach is still just a pull; B during the drag puts the label back and
## saves nothing; the right stick in Select does not step a dimension kind (S5's rule stays: the stick is the table's while no preview is live), and the pad is not
## opened at the label (it opens at its dock). The options row of a selected circle / angle dimension offers the R / diameter switch / Other side.
## NOT checked: a real trigger held by a hand, the shake of a real laser, how small a label is to grab (the handoff's headset checklist).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_label_drag.gd  (see tests/README.md)

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

	# --- a dimension on the bottom line
	table.manager.activate("dimension")
	await frames(2)
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	await settle(func() -> bool: return not ed.session.busy)
	var made_dim: Dictionary = await ed.session.confirm_ghost("length", 22.0)
	var cid := str(fake.cons.keys()[-1])
	_check(bool(made_dim["ok"]) and cid != "", "setup: a Length dimension on the line")
	table.manager.activate("select")
	await frames(3)
	ed.session.clear_selection()
	var item: Dictionary = {}
	for it in ed.session.dimension_items():
		if str(it["id"]) == cid:
			item = it
	var label_uv: Vector2 = ed.view._layout_for(item["spec"], str(item["text"]), ed.session)["text_uv"]

	# --- a quick pull is the old pull
	await aim_uv(label_uv)
	_check(not ed._hover_annotation.is_empty() and str(ed._hover_annotation["id"]) == cid, "the laser on the label lights it")
	var puts_before := calls_to("/label").size()
	await pull()
	_check(ed.session.is_annotation_selected("dimension", cid) and calls_to("/label").size() == puts_before and not ed.label_dragging(), "a quick pull selects the label and saves nothing")
	await pull()
	_check(table.keyboard_open() or not ed.session.is_annotation_selected("dimension", cid), "a second quick pull on it opens the pad as before (or lets it go)")
	if table.keyboard_open():
		table.close_keyboard()
	await frames(2)
	ed.session.annotations.clear()
	await frames(2)
	await aim_uv(label_uv)

	# --- a hold with a wobble is still a pull
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(label_uv + Vector2(0.3, 0.2))
	_check(not ed.label_dragging(), "a wobble inside a pick's reach does not start a drag")
	r.button_released.emit("trigger_click")
	await frames(3)
	_check(calls_to("/label").size() == puts_before, "...and letting go saves nothing")
	await frames(10)
	ed.session.annotations.clear()
	await aim_uv(label_uv)

	# --- a real drag
	var target := label_uv + Vector2(14, 11)
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(label_uv + Vector2(6, 4))
	await aim_uv(target)
	_check(ed.label_dragging(), "the trigger held and the laser moved: it is a drag")
	var live: Dictionary = {}
	for it in ed.session.dimension_items():
		if str(it["id"]) == cid:
			live = it
	var drawn: Vector2 = ed.view._layout_for(live["spec"], str(live["text"]), ed.session)["text_uv"]
	_check(drawn.distance_to(target) < 0.5 and calls_to("/label").size() == puts_before, "the label follows the laser, drawn at the placement it would be saved with; nothing is sent yet")
	_check(ed.session.is_annotation_selected("dimension", cid) and not table.keyboard_open(), "the grabbed label is lit as selected and no pad opened on the way")
	var stick_owned: bool = ed.dimension_stick(Vector2(0.9, 0.0))
	_check(not stick_owned and ed.dim_flow.chosen == "", "the stick does not step a dimension kind during the hold (S5's rule: no preview, the stick is the table's)")
	r.button_released.emit("trigger_click")
	var saved: bool = await settle(func() -> bool: return calls_to("/label").size() > puts_before and not ed.session.busy)
	var put: Array = calls_to("/label")
	_check(saved and put.back()[0].contains(cid) and (put.back()[1] as Dictionary).has("offset"), "letting go saves the placement: PUT .../constraints/%s/label" % cid)
	_check(not ed.session.label_override.has(cid) and not ed.label_dragging(), "...the drag's preview is gone, the saved placement takes over")
	for it in ed.session.dimension_items():
		if str(it["id"]) == cid:
			live = it
	drawn = ed.view._layout_for(live["spec"], str(live["text"]), ed.session)["text_uv"]
	_check(drawn.distance_to(target) < 0.5, "...and the label stays where it was dropped")
	await ed.session.undo()
	for it in ed.session.dimension_items():
		if str(it["id"]) == cid:
			live = it
	drawn = ed.view._layout_for(live["spec"], str(live["text"]), ed.session)["text_uv"]
	_check(drawn.distance_to(target) > 2.0, "Undo puts the label back")

	# --- B during a drag puts it back
	await aim_uv(label_uv)
	ed.session.annotations.clear()
	var puts_now := calls_to("/label").size()
	r.button_pressed.emit("trigger_click")
	await frames(2)
	await aim_uv(label_uv + Vector2(16, -9))
	var dragging: bool = ed.label_dragging()
	r.button_pressed.emit("by_button")
	await frames(1)
	r.button_released.emit("by_button")
	r.button_released.emit("trigger_click")
	await frames(3)
	_check(dragging and not ed.label_dragging() and calls_to("/label").size() == puts_now and ed.session.label_override.is_empty(), "B during the drag puts the label back and saves nothing")

	# --- the options of a selected circle / angle dimension
	var circle_options := SketchSelection.annotation_options([{"kind": "dimension", "id": "kc"}], [], _stub_session())
	_check(circle_options.any(func(o): return o["id"] == "diameter_toggle") and circle_options.any(func(o): return o["id"] == "edit_value"), "a circle's size dimension offers the R / diameter switch")
	var angle_options := SketchSelection.annotation_options([{"kind": "dimension", "id": "ka"}], [], _stub_session())
	_check(angle_options.any(func(o): return o["id"] == "angle_side"), "an angle dimension offers Other side")
	var line_options := SketchSelection.annotation_options([{"kind": "dimension", "id": cid}], [], ed.session)
	_check(not line_options.any(func(o): return o["id"] in ["diameter_toggle", "angle_side"]), "a length dimension offers neither")

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)


func _stub_session() -> Object:
	var s = Session.new(Callable(fake, "handle"))
	s.circles["c1"] = {"c": "a", "p": "b", "k": "kc"}
	s.constraints["kc"] = {"id": "kc", "type": "distance", "distance": 5.0, "point_a_id": "a", "point_b_id": "b"}
	s.constraints["ka"] = {"id": "ka", "type": "angle", "line1_id": "x", "line2_id": "y", "angle_degrees": 30.0}
	return s
