extends "res://scripts/design_table/features/feature_tool.gd"
## Move Face: push or pull the picked faces (of one body) along their normals by a distance. Reverse flips the direction. (Direct editing: works on
## faces of any solid, such as an imported STEP part, with no sketch.)


func _init() -> void:
	id = "move_face"


func options(ed) -> Array:
	return [
		{"id": "mf_offset", "text": "Distance %.2f mm" % float(ed.options["mf_offset"])},
		{"id": "mf_flip", "text": "Reverse", "toggle": true, "pressed": bool(ed.options["mf_flip"])},
		{"id": "clear_faces", "text": "Clear"},
		{"id": "apply", "text": "Apply (%d)" % ed.faces.size(), "disabled": not can_apply(ed)},
	]


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"mf_offset":
			ed.type_option("mf_offset", "Distance (mm)")
		"mf_flip":
			ed.options["mf_flip"] = not bool(ed.options["mf_flip"])
		"clear_faces":
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	ed.start_face_picks()
	ed.table.set_status("Pick the faces to move, set the distance, then Apply.")


func can_apply(ed) -> bool:
	return not ed.faces.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.move_face_request(ed.face_refs(), float(ed.options["mf_offset"]) * (-1.0 if bool(ed.options["mf_flip"]) else 1.0))


func build_type() -> String:
	return "move_face"


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["face_refs", "offset_distance", "delta", "direction_ref", "direction_distance"]


func patch_body(req: Dictionary) -> Dictionary:
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body["delta"] = null # a PATCH that switches mode must null the other modes' fields
	body["direction_ref"] = null
	body["direction_distance"] = null
	return body


func load_from_row(ed, row: Dictionary) -> void:
	var offset := float(row.get("offset_distance", 5.0) if row.get("offset_distance") != null else 5.0)
	ed.options["mf_offset"] = absf(offset)
	ed.options["mf_flip"] = offset < 0.0
	ed.faces = (row.get("face_refs", []) as Array).map(func(r): return {"kind": "face", "body_id": str(r.get("body_id", "")), "index": int(r.get("index", 0)), "key": "%s:%d" % [r.get("body_id", ""), int(r.get("index", 0))]})


func summary(f: Dictionary, _features: Array) -> String:
	return "%d face(s) by %s mm" % [(f.get("face_refs", []) as Array).size(), ed_number(f.get("offset_distance", 0.0))]


static func ed_number(x) -> String:
	return String.num(float(x) if x != null else 0.0, 2).rstrip("0").rstrip(".")


func done_text() -> String:
	return "Face moved."
