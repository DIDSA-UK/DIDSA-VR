extends SceneTree
## P4.3, the PRESENTER's half of marks (scripts/session/session_marks.gd), the app hosting through tests/fake_session_hub.gd with scripted observers: a raised hand is said in a line and on the
## person's name tag ("(hand up)") and listed; an observer's share is drawn here; Clear marks (the presenter's button: `marks_clear`, no `seq`, no ids = all) clears every mark here, at the hub and
## for every observer, and an observer cannot send it; a Look here is said in words ("asks you to look here") and `go_to_look_here` puts the presenter 1 m short of the spot, facing it, at their
## own eye height; the presenter can Ping from the laser. NOT covered: a real hub (tests/e2e_session_presenter.gd), a headset.
## Run: "$GODOT" --headless --path . --script res://tests/session_marks_presenter.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Navigation := preload("res://scripts/session/session_navigation.gd")

var hub: RefCounted
var backend: RefCounted
var main: Node


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _pose(x: float, y: float, z: float) -> Array:
	return [x, y, z, 0.0, 0.0, 0.0, 1.0]


func _initialize() -> void:
	hub = Hub.new()
	backend = Backend.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.use_transport(hub.make_transport)
	main.session.http.transport = backend.handle
	main._resolved_part_id = "part-root"
	main.backend_url = "https://cad.test"
	main.api_key = backend.key
	main.hub_url = "wss://hub.test"
	main.hub_key = hub.key
	main._show_model(FileAccess.get_file_as_bytes("res://tests/fixtures/session_assembly.glb"), "", main.spawn_scale, true)
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.02), Vector3(0.0, 1.2, -1.0))
	var hosted: Dictionary = await main.session.host_session()
	_check(hosted["ok"], "hosting")
	var marks: Node3D = main.session.marks
	var code: String = main.session.code()
	var blake := Client.new()
	blake.transport_factory = hub.make_transport
	root.add_child(blake)
	blake.join("wss://hub.test", code, {"name": "Blake", "device": "phone", "client": "t"})
	var casey := Client.new()
	casey.transport_factory = hub.make_transport
	root.add_child(casey)
	casey.join("wss://hub.test", code, {"name": "Casey", "device": "phone", "client": "t"})
	await _wait(0.4)
	var blake_id: int = int(blake.me["id"])
	var casey_id: int = int(casey.me["id"])
	var me: int = int(main.session.client.me["id"])
	# --- a raised hand
	blake.send({"t": "hand", "up": true})
	await _wait(0.3)
	_check(marks.raised_hands() == ["Blake"] and marks.last_line == "Blake raised a hand." and main.status_text == "Blake raised a hand.", "Blake raises a hand: the presenter is told in a line, and it is listed")
	blake.send({"t": "presence", "head": _pose(0.0, 1600.0, 0.0), "hands": [null, null], "laser": null, "cursor": null, "mode": "free"})
	await _wait(0.5)
	var tag: Label3D = main.session.avatars.avatar_of(blake_id)["tag"]
	_check(tag.text == "Blake (hand up)", "...and it is on their name tag (%s)" % tag.text)
	blake.send({"t": "hand", "up": true})
	await _wait(0.2)
	_check(marks.last_line == "Blake raised a hand.", "a hand already up is not announced again")
	blake.send({"t": "hand", "up": false})
	await _wait(0.4)
	_check(marks.raised_hands().is_empty() and (main.session.avatars.avatar_of(blake_id)["tag"] as Label3D).text == "Blake", "the hand goes down: the list and the tag are plain again")
	# --- marks arrive; Clear marks
	blake.send({"t": "mark", "id": "share", "kind": "share", "target": {"path": "occ-nut"}, "ttl_s": 0})
	casey.send({"t": "mark", "id": "p1", "kind": "ping", "target": {"point": [0.0, 0.0, 100.0]}, "ttl_s": 3})
	await _wait(0.4)
	_check(marks.marks.size() == 2 and marks.shared_by(blake_id)["name"] == "Blake", "an observer's share and another's ping are drawn here")
	_check(not marks.share_selection() and marks.last_line.contains("Nothing to share"), "the presenter has no cursor to share with")
	var cleared_before: int = hub.received_of(blake_id, "marks_clear").size()
	_check(marks.clear_marks(), "Clear marks")
	await _wait(0.3)
	var wire: Array = hub.messages_of(me, "marks_clear")
	_check(wire.size() == 1 and not wire[0].has("ids") and not wire[0].has("seq"), "it sends `marks_clear` with no ids (all) and no seq")
	_check(marks.marks.is_empty() and hub.room_of(code)["marks"].is_empty() and hub.received_of(blake_id, "marks_clear").size() == cleared_before + 1 and not hub.received_of(casey_id, "marks_clear").is_empty(), "every mark is gone here, at the hub, and every observer is told")
	blake.send({"t": "mark", "id": "share", "kind": "share", "target": {"path": "occ-bolt"}, "ttl_s": 0})
	await _wait(0.3)
	casey.send({"t": "marks_clear"})
	await _wait(0.3)
	_check(hub.ignored.get(casey_id, 0) >= 1 and not marks.shared_by(blake_id).is_empty(), "an observer cannot clear marks: the hub drops it, the share stays")
	# --- Look here
	casey.send({"t": "mark", "id": "look", "kind": "look_here", "target": {"path": "occ-nut", "point": [0.0, 30.0, 0.0]}, "ttl_s": 10})
	await _wait(0.4)
	_check(marks.last_line == "Casey asks you to look here.", "Casey's look-here is said to the presenter in words: %s" % marks.last_line)
	var spot: Vector3 = main.session_scene_root().global_transform * Vector3(0.0, 30.0, 0.0)
	var camera: Node3D = main.session_camera()
	var eye_y: float = camera.global_position.y
	_check(marks.go_to_look_here(), "Go to the spot")
	var flat: Vector3 = camera.global_position - spot
	flat.y = 0.0
	var facing: Vector3 = spot - camera.global_position
	_check(absf(flat.length() - marks.LOOK_STAND_BACK) < 0.01 and absf(camera.global_position.y - eye_y) < 0.01, "the presenter stands 1 m short of it, at their own eye height (%.3f m)" % flat.length())
	_check(absf(wrapf(Navigation.yaw_of(camera.global_transform.basis) - Navigation.yaw_of(Basis.looking_at(Vector3(facing.x, 0.0, facing.z), Vector3.UP)), -PI, PI)) < 0.02, "...facing it")
	# --- the presenter pings from the laser
	_check(marks.ping(), "the presenter pings (the laser's end is the point)")
	await _wait(0.3)
	var pings: Array = hub.received_of(blake_id, "mark").filter(func(m: Dictionary) -> bool: return m["kind"] == "ping" and int(m["from"]) == me)
	var tip = main.session_hands()[1].laser_tip()
	var back: Vector3 = main.session_scene_root().global_transform * Vector3(pings[0]["target"]["point"][0], pings[0]["target"]["point"][1], pings[0]["target"]["point"][2])
	_check(pings.size() == 1 and tip != null and back.distance_to(tip) < 0.02, "...the observers are sent a ping at that spot (%.4f m from the laser's end)" % back.distance_to(tip))
	# --- nothing else is a state message
	var kinds: Array = hub.sent_by[me].map(func(m: Dictionary) -> String: return str(m["t"]))
	_check(not kinds.has("mark_clear") and kinds.has("marks_clear") and kinds.has("mark") and not hub.ignored.has(me), "the presenter sent marks and the clear: nothing was refused")
	await main.session.end_session()
	await process_frame
	_check(marks.marks.is_empty(), "End: no marks left")
	quit()
