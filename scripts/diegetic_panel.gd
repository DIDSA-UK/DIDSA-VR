extends Node3D
## Shared mechanism for a free-floating (not wrist-mounted), on-demand
## world-space UI panel: a Control tree in a SubViewport, rendered onto a
## quad, hit-tested by hand against the right hand's laser (no physics
## involved) - extracted from popup_keyboard.gd, which was the first thing
## in this repo built this way (wrist_tablet.gd predates it and still has
## its own copy of the same mechanism, wrist-mounted instead of free-
## floating; this base is deliberately NOT retrofitted onto either of those
## two proven, already-headset-tested files - see docs/status.md's
## "Floating windows" section for why).
##
## Real-headset feedback: these panels opened in front of the camera and
## then just stayed exactly there forever, with no way to move one out of
## the way. A small grab handle at the centre of the panel's lower edge
## (_build_handle()) fixes that: GRIP it with either hand to drag the whole
## panel 1:1, release to let go — self-contained (both controllers'
## grip_click, not routed through controller.gd's own part-grab search),
## since a window handle floats well clear of the assembly in normal use.
##
## Resizing (real-headset request): four corner brackets sit just outside the
## panel's corners. Aim the right laser at one and it highlights (and the laser
## stops on it, like on the panel itself); hold the trigger and drag to resize
## - the OPPOSITE corner stays put. It's a true resize, not a zoom: the
## SubViewport grows with the panel at the same pixels-per-metre, so a bigger
## window shows more content (the Browser gets a bigger page area, the tree
## more rows) and text stays the same physical size.
##
## Subclasses override _build_content() to supply their own UI (a header
## with the panel's title and a close button are added automatically around
## whatever that returns), call setup() last from their own setup_xyz()
## once every field _build_content() might reference is already set, and
## can override _on_opened()/_on_closed() for any refresh-on-open behaviour.
##
## Multiple panels built on this base can be open at once. Each frame, a
## panel claims the right controller's shared "ui_hover"/"ui_hit_distance"
## meta (the same convention wrist_tablet.gd/popup_keyboard.gd already use,
## and controller.gd already reads to know whether the trigger belongs to a
## UI panel instead of a part, and how far to shorten the laser) only if
## nothing has already claimed it THIS frame - so at most one panel ever
## ends up hovered per frame, with no risk of two panels both thinking a
## single trigger pull is "for them". This is first-claim, not nearest-hit:
## among panels added in main.gd's _ready() (assembly tree, then
## calculator, then image viewer, then the wrist tablet, then the popup
## keyboard), whichever one runs first each frame and is genuinely
## geometrically hit wins, even if a later-processed panel is actually
## closer along the same ray - an earlier, cheaper "claim if nearer"
## version of this was dropped after tests/windows_tab.gd caught it letting
## an outbid panel keep believing it was still hovered for the rest of that
## frame (nothing ever told it otherwise), so two panels could both react
## to the same trigger pull at once. This only works because controller.gd
## resets the meta to neutral at the very start of every frame, before any
## panel gets a chance to claim it - see controller.gd's own _process()
## docstring. Correctness (never two panels believing they're both hovered
## at once) matters more here than optimality (always picking the true
## nearest) - each new window's own open_distance/open_lateral_offset is
## chosen so panels don't normally overlap in the first place, so true ray
## overlap between two open windows is an edge case, not the common path.
## The wrist tablet and popup keyboard predate this arbitration entirely
## and always claim unconditionally when they're hovered - an accepted,
## documented gap (not fixed by touching either of those two already-
## proven, headset-tested files) that only matters if one of THEM
## geometrically overlaps a new panel in the same laser path.

@export var panel_size := Vector2(0.26, 0.30) ## metres
@export var viewport_size := Vector2i(460, 560) ## pixels the UI is laid out in
@export var open_distance: float = 0.6 ## metres in front of the camera when opened
@export var open_lateral_offset: float = 0.0 ## metres, +right/-left of straight ahead - lets several windows spawn without stacking exactly on top of each other or the popup keyboard
@export var max_point_distance: float = 2.0 ## metres; laser reach
@export var click_action: String = "trigger_click"
@export var panel_title: String = "Window"
@export var grab_action: String = "grip_click"
@export var min_panel_size := Vector2(0.16, 0.16) ## metres; resize limits
@export var max_panel_size := Vector2(1.6, 1.3)
@export var corner_hit_reach: float = 0.10 ## metres outward from a corner (along both edges) that counts as aiming at it — doubled (was 0.05) after headset testing found the corners fiddly to hit
@export var free_on_close: bool = false ## extra windows spawned on demand (main.gd's spawn_window()) delete themselves when closed; the primary ones just hide
@export var scroll_deadzone: float = 0.5 ## right stick push (0..1) needed to scroll the window's scroll_target while the laser is on it
@export var scroll_speed_px: float = 900.0
@export var handle_grab_reach: float = 0.03 ## metres beyond the handle's own radius - it's small, so a bit of slack makes it easier to catch, same reasoning as controller.gd's own grab_reach

var _left: XRController3D
var _right: XRController3D
var _camera: XRCamera3D
var _handle: MeshInstance3D
var _handle_material: StandardMaterial3D
var _held_by: XRController3D = null ## whichever hand grabbed the handle, or null - see _try_grab_handle()/_release_handle()
var _grab_offset: Transform3D = Transform3D.IDENTITY ## this panel's pose in the holding hand's local frame, captured at grab time

const _CORNER_DIRS: Array[Vector2] = [Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1)] ## top-left, top-right, bottom-left, bottom-right (x, y signs in the panel's local frame)
const _CORNER_INSET := 0.008 ## metres the hit zone reaches back INSIDE the panel edge — just enough to catch an aim on the edge itself without stealing the content's own corner controls (e.g. the close button)
const _CORNER_IDLE := Color(0.82, 0.85, 0.9, 0.55)
const _CORNER_HOT := Color(0.35, 0.85, 1.0, 1.0)

var scroll_target: ScrollContainer = null ## set by a subclass's _build_content(): the right thumbstick scrolls it while the laser is on this window
var _header: HBoxContainer
var _title_label: Label
var _chrome: Array = [] ## header buttons that grow with the window: [{button, min_size, font_size}] — see _apply_chrome_scale()
var _base_width := 0.26 ## panel width when set up: chrome scale is panel_size.x / this
var _last_delta := 0.016
var _last_click_ms := -100000
var _scroll_f := 0.0
var _corners: Array[Node3D] = []
var _corner_materials: Array[StandardMaterial3D] = []
var _hover_corner := -1 ## corner the right laser is on (claims ui_hover like the panel does), or -1
var _resize_corner := -1 ## corner being dragged, or -1
var _pixels_per_metre := 1000.0 ## captured at setup() from the subclass's own panel_size/viewport_size, kept fixed through every resize
var _ui_root: Control

var _viewport: SubViewport
var _quad: MeshInstance3D
var _cursor: Control
var _content_holder: Control

var _open := false
var _hovering := false
var _pointer_px := Vector2.ZERO
var _press_px := Vector2.ZERO ## frozen at trigger-down - see popup_keyboard.gd's _send_click() for the real-headset reason this matters
var _last_sent_px := Vector2(-1, -1)
var _pressed := false


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	_left = left
	_right = right
	_camera = camera
	_pixels_per_metre = float(viewport_size.x) / panel_size.x
	_base_width = panel_size.x
	_build_viewport()
	_build_quad()
	_build_handle()
	_build_corners()
	add_to_group("diegetic_panels") # controller.gd asks every panel via handle_in_reach() before running its own part-grab
	_right.button_pressed.connect(_on_right_pressed)
	_right.button_released.connect(_on_right_released)
	_left.button_pressed.connect(_on_grip_pressed.bind(_left))
	_left.button_released.connect(_on_grip_released.bind(_left))
	_right.button_pressed.connect(_on_grip_pressed.bind(_right))
	_right.button_released.connect(_on_grip_released.bind(_right))
	visible = false


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_place_in_front_of_camera()
	_on_opened()


func close() -> void:
	_open = false
	visible = false
	_hovering = false
	_clear_held()
	_resize_corner = -1
	_set_hover_corner(-1)
	if free_on_close:
		queue_free.call_deferred() # after _on_closed() below has run
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _right:
		_right.set_meta("ui_hover", false)
		_right.set_meta("ui_hit_distance", -1.0) # _process() only runs while open - see popup_keyboard.gd's close() for why this needs doing explicitly too, not just left to next frame's reset
	_on_closed()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func _on_opened() -> void:
	pass # override in a subclass, e.g. to refresh data


func _on_closed() -> void:
	pass # override in a subclass


func _build_content() -> Control:
	return Control.new() # override in a subclass


func _place_in_front_of_camera() -> void:
	if _camera == null:
		return
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	# Yaw-only, same reasoning as popup_keyboard.gd's own _place_in_front_of_camera():
	# stays upright regardless of the camera's current pitch/roll.
	var right_axis := forward.cross(Vector3.UP).normalized()
	var target_position := _camera.global_position + forward * open_distance + right_axis * open_lateral_offset
	target_position.y = _camera.global_position.y - 0.1
	global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), target_position)


func _process(delta: float) -> void:
	_last_delta = delta
	if not _open or _camera == null or _right == null:
		return
	if _held_by:
		# Rigid 1:1 follow, same approach section_tool.gd's own gizmo grab
		# uses - a floating window doesn't need the part-grab path's
		# steadiness filtering, it's not a precision placement task.
		global_transform = _held_by.global_transform * _grab_offset
		return # being dragged by its handle - not also hoverable/clickable at the same time
	if _resize_corner >= 0:
		_update_resize()
		return # being resized - not also hoverable/clickable at the same time
	_update_pointer()
	_scroll_with_stick(delta)


func _scroll_with_stick(delta: float) -> void:
	## Right thumbstick Y scrolls this window's scroll_target while the laser is
	## on the window (push down = scroll down) — the same control the wrist
	## tablet has. locomotion.gd/controller.gd already stand the stick down
	## while a panel owns the laser ("ui_hover"). Not while a click is held or
	## just after one, or a resting thumb would slide rows out from under it.
	if not _hovering or scroll_target == null or not is_instance_valid(scroll_target) or not scroll_target.is_visible_in_tree():
		return
	if _pressed or Time.get_ticks_msec() - _last_click_ms < 400:
		_scroll_f = float(scroll_target.scroll_vertical)
		return
	var stick_y: float = _right.get_vector2("primary").y
	scroll_by_stick(stick_y, delta)


func scroll_by_stick(stick_y: float, delta: float) -> void:
	## Split out so tests can drive it without a real XR runtime.
	if scroll_target == null:
		return
	if absf(stick_y) < scroll_deadzone:
		_scroll_f = float(scroll_target.scroll_vertical)
		return
	_scroll_f = maxf(_scroll_f - stick_y * scroll_speed_px * delta, 0.0)
	scroll_target.scroll_vertical = int(_scroll_f)
	if float(scroll_target.scroll_vertical) < _scroll_f - 1.0:
		_scroll_f = float(scroll_target.scroll_vertical) # clamped at the bottom


func _update_pointer() -> void:
	var was_hovering := _hovering
	_hovering = false
	var normal := global_transform.basis.z.normalized()
	var origin := _right.global_position
	var dir := -_right.global_transform.basis.z.normalized()
	var geometrically_hit := false
	var hit_distance := -1.0
	var local_hit_px := Vector2.ZERO
	var corner := -1
	var corner_distance := -1.0

	var hit = Plane(normal, global_position).intersects_ray(origin, dir)
	if hit != null and origin.distance_to(hit) <= max_point_distance:
		var local: Vector3 = global_transform.affine_inverse() * hit
		if absf(local.x) <= panel_size.x * 0.5 and absf(local.y) <= panel_size.y * 0.5:
			geometrically_hit = true
			hit_distance = origin.distance_to(hit)
			local_hit_px = Vector2(
				(local.x / panel_size.x + 0.5) * _viewport.size.x,
				(0.5 - local.y / panel_size.y) * _viewport.size.y
			)
		elif not _pressed:
			corner = _corner_at(Vector2(local.x, local.y))
			corner_distance = origin.distance_to(hit)

	# A corner is hovered only when nothing else has claimed the laser this frame.
	var claimed: bool = _right.get_meta("ui_hover", false)
	if corner >= 0 and not claimed:
		_right.set_meta("ui_hover", true)
		_right.set_meta("ui_hit_distance", corner_distance)
	else:
		corner = -1
	_set_hover_corner(corner)

	# Claim only if nothing has already claimed the shared meta THIS frame -
	# see this class's own top docstring for why this is first-claim, not
	# nearest-hit, and why that's the right trade-off here.
	if geometrically_hit and not _right.get_meta("ui_hover", false):
		_hovering = true
		if not _pressed:
			_pointer_px = local_hit_px
		_right.set_meta("ui_hover", true)
		_right.set_meta("ui_hit_distance", hit_distance)

	_cursor.visible = _hovering
	if _hovering:
		_cursor.position = _pointer_px - _cursor.size * 0.5
		if not _pressed and _pointer_px != _last_sent_px:
			var motion := InputEventMouseMotion.new()
			motion.position = _pointer_px
			motion.global_position = _pointer_px
			motion.relative = _pointer_px - (_last_sent_px if was_hovering else _pointer_px)
			_viewport.push_input(motion)
			_last_sent_px = _pointer_px
	elif was_hovering and _pressed:
		_send_click(false) # lost hover (laser moved off, or another panel won this frame): let go so nothing stays stuck down


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _hover_corner >= 0 and not _hovering and _open and _held_by == null:
		_resize_corner = _hover_corner
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)
		return
	if action_name == click_action and _hovering:
		_press_px = _pointer_px
		_send_click(true)
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and _resize_corner >= 0:
		_end_resize()
		return
	if action_name == click_action and _pressed:
		_send_click(false)


func _send_click(down: bool) -> void:
	## Uses _press_px (frozen at press time), not the live _pointer_px, for
	## both down and up - see popup_keyboard.gd's own _send_click() for the
	## full real-headset reasoning this mirrors exactly.
	_pressed = down
	_last_click_ms = Time.get_ticks_msec()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	click.position = _press_px
	click.global_position = _press_px
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	_viewport.push_input(click)


func handle_in_reach(hand: Node3D) -> bool:
	## True if this open panel's drag handle is within this hand's grab reach.
	## controller.gd's _try_grab() asks every panel first (its own grip handler
	## runs before this one's), so a grip aimed at a window never also grabs a
	## part or the section gizmo.
	if not _open or _handle == null or not visible:
		return false
	var reach: float = (_handle.mesh as CapsuleMesh).radius + handle_grab_reach
	return hand.global_position.distance_to(_handle.global_position) <= reach


func _on_grip_pressed(action_name: String, hand: XRController3D) -> void:
	## These windows aren't wrist- or camera-attached - once placed in front
	## of you on open, they stay exactly there until dragged by this handle.
	## Grabbing sets a "window_held" meta on the hand (same convention as
	## section_tool.gd's "section_gizmo_held") so two_hand_model.gd's
	## _hand_free() doesn't also drag the whole model with the same grip press
	## - real-headset feedback: grabbing a window moved the world too.
	if action_name != grab_action or not _open or _held_by != null:
		return
	if handle_in_reach(hand):
		_held_by = hand
		hand.set_meta("window_held", true)
		_grab_offset = hand.global_transform.affine_inverse() * global_transform
		_handle_material.albedo_color = Color(1.0, 1.0, 1.0)
		hand.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_grip_released(action_name: String, hand: XRController3D) -> void:
	if action_name == grab_action and _held_by == hand:
		_clear_held()


func _clear_held() -> void:
	## Shared by release and close(): a window closed mid-grab must not leave
	## that hand's meta stuck true, permanently blocking whole-model drags.
	if _held_by != null and is_instance_valid(_held_by):
		_held_by.set_meta("window_held", false)
	_held_by = null
	if _handle_material:
		_handle_material.albedo_color = Color(0.82, 0.85, 0.9)


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while open
	add_child(_viewport)
	_ui_root = _build_root_ui()
	_viewport.add_child(_ui_root)


func _build_quad() -> void:
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = panel_size
	_quad.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	add_child(_quad)


## A small grab handle at the centre of the panel's lower edge, the common
## "drag this to move the window" affordance most VR UI toolkits use (Quest
## home/system panels included) - these windows otherwise just sit exactly
## where they opened forever (_place_in_front_of_camera(), once, on open),
## with no other way to reposition one. A thin white horizontal pill,
## matching this session's own white-line visual language (floor grid,
## wrist tablet icon, controller button discs) rather than a bespoke look.
func _build_handle() -> void:
	_handle = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.008
	capsule.height = 0.05
	_handle_material = StandardMaterial3D.new()
	_handle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_handle_material.emission_enabled = true
	_handle_material.emission = Color(0.82, 0.85, 0.9)
	_handle_material.albedo_color = Color(0.82, 0.85, 0.9)
	capsule.material = _handle_material
	_handle.mesh = capsule
	# Capsule's long axis is local Y by default; rotate 90 about Z so it lies
	# horizontal, spanning the panel's own lower edge left-to-right.
	_handle.rotation_degrees.z = 90.0
	add_child(_handle)
	_layout_handle()


func _layout_handle() -> void:
	if _handle:
		_handle.position = Vector3(0.0, -panel_size.y * 0.5 - 0.02, 0.01)


## Four L-shaped brackets just OUTSIDE the panel's corners (so they never sit
## on top of the content's own controls): dim at rest, bright cyan and a
## little larger while the laser is on one or it's being dragged.
func _build_corners() -> void:
	var length := 0.07 # doubled with the hit zone: the bracket is what you aim at
	var thickness := 0.010
	for i in _CORNER_DIRS.size():
		var dir := _CORNER_DIRS[i]
		var holder := Node3D.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = _CORNER_IDLE
		mat.no_depth_test = false
		var arms := [
			{"size": Vector3(length, thickness, 0.004), "pos": Vector3(-dir.x * (length * 0.5 - thickness * 0.5), 0.0, 0.0)},
			{"size": Vector3(thickness, length, 0.004), "pos": Vector3(0.0, -dir.y * (length * 0.5 - thickness * 0.5), 0.0)},
		]
		for arm in arms:
			var box := BoxMesh.new()
			box.size = arm["size"]
			box.material = mat
			var instance := MeshInstance3D.new()
			instance.mesh = box
			instance.position = arm["pos"]
			holder.add_child(instance)
		add_child(holder)
		_corners.append(holder)
		_corner_materials.append(mat)
	_layout_corners()


func _layout_corners() -> void:
	for i in _corners.size():
		var dir := _CORNER_DIRS[i]
		_corners[i].position = Vector3(dir.x * (panel_size.x * 0.5 + 0.003), dir.y * (panel_size.y * 0.5 + 0.003), 0.006)


func _corner_at(p: Vector2) -> int:
	## Which corner's outward hit zone (a corner_hit_reach square reaching
	## _CORNER_INSET back inside the edge) `p` (panel-local metres) is in;
	## -1 if none. Nearest wins if zones overlap on a tiny panel.
	var best := -1
	var best_distance := INF
	for i in _CORNER_DIRS.size():
		var dir := _CORNER_DIRS[i]
		var corner := Vector2(dir.x * panel_size.x * 0.5, dir.y * panel_size.y * 0.5)
		var rel := (p - corner) * dir # outward-positive along both axes
		if rel.x >= -_CORNER_INSET and rel.x <= corner_hit_reach and rel.y >= -_CORNER_INSET and rel.y <= corner_hit_reach:
			var d := rel.length()
			if d < best_distance:
				best_distance = d
				best = i
	return best


func _set_hover_corner(index: int) -> void:
	if index == _hover_corner:
		return
	_hover_corner = index
	_refresh_corner_look()


func _refresh_corner_look() -> void:
	for i in _corners.size():
		var hot := i == _hover_corner or i == _resize_corner
		_corner_materials[i].albedo_color = _CORNER_HOT if hot else _CORNER_IDLE
		_corners[i].scale = Vector3.ONE * (1.4 if hot else 1.0)


func _update_resize() -> void:
	## Drags the grabbed corner to wherever the laser meets the panel's plane,
	## the opposite corner held fixed: the new size is the distance from that
	## fixed corner (clamped to min/max), and the panel's centre — its origin —
	## moves to the middle of the new rectangle. Everything is recomputed from
	## the CURRENT pose each frame, so it self-corrects however the aim jitters.
	var normal := global_transform.basis.z.normalized()
	var hit = Plane(normal, global_position).intersects_ray(_right.global_position, -_right.global_transform.basis.z.normalized())
	_right.set_meta("ui_hover", true) # the trigger and stick belong to this drag until it ends
	_right.set_meta("ui_hit_distance", _right.global_position.distance_to(hit) if hit != null else -1.0)
	if hit == null:
		return
	var local: Vector3 = global_transform.affine_inverse() * hit
	var dir := _CORNER_DIRS[_resize_corner]
	var fixed := Vector2(-dir.x * panel_size.x * 0.5, -dir.y * panel_size.y * 0.5)
	var wanted := Vector2((local.x - fixed.x) * dir.x, (local.y - fixed.y) * dir.y)
	var new_size := wanted.clamp(min_panel_size, max_panel_size)
	var dragged := fixed + Vector2(dir.x * new_size.x, dir.y * new_size.y)
	var centre := (fixed + dragged) * 0.5
	global_position += global_transform.basis * Vector3(centre.x, centre.y, 0.0)
	_apply_panel_size(new_size, false)


func _end_resize() -> void:
	_resize_corner = -1
	_apply_panel_size(panel_size, true) # settle the SubViewport on the exact final pixel size
	_refresh_corner_look()


func _apply_panel_size(new_size: Vector2, force_viewport: bool) -> void:
	## Keeps pixels-per-metre fixed: the SubViewport (and so the UI layout) grows
	## with the panel. The render target is only re-allocated once the size has
	## moved a few pixels (or on release), not every frame of a drag.
	panel_size = new_size
	var wanted_px := Vector2i((new_size * _pixels_per_metre).round())
	if force_viewport or absi(wanted_px.x - _viewport.size.x) >= 4 or absi(wanted_px.y - _viewport.size.y) >= 4:
		viewport_size = wanted_px
		_viewport.size = wanted_px
		_ui_root.size = Vector2(wanted_px)
	(_quad.mesh as QuadMesh).size = new_size
	_layout_handle()
	_layout_corners()
	_apply_chrome_scale()


func _register_chrome(button: Button, min_size: Vector2, font_size: int) -> void:
	_chrome.append({"button": button, "min_size": min_size, "font_size": font_size})
	_apply_chrome_scale()


func add_header_button(text: String, callback: Callable, at_start: bool = true) -> Button:
	## A window-specific button in the header (the Image Viewer's Back). It's
	## sized like the close button and grows with the window the same way.
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	_header.add_child(button)
	if at_start:
		_header.move_child(button, 0)
	_register_chrome(button, Vector2(64, 64), 34)
	return button


func set_title(text: String) -> void:
	if _title_label:
		_title_label.text = text


func chrome_scale() -> float:
	## How much bigger than its opening size the window is (1 at opening,
	## capped at 3): the header buttons scale by this, so a big window gets big
	## close/back buttons instead of the same small ones.
	return clampf(panel_size.x / _base_width, 1.0, 3.0)


var _applied_chrome_scale := -1.0

func _apply_chrome_scale() -> void:
	var scale := chrome_scale()
	if absf(scale - _applied_chrome_scale) < 0.02:
		return # a drag resizes every frame: only touch the theme when the scale has actually moved
	_applied_chrome_scale = scale
	for entry in _chrome:
		var button: Button = entry["button"]
		if is_instance_valid(button):
			button.custom_minimum_size = (entry["min_size"] as Vector2) * scale
			button.add_theme_font_size_override("font_size", int(roundf(float(entry["font_size"]) * scale)))
	if _title_label:
		_title_label.add_theme_font_size_override("font_size", int(roundf(30.0 * sqrt(scale)))) # the title grows too, more gently


func _build_root_ui() -> Control:
	var theme := Theme.new()
	theme.default_font_size = 26
	# Same pressed-state fix wrist_tablet.gd's own theme applies, for the
	# same real-headset reason (Godot's own default fallback doesn't read at
	# arm's length on an unshaded SubViewport quad) - see that file's
	# _build_ui() docstring.
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = Color(0.15, 0.55, 0.68)
	pressed_style.set_corner_radius_all(4)
	pressed_style.set_content_margin_all(6)
	theme.set_stylebox("pressed", "Button", pressed_style)
	theme.set_stylebox("hover_pressed", "Button", pressed_style)

	var root := Control.new()
	root.theme = theme
	root.size = Vector2(viewport_size)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.1, 0.13)
	bg.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", bg)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	_header = header
	var title := Label.new()
	title.text = panel_title
	title.add_theme_font_size_override("font_size", 30)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	header.add_child(title)
	_title_label = title
	# The close button is big to begin with and GROWS with the window (see
	# _apply_chrome_scale()) so it stays easy to hit on a large window.
	var close_button := Button.new()
	close_button.text = "X"
	close_button.pressed.connect(close)
	header.add_child(close_button)
	_register_chrome(close_button, Vector2(64, 64), 34)

	_content_holder = VBoxContainer.new()
	_content_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_content_holder)
	# The content must EXPAND to fill the holder: a BoxContainer child without
	# an expand flag only gets its own minimum size, so a subclass's inner
	# SIZE_EXPAND_FILL ScrollContainer (the Assembly Tree's row list) collapsed
	# to ~0 px tall and its rows were never visible — real-headset report
	# "nothing ever populates in the tree".
	var content := _build_content()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_holder.add_child(content)

	# A soft glow where the laser terminates - same convention as
	# wrist_tablet.gd/popup_keyboard.gd's own cursor, for the same real-
	# headset reason (see either's docstring).
	_cursor = Control.new()
	_cursor.size = Vector2(28, 28)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.draw.connect(func() -> void:
		var centre: Vector2 = _cursor.size * 0.5
		for i in range(6, 0, -1):
			_cursor.draw_circle(centre, float(i) * 2.0, Color(1.0, 0.85, 0.1, 0.06))
		_cursor.draw_circle(centre, 5.0, Color(1.0, 0.95, 0.7, 0.9))
	)
	root.add_child(_cursor)

	return root
