extends "res://scripts/design_table/features/feature_tool.gd"
## Shell: hollow a body, opening the picked faces.


func _init() -> void:
	id = "shell"


func options(ed) -> Array:
	return [
		{"id": "thickness", "text": "Wall %.2f mm" % float(ed.options["thickness"])},
		{"id": "shell_in", "text": "Inward", "toggle": true, "pressed": str(ed.options["shell_direction"]) == "inward"},
		{"id": "shell_out", "text": "Outward", "toggle": true, "pressed": str(ed.options["shell_direction"]) == "outward"},
		{"id": "clear_faces", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d)" % ed.faces.size(), "disabled": not can_apply(ed)},
	]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"thickness":
			ed.type_option("thickness", "Wall thickness (mm)")
		"shell_in":
			ed.options["shell_direction"] = "inward"
		"shell_out":
			ed.options["shell_direction"] = "outward"
		"clear_faces":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	if ed.state in ["sketch", "pick_plane", "pick_edges", "extrude", "pick_faces"]:
		ed.clear_picks()
		ed.set_state("pick_faces")


func can_apply(ed) -> bool:
	return not ed.faces.is_empty()


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	if ed.faces.is_empty():
		return PartFeatures._bad("Pick the faces to open first.")
	return PartFeatures.shell_request(str(ed.faces[0]["body_id"]), ed.faces.map(func(f): return PartFeatures.face_ref(str(f["body_id"]), int(f["index"]))), float(ed.options["thickness"]), str(ed.options["shell_direction"]))
