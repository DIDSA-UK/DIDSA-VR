extends "res://scripts/design_table/features/feature_tool.gd"
## Create Plane: a plane offset from a reference plane, a flat face or a plane already made. The plane is not a body, so there is no preview; once
## made it is drawn beside the three reference planes (plane_markers.gd) and can be picked to sketch on, or offset again.


func _init() -> void:
	id = "create_plane"


func options(ed) -> Array:
	return [
		{"id": "plane_base", "text": "From: %s" % _base_text(ed.plane_base), "disabled": true},
		{"id": "plane_offset", "text": "Offset %.2f mm" % float(ed.options["plane_offset"])},
		{"id": "plane_flip", "text": "Reverse", "toggle": true, "pressed": bool(ed.options["plane_flip"])},
		{"id": "apply", "text": "Make plane", "disabled": not can_apply(ed)},
	]


static func _base_text(base: Dictionary) -> String:
	if base.has("fixed"):
		return "%s plane" % str(base["fixed"])
	if base.has("face"):
		return "a face"
	if base.has("plane_feature_id"):
		return "a made plane"
	return "pick one"


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"plane_offset":
			ed.type_option("plane_offset", "Offset (mm)")
		"plane_flip":
			ed.options["plane_flip"] = not bool(ed.options["plane_flip"])
		_:
			return false
	return true


func on_activated(ed) -> void:
	ed.plane_base = {}
	if ed.session == null and ed.state != "idle":
		ed.set_state("pick_plane")
		ed.table.set_status("Aim at a flat face or a plane and pull the trigger to offset a new plane from it.")
	elif ed.session != null:
		ed.table.set_status("Finish the sketch first (Done), then make a plane.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	ed.plane_base = spec
	ed.table.set_status("Offset from %s. Set the offset, then Make plane." % _base_text(spec))
	ed._update_options()


func can_apply(ed) -> bool:
	return not ed.plane_base.is_empty()


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var offset := float(ed.options["plane_offset"]) * (-1.0 if bool(ed.options["plane_flip"]) else 1.0)
	return PartFeatures.create_plane_request(ed.plane_base, offset)


func reload_build_after() -> bool:
	return true


func done_text() -> String:
	return "Plane made. Aim at it to sketch on it."
