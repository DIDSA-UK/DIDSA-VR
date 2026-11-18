extends SceneTree
## P2b: the other people, drawn (scripts/session/session_avatars.gd; decision D6, scope 4.4 and 4.8), in the real main.tscn hosting through the fake hub, with scripted observers sending
## presence. One avatar per other person, never your own; a head, two controllers, the laser and a name tag that faces the viewer; one colour each (the hub's palette); put into the world
## through THIS person's view of the model (a different scale and place give a different world spot for the same model-space pose) while keeping a person's own size; a hand or laser that is not
## sent is not drawn; smoothed one interval behind (halfway, past the newest, a gap snaps); hidden while the hub says they are not connected, drawn at once for a late joiner from the welcome's
## snapshot, gone when they leave; the presenter's star and "(following)". Headless: it reads the nodes' transforms and text, not a picture.
## Run: "$GODOT" --headless --path . --script res://tests/session_avatars.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Avatars := preload("res://scripts/session/session_avatars.gd")
const P := preload("res://scripts/session/session_protocol.gd")

var main: Node
var hub: RefCounted
var backend: RefCounted


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _pose(x: float, y: float, z: float, yaw_deg: float = 0.0) -> Array:
	var q := Quaternion(Vector3.UP, deg_to_rad(yaw_deg))
	return [x, y, z, q.x, q.y, q.z, q.w]


func _presence(client: Node, head: Array, hands: Array = [null, null], laser = null, mode: String = "free") -> void:
	client.send({"t": "presence", "head": head, "hands": hands, "laser": laser, "cursor": null, "mode": mode})


func _joined(code: String, name: String) -> Node:
	var c := Client.new()
	c.transport_factory = hub.make_transport
	root.add_child(c)
	c.join("wss://hub.test", code, {"name": name, "device": "phone", "client": "t"})
	return c


func _initialize() -> void:
	# --- the pure parts
	var track := {"a": {"at": 1000.0, "head": _pose(0, 0, 0, 0), "hands": [null, null], "laser": null, "mode": "free"}, "b": {"at": 1070.0, "head": _pose(100, 0, 0, 90), "hands": [_pose(10, 10, 10), null], "laser": [0, 0, 100], "mode": "free"}}
	var half := Avatars.sample_at(track, 1035.0)
	_check(absf(half["head"][0] - 50.0) < 1e-6 and absf(Quaternion(half["head"][3], half["head"][4], half["head"][5], half["head"][6]).get_euler().y - deg_to_rad(45.0)) < 1e-3, "halfway between two samples: halfway in position and rotation")
	_check(Avatars.sample_at(track, 2000.0)["head"][0] == 100.0 and Avatars.sample_at(track, 500.0)["head"][0] == 0.0, "past the newest: the newest; before the older: the older")
	_check(half["hands"][0] != null and half["hands"][1] == null and half["laser"] != null, "a hand present in one sample only is the newer sample's (no blend with nothing)")
	var gap := {"a": track["a"], "b": {"at": 1700.0, "head": _pose(100, 0, 0), "hands": [null, null], "laser": null, "mode": "free"}}
	_check(Avatars.sample_at(gap, 1300.0)["head"][0] == 100.0, "samples more than 500 ms apart: no tween, the newer")
	_check(Avatars.tag_text({"name": "Alex", "role": "presenter"}, "free") == "★ Alex" and Avatars.tag_text({"name": "Blake", "role": "observer"}, "following") == "Blake (following)", "the presenter has a star; someone riding the presenter's view says so")
	var frame := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.002).rotated(Vector3.UP, deg_to_rad(90.0)), Vector3(1.0, 1.0, -2.0))
	var world: Transform3D = Avatars.world_of(_pose(100.0, 1600.0, 200.0, 0.0), frame, 1.0)
	_check(world.origin.distance_to(frame * Vector3(100.0, 1600.0, 200.0)) < 1e-6 and absf(world.basis.get_scale().x - 1.0) < 1e-6, "a model-space pose goes through the model's own transform (scale and turn), and the result is not scaled: a person stays a person's size")
	_check(Avatars.world_of([1, 2, 3], frame, 1.0) == null and Avatars.world_of(null, frame, 1.0) == null, "a malformed pose is not drawn")
	# --- the world
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
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.002), Vector3(1.0, 1.0, -2.0))
	var hosted: Dictionary = await main.session.host_session()
	_check(hosted["ok"], "hosting")
	var avatars: Node3D = main.session.avatars
	var code: String = main.session.code()
	var blake := _joined(code, "Blake")
	await _wait(0.4)
	_check(avatars.avatar_ids().is_empty(), "nobody has sent presence: nobody is drawn")
	_presence(blake, _pose(100.0, 1600.0, 200.0, 0.0), [_pose(150.0, 1400.0, 100.0), _pose(50.0, 1400.0, 100.0)], [50.0, 1400.0, -300.0])
	await _wait(0.5)
	var bid: int = int(blake.me["id"])
	var parts: Dictionary = avatars.avatar_of(bid)
	_check(not parts.is_empty() and avatars.avatar_ids() == [bid], "presence from one person: one avatar, theirs")
	var scene_frame: Transform3D = main.session_scene_root().global_transform
	var head_expected: Vector3 = scene_frame * Vector3(100.0, 1600.0, 200.0)
	_check((parts["head"] as Node3D).global_position.distance_to(head_expected) < 1e-3 and avatars.heads[bid].origin.distance_to(head_expected) < 1e-3, "its head is where the model-space pose says, through this model's scale and place (%s)" % str((parts["head"] as Node3D).global_position))
	_check(absf((parts["head"] as Node3D).global_transform.basis.get_scale().x - 1.0) < 1e-4 and (parts["root"] as Node3D).visible, "...at a person's size, not the model's (the model is at 1:500 here)")
	_check((parts["tag"] as Label3D).text == "Blake" and (parts["tag"] as Label3D).billboard == BaseMaterial3D.BILLBOARD_ENABLED and (parts["tag"] as Label3D).global_position.y > (parts["head"] as Node3D).global_position.y + 0.15, "a name tag above the head that turns to face the viewer")
	_check((parts["material"] as StandardMaterial3D).albedo_color.is_equal_approx(Color.html("#1C7ED6")) and (parts["tag"] as Label3D).modulate.is_equal_approx(Color.html("#1C7ED6")), "in the colour the hub gave them")
	_check((parts["left"] as Node3D).visible and (parts["right"] as Node3D).visible and (parts["left"] as Node3D).global_position.distance_to(scene_frame * Vector3(150.0, 1400.0, 100.0)) < 1e-3, "two controllers, at their poses")
	var laser: MeshInstance3D = parts["laser"]
	var tip: Vector3 = scene_frame * Vector3(50.0, 1400.0, -300.0)
	var from: Vector3 = (parts["right"] as Node3D).global_position
	_check(laser.visible and absf((parts["laser_mesh"] as CylinderMesh).height - from.distance_to(tip)) < 1e-3 and laser.global_position.distance_to((from + tip) * 0.5) < 1e-3, "the laser runs from the right hand to its end (%.2f m)" % (parts["laser_mesh"] as CylinderMesh).height)
	_presence(blake, _pose(100.0, 1600.0, 200.0, 0.0), [_pose(150.0, 1400.0, 100.0), null], null)
	await _wait(0.5)
	_check((parts["left"] as Node3D).visible and not (parts["right"] as Node3D).visible and not (parts["laser"] as Node3D).visible, "a hand that is not sent is not drawn; no laser sent, no laser")
	_check(avatars.heads.has(int(main.session.client.me["id"])) == false and not avatars.avatar_ids().has(int(main.session.client.me["id"])), "this person is never drawn")
	main.session.client.presence_received.emit({"from": int(main.session.client.me["id"]), "at": 1.0, "head": _pose(0, 0, 0), "hands": [null, null], "laser": null, "mode": "free"})
	await process_frame
	_check(not avatars.avatar_ids().has(int(main.session.client.me["id"])), "...even if its own presence were echoed")
	# --- a second person, a late joiner and the snapshot
	var casey := _joined(code, "Casey")
	await _wait(0.3)
	_presence(casey, _pose(-200.0, 1500.0, 0.0, 180.0), [null, null], null, "following")
	await _wait(0.5)
	var cid: int = int(casey.me["id"])
	_check(avatars.avatar_ids().size() == 2 and (avatars.avatar_of(cid)["material"] as StandardMaterial3D).albedo_color.is_equal_approx(Color.html("#2F9E44")) and (avatars.avatar_of(cid)["tag"] as Label3D).text == "Casey (following)", "a second person: their own colour, and 'following' on the tag")
	_check(not (avatars.avatar_of(cid)["left"] as Node3D).visible and not (avatars.avatar_of(cid)["laser"] as Node3D).visible, "...with no hands drawn (a phone has none)")
	# --- smoothing at run time: it ends where they are
	_presence(blake, _pose(400.0, 1600.0, 200.0, 0.0))
	await _wait(0.4)
	_check((avatars.avatar_of(bid)["head"] as Node3D).global_position.distance_to(scene_frame * Vector3(400.0, 1600.0, 200.0)) < 1e-3, "after a move it arrives where they are")
	# --- the hub says they dropped; they come back; they leave
	hub.drop(bid)
	await _wait(0.4)
	_check(not (avatars.avatar_of(bid)["root"] as Node3D).visible, "a person the hub says is not connected is not drawn")
	await _wait(2.5)
	_presence(blake, _pose(400.0, 1600.0, 200.0, 0.0))
	await _wait(0.5)
	_check((avatars.avatar_of(bid)["root"] as Node3D).visible and blake.is_live(), "...and is drawn again when they are back and send presence")
	blake.leave()
	await _wait(0.4)
	_check(not avatars.avatar_ids().has(bid) and avatars.avatar_ids().has(cid), "a person who leaves is gone (and the others stay)")
	# --- a late joiner is shown the people already there at once
	var late := _joined(code, "Dana")
	await _wait(0.1)
	var late_seen: Array = []
	late.presence_received.connect(func(m: Dictionary) -> void: late_seen.append(m))
	await _wait(0.5)
	_check(late.snapshot.has("presence") and late.snapshot["presence"].has(str(cid)), "the hub's welcome carries each person's last presence (what the avatars draw a late joiner from)")
	# --- no model: nothing drawn; End: all gone
	var model_root: Node3D = main.session_scene_root()
	main.assembly_root.remove_child(model_root)
	await _wait(0.2)
	_check(not (avatars.avatar_of(cid)["root"] as Node3D).visible, "with no model open there is no model space: nobody is drawn")
	main.assembly_root.add_child(model_root)
	await _wait(0.3)
	_check((avatars.avatar_of(cid)["root"] as Node3D).visible, "...and they are back with the model")
	await main.session.end_session()
	await process_frame
	_check(avatars.avatar_ids().is_empty() and avatars.get_child_count() == 0 or avatars.get_children().all(func(n: Node) -> bool: return n.is_queued_for_deletion()), "End: every avatar is removed")
	quit()
