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
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const LaserPick := preload("res://scripts/laser_pick.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const GroupIndex := preload("res://scripts/group_index.gd") ## which sub-assembly a part sits in (a grip or the laser can take the whole of one)
const GroupSet := preload("res://scripts/group_set.gd")
const GroupCues := preload("res://scripts/group_cues.gd")
const GroupBreadcrumb := preload("res://scripts/group_breadcrumb.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd") ## which spots of which parts a room's clip has cut away: neither the laser nor a grip may take them

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
@export var nudge_min_distance: float = 0.15 ## metres: A/X stops pulling a part this close to your hand, so it can't pass through it
@export var nudge_steer_rate: float = 3.0 ## per second: how quickly A/X and B/Y swing the part's direction from your hand round to where you're aiming (both use it — 6 was too snappy for A, and B originally had none)
@export var stick_deadzone: float = 0.15
@export var laser_length: float = 3.0 ## metres; the laser's length when nothing's in the way — see _update_laser_visual() for how it shortens to whatever it's actually hitting (a UI panel or a part)

signal group_message(text: String) ## something to tell the user about choosing / moving a sub-assembly (main.gd shows it)
signal tool_message(text: String) ## what a shot tool did or why it did nothing (main.gd shows it on the status line and the wrist prompt)
signal wheel_chord_started() ## trigger + grip pressed together on a hand with wheel_enabled: tool_wheel.gd opens the wheel

@export var group_deadzone := 0.02 ## metres of hand travel after a grip on a part inside a sub-assembly before it follows the hand (0 = off): time to choose what to take
const CRUMB_HOLD_MS := 450 ## the laser trigger held this long on a part in a sub-assembly opens the assembly-level breadcrumb

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
var drive_tool_active := false ## the Drive tool (tablet / wheel): trigger picks the axis to turn a part about; on the tool hand (wheel_enabled) the stick is the throttle, A keeps it going, B stops
var drive_tool = null ## set by main.gd; the shared drive_tool.gd instance
var paint_active := false ## the Appearance tool (tool wheel / tablet): a trigger click paints the body under the laser, a hold opens the paint breadcrumb
var appearance_tool = null ## set by main.gd; the shared appearance_tool.gd instance (what to paint with, where it goes)
var wheel_enabled := false ## set on the RIGHT hand only (main.gd): trigger + grip pressed within wheel_window_ms of each other open the tool wheel instead of grabbing / selecting
var wheel_window_ms := 250 ## how close together the two presses must be to count as the wheel chord
var section_tool = null ## set by main.gd; a shared section_tool.gd instance — GRIP grabs its plane gizmo instead of a part when in reach (see that script's own docstring for why this isn't just another grabbable_parts member)

var _latch: Dictionary = {} ## a grip waiting out its dead zone: {target, levels, level, at, nodes}
var _held_group = null ## the GroupSet this hand carries (held_node is its anchor), or null
var _sel_group = null ## the GroupSet the laser has selected (selected_node is its anchor), or null
var _sel_level: Dictionary = {}
var _crumb = null ## the open laser breadcrumb
var _crumb_levels: Array = []
var _crumb_press: Dictionary = {} ## the trigger press that may turn into a breadcrumb: {ms, node, point}
var _select_down := false
var _paint_press: Dictionary = {} ## the trigger press of the Appearance tool: {ms, node, face_index, point}; a click or, held, the breadcrumb
var _paint_crumb = null ## the open paint breadcrumb (group_breadcrumb.gd with swatches)
var _paint_rows: Array = [] ## its rows (appearance_tool.gd rows_for)
var _paint_hover := -1 ## the row being previewed
var _paint_cues: Array = [] ## brackets round what the previewed row paints
var _wheel_press_ms := {} ## action name -> Time.get_ticks_msec() of its last press, for wheel chord detection
var _laser: MeshInstance3D
var _laser_mesh: CylinderMesh
var _part_hit_distance := -1.0 ## metres to whatever _update_aim_hover()'s own raycast last hit, or -1 for nothing — set alongside _aim_hover_node
var _select_material: StandardMaterial3D
var _hover_material: StandardMaterial3D
var _hover_node: Node3D = null ## the part a grip would grab right now, lightly highlighted
var _aim_hover_material: StandardMaterial3D
var _aim_hover_node: Node3D = null ## the part the laser would select right now, lightly highlighted
var face_highlight = null ## set by main.gd; face_highlight.gd: with Mates / Measure on, the laser lights up only the FACE it would pick
var _marker_material: StandardMaterial3D ## the small origin sphere; coloured from the UI theme (see _style_ring())
var _ring_material: StandardMaterial3D ## the tracking ring
var _ring_face_material: StandardMaterial3D ## its faint glass face
var _ring_glow_material: StandardMaterial3D ## its soft outer glow (shader effects on)
var _ring_glow_node: MeshInstance3D
var _seen_theme_revision := -1
var _hover_panel: Node3D = null ## the floating window / keyboard this hand's laser is on (it glows, and a grip would carry it)
var _hover_panel_distance := -1.0
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
	_add_tracking_ring()
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
	if _seen_theme_revision != UiThemes.revision:
		_style_ring()
	_update_grab_hover()
	_update_aim_hover()
	_update_panel_hover()
	_update_laser_visual()
	if section_tool:
		section_tool.update_held(self, delta, steadiness > 0)
	_update_latch()
	_update_crumb()
	_update_paint_crumb()
	if _sel_group != null:
		_sel_group.follow() # last frame's thumbstick / nudge moved the anchor: the rest of the group goes with it
	if held_node != null:
		_update_held_part(delta)
	if drive_tool_active and drive_tool != null and wheel_enabled and held_node == null and not bool(get_meta("ui_hover", false)) and not wheel_is_open():
		drive_tool.feed(get_vector2("primary"), is_button_pressed("ax_button"), is_button_pressed("by_button"))
	if _nudge_carried_panel(delta):
		return # A/B belong to the floating window this hand is carrying, not to a selected part
	if selected_node == null or _table_owns_input() or wheel_is_open():
		return # (the design table has this hand's stick and A / B while it is engaged: table_manip.gd)

	var stick: Vector2 = get_vector2("primary")
	# The laser on the wrist tablet / a floating window means the stick scrolls
	# that panel (wrist_tablet.gd) — it must not also spin the selected part.
	var stick_active := stick.length() >= stick_deadzone and not bool(get_meta("ui_hover", false))
	var pushing := stick_active or is_button_pressed("ax_button") or is_button_pressed("by_button")
	if pushing and mates_tool and mates_tool.is_locked(selected_node):
		mates_tool.notify_locked(selected_node) # grounded by an enforced mate: not movable (throttled message)
		return
	if pushing and mates_tool and _sel_group == null and mates_tool.is_nested_locked(selected_node):
		mates_tool.notify_nested_locked(selected_node) # held by its sub-assembly's mates (throttled message)
		return
	# Enforced mates: the increments below are applied to the drag's ACCUMULATED
	# wish (the displayed pose lags a network round trip behind), then handed to
	# the live solver, whose answer is what's shown — see mates_tool.gd.
	var constrained: bool = mates_tool != null and mates_tool.is_constrained(selected_node) and (pushing or mates_tool.has_drag(selected_node))
	if constrained:
		selected_node.global_transform = mates_tool.desired_global(selected_node)
	if stick_active:
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
		_nudge_along_aim(selected_node, forward, -1.0, speed, delta)
	if is_button_pressed("by_button"):
		_nudge_along_aim(selected_node, forward, 1.0, speed, delta)
	if constrained:
		selected_node.global_transform = mates_tool.constrain_drag(selected_node, selected_node.global_transform)
		if mates_tool.take_stuck_notice(selected_node):
			trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0) # fully constrained: the wrist says so (mates_tool.gd)


func _nudge_along_aim(part: Node3D, aim: Vector3, direction: float, speed: float, delta: float) -> void:
	## A/X (direction -1) pulls the part towards your hand, B/Y (+1) pushes it
	## away — both the same "bead on the laser" motion: the hand-to-part
	## direction eases towards where you're aiming (nudge_steer_rate) while the
	## distance changes at `speed`. Real-headset feedback on the first cut:
	## A (steering at 6/s) tracked the laser too fast while B (a plain
	## move-by-aim, no steering at all) hardly tracked it, and they should feel
	## the same — so they now share this one routine at the mid-point rate.
	## (Moving by -aim, the very first A, inverted the steering: tilt up and the
	## part went down.) A stops nudge_min_distance short of the hand so it can't
	## pass through it.
	var centre := part_centre(part)
	var offset := centre - global_position
	var dist := offset.length()
	if dist < 0.0001:
		return
	var dir := offset / dist
	if dir.dot(aim) > -0.99: # part directly behind the hand: no meaningful steering
		dir = dir.slerp(aim, clampf(nudge_steer_rate * delta, 0.0, 1.0))
	var new_dist := dist + direction * speed * delta
	if direction < 0.0:
		if dist <= nudge_min_distance:
			return
		new_dist = maxf(new_dist, nudge_min_distance)
	part.global_position += (global_position + dir * new_dist) - centre


func part_centre(part: Node3D) -> Vector3:
	## World-space middle of the part's bounds (a part's origin can sit far
	## from its geometry).
	if part is MeshInstance3D:
		return part.global_transform * (part as MeshInstance3D).get_aabb().get_center()
	return part.global_position


func nudge_speed_for(part: Node3D) -> float:
	## A/B speed for this part: proportional to how far it is from your hand
	## (measured to the middle of its bounds, since a part's origin can sit far
	## from its geometry), clamped to a sensible range.
	return clampf(nudge_rate * global_position.distance_to(part_centre(part)), nudge_min_speed, nudge_max_speed)


func is_manipulating() -> bool:
	## Lets locomotion.gd know this hand's thumbstick is busy rotating a
	## selected part (or the part on the design table) right now, so it doesn't
	## also drive movement/turning.
	return selected_node != null or _table_owns_input() or wheel_is_open() or (drive_tool_active and drive_tool != null and wheel_enabled and drive_tool.owns_stick())


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
	_close_crumb()
	_cancel_paint()
	_set_grab_hover(null)
	_set_aim_hover(null, Vector3.ZERO)


func wheel_is_open() -> bool:
	## True from the wheel chord until BOTH buttons are up again (tool_wheel.gd owns the meta): the grip / trigger
	## / stick must not also grab, select, drag the world or turn you while the wheel has them.
	return bool(get_meta("wheel_open", false))


func _wheel_chord_completed_by(action_name: String) -> bool:
	## Records the press and says whether it completes the trigger + grip chord (the other one is held, and was
	## pressed within wheel_window_ms). Only on a hand with wheel_enabled.
	if not wheel_enabled or (action_name != grab_action and action_name != select_action):
		return false
	var now := Time.get_ticks_msec()
	_wheel_press_ms[action_name] = now
	var other := select_action if action_name == grab_action else grab_action
	return is_button_pressed(other) and now - int(_wheel_press_ms.get(other, -1000000)) <= wheel_window_ms


func cancel_for_wheel() -> void:
	## The first press of a chord already did its normal job (began a grab, selected a part...); the second one
	## turns it into the wheel, so let go of whatever the first started.
	_try_release()


func _on_button_pressed(action_name: String) -> void:
	if wheel_is_open() or bool(get_meta("room_placing", false)):
		return # (placing an Assembly Room: this hand's laser and trigger are the room's - room_manager.gd)
	if _wheel_chord_completed_by(action_name):
		wheel_chord_started.emit()
		return
	if action_name == grab_action:
		if _try_grab_table():
			return
		if _try_grab_room_handle():
			return # a wall handle or the move bar of an Assembly Room (room_handles.gd)
		if _try_grab_panel_at_distance():
			return
		# The section-plane gizmo is independent of "Individual part
		# manipulation" mode (like mates_tool_active/hide_tool_active are for
		# the trigger below) — parts_enabled only gates the ordinary part-grab
		# search inside _try_grab() itself.
		if parts_enabled or (section_tool and section_tool.active):
			_try_grab()
	elif action_name == select_action:
		if not _latch.is_empty():
			_cycle_latch() # (a grip is waiting out its dead zone: the trigger widens what it will take - one level up each click)
			return
		if has_meta("ui_hover") and get_meta("ui_hover"):
			return # laser is over the wrist tablet or popup keyboard: the click is for them, not a part.
		_select_down = true
		if mates_tool_active:
			_try_pick_mate_entity()
		elif measure_tool_active:
			_try_pick_measure_entity()
		elif drive_tool_active:
			_try_pick_drive_axis()
		elif hide_tool_active:
			# Its own tool, independent of "Individual part manipulation" mode.
			_try_shoot_hide()
		elif paint_active:
			_arm_paint()
		elif parts_enabled and laser_select_enabled:
			_try_select()
			_arm_crumb()


func _on_button_released(action_name: String) -> void:
	if action_name == grab_action:
		_try_release()
	elif action_name == select_action:
		_select_down = false
		_finish_crumb()
		_finish_paint()
	if wheel_is_open():
		return


func _try_grab() -> void:
	if held_node != null:
		return
	for panel in get_tree().get_nodes_in_group("diegetic_panels"):
		if panel.handle_in_reach(self):
			return # a floating window's drag handle is what this grip is for (diegetic_panel.gd grabs it itself) — never also a part or the section gizmo
	if section_tool and section_tool.try_grab(self, grab_reach):
		return # gizmo grabbed instead — see section_tool.gd's own docstring for why this is checked first

	# Deliberately ignores selected_node so grip never feels tied to the laser-select state.
	var target := _find_grab_target()
	if target and mates_tool and mates_tool.is_locked(target):
		# Grounded by an enforced mate: it's the anchor the mated parts are solved
		# against. Say so instead of silently doing nothing.
		trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
		mates_tool.notify_locked(target)
		return
	if target:
		_set_grab_hover(null)
		if _sel_group != null and _sel_group.members.has(target):
			_sel_group.follow()
			_finish_group_move(_sel_group) # (whatever the thumbstick did to it so far is its own undo step)
			_sel_group.reset_starts()
			_begin_group_hold(target, _sel_level) # (the group you selected with the laser: no choosing to do)
			return
		if group_deadzone > 0.0 and GroupIndex.has_groups(target):
			_begin_latch(target)
			return
		_begin_part_hold(target)


# --- sub-assemblies: choosing what a grip or the laser takes (group_index.gd, group_set.gd) ---

func _scope_nodes() -> Array:
	return get_tree().get_nodes_in_group("grabbable_parts")


func _scene_root() -> Node:
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root


func _begin_latch(target: Node3D) -> void:
	## A grip on a part inside a sub-assembly: nothing moves yet. A faint sphere marks the dead zone, brackets show what a drag would take (the part), and
	## each trigger click widens that one level. Moving the hand out of the sphere takes it.
	var levels := GroupIndex.levels(target, _scope_nodes())
	if levels.size() <= 1:
		_begin_part_hold(target) # nothing wider to choose
		return
	_latch = {"target": target, "levels": levels, "level": 0, "at": global_position, "nodes": [], "cues": []}
	var sphere := GroupCues.sphere(group_deadzone)
	_scene_root().add_child(sphere)
	sphere.global_position = global_position
	_latch["nodes"].append(sphere)
	_show_latch_level()
	trigger_haptic_pulse("haptic", 0.0, 0.25, 0.04, 0.0)


func _show_latch_level() -> void:
	GroupCues.clear(_latch["cues"])
	_latch["cues"] = []
	var levels: Array = _latch["levels"]
	var level: Dictionary = levels[_latch["level"]]
	var box := GroupIndex.union_aabb(level["members"])
	var brackets := GroupCues.brackets(box.grow(0.004))
	_scene_root().add_child(brackets)
	var text := GroupIndex.breadcrumb(levels, _latch["level"])
	var cap := GroupCues.caption(text, box.get_center() + Vector3(0.0, box.size.y * 0.5 + 0.07, 0.0))
	_scene_root().add_child(cap)
	_latch["cues"] = [brackets, cap]


func _cycle_latch() -> void:
	var levels: Array = _latch["levels"]
	_latch["level"] = (int(_latch["level"]) + 1) % levels.size()
	_show_latch_level()
	trigger_haptic_pulse("haptic", 0.0, 0.35, 0.05, 0.0)
	group_message.emit(GroupIndex.breadcrumb(levels, _latch["level"]))


func _end_latch() -> void:
	if _latch.is_empty():
		return
	GroupCues.clear(_latch.get("nodes", []))
	GroupCues.clear(_latch.get("cues", []))
	_latch = {}


func _update_latch() -> void:
	if _latch.is_empty():
		return
	if not is_instance_valid(_latch["target"]):
		_end_latch()
		return
	if global_position.distance_to(_latch["at"]) > group_deadzone:
		_commit_latch()


func _commit_latch() -> void:
	## The hand left the dead zone: take what the trigger chose.
	var levels: Array = _latch["levels"]
	var level: Dictionary = levels[_latch["level"]]
	var target: Node3D = _latch["target"]
	_end_latch()
	if int(level["depth"]) == 0:
		_begin_part_hold(target)
		return
	_begin_group_hold(target, level)


func _begin_part_hold(target: Node3D) -> void:
	## A grip that takes the part on its own. A part its sub-assembly's mates hold (with mates enforced) refuses: only the sub-assembly can go.
	if mates_tool and mates_tool.is_nested_locked(target):
		trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
		mates_tool.notify_nested_locked(target)
		return
	_begin_hold(target, target.global_transform)


func _begin_group_hold(target: Node3D, level: Dictionary) -> void:
	var gs := GroupSet.new(target, level)
	var refusal := _group_refusal(gs)
	if refusal != "":
		trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
		group_message.emit(refusal)
		return
	_held_group = gs
	gs.set_flag("held", true)
	_begin_hold(target, target.global_transform)
	trigger_haptic_pulse("haptic", 0.0, 0.5, 0.06, 0.0)
	group_message.emit("Holding %s (%d parts)" % [gs.label, gs.members.size()])


func _group_refusal(gs) -> String:
	## Why this sub-assembly can't be moved now ("" if it can). Only a top-level one is saved, so only its grounding and mates matter.
	if mates_tool != null and mates_tool.relaxed:
		return "" # the sandbox: anything moves, nothing is saved, it all goes home after
	if gs.depth == 1 and mates_tool != null:
		match mates_tool.group_state(gs.root_part_id, gs.occurrence_id()):
			"grounded":
				return "%s is grounded (fixed): unground it to move it." % gs.label
			"mated":
				return "%s has mates on it: a mated sub-assembly can't be moved as a unit yet." % gs.label
	if gs.depth > 1 and mates_tool != null and gs.prefix.size() >= gs.depth:
		# A sub-assembly inside another moves on screen only: one its parent's mates hold would just be pulled off them.
		var parts: Array = gs.anchor.get_meta("group_parts", [])
		if parts.size() >= gs.depth - 1 and mates_tool.nested_occurrence_locked(str(parts[gs.depth - 2]), str(gs.prefix[gs.depth - 1])):
			return "%s is held by mates inside its sub-assembly: take the sub-assembly it sits in, or Relax all mates." % gs.label
	return ""


func _finish_group_move(gs) -> void:
	## A carried or selected group was put down. Out of its room (or into another): back where it was. Otherwise ONE undo step moves every member, and a
	## top-level sub-assembly's new pose is saved on its occurrence (a deeper one moves on screen only, as a part nested in a sub-assembly always has).
	if gs == null or not is_instance_valid(gs.anchor):
		return
	var stray := RoomRegistry.stray_reason(gs.anchor)
	if stray != "":
		var dropped: Transform3D = gs.anchor.global_transform
		var centre := GroupIndex.union_aabb(gs.members).get_center()
		var info := {"root": gs.root_part_id, "path": GroupIndex.path_of(gs.anchor), "parts": gs.anchor.get_meta("group_parts", []), "depth": gs.depth,
			"anchor_pose": dropped, "label": gs.label, "centre": centre}
		gs.restore()
		trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
		get_tree().call_group("room_listeners", "on_group_refused", info, stray) # (let go INSIDE a room: a copy of the sub-assembly is added to it - room_manager.gd)
		return
	if not gs.moved() or command_stack == null:
		return
	var starts: Dictionary = gs.starts.duplicate()
	var finals: Dictionary = gs.finals()
	var net: Transform3D = gs.net_delta() # (taken now: the group may be re-based while the pose below is read)
	var parent := gs.anchor.get_parent() as Node3D
	var pg: Transform3D = parent.global_transform if parent != null else Transform3D.IDENTITY
	var occ: String = gs.occurrence_id()
	var owner: String = gs.root_part_id
	var sandbox: bool = mates_tool != null and mates_tool.is_sandboxed(gs.anchor)
	var save: bool = occ != "" and mates_tool != null and not sandbox and mates_tool.group_state(owner, occ) == "ok"
	var old_pose: Variant = null
	var new_pose: Variant = null
	if save:
		old_pose = await mates_tool.group_pose(owner, occ)
		if old_pose != null:
			new_pose = (pg.affine_inverse() * net * pg) * (old_pose as Transform3D)
		else:
			save = false
	var tool = mates_tool
	command_stack.push("move %s" % gs.label,
		func() -> void:
			GroupSet.apply(starts)
			if save and tool != null:
				tool.persist_group_pose(owner, occ, old_pose),
		func() -> void:
			GroupSet.apply(finals)
			if save and tool != null:
				tool.persist_group_pose(owner, occ, new_pose),
		save)
	if save:
		mates_tool.persist_group_pose(owner, occ, new_pose)
	elif gs.depth > 1 and not sandbox:
		group_message.emit("%s moved on screen only: a sub-assembly inside another isn't saved from here (open it as a room to edit it)." % gs.label)


func _arm_crumb() -> void:
	## The trigger has just selected a part. Held on, it opens the breadcrumb of assembly levels at the spot the ray hit.
	_crumb_press = {}
	if selected_node == null or _sel_group != null or not GroupIndex.has_groups(selected_node):
		return
	_crumb_press = {"ms": Time.get_ticks_msec(), "node": selected_node, "point": selected_node.global_transform * _pivot_local}


func _update_crumb() -> void:
	if _crumb != null:
		_crumb.update_aim(global_position, -global_transform.basis.z)
		return
	if _crumb_press.is_empty():
		return
	if not _select_down or not is_instance_valid(_crumb_press["node"]) or selected_node != _crumb_press["node"]:
		_crumb_press = {}
		return
	if Time.get_ticks_msec() - int(_crumb_press["ms"]) >= CRUMB_HOLD_MS:
		_open_crumb()


func _open_crumb() -> void:
	var node: Node3D = _crumb_press["node"]
	_crumb_levels = GroupIndex.levels(node, _scope_nodes())
	if _crumb_levels.size() <= 1:
		_crumb_press = {}
		return
	var texts: Array = []
	for l in _crumb_levels:
		texts.append(str(l["label"]) + ("" if int(l["depth"]) == 0 else "  (%d)" % (l["members"] as Array).size()))
	_crumb = GroupBreadcrumb.new()
	_scene_root().add_child(_crumb)
	var head := _camera.global_position if _camera != null else global_position
	_crumb.open(texts, _crumb_press["point"], head, 0)
	trigger_haptic_pulse("haptic", 0.0, 0.3, 0.05, 0.0)


func _finish_crumb() -> void:
	## The trigger came up: a level under the laser is selected as a group (the part itself, or no row, keeps what the press selected).
	if _crumb == null:
		_crumb_press = {}
		return
	var index: int = _crumb.hovered
	var levels := _crumb_levels
	var point: Vector3 = _crumb_press.get("point", global_position)
	var node = _crumb_press.get("node")
	_close_crumb()
	if index > 0 and index < levels.size() and is_instance_valid(node) and selected_node == node:
		select_group_level(node, levels[index], point)


func _close_crumb() -> void:
	_crumb_press = {}
	_crumb_levels = []
	if _crumb != null:
		if is_instance_valid(_crumb):
			if _crumb.get_parent() != null:
				_crumb.get_parent().remove_child(_crumb)
			_crumb.queue_free()
		_crumb = null


func select_group_level(node: Node3D, level: Dictionary, point: Vector3) -> void:
	## Selects a sub-assembly (the level's members) with `node` as its anchor: all of it lights up, the thumbstick turns it and A / B push it as one, and a
	## grip on any of its parts carries all of it.
	_clear_selection()
	if int(level["depth"]) == 0 or (level["members"] as Array).size() <= 1:
		_set_selection(node, point)
		return
	_set_selection(node, point)
	_sel_level = level
	_sel_group = GroupSet.new(node, level)
	for m in _sel_group.members:
		if is_instance_valid(m):
			m.set_meta("selected", true)
			m.material_overlay = _select_material
	group_message.emit("Selected %s (%d parts)" % [_sel_group.label, _sel_group.members.size()])


func _try_grab_table() -> bool:
	## A part on the design table: gripping its copy moves it (and with the other hand turns and scales it), on the table
	## only and independent of the world (design_table.gd / table_manip.gd). Independent of "Individual part
	## manipulation" mode, like the section gizmo, and checked before the distance-grab of a window; a floating window's
	## own drag handle in reach still wins, as it does over every other grip.
	if held_node != null:
		return false
	var tables := get_tree().get_nodes_in_group("design_tables")
	if tables.is_empty():
		return false
	for panel in get_tree().get_nodes_in_group("diegetic_panels"):
		if panel.handle_in_reach(self):
			return false
	for table in tables:
		if table.try_grab(self):
			_set_grab_hover(null)
			return true
	return false


func _table_owns_input() -> bool:
	## The design table is engaged (a hand is on its part, or this hand's laser is): this hand's stick and A / B are the table's.
	for table in get_tree().get_nodes_in_group("design_tables"):
		if table.owns_stick(self):
			return true
	return false


func _begin_hold(target: Node3D, start_transform: Transform3D) -> void:
	## Starts carrying `target`. `start_transform` is the pose undo returns it to: where it was when picked up.
	target.set_meta("held", true)
	_held_start_transform = start_transform
	# Its pose relative to this hand right now, kept exactly where you took
	# hold of it: turning your hand turns the part about that spot. Stays
	# under assembly_root rather than reparenting to the hand, since
	# _update_held_part() drives its transform explicitly every frame (so
	# steadiness — see below — can filter the hand's position first).
	_grab_offset = global_transform.affine_inverse() * target.global_transform
	_grab_filter.reset(global_position)
	held_node = target


func _update_panel_hover() -> void:
	## Which floating window / keyboard this hand's laser is on (the nearest, unless a part is in front
	## of it): it glows, so you can see it's grabbable, and a grip will carry it. A hand that is already
	## carrying a part or a panel doesn't pick anything else.
	var panels := get_tree().get_nodes_in_group("diegetic_panels")
	var best: Node3D = null
	var best_d := INF
	var busy := held_node != null
	for panel in panels:
		if panel.get("handle") != null and panel.handle.held_by == self:
			busy = true
	if not busy:
		var origin := global_position
		var dir := -global_transform.basis.z.normalized()
		for panel in panels:
			if panel.get("handle") == null:
				continue
			var d: float = panel.handle.laser_hit_distance(origin, dir)
			if d >= 0.0 and d < best_d:
				best = panel
				best_d = d
		if best != null and _part_hit_distance >= 0.0 and _part_hit_distance < best_d - 0.02:
			best = null # a part is in front of the window: the laser is on the part
	for panel in panels:
		if panel.get("handle") != null:
			panel.handle.set_hover(self, panel == best)
	if best != null and best != _hover_panel:
		UiFeedback.haptic(self, "hover") # a light tick as the laser lands on a window
	_hover_panel = best
	_hover_panel_distance = best_d if best != null else -1.0


func _try_grab_panel_at_distance() -> bool:
	## Grip with the laser on a floating window / keyboard carries it from where it is. Anything the
	## hand is actually touching wins (a part in reach, the section gizmo, a panel's own near handle),
	## and so does the whole-model grab otherwise, so this only claims a grip aimed at a window.
	if _hover_panel == null or not is_instance_valid(_hover_panel) or held_node != null:
		return false
	if _hover_panel.handle_in_reach(self):
		return false # the near handle grab (panel_handle.gd) is for this grip
	if parts_enabled and _find_grab_target() != null:
		return false
	if section_tool and section_tool.active and section_tool.gizmo() != null and global_position.distance_to(section_tool.gizmo().global_position) < 0.2:
		return false
	return _hover_panel.handle.start_laser_grab(self)


func _nudge_carried_panel(delta: float) -> bool:
	## A/X pulls the window this hand is carrying towards you, B/Y pushes it away: the same
	## distance-proportional speed as nudging a part (far windows travel fast, near ones finely).
	## True while this hand carries a panel.
	for panel in get_tree().get_nodes_in_group("diegetic_panels"):
		if panel.get("handle") != null and panel.handle.held_by == self:
			var direction := 0.0
			if is_button_pressed("ax_button"):
				direction -= 1.0
			if is_button_pressed("by_button"):
				direction += 1.0
			if direction != 0.0:
				nudge_carried_panel(direction, delta)
			return true
	return false


func nudge_carried_panel(direction: float, delta: float) -> void:
	## Split out so tests can drive it without a real XR runtime (direction -1 pulls, +1 pushes).
	for panel in get_tree().get_nodes_in_group("diegetic_panels"):
		if panel.get("handle") != null and panel.handle.held_by == self:
			var speed := clampf(nudge_rate * panel.handle.carry_distance(), nudge_min_speed, nudge_max_speed)
			panel.handle.nudge(direction * speed * delta)


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
		if not RoomRegistry.part_visible_at(node, _closest_point_on_part(node)):
			continue # the part's nearest bit to your hand is cut away by a room's walls: there is nothing there to touch
		var volume: float = node.get_aabb().get_volume() * absf(node.global_transform.basis.determinant())
		if reach < best_reach - 0.001 or (absf(reach - best_reach) <= 0.001 and volume < best_volume):
			best = node
			best_reach = reach
			best_volume = volume
	return best


func _reach_distance(part: MeshInstance3D) -> float:
	## World distance from this hand to the part's bounding box (0 if inside it).
	return global_position.distance_to(_closest_point_on_part(part))


func _closest_point_on_part(part: MeshInstance3D) -> Vector3:
	## World-space point of the part's bounding box nearest this hand (the hand itself if it is inside the box).
	var box := part.get_aabb()
	var local: Vector3 = part.global_transform.affine_inverse() * global_position
	return part.global_transform * local.clamp(box.position, box.end)


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


func _try_grab_room_handle() -> bool:
	if held_node != null:
		return false
	for h in get_tree().get_nodes_in_group("room_handles"):
		if h.try_grab(self):
			_set_grab_hover(null)
			return true
	return false


func _try_release() -> void:
	for h in get_tree().get_nodes_in_group("room_handles"):
		if h.release(self):
			return
	for table in get_tree().get_nodes_in_group("design_tables"):
		if table.release_grab(self):
			return # let go of the part on the design table: it stays there or goes back to the arena (design_table.gd)
	if section_tool and section_tool.release(self):
		return
	if not _latch.is_empty():
		_end_latch() # let go inside the dead zone: nothing was taken, nothing moved, nothing to undo
		return
	if held_node == null:
		return

	var part := held_node
	part.set_meta("held", false)
	held_node = null
	if _held_group != null:
		var gs = _held_group
		_held_group = null
		gs.set_flag("held", false)
		gs.follow()
		_finish_group_move(gs)
		if _sel_group != null:
			_sel_group.reset_starts() # (the grip's move is its own undo step: selecting it later must not record it again)
		return
	if mates_tool and mates_tool.end_drag(part):
		return # constrained part: mates_tool.gd finishes the last solve and records the undo step
	for table in get_tree().get_nodes_in_group("design_tables"):
		if table.try_seat_released(part, _held_start_transform):
			return # let go over the design table: the table took it, and the part's pose in the assembly is unchanged
	_push_move_command(part, _held_start_transform)
	for table in get_tree().get_nodes_in_group("design_tables"):
		table.part_put_down(part) # a part whose mates went stale in an edit gets the Enforce mates button here


func _update_held_part(delta: float) -> void:
	## Filters this hand's position (not its rotation — see the class-level
	## comment) before applying the grab offset, so a held hand's few-mm
	## tremor doesn't reach the part while a deliberate move still does.
	var filtered_pos := global_position if steadiness == 0 else _grab_filter.filter(global_position, delta)
	var desired := Transform3D(global_transform.basis, filtered_pos) * _grab_offset
	if _held_group == null and mates_tool and mates_tool.is_constrained(held_node):
		# Enforced mates: the part slides along what they allow (a live solve on
		# the backend, mates_tool.gd) instead of following the hand freely.
		held_node.global_transform = mates_tool.constrain_drag(held_node, desired)
		if mates_tool.take_stuck_notice(held_node):
			trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0) # fully constrained: the wrist says so (mates_tool.gd)
	else:
		held_node.global_transform = desired
	if _held_group != null:
		_held_group.follow()


func _push_move_command(part: Node3D, before: Transform3D) -> void:
	if not is_instance_valid(part):
		return
	var stray := RoomRegistry.stray_reason(part)
	if stray != "":
		# A room's part put down outside its room, or a world part left inside a room: back to where it was picked up (the walls are the edge of its
		# world). The move was never recorded or saved, so there is nothing to undo.
		var dropped := part.global_transform
		part.global_transform = before
		trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
		get_tree().call_group("room_listeners", "on_part_refused", part, stray, dropped) # (a drop INTO a room becomes a copy added to it: room_manager.gd)
		return
	if command_stack == null:
		return
	var after := part.global_transform
	if before.is_equal_approx(after):
		return # no net move: nothing worth undoing
	command_stack.push("move %s" % part.name,
		func() -> void:
			part.global_transform = before
			_sync_pose(part),
		func() -> void:
			part.global_transform = after
			_sync_pose(part),
		not (mates_tool != null and mates_tool.is_sandboxed(part))) # persists: a part's pose is part of the document (a sandbox move is not: it goes home)
	_sync_pose(part) # the move itself: the backend's copy must match what you see, or every later mate solves against a stale pose


func _sync_pose(part: Node3D) -> void:
	if mates_tool and is_instance_valid(part):
		mates_tool.persist_pose(part)


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


# --- the Appearance tool's gun (DIDSA-CAD docs/appearance-tool-scope.md D1) ---

func _world_root() -> String:
	return str(appearance_tool.get("world_root")) if appearance_tool != null else ""


func _arm_paint() -> void:
	## Trigger down with the Appearance tool on. Nothing is painted yet: a click (up within CRUMB_HOLD_MS) paints the body on release,
	## a hold opens the breadcrumb. With the eyedropper armed the shot takes the look under the laser instead.
	_paint_press = {}
	if appearance_tool == null:
		return
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null:
		return
	if bool(appearance_tool.eyedropper):
		await appearance_tool.ensure_loaded(appearance_tool.root_of(part, _world_root()))
		var got: Dictionary = appearance_tool.take_from(part, int(hit.get("face_index", -1)), _world_root())
		trigger_haptic_pulse("haptic", 0.0, 0.3, 0.05, 0.0)
		tool_message.emit("Took the look of %s: %s." % [part.name, appearance_tool.Rule.key_of(got).replace(";", ", ")])
		return
	if bool(appearance_tool.is_busy()):
		tool_message.emit("Paint: still saving the last paint, shoot again in a moment.")
		return
	_paint_press = {"ms": Time.get_ticks_msec(), "node": part, "face_index": int(hit.get("face_index", -1)), "point": hit.get("point", part.global_position)}
	appearance_tool.ensure_loaded(appearance_tool.root_of(part, _world_root())) # (fire and forget: the lists are usually in by the time the trigger comes up)


func _update_paint_crumb() -> void:
	if _paint_crumb != null:
		var row: int = _paint_crumb.update_aim(global_position, -global_transform.basis.z)
		if row != _paint_hover:
			_paint_hover = row
			_show_paint_row(row)
		return
	if _paint_press.is_empty():
		return
	if not _select_down or not is_instance_valid(_paint_press["node"]):
		_paint_press = {}
		return
	if Time.get_ticks_msec() - int(_paint_press["ms"]) >= CRUMB_HOLD_MS:
		_open_paint_crumb()


func _open_paint_crumb() -> void:
	var node: Node3D = _paint_press["node"]
	_paint_rows = appearance_tool.rows_for(node, int(_paint_press["face_index"]), _scope_nodes(), _world_root())
	var texts: Array = []
	var swatches: Array = []
	var notes: Array = []
	var start := 0
	for i in _paint_rows.size():
		var row: Dictionary = _paint_rows[i]
		texts.append(row["label"])
		var look: Dictionary = row.get("swatch", {})
		swatches.append(appearance_tool.Look.colour_of(str(look["colour"]), float(look.get("opacity", 1.0))) if look.has("colour") else null)
		notes.append("set here" if bool(row.get("set_here", false)) else "")
		if row["id"] == "body":
			start = i # (what a click would have done: lit when it opens)
	_paint_crumb = GroupBreadcrumb.new()
	_scene_root().add_child(_paint_crumb)
	var head := _camera.global_position if _camera != null else global_position
	_paint_crumb.open(texts, _paint_press["point"], head, start, {"title": appearance_tool.panel_title(), "swatches": swatches, "notes": notes})
	_paint_hover = -2 # (the first update_aim previews whatever the laser is on)
	trigger_haptic_pulse("haptic", 0.0, 0.3, 0.05, 0.0)


func _show_paint_row(row: int) -> void:
	## Hovering a row: the model shows what a release would do (everything else keeps its own look), brackets show its extent, a tick.
	GroupCues.clear(_paint_cues)
	_paint_cues = []
	var nodes := _scope_nodes()
	if row < 0 or row >= _paint_rows.size():
		appearance_tool.end_preview(nodes, _world_root())
		return
	var r: Dictionary = _paint_rows[row]
	var node: Node3D = _paint_press.get("node")
	appearance_tool.preview(r, appearance_tool.root_of(node, _world_root()), nodes, _world_root())
	var box := GroupIndex.union_aabb(r["members"])
	var brackets := GroupCues.brackets(box.grow(0.004))
	_scene_root().add_child(brackets)
	_paint_cues.append(brackets)
	trigger_haptic_pulse("haptic", 0.0, 0.2, 0.03, 0.0)
	var count := (r["members"] as Array).size()
	tool_message.emit("Paint · %s%s" % [r["label"], ", %d parts" % count if count > 1 and not str(r["label"]).contains("(") else ""])


func _finish_paint() -> void:
	## Trigger up. Over a row: that row is painted (one undo step). Off the panel: nothing (a hold means "I want to choose"). No panel
	## (a click): the body under the laser.
	if _paint_crumb != null:
		var index := _paint_hover
		var rows := _paint_rows
		var node: Node3D = _paint_press.get("node")
		_close_paint_crumb()
		if index < 0 or index >= rows.size() or not is_instance_valid(node):
			appearance_tool.end_preview(_scope_nodes(), _world_root())
			tool_message.emit("Nothing painted (let go off the panel).")
			_paint_press = {}
			return
		_paint_press = {}
		await _paint_row(node, rows[index])
		return
	if _paint_press.is_empty():
		return
	var press := _paint_press
	_paint_press = {}
	if not is_instance_valid(press["node"]):
		return
	var root: String = appearance_tool.root_of(press["node"], _world_root())
	await appearance_tool.ensure_loaded(root)
	var rows: Array = appearance_tool.rows_for(press["node"], int(press["face_index"]), _scope_nodes(), _world_root())
	var body := rows.filter(func(r) -> bool: return r["id"] == "body")
	await _paint_row(press["node"], body[0] if not body.is_empty() else rows[0])


func _paint_row(node: Node3D, row: Dictionary) -> void:
	var result: Dictionary = await appearance_tool.apply(row, appearance_tool.root_of(node, _world_root()), _scope_nodes(), _world_root())
	if not result.get("ok", false):
		trigger_haptic_pulse("haptic", 0.0, 0.6, 0.12, 0.0)
		tool_message.emit("Couldn't paint %s: %s" % [str(row.get("label", "")), str(result.get("error", "unknown error"))])
		return
	trigger_haptic_pulse("haptic", 0.0, 0.3, 0.05, 0.0)


func _close_paint_crumb() -> void:
	GroupCues.clear(_paint_cues)
	_paint_cues = []
	_paint_rows = []
	_paint_hover = -1
	if _paint_crumb != null:
		if is_instance_valid(_paint_crumb):
			if _paint_crumb.get_parent() != null:
				_paint_crumb.get_parent().remove_child(_paint_crumb)
			_paint_crumb.queue_free()
		_paint_crumb = null


func _cancel_paint() -> void:
	if _paint_crumb != null and appearance_tool != null:
		appearance_tool.end_preview(_scope_nodes(), _world_root())
	_close_paint_crumb()
	_paint_press = {}


func _try_pick_mate_entity() -> void:
	## Mates tab active: the same ray test as laser-select, handed to
	## mates_tool.gd instead of selecting/hiding — see that script's own
	## try_pick() for validation (same-part, cross-assembly, no face
	## identity, etc.).
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null or mates_tool == null:
		return
	mates_tool.try_pick(part, hit.get("face_index", -1), _mate_entity(hit))


func _try_pick_measure_entity() -> void:
	## Measure tab active: same ray test, handed to measure_tool.gd instead —
	## see that script's own try_pick()/_validate_pick() for its (looser
	## than Mates') validation.
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null or measure_tool == null:
		return
	measure_tool.try_pick(part, hit.get("face_index", -1), _measure_entity(hit), hit.get("point", Vector3.INF))


func _try_pick_drive_axis() -> void:
	## Drive tool on: the same ray test; the pick (a round face, circular edge or straight edge) is the axis the stick turns / slides the part along.
	var hit := _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	var part: Node3D = hit.get("part")
	if part == null or drive_tool == null:
		return
	drive_tool.try_pick(part, hit.get("face_index", -1), _mate_entity(hit), hit.get("point", Vector3.INF))


func _mate_entity(hit: Dictionary) -> Dictionary:
	## What a Mates pick on this ray hit would take: a corner, a straight / circular edge, or the face.
	return LaserPick.entity_for(hit.get("part"), hit, global_position, true)


func _measure_entity(hit: Dictionary) -> Dictionary:
	## What a Measure pick on this ray hit would take: a vertex, an edge or a face (topology_pick.gd).
	return LaserPick.entity_for(hit.get("part"), hit, global_position)


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
	return LaserPick.ray(get_world_3d(), origin, direction, max_distance, func(part: Node3D) -> int:
		if not part.is_in_group("grabbable_parts"):
			return LaserPick.BLOCK # something solid that isn't an arena part (a design table copy): nothing behind it can be picked
		if (part.has_meta("held") and part.get_meta("held")) or not part.visible:
			return LaserPick.SKIP
		return LaserPick.HIT, 0xFFFFFFFF, RoomRegistry.part_visible_at)


func _update_aim_hover() -> void:
	## Light highlight plus the part's name on whatever the laser would
	## select right now, so you know what a trigger pull will pick before
	## you commit to it.
	var hit := {}
	if ((parts_enabled and laser_select_enabled) or hide_tool_active or paint_active or mates_tool_active or measure_tool_active or drive_tool_active) and held_node == null:
		hit = _raycast_part(global_transform.origin, -global_transform.basis.z.normalized(), select_max_distance)
	if face_highlight != null and paint_active and not mates_tool_active and not measure_tool_active and not drive_tool_active:
		# The Appearance tool: outline the body a click would paint (the outline only, no colour, so sweeping across a model doesn't flicker).
		_set_aim_hover(null, Vector3.ZERO)
		var paint_part: Node3D = hit.get("part")
		face_highlight.set_hover_entity(self, paint_part, TopologyPick.body_entity(paint_part, int(hit.get("face_index", -1))) if paint_part != null else {})
	elif face_highlight != null and (mates_tool_active or measure_tool_active or drive_tool_active):
		# A pick takes one CAD face (Mates) or face / edge / vertex (Measure), so light up just that, not the
		# whole mesh (which says nothing about what the trigger is about to take).
		_set_aim_hover(null, Vector3.ZERO)
		if measure_tool_active:
			face_highlight.set_hover_entity(self, hit.get("part"), _measure_entity(hit))
		else:
			var mate_entity := _mate_entity(hit)
			face_highlight.set_hover_entity(self, hit.get("part"), mate_entity if TopologyPick.is_mateable(hit.get("part"), mate_entity) else {})
	else:
		if face_highlight != null:
			face_highlight.clear_hover(self)
		_set_aim_hover(hit.get("part"), hit.get("point", Vector3.ZERO))
	_part_hit_distance = global_position.distance_to(hit["point"]) if hit.has("point") else -1.0


func _set_aim_hover(target: Node3D, _point: Vector3) -> void:
	## Highlight only: the part's name used to float beside the hit point too, which read as
	## clutter ("MESH 2") rather than information, so it was removed.
	if target == _aim_hover_node and is_instance_valid(target):
		return
	if is_instance_valid(_aim_hover_node) and _aim_hover_node != selected_node and _aim_hover_node.material_overlay == _aim_hover_material:
		_aim_hover_node.material_overlay = null
	_aim_hover_node = target
	if is_instance_valid(_aim_hover_node) and _aim_hover_node != selected_node:
		_aim_hover_node.material_overlay = _aim_hover_material


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
	if selected_node and _sel_group != null:
		var gs = _sel_group
		_sel_group = null
		_sel_level = {}
		selected_node = null
		for m in gs.members:
			if is_instance_valid(m):
				m.set_meta("selected", false)
				m.material_overlay = null
		gs.follow()
		_finish_group_move(gs)
		return
	if selected_node:
		var part := selected_node
		part.set_meta("selected", false)
		part.material_overlay = null
		selected_node = null
		if mates_tool and mates_tool.end_drag(part):
			return # constrained part: mates_tool.gd finishes the last solve and records the undo step
		_push_move_command(part, _selected_start_transform)


func _add_visible_marker() -> void:
	# Bare XRController3D nodes draw nothing at all — without this you
	# can't see your own hands in headset. Shrunk to a third of its
	# original 0.02m radius (John's own real-headset feedback: it read as
	# too large/prominent next to the laser it just marks the origin of)
	# and recoloured white to match the laser (see _add_laser()) and the
	# rest of this pass's white-line visual language (floor grid, tablet
	# icons).
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.02 / 3.0
	sphere.height = 0.04 / 3.0
	marker.mesh = sphere
	_marker_material = StandardMaterial3D.new()
	_marker_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_marker_material.emission_enabled = true
	sphere.material = _marker_material # coloured in _style_ring(): the UI theme's accent, like the rest of the redesign
	add_child(marker)


## A thin ring evoking the real controller's own tracking halo — the only
## controller reference left. Real-headset feedback removed the thumbstick /
## A-B / X-Y / Menu button discs (and their press flash) that used to sit on
## it, and asked for the ring itself to sit further back, towards the user:
## +Z is back (this XRController3D's aim points down local -Z — see
## _add_laser()), and it moved by one ring diameter (0.096 m, twice its 0.048 m
## outer radius) on top of the earlier 0.011 m nudge.
##
## UI redesign: the ring now matches the wrist watch and the tablet — a thin accent-coloured ring
## on a faint glass face, with a soft glow around it when shader effects are on; all colours come
## from the live UI theme (so Navy / Simple / Dark restyle it) via _style_ring().
func _add_tracking_ring() -> void:
	var anchor := Node3D.new()
	anchor.position = Vector3(0.0, 0.013, -0.024 + 0.011 + 0.096)
	add_child(anchor)

	_ring_glow_material = _flat_ring_material(true)
	_ring_glow_node = MeshInstance3D.new()
	var glow := TorusMesh.new()
	glow.inner_radius = 0.040
	glow.outer_radius = 0.058
	glow.material = _ring_glow_material
	_ring_glow_node.mesh = glow
	_ring_glow_node.position.y = -0.0005
	anchor.add_child(_ring_glow_node)

	_ring_face_material = _flat_ring_material(false)
	var face_node := MeshInstance3D.new()
	var face := CylinderMesh.new()
	face.top_radius = 0.0445
	face.bottom_radius = 0.0445
	face.height = 0.001
	face.radial_segments = 48
	face.material = _ring_face_material
	face_node.mesh = face
	anchor.add_child(face_node)

	_ring_material = _flat_ring_material(false)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.0435
	torus.outer_radius = 0.0485
	torus.rings = 48
	torus.material = _ring_material
	ring.mesh = torus
	ring.position.y = 0.0006
	anchor.add_child(ring)
	_style_ring()


func _flat_ring_material(additive: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return mat


func _style_ring() -> void:
	## The hand marker and ring in the live UI theme's colours; re-run when the theme or the effects switch changes.
	var theme: Resource = UiThemes.live()
	_seen_theme_revision = UiThemes.revision
	var accent: Color = theme.accent
	if _marker_material:
		var c: Color = accent.lightened(0.5)
		_marker_material.albedo_color = c
		_marker_material.emission = c
	if _ring_material:
		_ring_material.albedo_color = Color(accent.r, accent.g, accent.b, 0.85)
	if _ring_face_material:
		var panel: Color = theme.bg_panel
		_ring_face_material.albedo_color = Color(panel.r, panel.g, panel.b, 0.28)
	if _ring_glow_material:
		_ring_glow_material.albedo_color = Color(accent.r, accent.g, accent.b, 0.22)
		_ring_glow_node.visible = UiThemes.fx_enabled and theme.fx_button_glow > 0.001


func _add_laser() -> void:
	_laser = MeshInstance3D.new()
	_laser_mesh = CylinderMesh.new()
	_laser_mesh.top_radius = 0.002 # slightly narrower than the original 0.003
	_laser_mesh.bottom_radius = 0.002
	_laser_mesh.height = laser_length
	_laser.mesh = _laser_mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0, 0.5) # white, matching the shrunk origin marker
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
	if _laser != null:
		_laser.visible = not wheel_is_open() # the wheel is driven by hand movement, not aim
	var distance := laser_length
	var ui_distance: float = get_meta("ui_hit_distance", -1.0)
	var longest := laser_length
	if ui_distance >= 0.0:
		distance = ui_distance
		longest = maxf(laser_length, ui_distance) # the monolith can be pressed from 5 m: the laser must reach what it presses
	elif _hover_panel_distance >= 0.0:
		distance = _hover_panel_distance # stops on a window it's aimed at, even a far one
		longest = maxf(laser_length, _hover_panel_distance)
	elif _part_hit_distance >= 0.0:
		distance = _part_hit_distance
	_set_laser_length(clampf(distance, 0.02, longest))


