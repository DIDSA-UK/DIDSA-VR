extends SceneTree
## P2: the OBSERVER side, in the real main.tscn, joining a scripted presenter (a plain session client on tests/fake_session_hub.gd) with tests/fake_session_backend.gd serving the glb.
## Joining (a bad code, a bad hub, unsaved changes), the model fetched with the VIEW TOKEN ONLY (the app's own CAD key, which it has, never leaves), If-None-Match and 304, the
## snapshot applied (place, hidden parts, the section, the status line), the stream (poses applied, an older seq ignored, hide, the section, place), smoothing (one interval behind,
## no tween over a gap, a mirrored part), doc_changed (the parts named, `all` keeping the place, an old revision ignored, queued behind a slow fetch with the newest winning), a 401
## (a newer token already here; the hub's current one read by resuming; an expired link told in words), a drop of the presenter, a demo by path, a missing demo, the role gating
## (no hand grabbing, no wheel, no two-hand model, a trimmed tablet, no backend, no save / open / new / server switch, the landing's tiles), and Leave / the end of the session putting
## everything back. NOT covered: a real hub or backend (tests/e2e_session_observer.gd), the headset.
## Run: "$GODOT" --headless --path . --script res://tests/session_observer.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const Observer := preload("res://scripts/session/session_observer.gd")
const P := preload("res://scripts/session/session_protocol.gd")
const GLB := "res://tests/fixtures/session_assembly.glb"
const DEMO := "res://demo/spacecraft/Pioneer_10.glb"
const MISSING_DEMO := "res://demo/spacecraft/Nonexistent.glb"

var hub: RefCounted
var backend: RefCounted
var main: Node
var presenter: Node


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _part(path: String) -> Node3D:
	for node in main.session_world_parts():
		if str(node.get_meta("instance_path", "?")) == path:
			return node
	return null


func _model_mm(node: Node3D) -> Vector3:
	return (main.session_scene_root().global_transform.affine_inverse() * node.global_transform).origin


func _near(a: Vector3, b: Vector3, tolerance: float = 0.01) -> bool:
	## (Godot's transforms are single precision: a position 500 times down a 0.002 scale is good to about 1e-4 of a millimetre)
	return a.distance_to(b) < tolerance


func _xf(x: float, y: float, z: float) -> Array:
	return [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, x, y, z]


func _initialize() -> void:
	hub = Hub.new()
	backend = Backend.new()
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	main.session.use_transport(hub.make_transport)
	main.session.http.transport = backend.handle
	# this app has a server of its own, with its own key: an observer must never use it
	main.backend_url = "https://own.test"
	main.api_key = "observer-own-key"
	main._apply_backend()
	_check(main.has_backend() and not main.is_observer(), "before joining, the app has its own server")
	backend.tokens["tok-1"] = true
	presenter = Client.new()
	presenter.transport_factory = hub.make_transport
	root.add_child(presenter)
	presenter.host("wss://hub.test", hub.key, {"name": "Alex", "device": "quest", "client": "test", "model": {"kind": "backend", "root_part_id": "part-root", "rev": 3, "quality": 0.5, "tier": "full", "title": "Gearbox"},
		"backend_url": "https://cad.test", "view_token": "tok-1", "view_expires_at": 99999999999.0})
	await _wait(0.3)
	var code: String = str(presenter.room["code"])
	presenter.send_state({"t": "place", "xf": [0.002, 0.0, 0.0, 0.0, 0.002, 0.0, 0.0, 0.0, 0.002, 1.0, 1.0, -2.0]})
	presenter.send_state({"t": "poses", "full": true, "items": [{"path": "", "xf": _xf(0, 0, 0)}, {"path": "occ-bolt", "xf": _xf(31.5, 2.0, 0)}, {"path": "occ-nut", "xf": _xf(0, 33.0, 0)}]})
	presenter.send_state({"t": "visibility", "hidden": ["occ-nut"]})
	presenter.send_state({"t": "section", "on": true, "point": [15.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0]})
	presenter.send_state({"t": "status", "activity": "design_table", "detail": "Shaft"})
	await _wait(0.1)
	# --- joining: refusals first
	var bad_code: Dictionary = await main.session.join_session("wss://hub.test", "K0XQ4M")
	_check(not bad_code["ok"] and str(bad_code["error"]).contains("not a session code") and hub.open_count == 1, "a code with a 0 is refused before the hub is asked (no wrong-code strike)")
	var bad_hub: Dictionary = await main.session.join_session("ws://hub.example.com", code)
	_check(not bad_hub["ok"] and str(bad_hub["error"]).contains("not allowed"), "a plain ws:// hub on the internet is refused")
	var wrong: Dictionary = await main.session.join_session("wss://hub.test", "ZZZZZZ")
	_check(not wrong["ok"] and str(wrong["error"]).contains("No session has that code") and not main.session.is_active() and not main.is_observer(), "a code no session has: 'No session has that code', and nothing changed")
	main.document_is_demo = false
	main._resolved_part_id = "part-own"
	main.document_dirty = true
	var asked: Dictionary = await main.session.join_session("wss://hub.test", code)
	_check(not asked["ok"] and str(asked["error"]).contains("unsaved changes") and not main.session.is_active(), "with unsaved changes the join asks first and does nothing")
	main.document_dirty = false
	main._resolved_part_id = ""
	# --- joining
	var joined_signals: Array = []
	main.session.observer.model_ready.connect(func() -> void: joined_signals.append(true))
	var joined: Dictionary = await main.session.join_session("wss://hub.test", code.to_lower().insert(3, " "))
	await _wait(0.5)
	_check(joined["ok"] and main.session.role == "observer" and main.is_observer() and main.session.is_observer(), "Join: an observer (a code typed in lower case with a space works)")
	_check(not joined_signals.is_empty() and main.session_world_parts().size() == 3 and main.session_scene_root() != null, "the model was fetched and is on show: three parts")
	var glb_gets: Array = backend.requests_to("assembly-mesh.glb")
	var first: Dictionary = glb_gets[0]
	_check(first["path"] == "/document/parts/part-root/assembly-mesh.glb" and first["headers"].get("x-view-token", "") == "tok-1" and first["query"].contains("quality=0.5") and first["query"].contains("include_hidden=false"), "it GETs the root's glb from the presenter's backend address with the view token")
	var any_key := false
	for r in backend.log:
		any_key = any_key or r["headers"].has("x-api-key") or r["headers"].has("x-document-session")
	_check(not any_key and not JSON.stringify(backend.log).contains("observer-own-key"), "...and no request carried an API key or a document session: its own CAD key never left")
	_check(not first["headers"].has("if-none-match"), "the first fetch has no If-None-Match")
	_check(backend.requests_to("/health").is_empty() and backend.requests_to("view-tokens").is_empty(), "an observer asks the backend for nothing else")
	# --- the snapshot applied
	_check(is_equal_approx(main.assembly_root.transform.basis.get_scale().x, 0.002) and main.assembly_root.transform.origin.is_equal_approx(Vector3(1, 1, -2)), "the presenter's place and scale were applied (the shared place)")
	_check(_part("occ-bolt").visible and not _part("occ-nut").visible and _part("").visible, "the presenter's hidden list was applied")
	_check(_near(_model_mm(_part("occ-bolt")), Vector3(31.5, 2.0, 0)) and _near(_model_mm(_part("occ-nut")), Vector3(0, 33.0, 0)), "the pose table was applied (positions in model mm)")
	_check(main._section_tool.active, "the presenter's section is on here too")
	var plane: Dictionary = main._section_tool.world_plane()
	var expect_origin: Vector3 = main.session_scene_root().global_transform * Vector3(15, 0, 0)
	_check(plane["on"] and (plane["origin"] as Vector3).is_equal_approx(expect_origin) and (plane["normal"] as Vector3).is_equal_approx(Vector3(1, 0, 0)), "...at the same place in the model (15 mm along x), facing the same way")
	_check(main.session.observer.status_text == "Alex is at the design table: Shaft" and main.session.observer.title == "Gearbox", "the status line says what the presenter is doing, and the model has its title")
	_check(main.session.status_line() == "Watching Alex", "the monolith's line says whose session")
	# --- role gating
	var hands: Array = main.session_hands()
	_check(hands[0].view_only and hands[1].view_only, "an observer's hands do not grab, select or use tools")
	hands[1]._on_button_pressed("grip_click")
	hands[1]._on_button_pressed("trigger_click")
	_check(hands[1].held_node == null and hands[1].selected_node == null, "...a grip and a trigger do nothing")
	_check(not main._two_hand.enabled, "the whole-model move and scale is off (the presenter's place is the shared place)")
	_check(not main.has_backend() and main._mates_tool.backend_url == "" and main.design_table.api.backend_url == "" and main.room_manager.has_method("configure_backend"), "an observer has no backend: every tool is configured with none")
	var ids: Array = main._tablet.registry.categories().map(func(c) -> String: return c.id)
	_check(ids.size() == 6 and ids.all(func(i: String) -> bool: return Array(main.OBSERVER_CATEGORIES).has(i)) and not ids.has("assemble") and not ids.has("files") and not ids.has("design"), "the wrist tablet shows only View and Inspect (own-view tools, P4), Settings, Home and the plain windows (%s)" % str(ids))
	_check(not main.design_table.is_open(), "the design table is closed")
	var save: Dictionary = await main.save_project()
	_check(not save["ok"] and main.status_text.contains("not available while you are watching"), "Save is refused, in words")
	main.load_model_file("res://anything.didsa")
	_check(main.status_text.contains("Opening a file is not available"), "Open is refused")
	_check(not main.load_glb_file(DEMO) and main.shown_demo_path == "", "a demo cannot be opened over the shared model")
	_check(not (await main.new_assembly()), "New assembly is refused")
	_check(not main.switch_server(""), "switching server is refused while in a session")
	var tiles: Dictionary = {}
	for tile in main.landing.launcher.tiles():
		tiles[tile["id"]] = tile
	_check(not tiles["continue"]["enabled"] and not tiles["open"]["enabled"] and not tiles["new"]["enabled"] and not tiles["servers"]["enabled"] and not tiles["models"]["enabled"] and not tiles["host"]["enabled"] and not tiles["join"]["enabled"] and tiles["session"]["enabled"], "the landing's file, server, model, Host and Join tiles are off; Session is on")
	_check(str(tiles["servers"]["note"]) == "Not while watching" and main.connection_text() == "Watching Alex", "...and the pill says whose session it is")
	# --- the stream
	var bolt := _part("occ-bolt")
	presenter.send_state({"t": "poses", "items": [{"path": "occ-bolt", "xf": _xf(42.34, 2.0, 0)}]})
	await _wait(0.4)
	_check(_near(_model_mm(bolt), Vector3(42.34, 2.0, 0)), "a moved part arrives and ends where the presenter put it")
	var stale_seq: int = presenter._seq
	presenter.send({"t": "poses", "seq": 1, "items": [{"path": "occ-bolt", "xf": _xf(99.0, 0, 0)}]}) # an older seq than one already applied
	await _wait(0.3)
	_check(_near(_model_mm(bolt), Vector3(42.34, 2.0, 0)) and stale_seq > 1, "a message older than one already applied is ignored")
	presenter.send_state({"t": "poses", "items": [{"path": "occ-bolt", "xf": _xf(42.34, 2.0, 0)}]}) # (the hub keeps whatever it is sent for a late joiner or a resume: put the right pose back)
	await _wait(0.2)
	presenter.send_state({"t": "visibility", "hidden": ["occ-bolt"]})
	await _wait(0.2)
	_check(not bolt.visible and _part("occ-nut").visible, "hide: the list is applied in full (the nut is back, the bolt gone)")
	presenter.send_state({"t": "visibility", "hidden": []})
	presenter.send_state({"t": "section", "on": false})
	await _wait(0.2)
	_check(not main._section_tool.active, "the presenter turning the section off turns it off here")
	presenter.send_state({"t": "place", "xf": [0.001, 0.0, 0.0, 0.0, 0.001, 0.0, 0.0, 0.0, 0.001, 0.5, 1.0, -1.0]})
	await _wait(0.2)
	_check(is_equal_approx(main.assembly_root.transform.basis.get_scale().x, 0.001) and main.assembly_root.transform.origin.is_equal_approx(Vector3(0.5, 1.0, -1.0)), "the model's place follows the presenter")
	presenter.send_state({"t": "status", "activity": "model", "detail": ""})
	await _wait(0.2)
	_check(main.session.observer.status_text == "", "back at the model: no status line")
	# --- smoothing (pure)
	var track := {"a": {"at": 1000.0, "xf": Transform3D(Basis.IDENTITY, Vector3(0, 0, 0))}, "b": {"at": 1100.0, "xf": Transform3D(Basis(Vector3.UP, deg_to_rad(90.0)), Vector3(100, 0, 0))}}
	var mid: Transform3D = Observer.interpolated(track, 1050.0)
	_check(mid.origin.is_equal_approx(Vector3(50, 0, 0)) and absf(mid.basis.get_euler().y - deg_to_rad(45.0)) < 1e-3, "halfway between two poses: halfway in position and rotation (45 of 90 degrees)")
	_check(Observer.interpolated(track, 1500.0).origin.is_equal_approx(Vector3(100, 0, 0)) and Observer.interpolated(track, 900.0).origin.is_equal_approx(Vector3.ZERO), "past the newest: the newest; before the older: the older")
	var gap := {"a": {"at": 1000.0, "xf": Transform3D(Basis.IDENTITY, Vector3.ZERO)}, "b": {"at": 1800.0, "xf": Transform3D(Basis.IDENTITY, Vector3(100, 0, 0))}}
	_check(Observer.interpolated(gap, 1400.0).origin.is_equal_approx(Vector3(100, 0, 0)), "samples more than 500 ms apart are not tweened: it snaps")
	var mirrored := {"a": {"at": 1000.0, "xf": Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)), Vector3.ZERO)}, "b": {"at": 1100.0, "xf": Transform3D(Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)), Vector3(100, 0, 0))}}
	var m: Transform3D = Observer.interpolated(mirrored, 1050.0)
	_check(m.origin.is_equal_approx(Vector3(50, 0, 0)) and m.basis.determinant() < 0.0, "a mirrored part keeps its mirror (the origin is blended, the basis is the newer)")
	# --- a changed document
	var rev_before: int = main.session.observer.loaded_rev
	var gets_before: int = backend.requests_to("assembly-mesh.glb").size()
	var mesh_before: Mesh = _part("occ-bolt").mesh
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(0.5)
	var part_gets: Array = backend.requests_to("assembly-mesh.glb").slice(gets_before)
	_check(part_gets.size() == 1 and part_gets[0]["path"] == "/document/parts/part-bolt/assembly-mesh.glb" and part_gets[0]["headers"].get("x-view-token", "") == "tok-1" and not part_gets[0]["headers"].has("x-api-key"), "doc_changed with parts refetches just that part's glb, with the token only")
	_check(_part("occ-bolt").mesh != mesh_before and main.session.observer.loaded_rev == backend.rev and main.session.observer.loaded_rev > rev_before, "...and swaps its mesh in place; the revision shown is now the new one")
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(0.3)
	_check(backend.requests_to("assembly-mesh.glb").size() == gets_before + 1, "a doc_changed for a revision already shown is ignored (no request)")
	presenter.send_state({"t": "doc_changed", "rev": backend.rev + 5, "parts": ["part-bolt"]}) # the presenter's revision moved on but the backend's answer for this request is the same (a spare bump)
	await _wait(0.4)
	var again: Array = backend.requests_to("assembly-mesh.glb").filter(func(r: Dictionary) -> bool: return r["path"].contains("part-bolt"))
	_check(again.size() == 2 and again[1]["headers"].has("if-none-match") and main.session.observer.not_modified_count == 1, "a refetch sends If-None-Match with the last ETag and a 304 changes nothing")
	backend.rev = main.session.observer.loaded_rev # (the spare bump above ran the presenter's number ahead of the backend's: the backend catches up)
	var place_before: Transform3D = main.assembly_root.transform
	var root_gets: int = backend.requests_to("part-root/assembly-mesh.glb").size()
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "all": true})
	await _wait(0.6)
	_check(backend.requests_to("part-root/assembly-mesh.glb").size() == root_gets + 1 and main.session_world_parts().size() == 3, "doc_changed with all refetches the root's glb")
	_check(main.assembly_root.transform.is_equal_approx(place_before), "...and where the presenter put the model is kept (the document changed, the place did not)")
	_check(_near(_model_mm(_part("occ-bolt")), Vector3(42.34, 2.0, 0)), "...and the poses received so far are applied to the new nodes")
	presenter.send_state({"t": "visibility", "hidden": ["occ-nut"]})
	await _wait(0.2)
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "all": true})
	await _wait(0.6)
	_check(not _part("occ-nut").visible, "the hidden list survives a refetch")
	# queued behind a slow fetch: the newest revision wins and nothing is fetched twice for it
	presenter.send_state({"t": "visibility", "hidden": []})
	backend.delay_s = 0.3
	var queued_before: int = backend.requests_to("assembly-mesh.glb").size()
	var start_rev: int = backend.rev
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(0.1)
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-nut"]})
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(1.6)
	backend.delay_s = 0.0
	var queued: Array = backend.requests_to("assembly-mesh.glb").slice(queued_before)
	_check(queued.size() == 3 and main.session.observer.loaded_rev == start_rev + 3, "doc_changed messages that arrive during a slow fetch are queued and merged: one fetch running, then one for each part named since (%d requests), at the newest revision" % queued.size())
	# --- a 401
	backend.tokens["tok-2"] = true
	backend.tokens.erase("tok-1")
	presenter.send({"t": "token", "view_token": "tok-2", "view_expires_at": 99999999999.0})
	await _wait(0.2)
	backend.bump()
	var before_401: int = backend.requests_to("assembly-mesh.glb").size()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(0.5)
	var after_token: Array = backend.requests_to("assembly-mesh.glb").slice(before_401)
	_check(after_token.size() == 1 and after_token[0]["headers"].get("x-view-token", "") == "tok-2", "a renewed token is used for the next fetch")
	var observer_client: Node = main.session.client
	observer_client.view_token = "stale-token" # the observer missed the presenter's push
	backend.bump()
	var resumes_before := 0
	var resumed_welcomes: Array = []
	observer_client.welcomed.connect(func(_w: Dictionary, resumed: bool) -> void: resumed_welcomes.append(resumed))
	before_401 = backend.requests_to("assembly-mesh.glb").size()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(2.5)
	var recovered: Array = backend.requests_to("assembly-mesh.glb").slice(before_401).filter(func(r: Dictionary) -> bool: return r["path"].contains("part-bolt")) # (a resume also catches up on the whole model, which is not what this checks)
	_check(recovered.size() == 2 and recovered[0]["headers"].get("x-view-token", "") == "stale-token" and recovered[1]["headers"].get("x-view-token", "") == "tok-2" and resumed_welcomes == [true] and resumes_before == 0, "a 401: the hub's current token is read again by resuming, and the fetch is tried once more with it")
	_check(main.session.observer.loaded_rev == backend.rev, "...and it worked: the new revision is shown")
	backend.tokens.erase("tok-2") # the link is really gone
	backend.bump()
	main.session.observer.last_error = ""
	before_401 = backend.requests_to("assembly-mesh.glb").size()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "parts": ["part-bolt"]})
	await _wait(3.0)
	_check(main.session.observer.last_error.contains("expired or was ended") and main.status_text.contains("Ask them to share again") and main.session.is_observer(), "a link that no longer works is said so in words (the presenter renews it; here nobody did), and the observer stays")
	backend.tokens["tok-2"] = true
	# --- the presenter drops and comes back
	hub.drop(1)
	await _wait(0.3)
	_check(main.session.status_line() == "Watching Alex (presenter reconnecting ...)" and main.is_observer(), "the presenter dropped: the line says reconnecting and the observer keeps what it has")
	_check(_near(_model_mm(_part("occ-bolt")), Vector3(42.34, 2.0, 0)), "...with the last state still shown")
	await _wait(2.5)
	_check(presenter.is_live() and main.session.status_line() == "Watching Alex", "the presenter returns")
	presenter.send_state({"t": "poses", "items": [{"path": "occ-bolt", "xf": _xf(55.0, 2.0, 0)}]}) # seq 1 again on the new connection
	await _wait(0.4)
	_check(int(presenter._seq) < 10 and _near(_model_mm(_part("occ-bolt")), Vector3(55.0, 2.0, 0)), "after the presenter resumes, its messages (numbered from 1 again) are still applied: the old numbers are forgotten")
	# --- a demo by path
	presenter.send_state({"t": "model", "source": {"kind": "demo", "path": DEMO}, "title": "Pioneer 10", "rev": 0})
	await _wait(1.5)
	var demo_nodes: Array = main.session_world_parts()
	_check(main.shown_demo_path == DEMO and demo_nodes.size() > 0 and main.session.observer.title == "Pioneer 10", "a demo model is loaded by its path (no fetch)")
	var first_node: Node3D = demo_nodes[0]
	var key: String = main.session.publisher.part_key(first_node, main.session_scene_root())
	presenter.send_state({"t": "poses", "full": true, "items": [{"path": key, "xf": _xf(1500.0, 250.0, -300.0)}]})
	await _wait(0.4)
	var at_m: Vector3 = _model_mm(first_node)
	_check(_near(at_m, Vector3(1.5, 0.25, -0.3), 1e-4), "...whose poses are millimetres on the wire and metres in the glb (1500 mm is 1.5 m)")
	presenter.send_state({"t": "model", "source": {"kind": "demo", "path": MISSING_DEMO}, "title": "Gone", "rev": 0})
	await _wait(0.6)
	_check(main.session.observer.last_error.contains("does not have the demo model") and main.status_text.contains("Nonexistent.glb"), "a demo this build does not have is said so, by name")
	# --- the end puts everything back
	var ended_text: Array = []
	main.session.ended_for_me.connect(func(t: String) -> void: ended_text.append(t))
	presenter.end_session()
	await _wait(0.5)
	_check(not ended_text.is_empty() and ended_text[0] == "The presenter ended the session." and main.session.role == "" and not main.is_observer(), "the presenter ending the session ends it here, in words")
	_check(main.session_world_parts().is_empty() and main.shown_demo_path == "" and not main._section_tool.active, "the shared model is put away")
	_check(not hands[0].view_only and not hands[1].view_only and main._two_hand.enabled and main.has_backend() and main._mates_tool.backend_url == "https://own.test", "the hands, the whole-model move and this app's own server are back")
	var back_ids: Array = main._tablet.registry.categories().map(func(c) -> String: return c.id)
	_check(back_ids.size() > 4 and back_ids.has("files") and back_ids.has("assemble"), "the tablet has all its categories again")
	# --- Leave
	hub = Hub.new()
	main.session.use_transport(hub.make_transport)
	backend.tokens["tok-9"] = true
	var host2 := Client.new()
	host2.transport_factory = hub.make_transport
	root.add_child(host2)
	host2.host("wss://hub.test", hub.key, {"name": "Dana", "device": "pcvr", "client": "test", "model": {"kind": "backend", "root_part_id": "part-root", "rev": 3, "quality": 0.5, "tier": "full"}, "backend_url": "https://cad.test", "view_token": "tok-9"})
	await _wait(0.3)
	host2.send_state({"t": "poses", "full": true, "items": [{"path": "", "xf": _xf(0, 0, 0)}, {"path": "occ-bolt", "xf": _xf(30, 0, 0)}, {"path": "occ-nut", "xf": _xf(0, 30, 0)}]})
	var again_joined: Dictionary = await main.session.join_session("wss://hub.test", str(host2.room["code"]))
	await _wait(0.5)
	_check(again_joined["ok"] and main.is_observer() and main.session_world_parts().size() == 3, "joining a second session works the same way")
	main.session.leave_session()
	await _wait(0.4)
	_check(not main.is_observer() and main.session.role == "" and main.session_world_parts().is_empty() and host2.others().is_empty(), "Leave: a clean goodbye, the shared model is put away and the presenter's roster is down to one")
	_check(not hands[0].view_only and main._two_hand.enabled, "...and the app is the person's own again")
	quit()
