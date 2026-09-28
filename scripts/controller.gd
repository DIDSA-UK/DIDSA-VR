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
##    Picking is a real physics ray test against each part's actual mesh
##    (nearest hit wins), not the old angle-to-origin cone, which mis-picked
##    big or overlapping parts whenever the ray missed a part's geometry but
##    still passed near its origin. A hover highlight plus the part's name
##    show what a pull of the trigger would select. While selected: the
##    thumbstick rotates it in place, pivoting on the point the ray hit (or
##    the part's centre, e.g. for a selection with no hit point) rather than
##    the part's own origin — relative to how you're currently looking
##    (left/right spins it, up/down tips it away/towards you) rather than the
##    part's own, possibly already-tilted, axes. A/X pulls it nearer, B/Y
##    pushes it farther. This is the vision brief's "Individual part
##    manipulation" mode.
##
## Attach this to both the left and right XRController3D nodes. Parts need a
## collision shape to be ray-testable — main.gd calls create_trimesh_collision()
## on every loaded MeshInstance3D for this reason.
##
## A held part's POSITION goes through the same adaptive One Euro filter as
## whole-model moves (steadiness — see two_hand_model.gd), so a held hand
## doesn't shake the part; its ROTATION follows your hand directly, same as
## before (matching one-hand model-drag's own translation-only precedent —
## there's no quaternion version of the filter yet). The wrist tablet's
## Steadiness choice sets it on both hands as well as the model.

const TwoHandModel := preload("res://scripts/two_hand_model.gd") ## just for its STEADINESS_* tables, so the level numbers and cutoffs stay in one place
const OneEuro := preload("res://scripts/one_euro.gd")

@export var grab_action: String = "grip_click"
@export var grab_reach: float = 0.05 ## metres: your hand grabs a part if it's inside the part's bounding box or within this
## distance of it. (It used to be a sphere around each part's origin point, which missed the
## rest of the part and grabbed things you weren't touching.)
@export var select_action: String = "trigger_click"
@export var select_max_distance: float = 8.0 ## metres; laser-select range
@export var rotate_speed_degrees: float = 90.0 ## per second, at full thumbstick deflection
@export var nudge_rate: float = 0.6 ## A/X and B/Y move a part this fraction of its distance from your hand every second:
## 0.6 m/s at 1 m, 3 m/s at 5 m, 0.18 m/s at 30 cm. Far parts travel fast, near ones can be placed finely.
@export var nudge_min_speed: float = 0.03 ## metres/second floor, so a part right by your hand can still be pushed out
@export var nudge_max_speed: float = 8.0 ## metres/second ceiling
@export var stick_deadzone: float = 0.15
@export var laser_length: float = 3.0 ## metres; the laser's length when nothing's in the way — see _update_laser_visual() for how it shortens to whatever it's actually hitting (a UI panel or a part)

var held_node: Node3D = null
var selected_node: Node3D = null
var parts_enabled := true ## mode switch on the wrist tablet ("Individual part manipulation") — gates both grip-grab and laser-select
var laser_select_enabled := true ## set false on the LEFT hand only (main.gd) per real-headset feedback: selecting with the left trigger blocked left-hand locomotion (is_manipulating()), so left grip-grab stays on but left laser-select (and the A/B/X/Y nudge + thumbstick rotate that ride on selected_node) is off, freeing the left laser for something else later. Independent of parts_enabled, which still gates grip on both hands.
var command_stack = null ## set by main.gd; a shared command_stack.gd instance for undo/redo
var hide_tool_active := false ## Tools tab's "Shoot to hide": trigger hides whatever the laser hits instead of selecting it
var mates_tool_active := false ## wrist tablet's Mates tab: trigger picks a mate entity instead of selecting/hiding
var mates_tool = null ## set by main.gd; a shared mates_tool.gd instance
var measure_tool_active := false ## wrist tablet's Measure tab: trigger picks a measure entity instead of selecting/hiding
var measure_tool = null ## set by main.gd; a shared measure_tool.gd instance
var section_tool = null ## set by main.gd; a shared section_tool.gd instance — GRIP grabs its plane gizmo instead of a part when in reach (see that script's own docstring for why this isn't just another grabbable_parts member)

var _laser: MeshInstance3D
var _laser_mesh: CylinderMesh
var _part_hit_distance := -1.0 ## metres to whatever _update_aim_hover()'s own raycast last hit, or -1 for nothing — set alongside _aim_hover_node
var _select_material: StandardMaterial3D
var _hover_material: StandardMaterial3D
var _hover_node: Node3D = null ## the part a grip would grab right now, lightly highlighted
var _aim_hover_material: StandardMaterial3D
var _aim_hover_node: Node3D = null ## the part the laser would select right now, lightly highlighted
var _aim_label: Label3D ## floats near the hit point, showing the hovered part's name
var _pivot_local: Vector3 = Vector3.ZERO ## selected_node's local-space point the thumbstick rotates about
var _held_start_transform: Transform3D ## held_node's world transform when this grip grabbed it
var _selected_start_transform: Transform3D ## selected_node's world transform when the laser selected it
var steadiness := 2 ## index into TwoHandModel.STEADINESS_NAMES; set by the wrist tablet
var _grab_offset: Transform3D ## held_node's pose in this hand's local frame, captured at grab time
var _grab_filter := OneEuro.new() ## smooths this hand's own position while it's holding a part

# Rotation is expressed relative to how the headset is currently looking
# (world-up for spin, the camera's flattened right vector for tip), not the
# selected part's own local axes — using the part's local axes made every
# further nudge of the stick rotate around whatever tilted axis the part had
# drifted to, which read as "wrong".
var _camera: XRCamera3D


func _ready() -> void:
	# Guarantees this node's own _process() (the ui_hover/ui_hit_distance
	# reset below) runs before every UI panel's — including wrist_tablet.gd,
	# which is three levels deep (parented under the LEFT controller, not a
	# sibling of this one) rather than a direct child of main.gd's root as
	# first assumed. Confirmed by actually running this against a real
	# Godot instead of only inspecting the code (see docs/status.md): tree
	# depth/add-order alone did NOT reliably put this first, and without
	# this fix the reset sometimes ran AFTER wrist_tablet.gd's own
	# _process() within the same frame, wiping out a hover it had just
	# legitimately claimed — tests/laser_and_left_hand.gd's own
	# "shortens to the tablet via ui_hit_distance" check caught this.
	# process_priority is Godot's own explicit, documented ordering
	# mechanism for exactly this (lower runs first) — a real fix, not a
	# workaround.
	process_priority = -1000
	button_pressed.connect(_on_button_pressed)
	button_released.connect(_on_button_released)
	set_steadiness(steadiness)
	_add_visible_marker()
	_add_laser()
	_select_material = StandardMaterial3D.new()
	_select_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_select_material.albedo_color = Color(1.0, 0.85, 0.1, 0.35)
	_select_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_material = StandardMaterial3D.new()
	_hover_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hover_material.albedo_color = Color(0.3, 0.9, 1.0, 0.25)
	_hover_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_aim_hover_material = StandardMaterial3D.new()
	_aim_hover_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_aim_hover_material.albedo_color = Color(1.0, 1.0, 0.6, 0.3)
	_aim_hover_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_add_aim_label()

	var parent := get_parent()
	if parent:
		_camera = parent.get_node_or_null("XRCamera3D") as XRCamera3D


func set_steadiness(level: int) -> void:
	steadiness = clampi(level, 0, TwoHandModel.STEADINESS_NAMES.size() - 1)
	_grab_filter.min_cutoff = maxf(TwoHandModel.STEADINESS_CUTOFF_HZ[steadiness], 0.01)
	_grab_filter.beta = TwoHandModel.STEADINESS_BETA


func _process(_delta: float) -> void:
	## Resets the shared "ui_hover"/"ui_hit_distance" meta (written by
	## wrist_tablet.gd, popup_keyboard.gd, and any scripts/diegetic_panel.gd
	## -based floating window — see that script's own top docstring) to
	## neutral at the very start of every frame, before any of those panels'
	## own _process() runs — guaranteed by this node's process_priority
	## (set in _ready()), not by tree position: wrist_tablet.gd is three
	## levels deep (parented under the LEFT controller, not a sibling of
	## this one), so plain child/add order does NOT reliably put this
	## first — confirmed the hard way by actually running the tests against
	## a real Godot instead of only inspecting the code. Without this
	## reset, a floating window nobody's aiming at any more could keep
	## "owning" these two values indefinitely, since diegetic_panel.gd's own
	## arbitration only ever CLAIMS the meta, never unclaims it on its own —
	## see that script's own top docstring for the full picture this is one
	## half of (a first-claim-per-frame scheme, not nearest-hit, chosen so
	## at most one panel can ever believe it's hovered in a given frame).
	set_meta("ui_hover", false)
	set_meta("ui_hit_distance", -1.0)


func _physics_process(delta: float) -> void:
	_update_grab_hover()
	_update_aim_hover()
	_update_laser_visual()
	if section_tool:
		section_tool.update_held(self, delta, steadiness > 0)
	if held_node != null:
		_update_held_part(delta)
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
		# flattened right axis. Both pivot on where the ray hit when it was
		# selected (or the part's centre), not the part's own origin, so a
		# part grabbed by an edge swings from that edge rather than spinning
		# in place about a point that might be nowhere near your aim.
		_rotate_about_pivot(selected_node, Vector3.UP, deg_to_rad(rotate_speed_degrees) * stick.x * delta)
		_rotate_about_pivot(selected_node, pitch_axis, deg_to_rad(rotate_speed_degrees) * -stick.y * delta)

	var forward := -global_transform.basis.z.normalized()
	var speed := nudge_speed_for(selected_node)
	if is_button_pressed("ax_button"):
		selected_node.global_position -= forward * speed * delta
	if is_button_pressed("by_button"):
		selected_node.global_position += forward * speed * delta


func nudge_speed_for(part: Node3D) -> float:
	## A/B speed for this part: proportional to how far it is from your hand
	## (measured to the middle of its bounds, since a part's origin can sit far
	## from its geometry), clamped to a sensible range.
	var centre := part.global_position
	if part is MeshInstance3D:
		centre = part.global_transform * (part as MeshInstance3D).get_aabb().get_center()
	return clampf(nudge_rate * global_position.distance_to(centre), nudge_min_speed, nudge_max_speed)


func is_manipulating() -> bool:
	## Lets locomotion.gd know this hand's thumbstick is busy rotating a
	## selected part right now, so it doesn't also drive movement/turning.
	return selected_node != null


func set_parts_enabled(on: bool) -> void:
	parts_enabled = on
	if not on:
		reset_interaction()


func reset_interaction() -> void:
	## Let go of anything held and drop any selection: used when the mode is
	## switched off and before the model is replaced, so nothing is left
	## pointing at a part that's about to disappear.
	_try_release()
	_clear_selection()
	_set_grab_hover(null)
	_set_aim_hover(null, Vector3.ZERO)


func _on_button_pressed(action_name: String) -> void:
	if action_name == grab_action:
		# The section-plane gizmo is independent of "Individual part
		# manipulation" mode (like mates_tool_active/hide_tool_active are for
		# the trigger below) — parts_enabled only gates the ordinary part-grab
		# search inside _try_grab() itself.
		if parts_enabled or (section_tool and section_tool.active):
			_try_grab()
	elif action_name == select_action:
		if has_meta("ui_hover") and get_meta("ui_hover"):
			return # laser is over the wrist tablet or popup keyboard: the click is for them, not a part.
		if mates_tool_active:
			_try_pick_mate_entity()
		elif measure_tool_active:
			_try_pick_measure_entity()
		elif hide_tool_active:
			# Its own tool, independent of "Individual part manipulation" mode.
			_try_shoot_hide()
		elif parts_enabled and laser_select_enabled:
			_try_select()


func _on_button_released(action_name: String) -> void:
	if action_name == grab_action:
		_try_release()


func _try_grab() -> void:
	if held_node != null:
		return
	if section_tool and section_tool.try_grab(self, grab_reach):
		return # gizmo grabbed instead — see section_tool.gd's own docstring for why this is checked first

	# Deliberately ignores selected_node so grip never feels tied to the laser-select state.
	var target := _find_grab_target()
	if target:
		_set_grab_hover(null)
		target.set_meta("held", true)
		_held_start_transform = target.global_transform
		# Its pose relative to this hand right now, kept exactly where you took
		# hold of it: turning your hand turns the part about that spot. Stays
		# under assembly_root rather than reparenting to the hand, since
		# _update_held_part() drives its transform explicitly every frame (so
		# steadiness — see below — can filter the hand's position first).
		_grab_offset = global_transform.affine_inverse() * target.global_transform
		_grab_filter.reset(global_position)
		held_node = target


func _find_grab_target() -> Node3D:
	## The part your hand is touching: one whose bounding box contains the hand or
	## is within grab_reach of it. If several qualify, prefer the ones the hand is
	## actually inside/nearest to, and among equals the smallest, so a small part
	## against a big one can still be picked.
	var best: Node3D = null
	var best_reach := INF
	var best_volume := INF
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is MeshInstance3D):
			continue
		if node.has_meta("held") and node.get_meta("held"):
			continue
		if not node.visible: # a shot-hidden part isn't there to touch either
			continue
		var reach := _reach_distance(node)
		if reach > grab_reach:
			continue
		var volume: float = node.get_aabb().get_volume() * absf(node.global_transform.basis.determinant())
		if reach < best_reach - 0.001 or (absf(reach - best_reach) <= 0.001 and volume < best_volume):
			best = node
			best_reach = reach
			best_volume = volume
	return best


func _reach_distance(part: MeshInstance3D) -> float:
	## World distance from this hand to the part's bounding box (0 if inside it).
	var box := part.get_aabb()
	var local: Vector3 = part.global_transform.affine_inverse() * global_position
	var closest := local.clamp(box.position, box.end)
	return global_position.distance_to(part.global_transform * closest)


func _update_grab_hover() -> void:
	## Light highlight on the part a grip would take right now.
	var target: Node3D = null
	if parts_enabled and held_node == null:
		target = _find_grab_target()
	_set_grab_hover(target)


func _set_grab_hover(target: Node3D) -> void:
	if target == _hover_node:
		return
	if is_instance_valid(_hover_node) and _hover_node.material_overlay == _hover_material:
		_hover_node.material_overlay = null
	_hover_node = target
	if is_instance_valid(_hover_node) and _hover_node != selected_node:
		_hover_node.material_overlay = _hover_material


func _try_release() -> void:
	if section_tool and section_tool.release(self):
		return
	if held_node == null:
		return

	var part := held_node
	part.set_meta("held", false)
	held_node = null
	_push_move_command(part, _held_start_transform)


func _update_held_part(delta: float) -> void:
	## Filters this hand's position (not its rotation — see the class-level
	## comment) before applying the grab offset, so a held hand's few-mm
	## tremor doesn't reach the part while a deliberate move still does.
	var filtered_pos := global_position if steadiness == 0 else _grab_filter.filter(global_position, delta)
	held_node.global_transform = Transform3D(global_transform.basis, filtered_pos) * _grab_offset


func _push_move_command(part: Node3D, before: Transform3D) -> void:
	if command_stack == null or not is_instance_valid(part):
		return
	var after := part.global_transform
	if before.is_equal_approx(after):
		return # no net move: nothing worth undoing
	command_stack.push("move %s" % part.name,
		func() -> void: part.global_transform = before,
		func() -> void: part.global_transform = after)


func _try_shoot_hide() -> void:
	## Tools tab's "Shoot to hide": the same real ray test as laser-select,
	## but the trigger hides the hit part instead of selecting it.
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null:
		return
	if part == selected_node:
		_clear_selection() # can't stay "selected" once it's hidden
	if command_stack:
		command_stack.push("hide %s" % part.name,
			func() -> void: part.visible = true,
			func() -> void: part.visible = false)
	part.visible = false


func _try_pick_mate_entity() -> void:
	## Mates tab active: the same ray test as laser-select, handed to
	## mates_tool.gd instead of selecting/hiding — see that script's own
	## try_pick() for validation (same-part, cross-assembly, no face
	## identity, etc.).
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null or mates_tool == null:
		return
	mates_tool.try_pick(part, hit.get("face_index", -1))


func _try_pick_measure_entity() -> void:
	## Measure tab active: same ray test, handed to measure_tool.gd instead —
	## see that script's own try_pick()/_validate_pick() for its (looser
	## than Mates') validation.
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null or measure_tool == null:
		return
	measure_tool.try_pick(part, hit.get("face_index", -1))


func _try_select() -> void:
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var target: Node3D = hit.get("part")

	if selected_node != null:
		var previous := selected_node
		_clear_selection()
		if target == previous:
			return # pressed trigger again on the same part: deselect and stop.

	if target != null:
		var pivot_point: Vector3 = hit.get("point", target.global_position)
		_set_selection(target, pivot_point)


func select_external(node: Node3D, point: Vector3) -> void:
	## Lets something other than this hand's own laser drive selection
	## through the exact same path laser-select uses (_set_selection()/
	## _clear_selection() and their command_stack bookkeeping) instead of
	## reaching into private state — the assembly tree window's tap-to-
	## select (assembly_tree_window.gd, called via main.gd's
	## select_part_by_occurrence_id()) is the first caller. Re-selecting the
	## already-selected node deselects it, matching _try_select()'s own
	## toggle behaviour.
	if selected_node == node:
		_clear_selection()
		return
	if selected_node != null:
		_clear_selection()
	_set_selection(node, point)


func _raycast_part(origin: Vector3, direction: Vector3, max_distance: float) -> Dictionary:
	## A real ray test against the parts' actual collision geometry (see
	## main.gd's create_trimesh_collision() call) — nearest hit wins,
	## replacing the old cone around each part's origin point, which
	## mis-picked whenever a part's origin sat within the cone but the ray
	## never actually touched its geometry (or missed a nearer overlapping
	## part entirely). Held or hidden parts are click-through: a shot-hidden
	## part in front of something else shouldn't keep blocking the ray.
	## Returns {} if nothing was hit, else {"part": Node3D, "point": Vector3}
	## (world-space hit point).
	if not is_inside_tree():
		return {}
	var space_state := get_world_3d().direct_space_state
	var excluded: Array[RID] = []
	for _attempt in 8: # generous cap so a stack of hidden/held parts can't loop forever
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * max_distance)
		query.exclude = excluded
		var result := space_state.intersect_ray(query)
		if result.is_empty():
			return {}
		var collider: Object = result.get("collider")
		var part: Node3D = collider.get_parent() if collider is StaticBody3D else null
		if part == null or not part.is_in_group("grabbable_parts"):
			return {}
		if (part.has_meta("held") and part.get_meta("held")) or not part.visible:
			excluded.append((collider as StaticBody3D).get_rid())
			continue
		return {"part": part, "point": result.get("position"), "face_index": result.get("face_index", -1)}
	return {}


func _update_aim_hover() -> void:
	## Light highlight plus the part's name on whatever the laser would
	## select right now, so you know what a trigger pull will pick before
	## you commit to it.
	var hit := {}
	if ((parts_enabled and laser_select_enabled) or hide_tool_active or mates_tool_active or measure_tool_active) and held_node == null:
		hit = _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	_set_aim_hover(hit.get("part"), hit.get("point", Vector3.ZERO))
	_part_hit_distance = global_position.distance_to(hit["point"]) if hit.has("point") else -1.0


func _set_aim_hover(target: Node3D, point: Vector3) -> void:
	if target == _aim_hover_node and is_instance_valid(target):
		_aim_label.global_position = point + Vector3(0, 0.05, 0)
		return
	if is_instance_valid(_aim_hover_node) and _aim_hover_node != selected_node and _aim_hover_node.material_overlay == _aim_hover_material:
		_aim_hover_node.material_overlay = null
	_aim_hover_node = target
	if is_instance_valid(_aim_hover_node):
		if _aim_hover_node != selected_node:
			_aim_hover_node.material_overlay = _aim_hover_material
		_aim_label.text = _aim_hover_node.name
		_aim_label.global_position = point + Vector3(0, 0.05, 0)
		_aim_label.visible = true
	else:
		_aim_label.visible = false


func _rotate_about_pivot(node: Node3D, axis: Vector3, angle: float) -> void:
	var pivot := node.global_transform * _pivot_local
	var rot := Basis(axis, angle)
	var t := node.global_transform
	t.origin = pivot + rot * (t.origin - pivot)
	t.basis = rot * t.basis
	node.global_transform = t


func _set_selection(node: Node3D, pivot_point: Vector3) -> void:
	selected_node = node
	node.set_meta("selected", true)
	node.material_overlay = _select_material
	_pivot_local = node.global_transform.affine_inverse() * pivot_point
	_selected_start_transform = node.global_transform


func _clear_selection() -> void:
	if selected_node:
		var part := selected_node
		part.set_meta("selected", false)
		part.material_overlay = null
		selected_node = null
		_push_move_command(part, _selected_start_transform)


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
	_laser_mesh = CylinderMesh.new()
	_laser_mesh.top_radius = 0.003
	_laser_mesh.bottom_radius = 0.003
	_laser_mesh.height = laser_length
	_laser.mesh = _laser_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.9, 1.0, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_laser_mesh.material = mat
	add_child(_laser)
	# Cylinder's long axis is local Y by default; rotate -90 about X so it
	# points down local -Z (the controller's forward/aim direction); see
	# _set_laser_length() for how it's kept anchored at the hand as its own
	# length changes every frame.
	_laser.rotation_degrees.x = -90.0
	_set_laser_length(laser_length)


func _set_laser_length(length: float) -> void:
	_laser_mesh.height = length
	_laser.position.z = -length / 2.0 # shift out by half its length so the near end always stays at the hand regardless of how long it currently is


func _update_laser_visual() -> void:
	## Shortens the laser to wherever it's actually terminating, instead of
	## the fixed laser_length it always used to draw at regardless of what
	## was in the way — real-headset feedback: aiming at the wrist tablet,
	## the laser visibly passed straight through it rather than stopping
	## there. A UI panel (wrist_tablet.gd/popup_keyboard.gd, reported via
	## the "ui_hit_distance" meta those scripts set on us every frame — same
	## convention "ui_hover" already uses) takes priority over a plain part
	## hit, which takes priority over the default full length.
	var distance := laser_length
	var ui_distance: float = get_meta("ui_hit_distance", -1.0)
	if ui_distance >= 0.0:
		distance = ui_distance
	elif _part_hit_distance >= 0.0:
		distance = _part_hit_distance
	_set_laser_length(clampf(distance, 0.02, laser_length))


func _add_aim_label() -> void:
	_aim_label = Label3D.new()
	_aim_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_aim_label.no_depth_test = true
	_aim_label.font_size = 32
	_aim_label.outline_size = 10
	_aim_label.visible = false
	add_child(_aim_label)
