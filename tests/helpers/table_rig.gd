extends RefCounted
## The design table's test rig, shared by the Phase 5 / 6 tests: boots main.tscn, puts the box-and-cylinder fixture on the table with the
## fake backend (tests/helpers/fake_cad.gd), seated and ready for plane picking, and offers the laser helpers (aim, pull) the editing tests use.
##   var rig = Rig.new(); await rig.boot(self)   # self = the test's SceneTree
## Then rig.table, rig.ed (the editor), rig.fake, rig.r (the right controller), rig.box (the arena node).

const Fake := preload("res://tests/helpers/fake_cad.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

var tree: SceneTree
var main
var table
var ed
var r: XRController3D
var fake
var box: MeshInstance3D
var owner_id := ""


func frames(n: int = 3) -> void:
	for i in n:
		await tree.physics_frame
		await tree.process_frame


func boot(p_tree: SceneTree, seat := true) -> void:
	tree = p_tree
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	tree.root.add_child(main)
	await tree.process_frame
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
	for p in tree.get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	owner_id = str(box.get_meta("owner_part_id", ""))
	if owner_id == "":
		owner_id = "ASM"
		for p in tree.get_nodes_in_group("grabbable_parts"):
			p.set_meta("owner_part_id", owner_id)
	fake = Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.mesh_bytes = bytes
	fake.origin = true
	fake.feature_rows = {"PART_BOX": []}
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		if not body.has("face_refs") or (body["face_refs"] as Array).is_empty() or not (body["face_refs"][0] as Dictionary).has("face_ref"):
			return {"origin": [0, 0, 0], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]} # offset from a plane, not a face
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var plane := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [plane["origin"].x, plane["origin"].y, plane["origin"].z], "normal": [plane["n"].x, plane["n"].y, plane["n"].z],
			"x_axis": [plane["x"].x, plane["x"].y, plane["x"].z], "y_axis": [plane["y"].x, plane["y"].y, plane["y"].z]}
	ed.api = fake
	table.open()
	if seat:
		table.seat(box)
		await settle(func() -> bool: return ed.state == "pick_plane")


func aim(from: Vector3, to: Vector3) -> void:
	var dir := (to - from).normalized()
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	r.global_transform = Transform3D(Basis.looking_at(dir, up), from)
	await frames(3)


func aim_at_part(offset := Vector3(0.0, 0.25, 0.45)) -> void:
	## From in front of and above the console to the middle of the part on the table.
	var pivot: Vector3 = table.pivot.global_position
	await aim(pivot + table.global_transform.basis * offset, pivot)


func pull() -> void:
	r.button_pressed.emit("trigger_click")
	await frames(2)
	r.button_released.emit("trigger_click")
	await frames(2)


func settle(pred: Callable, n := 200) -> bool:
	for i in n:
		if pred.call():
			return true
		await tree.process_frame
	return false


func calls_to(fragment: String) -> Array:
	return fake.calls.filter(func(c): return c[0].contains(fragment))


func aim_uv(uv: Vector2) -> void:
	var copy: Node3D = table.table_copy
	var plane: Dictionary = ed.session.plane
	var world: Vector3 = copy.global_transform * SketchMath.from_sheet(uv, plane)
	var normal: Vector3 = (copy.global_transform.basis * (plane["n"] as Vector3)).normalized()
	await aim(world + normal * 0.45 + Vector3(0, 0, 0.12), world)


func top_face() -> Dictionary:
	## The box's top face as {body_id, index}.
	var bodies: Array = box.get_meta("body_ids")
	var best := {}
	for i in bodies.size():
		var pl := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(box, str(bodies[i]), int(box.get_meta("face_ids")[i])))
		if not pl.is_empty() and pl["n"].dot(Vector3(0, 0, 1)) > 0.99 and (best.is_empty() or pl["origin"].z > best["z"]):
			best = {"body_id": str(bodies[i]), "index": int(box.get_meta("face_ids")[i]), "z": pl["origin"].z}
	return best


func draw_rectangle() -> void:
	## Opens a sketch on the top face and draws a rectangle in it (a closed shape for Extrude / Revolve / Loft...).
	var top := top_face()
	await ed.begin_sketch({"face": {"body_id": top["body_id"], "index": top["index"]}})
	var c: Vector2 = ed.view.sheet_centre
	table.manager.activate("rectangle")
	await ed.session.tap({"uv": c + Vector2(-30, -20), "id": ""})
	await ed.session.tap({"uv": c + Vector2(10, 14), "id": ""})
	table.manager.deactivate()
