extends SceneTree
## The MODIFY category (Phase 6.5), fake backend: Move Face, Delete Face, Move Body, Scale Body, Delete Body. The category is on the console with its own accent;
## each tool picks what it needs (faces of one body / a body / bodies), shows its settings, refuses what the backend would, builds the right create body,
## shows its Build row, and Edit opens it with the row's values (a signed move along an axis included).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_modify.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")


func body(id: String) -> Dictionary:
	return {"kind": "body", "body_id": id, "index": -1, "key": "solid:" + id}


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	ed.preview_enabled = false
	var cat = table.registry.category("modify")
	print("SMOKE the Modify category is on the console with the five tools and the shared tab accent: ", cat != null and cat.tools.map(func(t): return t.id) == ["move_face", "delete_face", "move_body", "scale_body", "delete_body"] and cat.accent == TableTools.ACCENT_MODIFY)
	table.ui.select_category("modify")
	await rig.frames(2)
	# Move Face
	table.manager.activate("move_face")
	await rig.frames(3)
	print("SMOKE Move Face picks faces and lists Distance, Reverse, Clear, Apply (off): ", ed.state == "pick_faces" and table.props.option_ids() == ["mf_dir_normal", "mf_dir_x", "mf_dir_y", "mf_dir_z", "mf_offset", "mf_flip", "clear_faces", "apply"] and table.props.option_button("apply").disabled)
	print("SMOKE ...with no face it refuses: ", not ed.tools["move_face"].request(ed)["ok"])
	ed.faces = [{"kind": "face", "body_id": "body_box", "index": 3, "key": "body_box:3"}]
	ed.option_typed("mf_offset", "8")
	await ed.on_option("mf_flip")
	var req: Dictionary = ed.tools["move_face"].request(ed)
	print("SMOKE a face and 8 mm reversed is move-face-features with offset_distance -8: ", req["ok"] and req["route"] == "move-face-features" and req["body"] == {"face_refs": [{"body_id": "body_box", "shape_type": "face", "index": 3}], "offset_distance": -8.0}, " ", req["body"])
	print("SMOKE ...its PATCH nulls the other modes' fields: ", ed.tools["move_face"].patch_body(req).get("delta", 1) == null and ed.tools["move_face"].patch_body(req).get("direction_ref", 1) == null)
	await ed.apply_feature()
	print("SMOKE Apply sends it: ", not rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/move-face-features").is_empty())
	# Delete Face
	table.manager.activate("delete_face")
	await rig.frames(2)
	ed.faces = [{"kind": "face", "body_id": "body_box", "index": 2, "key": "body_box:2"}]
	req = ed.tools["delete_face"].request(ed)
	print("SMOKE Delete Face sends delete-face-features with the face refs: ", req["ok"] and req["body"] == {"face_refs": [{"body_id": "body_box", "shape_type": "face", "index": 2}]})
	# Move Body
	table.manager.activate("move_body")
	await rig.frames(2)
	print("SMOKE Move Body picks one body and lists X, Y, Z, Make a copy, Clear, Apply: ", ed.state == "pick_bodies" and ed.body_limit == 1 and table.props.option_ids() == ["mb_dx", "mb_dy", "mb_dz", "mb_copy", "clear_bodies", "apply"])
	ed.bodies = [body("body_box")]
	print("SMOKE ...a move of nothing is refused: ", not ed.tools["move_body"].request(ed)["ok"])
	ed.option_typed("mb_dx", "-12.5")
	ed.option_typed("mb_dz", "0")
	await ed.on_option("mb_copy")
	req = ed.tools["move_body"].request(ed)
	print("SMOKE a NEGATIVE X is accepted (signed settings) and the body is {body_id, delta [-12.5, 0, 0], make_copy true}: ", req["ok"] and req["body"] == {"body_id": "body_box", "delta": [-12.5, 0.0, 0.0], "make_copy": true}, " ", req["body"])
	ed.option_typed("mb_dx", "abc")
	print("SMOKE ...text is refused: ", ed.options["mb_dx"] == -12.5)
	# Scale Body
	table.manager.activate("scale_body")
	await rig.frames(2)
	ed.bodies = [body("body_box")]
	ed.option_typed("sb_factor", "0.5")
	req = ed.tools["scale_body"].request(ed)
	print("SMOKE Scale Body sends scale-body-features with the factor: ", req["ok"] and req["body"] == {"body_id": "body_box", "factor": 0.5})
	ed.option_typed("sb_factor", "-2")
	print("SMOKE ...a negative factor is refused: ", ed.options["sb_factor"] == 0.5)
	# Delete Body
	table.manager.activate("delete_body")
	await rig.frames(2)
	ed.bodies = [body("body_box"), body("body_top")]
	req = ed.tools["delete_body"].request(ed)
	print("SMOKE Delete Body (any number) sends delete-body-features: ", ed.body_limit == 0 and req["ok"] and req["body"] == {"body_ids": ["body_box", "body_top"]})
	# Build rows and Edit
	print("SMOKE the Build rows read: ", BuildTree.summary([{"type": "move_face", "face_refs": [{}, {}], "offset_distance": -8.0}], 0) == "2 face(s) by -8 mm" and BuildTree.summary([{"type": "delete_face", "face_refs": [{}]}], 0) == "1 face(s)" and BuildTree.summary([{"type": "move_body", "delta": [-12.5, 0, 0], "make_copy": true}], 0) == "by (-12.5, 0, 0), copy" and BuildTree.summary([{"type": "scale_body", "factor": 0.5}], 0) == "x 0.5" and BuildTree.summary([{"type": "delete_body", "body_ids": ["a", "b"]}], 0) == "2 bodies", " ", BuildTree.summary([{"type": "move_body", "delta": [-12.5, 0, 0], "make_copy": true}], 0))
	table.manager.deactivate()
	fake.feature_rows["PART_BOX"] = [{"id": "mb1", "type": "move_body", "body_id": "body_box", "delta": [3.0, -4.0, 5.0], "make_copy": false}]
	await table.build.reload()
	print("SMOKE a move-body row offers Edit: ", table.build.can_edit("mb1"))
	await ed.begin_tool_edit("mb1")
	await rig.frames(2)
	print("SMOKE Edit opens Move Body with the row's X, Y, Z: ", ed.options["mb_dx"] == 3.0 and ed.options["mb_dy"] == -4.0 and ed.options["mb_dz"] == 5.0 and ed.body_refs() == ["body_box"])
	ed.option_typed("mb_dy", "-6")
	await ed.apply_feature()
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/move-body-features/mb1")
	print("SMOKE Apply PATCHes the move (Y now -6) and Undo restores the old delta: ", patched.size() == 1 and patched[0][1]["delta"] == [3.0, -6.0, 5.0])
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/move-body-features/mb1")
	print("SMOKE ...Undo: ", patched.size() == 2 and patched[1][1]["delta"] == [3.0, -4.0, 5.0])
	quit()
