extends XROrigin3D
## Thumbstick locomotion, per the vision brief's spec: left stick walks and
## strafes relative to where you're actually looking; right stick's X axis
## snap-turns, its Y axis aims and blinks a teleport. Either stick backs off
## while that hand is busy rotating a selected part (controller.gd's
## is_manipulating()), so manipulating a part never also spins or teleports you.

@export var move_speed: float = 1.5 ## metres/second
@export var snap_turn_degrees: float = 30.0
@export var snap_turn_deadzone: float = 0.6 ## how far right stick must return before another snap can fire
@export var stick_deadzone: float = 0.15
@export var axis_lockout: float = 0.4 ## how much of the OTHER right-stick axis cancels snap-turn/teleport, so a diagonal push doesn't fire both
@export var teleport_deadzone: float = 0.3
@export var teleport_max_distance: float = 5.0 ## metres, at full forward stick deflection
@export var teleport_marker_clearance: float = 0.02 ## metres above the floor; the marker and the
## Ground plane's visual mesh both sit at y=0, so with no offset they z-fight and the floor wins.

@onready var camera: XRCamera3D = $XRCamera3D
@onready var left_controller: XRController3D = $LeftController
@onready var right_controller: XRController3D = $RightController

var _snap_ready := true
var _teleporting := false
var _teleport_target: Vector3 = Vector3.ZERO
var _teleport_marker: MeshInstance3D


func _ready() -> void:
	_build_teleport_marker()


func _physics_process(delta: float) -> void:
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


func _handle_snap_turn() -> void:
	if right_controller.has_method("is_manipulating") and right_controller.is_manipulating():
		_snap_ready = true
		return

	var input: Vector2 = right_controller.get_vector2("primary")
	if absf(input.x) < snap_turn_deadzone or absf(input.y) >= axis_lockout:
		_snap_ready = true
		return
	if not _snap_ready:
		return

	var angle := deg_to_rad(snap_turn_degrees) * signf(input.x)
	# Rotate about the camera's current position, not the origin's own, so
	# a snap-turn reorients you in place instead of also flinging you sideways.
	var pivot := camera.global_position
	global_position = pivot + (global_position - pivot).rotated(Vector3.UP, angle)
	rotate_y(angle)
	_snap_ready = false


func _handle_teleport() -> void:
	if right_controller.has_method("is_manipulating") and right_controller.is_manipulating():
		_hide_teleport_preview()
		return

	var input: Vector2 = right_controller.get_vector2("primary")
	var wanting_teleport := input.y > teleport_deadzone and absf(input.x) < axis_lockout

	if wanting_teleport:
		var forward := -camera.global_transform.basis.z
		forward.y = 0.0
		forward = forward.normalized()
		var distance := clampf(input.y, 0.0, 1.0) * teleport_max_distance
		_teleport_target = camera.global_position + forward * distance
		_teleport_target.y = global_position.y # keep current floor height
		if _teleport_marker:
			_teleport_marker.global_position = _teleport_target + Vector3(0, teleport_marker_clearance, 0)
			_teleport_marker.visible = true
		_teleporting = true
	else:
		if _teleporting:
			# Stick eased back off the deadzone: blink to the last previewed spot.
			global_position.x = _teleport_target.x
			global_position.z = _teleport_target.z
		_hide_teleport_preview()


func _hide_teleport_preview() -> void:
	_teleporting = false
	if _teleport_marker:
		_teleport_marker.visible = false


func _build_teleport_marker() -> void:
	_teleport_marker = MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.25
	mesh.bottom_radius = 0.25
	mesh.height = 0.02
	_teleport_marker.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.9, 1.0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	_teleport_marker.visible = false
	get_parent().add_child(_teleport_marker)
