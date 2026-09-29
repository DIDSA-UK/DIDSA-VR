extends XROrigin3D
## Thumbstick locomotion, per the vision brief's spec: left stick walks and
## strafes relative to where you're actually looking; right stick's X axis
## snap-turns, its Y axis aims and blinks a teleport. Either stick backs off
## while that hand is busy rotating a selected part (controller.gd's
## is_manipulating()), so manipulating a part never also spins or teleports you.

@export var enabled := true ## mode switch on the wrist tablet ("User movement")
@export var move_speed: float = 1.5 ## metres/second — the CURRENT walk speed; the wrist tablet's Travel speed slider sets it between min_move_speed and max_move_speed
@export var min_move_speed: float = 1.5 ## metres/second: the slider's bottom end AND the default (the original fixed walk speed)
@export var max_move_speed: float = 30.0 ## metres/second at the top of the slider: crossing a house's grounds or a small village in a sensible time (~110 km/h — deliberately fast; the slider is exponential so the low end stays fine-grained)
@export var snap_turn_degrees: float = 30.0
@export var snap_turn_deadzone: float = 0.6 ## how far right stick must return before another snap can fire
@export var stick_deadzone: float = 0.15
@export var axis_lockout: float = 0.4 ## how much of the OTHER right-stick axis cancels snap-turn/teleport, so a diagonal push doesn't fire both
@export var teleport_deadzone: float = 0.3
@export var teleport_max_distance: float = 5.0 ## metres from the right hand to where its laser meets the floor
@export var teleport_ring_radius: float = 0.25 ## metres, outer edge of the landing ring
@export var teleport_ring_thickness: float = 0.03 ## metres, outer minus inner radius
@export var teleport_marker_clearance: float = 0.005 ## metres between the ring's underside and the floor, so they don't z-fight

@onready var camera: XRCamera3D = $XRCamera3D
@onready var left_controller: XRController3D = $LeftController
@onready var right_controller: XRController3D = $RightController

var _snap_ready := true
var _teleporting := false
var _teleport_target: Vector3 = Vector3.ZERO
var _teleport_marker: MeshInstance3D


func _ready() -> void:
	_build_teleport_marker()


func speed_fraction() -> float:
	## Where move_speed sits on the slider, 0 (min_move_speed) .. 1 (max_move_speed).
	## Exponential, so equal slider steps are equal speed RATIOS: the bottom of
	## the range (walking) isn't crushed into a sliver by the top (driving).
	if max_move_speed <= min_move_speed:
		return 0.0
	return clampf(log(move_speed / min_move_speed) / log(max_move_speed / min_move_speed), 0.0, 1.0)


func set_speed_fraction(fraction: float) -> void:
	move_speed = min_move_speed * pow(max_move_speed / min_move_speed, clampf(fraction, 0.0, 1.0))


func _physics_process(delta: float) -> void:
	if not enabled:
		_hide_teleport_preview()
		return
	_handle_move(delta)
	_handle_snap_turn()
	_handle_teleport()


func _handle_move(delta: float) -> void:
	if left_controller.has_method("is_manipulating") and left_controller.is_manipulating():
		return

	var input: Vector2 = left_controller.get_vector2("primary")
	if input.length() < stick_deadzone:
		return

	# Relative to where the headset is facing, flattened onto the floor
	# plane so looking up/down doesn't tip the walk direction with it.
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var right := camera.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()

	var direction := (forward * input.y) + (right * input.x)
	global_position += direction * move_speed * delta


func _right_stick_owned_by_ui() -> bool:
	## The right laser is on the wrist tablet / a floating window: the right
	## stick scrolls that panel (wrist_tablet.gd), so it must not also turn or
	## teleport you. "ui_hover" is reset and re-claimed in _process() before
	## this _physics_process() runs (see controller.gd).
	return right_controller.has_meta("ui_hover") and right_controller.get_meta("ui_hover")


func _handle_snap_turn() -> void:
	if (right_controller.has_method("is_manipulating") and right_controller.is_manipulating()) or _right_stick_owned_by_ui():
		_snap_ready = true
		return

	var input: Vector2 = right_controller.get_vector2("primary")
	if absf(input.x) < snap_turn_deadzone or absf(input.y) >= axis_lockout:
		_snap_ready = true
		return
	if not _snap_ready:
		return

	_snap_turn(signf(input.x))
	_snap_ready = false


func _snap_turn(direction: float) -> void:
	## direction: +1 = turn right, -1 = turn left.
	# Negated: a positive rotation about +Y is counter-clockwise (a LEFT turn),
	# so a right push (positive x) used to turn you left — real-headset report.
	var angle := -deg_to_rad(snap_turn_degrees) * direction
	# Rotate about the camera's current position, not the origin's own, so
	# a snap-turn reorients you in place instead of also flinging you sideways.
	var pivot := camera.global_position
	global_position = pivot + (global_position - pivot).rotated(Vector3.UP, angle)
	rotate_y(angle)


func _handle_teleport() -> void:
	if (right_controller.has_method("is_manipulating") and right_controller.is_manipulating()) or _right_stick_owned_by_ui():
		_hide_teleport_preview()
		return

	var input: Vector2 = right_controller.get_vector2("primary")
	var wanting_teleport := input.y > teleport_deadzone and absf(input.x) < axis_lockout

	if wanting_teleport:
		# Target is wherever the right hand's laser meets the floor (the
		# origin's own height). Aiming level/upwards, or farther than
		# teleport_max_distance, gives no target: the ring hides and
		# releasing the stick won't jump.
		var aim_origin := right_controller.global_position
		var aim_dir := -right_controller.global_transform.basis.z.normalized()
		var floor_plane := Plane(Vector3.UP, global_position.y)
		var hit = floor_plane.intersects_ray(aim_origin, aim_dir)
		_teleporting = hit != null and aim_origin.distance_to(hit) <= teleport_max_distance
		if _teleporting:
			_teleport_target = hit
		if _teleport_marker and _teleport_marker.is_inside_tree():
			_teleport_marker.visible = _teleporting
			if _teleporting:
				_teleport_marker.global_position = _teleport_target + Vector3(0, _marker_lift(), 0)
	else:
		if _teleporting:
			# Stick eased back off the deadzone: blink so your head (not the
			# origin, which room-scale drift puts elsewhere) lands on the ring.
			var offset := _teleport_target - camera.global_position
			global_position.x += offset.x
			global_position.z += offset.z
		_hide_teleport_preview()


func _hide_teleport_preview() -> void:
	_teleporting = false
	if _teleport_marker:
		_teleport_marker.visible = false


func _marker_lift() -> float:
	# A torus is centred on its tube, so raise it by the tube's radius to sit on the floor.
	return teleport_ring_thickness / 2.0 + teleport_marker_clearance


func _build_teleport_marker() -> void:
	_teleport_marker = MeshInstance3D.new()
	var mesh := TorusMesh.new() # lies flat in the XZ plane, so it reads as a ring on the floor
	mesh.inner_radius = teleport_ring_radius - teleport_ring_thickness
	mesh.outer_radius = teleport_ring_radius
	_teleport_marker.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.9, 1.0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	_teleport_marker.visible = false
	# Deferred: this runs from _ready(), while Main is still setting up its
	# children, so a direct add_child() on it fails and the marker never enters the tree.
	get_parent().add_child.call_deferred(_teleport_marker)
