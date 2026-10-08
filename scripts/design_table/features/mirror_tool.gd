extends "res://scripts/design_table/features/feature_tool.gd"
## Mirror: reflect every body of the part across the plane or flat face the laser pulls on (so it has no Apply of its own).


func _init() -> void:
	id = "mirror"


func options(ed) -> Array:
	return [{"id": "mirror_fuse", "text": "Fuse into one", "toggle": true, "pressed": bool(ed.options["mirror_fuse"])}]


func handle_option(ed, option_id: String) -> bool:
	if option_id != "mirror_fuse":
		return false
	ed.options["mirror_fuse"] = not bool(ed.options["mirror_fuse"])
	return true


func on_activated(ed) -> void:
	if ed.state == "sketch" or ed.state == "extrude":
		ed.table.set_status("Finish the sketch first (Done), then mirror the part.")
	elif ed.state in ["pick_edges", "pick_faces"]:
		ed.highlight.set_set(ed.table.table_copy, [])
		ed.set_state("pick_plane")


func request(ed, extra: Dictionary = {}) -> Dictionary:
	## `extra.spec` is what the laser picked: {"fixed": "XY"} or {"face": {body_id, index}}.
	var spec: Dictionary = extra.get("spec", {})
	var plane: Dictionary = {}
	if spec.has("fixed"):
		plane = {"fixed_plane": str(spec["fixed"])}
	elif spec.has("face"):
		plane = {"face_ref": PartFeatures.face_ref(str(spec["face"]["body_id"]), int(spec["face"]["index"]))}
	return PartFeatures.mirror_request(ed.body_ids(), plane, bool(ed.options["mirror_fuse"]))


func done_text() -> String:
	return "Mirrored."
