extends SceneTree
## SPRING TOOL, fake backend: the Create group has Spring after Helix (id "spring", the backend's feature type "spring"); it lists its settings (mean
## diameter, wire, free length, active coils, each end cycling closed-and-ground / closed / open, hand, plane), turns them into the exact
## spring-features body, refuses what makes no spring (a wire as thick as the spring, under one coil) with the reason on Apply, stands on a
## picked plane, previews as an eager feature, Apply makes one spring, and the Build row reads and edits it (PATCH, Undo).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_spring.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const CadApi := preload("res://scripts/design_table/cad_api.gd")


func posts(rig) -> Array:
	return rig.fake.calls.filter(func(c): return c[0] == "POST /document/parts/PART_BOX/spring-features")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	fake.track_rows = true
	ed.preview_enabled = false

	var create: Array = TableTools.FEATURE_GROUPS.filter(func(g): return g[0] == "create")
	print("SMOKE the Create group holds Spring after Helix: ", (create[0][3] as Array).find("spring") == (create[0][3] as Array).find("helix") + 1)
	print("SMOKE ...Spring has an icon, a hint and a feature tool for the 'spring' type, labelled Spring in the Build tree: ", TableTools.HINTS.has("spring") and UiIcons.has_icon("tool_spring") and FeatureTools.make_all().has("spring") and FeatureTools.for_type("spring").id == "spring" and BuildTree.label("spring") == "Spring" and BuildTree.glyph("spring") == "tool_spring")

	table.manager.activate("spring")
	await rig.frames(3)
	var ids: Array = table.props.option_ids()
	print("SMOKE choosing Spring goes to plane picking and lists the mean diameter, wire, free length, coils, both ends, the hand, the plane and Apply: ", ed.state == "pick_plane" and ids == ["s_mean", "s_wire", "s_length", "s_coils", "s_start", "s_finish", "s_hand", "s_plane", "apply"], " ", ids)
	var tool = ed.tools["spring"]
	var req: Dictionary = tool.request(ed)
	print("SMOKE ...the default is a 10 mm spring of 1 mm wire, 20 mm long, 5 coils, closed and ground both ends, right-handed, on the default plane: ", req["ok"] and req["route"] == "spring-features" and req["body"] == {"mean_diameter": 10.0, "wire_diameter": 1.0, "free_length": 20.0, "active_coils": 5.0, "start_end": "closed_ground", "finish_end": "closed_ground", "right_handed": true}, " ", req["body"])
	print("SMOKE ...an eager preview: ", tool.preview_mode() == "eager")

	# the ends cycle closed-and-ground, closed, open
	await ed.on_option("s_finish")
	print("SMOKE Finish end cycles to closed: ", tool.request(ed)["body"]["finish_end"] == "closed" and table.props.option_button("s_finish").text == "Finish end: closed")
	await ed.on_option("s_finish")
	print("SMOKE ...then open: ", tool.request(ed)["body"]["finish_end"] == "open")
	await ed.on_option("s_finish")
	print("SMOKE ...then back to closed and ground: ", tool.request(ed)["body"]["finish_end"] == "closed_ground")

	# numbers
	ed.option_typed("s_wire", "0.3")
	ed.option_typed("s_coils", "10")
	req = tool.request(ed)
	print("SMOKE the bug report's 0.3 mm wire, 10 coils, is sent as typed: ", req["body"]["wire_diameter"] == 0.3 and req["body"]["active_coils"] == 10.0)
	ed.option_typed("s_wire", "10")
	req = tool.request(ed)
	print("SMOKE a wire as thick as the spring is refused, the reason on the greyed Apply: ", not req["ok"] and not tool.can_apply(ed) and table.props.option_button("apply").disabled and table.props.option_button("apply").text.contains("bigger than the wire"), " ", table.props.option_button("apply").text)
	ed.option_typed("s_wire", "0.3")
	ed.option_typed("s_coils", "0.5")
	print("SMOKE ...and under one coil: ", not tool.request(ed)["ok"] and tool.request(ed)["error"].contains("1 active coil"))
	ed.option_typed("s_coils", "10")
	ed.option_typed("s_length", "-5")
	print("SMOKE ...a negative length is not taken: ", tool.request(ed)["body"]["free_length"] == 20.0)
	await ed.on_option("s_hand")
	print("SMOKE Right-handed off sends a left-handed spring: ", tool.request(ed)["body"]["right_handed"] == false)

	# a plane
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	req = tool.request(ed)
	print("SMOKE a picked reference plane is the plane it stands on: ", req["body"].get("plane_ref") == {"fixed_plane": "XZ"} and table.props.option_button("s_plane").text == "Plane: XZ plane", " ", req["body"].get("plane_ref"))

	# apply
	await ed.apply_feature()
	var made: Array = posts(rig)
	print("SMOKE Apply makes one spring: ", made.size() == 1 and made[0][1]["wire_diameter"] == 0.3 and made[0][1]["right_handed"] == false, " ", made.size())

	# the Build row and Edit
	var row := {"id": "spr1", "type": "spring", "plane_ref": {"fixed_plane": "XZ", "face_ref": null, "plane_feature_id": null}, "mean_diameter": 8.0, "wire_diameter": 0.8,
		"free_length": 30.0, "active_coils": 9.0, "start_end": "closed", "finish_end": "open", "right_handed": false, "active_pitch": 3.1, "total_coils": 10.0, "solid_length": 8.4}
	fake.feature_rows["PART_BOX"] = [row]
	await table.build.reload()
	print("SMOKE the Build row reads the spring: ", BuildTree.summary(table.build.features, 0) == "D 8 x 0.8 wire, 30 long, 9 coils, closed / open" and table.build.can_edit("spr1"), " ", BuildTree.summary(table.build.features, 0))
	table.manager.deactivate()
	await rig.frames(2)
	await ed.begin_tool_edit("spr1")
	await rig.frames(3)
	print("SMOKE Edit opens Spring with the row's numbers: ", table.active_tool == "spring" and not ed.editing.is_empty() and ed.options["s_mean"] == 8.0 and ed.options["s_wire"] == 0.8 and ed.options["s_start"] == "closed" and ed.options["s_finish"] == "open" and ed.options["s_right"] == false)
	ed.option_typed("s_length", "35")
	await ed.apply_feature()
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/spring-features/spr1")
	print("SMOKE Apply PATCHes the spring-features route with the new length: ", patched.size() == 1 and patched[0][1]["free_length"] == 35.0 and patched[0][1]["start_end"] == "closed", " ", patched)
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/spring-features/spr1")
	print("SMOKE Undo puts the old length back: ", patched.size() == 2 and patched.back()[1]["free_length"] == 30.0)
	var refusal := {"detail": {"type": "invalid_spring_parameters", "detail": "the free length is too short: 7 active coils of 1 mm wire close up solid at 6.500 mm"}}
	print("SMOKE a spring the backend refuses is reported in its own words (the solid length), not as an error type: ", CadApi.error_text(refusal).contains("close up solid at 6.500 mm"))
	quit()
