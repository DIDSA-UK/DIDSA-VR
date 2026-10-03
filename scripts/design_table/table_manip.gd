extends RefCounted
## Handling the part that is on the design table, entirely on the TABLE'S COPY and independent of the arena: the
## real part's pose, the model's pose and the world's scale are never touched while the part is on the table.
##
##   * ONE hand gripping the part moves it (it follows the hand 1:1, through the same steadiness filter as an arena
##     part). Turning stays two-handed so a wrist twitch never spins it.
##   * TWO hands gripping it move it with the midpoint between them, turn it as the line between them swings and scale it
##     as they spread or close, all about the midpoint (table_pose.gd). The second grip may be anywhere over the table.
##   * The right STICK spins it about the slab's up axis and tips it; A pulls it nearer, B pushes it farther. These
##     belong to the table only while it is ENGAGED.
##   * LETTING GO over the slab leaves it on the table; letting go beyond it sends the real part back to the arena
##     where you let go (design_table.gd: send_to_arena).
##
## ENGAGED is automatic, no button: a hand is gripping the part, or the right laser is on the part or its sketch sheet
## (and not on the tool deck, which claims the stick for itself). The table shows it (the slab's frame glows, a
## "Table active" chip appears on the deck) and ticks the right hand as it comes and goes; a short grace period keeps
## it from flickering as the laser sweeps across the edge of the part. It is the same rule that makes the stick scroll
## a window when the laser is on it.
##
## Gripping the part sets a "table_part_held" meta on the hand (the convention "window_held" and "section_gizmo_held"
## already use), which two_hand_model.gd reads so the grip doesn't also drag the world.

signal engaged_changed(on: bool)

const TablePose := preload("res://scripts/design_table/table_pose.gd")
const TableSeat := preload("res://scripts/design_table/table_seat.gd")
const OneEuro := preload("res://scripts/one_euro.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const ENGAGE_GRACE := 0.15 ## seconds the laser may be off the part before the table lets go of the stick
const LASER_MARGIN := 1.4 ## the laser counts as "on the part" within this multiple of its bounding sphere (the sketch sheet is bigger than the part)
const MIN_HEIGHT := 0.05 ## metres: a part left on the table keeps its middle at least this far above the slab

var rotate_speed_degrees := 90.0
var nudge_rate := 0.6 ## A / B move the part this fraction of its distance from your hand every second
var nudge_min_speed := 0.05
var nudge_max_speed := 0.5
var nudge_min_distance := 0.15 ## A stops pulling the part this close to your hand
var stick_deadzone := 0.15
var engaged := false
var carry_outside := false ## a hand is carrying the part past the slab: letting go sends it to the arena

var _table ## design_table.gd
var _grips := {} ## hand -> {offset: Vector3 (part middle minus hand, console frame), filter: OneEuro}
var _prev := {} ## hand -> its filtered console-frame position last frame (two-hand grips)
var _lost_for := 0.0


func setup(table) -> void:
	_table = table


func is_gripping() -> bool:
	return not _grips.is_empty()


func grip_count() -> int:
	return _grips.size()


func owns_stick(hand: Object) -> bool:
	## True for the right hand while the table is engaged: the controller and locomotion leave its stick and A/B to us.
	return engaged and hand == _table._right


# --- Gripping ---------------------------------------------------------------------------

func try_grab(hand: XRController3D) -> bool:
	## controller.gd asks on every grip. True if this grip is now on the part on the table.
	if not _table.is_open() or _table.seated == null or _table.pivot == null or _grips.has(hand) or _grips.size() >= 2:
		return false
	var touching: bool = hand.global_position.distance_to(_table.pivot.global_position) <= _table.part_radius() + _table.lift_reach
	if not touching and _table.editor != null and _table.editor.sheet_reaches(hand.global_position):
		touching = true # with a sketch open the whole sheet is the thing to grab, not only the part's own bounding sphere
	if not touching:
		# A second hand may join from anywhere over the table, so you don't have to find the part with both.
		if _grips.is_empty() or not TableSeat.in_drop_zone(_table.to_local(hand.global_position), _table.slab_size, _table.drop_floor, _table.drop_ceiling):
			return false
	_table.stop_pose_tween()
	var filter := OneEuro.new()
	var level := clampi(int(hand.get("steadiness") if hand.get("steadiness") != null else 2), 0, TwoHandModel.STEADINESS_NAMES.size() - 1)
	filter.min_cutoff = maxf(TwoHandModel.STEADINESS_CUTOFF_HZ[level], 0.01)
	filter.beta = TwoHandModel.STEADINESS_BETA
	filter.reset(hand.global_position)
	_grips[hand] = {"offset": Vector3.ZERO, "filter": filter, "steady": level > 0}
	hand.set_meta("table_part_held", true)
	_rebase()
	UiFeedback.haptic(hand, "grab")
	_set_engaged(true)
	_lost_for = 0.0
	return true


func release(hand: Object) -> bool:
	## controller.gd calls this when a grip lets go. True if this hand was holding the part. When the LAST hand lets go,
	## the part either stays on the table or goes back to the arena, depending on where it is.
	if not _grips.has(hand):
		return false
	_grips.erase(hand)
	_prev.erase(hand)
	if is_instance_valid(hand):
		hand.set_meta("table_part_held", false)
	if _grips.is_empty():
		_finish()
	else:
		_rebase() # one hand left: carry on moving it from where it is, no jump
	return true


func cancel() -> void:
	## The part left the table (closed, returned, or the model was replaced): drop every grip without deciding anything.
	for hand in _grips.keys():
		if is_instance_valid(hand):
			hand.set_meta("table_part_held", false)
	_grips.clear()
	_prev.clear()
	_set_carry_outside(false)
	_set_engaged(false)
	_lost_for = 0.0


func _rebase() -> void:
	## Re-measures the grips from the part's pose right now, so going between one and two hands never jumps.
	for hand in _grips:
		var local: Vector3 = _table.to_local(hand.global_position)
		_grips[hand]["offset"] = _table.pivot.position - local
		(_grips[hand]["filter"] as OneEuro).reset(hand.global_position)
		_prev[hand] = local


func _finish() -> void:
	_set_carry_outside(false)
	if _table.seated == null or _table.pivot == null:
		return
	var centre: Vector3 = _table.pivot.position
	if _table.editing_sketch():
		# A sketch is open on the part: letting go beyond the slab must not send the real part away (that would end the sketch), so it is
		# held back over the slab.
		centre = TablePose.clamp_to_zone(centre, _table.slab_size, MIN_HEIGHT, _table.drop_ceiling)
		_table.pivot.position = centre
		UiFeedback.haptic(_table._right, "confirm")
	elif TableSeat.in_drop_zone(centre, _table.slab_size, _table.drop_floor, _table.drop_ceiling):
		centre.y = maxf(centre.y, MIN_HEIGHT)
		_table.pivot.position = centre
		UiFeedback.haptic(_table._right, "confirm")
	else:
		_table.send_to_arena(_table.pivot.global_position)


# --- Per frame ------------------------------------------------------------------------------

func process(delta: float) -> void:
	if _table.seated == null or _table.pivot == null or not _table.is_open():
		if not _grips.is_empty() or engaged:
			cancel()
		return
	for hand in _grips.keys():
		if not is_instance_valid(hand):
			_grips.erase(hand)
			_prev.erase(hand)
	if _grips.is_empty() and _prev.size() > 0:
		_prev.clear()
	match _grips.size():
		1:
			_follow_one(delta)
		2:
			_follow_two(delta)
	_set_carry_outside(not _grips.is_empty() and not _table.editing_sketch() and not TableSeat.in_drop_zone(_table.pivot.position, _table.slab_size, _table.drop_floor, _table.drop_ceiling))
	_update_engaged(delta)
	if engaged:
		var right: XRController3D = _table._right
		drive_input(right.get_vector2("primary"), right.is_button_pressed("ax_button"), right.is_button_pressed("by_button"), delta)


func _steady(hand: Object, delta: float) -> Vector3:
	var g: Dictionary = _grips[hand]
	var raw: Vector3 = hand.global_position
	return (g["filter"] as OneEuro).filter(raw, delta) if bool(g["steady"]) else raw


func _follow_one(delta: float) -> void:
	var hand: Object = _grips.keys()[0]
	var local: Vector3 = _table.to_local(_steady(hand, delta))
	_table.pivot.position = local + (_grips[hand]["offset"] as Vector3)
	_prev[hand] = local


func _follow_two(delta: float) -> void:
	var keys := _grips.keys() # insertion order is stable, and only the line between the two hands matters
	var left: Object = keys[0]
	var right: Object = keys[1]
	var l: Vector3 = _table.to_local(_steady(left, delta))
	var r: Vector3 = _table.to_local(_steady(right, delta))
	var step := TablePose.two_hand(_prev.get(left, l), _prev.get(right, r), l, r, _table.pivot.position, _table.pivot.basis.orthonormalized(), _table.user_scale, not _table.sketch_locked(), _table.max_user_scale())
	_table.apply_pose(step["centre"], step["rotation"], step["scale"])
	_prev[left] = l
	_prev[right] = r


func drive_input(stick: Vector2, pull: bool, push: bool, delta: float) -> void:
	## The right stick and A / B while engaged. Split out so tests can drive it without an XR runtime.
	if _table.pivot == null or _table.seated == null:
		return
	var right: XRController3D = _table._right
	if bool(right.get_meta("ui_hover", false)):
		return # the laser is on the tool deck: the stick is the deck's, not the part's
	if stick.length() >= stick_deadzone and not _table.sketch_locked(): # the sketch is tilted to face you: the stick must not spin or tip it away
		_table.stop_pose_tween()
		_table.apply_pose(_table.pivot.position, TablePose.stick_turn(_table.pivot.basis.orthonormalized(), stick, delta, rotate_speed_degrees), _table.user_scale)
	var direction := 0.0
	if pull:
		direction -= 1.0
	if push:
		direction += 1.0
	if direction != 0.0:
		_table.stop_pose_tween()
		var hand_local: Vector3 = _table.to_local(right.global_position)
		var aim: Vector3 = _table.global_transform.basis.inverse() * (-right.global_transform.basis.z)
		var speed := clampf(nudge_rate * hand_local.distance_to(_table.pivot.position), nudge_min_speed, nudge_max_speed)
		var moved := TablePose.nudge(_table.pivot.position, hand_local, aim, direction, speed, delta, nudge_min_distance)
		if _grips.is_empty():
			moved = TablePose.clamp_to_zone(moved, _table.slab_size, MIN_HEIGHT, _table.drop_ceiling) # a nudge never walks it off the table
		var shift: Vector3 = moved - _table.pivot.position
		_table.pivot.position = moved
		for hand in _grips:
			_grips[hand]["offset"] = (_grips[hand]["offset"] as Vector3) + shift # a held part keeps the hold you have on it


# --- Engagement ---------------------------------------------------------------------------

func _update_engaged(delta: float) -> void:
	var want := not _grips.is_empty()
	if not want:
		want = laser_on_part()
	if want:
		_lost_for = 0.0
		_set_engaged(true)
	elif engaged:
		_lost_for += delta
		if _lost_for >= ENGAGE_GRACE:
			_set_engaged(false)


func laser_on_part() -> bool:
	## The right laser is on the part or its sketch sheet, and not on the tool deck or a window.
	var right: XRController3D = _table._right
	if right == null or bool(right.get_meta("ui_hover", false)):
		return false
	if _table.editor != null and _table.editor.hovering:
		return true
	return TablePose.ray_near_sphere(right.global_position, -right.global_transform.basis.z, _table.pivot.global_position, _table.part_radius() * LASER_MARGIN)


func _set_engaged(on: bool) -> void:
	if engaged == on:
		return
	engaged = on
	if on and _grips.is_empty():
		UiFeedback.haptic(_table._right, "press") # entered by laser: a tick (entered by grip, the grab tick already says it)
	elif not on:
		UiFeedback.haptic(_table._right, "close")
	engaged_changed.emit(on)


func _set_carry_outside(on: bool) -> void:
	if carry_outside == on:
		return
	carry_outside = on
	_table.set_leave_cue(on)
	if on:
		UiFeedback.haptic(_table._right, "hover")
