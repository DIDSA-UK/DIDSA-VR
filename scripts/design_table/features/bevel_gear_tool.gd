extends "res://scripts/design_table/features/feature_tool.gd"
## Bevel gear: one straight (or spiral) bevel gear made from its numbers (no sketch), a new body, with a through bore on its axis. The pitch cone angle is typed, or filled in
## for a 90 degree pair from the teeth of this gear and of its mate (Mate teeth). The coarse preview shows it before Apply.

const Common := preload("res://scripts/design_table/features/gear_common.gd")

const DEFAULTS := {"b_module": 2.0, "b_teeth": 20.0, "b_face": 8.0, "b_mate": 20.0, "b_cone": 45.0, "b_pa": 20.0, "b_spiral": 0.0, "b_hand": "right", "b_bore": 8.0}

var _plane := {}


func _init() -> void:
	id = "bevel_gear"


static func cone_for_pair(teeth: float, mate_teeth: float) -> float:
	## The pitch cone angle (degrees) of a gear of `teeth` teeth meshing with `mate_teeth` on shafts at 90 degrees: atan(z / z_mate).
	return rad_to_deg(atan2(teeth, mate_teeth))


func options(ed) -> Array:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	var spiral := float(o["b_spiral"]) > 0.0
	var list := [
		{"id": "b_module", "text": "Module %s" % Common.num(float(o["b_module"]))},
		{"id": "b_teeth", "text": "Teeth %d" % roundi(float(o["b_teeth"]))},
		{"id": "b_face", "text": "Width %s mm" % Common.num(float(o["b_face"]))},
		{"id": "b_cone", "text": "Cone %s deg" % Common.num(float(o["b_cone"]))},
		{"id": "b_mate", "text": "Mate teeth %d (90 deg)" % roundi(float(o["b_mate"]))},
		{"id": "b_fit", "text": "Cone from mate"},
		{"id": "b_pa", "text": "Pressure %s deg" % Common.num(float(o["b_pa"]))},
		{"id": "b_spiral", "text": "Spiral %s deg" % Common.num(float(o["b_spiral"]))},
	]
	if spiral:
		for h in [["left", "Left"], ["right", "Right"]]:
			list.append({"id": "b_hand_" + h[0], "text": h[1], "toggle": true, "pressed": str(o["b_hand"]) == h[0]})
	list.append({"id": "b_bore", "text": "Bore %s mm" % (Common.num(float(o["b_bore"])) if float(o["b_bore"]) > 0.0 else "none")})
	list.append({"id": "b_plane", "text": "Plane: %s" % Common.plane_text(_plane), "toggle": true, "pressed": false})
	list.append({"id": "apply", "text": "Apply", "disabled": not can_apply(ed)})
	return list


func handle_option(ed, option_id: String) -> bool:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	match option_id:
		"b_module":
			ed.type_option("b_module", "Module (mm, at the outer end)")
		"b_teeth":
			ed.type_option("b_teeth", "Number of teeth")
		"b_face":
			ed.type_option("b_face", "Face width (mm)")
		"b_cone":
			ed.type_option("b_cone", "Pitch cone angle (degrees, up to 90)")
		"b_mate":
			ed.type_option("b_mate", "Teeth of the gear it will mesh with")
		"b_fit":
			o["b_cone"] = cone_for_pair(float(o["b_teeth"]), float(o["b_mate"]))
		"b_pa":
			o["b_pa"] = Common.next_pressure_angle(float(o["b_pa"]))
		"b_spiral":
			ed.type_option("b_spiral", "Spiral angle (degrees, 0 is straight)")
		"b_hand_left":
			o["b_hand"] = "left"
		"b_hand_right":
			o["b_hand"] = "right"
		"b_bore":
			ed.type_option("b_bore", "Bore diameter (mm, 0 for none)")
		"b_plane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a plane or a flat face and pull the trigger: the gear's apex goes at the plane's origin, its axis along the normal.")
		_:
			return false
	return true


func on_activated(ed) -> void:
	Common.ensure(ed, DEFAULTS)
	_plane = {}
	if ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a bevel gear.")
		return
	ed.set_pick_mode("plane")
	ed.table.set_status("Set the gear, then Apply. For a 90 degree pair, set Mate teeth and press Cone from mate.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	_plane = Common.plane_ref_from_spec(spec)
	ed.table.set_status("The bevel gear stands on %s." % Common.plane_text(_plane))
	ed._update_options()
	ed.schedule_preview()


func preview_mode() -> String:
	return "coarse"


func preview_route() -> String:
	return "bevel-gear-features/coarse-preview"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	return PartFeatures.bevel_gear_request({"module": float(o["b_module"]), "teeth": roundi(float(o["b_teeth"])), "face": float(o["b_face"]), "cone": float(o["b_cone"]),
		"pressure_angle": float(o["b_pa"]), "spiral": float(o["b_spiral"]), "hand": str(o["b_hand"]), "bore": float(o["b_bore"])}, _plane)


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["module", "tooth_count", "face_width", "pitch_cone_angle_degrees", "pressure_angle_degrees", "spiral_angle_degrees", "spiral_hand", "bore_diameter"]


func patch_body(req: Dictionary) -> Dictionary:
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body.erase("bevel_type")
	body.erase("target_body_ids")
	return body


func load_from_row(ed, row: Dictionary) -> void:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	o["b_module"] = float(row.get("module", 2.0))
	o["b_teeth"] = float(row.get("tooth_count", 20))
	o["b_face"] = float(row.get("face_width", 8.0))
	o["b_cone"] = float(row.get("pitch_cone_angle_degrees", 45.0))
	o["b_pa"] = float(row.get("pressure_angle_degrees", 20.0))
	o["b_spiral"] = float(row.get("spiral_angle_degrees", 0.0))
	o["b_hand"] = str(row.get("spiral_hand", "right"))
	o["b_bore"] = float(row.get("bore_diameter", 0.0))
	_plane = Common.plane_ref_from_row(row)


func summary(f: Dictionary, _features: Array) -> String:
	var text := "%d teeth, module %s, cone %s deg" % [int(f.get("tooth_count", 0)), Common.num(float(f.get("module", 0.0))), Common.num(float(f.get("pitch_cone_angle_degrees", 0.0)))]
	if float(f.get("spiral_angle_degrees", 0.0)) > 0.0:
		text += ", spiral"
	return text


func done_text() -> String:
	return "Bevel gear made."
