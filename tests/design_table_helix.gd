extends SceneTree
## HELIX TOOL (milestone 4), fake backend: the Create group has Helix (id "helix", the backend's feature type is "curve"); it lists its settings (radius, taper, segments, hand, plane), turns them
## into the exact curve-features body (a constant radius, an end radius, a taper angle: only one of those; segments with pitch and turns; left-handed; a negative pitch), refuses what the backend
## would refuse, shows the other taper quantity read-only, stands on a picked plane, previews as an eager feature, Apply makes one curve, and the Build row's Edit loads the helix (an
## intersection curve is not offered Edit) and PATCHes the curve-features route.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_helix.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")


func posts(rig) -> Array:
	return rig.fake.calls.filter(func(c): return c[0] == "POST /document/parts/PART_BOX/curve-features")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	fake.track_rows = true
	ed.preview_enabled = false

	var create: Array = TableTools.FEATURE_GROUPS.filter(func(g): return g[0] == "create")
	print("SMOKE the Create group holds Helix after Sweep: ", create[0][3] == ["extrude", "revolve", "loft", "sweep", "helix", "create_plane"])
	print("SMOKE ...Helix has an icon, a hint and a feature tool that makes the 'curve' type: ", TableTools.HINTS.has("helix") and UiIcons.has_icon("tool_helix") and FeatureTools.make_all().has("helix") and FeatureTools.for_type("curve").id == "helix" and BuildTree.label("curve") == "Curve" and UiIcons.has_icon(BuildTree.glyph("curve")))

	table.manager.activate("helix")
	await rig.frames(3)
	var ids: Array = table.props.option_ids()
	print("SMOKE choosing Helix goes to plane picking and lists the radius, the taper, a segment's pitch and turns, Add segment, the hand, the plane and Apply: ", ed.state == "pick_plane" and ids == ["h_radius", "h_taper", "h_pitch_0", "h_turns_0", "h_add", "h_hand", "h_plane", "apply"], " ", ids)
	var tool = ed.tools["helix"]
	var req: Dictionary = tool.request(ed)
	print("SMOKE ...the default request is a constant-radius, right-handed 5 mm helix of one segment (pitch 2, 3 turns) on XY: ", req["ok"] and req["route"] == "curve-features" and req["body"] == {"curve_type": "helix", "axis_ref": {"fixed_plane": "XY"}, "radius": 5.0, "segments": [{"pitch": 2.0, "turns": 3.0}], "right_handed": true}, " ", req["body"])
	print("SMOKE ...it previews as an eager feature (there is no coarse route) and the height shows on Apply: ", tool.preview_mode() == "eager" and table.props.option_button("apply").text == "Apply (height 6 mm)")

	# taper
	await ed.on_option("h_taper")
	ids = table.props.option_ids()
	print("SMOKE Taper cycles to 'end radius': a value row and the angle it gives, read-only: ", ids.has("h_taper_value") and ids.has("h_taper_info") and table.props.option_button("h_taper_info").disabled and table.props.option_button("h_taper").text == "Taper: end radius" and table.props.option_button("h_taper_info").text == "= 26.57 deg", " ", table.props.option_button("h_taper_info").text)
	tool.type_value(ed, "h_taper_value", "8")
	req = tool.request(ed)
	print("SMOKE ...an end radius of 8 is sent as end_radius only: ", req["body"].get("end_radius") == 8.0 and not req["body"].has("taper_angle_degrees"))
	tool.type_value(ed, "h_taper_value", "0")
	print("SMOKE ...an end radius of 0 is refused (still 8): ", req["body"]["end_radius"] == 8.0 and tool.request(ed)["body"]["end_radius"] == 8.0 and table.status().contains("bigger than zero"))
	await ed.on_option("h_taper")
	req = tool.request(ed)
	print("SMOKE Taper again is 'angle' (10): sent as taper_angle_degrees only, and the read-only line gives the end radius: ", req["body"].get("taper_angle_degrees") == 10.0 and not req["body"].has("end_radius") and table.props.option_button("h_taper_info").text == "= end radius 5.00 mm".replace("5.00", "6.06"), " ", table.props.option_button("h_taper_info").text)
	tool.type_value(ed, "h_taper_value", "-20")
	print("SMOKE ...a negative angle (narrowing) is accepted, 90 is refused: ", tool.request(ed)["body"]["taper_angle_degrees"] == -20.0)
	tool.type_value(ed, "h_taper_value", "90")
	print("SMOKE ...(still -20): ", tool.request(ed)["body"]["taper_angle_degrees"] == -20.0)
	await ed.on_option("h_taper")
	req = tool.request(ed)
	print("SMOKE Taper back to none sends neither: ", not req["body"].has("end_radius") and not req["body"].has("taper_angle_degrees") and not table.props.option_ids().has("h_taper_value"))

	# segments
	tool.type_value(ed, "h_radius", "10")
	await ed.on_option("h_add")
	await ed.on_option("h_add")
	tool.type_value(ed, "h_pitch_1", "6")
	tool.type_value(ed, "h_turns_1", "3")
	tool.type_value(ed, "h_turns_0", "2")
	tool.type_value(ed, "h_turns_2", "2")
	tool.type_value(ed, "h_pitch_2", "2")
	req = tool.request(ed)
	print("SMOKE a spring of three segments (2 x 2, 6 x 3, 2 x 2) is sent in order, height 26: ", req["body"]["segments"] == [{"pitch": 2.0, "turns": 2.0}, {"pitch": 6.0, "turns": 3.0}, {"pitch": 2.0, "turns": 2.0}] and req["body"]["radius"] == 10.0 and table.props.option_button("apply").text == "Apply (height 26 mm)", " ", req["body"]["segments"])
	print("SMOKE ...every segment has Remove, and Add segment repeats the last pitch at 1 turn: ", table.props.option_ids().has("h_del_2") and table.props.option_ids().has("h_pitch_2"))
	await ed.on_option("h_del_1")
	req = tool.request(ed)
	print("SMOKE Remove segment 2 leaves the other two: ", (req["body"]["segments"] as Array).size() == 2 and table.props.option_button("apply").text == "Apply (height 8 mm)")
	await ed.on_option("h_del_1")
	print("SMOKE ...the last segment cannot be removed (no Remove row): ", not table.props.option_ids().has("h_del_0") and (tool.request(ed)["body"]["segments"] as Array).size() == 1)
	tool.type_value(ed, "h_pitch_0", "0")
	print("SMOKE a pitch of 0 is refused: ", tool.request(ed)["body"]["segments"][0]["pitch"] == 2.0)
	tool.type_value(ed, "h_turns_0", "0")
	print("SMOKE ...so are 0 turns: ", tool.request(ed)["body"]["segments"][0]["turns"] == 2.0)
	tool.type_value(ed, "h_radius", "-1")
	print("SMOKE ...and a negative radius: ", tool.request(ed)["body"]["radius"] == 10.0)
	tool.type_value(ed, "h_radius", "abc")
	print("SMOKE ...and text: ", tool.request(ed)["body"]["radius"] == 10.0)

	# hand and direction
	await ed.on_option("h_hand")
	print("SMOKE Right-handed off sends a left-handed request: ", tool.request(ed)["body"]["right_handed"] == false and not table.props.option_button("h_hand").button_pressed)
	await ed.on_option("h_hand")
	tool.type_value(ed, "h_pitch_0", "-2")
	print("SMOKE a negative pitch goes the other way along the axis and is sent as it is: ", tool.request(ed)["body"]["segments"][0]["pitch"] == -2.0 and table.props.option_button("apply").text == "Apply (height 4 mm)")
	print("SMOKE ...but segments that go different ways are refused with a reason (Apply greyed): ", PartFeatures.helix_request({"radius": 5.0, "taper": "none", "taper_value": 0.0, "segments": [{"pitch": 2.0, "turns": 1.0}, {"pitch": -2.0, "turns": 1.0}], "right_handed": true}, {})["error"].contains("same way"))
	tool.type_value(ed, "h_pitch_0", "2")

	# a plane
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	req = tool.request(ed)
	print("SMOKE a picked reference plane is the axis plane: ", req["body"]["axis_ref"] == {"fixed_plane": "XZ"} and table.props.option_button("h_plane").text == "Plane: XZ plane", " ", req["body"]["axis_ref"])

	# apply
	await ed.apply_feature()
	var made: Array = posts(rig)
	print("SMOKE Apply makes one curve feature: ", made.size() == 1 and made[0][1]["curve_type"] == "helix" and made[0][1]["axis_ref"] == {"fixed_plane": "XZ"}, " ", made.size())
	var helix_id: String = ed.feature_stack.back()
	print("SMOKE ...its Build row reads the radius, turns, segments and hand and the Build tree draws it: ", BuildTree.summary(table.build.features, table.build.features.size() - 1) == "R 10 mm, 2 turns, 1 segment, right-handed", " ", BuildTree.summary(table.build.features, table.build.features.size() - 1))

	# edit
	var row := {"id": helix_id, "type": "curve", "curve_type": "helix", "axis_ref": {"fixed_plane": "XZ", "face_ref": null, "plane_feature_id": null}, "radius": 10.0, "end_radius": 14.0, "taper_angle_degrees": 25.0,
		"segments": [{"pitch": 2.0, "turns": 2.0}, {"pitch": 6.0, "turns": 3.0}], "right_handed": false, "total_height": 22.0}
	fake.feature_rows["PART_BOX"] = [row]
	await table.build.reload()
	print("SMOKE the Build row of a tapered, left-handed helix: ", BuildTree.summary(table.build.features, 0) == "R 10 to 14 mm, 5 turns, 2 segments, left-handed" and table.build.can_edit(helix_id))
	var intersection := {"id": "crv2", "type": "curve", "curve_type": "intersection", "sketch_feature_id_a": "a", "sketch_feature_id_b": "b"}
	fake.feature_rows["PART_BOX"] = [row, intersection]
	await table.build.reload()
	print("SMOKE ...an intersection curve is not offered Edit (the Helix tool does not make it) and has no helix summary: ", not table.build.can_edit("crv2") and BuildTree.summary(table.build.features, 1) == "")
	table.manager.deactivate()
	await rig.frames(2)
	await ed.begin_tool_edit(helix_id)
	await rig.frames(3)
	print("SMOKE Edit opens Helix with the row's settings (radius 10, end radius 14, two segments, left-handed, XZ): ", table.active_tool == "helix" and not ed.editing.is_empty() and ed.options["h_radius"] == 10.0 and ed.options["h_taper"] == "end_radius" and ed.options["h_taper_value"] == 14.0 and ed.options["h_segments"].size() == 2 and ed.options["h_right"] == false and ed.options["h_plane"] == {"fixed_plane": "XZ"})
	tool.type_value(ed, "h_turns_1", "4")
	await ed.on_option("h_taper")
	await ed.on_option("h_taper")
	await ed.apply_feature()
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/curve-features/" + helix_id)
	print("SMOKE Apply PATCHes the curve-features route (never curve_type), turning the taper off with an explicit end_radius: null: ", patched.size() == 1 and not patched[0][1].has("curve_type") and patched[0][1].has("end_radius") and patched[0][1]["end_radius"] == null and patched[0][1]["segments"][1]["turns"] == 4.0, " ", patched)
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/curve-features/" + helix_id)
	print("SMOKE Undo puts the old values back (the 14 mm end radius, the old turns): ", patched.size() == 2 and patched.back()[1]["end_radius"] == 14.0 and patched.back()[1]["segments"][1]["turns"] == 3.0 and patched.back()[1]["right_handed"] == false)
	quit()
