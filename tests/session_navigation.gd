extends SceneTree
## P2b: Go to presenter, Follow presenter (with the comfort vignette) and Gather everyone (scripts/session/session_navigation.gd), in the real main.tscn as an observer of a scripted presenter,
## then as the presenter. The arithmetic (heading, the spot beside a head, the arc in front of it), Go to (nothing to go to yet; beside the presenter at their height facing their way; a dark pulse that
## fades), Follow (eases at no more than 3 m/s, the vignette closes while it moves and opens when it has caught up, the presence says "following", a push of the left stick stops it, Reduce motion
## steps instead of gliding, a long way is a jump), Gather received (each observer in the arc by participant id, facing the presenter, an older gather ignored) and sent (only by the presenter, with
## its head pose), and an observer cannot gather. NOT judged: whether any of it is comfortable (headset), the vignette's picture (tests/session_vignette_render.gd).
## Run: "$GODOT" --headless --path . --script res://tests/session_navigation.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Nav := preload("res://scripts/session/session_navigation.gd")
const DEMO := "res://demo/spacecraft/Pioneer_10.glb"

var main: Node
var hub: RefCounted


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _pose(x: float, y: float, z: float, yaw_deg: float = 0.0) -> Array:
	var q := Quaternion(Vector3.UP, deg_to_rad(yaw_deg))
	return [x, y, z, q.x, q.y, q.z, q.w]


func _head(presenter: Node, mm: Array) -> void:
	presenter.send({"t": "presence", "head": mm, "hands": [null, null], "laser": null, "cursor": null, "mode": "free"})


func _cam() -> Node3D:
	return main.session_camera()


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _initialize() -> void:
	# --- the arithmetic
	_check(absf(Nav.yaw_of(Basis.IDENTITY)) < 1e-6 and absf(Nav.yaw_of(Basis(Vector3.UP, deg_to_rad(90.0))) - deg_to_rad(90.0)) < 1e-5 and absf(Nav.yaw_of(Basis(Vector3.UP, deg_to_rad(-120.0))) - deg_to_rad(-120.0)) < 1e-5, "the heading of a basis is the angle about up that turns forward to where it looks")
	_check(absf(Nav.yaw_of(Basis(Vector3.RIGHT, deg_to_rad(40.0)))) < 1e-5, "looking up or down does not change the heading")
	var head_at := Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(2.0, 1.6, -1.0)) # facing -X
	var beside: Dictionary = Nav.spot_beside(head_at)
	_check(absf((beside["position"] as Vector3).distance_to(head_at.origin) - Nav.SIDE_OFFSET) < 1e-5 and absf((beside["position"] as Vector3).y - 1.6) < 1e-6 and absf(float(beside["yaw"]) - deg_to_rad(90.0)) < 1e-5, "the spot beside a head: 0.9 m away, level, facing the way the head faces")
	var side_dir: Vector3 = ((beside["position"] as Vector3) - head_at.origin).normalized()
	_check(side_dir.dot(-head_at.basis.z) < 1e-5 and side_dir.dot(head_at.basis.x) > 0.99, "...on its right (not in front of it, where the person is looking)")
	var front := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, 0.0)) # facing -Z
	var one: Dictionary = Nav.gather_spot(front, 0, 1)
	_check((one["position"] as Vector3).distance_to(Vector3(0.0, 1.6, -Nav.GATHER_RADIUS)) < 1e-5 and absf(absf(float(one["yaw"])) - PI) < 1e-4, "one person gathered stands straight in front, 1.4 m out, looking back at them")
	var arc: Array = []
	for i in 3:
		arc.append(Nav.gather_spot(front, i, 3))
	var spacing: float = deg_to_rad(Nav.GATHER_STEP_DEG)
	var a0: Vector3 = (arc[0]["position"] as Vector3) - front.origin
	var a1: Vector3 = (arc[1]["position"] as Vector3) - front.origin
	var a2: Vector3 = (arc[2]["position"] as Vector3) - front.origin
	_check(absf(a0.length() - Nav.GATHER_RADIUS) < 1e-5 and absf(a1.angle_to(a0) - spacing) < 1e-4 and absf(a1.angle_to(a2) - spacing) < 1e-4 and a1.distance_to(Vector3(0, 0, -Nav.GATHER_RADIUS)) < 1e-5, "three in an arc: the middle one in front, the others 28 degrees either side, all 1.4 m out")
	var faces_back := true
	for spot in arc:
		var toward: Vector3 = (front.origin - (spot["position"] as Vector3))
		faces_back = faces_back and absf(wrapf(Nav.yaw_of(Basis.looking_at(toward, Vector3.UP)) - float(spot["yaw"]), -PI, PI)) < 1e-4
	_check(faces_back, "...each looking at the presenter")
	# --- the world: a scripted presenter hosting a demo, and this app joining as an observer
	hub = Hub.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.use_transport(hub.make_transport)
	var presenter := Client.new()
	presenter.transport_factory = hub.make_transport
	root.add_child(presenter)
	presenter.host("wss://hub.test", hub.key, {"name": "Alex", "device": "pcvr", "client": "t", "model": {"kind": "demo", "path": DEMO, "title": "Pioneer 10"}})
	await _wait(0.3)
	presenter.send_state({"t": "place", "xf": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -3.0]})
	var code: String = presenter.room["code"]
	var other := Client.new() # a second observer, so the arc has two
	other.transport_factory = hub.make_transport
	root.add_child(other)
	other.join("wss://hub.test", code, {"name": "Casey", "device": "phone", "client": "t"})
	await _wait(0.3)
	var joined: Dictionary = await main.session.join_session("wss://hub.test", code)
	await _wait(1.0)
	_check(joined["ok"] and main.is_observer(), "joined as an observer")
	var nav: Node = main.session.navigation
	var rig: XROrigin3D = main.session_rig()
	_cam().position = Vector3(0.0, 1.6, 0.0)
	_check(nav.vignette != null and nav.vignette.get_parent() == _cam(), "the comfort vignette is on the camera")
	# --- Go to: nothing to go to yet
	_check(not nav.go_to_presenter() and nav.last_line.contains("Nothing from the presenter yet") and nav.jumps == 0, "before the presenter's position has arrived: it says so and goes nowhere")
	_check(not nav.set_following(true) and not nav.following, "...and Follow will not start")
	# the presenter's head: 2 m right, 1.6 up, 1 m back of the model's origin (millimetres, a demo), looking along -X
	_head(presenter, _pose(2000.0, 1600.0, 1000.0, 90.0))
	await _wait(0.8)
	var head: Transform3D = nav.presenter_head() if nav.presenter_head() != null else Transform3D.IDENTITY
	_check(head != null and (head.origin).distance_to(Vector3(2.0, 1.6, -2.0)) < 1e-3, "the presenter's head is at the model-space spot, through this view of the model: (%s)" % str(head.origin if head != null else null))
	var spot: Dictionary = Nav.spot_beside(head)
	_check(nav.go_to_presenter(), "Go to presenter")
	_check(_cam().global_position.distance_to(spot["position"]) < 1e-3, "your head is beside theirs (0.9 m to their right), at their height: (%s)" % str(_cam().global_position))
	_check(absf(wrapf(Nav.yaw_of(_cam().global_transform.basis) - Nav.yaw_of(head.basis), -PI, PI)) < 1e-3, "...turned the way they face")
	_check(nav._pulse > 0.99 and nav.jumps == 1, "a jump comes with a dark pulse (the comfort vignette, asked for at %.2f)" % nav._pulse)
	await _wait(0.6)
	_check(nav.vignette_strength == 0.0 and not nav.vignette.visible, "...which has gone again")
	# --- Follow: the presenter walks 4 m away
	var follow_started: bool = nav.set_following(true)
	_check(follow_started and nav.following and main.session.navigation.last_line.contains("left stick"), "Follow presenter starts (and says how to stop)")
	_head(presenter, _pose(6000.0, 1600.0, 1000.0, 90.0))
	await _wait(0.5)
	var strongest := 0.0
	var fastest := 0.0
	var window_pos: Vector3 = _cam().global_position
	var started := Time.get_ticks_msec()
	var window_ms := started
	while Time.get_ticks_msec() - started < 3500:
		await process_frame
		var now := Time.get_ticks_msec()
		if now - window_ms >= 250: # speed over a quarter of a second (a single frame's time is too coarse to read)
			fastest = maxf(fastest, _cam().global_position.distance_to(window_pos) / (float(now - window_ms) / 1000.0))
			window_pos = _cam().global_position
			window_ms = now
		strongest = maxf(strongest, nav.vignette_strength)
	var target: Dictionary = Nav.spot_beside(nav.presenter_head())
	_check(_cam().global_position.distance_to(target["position"]) < 0.1, "following: the view caught up with the presenter 4 m away (%.3f m off)" % _cam().global_position.distance_to(target["position"]))
	_check(fastest < 3.3 and fastest > 0.5, "...gliding at no more than 3 m/s (%.2f m/s at most)" % fastest)
	_check(strongest > 0.3, "...with the vignette closing while it moved (%.2f at most)" % strongest)
	_check(nav.vignette_strength < 0.02, "...and open again once it caught up (%.3f)" % nav.vignette_strength)
	_check(nav.jumps == 1, "a short way is a glide, not a jump")
	# the others are told
	var seen_modes: Array = []
	presenter.presence_received.connect(func(m: Dictionary) -> void: seen_modes.append(m["mode"]))
	await _wait(1.5)
	_check(seen_modes.has("following"), "the presenter sees this person's presence say 'following'")
	# a push of the left stick stops it
	nav.stick = func(_hand: Node) -> Vector2: return Vector2(0.0, 1.0)
	await _wait(0.2)
	_check(not nav.following and nav.last_line.contains("Stopped following"), "a push of the left stick stops following")
	nav.stick = func(hand: Node) -> Vector2: return hand.get_vector2("primary")
	# a long way: a jump
	nav.set_following(true)
	var jumps_before: int = nav.jumps
	_head(presenter, _pose(60000.0, 1600.0, 1000.0, 0.0)) # 60 m
	await _wait(2.5) # (jumps while the presenter's smoothed head is more than 8 m away, then glides the last few metres)
	_check(nav.jumps >= jumps_before + 1 and _cam().global_position.distance_to(Nav.spot_beside(nav.presenter_head())["position"]) < 0.1, "more than 8 m away: a jump (or a few as it sweeps by), with the pulse, not a long glide")
	# Reduce motion: a step, not a glide
	main.set_reduce_motion(true)
	jumps_before = nav.jumps
	_head(presenter, _pose(63000.0, 1600.0, 1000.0, 0.0))
	await _wait(0.8)
	_check(nav.jumps >= jumps_before + 1 and _cam().global_position.distance_to(Nav.spot_beside(nav.presenter_head())["position"]) < Nav.REDUCE_MOTION_JUMP + 0.05, "with Reduce motion on, following steps (a jump with the pulse) instead of gliding, and is left within the step distance (0.6 m)")
	main.set_reduce_motion(false)
	nav.set_following(false)
	# --- Gather received
	jumps_before = nav.jumps
	var mine := int(main.session.client.me["id"])
	var theirs := int(other.me["id"])
	presenter.send_state({"t": "gather", "pose": _pose(0.0, 1600.0, 0.0, 0.0)})
	await process_frame
	await process_frame
	var gather_head := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.6, -3.0)) # the model's place is z -3: model (0, 1600, 0) mm of a demo is (0, 1.6, -3)
	var rank: int = [mine, theirs].find(mine) if mine < theirs else 1
	var expected: Dictionary = Nav.gather_spot(gather_head, 0 if mine < theirs else 1, 2)
	_check(nav.jumps == jumps_before + 1 and _cam().global_position.distance_to(expected["position"]) < 1e-3, "gather: this person is moved to their place in the arc in front of the presenter (rank %d of 2)" % rank)
	_check(absf(wrapf(Nav.yaw_of(_cam().global_transform.basis) - float(expected["yaw"]), -PI, PI)) < 1e-3, "...looking at them")
	_check(nav.vignette_strength > 0.5, "...with the pulse")
	await _wait(0.6)
	var before_old: Vector3 = _cam().global_position
	presenter.send({"t": "gather", "seq": 1, "pose": _pose(5000.0, 1600.0, 0.0, 0.0)}) # an older number than one already applied
	await _wait(0.4)
	_check(_cam().global_position.distance_to(before_old) < 1e-4, "a gather numbered older than one already applied is ignored")
	_check(not nav.gather_everyone() and nav.last_line.contains("Only the presenter"), "an observer cannot gather anyone")
	# --- then as the presenter: Gather everyone
	main.session.leave_session()
	await _wait(0.5)
	main.mark_clean()
	main.load_glb_file(DEMO)
	main.hub_url = "wss://hub.test"
	main.hub_key = hub.key
	var hosted: Dictionary = await main.session.host_session()
	_check(hosted["ok"] and main.session.is_presenter(), "hosting the demo")
	var watcher := Client.new()
	watcher.transport_factory = hub.make_transport
	root.add_child(watcher)
	var gathers: Array = []
	watcher.message_received.connect(func(m: Dictionary) -> void:
		if m["t"] == "gather":
			gathers.append(m))
	watcher.join("wss://hub.test", main.session.code(), {"name": "Dana", "device": "quest", "client": "t"})
	await _wait(0.4)
	var nav2: Node = main.session.navigation
	_cam().position = Vector3(0.3, 1.5, 0.2)
	_check(not nav2.go_to_presenter() and nav2.last_line.contains("You are the presenter") and not nav2.set_following(true), "the presenter has no one to go to or follow")
	_check(nav2.gather_everyone() and nav2.last_line.contains("Asked 1 person"), "Gather everyone")
	await _wait(0.3)
	var expect_head: Array = main.session.presence.build()["head"]
	_check(gathers.size() == 1 and gathers[0]["pose"].size() == 7 and absf(float(gathers[0]["pose"][0]) - float(expect_head[0])) < 1.0 and int(gathers[0]["seq"]) >= 1, "the observers are sent the presenter's head pose in model space (%s)" % str(gathers[0]["pose"] if not gathers.is_empty() else null))
	await main.session.end_session()
	quit()
