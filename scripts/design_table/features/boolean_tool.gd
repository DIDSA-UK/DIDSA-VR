extends "res://scripts/design_table/features/feature_tool.gd"
## Boolean: Subtract (the tool bodies cut out of the targets) or Common (only what they share is kept). Two picks of whole bodies: the target(s), then
## the tool(s); the "Pick" toggles say which the laser is filling. Consume tool (on by default) removes the tool bodies.

var _target: Array = []
var _tool: Array = []
var _slot := "target"


func _init() -> void:
	id = "boolean"


func options(ed) -> Array:
	return [
		{"id": "bool_subtract", "text": "Subtract", "toggle": true, "pressed": str(ed.options["bool_op"]) == "subtract"},
		{"id": "bool_common", "text": "Common", "toggle": true, "pressed": str(ed.options["bool_op"]) == "common"},
		{"id": "slot_target", "text": "Pick target (%d)" % _count(ed, "target"), "toggle": true, "pressed": _slot == "target"},
		{"id": "slot_tool", "text": "Pick tool (%d)" % _count(ed, "tool"), "toggle": true, "pressed": _slot == "tool"},
		{"id": "bool_consume", "text": "Consume tool", "toggle": true, "pressed": bool(ed.options["bool_consume"])},
		{"id": "clear_bodies", "text": "Clear"},
		{"id": "apply", "text": "Apply", "disabled": not can_apply(ed)},
	]


func _count(ed, slot: String) -> int:
	return ed.bodies.size() if _slot == slot else (_target.size() if slot == "target" else _tool.size())


func _flush(ed) -> void:
	if _slot == "target":
		_target = ed.bodies.duplicate()
	else:
		_tool = ed.bodies.duplicate()


func _switch(ed, slot: String) -> void:
	_flush(ed)
	_slot = slot
	ed.bodies = (_target if slot == "target" else _tool).duplicate()
	ed._refresh_lit()


func handle_option(ed, option_id: String) -> bool:
	match option_id:
		"bool_subtract":
			ed.options["bool_op"] = "subtract"
		"bool_common":
			ed.options["bool_op"] = "common"
		"bool_consume":
			ed.options["bool_consume"] = not bool(ed.options["bool_consume"])
		"slot_target":
			_switch(ed, "target")
		"slot_tool":
			_switch(ed, "tool")
		"clear_bodies":
			_target.clear()
			_tool.clear()
			ed.clear_picks()
		_:
			return false
	return true


func on_activated(ed) -> void:
	_target.clear()
	_tool.clear()
	_slot = "target"
	ed.start_body_picks(0)
	ed.table.set_status("Pick the body to change, then press Pick tool and pick the body to use on it.")


func _ids(ed) -> Array:
	_flush(ed)
	return [_target.map(func(b): return str(b["body_id"])), _tool.map(func(b): return str(b["body_id"]))]


func can_apply(ed) -> bool:
	var ids := _ids(ed)
	return not (ids[0] as Array).is_empty() and not (ids[1] as Array).is_empty()


func preview_mode() -> String:
	return "eager"


func request(ed, _extra: Dictionary = {}) -> Dictionary:
	var ids := _ids(ed)
	return PartFeatures.boolean_request(str(ed.options["bool_op"]), ids[0], ids[1], bool(ed.options["bool_consume"]))


func edits_in_tool() -> bool:
	return true


func patch_keys() -> Array:
	return ["operation", "target_body_ids", "tool_body_ids", "consume_tool_bodies"]


func load_from_row(ed, row: Dictionary) -> void:
	ed.options["bool_op"] = str(row.get("operation", "subtract"))
	ed.options["bool_consume"] = bool(row.get("consume_tool_bodies", true))
	_target = (row.get("target_body_ids", []) as Array).map(func(b): return {"kind": "body", "body_id": str(b), "index": -1, "key": "solid:%s" % str(b)})
	_tool = (row.get("tool_body_ids", []) as Array).map(func(b): return {"kind": "body", "body_id": str(b), "index": -1, "key": "solid:%s" % str(b)})
	_slot = "target"
	ed.bodies = _target.duplicate()


func summary(f: Dictionary, _features: Array) -> String:
	return "%s, %d target(s) with %d tool(s)" % [str(f.get("operation", "subtract")).capitalize(), (f.get("target_body_ids", []) as Array).size(), (f.get("tool_body_ids", []) as Array).size()]


func done_text() -> String:
	return "Boolean done."
