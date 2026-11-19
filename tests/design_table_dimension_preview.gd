extends SceneTree
## S5 of docs/dimension-constraint-parity-plan.md through the design table's real laser path (table_editor.gd, table_manip.gd) against the FAKE backend
## (tests/helpers/fake_cad.gd), a rectangle drawn first. With the Dimension tool: a pull on a line picks it; the laser on empty sheet shows ONE
## candidate, its label at the laser (the others are not drawn); the options row lists the line's kinds with the previewed one lit and the
## "All candidates" toggle (F7) off. The right stick (table_manip.drive_input, as the controller feeds it while the table is engaged) steps the kind
## and does not turn the part; with a hand gripping the table the stick still steps the kind while Orbit lock is on (the default) and is the table's when it is off (F2, owner decision 1). B while the dimension flow has a step to go back to
## does not push the part away. A pull on empty sheet drops it: the number pad opens and the preview stays put while the laser moves; B closes the
## pad and goes back to the preview; a second drop and a typed value make the dimension (POST) and save the dropped placement (PUT .../label);
## B with a pick and no pad lets the pick go; F7 on draws every candidate and no preview. NOT checked: a real stick or button on a headset, the
## feel (the handoff's headset checklist).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_dimension_preview.gd  (see tests/README.md)

const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const Fake := preload("res://tests/helpers/fake_cad.gd")

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

	# --- pick a line with the Dimension tool
	table.manager.activate("dimension")
	await frames(2)
	_check(ed.dim_flow.stage == "picking" and option_pressed("dk_all") == false and table.ui.option_button("dk_all") != null, "the Dimension tool: nothing previewed yet, the Properties panel has the 'All candidates' toggle, off (F7)")
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	await settle(func() -> bool: return not ed.session.busy)
	_check(ed.session.selection.size() == 1 and ed.session.selection[0]["kind"] == "line" and ed.dim_flow.live(), "a pull on a line picks it and a preview goes live")
	var spot := centre_uv + Vector2(4, -22)
	await aim_uv(spot)
	_check(ed.view.dim_preview_uv != null and (ed.view.dim_preview_uv as Vector2).distance_to(ed._hover_uv) < 0.01 and (ed._hover_uv as Vector2).distance_to(spot) < 1.5,
		"the laser on empty sheet: ONE candidate, its label at the laser")
	_check(not ed.view.label_texts().any(func(t): return t.begins_with("?")) and ed.view._ghost_text_uv.is_empty(), "...the other candidates are not drawn")
	_check(option_pressed("dk:length") and not option_pressed("dk:h") and table.ui.option_button("dk:v") != null and table.ui.option_button("dk:horizontalAngle") != null,
		"the options row lists the line's four kinds, Length (the previewed one) lit")

	# --- the stick: the kind, not the part (F3)
	var basis_before: Basis = table.pivot.basis
	var pos_before: Vector3 = table.pivot.position
	_check(table.manip.engaged and table.owns_stick(r), "the laser on the sheet engages the table (the stick and A / B are its, not walking's)")
	table.manip.drive_input(Vector2(0.9, 0.0), false, false, 0.1)
	table.manip.drive_input(Vector2(0.9, 0.0), false, false, 0.1)
	await frames(2)
	_check(ed.dim_flow.chosen == "h" and option_pressed("dk:h") and not option_pressed("dk:length"), "the right stick flicked right steps the kind once (Length -> Horizontal length), held does not step again; the row lights it")
	_check(table.pivot.basis.is_equal_approx(basis_before), "...and the part did not turn with it")
	table.manip.drive_input(Vector2.ZERO, false, false, 0.1)
	table.manip.drive_input(Vector2(-0.9, 0.0), false, false, 0.1)
	_check(ed.dim_flow.chosen == "length", "back to the middle, then left: back to Length")
	table.manip.drive_input(Vector2.ZERO, false, false, 0.1)
	# F2, owner decision 1: whenever a preview is live and the laser is on the sheet the stick cycles, except when Orbit lock is off and a hand grips.
	table.manip._grips[l] = {"offset": Vector3.ZERO}
	_check(table.part_locked and table.sketch_locked(), "(Orbit lock is on, the default, with the sketch open)")
	var owned_gripped: bool = ed.dimension_stick(Vector2(0.9, 0.0))
	_check(owned_gripped and ed.dim_flow.chosen == "h", "Orbit lock on, a hand gripping the table: the stick still steps the kind (it would do nothing to the part)")
	table.manip.drive_input(Vector2.ZERO, false, false, 0.1)
	ed.dimension_stick(Vector2.ZERO)
	ed.dimension_stick(Vector2(-0.9, 0.0))
	_check(ed.dim_flow.chosen == "length", "...and back")
	ed.dimension_stick(Vector2.ZERO)
	table.part_locked = false
	var basis_gripped: Basis = table.pivot.basis
	var owned_free: bool = ed.dimension_stick(Vector2(0.9, 0.0))
	var ui_hover_was = table._right.get_meta("ui_hover", false)
	table._right.set_meta("ui_hover", false) # (drive_input leaves the stick to the deck while the laser is on it; here the part's turn is what is looked at)
	table.manip.drive_input(Vector2(0.9, 0.0), false, false, 0.1)
	table._right.set_meta("ui_hover", ui_hover_was)
	_check(not owned_free and ed.dim_flow.chosen == "length" and not table.pivot.basis.is_equal_approx(basis_gripped), "Orbit lock off, a hand gripping the table: the stick is the table's (the kind does not change, the part turns)")
	table.manip._grips.erase(l)
	table.pivot.basis = basis_gripped
	ed.dimension_stick(Vector2.ZERO)
	_check(ed.dimension_stick(Vector2(0.9, 0.0)) and ed.dim_flow.chosen == "h", "Orbit lock off, no grip: the stick steps the kind as before")
	ed.dimension_stick(Vector2.ZERO)
	ed.dimension_stick(Vector2(-0.9, 0.0))
	table.part_locked = true
	table.manip.drive_input(Vector2.ZERO, false, false, 0.1)
	_check(ed.dim_flow.chosen == "length", "(back to Length, Orbit lock on again)")
	table.manip.drive_input(Vector2.ZERO, false, true, 0.2)
	_check(table.pivot.position.is_equal_approx(pos_before), "B held while the dimension flow can step back does not push the part away")
	ed.on_option("dk:v")
	await frames(1)
	_check(ed.dim_flow.chosen == "v" and option_pressed("dk:v"), "a press on a kind in the options row chooses it (the stick's mirror)")
	ed.on_option("dk:length")

	# --- drop, B back, drop again, type
	await aim_uv(spot)
	await pull()
	_check(table.keyboard_open() and ed.dim_flow.stage == "pad" and ed.dim_flow.frozen["key"] == "length", "a pull on empty sheet drops it: the number pad opens, the kind frozen")
	var dropped_uv: Vector2 = ed.view.dim_preview_uv
	await aim_uv(spot + Vector2(10, -6))
	_check((ed.view.dim_preview_uv as Vector2).distance_to(dropped_uv) < 0.01, "...the dropped dimension stays where it was while the laser moves on")
	await press_b()
	_check(not table.keyboard_open() and ed.dim_flow.stage == "preview" and ed.session.selection.size() == 1, "B: the pad closes and the preview is back (the pick kept)")
	await aim_uv(spot)
	_check((ed.view.dim_preview_uv as Vector2).distance_to(ed._hover_uv) < 0.01, "...following the laser again")
	await pull()
	var kb = main._keyboard
	kb._text = "33"
	kb._confirm()
	var made: bool = await settle(func() -> bool: return not calls_to("/label").is_empty() and not ed.session.busy)
	var post: Array = calls_to("/constraints").filter(func(c): return c[0].begins_with("POST"))
	var put: Array = calls_to("/label")
	_check(made and not post.is_empty() and float(post.back()[1]["distance"]) == 33.0, "a typed value makes the dimension through the backend (POST, 33)")
	var cid := str(put[0][0].get_base_dir().get_file()) if not put.is_empty() else ""
	_check(cid != "" and fake.cons.has(cid) and (put[0][1] as Dictionary).has("offset") and (put[0][1] as Dictionary).has("along"), "...and saves the dropped placement on it (PUT .../constraints/%s/label, offset and along)" % cid)
	var label_at: Variant = null
	for it in ed.session.dimension_items():
		if str(it["id"]) == cid:
			label_at = ed.view._layout_for(it["spec"], str(it["text"]), ed.session)["text_uv"]
	_check(label_at != null and (label_at as Vector2).distance_to(ed._hover_uv) < 0.05, "...so the dimension is drawn with its label where it was dropped")
	_check(ed.dim_flow.stage == "picking" and ed.session.selection.is_empty() and ed.view.dim_preview_uv == null, "...and the tool is back to picking")

	# --- B with a pick and no pad lets it go; F7 draws every candidate
	await aim_uv(centre_uv + Vector2(12, -1))
	await pull()
	await settle(func() -> bool: return not ed.session.busy)
	await aim_uv(spot)
	var picked_one: bool = ed.session.selection.size() == 1
	await press_b()
	_check(picked_one and ed.session.selection.is_empty() and ed.dim_flow.stage == "picking", "B with a pick and the preview live: the pick is let go")
	await aim_uv(centre_uv + Vector2(1, -10))
	await pull()
	await settle(func() -> bool: return not ed.session.busy)
	ed.on_option("dk_all")
	await frames(2)
	await aim_uv(spot)
	_check(ed.dim_flow.show_all and option_pressed("dk_all") and ed.view._ghost_text_uv.size() == ed.session.ghosts.size() and ed.view.dim_preview_uv == null,
		"F7 'All at once' on: every candidate is drawn, no preview follows the laser")
	ed.on_option("dk_all")
	await frames(2)
	_check(not ed.dim_flow.show_all and ed.view._ghost_text_uv.is_empty(), "...off again: back to the one preview")

	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
