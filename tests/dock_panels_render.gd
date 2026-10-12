extends SceneTree
## NEEDS A REAL RENDER, not --headless (Xvfb + llvmpipe, same recipe as tests/design_table_render.gd):
##   TABLE_RENDER_DIR=/tmp/dock xvfb-run -a "$GODOT" --path . --script res://tests/dock_panels_render.gd
## Picture-only (a human reads the PNGs; not run by ci_render.sh). Puts the box-and-cylinder fixture on the design table with the fake backend,
## opens a sketch on the top face and draws a rectangle, then activates each tool in turn and saves two PNGs per tool: the whole console
## and a close-up of the Properties panel (or, for a tool with no settings, of the deck), named NN_category_tool.png / NN_category_tool_panel.png.
## DOCK_MODE=before names the files before_<tool>.png and covers only Extrude, Fillet and Mirror (the deck's old options row, kept for comparison).
## GL-compatibility software render, not a headset view: a layout smoke test.

const Fake := preload("res://tests/helpers/fake_cad.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")

var _main: Node
var _table
var _eye: Camera3D
var _cam: XRCamera3D
var _dir := ""
var _saved := 0


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1280, 720))
	_main = load("res://scenes/main.tscn").instantiate()
	_main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(_main)
	await process_frame
	UiFeedback.reduce_motion = true
	var origin: XROrigin3D = _main.get_node("XROrigin3D")
	_cam = origin.get_node("XRCamera3D")
	_cam.position = Vector3(0, 1.6, 0)
	origin.get_node("LeftController").position = Vector3(-0.5, 1.0, -0.2)
	origin.get_node("RightController").position = Vector3(1.0, 1.5, 1.0)
	_main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/topology_box_cylinder.glb"), "", 0.001)
	await process_frame
	var box: MeshInstance3D = null
	for p in get_nodes_in_group("grabbable_parts"):
		if p.get_meta("occurrence_id", "") == "occ_box":
			box = p
	var owner_id := str(box.get_meta("owner_part_id", "ASM"))
	_table = _main.design_table
	var fake := Fake.new()
	fake.occurrences = {owner_id: [{"id": "occ_box", "resolved_part_id": "PART_BOX"}, {"id": "occ_cyl", "resolved_part_id": "PART_CYL"}]}
	fake.plane_for = func(body: Dictionary) -> Dictionary:
		var ref: Dictionary = body["face_refs"][0]["face_ref"]
		var pl := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(_table.table_copy, ref["body_id"], int(ref["index"])))
		return {"origin": [pl["origin"].x, pl["origin"].y, pl["origin"].z], "normal": [pl["n"].x, pl["n"].y, pl["n"].z],
			"x_axis": [pl["x"].x, pl["x"].y, pl["x"].z], "y_axis": [pl["y"].x, pl["y"].y, pl["y"].z]}
	_table.editor.api = fake
	fake.feature_rows = {"PART_BOX": []}
	_eye = Camera3D.new()
	_eye.fov = 75.0
	_main.add_child(_eye)
	_eye.make_current()
	_table.open()
	_table.seat(box)
	for i in 60:
		await process_frame
		if _table.editor.state == "pick_plane":
			break
	_dir = OS.get_environment("TABLE_RENDER_DIR")
	var top := {}
	var bodies: Array = box.get_meta("body_ids")
	for i in bodies.size():
		var pl := SketchMath.plane_from_face_triangles(TopologyPick.face_triangles(box, str(bodies[i]), int(box.get_meta("face_ids")[i])))
		if not pl.is_empty() and pl["n"].dot(Vector3(0, 0, 1)) > 0.99 and (top.is_empty() or pl["origin"].z > top["plane"]["origin"].z):
			top = {"body_id": str(bodies[i]), "index": int(box.get_meta("face_ids")[i]), "plane": pl}
	await _table.editor.begin_sketch({"face": {"body_id": top["body_id"], "index": top["index"]}})
	var ed = _table.editor
	var c: Vector2 = ed.view.sheet_centre
	_table.manager.activate("rectangle")
	await ed.session.tap({"uv": c + Vector2(-30, -20), "id": ""})
	await ed.session.tap({"uv": c + Vector2(10, 14), "id": ""})
	_table.manager.deactivate()

	if OS.get_environment("DOCK_MODE") == "before":
		for t in ["extrude", "fillet", "mirror"]:
			await _shoot("before_" + t, "feature", t, false)
	else:
		var n := 0
		for cat in [["sketch", TableTools.SKETCH_TOOLS + TableTools.CONSTRAIN_TOOLS], ["feature", TableTools.FEATURE_TOOLS], ["modify", TableTools.MODIFY_TOOLS]]:
			for t in cat[1]:
				n += 1
				await _shoot("%02d_%s_%s" % [n, cat[0], t[0]], str(cat[0]), str(t[0]), true)
	if OS.get_environment("DOCK_MODE") != "before": # Extrude with its optional groups switched on (7.1), the longest the panel gets for it
		ed.options["ext_thin"] = true
		await _shoot("90_extrude_thin", "feature", "extrude", true)
		ed.options["ext_thin"] = false
		ed.options["ext_draft"] = true
		await _shoot("91_extrude_draft", "feature", "extrude", true)
		ed.options["ext_draft"] = false
		ed.options["ch_angle_on"] = true
		await _shoot("92_chamfer_angle", "feature", "chamfer", true)
		ed.options["ch_angle_on"] = false
		ed.options["lo_thin"] = true
		await _shoot("93_loft_thin", "feature", "loft", true)
		ed.options["lo_thin"] = false
		ed.options["pat_type"] = "circular"
		await _shoot("94_pattern_circular", "feature", "pattern", true)
		ed.options["pat_type"] = "rectangular"
	print("SMOKE dock render saved %d pictures" % _saved)
	quit()


func _look_at_console() -> void:
	_eye.global_position = _cam.global_position + Vector3(0.0, 0.0, 0.1)
	_eye.look_at(_table.global_position + Vector3(0.0, 0.12, 0.0))


func _shoot(name: String, category: String, tool_id: String, with_console: bool) -> void:
	_table.ui.select_category(category)
	_table.manager.activate(tool_id)
	for i in 6:
		await process_frame
	await create_timer(0.35).timeout
	if _dir == "":
		return
	if with_console:
		_look_at_console()
		await create_timer(0.2).timeout
		root.get_texture().get_image().save_png(_dir.path_join(name + ".png"))
		_saved += 1
	if _table.props.is_open():
		var panel_world: Vector3 = _table.props.global_position
		_eye.global_position = panel_world + _table.props.global_transform.basis.z * 0.5 # the Properties panel, close up
		_eye.look_at(panel_world)
	else:
		var deck_world: Vector3 = _table._deck_quad.global_position
		_eye.global_position = deck_world + _table._deck_quad.global_transform.basis.z * 0.38 # no settings to show: the deck, close up
		_eye.look_at(deck_world)
	await create_timer(0.3).timeout
	root.get_texture().get_image().save_png(_dir.path_join((name + "_panel.png") if with_console else (name + ".png")))
	_saved += 1
	_look_at_console()
