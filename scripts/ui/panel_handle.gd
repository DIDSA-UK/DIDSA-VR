extends RefCounted
## The "grab me to move this" handle shared by every free-floating panel: floating
## windows (diegetic_panel.gd) and the popup keyboard. A small pill at the centre of
## the panel's lower edge; GRIP it with either hand to carry the whole panel along
## 1:1, release to drop it. Extracted from diegetic_panel.gd so the keyboard gets
## exactly the same behaviour instead of a second copy.
##
## Self-contained: it listens to both controllers' grip itself (not routed through
## controller.gd's part-grab search). The host does two things: calls follow() each
## frame (it returns true while being carried), and exposes in_reach() to
## controller.gd via a `handle_in_reach(hand)` method and the "diegetic_panels" group,
## so a grip aimed at a panel's handle never also grabs a part or the section gizmo.
##
## Grabbing sets a "window_held" meta on the hand (the same convention as
## section_tool.gd's "section_gizmo_held") so two_hand_model.gd's _hand_free() doesn't
## also drag the whole model with the same grip press — real-headset feedback:
## grabbing a window moved the world too. clear() undoes it, and the host must call
## clear() when it closes mid-grab or the hand's meta stays true and blocks model drags.

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

signal grabbed(hand: XRController3D)
signal dropped(hand: XRController3D)

var node: MeshInstance3D ## the pill; null until build()
var held_by: XRController3D = null
var grab_action := "grip_click"
var reach_slack := 0.03 ## metres beyond the pill's own radius: it's small, so a bit of slack makes it easier to catch
var idle_colour := Color(0.60, 0.70, 0.80)
var held_colour := Color(0.31, 0.77, 1.0)
var drop_distance := 0.02 ## metres below the panel's lower edge

var _host: Node3D
var _is_open: Callable
var _material: StandardMaterial3D
var _grab_offset := Transform3D.IDENTITY


func setup(host: Node3D, left: XRController3D, right: XRController3D, is_open: Callable, tokens: Resource = null) -> void:
	_host = host
	_is_open = is_open
	if tokens != null:
		idle_colour = tokens.text_dim
		held_colour = tokens.accent
	left.button_pressed.connect(_on_pressed.bind(left))
	left.button_released.connect(_on_released.bind(left))
	right.button_pressed.connect(_on_pressed.bind(right))
	right.button_released.connect(_on_released.bind(right))


func build(panel_size: Vector2) -> MeshInstance3D:
	node = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.008
	capsule.height = 0.05
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.emission_enabled = true
	_material.emission = idle_colour
	_material.albedo_color = idle_colour
	capsule.material = _material
	node.mesh = capsule
	node.rotation_degrees.z = 90.0 # a capsule's long axis is local Y; lay it along the panel's lower edge
	_host.add_child(node)
	layout(panel_size)
	return node


func set_colours(idle: Color, held: Color) -> void:
	idle_colour = idle
	held_colour = held
	if _material:
		var c := held_colour if held_by != null else idle_colour
		_material.albedo_color = c
		_material.emission = c


func layout(panel_size: Vector2) -> void:
	if node:
		node.position = Vector3(0.0, -panel_size.y * 0.5 - drop_distance, 0.01)


func in_reach(hand: Node3D) -> bool:
	if node == null or not _is_open.call() or not _host.visible:
		return false
	var reach: float = (node.mesh as CapsuleMesh).radius + reach_slack
	return hand.global_position.distance_to(node.global_position) <= reach


func follow() -> bool:
	## Call every frame. While carried: the host's pose is the holding hand's, 1:1
	## (a floating panel isn't a precision placement task, so no steadiness filter).
	if held_by == null:
		return false
	_host.global_transform = held_by.global_transform * _grab_offset
	return true


func clear() -> void:
	## Release + drop the hand meta; safe to call when nothing is held.
	var hand := held_by
	if hand != null and is_instance_valid(hand):
		hand.set_meta("window_held", false)
	held_by = null
	if _material:
		_material.albedo_color = idle_colour
		_material.emission = idle_colour
	if hand != null and is_instance_valid(hand):
		dropped.emit(hand)


func _on_pressed(action_name: String, hand: XRController3D) -> void:
	if action_name != grab_action or not _is_open.call() or held_by != null:
		return
	if in_reach(hand):
		held_by = hand
		hand.set_meta("window_held", true)
		_grab_offset = hand.global_transform.affine_inverse() * _host.global_transform
		_material.albedo_color = held_colour
		_material.emission = held_colour
		UiFeedback.haptic(hand, "grab")
		UiFeedback.play("grab", _host)
		grabbed.emit(hand)


func _on_released(action_name: String, hand: XRController3D) -> void:
	if action_name == grab_action and held_by == hand:
		clear()
