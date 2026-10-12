extends "res://scripts/design_table/features/feature_tool.gd"
## Move Face: push or pull the picked faces (of one body) along their normals by a distance. Reverse flips the direction. (Direct editing: works on
## faces of any solid, such as an imported STEP part, with no sketch.)


func _init() -> void:
	id = "move_face"


func options(ed) -> Array:
	var d := str(ed.options["mf_dir"])
	var list := []
	if d in ["line", "delta"]:
		list.append({"id": "mf_odd", "text": "Direction made elsewhere (kept)", "toggle": true, "pressed": true, "disabled": true}) # a sketch line or XYZ shift: shown, not editable here
	else:
		for k in [["normal", "Normal"], ["x", "X"], ["y", "Y"], ["z", "Z"]]:
			list.append({"id": "mf_dir_" + k[0], "text": k[1], "toggle": true, "pressed": d == k[0]})
	list.append({"id": "mf_offset", "text": "Distance %.2f mm" % float(ed.options["mf_offset"])})
	list.append({"id": "mf_flip", "text": "Reverse", "toggle": true, "pressed": bool(ed.options["mf_flip"])})
	list.append({"id": "clear_faces", "text": "Clear"})
	list.append({"id": "apply", "text": "Apply (%d)" % ed.faces.size(), "disabled": not can_apply(ed)})
	return list


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"mf_offset":
			ed.type_option("mf_offset", "Distance (mm)")
		"mf_flip":
			ed.options["mf_flip"] = not bool(ed.options["mf_flip"])
		"clear_faces":
			ed.clear_picks()
		_:
			if option_id.begins_with("mf_dir_"):
				ed.options["mf_dir"] = option_id.trim_prefix("mf_dir_")
			else:
				return false
	return true


func on_activated(ed) -> void:
	if not ed.activating_edit:
		ed.options["mf_dir"] = "normal" # (a Build row's Edit loads its own)
	ed.start_face_picks()
	ed.table.set_status("Pick the faces to move, set the distance, then Apply.")


func can_apply(ed) -> bool:
	return not ed.faces.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var axis := str(ed.options["mf_dir"])
	return PartFeatures.move_face_request(ed.face_refs(), float(ed.options["mf_offset"]) * (-1.0 if bool(ed.options["mf_flip"]) else 1.0), "" if axis == "normal" else axis)


func build_type() -> String:
	return "move_face"


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["face_refs", "offset_distance", "delta", "direction_ref", "direction_distance"]


func patch_body(req: Dictionary) -> Dictionary:
	var body: Dictionary = (req["body"] as Dictionary).duplicate()
	body["delta"] = null # a PATCH that switches mode must null the other modes' fields
	if body.has("direction_ref"):
		body["offset_distance"] = null
	else:
		body["direction_ref"] = null
		body["direction_distance"] = null
	return body


func load_from_row(ed, row: Dictionary) -> void:
	var offset := float(row.get("offset_distance", 5.0) if row.get("offset_distance") != null else 5.0)
	ed.options["mf_dir"] = "normal"
	if row.get("direction_ref") is Dictionary:
		var ref: Dictionary = row["direction_ref"]
		ed.options["mf_dir"] = str(ref["fixed_axis"]) if ref.get("fixed_axis") != null else "line"
		offset = float(row.get("direction_distance", 5.0))
	elif row.get("delta") != null:
		ed.options["mf_dir"] = "delta"
	ed.options["mf_offset"] = absf(offset)
	ed.options["mf_flip"] = offset < 0.0
	ed.faces = (row.get("face_refs", []) as Array).map(func(r): return {"kind": "face", "body_id": str(r.get("body_id", "")), "index": int(r.get("index", 0)), "key": "%s:%d" % [r.get("body_id", ""), int(r.get("index", 0))]})


func summary(f: Dictionary, _features: Array) -> String:
	if f.get("direction_ref") is Dictionary:
		var ref: Dictionary = f["direction_ref"]
		return "%d face(s) by %s mm along %s" % [(f.get("face_refs", []) as Array).size(), ed_number(f.get("direction_distance", 0.0)), str(ref["fixed_axis"]).to_upper() if ref.get("fixed_axis") != null else "a line"]
	return "%d face(s) by %s mm" % [(f.get("face_refs", []) as Array).size(), ed_number(f.get("offset_distance", 0.0))]


static func ed_number(x) -> String:
	return String.num(float(x) if x != null else 0.0, 2).rstrip("0").rstrip(".")


func done_text() -> String:
	return "Face moved."
