extends SceneTree
## P2: the PRESENTER side, in the real main.tscn, against tests/fake_session_hub.gd and tests/fake_session_backend.gd, with scripted observers (plain session clients) reading what
## the hub relays. Host Session's refusals (a bare file, no hub, no key, a server too old, the hub unreachable: the token is revoked), the view token (minted with the CAD key
## and document session, revoked at End), what the hub is told (no CAD key anywhere), and then every kind of message the presenter streams: the full pose table, a moved part
## (only that part, rate-capped), hide, the section plane in model space, the model's place, status, doc_changed with the revision from the response headers (or one cheap probe),
## a model opened while hosting (a demo by path, a bare file refused), a drop and resume (the full state again), a renewed token, a token the backend lost, and End.
## NOT covered: a real hub or backend (tests/e2e_session_presenter.gd), the headset.
## Run: "$GODOT" --headless --path . --script res://tests/session_presenter.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const DocumentRevision := preload("res://scripts/session/document_revision.gd")
const P := preload("res://scripts/session/session_protocol.gd")
const GLB := "res://tests/fixtures/session_assembly.glb"
const DEMO := "res://demo/spacecraft/Pioneer_10.glb"

var hub: RefCounted
var backend: RefCounted
var main: Node
var observer: Node
var seen: Array = [] ## every message the scripted observer has been sent (relayed)


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _of(kind: String, from: int = 0) -> Array:
	return seen.slice(from).filter(func(m: Dictionary) -> bool: return m.get("t", "") == kind)


func _part(path: String) -> Node3D:
	for node in main.session_world_parts():
		if str(node.get_meta("instance_path", "?")) == path:
			return node
	return null


func _initialize() -> void:
	hub = Hub.new()
	backend = Backend.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.use_transport(hub.make_transport)
	main.session.http.transport = backend.handle
	var bytes := FileAccess.get_file_as_bytes(GLB)
	# --- nothing to share yet
	_check(not main.session.hostable_model()["ok"] and str(main.session.hostable_model()["error"]).contains("Open a model first"), "with no model open there is nothing to host, and it says what to open")
	main._show_model(bytes, "", main.spawn_scale, true) # a bare glb, as if opened from a folder
	var bare: Dictionary = main.session.hostable_model()
	_check(not bare["ok"] and str(bare["error"]).contains("cannot be shared"), "a bare glb opened from a folder cannot be hosted (decision LS-9): it would mean sending a file")
	main._resolved_part_id = "part-root"
	main.backend_url = "https://cad.test"
	main.api_key = backend.key
	_check(main.session.hostable_model()["ok"] and main.session.hostable_model()["source"]["kind"] == "backend" and main.session.hostable_model()["source"]["root_part_id"] == "part-root", "a document on the backend can be hosted")
	# --- the hub: none, no key, unreachable, advertised
	var none: Dictionary = await main.session.host_session()
	_check(not none["ok"] and str(none["error"]).contains("No session hub is set") and backend.requests_to("view-tokens").is_empty(), "no hub set: it says so and no read-only link was minted (nothing to clean up)")
	main.hub_url = "wss://hub.test"
	var nokey: Dictionary = await main.session.host_session()
	_check(not nokey["ok"] and str(nokey["error"]).contains("key is missing"), "a hub with no key: the words say the key is missing")
	main.hub_url = ""
	main.hub_key = hub.key
	var health_hub: Dictionary = await main.session.resolve_hub()
	_check(not health_hub["ok"] and str(health_hub["error"]).contains("No session hub is set"), "a key but no address, and the server advertises none: no hub")
	backend.hub_advertised = "wss://hub.test"
	main.session.advertised_hub.clear()
	var advertised: Dictionary = await main.session.resolve_hub()
	_check(advertised["ok"] and advertised["url"] == "wss://hub.test" and advertised["source"] == "health" and advertised["key"] == hub.key, "the address /health advertises is used with the saved key")
	_check(not backend.requests_to("/health").is_empty() and not backend.log[-1]["headers"].has("x-view-token"), "...asked of the server with the CAD key")
	main.hub_url = "ws://hub.example.com" # plain ws:// to the internet
	var plain: Dictionary = await main.session.host_session()
	_check(not plain["ok"] and str(plain["error"]).contains("not allowed"), "a plain ws:// hub on the internet is refused by the address rules")
	main.hub_url = "wss://hub.test"
	# --- the backend says no
	backend.mint_status = 404
	var old_server: Dictionary = await main.session.host_session()
	_check(not old_server["ok"] and str(old_server["error"]).contains("too old") and hub.rooms.is_empty(), "a server with no view tokens: 'too old, update DIDSA-CAD', and no room was made")
	backend.mint_status = 500
	var broken: Dictionary = await main.session.host_session()
	_check(not broken["ok"] and str(broken["error"]).contains("500") and hub.rooms.is_empty(), "a server error is shown with its status")
	backend.mint_status = 201
	backend.offline = true
	var down: Dictionary = await main.session.host_session()
	_check(not down["ok"] and str(down["error"]).contains("could not be reached"), "an unreachable server is said to be unreachable")
	backend.offline = false
	hub.connect_failures = 1
	var minted_before: int = backend.requests_to("view-tokens").filter(func(r: Dictionary) -> bool: return r["method"] == HTTPClient.METHOD_POST).size()
	var hub_down: Dictionary = await main.session.host_session()
	var deleted: Array = backend.requests_to("view-tokens").filter(func(r: Dictionary) -> bool: return r["method"] == HTTPClient.METHOD_DELETE)
	_check(not hub_down["ok"] and minted_before >= 0 and not backend.revoked.is_empty() and deleted.size() == backend.revoked.size() and not main.session.is_active(), "the hub unreachable after a token was minted: the token is revoked, nothing is left running")
	# --- hosting
	var hosted: Dictionary = await main.session.host_session()
	_check(hosted["ok"] and main.session.role == "presenter" and main.session.is_presenter() and P.code_is_valid(main.session.code()), "Host Session: a presenter with a well-formed code")
	var mint: Dictionary = backend.requests_to("view-tokens").filter(func(r: Dictionary) -> bool: return r["method"] == HTTPClient.METHOD_POST)[-1]
	_check(mint["headers"].get("x-api-key", "") == backend.key and str(mint["headers"].get("x-document-session", "")).begins_with("vr-") and JSON.parse_string(mint["body"])["root_part_id"] == "part-root", "the token is minted with the CAD key and this app's document session, for the root part")
	var room: Dictionary = hub.only_room()
	_check(room["model"]["kind"] == "backend" and room["model"]["root_part_id"] == "part-root" and room["model"]["title"] == "Gearbox" and room["backend_url"] == "https://cad.test" and room["view_token"] != "", "the hub was told the model (titled with the root part's name, not a file), the backend's address and the token")
	_check(not JSON.stringify(hub.sent_by[1]).contains(backend.key) and not JSON.stringify(room).contains(backend.key) and not JSON.stringify(hub.received_by[1]).contains(backend.key), "the CAD key is in nothing the hub was sent")
	_check(not main.session.join_uri.is_empty() and main.session.status_line().begins_with("Hosting "), "the join link and a status line are there")
	_check(not main.session_hands()[0].view_only and not main.session_hands()[1].view_only and main._two_hand.enabled, "a presenter keeps every tool")
	var token: String = room["view_token"]
	# --- a scripted observer
	observer = Client.new()
	observer.transport_factory = hub.make_transport
	root.add_child(observer)
	observer.message_received.connect(func(m: Dictionary) -> void: seen.append(m))
	observer.token_changed.connect(func(tok: String, _e: float) -> void: seen.append({"t": "token", "view_token": tok})) # (the client keeps a token to itself; this logs it)
	observer.join("wss://hub.test", main.session.code(), {"name": "Blake", "device": "phone", "client": "test"})
	await _wait(0.3)
	var snap: Dictionary = observer.snapshot
	var table := {}
	for item in snap["poses"]:
		table[item["path"]] = item["xf"]
	_check(observer.is_live() and observer.view_token == token and observer.backend_url == "https://cad.test", "an observer is handed the token and the address")
	_check(table.size() == 3 and table.has("") and table.has("occ-bolt") and table.has("occ-nut"), "the pose table has all three parts under their instance paths")
	_check(table["occ-bolt"][9] == 30.0 and table["occ-nut"][10] == 30.0 and table[""][9] == 0.0, "...in model space, millimetres (the cubes sit 30 mm out)")
	_check(snap["place"]["xf"][0] == 0.001 and absf(float(snap["place"]["xf"][10]) - float(main.spawn_position.y)) < 1e-3, "the model's place carries its 0.001 scale and where it stands")
	_check(snap["visibility"]["hidden"].is_empty() and snap["section"]["on"] == false and snap["status"]["activity"] == "model", "visibility, section and status are in the snapshot")
	var first_seq: int = int(snap["place"]["seq"])
	_check(first_seq >= 1, "state messages carry a seq")
	# --- a moved part: only that part, and not more often than 30 Hz
	seen.clear()
	var bolt := _part("occ-bolt")
	bolt.global_position += Vector3(0.01234, 0.0, 0.0)
	await _wait(0.5)
	var moved := _of("poses")
	_check(not moved.is_empty() and moved.all(func(m: Dictionary) -> bool: return not m["full"]), "a part moved: partial pose messages, not a full table")
	var only_bolt: bool = moved.all(func(m: Dictionary) -> bool: return m["items"].size() == 1 and m["items"][0]["path"] == "occ-bolt")
	_check(only_bolt and absf(float(moved[-1]["items"][0]["xf"][9]) - 42.34) < 0.02, "...carrying only that part, at its new place in mm (%s)" % str(moved[-1]["items"][0]["xf"][9] if not moved.is_empty() else "none"))
	seen.clear()
	await _wait(0.6)
	_check(_of("poses").is_empty(), "nothing moves: nothing is sent")
	# the hot path: parts that are moving are read every frame (30 Hz), whoever announced them (the controller's grab and _sync_pose, the mates glide: "session_listeners")
	var nut := _part("occ-nut")
	var left: Node = main.session_hands()[0]
	left.held_node = nut # (a hand holding a part marks it hot by itself; the controller then carries it, so this check ends before it moves anything)
	await process_frame
	await process_frame
	_check(main.session.publisher._hot.has("occ-nut"), "a part a hand is holding is in the hot set")
	left.held_node = null
	await _wait(0.2)
	seen.clear()
	var started := Time.get_ticks_msec()
	var frames := 0
	while Time.get_ticks_msec() - started < 1000:
		nut.global_position += Vector3(0.0, 0.0001, 0.0)
		get_root().get_tree().call_group("session_listeners", "on_parts_moving", [nut])
		frames += 1
		await process_frame
	await _wait(0.2)
	var held_messages := _of("poses")
	var expected_rate := mini(frames, 30)
	_check(held_messages.size() >= int(expected_rate * 0.6) and held_messages.size() <= 36, "a moving part streams at up to 30 Hz, a message a frame when frames are slower (%d messages, %d frames, in about a second)" % [held_messages.size(), frames])
	var final_y := float(held_messages[-1]["items"][0]["xf"][10])
	var expect_y: float = (main.session_scene_root().global_transform.affine_inverse() * nut.global_transform).origin.y
	_check(absf(final_y - expect_y) < 0.02, "...and the last one is where the part ended (y %.2f mm)" % final_y)
	# --- hide
	seen.clear()
	bolt.visible = false
	await _wait(0.5)
	var hidden_msgs := _of("visibility")
	_check(hidden_msgs.size() == 1 and hidden_msgs[0]["hidden"] == ["occ-bolt"], "a hidden part: the full hidden list, once")
	bolt.visible = true
	nut.visible = false
	main.room_manager._seed_hidden[999] = [nut] # hidden because a room opened on it
	seen.clear()
	await _wait(0.5)
	_check(_of("visibility").size() == 1 and _of("visibility")[0]["hidden"].is_empty(), "a part hidden by a room (or seated on the design table) is not copied to observers")
	main.room_manager._seed_hidden.erase(999)
	nut.visible = true
	await _wait(0.4)
	# --- the section plane
	seen.clear()
	main._section_tool.set_remote_plane(true, Vector3(0.03, 1.0, -1.0), Vector3(1, 0, 0), main.get_node("XROrigin3D/XRCamera3D"))
	await _wait(0.5)
	var cut := _of("section")
	_check(cut.size() == 1 and cut[0]["on"] == true and absf(float(cut[0]["point"][0]) - 30.0) < 0.1 and absf(float(cut[0]["point"][1])) < 0.1 and absf(float(cut[0]["normal"][0]) - 1.0) < 1e-3, "the section plane goes out in model space (a plane 30 mm out along x, facing +x)")
	seen.clear()
	main._section_tool.set_active(false)
	await _wait(0.5)
	_check(_of("section").size() == 1 and _of("section")[0]["on"] == false, "turning the section off says so")
	# --- the model's place
	seen.clear()
	main.assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.002), Vector3(1.0, 1.0, -2.0))
	await _wait(0.5)
	var placed := _of("place")
	_check(placed.size() == 1 and absf(float(placed[0]["xf"][0]) - 0.002) < 1e-9 and absf(float(placed[0]["xf"][9]) - 1.0) < 1e-3 and absf(float(placed[0]["xf"][11]) + 2.0) < 1e-3, "moving and scaling the model sends its new place (scale included)")
	_check(_of("poses").is_empty(), "...and, since the parts did not move in model space, no poses")
	# --- status
	seen.clear()
	main.design_table._open = true
	await _wait(0.5)
	var at_table := _of("status")
	_check(at_table.size() == 1 and at_table[0]["activity"] == "design_table", "the design table opening is a status: 'at the design table'")
	main.design_table._open = false
	var stub_script := GDScript.new()
	stub_script.source_code = "extends Node3D\nvar handles = null\nfunc update_reveal(_hands) -> void:\n\tpass\n"
	stub_script.reload()
	var dummy_room := Node3D.new()
	dummy_room.set_script(stub_script)
	main.room_manager.rooms.append(dummy_room)
	seen.clear()
	await _wait(0.5)
	_check(_of("status").size() == 1 and _of("status")[0]["activity"] == "room", "an Assembly Room open is 'room'")
	main.room_manager.rooms.erase(dummy_room)
	dummy_room.free()
	seen.clear()
	await _wait(0.5)
	_check(_of("status")[-1]["activity"] == "model", "and back to 'model'")
	# --- a changed document: the revision from a response header, then a probe
	seen.clear()
	backend.bump()
	DocumentRevision.note(PackedStringArray(["X-Document-Revision: %d" % backend.rev, "Content-Type: x"])) # what the design table's client does with its own response
	var probes_before: int = backend.requests_to("/document/view-state").size()
	_check(main.swap_part_mesh([bolt], bytes) == 1, "a part's mesh is swapped (as after a design-table edit)")
	main.swap_part_mesh([nut], bytes)
	await _wait(0.8)
	var changed := _of("doc_changed")
	_check(changed.size() == 1 and changed[0]["rev"] == backend.rev and changed[0]["parts"].has("part-bolt") and changed[0]["parts"].has("part-nut") and not changed[0].has("all"), "two swaps close together are ONE doc_changed, naming both parts, with the revision from the response header")
	_check(backend.requests_to("/document/view-state").size() == probes_before, "...and no extra call was needed to learn the revision")
	seen.clear()
	backend.bump() # a change nobody noted
	main.swap_part_mesh([bolt], bytes)
	await _wait(0.8)
	changed = _of("doc_changed")
	var probes: Array = backend.requests_to("/document/view-state").slice(probes_before)
	_check(changed.size() == 1 and changed[0]["rev"] == backend.rev and probes.size() == 1 and probes[0]["headers"].get("x-api-key", "") == backend.key and not probes[0]["headers"].has("x-view-token"), "a change that no response announced costs one cheap probe, made with the key, and the revision is read from its header (%d)" % backend.rev)
	seen.clear()
	main.session_doc_changed.emit([], true)
	await _wait(0.8)
	changed = _of("doc_changed")
	var after_full := _of("poses")
	_check(changed.size() == 1 and changed[0]["all"] == true and not changed[0].has("parts"), "a refetched world is doc_changed with all")
	_check(not after_full.is_empty() and after_full[0]["full"] == true and after_full[0]["items"].size() == 3, "...followed by the full pose table (observers apply it after their own refetch)")
	seen.clear()
	main._appearance_tool.document_changed.emit()
	await _wait(0.8)
	_check(_of("doc_changed").size() == 1 and _of("doc_changed")[0]["all"] == true, "a real paint is a document change for observers")
	seen.clear()
	main._mates_tool.document_changed.emit()
	await _wait(0.5)
	_check(_of("doc_changed").is_empty(), "a mate is not: its motion arrives as poses, and the mesh has not changed")
	# --- another model while hosting
	seen.clear()
	main.document_is_demo = false
	main.mark_clean() # (the swaps and the paint above raised "unsaved changes": a load would ask first)
	main.load_glb_file(DEMO)
	await _wait(1.2)
	var model_msgs := _of("model")
	_check(model_msgs.size() == 1 and model_msgs[0]["source"] == {"kind": "demo", "path": DEMO, "rev": model_msgs[0]["source"].get("rev", 0)} or (model_msgs.size() == 1 and model_msgs[0]["source"]["kind"] == "demo" and model_msgs[0]["source"]["path"] == DEMO), "opening a demo while hosting sends the new model by its path")
	var demo_poses := _of("poses")
	var demo_nodes: Array = main.session_world_parts()
	_check(not demo_poses.is_empty() and demo_poses[-1]["full"] == true and demo_poses[-1]["items"].size() == demo_nodes.size(), "...and its full pose table (%d parts)" % demo_nodes.size())
	var first_demo: Node3D = demo_nodes[0]
	var key: String = str(main.session.publisher.part_key(first_demo, main.session_scene_root()))
	var demo_item := {}
	for m in demo_poses:
		for item in m["items"]:
			if item["path"] == key:
				demo_item = item
	var expect_mm: Vector3 = (main.session_scene_root().global_transform.affine_inverse() * first_demo.global_transform).origin * 1000.0
	_check(not demo_item.is_empty() and absf(float(demo_item["xf"][9]) - expect_mm.x) < 0.02 and absf(float(demo_item["xf"][10]) - expect_mm.y) < 0.02, "a demo's poses are in millimetres too (a demo glb is in metres)")
	seen.clear()
	main._resolved_part_id = ""
	main.document_is_demo = false
	main._show_model(bytes, "", main.spawn_scale, true)
	await _wait(1.0)
	var refused := _of("status")
	_check(refused.size() >= 1 and refused[-1]["activity"] == "files" and _of("model").is_empty() and _of("poses").is_empty(), "a bare file opened while hosting is not shared: the observers are told, and keep the old model")
	main._resolved_part_id = "part-root"
	seen.clear()
	main._show_model(bytes, "", main.spawn_scale)
	await _wait(1.2)
	_check(_of("model").size() == 1 and _of("model")[0]["source"]["kind"] == "backend" and _of("poses").size() >= 1, "going back to the document sends the model and its poses again")
	# --- a drop and a resume: the full state again
	seen.clear()
	hub.drop(1)
	await _wait(0.3)
	_check(not observer.presenter_connected(), "the observer is told the presenter dropped")
	await _wait(2.0)
	_check(main.session.client.is_live() and observer.presenter_connected(), "the presenter resumes")
	var again := {"poses": _of("poses"), "place": _of("place"), "visibility": _of("visibility"), "section": _of("section"), "status": _of("status")}
	_check(not again["poses"].is_empty() and again["poses"][0]["full"] == true and not again["place"].is_empty() and not again["visibility"].is_empty() and not again["section"].is_empty() and not again["status"].is_empty(), "after a resume it sends place, section, visibility, status and the full pose table again")
	# --- tokens
	var live_before: int = backend.tokens.size()
	seen.clear()
	_check(await main.session.renew_token(), "the presenter can mint a fresh token")
	await _wait(0.3)
	_check(backend.tokens.size() == live_before + 1 and _of("token").size() == 1 and observer.view_token == _of("token")[0]["view_token"] and observer.view_token != token, "...and the observers are given it")
	var lost: String = observer.view_token
	backend.tokens.erase(lost) # the backend restarted: it has forgotten every token
	seen.clear()
	await main.session.check_token_alive()
	await _wait(0.3)
	_check(_of("token").size() == 1 and observer.view_token != lost and backend.tokens.has(observer.view_token), "a token the backend has forgotten is noticed (a 401 as an observer would get) and replaced")
	# --- End
	var minted_all: Array = backend.tokens.keys()
	var end_seen := []
	observer.closed.connect(func(kind: String, text: String) -> void: end_seen.append([kind, text]))
	await main.session.end_session()
	await _wait(0.3)
	_check(main.session.role == "" and not main.session.is_active() and hub.rooms.is_empty(), "End: the app is no longer hosting and the hub forgot the room")
	_check(backend.tokens.is_empty() and minted_all.all(func(t: String) -> bool: return backend.revoked.has(t)), "...and every token this session minted was revoked at the backend")
	_check(not end_seen.is_empty() and end_seen[0][0] == "ended" and str(end_seen[0][1]).contains("ended"), "...and the observers were told the session ended")
	var after: Variant = backend.handle(HTTPClient.METHOD_GET, "https://cad.test/document/parts/part-root/assembly-mesh.glb?quality=0.5", ["X-View-Token: " + lost], "")
	_check((await after)["code"] == 401, "a revoked token reads nothing")
	# --- hosting a demo (no token, no backend)
	main.backend_url = ""
	main.api_key = ""
	main.document_is_demo = false
	main._resolved_part_id = ""
	main.mark_clean()
	main.load_glb_file(DEMO)
	var demo_host: Dictionary = await main.session.host_session()
	var demo_room: Dictionary = hub.only_room()
	var posts: Array = backend.requests_to("view-tokens").filter(func(r: Dictionary) -> bool: return r["method"] == HTTPClient.METHOD_POST)
	_check(demo_host["ok"] and demo_room["model"]["kind"] == "demo" and demo_room["model"]["path"] == DEMO and demo_room["view_token"] == "" and demo_room["backend_url"] == "", "a demo is hosted by its path: no token, no backend address")
	await main.session.end_session()
	_check(posts.size() == backend.requests_to("view-tokens").filter(func(r: Dictionary) -> bool: return r["method"] == HTTPClient.METHOD_POST).size(), "...and nothing was asked of a backend for it")
	quit()
