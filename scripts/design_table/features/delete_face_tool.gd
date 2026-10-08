extends "res://scripts/design_table/features/feature_tool.gd"
## Delete Face: remove the picked faces of one body and heal the opening closed (the neighbouring faces are extended to meet).


func _init() -> void:
	id = "delete_face"


func options(ed) -> Array:
	return [{"id": "clear_faces", "text": "Clear"}, {"id": "apply", "text": "Apply (%d)" % ed.faces.size(), "disabled": not can_apply(ed)}]


func handle_option(ed, option_id: String) -> bool:
	if option_id != "clear_faces":
		return false
	ed.clear_picks()
	return true


func on_activated(ed) -> void:
	ed.start_face_picks()
	ed.table.set_status("Pick the faces to delete (the gap is healed), then Apply.")


func can_apply(ed) -> bool:
	return not ed.faces.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.delete_face_request(ed.face_refs())


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["face_refs"]


func load_from_row(ed, row: Dictionary) -> void:
	ed.faces = (row.get("face_refs", []) as Array).map(func(r): return {"kind": "face", "body_id": str(r.get("body_id", "")), "index": int(r.get("index", 0)), "key": "%s:%d" % [r.get("body_id", ""), int(r.get("index", 0))]})


func summary(f: Dictionary, _features: Array) -> String:
	return "%d face(s)" % (f.get("face_refs", []) as Array).size()


func done_text() -> String:
	return "Face deleted."
