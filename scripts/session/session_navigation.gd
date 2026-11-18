extends Node
## Moving yourself to other people in a live session (DIDSA-CAD plan P2: Go to presenter, Follow presenter, the presenter's Gather everyone).
##   Go to presenter  : your head goes to a spot 0.9 m to the presenter's right, at their eye height, turned the way they face. A short dark pulse hides the jump.
##   Follow presenter : your view rides theirs: each frame your head is eased towards that spot (at most 3 m/s and 70 degrees a second; a long way off, or Reduce motion, takes a jump with a
##                      pulse instead). The comfort vignette closes the edges of the view while it moves and opens again when it has caught up. Pushing the left stick stops it. Your presence says "following".
##   Gather everyone  : the presenter's button sends their head pose; each observer is placed in an arc in front of the presenter, facing them (28 degrees apart, 1.4 m out, ordered by their
##                      participant id), the same short pulse. Everyone obeys; it is a presenter's tool (an observer's message is dropped by the hub).
## All positions come from the avatars (session_avatars.gd): the presenter's last drawn head, in model space through this person's own view of the model. Feel and comfort are the
## owner's to judge on a headset; headless tests check the arithmetic and that the vignette is asked for.

const Protocol := preload("res://scripts/session/session_protocol.gd")
const Avatars := preload("res://scripts/session/session_avatars.gd")
const Vignette := preload("res://scripts/session/comfort_vignette.gd")
const Presence := preload("res://scripts/session/session_presence.gd")

const SIDE_OFFSET := 0.9 ## metres to the presenter's right
const FOLLOW_GAIN := 5.0 ## 1/s: how fast the view closes on the target
const FOLLOW_SPEED := 3.0 ## m/s at most
const FOLLOW_TURN_DEG := 70.0 ## degrees a second at most
const SNAP_DISTANCE := 8.0 ## further than this: a jump, not a glide
const REDUCE_MOTION_JUMP := 0.6 ## with Reduce motion, the view jumps when this far (metres) or ...
const REDUCE_MOTION_TURN_DEG := 25.0 ## ... this far round
const STICK_STOPS := 0.5
const GATHER_RADIUS := 1.4
const GATHER_STEP_DEG := 28.0
const PULSE_SECONDS := 0.35

signal following_changed(on: bool)

var main: Node
var client: Node
var avatars: Node3D
var vignette: MeshInstance3D
var following := false
var last_line := ""
var jumps := 0 ## teleports done (a test reads it)
var stick: Callable = func(hand: Node) -> Vector2: return hand.get_vector2("primary") ## the left stick (tests replace it)
var vignette_strength := 0.0 ## what was last asked of the vignette

var _move_strength := 0.0
var _pulse := 0.0
var _applied_gather_seq := 0
var _active := false


func start(p_main: Node, p_client: Node, p_avatars: Node3D) -> void:
	main = p_main
	client = p_client
	avatars = p_avatars
	_active = true
	following = false
	_applied_gather_seq = 0
	_move_strength = 0.0
	_pulse = 0.0
	if vignette == null or not is_instance_valid(vignette):
		vignette = Vignette.new()
		main.session_camera().add_child(vignette)
	if not client.message_received.is_connected(_on_message):
		client.message_received.connect(_on_message)
		client.presenter_resumed.connect(_on_presenter_resumed)


func stop() -> void:
	_active = false
	if following:
		following = false
		following_changed.emit(false)
	if client != null and client.message_received.is_connected(_on_message):
		client.message_received.disconnect(_on_message)
		client.presenter_resumed.disconnect(_on_presenter_resumed)
	if vignette != null and is_instance_valid(vignette):
		vignette.queue_free()
	vignette = null
	_move_strength = 0.0
	_pulse = 0.0


func _on_presenter_resumed() -> void:
	_applied_gather_seq = 0 # (its numbers start again)


# --- Where people are -----------------------------------------------------------------------------------------------------------

func presenter_id() -> int:
	return int(client.presenter().get("id", 0))


func presenter_head() -> Variant:
	## The presenter's head as drawn now (a world Transform3D), or null before any presence has arrived.
	return avatars.heads.get(presenter_id())


static func yaw_of(basis: Basis) -> float:
	## The heading of a basis: the angle about +Y that turns -Z to its forward direction (flattened). Rotating by it again adds to it.
	var forward := -basis.z
	forward.y = 0.0
	if forward.length() < 0.001:
		return 0.0
	forward = forward.normalized()
	return atan2(-forward.x, -forward.z)


static func spot_beside(head: Transform3D) -> Dictionary:
	## {position, yaw}: 0.9 m to the head's right (level), at its height, facing the way it does.
	var right := head.basis.x
	right.y = 0.0
	right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
	return {"position": head.origin + right * SIDE_OFFSET, "yaw": yaw_of(head.basis)}


static func gather_spot(head: Transform3D, rank: int, count: int) -> Dictionary:
	## {position, yaw} for observer `rank` of `count` in the arc in front of `head`: GATHER_RADIUS out, GATHER_STEP_DEG apart, centred on where the head faces, looking back at it.
	var forward := -head.basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length() > 0.001 else Vector3.FORWARD
	var angle := (float(rank) - float(count - 1) * 0.5) * deg_to_rad(GATHER_STEP_DEG)
	var direction := forward.rotated(Vector3.UP, angle)
	var position := head.origin + direction * GATHER_RADIUS
	return {"position": position, "yaw": yaw_of(Basis.looking_at(-direction, Vector3.UP))}


# --- Moving the rig -------------------------------------------------------------------------------------------------------------

func place_head(position: Vector3, yaw: float) -> void:
	## Puts the headset's view at `position` (world; eye height included) turned to `yaw`: the rig is turned about the head, then carried so the head is there.
	var rig: XROrigin3D = main.session_rig()
	var camera: XRCamera3D = main.session_camera()
	var delta := wrapf(yaw - yaw_of(camera.global_transform.basis), -PI, PI)
	turn_rig(delta)
	rig.global_position += position - camera.global_position


func turn_rig(delta: float) -> void:
	var rig: XROrigin3D = main.session_rig()
	var pivot: Vector3 = main.session_camera().global_position
	rig.global_position = pivot + (rig.global_position - pivot).rotated(Vector3.UP, delta)
	rig.rotate_y(delta)


func _jump_to(position: Vector3, yaw: float) -> void:
	place_head(position, yaw)
	jumps += 1
	_pulse = 1.0


# --- Go to, Follow ----------------------------------------------------------------------------------------------------------------

func go_to_presenter() -> bool:
	if client.is_presenter():
		_say("You are the presenter.")
		return false
	var head = presenter_head()
	if head == null:
		_say("Nothing from the presenter yet: their position has not arrived.")
		return false
	var spot := spot_beside(head)
	_jump_to(spot["position"], spot["yaw"])
	_say("Beside %s." % str(client.presenter().get("name", "the presenter")))
	return true


func set_following(on: bool) -> bool:
	## Starts or stops riding the presenter's viewpoint. False (and a line saying why) when it cannot start.
	if on == following:
		return true
	if on:
		if client.is_presenter():
			_say("You are the presenter: there is no one to follow.")
			return false
		if presenter_head() == null:
			_say("Nothing from the presenter yet: their position has not arrived.")
			return false
	following = on
	following_changed.emit(on)
	_say("Following %s: push the left stick to stop." % str(client.presenter().get("name", "the presenter")) if on else "Stopped following.")
	return true


func _process(delta: float) -> void:
	if not _active or main == null or client == null:
		return
	var wanted := 0.0
	if following:
		wanted = _follow(delta)
	_move_strength = lerpf(_move_strength, wanted, clampf(8.0 * delta, 0.0, 1.0))
	_pulse = maxf(0.0, _pulse - delta / PULSE_SECONDS)
	vignette_strength = maxf(_move_strength, _pulse)
	if vignette != null and is_instance_valid(vignette):
		vignette.strength = vignette_strength


func _follow(delta: float) -> float:
	## One frame of riding the presenter. Returns how hard the vignette should close (0 to 1).
	var left: Node = main.session_hands()[0]
	if stick.call(left).length() > STICK_STOPS:
		set_following(false)
		_say("Stopped following: you moved.")
		return 0.0
	var head = presenter_head()
	if head == null or delta <= 0.0:
		return 0.0
	var spot := spot_beside(head)
	var camera: Node3D = main.session_camera()
	var error: Vector3 = (spot["position"] as Vector3) - camera.global_position
	var yaw_error := wrapf(float(spot["yaw"]) - yaw_of(camera.global_transform.basis), -PI, PI)
	if error.length() > SNAP_DISTANCE:
		_jump_to(spot["position"], spot["yaw"])
		return 0.0
	if main.reduce_motion():
		if error.length() > REDUCE_MOTION_JUMP or absf(rad_to_deg(yaw_error)) > REDUCE_MOTION_TURN_DEG:
			_jump_to(spot["position"], spot["yaw"]) # (no gliding for someone who asked for less motion: a step, with the pulse)
		return 0.0
	var gain := clampf(FOLLOW_GAIN * delta, 0.0, 1.0)
	var step := error * gain
	if step.length() > FOLLOW_SPEED * delta:
		step = step.normalized() * FOLLOW_SPEED * delta
	var turn := yaw_error * gain
	var max_turn := deg_to_rad(FOLLOW_TURN_DEG) * delta
	turn = clampf(turn, -max_turn, max_turn)
	if turn != 0.0:
		turn_rig(turn)
	main.session_rig().global_position += step
	var speed := step.length() / delta
	var rate := absf(rad_to_deg(turn)) / delta
	return clampf(maxf(speed / 2.0, rate / 50.0), 0.0, 1.0)


# --- Gather -----------------------------------------------------------------------------------------------------------------------

func gather_everyone() -> bool:
	## The presenter calls everyone to where they stand: their head pose (model space) goes out and each observer places itself in the arc.
	if not client.is_presenter():
		_say("Only the presenter can gather everyone.")
		return false
	var presence := Presence.new()
	var head: Array = []
	var built: Dictionary = {}
	presence.main = main
	built = presence.build()
	presence.free()
	if built.is_empty():
		_say("Nothing to gather round: no model is open.")
		return false
	head = built["head"]
	if not client.send_state({"t": "gather", "pose": head}):
		_say("Not connected to the session.")
		return false
	var others: int = client.others().size()
	_say("Asked %d %s to gather round you." % [others, "person" if others == 1 else "people"])
	return true


func _on_message(message: Dictionary) -> void:
	if not _active or str(message.get("t", "")) != "gather" or client.is_presenter():
		return
	if message.has("seq"):
		if int(message["seq"]) <= _applied_gather_seq:
			return
		_applied_gather_seq = int(message["seq"])
	var scene_root: Node3D = main.session_scene_root()
	if scene_root == null:
		return
	var head = Avatars.world_of(message.get("pose"), scene_root.global_transform, main.session_unit_mm())
	if head == null:
		return
	var rank := 0
	var count := 0
	var me := int(client.me.get("id", -1))
	var ids: Array = []
	for id in client.participants:
		if str(client.participants[id].get("role", "")) != "presenter" and bool(client.participants[id].get("connected", true)):
			ids.append(int(id))
	ids.sort()
	count = ids.size()
	rank = maxi(ids.find(me), 0)
	var spot := gather_spot(head, rank, maxi(count, 1))
	_jump_to(spot["position"], spot["yaw"])
	_say("%s gathered everyone." % str(client.presenter().get("name", "The presenter")))


func _say(text: String) -> void:
	last_line = text
	if main != null:
		main.say(text)
