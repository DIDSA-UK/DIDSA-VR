extends SceneTree
## The shared laser -> SubViewport pointer (scripts/ui/laser_surface.gd) on its own,
## with a fake host and a bare right controller — the behaviours wrist_tablet.gd
## learned from real headsets, checked once for every panel that will use it:
## hover + claim protocol, FROZEN press (a click survives mid-press aim drift),
## edge slack while pressed, slider drag, let-go-on-leave, settle window,
## first-claim arbitration, stick scroll.
## Run: "$GODOT" --headless --path . --script res://tests/laser_surface.gd  (see tests/README.md)

const Surface := preload("res://scripts/ui/laser_surface.gd")
var r: XRController3D
var host: Node3D
var surf
var button: Button
var slider: HSlider
var scroll: ScrollContainer
var clicks := [0]
const PANEL := Vector2(0.4, 0.3)
const PX := Vector2i(400, 300) # 1000 px per metre

func aim_at_px(p: Vector2) -> void:
	# host sits at (0, 1.5, -1) facing +Z; the controller points down -Z from z=0
	r.position = Vector3((p.x / PX.x - 0.5) * PANEL.x, 1.5 + (0.5 - p.y / PX.y) * PANEL.y, 0.0)

func frames(n: int = 2) -> void:
	for i in n:
		await process_frame
		if surf.claim_first: # controller.gd resets the claim at the start of every real frame
			r.set_meta("ui_hover", false); r.set_meta("ui_hit_distance", -1.0)
		surf.process(0.016, true)

func click(down: bool) -> void:
	if down: r.button_pressed.emit("trigger_click")
	else: r.button_released.emit("trigger_click")

func _initialize() -> void:
	var world := Node3D.new(); root.add_child(world)
	r = XRController3D.new(); r.tracker = &"right_hand"; world.add_child(r)
	host = Node3D.new(); world.add_child(host); host.position = Vector3(0, 1.5, -1)
	var vp := SubViewport.new(); vp.size = PX; vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS; world.add_child(vp)
	var ui := Control.new(); ui.size = Vector2(PX); vp.add_child(ui)
	button = Button.new(); button.position = Vector2(100, 40); button.size = Vector2(200, 100); ui.add_child(button)
	button.pressed.connect(func() -> void: clicks[0] += 1)
	slider = HSlider.new(); slider.position = Vector2(20, 160); slider.size = Vector2(360, 40)
	slider.min_value = 0; slider.max_value = 100; slider.step = 1; slider.scrollable = false; slider.value = 50; ui.add_child(slider)
	scroll = ScrollContainer.new(); scroll.position = Vector2(20, 210); scroll.size = Vector2(360, 80); ui.add_child(scroll)
	var tall := Control.new(); tall.custom_minimum_size = Vector2(300, 1000); scroll.add_child(tall)
	var cursor = Surface.make_cursor(); ui.add_child(cursor)

	surf = Surface.new()
	surf.setup(host, vp, r, PANEL)
	surf.cursor = cursor
	surf.add_slider(slider)
	surf.scroll_target = scroll
	await process_frame
	await process_frame

	# --- hover + claim protocol
	r.set_meta("ui_hover", false); r.set_meta("ui_hit_distance", -1.0)
	aim_at_px(Vector2(200, 90))
	await frames()
	print("SMOKE aiming at the panel hovers it: ", surf.hovering)
	print("SMOKE ...and claims ui_hover with the distance (1 m): ", r.get_meta("ui_hover") == true and absf(float(r.get_meta("ui_hit_distance")) - 1.0) < 0.01)
	print("SMOKE ...and the cursor glow follows the aim: ", cursor.visible and cursor.position.distance_to(Vector2(200, 90) - cursor.size * 0.5) < 1.0)
	r.set_meta("ui_hover", false); r.set_meta("ui_hit_distance", -1.0)
	r.position = Vector3(1.0, 1.5, 0.0) # well off the panel
	await frames()
	print("SMOKE aiming off the panel does not hover: ", not surf.hovering and not cursor.visible)

	# --- a plain click
	r.set_meta("ui_hover", false)
	aim_at_px(Vector2(200, 90)); await frames()
	click(true); await process_frame; click(false); await process_frame
	print("SMOKE a click lands on the button under the laser: ", clicks[0] == 1)

	# --- the real-headset bug: aim drifts mid-press
	r.set_meta("ui_hover", false)
	aim_at_px(Vector2(200, 90)); await frames()
	click(true); await process_frame
	aim_at_px(Vector2(360, 250)); await frames(3) # hand drifts far off the button but stays on the panel
	click(false); await process_frame
	print("SMOKE a click still registers when the aim drifts mid-press (frozen press): ", clicks[0] == 2)

	# --- edge slack while pressed
	r.set_meta("ui_hover", false)
	aim_at_px(Vector2(395, 150)); await frames()
	click(true); await process_frame
	r.position.x += 0.02 # 2 cm past the right edge: inside the 3 cm press slack
	await frames()
	var held_in_slack: bool = surf.hovering and surf.pressed
	click(false); await process_frame
	r.set_meta("ui_hover", false)
	r.position.x = 0.5 * PANEL.x + 0.02
	await frames()
	print("SMOKE while pressed the edge is forgiving (2 cm outside still hovers): ", held_in_slack)
	print("SMOKE ...but 2 cm outside with nothing pressed does not: ", not surf.hovering)

	# --- let go on leave
	r.set_meta("ui_hover", false)
	aim_at_px(Vector2(200, 90)); await frames()
	var before: int = clicks[0]
	click(true); await process_frame
	r.position = Vector3(2.0, 1.5, 0.0) # far outside slack
	await frames()
	print("SMOKE leaving the panel mid-press releases it (nothing stuck down): ", not surf.pressed and not button.button_pressed)
	click(false); await process_frame

	# --- slider drag: keeps tracking the aim while pressed
	r.set_meta("ui_hover", false)
	aim_at_px(Vector2(200, 180)); await frames()
	var v0 := slider.value
	click(true); await process_frame
	aim_at_px(Vector2(350, 180)); await frames(3)
	var dragged := slider.value
	click(false); await process_frame
	print("SMOKE a press that starts on a slider drags it with the aim: ", dragged > v0 + 20.0)

	# --- first-claim arbitration
	r.set_meta("ui_hover", true); r.set_meta("ui_hit_distance", 5.0)
	aim_at_px(Vector2(200, 90)); await process_frame
	surf.process(0.016, true) # no reset: someone else claimed this frame
	print("SMOKE first-claim: a surface does not take a claim someone already holds: ", not surf.hovering and absf(float(r.get_meta("ui_hit_distance")) - 5.0) < 0.001)
	surf.claim_first = false
	await frames()
	print("SMOKE claim_first=false (old tablet behaviour) overwrites it: ", surf.hovering and absf(float(r.get_meta("ui_hit_distance")) - 1.0) < 0.01)
	surf.claim_first = true

	# --- release_all drops the claim
	surf.release_all()
	print("SMOKE release_all() drops the claim we hold: ", r.get_meta("ui_hover") == false and not surf.hovering)

	# --- settle window
	r.set_meta("ui_hover", false)
	surf.settle_seconds = 0.4
	surf.arm()
	var n0: int = clicks[0]
	aim_at_px(Vector2(200, 90)); await frames()
	click(true); await process_frame; click(false); await process_frame
	var ignored: bool = clicks[0] == n0
	await create_timer(0.5).timeout
	r.set_meta("ui_hover", false)
	await frames()
	click(true); await process_frame; click(false); await process_frame
	print("SMOKE a press inside the settle window is ignored, a later one lands: ", ignored and clicks[0] == n0 + 1)
	surf.settle_seconds = 0.0

	# --- stick scroll
	await create_timer(0.5).timeout # click lockout from the last click
	scroll.scroll_vertical = 0
	surf.scroll_by_stick(0.2, 0.016)
	print("SMOKE a light stick touch (inside the deadzone) doesn't scroll: ", scroll.scroll_vertical == 0)
	surf.scroll_by_stick(-1.0, 0.1) # stick pushed down is negative y on Quest; matches wrist_tablet: -y scrolls down
	print("SMOKE pushing the stick down scrolls down: ", scroll.scroll_vertical > 0)
	scroll.scroll_vertical = 100000
	surf.scroll_by_stick(-1.0, 0.1)
	surf.scroll_by_stick(1.0, 0.1)
	print("SMOKE after bottoming out, pushing up scrolls back immediately (no wind-up): ", scroll.scroll_vertical < int(scroll.get_v_scroll_bar().max_value) )
	quit()
