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
##
## Phase 3 of the UI redesign (docs/wrist-tablet-redesign-plan.md): the laser ->
## SubViewport handling now lives in scripts/ui/laser_surface.gd (shared with the
## redesigned tablet and the popup keyboard; every real-headset fix described above
## is still in force there, unchanged) and the drag handle in scripts/ui/panel_handle.gd
## (shared with the popup keyboard). This class keeps what is specific to a window:
## resize corners, header chrome and the content hook. Its look comes from the UI
## theme resource (ui/didsa_ui_theme.tres), the same one the tablet uses.

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

const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const LaserSurface := preload("res://scripts/ui/laser_surface.gd")
const PanelHandle := preload("res://scripts/ui/panel_handle.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"
const _CORNER_DIRS: Array[Vector2] = [Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1)] ## top-left, top-right, bottom-left, bottom-right (x, y signs in the panel's local frame)
const _CORNER_INSET := 0.008 ## metres the hit zone reaches back INSIDE the panel edge — just enough to catch an aim on the edge itself without stealing the content's own corner controls (e.g. the close button)

var _left: XRController3D
var _right: XRController3D
var _camera: XRCamera3D
var tokens: Resource ## ui/didsa_ui_theme.tres
var surface ## LaserSurface: hover, claim, frozen press, stick scroll
var handle ## PanelHandle: the grab pill at the lower edge
var _handle: MeshInstance3D: ## the handle's mesh (tests and callers poke at it)
	get: return handle.node if handle else null
var _held_by: XRController3D: ## whichever hand is carrying the panel by its handle, or null
	get: return handle.held_by if handle else null
var _hovering: bool: ## the right laser is on this window's content, and nothing else claimed it first this frame
	get: return surface != null and surface.hovering
var _pressed: bool:
	get: return surface != null and surface.pressed
var _pointer_px: Vector2:
	get: return surface.pointer_px if surface else Vector2.ZERO
var _corner_idle := Color(0.82, 0.85, 0.9, 0.55) ## set from the theme in setup()
var _corner_hot := Color(0.35, 0.85, 1.0, 1.0)

var scroll_target: ScrollContainer = null ## set by a subclass's _build_content(): the right thumbstick scrolls it while the laser is on this window
var _header: HBoxContainer
var _title_label: Label
var _chrome: Array = [] ## header buttons that grow with the window: [{button, min_size, font_size}] — see _apply_chrome_scale()
var _base_width := 0.26 ## panel width when set up: chrome scale is panel_size.x / this
var _last_delta := 0.016
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


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	_left = left
	_right = right
	_camera = camera
	tokens = load(THEME_PATH)
	_corner_idle = tokens.border.lightened(0.3)
	_corner_idle.a = 0.55
	_corner_hot = tokens.accent
	_pixels_per_metre = float(viewport_size.x) / panel_size.x
	_base_width = panel_size.x
	_build_viewport()
	_build_quad()
	surface = LaserSurface.new()
	surface.setup(self, _viewport, _right, panel_size)
	surface.claim_first = true
	surface.cursor = _cursor
	handle = PanelHandle.new()
	handle.setup(self, _left, _right, func() -> bool: return _open, tokens)
	handle.grab_action = grab_action
	handle.reach_slack = handle_grab_reach
	handle.build(panel_size)
	_build_corners()
	add_to_group("diegetic_panels") # controller.gd asks every panel via handle_in_reach() before running its own part-grab
	_right.button_pressed.connect(_on_right_pressed)
	_right.button_released.connect(_on_right_released)
	visible = false


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_place_in_front_of_camera()
	_on_opened()
	UiFeedback.play("open", self)


func close() -> void:
	_open = false
	visible = false
	if surface:
		surface.release_all()
	if handle:
		handle.clear()
	_resize_corner = -1
	_set_hover_corner(-1)
	if free_on_close:
		queue_free.call_deferred() # after _on_closed() below has run
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _right:
		_right.set_meta("ui_hover", false)
		_right.set_meta("ui_hit_distance", -1.0) # _process() only runs while open - see popup_keyboard.gd's close() for why this needs doing explicitly too, not just left to next frame's reset
	_on_closed()
	UiFeedback.play("close", self)


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
	if handle.follow():
		surface.release_all() # being dragged by its handle - not also hoverable/clickable (and no stale hover left over to click with)
		return
	if _resize_corner >= 0:
		_update_resize()
		return # being resized - not also hoverable/clickable at the same time
	_update_pointer()


func scroll_by_stick(stick_y: float, delta: float) -> void:
	## Right thumbstick Y scrolls this window's scroll_target while the laser is on
	## the window (push down = scroll down) — the same control the wrist tablet has.
	## The per-frame call is LaserSurface's; this stays public so tests can drive it
	## without a real XR runtime.
	surface.scroll_target = scroll_target
	surface.scroll_speed_px = scroll_speed_px
	surface.scroll_deadzone = scroll_deadzone
	surface.scroll_by_stick(stick_y, delta)


func _update_pointer() -> void:
	# The laser on the window's content: hover, the claim, the frozen press and the
	# stick scroll are all LaserSurface's.
	surface.panel_size = panel_size
	surface.max_point_distance = max_point_distance
	surface.click_action = click_action
	surface.scroll_target = scroll_target
	surface.scroll_speed_px = scroll_speed_px
	surface.scroll_deadzone = scroll_deadzone
	surface.process(_last_delta, true)

	# Resize corners: the laser just OUTSIDE the panel, on a corner bracket. A corner
	# is hovered only when nothing else (including this window's own content) has
	# claimed the laser this frame.
	var corner := -1
	var corner_distance := -1.0
	if not surface.hovering and not surface.pressed:
		var origin := _right.global_position
		var hit = Plane(global_transform.basis.z.normalized(), global_position).intersects_ray(origin, -_right.global_transform.basis.z.normalized())
		if hit != null and origin.distance_to(hit) <= max_point_distance:
			var local: Vector3 = global_transform.affine_inverse() * hit
			if absf(local.x) > panel_size.x * 0.5 or absf(local.y) > panel_size.y * 0.5:
				corner = _corner_at(Vector2(local.x, local.y))
				corner_distance = origin.distance_to(hit)
	var claimed: bool = _right.get_meta("ui_hover", false)
	if corner >= 0 and not claimed:
		_right.set_meta("ui_hover", true)
		_right.set_meta("ui_hit_distance", corner_distance)
	else:
		corner = -1
	_set_hover_corner(corner)


func _on_right_pressed(action_name: String) -> void:
	# Content clicks are LaserSurface's; only a press on a resize corner is ours.
	if action_name == click_action and _hover_corner >= 0 and not surface.hovering and _open and handle.held_by == null:
		_resize_corner = _hover_corner
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and _resize_corner >= 0:
		_end_resize()


func handle_in_reach(hand: Node3D) -> bool:
	## True if this open panel's drag handle is within this hand's grab reach.
	## controller.gd's _try_grab() asks every panel first (its own grip handler
	## runs before the handle's), so a grip aimed at a window never also grabs a
	## part or the section gizmo.
	return handle != null and handle.in_reach(hand)


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


## Four L-shaped brackets just OUTSIDE the panel's corners (so they never sit
## on top of the content's own controls): dim at rest, bright accent and a
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
		mat.albedo_color = _corner_idle
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
		_corner_materials[i].albedo_color = _corner_hot if hot else _corner_idle
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
	if surface:
		surface.panel_size = new_size
	handle.layout(new_size)
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
			if button.icon != null:
				button.add_theme_constant_override("icon_max_width", mini(int(roundf(34.0 * scale)), 64)) # the glyph is rasterised at 64 px: don't stretch it past that
	if _title_label:
		_title_label.add_theme_font_size_override("font_size", int(roundf(float(tokens.font_title) * sqrt(scale)))) # the title grows too, more gently


func _build_root_ui() -> Control:
	var root := Control.new()
	root.theme = tokens.build_theme() # the same theme resource the tablet uses: panel chrome, buttons, labels, sliders
	root.theme.default_font_size = 26 # windows have always used a slightly larger body size than the tablet
	root.size = Vector2(viewport_size)

	var panel := PanelContainer.new() # drawn with the theme's panel chrome (rounded, outlined)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap + 2)
	panel.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", tokens.gap)
	column.add_child(header)
	_header = header
	var title := Label.new()
	title.text = panel_title
	title.theme_type_variation = &"LabelTitle"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	header.add_child(title)
	_title_label = title
	# The close button is big to begin with and GROWS with the window (see
	# _apply_chrome_scale()) so it stays easy to hit on a large window.
	var close_button := Button.new()
	close_button.icon = UiIcons.texture("close", 64)
	close_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close_button.expand_icon = false
	close_button.theme_type_variation = &"ButtonDanger"
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

	# A soft glow where the laser terminates (see laser_surface.gd's make_cursor()).
	_cursor = LaserSurface.make_cursor()
	root.add_child(_cursor)

	return root
