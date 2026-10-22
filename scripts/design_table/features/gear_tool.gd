extends "res://scripts/design_table/features/feature_tool.gd"
## Gear: one spur gear made from its numbers (no sketch), external or internal, straight, helical or herringbone, with a through bore on an external one so it can be mated
## concentric to a shaft. It stands on the part's XY plane unless a plane or flat face is picked first, and starts a new body. The coarse preview shows it before Apply; a line
## under the settings gives the circle sizes and the centre distance to a partner gear (where the shaft holes go).

const Common := preload("res://scripts/design_table/features/gear_common.gd")

const DEFAULTS := {"g_internal": false, "g_module": 2.0, "g_teeth": 20.0, "g_face": 10.0, "g_pa": 20.0, "g_helix": 0.0, "g_herring": false, "g_bore": 8.0,
	"g_outer": 0.0, "g_backlash": 0.0, "g_fillet": 0.0, "g_shift_auto": true, "g_shift": 0.0, "g_mate": 20.0}

var _plane := {} ## the backend's plane_ref of the plane picked ({} = the default XY plane)
var _circles := {} ## the last /document/gear/preview answer's diameters: {key, pitch, tip, root}


func _init() -> void:
	id = "gear"


func options(ed) -> Array:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	var internal := bool(o["g_internal"])
	var helix := float(o["g_helix"])
	var list := [
		{"id": "g_external", "text": "External", "toggle": true, "pressed": not internal},
		{"id": "g_internal", "text": "Internal", "toggle": true, "pressed": internal},
	]
	var lines := readout(o) # at the top, where the panel shows it without scrolling
	for i in lines.size():
		list.append({"id": "g_info_%d" % i, "text": lines[i], "disabled": true})
	list += [
		{"id": "g_module", "text": "Module %s" % Common.num(float(o["g_module"]))},
		{"id": "g_teeth", "text": "Teeth %d" % roundi(float(o["g_teeth"]))},
		{"id": "g_face", "text": "Width %s mm" % Common.num(float(o["g_face"]))},
		{"id": "g_pa", "text": "Pressure %s deg" % Common.num(float(o["g_pa"]))},
		{"id": "g_helix", "text": "Helix %s deg" % Common.num(helix)},
		{"id": "g_herring", "text": "Herringbone", "toggle": true, "pressed": bool(o["g_herring"]) and not is_zero_approx(helix), "disabled": is_zero_approx(helix)},
	]
	if internal:
		list.append({"id": "g_outer", "text": "Outer %s mm" % (Common.num(float(o["g_outer"])) if float(o["g_outer"]) > 0.0 else "(set it)")})
	else:
		list.append({"id": "g_bore", "text": "Bore %s mm" % (Common.num(float(o["g_bore"])) if float(o["g_bore"]) > 0.0 else "none")})
	list.append({"id": "g_backlash", "text": "Backlash %s mm" % Common.num(float(o["g_backlash"]))})
	list.append({"id": "g_fillet", "text": "Root fillet %s mm" % Common.num(float(o["g_fillet"]))})
	list.append({"id": "g_shift_auto", "text": "Shift: auto", "toggle": true, "pressed": bool(o["g_shift_auto"])})
	if not bool(o["g_shift_auto"]):
		list.append({"id": "g_shift", "text": "Shift %s" % Common.num(float(o["g_shift"]))})
	list.append({"id": "g_mate", "text": "Mate teeth %d" % roundi(float(o["g_mate"]))})
	list.append({"id": "g_plane", "text": "Plane: %s" % Common.plane_text(_plane), "toggle": true, "pressed": false})
	list.append({"id": "apply", "text": "Apply", "disabled": not can_apply(ed)})
	return list


func readout(o: Dictionary) -> Array:
	## The circle sizes and the centre distance to a partner gear of "Mate teeth" teeth. Sizes come from the backend's last answer for these settings, or (until it
	## answers) the standard-tooth formulas, which are exact at zero profile shift.
	var m := float(o["g_module"])
	var z := roundi(float(o["g_teeth"]))
	var n := roundi(float(o["g_mate"]))
	var internal := bool(o["g_internal"])
	var pitch := m * z
	var tip := m * (z - 2 if internal else z + 2)
	var root := m * (z + 2.5 if internal else z - 2.5)
	if _circles.get("key") == _circles_key(o):
		pitch = float(_circles["pitch"])
		tip = float(_circles["tip"])
		root = float(_circles["root"])
	var centre := absf(m * (z - n) / 2.0) if internal else m * (z + n) / 2.0
	return ["Pitch %s  Tip %s  Root %s mm" % [Common.num(pitch), Common.num(tip), Common.num(root)],
		"Centre distance to a %d-tooth %s: %s mm" % [n, "pinion" if internal else "gear", Common.num(centre)]]


static func _circles_key(o: Dictionary) -> String:
	return "%s|%s|%s|%s|%s|%s" % [o["g_internal"], o["g_module"], o["g_teeth"], o["g_pa"], o["g_backlash"], o["g_shift"] if not bool(o["g_shift_auto"]) else "auto"]


func preview_aux(ed) -> void:
	## Asks the backend for the real circle sizes (the cheap /gear/preview, no solid is built); the options row shows them when they arrive.
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	var key := _circles_key(o)
	if _circles.get("key") == key or roundi(float(o["g_teeth"])) < 3 or float(o["g_module"]) <= 0.0:
		return
	var internal := bool(o["g_internal"])
	var body := {"gear_kind": "internal" if internal else "external", "module": float(o["g_module"]), "tooth_count": roundi(float(o["g_teeth"])),
		"pressure_angle_degrees": float(o["g_pa"]), "backlash": float(o["g_backlash"])}
	if not bool(o["g_shift_auto"]):
		body["profile_shift"] = float(o["g_shift"])
	if internal:
		body["outer_diameter"] = maxf(float(o["g_outer"]), float(o["g_module"]) * (roundi(float(o["g_teeth"])) + 8))
	var answer: Dictionary = await ed._call(HTTPClient.METHOD_POST, "/document/gear/preview", body)
	if not bool(answer["ok"]) or not (answer["json"] is Dictionary):
		return
	var j: Dictionary = answer["json"]
	if j.get("pitch_radius") == null or j.get("addendum_radius") == null or j.get("dedendum_radius") == null:
		return
	_circles = {"key": key, "pitch": 2.0 * float(j["pitch_radius"]), "tip": 2.0 * float(j["addendum_radius"]), "root": 2.0 * float(j["dedendum_radius"])}
	ed._update_options()


func handle_option(ed, option_id: String) -> bool:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	match option_id:
		"g_external":
			o["g_internal"] = false
		"g_internal":
			o["g_internal"] = true
			if float(o["g_outer"]) <= 0.0:
				o["g_outer"] = float(o["g_module"]) * (float(o["g_teeth"]) + 8.0) # room for a rim, the way the flat app fills it
		"g_module":
			ed.type_option("g_module", "Module (mm)")
		"g_teeth":
			ed.type_option("g_teeth", "Number of teeth")
		"g_face":
			ed.type_option("g_face", "Face width (mm)")
		"g_pa":
			o["g_pa"] = Common.next_pressure_angle(float(o["g_pa"]))
		"g_helix":
			ed.type_option("g_helix", "Helix angle (degrees, 0 is straight, negative the other hand)")
		"g_herring":
			o["g_herring"] = not bool(o["g_herring"])
		"g_bore":
			ed.type_option("g_bore", "Bore diameter (mm, 0 for none)")
		"g_outer":
			ed.type_option("g_outer", "Outer diameter of the ring (mm)")
		"g_backlash":
			ed.type_option("g_backlash", "Backlash (mm)")
		"g_fillet":
			ed.type_option("g_fillet", "Root fillet radius (mm, 0 for none)")
		"g_shift_auto":
			o["g_shift_auto"] = not bool(o["g_shift_auto"])
		"g_shift":
			ed.type_option("g_shift", "Profile shift (a number, negative allowed)")
		"g_mate":
			ed.type_option("g_mate", "Teeth of the gear it will mesh with")
		"g_plane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a plane or a flat face and pull the trigger: the gear stands on it, its axis along the plane's normal.")
		_:
			return option_id.begins_with("g_info_") # the readout lines are greyed, a press on one does nothing
	return true


func on_activated(ed) -> void:
	Common.ensure(ed, DEFAULTS)
	_plane = {}
	if ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a gear.")
		return
	ed.set_pick_mode("plane") # a pull on a plane or a flat face is the gear's plane (none picked: the XY plane)
	ed.table.set_status("Set the gear, then Apply. To stand it on another plane, pull the trigger on that plane or a flat face first.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	_plane = Common.plane_ref_from_spec(spec)
	ed.table.set_status("The gear stands on %s." % Common.plane_text(_plane))
	ed._update_options()
	ed.schedule_preview()


func preview_mode() -> String:
	return "coarse"


func preview_route() -> String:
	return "gear-features/coarse-preview"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	return PartFeatures.gear_request({"internal": bool(o["g_internal"]), "module": float(o["g_module"]), "teeth": roundi(float(o["g_teeth"])), "face": float(o["g_face"]),
		"pressure_angle": float(o["g_pa"]), "helix": float(o["g_helix"]), "herringbone": bool(o["g_herring"]), "bore": float(o["g_bore"]), "outer": float(o["g_outer"]),
		"backlash": float(o["g_backlash"]), "fillet": float(o["g_fillet"]), "shift": null if bool(o["g_shift_auto"]) else float(o["g_shift"])}, _plane)


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["is_internal", "module", "tooth_count", "face_width", "pressure_angle_degrees", "profile_shift", "backlash", "root_fillet_radius", "outer_diameter", "helix_angle_degrees", "herringbone", "bore_diameter"]


func patch_body(req: Dictionary) -> Dictionary:
	## A PATCH changes the settings, never what the gear is made into (always a Boss, a new body); an Auto profile shift is left out (the backend keeps a typed one once set).
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body.erase("gear_type")
	body.erase("target_body_ids")
	return body


func load_from_row(ed, row: Dictionary) -> void:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	o["g_internal"] = bool(row.get("is_internal", false))
	o["g_module"] = float(row.get("module", 2.0))
	o["g_teeth"] = float(row.get("tooth_count", 20))
	o["g_face"] = float(row.get("face_width", 10.0))
	o["g_pa"] = float(row.get("pressure_angle_degrees", 20.0))
	o["g_helix"] = float(row.get("helix_angle_degrees", 0.0))
	o["g_herring"] = bool(row.get("herringbone", false))
	o["g_bore"] = float(row.get("bore_diameter", 0.0))
	o["g_outer"] = float(row["outer_diameter"]) if row.get("outer_diameter") != null else 0.0
	o["g_backlash"] = float(row.get("backlash", 0.0))
	o["g_fillet"] = float(row.get("root_fillet_radius", 0.0))
	o["g_shift_auto"] = row.get("profile_shift") == null
	o["g_shift"] = float(row["profile_shift"]) if row.get("profile_shift") != null else 0.0
	_plane = Common.plane_ref_from_row(row)


func summary(f: Dictionary, _features: Array) -> String:
	var text := "%s %d teeth, module %s" % ["Internal" if bool(f.get("is_internal", false)) else "External", int(f.get("tooth_count", 0)), Common.num(float(f.get("module", 0.0)))]
	if not is_zero_approx(float(f.get("helix_angle_degrees", 0.0))):
		text += ", %s %s deg" % ["herringbone" if bool(f.get("herringbone", false)) else "helix", Common.num(float(f["helix_angle_degrees"]))]
	if float(f.get("bore_diameter", 0.0)) > 0.0:
		text += ", bore %s" % Common.num(float(f["bore_diameter"]))
	return text


func done_text() -> String:
	return "Gear made."
