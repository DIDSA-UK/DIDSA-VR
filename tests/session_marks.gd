extends SceneTree
## P4.3: SHARE, PING, LOOK HERE and RAISE HAND (scripts/session/session_marks.gd; decision D7, DIDSA-CAD docs/live-sessions-scope.md 4.5), the app as an OBSERVER joining a scripted presenter on
## tests/fake_session_hub.gd (which now keeps and relays marks as the real hub does: hub.py `_on_mark`), with a second scripted observer (Blake). Covered: Share sends the cursor's selection as a
## `mark` (`client.send`: no `seq`, never a state message; kind share, the target in the wire's shape, the sender's colour stamped by the hub) and draws it for the sender too (brackets and a
## name); a new share replaces the old one; Stop sharing clears it for everyone; nothing selected is refused in words; Ping (a point in model mm, three seconds) and Look here (ten seconds, the
## selection and the point); Raise hand (the roster's `hand`, and on the name tag); other people's marks drawn here (a share round the named part, a ping ring, a look-here arrow) in their colour
## with their name, and gone when cleared, expired, or the sender leaves; a late joiner is shown the live shares from the welcome's snapshot; the presenter's `marks_clear` clears everything
## and an observer's is dropped by the hub; a mark for a part that is not here is kept, not drawn; a malformed mark is ignored. NOT covered: a real hub (tests/e2e_session_observer.gd), a headset.
## Run: "$GODOT" --headless --path . --script res://tests/session_marks.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const BENCH := 1.2

var hub: RefCounted
var backend: RefCounted
var main: Node
var presenter: Node
var blake: Node
var cursor: Node3D
var marks: Node3D
var aim_origin := Vector3.ZERO
var aim_direction := Vector3(0, 0, -1)
var code := ""


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _part(path: String) -> Node3D:
	for node in main.session_world_parts():
		if str(node.get_meta("instance_path", "?")) == path:
			return node
	return null


func _aim_cursor(origin: Vector3, distance: float) -> void:
	aim_origin = origin
	cursor.distance = distance
	for i in 3:
		await physics_frame
	cursor.refresh()


func _drawn(mark: Dictionary, name: String) -> Node:
	return (mark["visuals"] as Dictionary).get(name)


func _initialize() -> void:
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
	code = str(presenter.room["code"])
	presenter.send_state({"t": "place", "xf": [0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 0.02, 0.0, BENCH, 0.0]})
	presenter.send_state({"t": "poses", "full": true, "items": [{"path": "", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]}, {"path": "occ-bolt", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 30, 0, 0]}, {"path": "occ-nut", "xf": [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 30, 0]}]})
	var joined: Dictionary = await main.session.join_session("wss://hub.test", code)
	await _wait(0.5)
	_check(joined["ok"] and main.is_observer(), "an observer is in")
	blake = Client.new()
	blake.transport_factory = hub.make_transport
	root.add_child(blake)
	blake.join("wss://hub.test", code, {"name": "Blake", "device": "phone", "client": "t"})
	await _wait(0.3)
	var me: int = int(main.session.client.me["id"])
	var blake_id: int = int(blake.me["id"])
	var presenter_id: int = int(presenter.me["id"])
	cursor = main.session.cursor
	marks = main.session.marks
	cursor.aim = func() -> Dictionary: return {"origin": aim_origin, "direction": aim_direction}
	cursor.stick = func() -> Vector2: return Vector2.ZERO
	var bolt := _part("occ-bolt")
	var nut := _part("occ-nut")
	var my_colour: String = str(main.session.client.me["colour"])
	var mine: Dictionary = {}
	# --- nothing selected: refused in words
	_check(not marks.share_selection() and marks.last_line.contains("Nothing to share"), "Share with nothing picked: refused, and it says to put the cursor on a part")
	# --- Share
	cursor.set_enabled(true)
	await _aim_cursor(Vector3(0.6, BENCH, 1.0), 0.8)
	_check(marks.share_selection(), "Share: the cursor's selection is sent")
	await _wait(0.2)
	var seen: Array = hub.received_of(presenter_id, "mark")
	_check(seen.size() == 1 and seen[0]["kind"] == "share" and seen[0]["id"] == "share" and seen[0]["target"] == {"path": "occ-bolt"} and int(seen[0]["from"]) == me and not seen[0].has("seq"), "the presenter is sent a `mark` of kind share with the wire target, from this person, and no seq (it is not state)")
	_check(seen[0]["colour"] == my_colour and hub.received_of(blake_id, "mark").size() == 1 and float(seen[0]["ttl_s"]) == 0.0, "...in this person's colour (the hub's), to the other observer too, with no time limit")
	_check(hub.room_of(code)["marks"].size() == 1, "the hub keeps it for a late joiner")
	mine = marks.shared_by(me)
	_check(not mine.is_empty() and _drawn(mine, "brackets") != null and _drawn(mine, "caption") != null and str((_drawn(mine, "caption") as Label3D).text).begins_with(str(main.session.client.me["name"])), "this person sees their own share too: brackets, and their name")
	marks.refresh()
	var box: AABB = bolt.global_transform * bolt.get_aabb()
	_check(((_drawn(mine, "brackets") as Node3D).visible) and mine["visuals"]["box"].is_equal_approx(box), "...round the bolt")
	# a new share replaces the old
	await _aim_cursor(Vector3(0.0, BENCH + 0.6, 1.0), 0.8)
	marks.share_selection()
	await _wait(0.2)
	_check(marks.marks_of("share").size() == 1 and marks.shared_by(me)["target"] == {"path": "occ-nut"} and hub.room_of(code)["marks"].size() == 1, "sharing something else replaces the share (one live share each), here and at the hub")
	# stop
	_check(marks.stop_sharing(), "Stop sharing")
	await _wait(0.2)
	_check(marks.marks_of("share").is_empty() and hub.room_of(code)["marks"].is_empty() and not hub.received_of(blake_id, "mark_clear").is_empty(), "...it is gone here, at the hub, and for the other observer")
	_check(not marks.stop_sharing() and marks.last_line.contains("not sharing"), "stopping when nothing is shared says so")
	_check(not marks.clear_marks() and marks.last_line.contains("Only the presenter clears marks") and hub.messages_of(me, "marks_clear").is_empty(), "an observer is not offered Clear marks: nothing is sent")
	# --- Ping
	_check(marks.ping(), "Ping")
	await _wait(0.2)
	var pings: Array = hub.received_of(presenter_id, "mark").filter(func(m: Dictionary) -> bool: return m["kind"] == "ping")
	var expected: Vector3 = main.session_scene_root().global_transform.affine_inverse() * cursor.world_transform().origin
	_check(pings.size() == 1 and float(pings[0]["ttl_s"]) == 3.0 and pings[0]["target"].has("point") and Vector3(pings[0]["target"]["point"][0], pings[0]["target"]["point"][1], pings[0]["target"]["point"][2]).distance_to(expected) < 0.02, "a ping is a point in model mm (%s), three seconds" % str(pings[0]["target"]["point"] if not pings.is_empty() else ""))
	_check(hub.room_of(code)["marks"].is_empty(), "...and the hub does not keep it (a ping is not in the snapshot)")
	var ping_mark: Dictionary = marks.marks_of("ping")[0]
	marks.refresh()
	_check(_drawn(ping_mark, "ring") != null and (_drawn(ping_mark, "ring") as Node3D).global_position.distance_to(cursor.world_transform().origin) < 1e-3, "this person sees their own pulse at the cursor")
	ping_mark["born"] = float(ping_mark["born"]) - 3.5
	marks.refresh()
	_check(marks.marks_of("ping").is_empty(), "after its three seconds it is gone")
	# --- Look here
	_check(marks.look_here(), "Look here")
	await _wait(0.2)
	var looks: Array = hub.received_of(presenter_id, "mark").filter(func(m: Dictionary) -> bool: return m["kind"] == "look_here")
	_check(looks.size() == 1 and float(looks[0]["ttl_s"]) == 10.0 and looks[0]["target"].get("path") == "occ-nut" and looks[0]["target"].has("point"), "it names the selected part and the spot, for ten seconds (%s)" % str(looks[0]["target"] if not looks.is_empty() else ""))
	# --- Raise hand
	_check(marks.set_hand(true), "Raise hand")
	await _wait(0.2)
	_check(bool(presenter.participants[me]["hand"]) and bool(blake.participants[me]["hand"]) and marks.raised_hands() == [main.session.client.me["name"]], "the roster says this person's hand is up, to everyone")
	marks.set_hand(false)
	await _wait(0.2)
	_check(not bool(presenter.participants[me]["hand"]), "...and down")
	# --- other people's marks
	blake.send({"t": "mark", "id": "share", "kind": "share", "target": {"path": "occ-nut"}, "colour": "#000000", "ttl_s": 0})
	await _wait(0.3)
	var theirs: Dictionary = marks.shared_by(blake_id)
	var blake_colour: String = str(main.session.client.participants[blake_id]["colour"])
	marks.refresh()
	_check(not theirs.is_empty() and theirs["colour"] == blake_colour and theirs["name"] == "Blake", "Blake's share arrives: in the colour the HUB gave them (not the one they claimed), with their name")
	var nut_box: AABB = nut.global_transform * nut.get_aabb()
	_check(theirs["visuals"]["box"].is_equal_approx(nut_box) and str((_drawn(theirs, "caption") as Label3D).text).begins_with("Blake") and (_drawn(theirs, "caption") as Label3D).modulate.is_equal_approx(Color.html(blake_colour)), "...brackets round the nut, 'Blake: ...' over it, in their colour")
	nut.global_position += Vector3(0.0, 0.3, 0.0)
	marks.refresh()
	_check(theirs["visuals"]["box"].is_equal_approx(nut.global_transform * nut.get_aabb()), "the part moves: the brackets follow it")
	blake.send({"t": "mark", "id": "p1", "kind": "ping", "target": {"point": [100.0, 0.0, 0.0]}, "ttl_s": 3})
	await _wait(0.3)
	var their_ping: Array = marks.marks_of("ping")
	marks.refresh()
	_check(their_ping.size() == 1 and (_drawn(their_ping[0], "ring") as Node3D).global_position.distance_to(main.session_scene_root().global_transform * Vector3(100, 0, 0)) < 1e-3, "Blake's ping is a ring at that model-space point, in this person's own view of the model")
	blake.send({"t": "mark", "id": "look", "kind": "look_here", "target": {"point": [0.0, 0.0, 100.0]}, "ttl_s": 10})
	await _wait(0.3)
	var their_look: Dictionary = marks.marks.get("%d:look" % blake_id, {})
	marks.refresh()
	_check(marks.last_line == "Blake points something out." and not their_look.is_empty() and _drawn(their_look, "arrow") != null, "Blake's look-here: an arrow, and a line (to an observer: 'points something out')")
	# a mark for a part that is not here
	blake.send({"t": "mark", "id": "far", "kind": "share", "target": {"path": "occ-nowhere"}, "ttl_s": 0})
	blake.send({"t": "mark", "id": "bad", "kind": "scribble", "target": {"path": "occ-nut"}})
	blake.send({"t": "mark", "id": "worse", "kind": "share", "target": "occ-nut"})
	await _wait(0.3)
	marks.refresh()
	var far: Dictionary = marks.marks.get("%d:far" % blake_id, {})
	_check(not far.is_empty() and not (far["visuals"].get("brackets") is Node and is_instance_valid(far["visuals"].get("brackets"))), "a share of a part this person does not have is kept and not drawn (it appears when the part does)")
	_check(not marks.marks.has("%d:bad" % blake_id) and not marks.marks.has("%d:worse" % blake_id), "a mark of an unknown kind, or with a target that is not a target, is ignored")
	# Blake clears their own, the others stay
	blake.send({"t": "mark_clear", "id": "far"})
	await _wait(0.3)
	_check(not marks.marks.has("%d:far" % blake_id) and not marks.shared_by(blake_id).is_empty(), "Blake clears one of their marks: that one goes, their other mark stays")
	# --- a late joiner (this app, leaving and joining again) is shown the live shares at once
	await main.session.leave_session()
	await process_frame
	_check(marks.marks.is_empty(), "leaving the session: no marks left drawn")
	var again: Dictionary = await main.session.join_session("wss://hub.test", code)
	await _wait(0.6)
	_check(again["ok"] and not marks.shared_by(blake_id).is_empty(), "joining later: Blake's live share is in the welcome's snapshot and is drawn at once")
	_check(marks.marks_of("ping").is_empty() and marks.marks_of("look_here").is_empty(), "...and the pings and look-heres that came and went are not")
	# --- the presenter clears marks; an observer cannot
	blake.send({"t": "marks_clear"})
	await _wait(0.3)
	_check(hub.ignored.get(blake_id, 0) >= 1 and not marks.shared_by(blake_id).is_empty(), "an observer's `marks_clear` is dropped by the hub: Blake's share is still up")
	presenter.send({"t": "marks_clear"})
	await _wait(0.3)
	_check(marks.marks.is_empty() and main.status_text.contains("cleared the marks"), "the presenter's `marks_clear`: every mark goes, and a line says so")
	_check(hub.room_of(code)["marks"].is_empty(), "...at the hub too")
	# --- a share goes when its sender leaves
	blake.send({"t": "mark", "id": "share", "kind": "share", "target": {"path": "occ-nut"}, "ttl_s": 0})
	await _wait(0.3)
	_check(not marks.shared_by(blake_id).is_empty(), "Blake shares again")
	blake.leave()
	await _wait(0.4)
	_check(marks.marks.is_empty() and hub.room_of(code)["marks"].is_empty(), "Blake leaves: their share goes with them")
	# --- what this observer sent
	var kinds: Array = (hub.sent_by[int(main.session.client.me["id"])] as Array).map(func(m: Dictionary) -> String: return str(m["t"]))
	_check(kinds.all(func(k: String) -> bool: return ["presence", "mark", "mark_clear", "hand"].has(k)) and not hub.ignored.has(int(main.session.client.me["id"])), "an observer sent the hub only what an observer may (presence, mark, mark_clear, hand): nothing was dropped (%s)" % str(kinds.filter(func(k: String) -> bool: return k != "presence")))
	quit()
