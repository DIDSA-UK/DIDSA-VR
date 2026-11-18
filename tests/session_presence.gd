extends SceneTree
## P2b: what this person sends the others (scripts/session/session_presence.gd, scope 4.4), in the real main.tscn hosting through the fake hub, with a scripted observer reading it. The head
## in MODEL space (millimetres, relative to the glb root, whatever scale or place the model has, and a demo's metres as mm), its rotation, a hand with no tracking as null, the laser's end,
## the mode ("following"), 15 Hz while moving and 1 Hz while still, a move under 2 mm and 1 degree counting as still, nothing while no model is open, nothing after End. Headless: no hand is
## tracked (the test says so through `hand_tracked`), so the hands and laser are checked with a stand-in.
## Run: "$GODOT" --headless --path . --script res://tests/session_presence.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Presence := preload("res://scripts/session/session_presence.gd")
const DEMO := "res://demo/spacecraft/Pioneer_10.glb"

var main: Node
var hub: RefCounted
var backend: RefCounted
var seen: Array = []


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _expected_head(camera: Node3D, unit: float) -> Transform3D:
	var local: Transform3D = main.session_scene_root().global_transform.affine_inverse() * camera.global_transform
	return Transform3D(local.basis.orthonormalized(), local.origin * unit)


func _initialize() -> void:
	# --- the pure part
	var still := [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], null, null]
	var tiny := [[1.9, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], null, null]
	var far := [[2.1, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], null, null]
	var small_turn := [[0.0, 0.0, 0.0, 0.0, sin(deg_to_rad(0.4)), 0.0, cos(deg_to_rad(0.4))], null, null]
	var big_turn := [[0.0, 0.0, 0.0, 0.0, sin(deg_to_rad(0.6)), 0.0, cos(deg_to_rad(0.6))], null, null] # 1.2 degrees
	_check(not Presence.moved(tiny, still) and Presence.moved(far, still), "under 2 mm is still, over 2 mm is a move")
	_check(not Presence.moved(small_turn, still) and Presence.moved(big_turn, still), "under 1 degree is still, over 1 degree is a move")
	var with_hand := [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], null]
	_check(Presence.moved(with_hand, still) and Presence.moved(still, with_hand) and not Presence.moved(with_hand, with_hand.duplicate(true)), "a hand appearing or going counts as a move")
	hub = Hub.new()
	backend = Backend.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.use_transport(hub.make_transport)
	main.session.http.transport = backend.handle
	var empty_presence := Presence.new()
	empty_presence.main = main
	_check(empty_presence.build().is_empty(), "with no model open there is nothing to be relative to: no presence")
	empty_presence.free()
	main._resolved_part_id = "part-root"
	main.backend_url = "https://cad.test"
	main.api_key = backend.key
	main.hub_url = "wss://hub.test"
	main.hub_key = hub.key
	main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/session_assembly.glb"), "", main.spawn_scale, true)
	var camera: Node3D = main.session_camera()
	camera.position = Vector3(0.2, 1.6, -0.3)
	camera.rotation_degrees = Vector3(0, 90, 0)
	var hosted: Dictionary = await main.session.host_session()
	_check(hosted["ok"], "hosting")
	var watcher := Client.new()
	watcher.transport_factory = hub.make_transport
	root.add_child(watcher)
	watcher.presence_received.connect(func(m: Dictionary) -> void: seen.append(m))
	watcher.join("wss://hub.test", main.session.code(), {"name": "Blake", "device": "phone", "client": "t"})
	await _wait(1.4) # (the presenter's own presence goes out at least once a second; the hub keeps the last one for whoever joins: session_avatars.gd draws that at once)
	_check(not seen.is_empty() and int(seen[0]["from"]) == 1, "the presenter's presence reaches an observer, stamped with who it is from")
	var message: Dictionary = seen[-1]
	_check(message["t"] == "presence" and message["mode"] == "free" and message["cursor"] == null and message["hands"] == [null, null] and message["laser"] == null, "no tracked hands: both null, no laser, no cursor, mode free")
	var expected := _expected_head(camera, 1.0)
	var head: Array = message["head"]
	var got := Vector3(head[0], head[1], head[2])
	_check(got.distance_to(expected.origin) < 0.05 and head.size() == 7, "the head is in model space, millimetres: (%.2f, %.2f, %.2f) expected (%.2f, %.2f, %.2f)" % [got.x, got.y, got.z, expected.origin.x, expected.origin.y, expected.origin.z])
	var q := Quaternion(head[3], head[4], head[5], head[6])
	_check(absf(q.dot(expected.basis.get_rotation_quaternion())) > 0.9999, "...and its rotation (turned 90 degrees)")
	# the same head, the model moved and scaled: the numbers follow the model, not the world
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.002), Vector3(1.0, 1.0, -2.0))
	seen.clear()
	await _wait(1.3)
	var moved_head: Array = seen[-1]["head"]
	var expected2 := _expected_head(camera, 1.0)
	_check(Vector3(moved_head[0], moved_head[1], moved_head[2]).distance_to(expected2.origin) < 0.1 and Vector3(moved_head[0], moved_head[1], moved_head[2]).distance_to(got) > 100.0, "move and scale the model: the same head is somewhere else in model space (the model is what it is relative to)")
	# a tracked hand and a laser (stand-ins: nothing is tracked headless)
	var presence: Node = main.session.presence
	presence.hand_tracked = func(_hand: Node) -> bool: return true
	main.session_hands()[1].global_position = Vector3(0.4, 1.2, -0.5)
	seen.clear()
	await _wait(1.4)
	var hands: Array = seen[-1]["hands"]
	_check(hands[0] != null and hands[1] != null and hands[0].size() == 7, "tracked hands are sent as poses")
	var right_expected := _expected_head(main.session_hands()[1], 1.0)
	_check(Vector3(hands[1][0], hands[1][1], hands[1][2]).distance_to(right_expected.origin) < 0.1, "...the right hand where it is, in model mm")
	var tip = main.session_hands()[1].laser_tip()
	_check(tip is Vector3 and (tip as Vector3).distance_to(main.session_hands()[1].global_position) > 0.01, "the controller reports where its laser ends")
	var laser = seen[-1]["laser"]
	var tip_model: Vector3 = (main.session_scene_root().global_transform.affine_inverse() * (tip as Vector3))
	_check(laser is Array and Vector3(laser[0], laser[1], laser[2]).distance_to(tip_model) < 0.1, "...and it is sent in model space")
	main.session_hands()[1].set_meta("wheel_open", true)
	main.session_hands()[1]._update_laser_visual()
	_check(main.session_hands()[1].laser_tip() == null, "no laser drawn, no laser sent")
	main.session_hands()[1].set_meta("wheel_open", false)
	presence.hand_tracked = func(hand: Node) -> bool: return hand.get_has_tracking_data()
	# --- rates
	await _wait(0.4)
	seen.clear()
	await _wait(3.2)
	_check(seen.size() >= 2 and seen.size() <= 5, "still: about once a second (%d in 3.2 s)" % seen.size())
	seen.clear()
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 1000:
		camera.position += Vector3(0.004, 0.0, 0.0)
		await process_frame
	await _wait(0.1)
	_check(seen.size() >= 8 and seen.size() <= 18, "moving: up to 15 times a second (%d in about a second)" % seen.size())
	seen.clear()
	camera.position += Vector3(0.0, 0.0, 0.0005) # half a millimetre at model scale is far under 2 mm
	await _wait(2.4)
	_check(seen.size() <= 4, "a move under 2 mm is still: back to once a second (%d in 2.4 s)" % seen.size())
	# --- the mode
	main.session.navigation.following = true
	seen.clear()
	await _wait(1.3)
	_check(seen[-1]["mode"] == "following", "someone riding the presenter's view says 'following'")
	main.session.navigation.following = false
	# --- a demo: millimetres
	main.mark_clean()
	main.load_glb_file(DEMO)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY, Vector3(0, 0, -3))
	seen.clear()
	await _wait(1.6)
	var demo_head: Array = seen[-1]["head"] if not seen.is_empty() else [0, 0, 0]
	var expected_demo := _expected_head(camera, 1000.0)
	_check(not seen.is_empty() and Vector3(demo_head[0], demo_head[1], demo_head[2]).distance_to(expected_demo.origin) < 1.0 and main.session_unit_mm() == 1000.0, "a demo (a glb in metres) is sent in millimetres too: x1000")
	# --- End: nothing more
	await main.session.end_session()
	var count: int = presence.sent_count
	await _wait(1.3)
	_check(presence.sent_count == count and not main.session.is_active(), "after End nothing more is sent")
	quit()
