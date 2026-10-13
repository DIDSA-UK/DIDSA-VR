extends SceneTree
## Phase 7.2's small tool options, fake backend, through the real editor: Chamfer angle and flip (edge_options for every picked edge, Edit loads and clears it, per-edge
## values from the flat app are kept), Move Face along X / Y / Z (direction_ref and direction_distance, Edit switches modes with the other fields nulled), Pattern skipped
## instances (typed list, checked against the instance count) and the circular orientation mode, and Loft's thin wall (a wall, the closed-profile switch, an explicit null to turn it off).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_small_options.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const PatternTool := preload("res://scripts/design_table/features/pattern_tool.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")


func edge(i: int) -> Dictionary:
	return {"kind": "edge", "body_id": "body_box", "index": i, "key": "edge:body_box:%d" % i}


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	ed.preview_enabled = false

	# --- Chamfer angle and flip
	table.manager.activate("chamfer")
	await rig.frames(3)
	var ch = ed.tools["chamfer"]
	ed.edges = [edge(3), edge(5)]
	ed._update_options()
	var req: Dictionary = ch.request(ed)
	print("SMOKE Chamfer with no angle is the plain symmetric one (no edge_options): ", req["ok"] and not req["body"].has("edge_options") and req["body"]["distance"] == 2.0)
	print("SMOKE ...Angle is a toggle that adds the angle value and Flip: ", table.props.option_ids() == ["ch_angle_on", "distance", "clear_edges", "apply"])
	await ed.on_option("ch_angle_on")
	await rig.frames(2)
	print("SMOKE ...switching it on lists Angle, the value and Flip: ", table.props.option_ids() == ["ch_angle_on", "ch_flip", "distance", "ch_angle", "clear_edges", "apply"], " ", table.props.option_ids())
	ed.option_typed("ch_angle", "30")
	await ed.on_option("ch_flip")
	req = ch.request(ed)
	print("SMOKE ...every picked edge gets the angle and the flip, keyed by its index in edge_refs: ", req["ok"] and req["body"]["edge_options"] == {"0": {"angle": 30.0, "flip": true}, "1": {"angle": 30.0, "flip": true}}, " ", req["body"])
	ed.option_typed("ch_angle", "90")
	print("SMOKE ...an angle of 90 or more is refused when typed, and 0 is not a number bigger than zero: ", float(ed.options["ch_angle"]) == 30.0)
	ed.option_typed("ch_angle", "0")
	print("SMOKE ...(0 refused too): ", float(ed.options["ch_angle"]) == 30.0)
	print("SMOKE The request builder refuses an angle outside 0 to 90 with a reason: ", not PartFeatures.chamfer_request([PartFeatures.edge_ref("b", 1)], 2.0, 95.0)["ok"] and PartFeatures.chamfer_request([PartFeatures.edge_ref("b", 1)], 2.0, 0.0)["ok"])
	var row := {"type": "chamfer", "id": "c1", "edge_refs": [PartFeatures.edge_ref("body_box", 3), PartFeatures.edge_ref("body_box", 5)], "distance": 3.0,
		"edge_options": {"0": {"angle": 25.0, "flip": true, "face_ref": null}, "1": {"angle": 25.0, "flip": true, "face_ref": null}}}
	ch.load_from_row(ed, row)
	print("SMOKE Edit loads the distance, the two edges and the common angle and flip: ", ed.edges.size() == 2 and float(ed.options["distance"]) == 3.0 and bool(ed.options["ch_angle_on"]) and float(ed.options["ch_angle"]) == 25.0 and bool(ed.options["ch_flip"]) and not bool(ed.options["ch_mixed"]))
	ed.options["ch_angle_on"] = false
	var off: Dictionary = ch.patch_body(ch.request(ed))
	print("SMOKE ...turning the angle off PATCHes an empty edge_options (an omitted one would leave it): ", off.has("edge_options") and (off["edge_options"] as Dictionary).is_empty())
	row["edge_options"]["1"]["angle"] = 40.0
	ch.load_from_row(ed, row)
	req = ch.request(ed)
	print("SMOKE Per-edge angles that differ (made in the flat app) are shown as kept and never sent: ", bool(ed.options["ch_mixed"]) and not req["body"].has("edge_options") and not ch.patch_body(req).has("edge_options") and table.props.option_ids().size() >= 0)
	print("SMOKE ...the Build row says angled: ", BuildTree.summary([row], 0) == "3 mm, 2 edge(s), angled" and ch.edits_in_tool())
	ed.options["ch_mixed"] = false
	ed.options["ch_angle_on"] = false

	# --- Move Face along an axis
	table.manager.activate("move_face")
	await rig.frames(3)
	var mf = ed.tools["move_face"]
	ed.faces = [{"kind": "face", "body_id": "body_box", "index": 2, "key": "body_box:2"}]
	ed._update_options()
	req = mf.request(ed)
	print("SMOKE Move Face defaults to along the face's own normal: ", req["ok"] and req["body"].has("offset_distance") and not req["body"].has("direction_ref"), " ", req["body"])
	await ed.on_option("mf_dir_y")
	await ed.on_option("mf_flip")
	req = mf.request(ed)
	print("SMOKE ...Y and Reverse send direction_ref y and a negative direction_distance, and no offset_distance: ", req["ok"] and req["body"]["direction_ref"] == {"fixed_axis": "y"} and req["body"]["direction_distance"] == -5.0 and not req["body"].has("offset_distance"), " ", req["body"])
	var moved: Dictionary = mf.patch_body(req)
	print("SMOKE ...its PATCH nulls the other modes (offset and delta): ", moved["offset_distance"] == null and moved["delta"] == null and moved["direction_ref"] == {"fixed_axis": "y"})
	await ed.on_option("mf_dir_normal")
	var normal_patch: Dictionary = mf.patch_body(mf.request(ed))
	print("SMOKE ...and back to normal it nulls the direction fields: ", normal_patch["direction_ref"] == null and normal_patch["direction_distance"] == null and normal_patch["delta"] == null and normal_patch.has("offset_distance"))
	mf.load_from_row(ed, {"type": "move_face", "face_refs": [PartFeatures.face_ref("body_box", 2)], "offset_distance": null, "delta": null, "direction_ref": {"fixed_axis": "z", "sketch_line_ref": null}, "direction_distance": 7.0})
	print("SMOKE Edit loads an axis row: Z, 7 mm: ", str(ed.options["mf_dir"]) == "z" and float(ed.options["mf_offset"]) == 7.0 and not bool(ed.options["mf_flip"]))
	mf.load_from_row(ed, {"type": "move_face", "face_refs": [PartFeatures.face_ref("body_box", 2)], "offset_distance": null, "delta": null, "direction_ref": {"fixed_axis": null, "sketch_line_ref": {"sketch_id": "s", "entity_type": "line", "entity_id": "l"}}, "direction_distance": 7.0})
	print("SMOKE ...a row whose direction is a sketch line is shown as made elsewhere and refused with a reason, not overwritten: ", str(ed.options["mf_dir"]) == "line" and not mf.request(ed)["ok"] and str(mf.request(ed)["error"]).contains("sketch line"))
	print("SMOKE ...the Build row names the axis: ", mf.summary({"face_refs": [1], "direction_ref": {"fixed_axis": "x"}, "direction_distance": 4.0}, []) == "1 face(s) by 4 mm along X")
	ed.options["mf_dir"] = "normal"
	ed.options["mf_flip"] = false

	# --- Pattern: skipped instances, circular orientation
	table.manager.activate("pattern")
	await rig.frames(3)
	var pt = ed.tools["pattern"]
	ed.bodies = [{"kind": "body", "body_id": "body_box", "index": -1, "key": "solid:body_box"}]
	ed.option_typed("pat_count1", "5")
	req = pt.request(ed)
	print("SMOKE Pattern always sends skip_indices (an empty list clears an old one on a PATCH): ", req["ok"] and req["body"]["skip_indices"] == [])
	var parsed: Dictionary = PatternTool.parse_skip("2, 4", 5)
	print("SMOKE Typed skips parse '2, 4' and '4 2 2' to sorted lists without repeats: ", parsed["ok"] and parsed["list"] == [2, 4] and PatternTool.parse_skip("4 2 2", 5)["list"] == [2, 4] and PatternTool.parse_skip("", 5)["list"] == [])
	print("SMOKE ...0, the instance count or more, and words are refused with a reason: ", not PatternTool.parse_skip("0", 5)["ok"] and not PatternTool.parse_skip("5", 5)["ok"] and not PatternTool.parse_skip("two", 5)["ok"] and str(PatternTool.parse_skip("9", 5)["error"]).contains("1 to 4"))
	pt.skip_typed(ed, "2 3")
	req = pt.request(ed)
	print("SMOKE ...a good list reaches the body: ", req["body"]["skip_indices"] == [2, 3], " ", ed.options["pat_skip"])
	pt.skip_typed(ed, "9")
	print("SMOKE ...a bad one leaves the list as it was and says why: ", ed.options["pat_skip"] == [2, 3] and table.status().contains("1 to 4"))
	ed.option_typed("pat_count1", "3") # the count dropped below a skipped number: it is left out of the request, not sent invalid
	print("SMOKE ...lowering the count drops numbers that no longer exist from the request: ", pt.request(ed)["body"]["skip_indices"] == [2])
	ed.option_typed("pat_count1", "5")
	print("SMOKE The panel lists Skip (no orientation for a rectangular pattern): ", table.props.option_ids().has("pat_skip") and not table.props.option_ids().has("pat_orient_keep"), " ", table.props.option_button("pat_skip").text)
	ed.options["pat_type"] = "circular"
	ed.curve_picks = [{"kind": "curve", "sketch_feature_id": "S1", "sketch_id": "SK1", "entity_type": "line", "entity_id": "L1", "key": "k"}]
	ed._update_options()
	await ed.on_option("pat_orient_keep")
	req = pt.request(ed)
	print("SMOKE A circular pattern sends its orientation mode (Keep angle is maintain_orientation): ", req["ok"] and req["body"]["orientation_mode"] == "maintain_orientation", " ", req["body"])
	print("SMOKE ...Rotate and Keep angle are offered for a circular pattern only: ", table.props.option_ids().has("pat_orient_rotate") and table.props.option_ids().has("pat_orient_keep"))
	pt.load_from_row(ed, {"pattern_type": "circular", "source_body_ids": ["body_box"], "count_angular": 6, "angle_total": 360.0, "skip_indices": [3], "orientation_mode": "maintain_orientation", "direction_1": null, "direction_2": null, "axis": null, "merge": "keep_separate"})
	print("SMOKE Edit loads the skipped numbers and the orientation: ", ed.options["pat_skip"] == [3] and str(ed.options["pat_orient"]) == "maintain_orientation")
	ed.options["pat_type"] = "rectangular"
	ed.options["pat_skip"] = []
	ed.options["pat_orient"] = "rotate_with_pattern"

	# --- Loft thin wall
	var lo = ed.tools["loft"]
	req = PartFeatures.loft_request(["a", "b"], true, false, [])
	print("SMOKE A plain loft sends no wall: ", req["ok"] and not req["body"].has("thickness"))
	req = PartFeatures.loft_request(["a", "b"], true, false, [], 1.5, true)
	print("SMOKE A thin loft sends the wall and whether it comes from the closed profiles: ", req["body"]["thickness"] == 1.5 and req["body"]["thin_from_closed_profile"] == true)
	ed.options["lo_thin"] = true
	ed.options["lo_wall"] = 2.0
	lo.load_from_row(ed, {"sections": [{"sketch_feature_id": "A"}, {"sketch_feature_id": "B"}], "mode": "boss", "ruled": false, "thickness": null, "thin_from_closed_profile": false})
	print("SMOKE Edit of a solid loft loads the wall as off: ", not bool(ed.options["lo_thin"]) and lo.options(ed).filter(func(o): return o["id"] == "lo_wall").is_empty())
	var off_body: Dictionary = lo.patch_body({"ok": true, "body": {"sections": [], "mode": "boss", "ruled": false}})
	print("SMOKE ...turning a wall off PATCHes thickness: null: ", off_body.has("thickness") and off_body["thickness"] == null)
	lo.load_from_row(ed, {"sections": [{"sketch_feature_id": "A"}, {"sketch_feature_id": "B"}], "mode": "boss", "ruled": false, "thickness": -1.5, "thin_from_closed_profile": true})
	print("SMOKE Edit of a thin loft loads the wall (as a positive number) and its source: ", bool(ed.options["lo_thin"]) and float(ed.options["lo_wall"]) == 1.5 and bool(ed.options["lo_closed"]))
	print("SMOKE ...the Build row says thin wall: ", lo.summary({"mode": "boss", "sections": [1, 2], "ruled": false, "thickness": 1.5}, []) == "Boss, 2 sections, thin wall")
	quit()
