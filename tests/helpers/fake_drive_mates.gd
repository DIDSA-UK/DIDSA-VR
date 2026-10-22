extends Node
## A stand-in for mates_tool.gd for tests/drive_tool.gd: records the calls the Drive tool makes, shows the wish as is, and turns a follower the opposite way
## by half the driven part's turn about Z (a 1 : 2 gear pair). Not a test.

var managed := true
var locked := false
var constrained := true
var drag := false
var desired := Transform3D.IDENTITY
var calls: Array = []
var followers := {}
var stuck_once := false
var _start_angle := 0.0
var _started := false


func is_managed(_p: Node3D) -> bool:
	return managed


func is_locked(_p: Node3D) -> bool:
	return locked


func is_constrained(_p: Node3D) -> bool:
	return constrained


func notify_locked(_p: Node3D) -> void:
	calls.append("locked")


func has_drag(_p: Node3D) -> bool:
	return drag


func desired_global(_p: Node3D) -> Transform3D:
	return desired


func drag_member_nodes(_p: Node3D) -> Dictionary:
	return followers.duplicate()


func take_stuck_notice(_p: Node3D) -> bool:
	var once := stuck_once
	stuck_once = false
	return once


func constrain_drag(_p: Node3D, wish: Transform3D) -> Transform3D:
	calls.append("constrain")
	drag = true
	desired = wish
	var angle := atan2(wish.basis.x.y, wish.basis.x.x)
	_started = true
	for node in followers.values():
		(node as Node3D).global_transform = Transform3D(Basis(Vector3.BACK, -0.5 * (angle - _start_angle)), (node as Node3D).global_transform.origin)
	return wish


func end_drag(_p: Node3D) -> bool:
	calls.append("end")
	drag = false
	_started = false
	return true
