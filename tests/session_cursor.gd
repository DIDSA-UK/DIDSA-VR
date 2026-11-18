extends SceneTree
## P4.1: the DRONE CURSOR (scripts/session/session_cursor.gd; plan "Observer tools"), in the real main.tscn as an OBSERVER joining a scripted presenter through tests/fake_session_hub.gd, with
## tests/fake_session_backend.gd serving the glb (three 10 mm cubes, shown here at 1:50 so each is 0.2 m). There is no hand headless, so the test replaces the cursor's `aim` and `stick`.
## Covered: off by default; on takes the right stick away from locomotion (is_manipulating); what it picks (touching a surface, inside a part, pointing at one, nothing; a hidden part is never
## picked); the breadcrumb level (Face, Body, Part, the sub-assembly, A wider and B narrower, never past what the part has) and the wire target each level gives; the leash (the stick lets it out
## and in, clamped); the pose in presence's `cursor` field in model space and null again when it is off (and a moving cursor counts as movement); others' cursors drawn by the avatars (their name,
## their colour, interpolated); and that an observer sends nothing but presence while doing it. NOT covered: how it feels to fly one, a headset.
## Run: "$GODOT" --headless --path . --script res://tests/session_cursor.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Avatars := preload("res://scripts/session/session_avatars.gd")
const Presence := preload("res://scripts/session/session_presence.gd")
const BENCH := 1.2 ## metres above the floor

var hub: RefCounted
var backend: RefCounted
var main: Node
var presenter: Node
var cursor: Node3D
var aim_origin := Vector3.ZERO
var aim_direction := Vector3(0, 0, -1)
var stick := Vector2.ZERO


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _part(path: String) -> Node3D:
	for node in main.session_world_parts():
		if str(node.get_meta("instance_path", "?")) == path:
			return node
	return null


func _aim(origin: Vector3, direction: Vector3, distance: float) -> void:
	aim_origin = origin
	aim_direction = direction
	cursor.distance = distance
	for i in 3:
		await physics_frame # (the frame places the cursor and works out what it is on)
	cursor.refresh()


func _pose(x: float, y: float, z: float) -> Array:
	return [x, y, z, 0.0, 0.0, 0.0, 1.0]


func _initialize() -> void:
	# --- the pure part: a cursor sample is blended between two presence samples
	var track := {"a": {"at": 1000.0, "head": _pose(0, 0, 0), "hands": [null, null], "laser": null, "cursor": _pose(0, 0, 0), "mode": "free"},
		"b": {"at": 1070.0, "head": _pose(0, 0, 0), "hands": [null, null], "laser": null, "cursor": _pose(100, 0, 0), "mode": "free"}}
	_check(absf(Avatars.sample_at(track, 1035.0)["cursor"][0] - 50.0) < 1e-6, "a cursor is blended halfway between two samples")
	track["a"]["cursor"] = null
	_check(Avatars.sample_at(track, 1035.0)["cursor"][0] == 100.0, "a cursor missing from the older sample is the newer one's (no blend with nothing)")
	track["b"]["cursor"] = null
	_check(Avatars.sample_at(track, 1035.0)["cursor"] == null, "no cursor in either: none")
	_check(Presence.moved([_pose(0, 0, 0), null, null, _pose(5, 0, 0)], [_pose(0, 0, 0), null, null, _pose(0, 0, 0)]) and Presence.moved([_pose(0, 0, 0), null, null, null], [_pose(0, 0, 0), null, null, _pose(0, 0, 0)]) and not Presence.moved([_pose(0, 0, 0), null, null, null], [_pose(0, 0, 0), null, null, null]),
		"a cursor moving, appearing or going away counts as movement for presence (so it is sent at 15 Hz)")
	# --- an observer joins a scripted presenter
	hub = Hub.new()
	backend = Backend.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.use_transport(hub.make_transport)
	main.session.http.transport = backend.handle
	backend.tokens["tok-1"] = true
	presenter = Client.new()
	presenter.transport_factory = hub.make_transport
	root.add_child(presenter)
	presenter.host("wss://hub.test", hub.key, {"name": "Alex", "device": "quest", "client": "test", "model": {"kind": "backend", "root_part_id": "part-root", "rev": 3, "quality": 0.5, "tier": "full", "title": "Gearbox"},
		"backend_url": "https://cad.test", "view_token": "tok-1", "view_expires_at": 99999999999.0})
	await _wait(0.3)
	var code: String = str(presenter.room["code"])
	presenter.send_state({"t": "poses", "full": true, "items": [{"path": "", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]}, {"path": "occ-bolt", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 30, 0, 0]}, {"path": "occ-nut", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 30, 0]}]})
	var joined: Dictionary = await main.session.join_session("wss://hub.test", code)
	await _wait(0.5)
	_check(joined["ok"] and main.is_observer() and main.session_world_parts().size() == 3, "an observer is in, the model is on show")
	main.session_apply_place(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.02), Vector3(0.0, BENCH, 0.0))) # 1:50: each cube is 0.2 m, the bolt 0.6 m along x, the nut 0.6 m up; the whole model on a bench, off the floor (a cursor at the floor touches the floor, which is not a part)
	cursor = main.session.cursor
	cursor.aim = func() -> Dictionary: return {"origin": aim_origin, "direction": aim_direction}
	cursor.stick = func() -> Vector2: return stick
	for i in 3:
		await physics_frame
	var me: int = int(main.session.client.me["id"])
	var hands: Array = main.session_hands()
	# --- off by default
	_check(not cursor.enabled and cursor.selection().is_empty() and main.session.presence.build()["cursor"] == null, "the cursor is off to begin with: nothing selected, and presence carries no cursor")
	_check(not hands[1].is_manipulating(), "...and the right stick is the app's (snap turn, teleport)")
	cursor.set_enabled(true)
	_check(cursor.enabled and hands[1].is_manipulating() and not hands[0].is_manipulating(), "on: the right stick is the cursor's (locomotion leaves it alone), the left is not")
	# --- what it picks
	var bolt := _part("occ-bolt")
	var nut := _part("occ-nut")
	await _aim(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.8) # the cursor is at z = 0.2, the bolt's near face at z = 0.1
	var picked: Dictionary = cursor.selection()
	_check(cursor.last_how == "pointing" and picked.get("node") == bolt, "a cursor in front of a part, aimed at it, points at it (%s)" % cursor.last_how)
	_check(str(picked.get("label", "")).begins_with("Part") and picked.get("target") == {"path": "occ-bolt"}, "at the Part level: the part's wire key is the target (%s)" % str(picked.get("target")))
	await _aim(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.88) # z = 0.12: 2 cm off the near face (z = 0.1): touching is within 4 cm of a surface
	_check(cursor.last_how == "touching" and cursor.selection().get("node") == bolt, "within 4 cm of a surface it touches it (%s)" % cursor.last_how)
	await _aim(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 1.0) # the middle of the cube: no surface within reach
	_check(cursor.last_how == "inside" and cursor.selection().get("node") == bolt and cursor.selection()["face_index"] == -1, "flown inside a part, it is inside it (no face is known)")
	await _aim(Vector3(5.0, 5.0, 5.0), Vector3(0, 1, 0), 1.0)
	_check(cursor.selection().is_empty() and cursor.last_how == "", "away from everything it has nothing selected")
	bolt.visible = false
	await _aim(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.8)
	_check(cursor.selection().is_empty(), "a hidden part is never picked")
	bolt.visible = true
	# --- the levels
	var face_ids: Array = []
	var body_ids: Array = []
	for t in 12:
		face_ids.append(10 + t / 2)
		body_ids.append("b1")
	nut.set_meta("face_ids", face_ids)
	nut.set_meta("body_ids", body_ids)
	await _aim(Vector3(0.0, BENCH + 0.6, 1.0), Vector3(0, 0, -1), 0.8)
	var rows: Array = cursor.levels().map(func(r: Dictionary) -> String: return str(r["id"]))
	_check(cursor.selection().get("node") == nut and rows == ["face", "body", "part"], "a part with face identity has Face, Body and Part levels, and no 'whole assembly' (%s)" % str(rows))
	_check(cursor.selection()["row"]["id"] == "part" and cursor.level_rank == 2, "Part is the default")
	cursor.step_level(-1)
	var body: Dictionary = cursor.selection()
	_check(body["row"]["id"] == "body" and body["target"] == {"path": "occ-nut", "body": "b1"}, "B, one level narrower: the Body, target with its body (%s)" % str(body["target"]))
	hands[1].button_pressed.emit("by_button")
	var face: Dictionary = cursor.selection()
	_check(face["row"]["id"] == "face" and face["target"].get("body") == "b1" and int(face["target"].get("face", -1)) >= 10, "the B button on the right hand: the Face, target with body and face index (%s)" % str(face["target"]))
	cursor.step_level(-1)
	_check(cursor.selection()["row"]["id"] == "face", "narrower than a face is still the face")
	hands[1].button_pressed.emit("ax_button")
	_check(cursor.selection()["row"]["id"] == "body", "the A button: one level wider")
	cursor.step_level(5)
	_check(cursor.selection()["row"]["id"] == "part", "wider than the part, with no sub-assembly: still the part")
	# a sub-assembly: the glb's paths say bolt and nut sit in one
	bolt.set_meta("instance_path", "sub/occ-bolt")
	nut.set_meta("instance_path", "sub/occ-nut")
	await _aim(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.8)
	await _aim(Vector3(0.0, BENCH + 0.6, 1.0), Vector3(0, 0, -1), 0.8)
	rows = cursor.levels().map(func(r: Dictionary) -> String: return str(r["id"]))
	_check(rows.size() == 4 and rows[3].begins_with("sub_"), "a part that sits in a sub-assembly has that level too (%s)" % str(rows))
	cursor.set_level_rank(3)
	var sub: Dictionary = cursor.selection()
	_check(str(sub["label"]).begins_with("Sub-assembly") and sub["members"].size() == 2 and sub["target"] == {"path": "sub"}, "the sub-assembly level: both parts, the target is the path prefix (%s)" % str(sub["target"]))
	bolt.set_meta("instance_path", "occ-bolt")
	nut.set_meta("instance_path", "occ-nut")
	# --- the leash
	cursor.distance = 1.0
	cursor.fly(0.5)
	var far: float = cursor.distance
	cursor.fly(100.0)
	var longest: float = cursor.distance
	cursor.fly(-100.0)
	_check(is_equal_approx(far, 1.5) and is_equal_approx(longest, cursor.MAX_DISTANCE) and is_equal_approx(cursor.distance, cursor.MIN_DISTANCE), "the leash lets out and reels in, within its limits")
	aim_origin = Vector3(5.0, 5.0, 5.0)
	cursor.distance = 1.0
	stick = Vector2(0.0, -1.0) # pushed forward
	for i in 6:
		await physics_frame
	stick = Vector2.ZERO
	_check(cursor.distance > 1.0, "the right stick pushed forward lets the cursor out (%.3f m)" % cursor.distance)
	stick = Vector2(0.0, 0.1) # inside the dead zone
	var held: float = cursor.distance
	for i in 3:
		await physics_frame
	stick = Vector2.ZERO
	_check(is_equal_approx(cursor.distance, held), "a stick inside its dead zone does nothing")
	# --- what it sends
	var blake := Client.new()
	blake.transport_factory = hub.make_transport
	root.add_child(blake)
	blake.join("wss://hub.test", code, {"name": "Blake", "device": "phone", "client": "t"})
	await _wait(0.3)
	var blake_id: int = int(blake.me["id"])
	await _aim(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.8)
	await _wait(0.3)
	var message: Dictionary = main.session.presence.build()
	var expected_mm: Vector3 = main.session_scene_root().global_transform.affine_inverse() * cursor.world_transform().origin
	_check(message["cursor"] is Array and message["cursor"].size() == 7 and Vector3(message["cursor"][0], message["cursor"][1], message["cursor"][2]).distance_to(expected_mm) < 0.02, "presence's cursor is a model-space pose in mm (%s)" % str(message["cursor"]))
	var seen: Array = hub.received_of(blake_id, "presence").filter(func(m: Dictionary) -> bool: return int(m.get("from", 0)) == me and m.get("cursor") != null)
	_check(not seen.is_empty(), "another observer is sent it (%d presence messages with a cursor)" % seen.size())
	cursor.set_enabled(false)
	_check(not hands[1].is_manipulating() and main.session.presence.build()["cursor"] == null and cursor.selection().is_empty(), "off again: the stick is the app's, presence carries null, nothing is selected")
	await _wait(1.3)
	var last: Dictionary = (hub.received_of(blake_id, "presence").filter(func(m: Dictionary) -> bool: return int(m.get("from", 0)) == me)).back()
	_check(last.get("cursor") == null, "...and the others are told (the next presence has no cursor)")
	# --- others' cursors are drawn
	var avatars: Node3D = main.session.avatars
	blake.send({"t": "presence", "head": _pose(0.0, 1600.0, 0.0), "hands": [null, null], "laser": null, "cursor": _pose(600.0, 0.0, 100.0), "mode": "free"})
	await _wait(0.5)
	var drawn: Dictionary = avatars.avatar_of(blake_id)
	var spot: Vector3 = main.session_scene_root().global_transform * Vector3(600.0, 0.0, 100.0)
	_check(not drawn.is_empty() and (drawn["cursor"] as Node3D).visible and (drawn["cursor"] as Node3D).global_position.distance_to(spot) < 1e-3, "Blake's cursor is drawn where their presence says, through this person's view of the model")
	_check((drawn["cursor_tag"] as Label3D).text == "Blake" and (drawn["material"] as StandardMaterial3D).albedo_color.is_equal_approx(Color.html(str(main.session.client.participants[blake_id]["colour"]))), "...with their name, in their colour")
	blake.send({"t": "presence", "head": _pose(0.0, 1600.0, 0.0), "hands": [null, null], "laser": null, "cursor": null, "mode": "free"})
	await _wait(0.5)
	_check(not (drawn["cursor"] as Node3D).visible, "a presence with no cursor: it goes")
	# --- it never touches the presenter's state
	var sent: Array = (hub.sent_by[me] as Array).map(func(m: Dictionary) -> String: return str(m["t"]))
	_check(sent.all(func(k: String) -> bool: return k == "presence") and not hub.ignored.has(me), "all this observer sent the hub was presence (%s)" % str(sent.slice(0, 4)))
	_check(backend.requests_to("view-tokens").is_empty() and backend.log.all(func(r: Dictionary) -> bool: return not r["headers"].has("x-api-key")), "...and no backend was asked for anything but the model")
	await main.session.leave_session()
	await process_frame
	_check(not cursor.enabled and not hands[1].has_meta("cursor_owns_stick") or not bool(hands[1].get_meta("cursor_owns_stick")), "leaving the session turns the cursor off and gives the stick back")
	quit()
