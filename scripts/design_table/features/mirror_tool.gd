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
	elif ed.state in ed.PICK_STATES:
		ed.highlight.set_set(ed.table.table_copy, [])
		ed.set_state("pick_plane")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	await ed.mirror_across(spec)


func request(ed, extra: Dictionary = {}) -> Dictionary:
	## `extra.spec` is what the laser picked: {"fixed": "XY"} or {"face": {body_id, index}}.
	var spec: Dictionary = extra.get("spec", {})
	var plane: Dictionary = {}
	if spec.has("fixed"):
		plane = {"fixed_plane": str(spec["fixed"])}
	elif spec.has("plane_feature_id"):
		plane = {"plane_feature_id": str(spec["plane_feature_id"])}
	elif spec.has("face"):
		plane = {"face_ref": PartFeatures.face_ref(str(spec["face"]["body_id"]), int(spec["face"]["index"]))}
	return PartFeatures.mirror_request(ed.body_ids(), plane, bool(ed.options["mirror_fuse"]))


func done_text() -> String:
	return "Mirrored."
