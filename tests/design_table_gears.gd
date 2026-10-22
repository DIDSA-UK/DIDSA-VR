extends SceneTree
## GEAR TOOLS on the design table (gears-and-motion plan M2), fake backend: the deck's Feature tab has a Gears group (Gear, Rack, Bevel); each tool lists its settings and
## the rules for enabling them, turns them into the exact create body and route the backend takes, takes a plane or flat face as where the part stands, shows the circle sizes and
## the centre distance, previews through the coarse route (Gear, Bevel) or as an eager feature (Rack), makes one body per Apply, and the Build row's Edit loads the feature's
## own settings and PATCHes it.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_gears.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const BevelGearTool := preload("res://scripts/design_table/features/bevel_gear_tool.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")


func posts_to(rig, route: String) -> Array:
	## The creates (not the coarse previews, whose path continues) of one feature route.
	return rig.fake.calls.filter(func(c): return c[0] == "POST /document/parts/PART_BOX/" + route)


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	fake.track_rows = true
	ed.preview_enabled = false

	# the deck
	var gear_group: Array = TableTools.FEATURE_GROUPS.filter(func(g): return g[0] == "gears")
	print("SMOKE the Feature tab has a Gears group of Gear, Rack and Bevel: ", gear_group.size() == 1 and gear_group[0][3] == ["gear", "rack", "bevel_gear"])
	print("SMOKE ...each has an icon, a hint and a feature tool: ", ["gear", "rack", "bevel_gear"].all(func(id): return TableTools.HINTS.has(id) and FeatureTools.make_all().has(id)) and ["tool_gear", "tool_rack", "tool_bevel_gear"].all(func(i): return UiIcons.has_icon(i)))
	print("SMOKE ...the Build tree names and draws them: ", BuildTree.label("bevel_gear") == "Bevel Gear" and BuildTree.glyph("gear") == "tool_gear" and BuildTree.glyph("rack") == "tool_rack" and UiIcons.has_icon(BuildTree.glyph("bevel_gear")))

	# Gear: options
	table.manager.activate("gear")
	await rig.frames(3)
	var ids: Array = table.props.option_ids()
	print("SMOKE choosing Gear goes to plane picking and lists External, Internal, the readout, the numbers, Bore, Backlash, Fillet, Shift, Mate teeth, Plane and Apply: ", ed.state == "pick_plane" and ids == ["g_external", "g_internal", "g_info_0", "g_info_1", "g_module", "g_teeth", "g_face", "g_pa", "g_helix", "g_herring", "g_bore", "g_backlash", "g_fillet", "g_shift_auto", "g_mate", "g_plane", "apply"], " ", ids)
	print("SMOKE ...Herringbone is greyed at helix 0 and Apply is on: ", table.props.option_button("g_herring").disabled and not table.props.option_button("apply").disabled)
	print("SMOKE ...the defaults are an external module-2, 20-tooth, 10 mm wide gear with an 8 mm bore: ", ed.options["g_internal"] == false and ed.options["g_module"] == 2.0 and ed.options["g_teeth"] == 20.0 and ed.options["g_face"] == 10.0 and ed.options["g_bore"] == 8.0 and table.props.option_button("g_bore").text.contains("8"))
	var req: Dictionary = ed.tools["gear"].request(ed)
	print("SMOKE ...its request is the gear-features body (a Boss, a new body, the bore, no plane, no outer, auto shift): ", req["ok"] and req["route"] == "gear-features" and req["body"] == {"gear_type": "boss", "is_internal": false, "module": 2.0, "tooth_count": 20, "face_width": 10.0, "pressure_angle_degrees": 20.0,
		"backlash": 0.0, "root_fillet_radius": 0.0, "helix_angle_degrees": 0.0, "herringbone": false, "bore_diameter": 8.0, "target_body_ids": []}, " ", req["body"])
	print("SMOKE ...it previews through the coarse route: ", ed.tools["gear"].preview_mode() == "coarse" and ed.tools["gear"].preview_route() == "gear-features/coarse-preview")

	# typed numbers
	ed.option_typed("g_module", "3")
	ed.option_typed("g_teeth", "30")
	ed.option_typed("g_face", "12")
	print("SMOKE typed module, teeth and width reach the settings: ", ed.options["g_module"] == 3.0 and ed.options["g_teeth"] == 30.0 and ed.options["g_face"] == 12.0)
	ed.option_typed("g_teeth", "12.5")
	print("SMOKE ...a fractional tooth count is refused: ", ed.options["g_teeth"] == 30.0 and table.status().contains("whole"))
	ed.option_typed("g_bore", "0")
	print("SMOKE ...a bore of 0 (none) is accepted, a negative one is not: ", ed.options["g_bore"] == 0.0 and table.props.option_button("g_bore").text.contains("none"))
	ed.option_typed("g_bore", "-2")
	print("SMOKE ...(still none): ", ed.options["g_bore"] == 0.0)
	ed.option_typed("g_helix", "-20")
	print("SMOKE ...a negative helix is the other hand and is accepted; 90 is not: ", ed.options["g_helix"] == -20.0)
	ed.option_typed("g_helix", "90")
	print("SMOKE ...(still -20): ", ed.options["g_helix"] == -20.0 and not table.props.option_button("g_herring").disabled)
	await ed.on_option("g_herring")
	req = ed.tools["gear"].request(ed)
	print("SMOKE a helical herringbone gear sends the angle and the flag: ", req["body"]["helix_angle_degrees"] == -20.0 and req["body"]["herringbone"] == true and req["body"]["tooth_count"] == 30 and req["body"]["module"] == 3.0)
	ed.option_typed("g_helix", "0")
	print("SMOKE ...back at helix 0 the flag is not sent: ", ed.tools["gear"].request(ed)["body"]["herringbone"] == false)
	await ed.on_option("g_pa")
	await ed.on_option("g_pa")
	print("SMOKE the pressure angle cycles 20, 14.5, 25: ", ed.options["g_pa"] == 25.0)
	await ed.on_option("g_pa")
	print("SMOKE ...and back to 20: ", ed.options["g_pa"] == 20.0)
	await ed.on_option("g_shift_auto")
	print("SMOKE turning Auto off shows Shift and sends it: ", table.props.option_ids().has("g_shift") and ed.tools["gear"].request(ed)["body"].get("profile_shift") == 0.0)
	ed.option_typed("g_shift", "-0.4")
	print("SMOKE ...a negative shift is accepted: ", ed.tools["gear"].request(ed)["body"]["profile_shift"] == -0.4)
	await ed.on_option("g_shift_auto")
	print("SMOKE ...Auto again sends no shift: ", not ed.tools["gear"].request(ed)["body"].has("profile_shift"))

	# Internal
	await ed.on_option("g_internal")
	print("SMOKE Internal swaps Bore for Outer, filled with room for a rim, and drops the bore from the body: ", table.props.option_ids().has("g_outer") and not table.props.option_ids().has("g_bore") and ed.options["g_outer"] == 3.0 * (30.0 + 8.0))
	req = ed.tools["gear"].request(ed)
	print("SMOKE ...the body is internal with its outer diameter and a bore of 0: ", req["ok"] and req["body"]["is_internal"] == true and req["body"]["outer_diameter"] == 114.0 and req["body"]["bore_diameter"] == 0.0)
	ed.options["g_outer"] = 0.0
	print("SMOKE ...an internal gear with no outer diameter is refused with a reason: ", not ed.tools["gear"].request(ed)["ok"] and str(ed.tools["gear"].request(ed)["error"]).contains("outer"))
	ed.options["g_outer"] = 114.0
	await ed.on_option("g_external")
	ed.options["g_teeth"] = 2.0
	print("SMOKE fewer than 3 teeth is refused: ", not ed.tools["gear"].request(ed)["ok"])
	ed.options["g_teeth"] = 20.0
	ed.options["g_module"] = 2.0
	ed.options["g_face"] = 10.0

	# readout
	ed.options["g_mate"] = 40.0
	await ed.tools["gear"].preview_aux(ed)
	var lines: Array = ed.tools["gear"].readout(ed.options)
	print("SMOKE the readout gives pitch, tip and root diameters (from the backend's answer) and the centre distance to a 40-tooth gear: ", lines[0] == "Pitch 40  Tip 44  Root 35 mm" and lines[1] == "Centre distance to a 40-tooth gear: 60 mm", " ", lines)
	print("SMOKE ...the preview call was made once, with the gear's own numbers: ", rig.calls_to("POST /document/gear/preview").size() == 1 and rig.calls_to("POST /document/gear/preview")[0][1]["tooth_count"] == 20)
	await ed.tools["gear"].preview_aux(ed)
	print("SMOKE ...asking again for the same numbers does not call again: ", rig.calls_to("POST /document/gear/preview").size() == 1)
	ed.options["g_internal"] = true
	print("SMOKE ...for an internal gear the distance is to a pinion: ", str(ed.tools["gear"].readout(ed.options)[1]).begins_with("Centre distance to a 40-tooth pinion"))
	ed.options["g_internal"] = false
	ed.options["g_mate"] = 20.0

	# Plane pick
	ed._hover_plane = "XZ"
	await ed._pick_plane()
	req = ed.tools["gear"].request(ed)
	print("SMOKE a pull on a reference plane is where the gear stands (plane_ref sent), not a sketch: ", ed.session == null and req["body"].get("plane_ref") == {"fixed_plane": "XZ"} and table.props.option_button("g_plane").text.contains("XZ"))
	var top: Dictionary = rig.top_face()
	ed._hover_plane = ""
	ed._hover_face = {"body_id": top["body_id"], "index": top["index"]}
	await ed._pick_plane()
	print("SMOKE ...a flat face sends face_ref: ", ed.tools["gear"].request(ed)["body"].get("plane_ref", {}).has("face_ref"))
	ed._hover_face = {}
	ed._hover_plane = "plane:PL1"
	fake.feature_rows["PART_BOX"] = [{"id": "PL1", "type": "create_plane", "plane_type": "offset_face", "offset": 5.0, "origin": [0, 0, 5], "normal": [0, 0, 1], "x_axis": [1, 0, 0], "y_axis": [0, 1, 0]}]
	await table.build.reload()
	await ed._pick_plane()
	print("SMOKE ...a made plane sends plane_feature_id: ", ed.tools["gear"].request(ed)["body"].get("plane_ref") == {"plane_feature_id": "PL1"})
	fake.feature_rows["PART_BOX"] = []
	await table.build.reload()

	print("SMOKE the backend's bore refusals are said in words: ", PartFeatures._plain("bore_too_large").contains("too big") and PartFeatures._plain("bore_on_internal_gear").contains("ring") and PartFeatures._plain("invalid_bore").contains("negative"))

	# Coarse preview
	ed.options["g_bore"] = 8.0
	ed.preview_enabled = true
	fake.coarse_bodies = [{"body_id": "g", "source": "computed", "mesh": {"vertices": [[0, 0, 0], [10, 0, 0], [0, 10, 0]], "normals": [[0, 0, 1], [0, 0, 1], [0, 0, 1]], "triangle_indices": [[0, 1, 2]]}}]
	table.manager.deactivate()
	await rig.frames(2)
	table.manager.activate("gear")
	await rig.frames(2)
	await ed.schedule_preview()
	var coarse: Array = rig.calls_to("gear-features/coarse-preview")
	print("SMOKE the preview posts the create body to the gear coarse route and draws it, nothing stored: ", not coarse.is_empty() and coarse[-1][0].contains("?quality=") and coarse[-1][1]["tooth_count"] == 20 and ed.preview.is_showing() and posts_to(rig, "gear-features").is_empty() and ed.preview_feature_id == "")
	ed.preview_enabled = false

	# Apply
	await ed.apply_feature()
	var made: Array = posts_to(rig, "gear-features")
	print("SMOKE Apply makes one gear (new body, no plane since the XY default was reset by choosing the tool again): ", made.size() == 1 and made[0][1]["gear_type"] == "boss" and made[0][1]["target_body_ids"] == [] and not made[0][1].has("plane_ref") and made[0][1]["bore_diameter"] == 8.0, " ", made)
	print("SMOKE ...it is on Undo's stack and can be made again: ", ed.feature_stack.size() == 1 and ed.created_requests[ed.feature_stack[0]]["route"] == "gear-features")
	print("SMOKE ...the Build row reads as an external gear: ", BuildTree.summary([{"type": "gear", "is_internal": false, "tooth_count": 20, "module": 2.0, "helix_angle_degrees": 0.0, "bore_diameter": 8.0}], 0) == "External 20 teeth, module 2, bore 8")
	print("SMOKE ...a helical one says so: ", BuildTree.summary([{"type": "gear", "is_internal": true, "tooth_count": 60, "module": 1.5, "helix_angle_degrees": 15.0, "herringbone": true, "bore_diameter": 0.0}], 0) == "Internal 60 teeth, module 1.5, herringbone 15 deg")

	# Edit
	var gear_id: String = ed.feature_stack[0]
	await table.build.reload()
	var row: Dictionary = table.build.row(gear_id)
	print("SMOKE the made gear is a Build row of type gear that edits in its own tool: ", row.get("type") == "gear" and ed.tools["gear"].edits_in_tool() and table.build.can_edit(gear_id) if table.build.has_method("can_edit") else row.get("type") == "gear")
	await ed.begin_tool_edit(gear_id)
	print("SMOKE Edit opens the Gear tool with the feature's own settings: ", table.active_tool == "gear" and not ed.editing.is_empty() and ed.options["g_teeth"] == 20.0 and ed.options["g_bore"] == 8.0 and ed.options["g_module"] == 2.0)
	ed.option_typed("g_teeth", "24")
	ed.option_typed("g_bore", "10")
	await ed.apply_feature()
	var patches: Array = rig.calls_to("PATCH /document/parts/PART_BOX/gear-features/" + gear_id)
	print("SMOKE Apply PATCHes the gear with the new numbers and without gear_type or targets: ", patches.size() == 1 and patches[0][1]["tooth_count"] == 24 and patches[0][1]["bore_diameter"] == 10.0 and not patches[0][1].has("gear_type") and not patches[0][1].has("target_body_ids"), " ", patches)
	print("SMOKE ...Undo's payload is the old numbers: ", ed.feature_stack.back() is Dictionary and ed.feature_stack.back()["payload"].get("tooth_count") == 20 and ed.feature_stack.back()["payload"].get("bore_diameter") == 8.0)

	# Rack
	table.manager.deactivate()
	await rig.frames(2)
	table.manager.activate("rack")
	await rig.frames(3)
	ids = table.props.option_ids()
	print("SMOKE Rack lists Module, Teeth, Width, Pressure, Backing, Backing auto, Backlash, Plane and Apply: ", ids == ["r_module", "r_teeth", "r_face", "r_pa", "r_backing", "r_backing_auto", "r_backlash", "r_plane", "apply"], " ", ids)
	req = ed.tools["rack"].request(ed)
	print("SMOKE ...its body is the rack-features create body with the default backing left out: ", req["ok"] and req["route"] == "rack-features" and req["body"] == {"rack_type": "boss", "module": 2.0, "tooth_count": 10, "face_width": 10.0, "pressure_angle_degrees": 20.0, "backlash": 0.0, "target_body_ids": []}, " ", req["body"])
	ed.option_typed("r_backing", "6")
	print("SMOKE ...a typed backing height is sent: ", ed.tools["rack"].request(ed)["body"].get("backing_height") == 6.0)
	await ed.on_option("r_backing_auto")
	print("SMOKE ...Backing: auto drops it again: ", not ed.tools["rack"].request(ed)["body"].has("backing_height"))
	print("SMOKE ...a rack previews as an eager feature (there is no coarse route): ", ed.tools["rack"].preview_mode() == "eager")
	await ed.apply_feature()
	made = posts_to(rig, "rack-features")
	print("SMOKE Apply makes one rack: ", made.size() == 1 and made[0][1]["tooth_count"] == 10)
	var rack_id: String = ed.feature_stack.back()
	await table.build.reload()
	await ed.begin_tool_edit(rack_id)
	ed.option_typed("r_teeth", "14")
	await ed.apply_feature()
	var rack_patch: Array = rig.calls_to("PATCH /document/parts/PART_BOX/rack-features/" + rack_id)
	print("SMOKE Edit changes a rack's teeth with a PATCH: ", rack_patch.size() == 1 and rack_patch[0][1]["tooth_count"] == 14 and not rack_patch[0][1].has("rack_type"))

	# Bevel
	table.manager.deactivate()
	await rig.frames(2)
	table.manager.activate("bevel_gear")
	await rig.frames(3)
	ids = table.props.option_ids()
	print("SMOKE Bevel lists the numbers, Mate teeth, Cone from mate, Pressure, Spiral, Bore, Plane and Apply (no hand while straight): ", ids == ["b_module", "b_teeth", "b_face", "b_cone", "b_mate", "b_fit", "b_pa", "b_spiral", "b_bore", "b_plane", "apply"], " ", ids)
	req = ed.tools["bevel_gear"].request(ed)
	print("SMOKE ...its body is the bevel-gear-features create body: ", req["ok"] and req["route"] == "bevel-gear-features" and req["body"]["bevel_type"] == "boss" and req["body"]["pitch_cone_angle_degrees"] == 45.0 and req["body"]["bore_diameter"] == 8.0 and req["body"]["spiral_angle_degrees"] == 0.0 and req["body"]["target_body_ids"] == [], " ", req["body"])
	print("SMOKE ...it previews through the bevel coarse route: ", ed.tools["bevel_gear"].preview_mode() == "coarse" and ed.tools["bevel_gear"].preview_route() == "bevel-gear-features/coarse-preview")
	ed.option_typed("b_teeth", "20")
	ed.option_typed("b_mate", "40")
	await ed.on_option("b_fit")
	print("SMOKE Cone from mate fills atan(z / z_mate) for a 90 degree pair: ", absf(float(ed.options["b_cone"]) - rad_to_deg(atan(20.0 / 40.0))) < 1e-9 and absf(BevelGearTool.cone_for_pair(20.0, 20.0) - 45.0) < 1e-9)
	ed.option_typed("b_spiral", "25")
	ids = table.props.option_ids()
	print("SMOKE a spiral angle shows Left and Right and sends the hand: ", ids.has("b_hand_left") and ids.has("b_hand_right") and ed.tools["bevel_gear"].request(ed)["body"]["spiral_angle_degrees"] == 25.0)
	await ed.on_option("b_hand_left")
	print("SMOKE ...the hand is left: ", ed.tools["bevel_gear"].request(ed)["body"]["spiral_hand"] == "left")
	ed.option_typed("b_cone", "95")
	print("SMOKE a cone over 90 degrees is refused when typed: ", float(ed.options["b_cone"]) <= 90.0)
	ed.options["b_cone"] = 0.0
	print("SMOKE ...and a cone of 0 is refused by the request: ", not ed.tools["bevel_gear"].request(ed)["ok"])
	ed.options["b_cone"] = 30.0
	ed.options["b_spiral"] = 0.0
	await ed.apply_feature()
	made = posts_to(rig, "bevel-gear-features")
	print("SMOKE Apply makes one bevel gear: ", made.size() == 1 and made[0][1]["pitch_cone_angle_degrees"] == 30.0)
	var bevel_id: String = ed.feature_stack.back()
	await table.build.reload()
	await ed.begin_tool_edit(bevel_id)
	print("SMOKE Edit loads the bevel gear's own settings: ", ed.options["b_cone"] == 30.0 and ed.options["b_teeth"] == 20.0 and ed.options["b_bore"] == 8.0)
	ed.option_typed("b_bore", "0")
	await ed.apply_feature()
	var bevel_patch: Array = rig.calls_to("PATCH /document/parts/PART_BOX/bevel-gear-features/" + bevel_id)
	print("SMOKE ...taking the bore away PATCHes bore_diameter 0: ", bevel_patch.size() == 1 and bevel_patch[0][1]["bore_diameter"] == 0.0 and not bevel_patch[0][1].has("bevel_type"))

	# Undo takes the edit back, then the creations
	await ed.undo()
	var undone_patch: Array = rig.calls_to("PATCH /document/parts/PART_BOX/bevel-gear-features/" + bevel_id)
	print("SMOKE Undo of the edit puts the old bore back: ", undone_patch.size() == 2 and undone_patch[1][1].get("bore_diameter") == 8.0, " ", undone_patch)
	quit()
