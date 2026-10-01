extends RefCounted
## The right hand's laser -> a 2D UI in a SubViewport, shared by every flat UI
## that floats in the world. This is the logic wrist_tablet.gd perfected over
## several real-headset rounds, lifted out so the new tablet (and, in Phase 3,
## the floating windows and the popup keyboard) stop carrying private copies.
## It does NOT own a viewport, a quad or any layout: the host builds those and
## calls process() every frame. Nothing here knows about tablets or tools.
##
## No physics: the laser ray is intersected with the host's plane by hand and the
## hit turned into mouse events pushed into the SubViewport.
##
## Every behaviour below exists because of a real headset bug — see
## docs/status.md "Tablet/keyboard buttons: hover worked, activating never did":
##  * FROZEN PRESS. While the trigger is held the pointer stops following the aim.
##    A real squeeze takes 100-300 ms and a hand drifts a few mm; Godot's BaseButton
##    cancels a press when ANY motion event lands outside its rect, whatever the
##    eventual release event carries. Both the down and the up event use the
##    position the trigger went down at. (Exception: a press that starts on a
##    registered Slider keeps tracking the aim — a slider has to be dragged — and
##    releases wherever the laser got to.)
##  * EDGE SLACK. While pressed the panel edge is forgiving (3 cm): a trigger squeeze
##    tilts the controller a few degrees, and losing hover mid-press used to let go
##    of the button and let the laser run through the panel.
##  * LET GO ON LEAVE. If hover is lost mid-press (laser slid off, or another panel
##    won the claim) a release is sent so nothing stays stuck down.
##  * SETTLE. Presses are ignored for settle_seconds after arm(): the laser is still
##    resting where the thing that opened this panel was.
##  * CLAIM PROTOCOL. The right controller's "ui_hover" / "ui_hit_distance" meta tell
##    controller.gd not to laser-select a part, locomotion.gd not to teleport, and the
##    laser how far to draw. controller.gd resets them at the start of every frame
##    (process_priority -1000). With claim_first = true (what new panels should use)
##    a surface only claims if nothing already has this frame and never writes
##    "false" — the same first-claim arbitration diegetic_panel.gd documents.
##    claim_first = false is the old wrist tablet / keyboard behaviour, which
##    overwrites unconditionally.
##  * STICK SCROLL. While the laser is on the surface the right thumbstick scrolls
##    scroll_target (push down = scroll down), with a deadzone and a lockout while a
##    click is held or just released, so a resting thumb can't slide rows away.

signal pressed_changed(down: bool)

var host: Node3D ## whose +Z-facing plane is the surface (quad faces +Z)
var viewport: SubViewport
var right: XRController3D
var panel_size := Vector2(0.3, 0.2) ## metres; host updates this if it resizes
var max_point_distance := 2.0
var click_action := "trigger_click"
var claim_first := true
var settle_seconds := 0.0
var press_slack := 0.03
var cursor: Control = null ## optional glow dot, lives in the viewport; positioned for you
var scroll_target: ScrollContainer = null
var scroll_speed_px := 900.0
var scroll_deadzone := 0.5
var scroll_click_lockout_ms := 400
var haptics := true

var hovering := false
var pressed := false
var pointer_px := Vector2.ZERO
var hit_distance := -1.0 ## metres to the surface this frame, or -1

var _press_px := Vector2.ZERO
var _last_sent_px := Vector2(-1, -1)
var _last_click_ms := -100000
var _armed_at_ms := -100000
var _drag_slider := false
var _sliders: Array = []
var _scroll_f := 0.0


func setup(p_host: Node3D, p_viewport: SubViewport, p_right: XRController3D, p_panel_size: Vector2) -> void:
	host = p_host
	viewport = p_viewport
	right = p_right
	panel_size = p_panel_size
	right.button_pressed.connect(_on_right_pressed)
	right.button_released.connect(_on_right_released)


func add_slider(slider: Slider) -> void:
	## A press that starts on a registered slider keeps tracking the laser.
	_sliders.append(slider)


func arm() -> void:
	## Call when the host opens: starts the settle window.
	_armed_at_ms = Time.get_ticks_msec()


func viewport_px_per_metre() -> Vector2:
	return Vector2(viewport.size) / panel_size


func process(delta: float, active: bool = true) -> void:
	var was_hovering := hovering
	hovering = false
	hit_distance = -1.0
	var geometrically_hit := false
	var local_px := Vector2.ZERO

	if active and host != null and right != null:
		var origin := right.global_position
		var dir := -right.global_transform.basis.z.normalized()
		var normal := host.global_transform.basis.z.normalized()
		var hit = Plane(normal, host.global_position).intersects_ray(origin, dir)
		if hit != null and origin.distance_to(hit) <= max_point_distance:
			var local: Vector3 = host.global_transform.affine_inverse() * hit
			var slack := press_slack if pressed else 0.0
			if absf(local.x) <= panel_size.x * 0.5 + slack and absf(local.y) <= panel_size.y * 0.5 + slack:
				geometrically_hit = true
				hit_distance = origin.distance_to(hit)
				local_px = Vector2(
					(local.x / panel_size.x + 0.5) * viewport.size.x,
					(0.5 - local.y / panel_size.y) * viewport.size.y
				)

	if geometrically_hit:
		if claim_first:
			if not right.get_meta("ui_hover", false):
				hovering = true
				right.set_meta("ui_hover", true)
				right.set_meta("ui_hit_distance", hit_distance)
		else:
			hovering = true
			right.set_meta("ui_hover", true)
			right.set_meta("ui_hit_distance", hit_distance)
	if not hovering:
		hit_distance = -1.0
		if not claim_first and right != null:
			right.set_meta("ui_hover", false)
			right.set_meta("ui_hit_distance", -1.0)

	if hovering and (not pressed or _drag_slider):
		pointer_px = local_px

	if cursor != null:
		cursor.visible = hovering
	if hovering:
		if cursor != null:
			cursor.position = pointer_px - cursor.size * 0.5
		if (not pressed or _drag_slider) and pointer_px != _last_sent_px:
			var motion := InputEventMouseMotion.new()
			motion.position = pointer_px
			motion.global_position = pointer_px
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			motion.relative = pointer_px - (_last_sent_px if was_hovering else pointer_px)
			viewport.push_input(motion)
			_last_sent_px = pointer_px
		_scroll_with_stick(delta)
	elif was_hovering and pressed:
		_send_click(false)


func release_all() -> void:
	## Host closing or hiding: let go of anything held and drop the claim if we hold it.
	if pressed:
		_send_click(false)
	if hovering and right != null:
		right.set_meta("ui_hover", false)
		right.set_meta("ui_hit_distance", -1.0)
	hovering = false
	if cursor != null:
		cursor.visible = false


func _on_right_pressed(action_name: String) -> void:
	if action_name != click_action or not hovering:
		return
	if (Time.get_ticks_msec() - _armed_at_ms) < settle_seconds * 1000.0:
		return
	_press_px = pointer_px
	_drag_slider = _slider_at(_press_px)
	_send_click(true)
	if haptics:
		right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and pressed:
		_send_click(false)


func _send_click(down: bool) -> void:
	pressed = down
	_last_click_ms = Time.get_ticks_msec()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	# A slider drag is released wherever the laser has got to; every other press
	# releases at its frozen press point.
	var at := pointer_px if (_drag_slider and not down) else _press_px
	click.position = at
	click.global_position = at
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	viewport.push_input(click)
	if not down:
		_drag_slider = false
	pressed_changed.emit(down)


func _slider_at(px: Vector2) -> bool:
	for slider in _sliders:
		if is_instance_valid(slider) and slider.is_visible_in_tree() and Rect2(slider.global_position, slider.size).has_point(px):
			return true
	return false


func _scroll_with_stick(delta: float) -> void:
	if scroll_target == null or not is_instance_valid(scroll_target) or not scroll_target.is_visible_in_tree():
		return
	if pressed or Time.get_ticks_msec() - _last_click_ms < scroll_click_lockout_ms:
		_scroll_f = float(scroll_target.scroll_vertical)
		return # mid-click: the page must not move under the frozen press point
	scroll_by_stick(right.get_vector2("primary").y, delta)


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
		_scroll_f = float(scroll_target.scroll_vertical) # clamped at the bottom: don't keep accumulating


static func make_cursor() -> Control:
	## The soft glow showing where the laser lands: concentric fading rings read
	## as a glow at arm's length better than one flat-alpha circle.
	var c := Control.new()
	c.size = Vector2(28, 28)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.visible = false
	c.draw.connect(func() -> void:
		var centre: Vector2 = c.size * 0.5
		for i in range(6, 0, -1):
			c.draw_circle(centre, float(i) * 2.0, Color(1.0, 0.85, 0.1, 0.06))
		c.draw_circle(centre, 5.0, Color(1.0, 0.95, 0.7, 0.9))
	)
	return c
