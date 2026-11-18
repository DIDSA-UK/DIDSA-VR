extends Node
## What THIS person sends the others in a live session (DIDSA-CAD docs/live-sessions-scope.md, section 4.4): the head, the two hands, where the laser ends, and what mode they are in,
## all in MODEL SPACE (millimetres, relative to the glb root), so the avatar is right whatever scale or place each person sees the model at. Both roles send it.
## 15 Hz while anything changed by more than 2 mm or 1 degree, 1 Hz otherwise; the client's send guard drops presence first when a presenter is also streaming poses. A hand with no
## tracking data is null; the laser is the right hand's, or null when none is drawn. Nothing is sent while there is no model (nothing to be relative to).

const Protocol := preload("res://scripts/session/session_protocol.gd")

const MOVING_HZ := 15.0
const IDLE_S := 1.0
const MOVE_MM := 2.0
const TURN_DEG := 1.0

var main: Node
var client: Node
var navigation: Node ## session_navigation.gd: its `following` says the mode
var sent_count := 0
var hand_tracked: Callable = func(hand: Node) -> bool: return hand.get_has_tracking_data() ## tests replace it (there is no tracking headless)
var last_message: Dictionary = {}

var _active := false
var _since_send := 0.0
var _last_pose: Array = [] ## the head and hands as last sent, to see whether anything moved


func start(p_main: Node, p_client: Node, p_navigation: Node = null) -> void:
	main = p_main
	client = p_client
	navigation = p_navigation
	_active = true
	_since_send = IDLE_S
	_last_pose = []
	sent_count = 0


func stop() -> void:
	_active = false


func _process(delta: float) -> void:
	if not _active or main == null or client == null or not client.is_live():
		return
	_since_send += delta
	if _since_send < 1.0 / MOVING_HZ:
		return
	var message := build()
	if message.is_empty():
		return
	var poses := _poses_of(message)
	if _since_send >= IDLE_S or moved(poses, _last_pose):
		_since_send = 0.0
		_last_pose = poses
		last_message = message
		if client.send(message):
			sent_count += 1


func build() -> Dictionary:
	## The presence message now, or {} when there is no model to be relative to.
	var scene_root: Node3D = main.session_scene_root()
	if scene_root == null or not is_instance_valid(scene_root):
		return {}
	var inverse := scene_root.global_transform.affine_inverse()
	var unit: float = main.session_unit_mm()
	var camera: Node3D = main.session_camera()
	var hands: Array = []
	for hand in main.session_hands():
		hands.append(pose_of(hand.global_transform, inverse, unit) if hand_tracked.call(hand) else null)
	var laser = null
	var right: Node = main.session_hands()[1]
	if right.has_method("laser_tip") and hands[1] != null:
		var tip = right.laser_tip()
		if tip != null:
			var m: Vector3 = (inverse * (tip as Vector3)) * unit
			laser = [snappedf(m.x, Protocol.POSITION_STEP), snappedf(m.y, Protocol.POSITION_STEP), snappedf(m.z, Protocol.POSITION_STEP)]
	var mode := "following" if navigation != null and navigation.following else "free"
	return {"t": "presence", "head": pose_of(camera.global_transform, inverse, unit), "hands": hands, "laser": laser, "cursor": null, "mode": mode}


static func pose_of(world: Transform3D, inverse_model: Transform3D, unit_mm: float) -> Array:
	## A world transform as a 7-number pose in model space: position in mm, then the rotation as a quaternion (the scale of the model removed).
	var local := inverse_model * world
	return Protocol.pose_to_array(local.origin * unit_mm, local.basis.orthonormalized().get_rotation_quaternion())


static func moved(a: Array, b: Array) -> bool:
	## Whether any pose moved by more than 2 mm or 1 degree since the last one sent (a hand appearing or disappearing counts).
	if a.size() != b.size():
		return true
	for i in a.size():
		var pa = a[i]
		var pb = b[i]
		if (pa == null) != (pb == null):
			return true
		if pa == null:
			continue
		var d := Vector3(float(pa[0]) - float(pb[0]), float(pa[1]) - float(pb[1]), float(pa[2]) - float(pb[2])).length()
		if d > MOVE_MM:
			return true
		var qa := Quaternion(float(pa[3]), float(pa[4]), float(pa[5]), float(pa[6])).normalized()
		var qb := Quaternion(float(pb[3]), float(pb[4]), float(pb[5]), float(pb[6])).normalized()
		if rad_to_deg(qa.angle_to(qb)) > TURN_DEG:
			return true
	return false


static func _poses_of(message: Dictionary) -> Array:
	var out: Array = [message["head"]]
	out.append_array(message["hands"])
	return out
