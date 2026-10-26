extends "res://scripts/design_table/features/feature_tool.gd"
## Rack: one straight rack made from its numbers (no sketch), a new body, on the part's XY plane unless a plane or flat face is picked first. The backend has no coarse
## preview for a rack, so it is made when the settings change (and taken back on Cancel) like the other eager tools.

const Common := preload("res://scripts/design_table/features/gear_common.gd")

const DEFAULTS := {"r_module": 2.0, "r_teeth": 10.0, "r_face": 10.0, "r_pa": 20.0, "r_backlash": 0.0, "r_backing": 0.0}

var _plane := {}


func _init() -> void:
	id = "rack"


func options(ed) -> Array:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	return [
		{"id": "r_module", "text": "Module %s" % Common.num(float(o["r_module"]))},
		{"id": "r_teeth", "text": "Teeth %d" % roundi(float(o["r_teeth"]))},
		{"id": "r_face", "text": "Width %s mm" % Common.num(float(o["r_face"]))},
		{"id": "r_pa", "text": "Pressure %s deg" % Common.num(float(o["r_pa"]))},
		{"id": "r_backing", "text": "Backing %s" % ("%s mm" % Common.num(float(o["r_backing"])) if float(o["r_backing"]) > 0.0 else "auto")},
		{"id": "r_backing_auto", "text": "Backing: auto", "toggle": true, "pressed": float(o["r_backing"]) <= 0.0},
		{"id": "r_backlash", "text": "Backlash %s mm" % Common.num(float(o["r_backlash"]))},
		{"id": "r_plane", "text": "Plane: %s" % Common.plane_text(_plane), "toggle": true, "pressed": false},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]


func handle_option(ed, option_id: String) -> bool:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	match option_id:
		"r_module":
			ed.type_option("r_module", "Module (mm)")
		"r_teeth":
			ed.type_option("r_teeth", "Number of teeth")
		"r_face":
			ed.type_option("r_face", "Face width (mm)")
		"r_pa":
			o["r_pa"] = Common.next_pressure_angle(float(o["r_pa"]))
		"r_backing":
			ed.type_option("r_backing", "Backing height (mm, 0 for the default of 2 x module)")
		"r_backing_auto":
			o["r_backing"] = 0.0
		"r_backlash":
			ed.type_option("r_backlash", "Backlash (mm)")
		"r_plane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a plane or a flat face and pull the trigger: the rack stands on it.")
		_:
			return false
	return true


func on_activated(ed) -> void:
	Common.ensure(ed, DEFAULTS)
	_plane = {}
	if ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a rack.")
		return
	ed.set_pick_mode("plane")
	ed.table.set_status("Set the rack, then Apply. To stand it on another plane, pull the trigger on that plane or a flat face first.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	_plane = Common.plane_ref_from_spec(spec)
	ed.table.set_status("The rack stands on %s." % Common.plane_text(_plane))
	ed._update_options()
	ed.schedule_preview()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	return PartFeatures.rack_request({"module": float(o["r_module"]), "teeth": roundi(float(o["r_teeth"])), "face": float(o["r_face"]), "pressure_angle": float(o["r_pa"]),
		"backlash": float(o["r_backlash"]), "backing": float(o["r_backing"])}, _plane)


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["module", "tooth_count", "face_width", "pressure_angle_degrees", "backlash", "backing_height"]


func patch_body(req: Dictionary) -> Dictionary:
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body.erase("rack_type")
	body.erase("target_body_ids")
	return body


func load_from_row(ed, row: Dictionary) -> void:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	o["r_module"] = float(row.get("module", 2.0))
	o["r_teeth"] = float(row.get("tooth_count", 10))
	o["r_face"] = float(row.get("face_width", 10.0))
	o["r_pa"] = float(row.get("pressure_angle_degrees", 20.0))
	o["r_backlash"] = float(row.get("backlash", 0.0))
	o["r_backing"] = float(row["backing_height"]) if row.get("backing_height") != null else 0.0
	_plane = Common.plane_ref_from_row(row)


func summary(f: Dictionary, _features: Array) -> String:
	return "%d teeth, module %s" % [int(f.get("tooth_count", 0)), Common.num(float(f.get("module", 0.0)))]


func done_text() -> String:
	return "Rack made."
