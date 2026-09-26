extends XRController3D
## Milestone 1: two ways to manipulate a part.
##
## 1. Proximity grab (grip, close range): hold grip near whichever part is
##    physically closest to your hand to pick it up and move it 1:1; release
##    to drop it back into the assembly. Purely distance-based — it ignores
##    laser-selection entirely, so grabbing next to part B always moves part
##    B even while part A is still selected.
## 2. Laser-select (trigger, long range): point at a part and pull the
##    trigger to select it (trigger again, or aim at nothing, to deselect).
##    While selected: the thumbstick rotates it in place, relative to how
##    you're currently looking (left/right spins it, up/down tips it
##    away/towards you) rather than the part's own, possibly already-tilted,
##    axes. A/X pulls it nearer, B/Y pushes it farther. This is the vision
##    brief's "Individual part manipulation" mode.
##
## Attach this to both the left and right XRController3D nodes.

@export var grab_action: String = "grip_click"
@export var grab_radius: float = 0.25 ## metres; how close a part must be for proximity grab
@export var select_action: String = "trigger_click"
@export var select_max_distance: float = 8.0 ## metres; laser-select range
@export var select_max_angle_degrees: float = 12.0 ## cone half-angle around where you're aiming
@export var rotate_speed_degrees: float = 90.0 ## per second, at full thumbstick deflection
@export var nudge_speed: float = 0.6 ## metres/second, A/X and B/Y nearer/farther
@export var stick_deadzone: float = 0.15
@export var laser_length: float = 3.0 ## metres; fixed visual length, doesn't retarget to hit point

var held_node: Node3D = null
var selected_node: Node3D = null

var _laser: MeshInstance3D
var _select_material: StandardMaterial3D

# Rotation is expressed relative to how the headset is currently looking
# (world-up for spin, the camera's flattened right vector for tip), not the
# selected part's own local axes — using the part's local axes made every
# further nudge of the stick rotate around whatever tilted axis the part had
# drifted to, which read as "wrong".
var _camera: XRCamera3D


func _ready() -> void:
	button_pressed.connect(_on_button_pressed)
	button_released.connect(_on_button_released)
	_add_visible_marker()
	_add_laser()
	_select_material = StandardMaterial3D.new()
	_select_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_select_material.albedo_color = Color(1.0, 0.85, 0.1, 0.35)
	_select_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var parent := get_parent()
	if parent:
		_camera = parent.get_node_or_null("XRCamera3D") as XRCamera3D


func _physics_process(delta: float) -> void:
	if selected_node == null:
		return

	var stick: Vector2 = get_vector2("primary")
	if stick.length() >= stick_deadzone:
		var pitch_axis := Vector3.RIGHT
		if _camera:
			var camera_right := _camera.global_transform.basis.x
			camera_right.y = 0.0
			if camera_right.length() > 0.0001:
				pitch_axis = camera_right.normalized()
		# Left/right spins around world-up, as seen from in front of the part;
		# up/down tips it away from or towards you around the camera's own
		# flattened right axis. Both are global-space rotations pivoting on
		# the part's own origin, so they never drift onto the part's local axes.
		selected_node.global_rotate(Vector3.UP, deg_to_rad(rotate_speed_degrees) * stick.x * delta)
		selected_node.global_rotate(pitch_axis, deg_to_rad(rotate_speed_degrees) * -stick.y * delta)

	var forward := -global_transform.basis.z.normalized()
	if is_button_pressed("ax_button"):
		selected_node.global_position -= forward * nudge_speed * delta
	if is_button_pressed("by_button"):
		selected_node.global_position += forward * nudge_speed * delta


func is_manipulating() -> bool:
	## Lets locomotion.gd know this hand's thumbstick is busy rotating a
	## selected part right now, so it doesn't also drive movement/turning.
	return selected_node != null


func _on_button_pressed(action_name: String) -> void:
	if action_name == grab_action:
		_try_grab()
	elif action_name == select_action:
		_try_select()


func _on_button_released(action_name: String) -> void:
	if action_name == grab_action:
		_try_release()


func _try_grab() -> void:
	if held_node != null:
		return

	# Always whichever part is physically closest — deliberately ignores
	# selected_node so grip never feels tied to the laser-select state.
	var closest: Node3D = null
	var closest_dist := grab_radius
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is Node3D):
			continue
		if node.has_meta("held") and node.get_meta("held"):
			continue
		var dist := global_transform.origin.distance_to(node.global_transform.origin)
		if dist < closest_dist:
			closest = node
			closest_dist = dist

	if closest:
		closest.set_meta("held", true)
		closest.reparent(self, true)
		held_node = closest


func _try_release() -> void:
	if held_node == null:
		return

	held_node.set_meta("held", false)
	var assembly_root := get_tree().get_first_node_in_group("assembly_root")
	if assembly_root:
		held_node.reparent(assembly_root, true)
	held_node = null


func _try_select() -> void:
	var target := _find_aim_target()

	if selected_node != null:
		var previous := selected_node
		_clear_selection()
		if target == previous:
			return # pressed trigger again on the same part: deselect and stop.

	if target != null:
		_set_selection(target)


func _find_aim_target() -> Node3D:
	var forward := -global_transform.basis.z.normalized()
	var origin := global_transform.origin
	var best: Node3D = null
	var best_angle := deg_to_rad(select_max_angle_degrees)

	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is Node3D):
			continue
		if node.has_meta("held") and node.get_meta("held"):
			continue
		if node.has_meta("selected") and node.get_meta("selected") and node != selected_node:
			continue
		var to_target: Vector3 = node.global_transform.origin - origin
		var dist := to_target.length()
		if dist > select_max_distance or dist < 0.001:
			continue
		var angle := forward.angle_to(to_target.normalized())
		if angle < best_angle:
			best_angle = angle
			best = node

	return best


func _set_selection(node: Node3D) -> void:
	selected_node = node
	node.set_meta("selected", true)
	node.material_overlay = _select_material


func _clear_selection() -> void:
	if selected_node:
		selected_node.set_meta("selected", false)
		selected_node.material_overlay = null
	selected_node = null


func _add_visible_marker() -> void:
	# Bare XRController3D nodes draw nothing at all — without this you
	# can't see your own hands in headset.
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.02
	sphere.height = 0.04
	marker.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 0.9)
	mat.albedo_color = Color(0.2, 0.9, 0.9)
	sphere.material = mat
	add_child(marker)


func _add_laser() -> void:
	_laser = MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.003
	mesh.bottom_radius = 0.003
	mesh.height = laser_length
	_laser.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.9, 1.0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	add_child(_laser)
	# Cylinder's long axis is local Y by default; rotate -90 about X so it
	# points down local -Z (the controller's forward/aim direction), then
	# shift it out by half its length so the near end sits at the hand.
	_laser.rotation_degrees.x = -90.0
	_laser.position.z = -laser_length / 2.0
