extends SceneTree
## PATTERN, BOOLEAN, MERGE and SPLIT (Phase 6.4), fake backend, on a part split into two bodies. Pattern: Rectangular / Circular, X / Y / Z or a picked line
## as the direction, count / spacing / reverse, a second direction, circular axis from a picked sketch line, Merge; the coarse preview route; refusals; the Build row
## and Edit. Boolean: target then tool picks (two slots), Subtract / Common, Consume; Merge: two or more bodies; Split: a body and a plane (reference plane or
## made plane). Mates: an edit that ADDS bodies (Pattern) leaves every mate's face where it was, one that CONSUMES a body (Boolean) is seen by mate_health.gd as
## drift on the faces of the consumed body, and notify_edited flags the instances.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_body_features.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const MateHealth := preload("res://scripts/design_table/mate_health.gd")
const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")


func body(id: String) -> Dictionary:
	return {"kind": "body", "body_id": id, "index": -1, "key": "solid:" + id}


func last_post(rig, route: String) -> Array:
	var all: Array = rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/" + route)
	return all.back() if not all.is_empty() else []


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	ed.preview_enabled = false
	fake.coarse_bodies = [{"body_id": "coarse-preview", "source": "coarse", "mesh": {"vertices": [[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], "normals": [[0, 0, -1], [0, 0, -1], [0, 0, -1], [0, 0, -1]], "triangle_indices": [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]], "edges": []}}]
	# two bodies: the top face's triangles become body_top
	var top: Dictionary = rig.top_face()
	var ids: Array = table.table_copy.get_meta("body_ids").duplicate()
	var face_ids: Array = table.table_copy.get_meta("face_ids")
	for i in ids.size():
		if str(ids[i]) == str(top["body_id"]) and int(face_ids[i]) == int(top["index"]):
			ids[i] = "body_top"
	table.table_copy.set_meta("body_ids", ids)
	ed.highlight.invalidate(table.table_copy)

	# --- Pattern, rectangular
	table.manager.activate("pattern")
	await rig.frames(3)
	print("SMOKE choosing Pattern picks bodies (one at most) and lists type, picks, directions, count, spacing, reverse, 2nd direction, merge, Apply: ", ed.state == "pick_bodies" and ed.body_limit == 1 and table.props.option_button("pat_rect") != null and table.props.option_button("pat_dir1_line") != null and table.props.option_button("pat_count1") != null and table.props.option_button("pat_dir2_z") != null and table.props.option_button("apply").disabled)
	print("SMOKE ...with no body it refuses, saying why: ", not ed.tools["pattern"].request(ed)["ok"])
	ed.bodies = [body("body_box")]
	ed._update_options()
	var req: Dictionary = ed.tools["pattern"].request(ed)
	print("SMOKE a body and the default X direction is a valid rectangular pattern (3 x 20 mm): ", req["ok"] and req["route"] == "pattern-features" and req["body"]["direction_1"] == {"fixed_axis": "x"} and req["body"]["count_1"] == 3 and req["body"]["spacing_1"] == 20.0 and req["body"]["merge"] == "keep_separate" and req["body"]["source_body_ids"] == ["body_box"], " ", req["body"])
	ed.option_typed("pat_count1", "5")
	ed.option_typed("pat_spacing1", "12.5")
	await ed.on_option("pat_dir1_z")
	await ed.on_option("pat_rev1")
	await ed.on_option("pat_dir2_y")
	ed.option_typed("pat_count2", "2")
	await ed.on_option("pat_merge")
	req = ed.tools["pattern"].request(ed)
	var b: Dictionary = req["body"]
	print("SMOKE count, spacing, Z, reverse, a second direction Y and Merge all reach the body: ", b["count_1"] == 5 and b["spacing_1"] == 12.5 and b["direction_1"] == {"fixed_axis": "z"} and b["reverse_1"] == true and b["direction_2"] == {"fixed_axis": "y"} and b["count_2"] == 2 and b["merge"] == "fuse_into_one", " ", b)
	print("SMOKE ...the second direction's own settings show only while it is on: ", table.props.option_button("pat_count2") != null)
	await ed.on_option("pat_dir2_none")
	print("SMOKE ...and go with it: ", table.props.option_button("pat_count2") == null and not ed.tools["pattern"].request(ed)["body"].has("direction_2"))
	await ed.on_option("pat_dir1_line")
	print("SMOKE a line direction needs a picked line: ", not ed.tools["pattern"].request(ed)["ok"] and table.props.option_button("apply").disabled)
	ed.curve_picks = [{"kind": "curve", "sketch_feature_id": "s1", "sketch_id": "sk1", "entity_type": "line", "entity_id": "L7", "key": "curve:sk1:L7"}]
	ed._update_options()
	print("SMOKE ...with one it is that sketch line: ", ed.tools["pattern"].request(ed)["body"]["direction_1"] == {"sketch_line_ref": {"sketch_id": "sk1", "entity_type": "line", "entity_id": "L7"}} and not table.props.option_button("apply").disabled)
	await ed.on_option("pick_lines")
	await rig.frames(3)
	print("SMOKE Pick line switches the laser to curves and keeps the body pick: ", ed.state == "pick_curves" and ed.bodies.size() == 1 and ed.curve_picks.size() == 1)
	await ed.on_option("pick_bodies")
	print("SMOKE ...and Pick body switches back, keeping both: ", ed.state == "pick_bodies" and ed.curve_picks.size() == 1)
	ed.preview_enabled = true
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview.is_showing())
	ed.preview_enabled = false
	print("SMOKE the preview POSTs pattern-features/coarse-preview and creates nothing: ", not rig.calls_to("pattern-features/coarse-preview").is_empty() and last_post(rig, "pattern-features").is_empty())
	await ed.apply_feature()
	var made := last_post(rig, "pattern-features")
	print("SMOKE Apply sends pattern-features: ", not made.is_empty() and made[1]["pattern_type"] == "rectangular" and made[1]["direction_1"].has("sketch_line_ref"))
	# --- Circular
	table.manager.deactivate()
	table.manager.activate("pattern")
	await rig.frames(2)
	ed.bodies = [body("body_box")]
	await ed.on_option("pat_circ")
	print("SMOKE Circular shows count, total angle and reverse instead (no spacing), and wants an axis line: ", table.props.option_button("pat_count_ang") != null and table.props.option_button("pat_angle") != null and table.props.option_button("pat_spacing1") == null and not ed.tools["pattern"].request(ed)["ok"])
	ed.curve_picks = [{"kind": "curve", "sketch_feature_id": "s1", "sketch_id": "sk1", "entity_type": "line", "entity_id": "AX", "key": "curve:sk1:AX"}]
	ed.option_typed("pat_count_ang", "6")
	ed.option_typed("pat_angle", "180")
	req = ed.tools["pattern"].request(ed)
	print("SMOKE ...6 over 180 degrees round that line: ", req["ok"] and req["body"]["pattern_type"] == "circular" and req["body"]["axis"] == {"sketch_line_ref": {"sketch_id": "sk1", "entity_type": "line", "entity_id": "AX"}} and req["body"]["count_angular"] == 6 and req["body"]["angle_total"] == 180.0 and req["body"]["reverse_angular"] == false)
	ed.option_typed("pat_angle", "400")
	print("SMOKE ...an angle over 360 is refused: ", ed.options["pat_angle"] == 180.0)
	# row summary and Edit
	var prow := {"id": "pat1", "type": "pattern", "pattern_type": "rectangular", "source_body_ids": ["body_box"], "direction_1": {"fixed_axis": "y"}, "count_1": 4, "spacing_1": 15.0, "reverse_1": true, "direction_2": null, "count_2": 1, "merge": "keep_separate"}
	print("SMOKE the Build rows read: ", BuildTree.summary([prow], 0) == "Rectangular, 4 x 15 mm" and BuildTree.summary([{"type": "pattern", "pattern_type": "circular", "count_angular": 6, "angle_total": 180.0}], 0) == "Circular, 6 over 180 deg", " ", BuildTree.summary([prow], 0))
	table.manager.deactivate()
	fake.feature_rows["PART_BOX"] = [prow]
	await table.build.reload()
	await ed.begin_tool_edit("pat1")
	await rig.frames(2)
	print("SMOKE Edit opens Pattern with the row's settings (Y, 4, 15, reversed, its body): ", ed.options["pat_dir1"] == "y" and ed.options["pat_count1"] == 4.0 and ed.options["pat_spacing1"] == 15.0 and ed.options["pat_rev1"] == true and ed.body_refs() == ["body_box"])
	ed.option_typed("pat_count1", "6")
	await ed.apply_feature()
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/pattern-features/pat1")
	print("SMOKE Apply PATCHes it with count 6 (and Undo restores 4): ", patched.size() == 1 and patched[0][1]["count_1"] == 6)
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/pattern-features/pat1")
	print("SMOKE ...Undo: ", patched.size() == 2 and patched[1][1]["count_1"] == 4)

	# --- Boolean
	fake.feature_rows["PART_BOX"] = []
	table.manager.activate("boolean")
	await rig.frames(3)
	print("SMOKE Boolean picks bodies with Subtract on, Pick target on, Consume on, Apply off: ", ed.state == "pick_bodies" and table.props.option_button("bool_subtract").button_pressed and table.props.option_button("slot_target").button_pressed and table.props.option_button("bool_consume").button_pressed and table.props.option_button("apply").disabled)
	ed.bodies = [body("body_box")]
	await ed.on_option("slot_tool")
	print("SMOKE switching to the tool slot keeps the target and starts an empty tool set: ", ed.bodies.is_empty() and table.props.option_button("slot_target").text == "Pick target (1)")
	ed.bodies = [body("body_top")]
	ed._update_options()
	req = ed.tools["boolean"].request(ed)
	print("SMOKE target box, tool top, Subtract: ", req["ok"] and req["body"] == {"operation": "subtract", "target_body_ids": ["body_box"], "tool_body_ids": ["body_top"], "consume_tool_bodies": true}, " ", req["body"])
	await ed.on_option("bool_common")
	await ed.on_option("bool_consume")
	req = ed.tools["boolean"].request(ed)
	print("SMOKE Common and not consuming reach the body: ", req["body"]["operation"] == "common" and req["body"]["consume_tool_bodies"] == false)
	ed.bodies = [body("body_box")]
	print("SMOKE the same body as target and tool is refused: ", not ed.tools["boolean"].request(ed)["ok"])
	ed.bodies = [body("body_top")]
	# mates around a consumed body
	var node: MeshInstance3D = table.table_copy # (the copy carries the two-body split; the arena node is the box alone)
	node.set_meta("occurrence_id", "occ_box")
	var side_face := -1
	for i in ids.size():
		if str(ids[i]) == "body_box":
			side_face = int(face_ids[i])
			break
	var mates := [{"id": "m1", "references": [{"occurrence_id": str(node.get_meta("occurrence_id")), "subshape_ref": {"body_id": "body_box", "index": side_face, "shape_type": "face"}}]}]
	var captured := MateHealth.capture([node], mates)
	print("SMOKE (mates) a mate on a face of the box body is captured: ", captured.size() == 1)
	var kept_ids: Array = node.get_meta("body_ids").duplicate()
	var added: Array = kept_ids.duplicate()
	added.append_array(kept_ids) # a Pattern adds triangles of new bodies; the old faces are where they were
	print("SMOKE (mates) nothing moved a face: no drift: ", MateHealth.drifted(captured, [node]).is_empty())
	var before_meta: Array = node.get_meta("body_ids")
	var consumed: Array = before_meta.map(func(b): return "gone" if str(b) == "body_box" else b)
	node.set_meta("body_ids", consumed)
	print("SMOKE (mates) a Boolean that consumes that body leaves that mate's face missing: drift reported: ", MateHealth.drifted(captured, [node]).size() == 1)
	node.set_meta("body_ids", before_meta)
	await ed.on_option("bool_consume")
	await ed.on_option("bool_common")
	ed.bodies = [body("body_top")]
	await ed.apply_feature()
	var bm := last_post(rig, "boolean-features")
	print("SMOKE Apply sends boolean-features (the edit goes through notify_edited like every feature, which is what flags mates): ", not bm.is_empty() and bm[1]["tool_body_ids"] == ["body_top"] and bm[1]["operation"] == "common")

	# --- Merge
	table.manager.deactivate()
	table.manager.activate("merge")
	await rig.frames(2)
	ed.bodies = [body("body_box")]
	ed._update_options()
	print("SMOKE Merge needs two bodies: ", table.props.option_button("apply").disabled and not ed.tools["merge"].request(ed)["ok"])
	ed.bodies = [body("body_box"), body("body_top")]
	ed._update_options()
	req = ed.tools["merge"].request(ed)
	print("SMOKE ...two make merge-features with both ids: ", req["ok"] and req["body"] == {"body_ids": ["body_box", "body_top"]} and not table.props.option_button("apply").disabled)

	# --- Split
	table.manager.deactivate()
	table.manager.activate("split")
	await rig.frames(2)
	ed.bodies = [body("body_box")]
	ed._update_options()
	print("SMOKE Split needs a plane as well as a body: ", table.props.option_button("apply").disabled)
	await ed.on_option("slot_plane")
	print("SMOKE Pick plane switches the laser to plane picking: ", ed.state == "pick_plane")
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	req = ed.tools["split"].request(ed)
	print("SMOKE a pull on a reference plane is the split plane: ", req["ok"] and req["body"] == {"target_body_id": "body_box", "tool": {"plane_ref": {"fixed_plane": "XZ"}}} and ed.state == "pick_plane", " ", req["body"])
	await ed.apply_feature()
	print("SMOKE Apply sends split-features: ", not last_post(rig, "split-features").is_empty())
	print("SMOKE the Build rows of Boolean, Merge and Split read: ", BuildTree.summary([{"type": "boolean", "operation": "common", "target_body_ids": ["a"], "tool_body_ids": ["b", "c"]}], 0) == "Common, 1 target(s) with 2 tool(s)" and BuildTree.summary([{"type": "merge", "body_ids": ["a", "b"]}], 0) == "2 bodies" and BuildTree.summary([{"type": "split", "tool": {"plane_ref": {"fixed_plane": "XZ"}}}], 0) == "along XZ plane")
	quit()
