extends "res://scripts/design_table/features/feature_tool.gd"
## Split: divide a body in two along a reference plane, a plane made with Plane, or a flat face. Pick the body, then the plane (the "Pick" toggles say
## which the laser is filling).

var _plane := {}
var _slot := "body"


func _init() -> void:
	id = "split"


func options(ed) -> Array:
	return [
		{"id": "slot_body", "text": "Pick body (%d)" % ed.bodies.size(), "toggle": true, "pressed": _slot == "body"},
		{"id": "slot_plane", "text": "Pick plane: %s" % _plane_text(), "toggle": true, "pressed": _slot == "plane"},
		{"id": "clear_bodies", "text": "Clear"},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]


func _plane_text() -> String:
	if _plane.has("fixed_plane"):
		return str(_plane["fixed_plane"])
	if _plane.has("face_ref"):
		return "a face"
	if _plane.has("plane_feature_id"):
		return "a made plane"
	return "none"


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"slot_body":
			_slot = "body"
			ed.set_pick_mode("bodies")
		"slot_plane":
			_slot = "plane"
			ed.set_pick_mode("plane")
		"clear_bodies":
			_plane = {}
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	_plane = {}
	_slot = "body"
	ed.start_body_picks(1)
	ed.table.set_status("Pick the body to split, then press Pick plane and pick the plane or flat face to split along.")


func wants_plane_pick() -> bool:
	return true


func on_plane_picked(ed, spec: Dictionary) -> void:
	if spec.has("fixed"):
		_plane = {"fixed_plane": str(spec["fixed"])}
	elif spec.has("face"):
		_plane = {"face_ref": PartFeatures.face_ref(str(spec["face"]["body_id"]), int(spec["face"]["index"]))}
	elif spec.has("plane_feature_id"):
		_plane = {"plane_feature_id": str(spec["plane_feature_id"])}
	ed.table.set_status("Split along %s." % _plane_text())
	ed._update_options()
	ed.schedule_preview()


func can_apply(ed) -> bool:
	return ed.bodies.size() >= 1 and not _plane.is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	return PartFeatures.split_request(str(ed.bodies[0]["body_id"]) if not ed.bodies.is_empty() else "", _plane)


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["target_body_id", "tool"]


func load_from_row(ed, row: Dictionary) -> void:
	var tool: Dictionary = row.get("tool", {})
	_plane = (tool.get("plane_ref", {}) as Dictionary).duplicate()
	var target := str(row.get("target_body_id", ""))
	ed.bodies = [{"kind": "body", "body_id": target, "index": -1, "key": "solid:%s" % target}] if target != "" else []


func summary(f: Dictionary, _features: Array) -> String:
	var plane: Dictionary = (f.get("tool", {}) as Dictionary).get("plane_ref", {}) if f.get("tool") is Dictionary else {}
	return "along %s" % (str(plane["fixed_plane"]) + " plane" if plane.get("fixed_plane") != null else "a plane")


func done_text() -> String:
	return "Split done."
