extends Node
## Whole-model manipulation (vision brief mode 1, "Model movement"), plus the
## scale views (mode 4).
##
## Grips on EMPTY space (a hand that grabbed a part sits out):
##  - ONE hand: the model follows that hand, translation only, like dragging a
##    drawing across a table. Turning stays two-handed so a small wrist twitch
##    never spins your model. The drag is amplified for big models (see
##    one_hand_gain_*): a model 10 m across would otherwise need you to
##    shuffle it a metre at a time with your arm.
##  - TWO hands: it follows your hands like a rope between two fists. Moving
##    them together drags it (amplified for big models by the same
##    size-based gain as one-hand drag — see one_hand_drag_gain(), measured
##    once per gesture and applied to the midpoint's own movement so big
##    models don't need endless re-grabbing two-handed either), swinging the
##    line between them turns it (shortest-arc, so it never rolls about that
##    line, and NOT gain-amplified — a given wrist swing always turns the
##    model by the same angle regardless of size), spreading/closing them
##    scales it (also ungained; scale_gain is its own separate sensitivity
##    knob). Turn/scale pivot on a virtual point that tracks the (gained)
##    drag rather than your hands' literal midpoint, since on a big model
##    that point can end up well away from where your hands physically are.
##    Each frame applies only how your hands moved SINCE THE LAST FRAME, on top
##    of the model's current pose. (Measuring against the pose at the start of
##    the grab instead made a second rotation about a different axis feel
##    anchored to the model's orientation before the first one.)
## Going between one and two hands re-baselines, so the model never jumps.
##
## Steadiness: your hand positions go through an adaptive filter (one_euro.gd)
## before they move the model, so a hand held "still" doesn't make it shake,
## while deliberate moves stay direct. Levels below; the tablet sets it.
##
## Scale views: set_preset() jumps to a multiple of real life (1.0 = 1:1),
## about the model's centre. scale_locked stops presets, Fit and the two-hand
## spread/close from changing scale; dragging and turning still work.
## fit_to_view() brings the whole model in front of you at a comfortable size
## (CAD's "zoom to extents"); go_home() returns it to where it first loaded.
## The wrist tablet drives these; no thumbstick clicks are used (the right one
## is reserved for the popup keyboard).

const OneEuro := preload("res://scripts/one_euro.gd")
const STEADINESS_NAMES: Array[String] = ["Off", "Light", "Medium", "Strong"]
const STEADINESS_CUTOFF_HZ: Array[float] = [0.0, 3.0, 1.5, 0.8] ## lower = steadier when still (and slower to settle)
const STEADINESS_BETA := 10.0 ## Hz per m/s: how quickly the filter opens up when the hand moves

@export var min_multiple: float = 0.1 ## smallest scale, as a multiple of real life
@export var max_multiple: float = 50.0 ## largest
@export var grab_action: String = "grip_click"
@export var presets: Array[float] = [0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0] ## multiples of real life; 1.0 = 1:1
@export var scale_gain: float = 3.0 ## how strongly spreading/closing your hands scales: hands 10% farther apart = 1.1^gain (~33%) bigger
@export var one_hand_gain_ref_radius: float = 0.6 ## metres: a model this size (or smaller, half its bounding diagonal) drags 1:1 — shared by one- and two-hand drag
@export var one_hand_gain_max: float = 15.0 ## a bigger model drags proportionally faster, up to this multiple — shared by one- and two-hand drag
@export var fit_radius: float = 0.5 ## metres: half the model's bounding diagonal after Fit
@export var fit_distance: float = 1.2 ## metres in front of your head after Fit

var enabled := true ## mode switch on the wrist tablet
var scale_locked := false
var steadiness := 2 ## index into STEADINESS_NAMES

enum Mode { NONE, ONE_HAND, TWO_HAND }

var _root: Node3D
var _left: XRController3D
var _right: XRController3D
var _real_life_scale := 0.001
var _home: Transform3D
var _has_home := false

var _mode := Mode.NONE
var _one_hand: XRController3D
var _start_root: Transform3D
var _left_filter := OneEuro.new()
var _right_filter := OneEuro.new()
var _one_hand_gain := 1.0
var _start_hand := Vector3.ZERO
var _prev_mid := Vector3.ZERO
var _prev_vec := Vector3.ZERO
var _two_hand_gain := 1.0 ## same size-based gain as one-hand drag, measured once per gesture
var _prev_pivot := Vector3.ZERO ## virtual pivot the transform is built around each frame — tracks _prev_mid with gain applied, so it can drift from where your hands actually are on a big model
var _gesture_active := false
var _gesture_start_transform: Transform3D
var command_stack = null ## set via setup(); a shared command_stack.gd instance for undo/redo


func setup(root: Node3D, left: XRController3D, right: XRController3D, real_life_scale: float, stack = null) -> void:
	_root = root
	_left = left
	_right = right
	_real_life_scale = real_life_scale
	command_stack = stack


func _init() -> void:
	set_steadiness(steadiness)


func set_steadiness(level: int) -> void:
	steadiness = clampi(level, 0, STEADINESS_NAMES.size() - 1)
	for f in [_left_filter, _right_filter]:
		f.min_cutoff = maxf(STEADINESS_CUTOFF_HZ[steadiness], 0.01)
		f.beta = STEADINESS_BETA


func one_hand_drag_gain() -> float:
	## How far the model moves per unit your hand moves: 1 for anything you can
	## reach around, growing in proportion to the model's size beyond that.
	## Measured once when the grab starts, so it can't feed back on itself.
	## Despite the name, also used by two-hand drag (_update_two_hand()) —
	## the same "big models need amplified dragging" problem applies to both.
	var radius := _model_bounds().size.length() * 0.5
	return clampf(radius / one_hand_gain_ref_radius, 1.0, one_hand_gain_max)


func set_real_life_scale(scale_value: float) -> void:
	## What assembly_root's scale is at 1:1. The backend's glb is in mm (0.001);
	## a local .glb is normally in metres (1.0).
	_real_life_scale = scale_value


func remember_home() -> void:
	_home = _root.global_transform
	_has_home = true


func is_active() -> bool:
	return _mode != Mode.NONE


func current_multiple() -> float:
	return _current_multiple()


func scale_text() -> String:
	## e.g. "scale 1:1", "scale 2:1 (locked)" — for the on-screen readout.
	if _root == null:
		return ""
	var ratio := _current_multiple()
	var text: String
	if ratio >= 1.0:
		text = "%s:1" % _trim(ratio)
	else:
		text = "1:%s" % _trim(1.0 / ratio)
	return "scale %s%s" % [text, " (locked)" if scale_locked else ""]


func set_preset(multiple: float) -> void:
	## Jump to `multiple` times real life (1.0 = 1:1), about the model's centre.
	if scale_locked or _mode == Mode.TWO_HAND or _root == null:
		return
	var before := _root.global_transform
	var factor := _clamped_multiple(multiple) / _current_multiple()
	_scale_about(_model_bounds().get_center(), factor)
	_push_move_command("scale to %s" % _ratio_hint(multiple), before)


func fit_to_view(camera: Node3D) -> void:
	## Bring the whole model in front of you, centred, at a size that fits.
	## Locked scale: it's moved but not resized.
	if _root == null or _model_bounds().size == Vector3.ZERO:
		return
	var before := _root.global_transform
	var box := _model_bounds()
	var factor := 1.0
	if not scale_locked:
		var radius := box.size.length() * 0.5
		var target_multiple := _clamped_multiple(_current_multiple() * fit_radius / radius)
		factor = target_multiple / _current_multiple()

	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	var target_centre := camera.global_position + forward * fit_distance
	target_centre.y = camera.global_position.y - 0.2

	var t := _root.global_transform
	_root.global_transform = Transform3D(t.basis * factor, target_centre + (t.origin - box.get_center()) * factor)
	_push_move_command("fit to view", before)


func go_home() -> void:
	## Back to where the model first appeared. Not while the scale is locked
	## (that would silently change it).
	if _has_home and not scale_locked and _mode == Mode.NONE:
		var before := _root.global_transform
		_root.global_transform = _home
		_push_move_command("go home", before)


func _push_move_command(label: String, before: Transform3D) -> void:
	if command_stack == null or _root == null:
		return
	var after := _root.global_transform
	if before.is_equal_approx(after):
		return # no net change: nothing worth undoing
	var target := _root
	command_stack.push(label,
		func() -> void: target.global_transform = before,
		func() -> void: target.global_transform = after)


func _ratio_hint(multiple: float) -> String:
	return "%s:1" % _trim(multiple) if multiple >= 1.0 else "1:%s" % _trim(1.0 / multiple)


func _process(delta: float) -> void:
	if _root == null or _left == null or _right == null:
		return

	var left_free := enabled and _hand_free(_left)
	var right_free := enabled and _hand_free(_right)
	var left_pos := _steady(_left_filter, _left.global_position, left_free, delta)
	var right_pos := _steady(_right_filter, _right.global_position, right_free, delta)

	if left_free and right_free and (right_pos - left_pos).length() >= 0.05:
		_update_two_hand(left_pos, right_pos)
	elif left_free != right_free:
		_update_one_hand(_left if left_free else _right, left_pos if left_free else right_pos)
	else:
		_end_gesture()
		_mode = Mode.NONE


func _begin_gesture() -> void:
	## One undo step per drag, however it moved between one and two hands —
	## only remember the transform from the FIRST frame of a fresh gesture.
	if not _gesture_active:
		_gesture_active = true
		_gesture_start_transform = _root.global_transform


func _end_gesture() -> void:
	if not _gesture_active:
		return
	_gesture_active = false
	_push_move_command("move model", _gesture_start_transform)


func _steady(filter: RefCounted, raw: Vector3, gripping: bool, delta: float) -> Vector3:
	## The filter only matters while a hand is on the model; otherwise keep it
	## parked on the raw position so it starts fresh the moment you grab.
	if steadiness == 0:
		return raw
	if not gripping:
		filter.reset(raw)
		return raw
	return filter.filter(raw, delta)


func _update_one_hand(hand: XRController3D, hand_pos: Vector3) -> void:
	if _mode != Mode.ONE_HAND or _one_hand != hand:
		_mode = Mode.ONE_HAND
		_one_hand = hand
		_start_root = _root.global_transform
		_start_hand = hand_pos
		_one_hand_gain = one_hand_drag_gain()
		_begin_gesture()
		return
	var t := _start_root
	t.origin += (hand_pos - _start_hand) * _one_hand_gain
	_root.global_transform = t


func _update_two_hand(left_pos: Vector3, right_pos: Vector3) -> void:
	var vec := right_pos - left_pos
	var mid := (left_pos + right_pos) * 0.5
	if _mode != Mode.TWO_HAND:
		_mode = Mode.TWO_HAND
		_prev_mid = mid
		_prev_vec = vec
		_prev_pivot = mid # virtual pivot starts exactly at your hands' real midpoint
		_two_hand_gain = one_hand_drag_gain() # measured once, like one-hand's own gain, so it can't feed back on itself
		_begin_gesture()
		return

	# The change since last frame: how far the line between the hands swung
	# (shortest-arc), and how much it lengthened or shortened.
	var rot := Basis(_shortest_arc(_prev_vec.normalized(), vec.normalized()))
	var scale_factor := 1.0
	if not scale_locked:
		var current := _current_multiple()
		# Raised to scale_gain, so a small spread goes a long way. Because each frame's ratio
		# telescopes, the total is still (hand distance now / at grab)^gain, whatever the path.
		scale_factor = _clamped_multiple(current * pow(vec.length() / _prev_vec.length(), scale_gain)) / current

	# The DRAG (how far the midpoint itself moved this frame) gets the same
	# size-based amplification one-hand drag gets; turn/scale above are
	# deliberately left at their own raw/gain_gain sensitivity, unaffected.
	var pivot := _prev_pivot + (mid - _prev_mid) * _two_hand_gain

	# Turn/scale the model about where the (gain-amplified) pivot WAS, then hang it off where it is now.
	var t := _root.global_transform
	_root.global_transform = Transform3D(
		(rot * t.basis) * scale_factor,
		pivot + (rot * (t.origin - _prev_pivot)) * scale_factor
	)
	_prev_mid = mid
	_prev_vec = vec
	_prev_pivot = pivot


func _hand_free(hand: XRController3D) -> bool:
	if not hand.is_button_pressed(grab_action):
		return false
	return _hand_free_ignoring_button(hand)


func _hand_free_ignoring_button(hand: XRController3D) -> bool:
	## The part of _hand_free() that doesn't read the live grip state (which
	## needs a real XR runtime), so tests can check the arbitration metas.
	# Real-headset feedback: grabbing the section-plane gizmo also dragged
	# the whole model, because this check only ever knew about controller.gd's
	# own held_node (a PART) — section_tool.gd's gizmo deliberately never
	# sets that (see its own class docstring for why it isn't a
	# grabbable_parts member), so this considered the hand "free" and dragged
	# the whole model on the same grip press. section_tool.gd sets/clears
	# this meta on the hand itself (same convention ui_hover/ui_hit_distance
	# already use for controller.gd), so check it here too.
	if hand.has_meta("section_gizmo_held") and hand.get_meta("section_gizmo_held"):
		return false
	# Same for a floating window grabbed by its handle (diegetic_panel.gd sets
	# "window_held") — grabbing a window also moved the world otherwise.
	if hand.has_meta("window_held") and hand.get_meta("window_held"):
		return false
	# Same for the part on the design table (table_manip.gd sets "table_part_held"): moving, turning or scaling it is
	# independent of the world, so the grip must not also drag the model.
	if hand.has_meta("table_part_held") and hand.get_meta("table_part_held"):
		return false
	# The tool wheel (tool_wheel.gd sets "wheel_open" from the trigger + grip chord until both are up): the grip belongs to it.
	if hand.has_meta("wheel_open") and hand.get_meta("wheel_open"):
		return false
	# controller.gd exposes held_node; a hand carrying a part isn't free.
	return hand.get("held_node") == null


func _current_multiple() -> float:
	return _root.global_transform.basis.get_scale().x / _real_life_scale


func _clamped_multiple(multiple: float) -> float:
	return clampf(multiple, min_multiple, max_multiple)


func _scale_about(pivot: Vector3, factor: float) -> void:
	var t := _root.global_transform
	_root.global_transform = Transform3D(t.basis * factor, pivot + (t.origin - pivot) * factor)


func _model_bounds() -> AABB:
	## World-space bounds of all the part meshes; zero-size if there are none.
	## (A held part has left the model, so it doesn't count.)
	var box := AABB()
	var first := true
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is MeshInstance3D) or (node.has_meta("held") and node.get_meta("held")):
			continue
		var b: AABB = node.global_transform * node.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _trim(x: float) -> String:
	return ("%.2f" % x).rstrip("0").rstrip(".")


func _shortest_arc(from: Vector3, to: Vector3) -> Quaternion:
	var d := from.dot(to)
	if d < -0.9999:
		# Hands flipped exactly through each other: any perpendicular axis will do.
		var axis := from.cross(Vector3.UP)
		if axis.length() < 0.001:
			axis = from.cross(Vector3.RIGHT)
		return Quaternion(axis.normalized(), PI)
	return Quaternion(from, to)
