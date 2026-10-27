extends "res://scripts/design_table/features/feature_tool.gd"
## Spring: a compression spring made from its numbers (no sketch), one new body, as the flat app's Spring feature: the mean diameter (through the wire
## centre), the wire diameter, the free length, the active coils, each end open, closed (a dead coil at the wire's pitch, then a smooth rise to the
## working pitch) or closed and ground flat, and the hand. It stands on the part's XY plane unless a plane or flat face is picked first: the plane's
## normal is the axis, its origin the centre of the base. The backend works the pitch out from the free length (and refuses one the coils can't reach,
## saying the solid length). No coarse preview for a spring, so it is made when the settings change (and taken back on Cancel) like the other eager tools.

const Common := preload("res://scripts/design_table/features/gear_common.gd")

const DEFAULTS := {"s_mean": 10.0, "s_wire": 1.0, "s_length": 20.0, "s_coils": 5.0, "s_start": "closed_ground", "s_finish": "closed_ground", "s_right": true}
const END_TEXT := {"closed_ground": "closed, ground", "closed": "closed", "open": "open"}

var _plane := {}


func _init() -> void:
	id = "spring"


func options(ed) -> Array:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	var list: Array = [
		{"id": "s_mean", "text": "Mean diameter %s mm" % Common.num(float(o["s_mean"]))},
		{"id": "s_wire", "text": "Wire %s mm" % Common.num(float(o["s_wire"]))},
		{"id": "s_length", "text": "Free length %s mm" % Common.num(float(o["s_length"]))},
		{"id": "s_coils", "text": "Active coils %s" % Common.num(float(o["s_coils"]))},
		{"id": "s_start", "text": "Start end: %s" % END_TEXT[o["s_start"]]},
		{"id": "s_finish", "text": "Finish end: %s" % END_TEXT[o["s_finish"]]},
		{"id": "s_hand", "text": "Right-handed", "toggle": true, "pressed": bool(o["s_right"])},
		{"id": "s_plane", "text": "Plane: %s" % Common.plane_text(_plane), "toggle": true, "pressed": false},
	]
	var req := request(ed)
	list.append({"id": "apply", "text": "Apply" if req["ok"] else "Apply (%s)" % req["error"], "disabled": not req["ok"]})
	return list


func handle_option(ed, option_id: String) -> bool:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	match option_id:
		"s_mean":
			ed.type_option("s_mean", "Mean diameter (mm, through the wire centre)")
		"s_wire":
			ed.type_option("s_wire", "Wire diameter (mm)")
		"s_length":
			ed.type_option("s_length", "Free length (mm)")
		"s_coils":
			ed.type_option("s_coils", "Active coils")
		"s_start", "s_finish":
			var ends: Array = PartFeatures.SPRING_ENDS
			o[option_id] = ends[(ends.find(o[option_id]) + 1) % ends.size()]
		"s_hand":
			o["s_right"] = not bool(o["s_right"])
		"s_plane":
			ed.set_pick_mode("plane")
			ed.table.set_status("Aim at a plane or a flat face and pull the trigger: the spring stands on it.")
		_:
			return false
	return true


func on_activated(ed) -> void:
	Common.ensure(ed, DEFAULTS)
	if ed.activating_edit:
		return # a Build row's Edit loads its own settings
	_plane = {}
	if ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a spring.")
		return
	ed.set_pick_mode("plane")
	ed.table.set_status("Set the spring, then Apply. To stand it on another plane, pull the trigger on that plane or a flat face first.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	_plane = Common.plane_ref_from_spec(spec)
	ed.table.set_status("The spring stands on %s." % Common.plane_text(_plane))
	ed._update_options()
	ed.schedule_preview()


func can_apply(ed) -> bool:
	return request(ed)["ok"]


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	return PartFeatures.spring_request({"mean": float(o["s_mean"]), "wire": float(o["s_wire"]), "length": float(o["s_length"]), "coils": float(o["s_coils"]),
		"start_end": str(o["s_start"]), "finish_end": str(o["s_finish"]), "right_handed": bool(o["s_right"])}, _plane)


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["plane_ref", "mean_diameter", "wire_diameter", "free_length", "active_coils", "start_end", "finish_end", "right_handed"]


func load_from_row(ed, row: Dictionary) -> void:
	Common.ensure(ed, DEFAULTS)
	var o: Dictionary = ed.options
	o["s_mean"] = float(row.get("mean_diameter", 10.0))
	o["s_wire"] = float(row.get("wire_diameter", 1.0))
	o["s_length"] = float(row.get("free_length", 20.0))
	o["s_coils"] = float(row.get("active_coils", 5.0))
	o["s_start"] = str(row.get("start_end", "closed_ground"))
	o["s_finish"] = str(row.get("finish_end", "closed_ground"))
	o["s_right"] = bool(row.get("right_handed", true))
	_plane = Common.plane_ref_from_row(row)


func summary(f: Dictionary, _features: Array) -> String:
	var ends := "%s / %s" % [END_TEXT.get(str(f.get("start_end", "")), "?"), END_TEXT.get(str(f.get("finish_end", "")), "?")]
	return "D %s x %s wire, %s long, %s coils, %s" % [Common.num(float(f.get("mean_diameter", 0.0))), Common.num(float(f.get("wire_diameter", 0.0))),
		Common.num(float(f.get("free_length", 0.0))), Common.num(float(f.get("active_coils", 0.0))), ends]


func done_text() -> String:
	return "Spring made."
