extends RefCounted
## Several parts handled as one: a sub-assembly that is held, or selected with the laser. One member is the ANCHOR (the part the grip or ray took); the
## controller moves that exactly as it moves any single part (the hand, the thumbstick, A / B), and `follow()` carries every other member by the same
## change, so rotating or pushing a group turns or slides the whole of it about the anchor's pivot.
##
## Saving: a group's move is saved as the move of ONE occurrence, the sub-assembly's, but only when that occurrence is a top-level one of its scope (depth 1:
## a placed sub-assembly of the loaded root, or of a room's Part) - the only kind the backend holds a pose for (mates_tool.gd is_managed). Deeper groups move
## on screen only, as a part nested in a sub-assembly always has.

const GroupIndex := preload("res://scripts/group_index.gd")

var members: Array = []
var anchor: Node3D
var depth := 0 ## path elements the group spans (1 = a top-level sub-assembly)
var prefix: Array = []
var root_part_id := ""
var label := ""
var starts: Dictionary = {} ## member -> its global transform when the group was taken
var _last_anchor := Transform3D.IDENTITY


func _init(p_anchor: Node3D, level: Dictionary) -> void:
	anchor = p_anchor
	members = (level["members"] as Array).duplicate()
	depth = int(level["depth"])
	prefix = (level["prefix"] as Array).duplicate()
	label = str(level["label"])
	root_part_id = str(p_anchor.get_meta("group_root", ""))
	reset_starts()


func reset_starts() -> void:
	starts.clear()
	for m in members:
		if is_instance_valid(m):
			starts[m] = (m as Node3D).global_transform
	_last_anchor = anchor.global_transform


func is_group() -> bool:
	return members.size() > 1


func occurrence_id() -> String:
	## The occurrence a move of this group is saved on, or "" if it can't be saved (not a top-level sub-assembly).
	return str(prefix[0]) if depth == 1 and not prefix.is_empty() else ""


func set_flag(key: String, on: bool) -> void:
	for m in members:
		if is_instance_valid(m):
			(m as Node3D).set_meta(key, on)


func follow() -> void:
	## Carries every member except the anchor by whatever the anchor has moved since the last call.
	if not is_instance_valid(anchor):
		return
	var now := anchor.global_transform
	var delta := now * _last_anchor.affine_inverse()
	_last_anchor = now
	if delta.is_equal_approx(Transform3D.IDENTITY):
		return
	for m in members:
		if m != anchor and is_instance_valid(m):
			(m as Node3D).global_transform = delta * (m as Node3D).global_transform


func restore() -> void:
	for m in starts:
		if is_instance_valid(m):
			(m as Node3D).global_transform = starts[m]
	_last_anchor = anchor.global_transform


func finals() -> Dictionary:
	var out := {}
	for m in members:
		if is_instance_valid(m):
			out[m] = (m as Node3D).global_transform
	return out


func net_delta() -> Transform3D:
	## The anchor's net world-space change since the group was taken.
	return anchor.global_transform * (starts[anchor] as Transform3D).affine_inverse()


func moved() -> bool:
	return not net_delta().is_equal_approx(Transform3D.IDENTITY)


static func apply(poses: Dictionary) -> void:
	for m in poses:
		if is_instance_valid(m):
			(m as Node3D).global_transform = poses[m]
