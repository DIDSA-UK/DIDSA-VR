extends SceneTree
## P4.2: an observer's OWN-VIEW edits (scripts/session/session_own_view.gd, plan "Observer tools", D7), in the real main.tscn joining a scripted presenter through tests/fake_session_hub.gd, with
## tests/fake_session_backend.gd serving the glb (three 10 mm cubes at 1:50 on a bench). Covered: the narrow hand input an observer keeps (view_only stays on; the trigger works the Hide and Measure
## tools, the grip the cut's handle and, only when "Pull a part out" is on, a part; nothing selects or grabs otherwise); the wrist tablet's View and Inspect tools for an observer (no Scale or
## Navigate; the cursor, Share and My view added; a presenter sees none of the three); colour and see-through on a selection (the glb's other looks untouched, a refetch keeps the paint, Clear
## puts the glb's look back); hide and isolate (the presenter's hide list is applied as CHANGES, so what this person hid stays hidden); the cut (their own is kept when the presenter's arrives;
## Reset gives the presenter's); measure (client-side, straight-line, no backend); pulling a part out (the presenter's pose for it is kept, not applied); Reset my view; and that NOTHING of
## this reached the hub's presenter-only messages or the backend. NOT covered: how any of it feels in the hand, a headset.
## Run: "$GODOT" --headless --path . --script res://tests/session_own_view.gd  (see tests/README.md)

const Hub := preload("res://tests/fake_session_hub.gd")
const Backend := preload("res://tests/fake_session_backend.gd")
const Client := preload("res://scripts/session/session_client.gd")
const BENCH := 1.2

var hub: RefCounted
var backend: RefCounted
var main: Node
var presenter: Node
var cursor: Node3D
var own: Node
var aim_origin := Vector3.ZERO
var aim_direction := Vector3(0, 0, -1)


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


func _aim_cursor(origin: Vector3, direction: Vector3, distance: float) -> void:
	aim_origin = origin
	aim_direction = direction
	cursor.distance = distance
	for i in 3:
		await physics_frame
	cursor.refresh()


func _point_hand(hand: Node3D, at: Vector3) -> void:
	hand.global_transform = Transform3D(Basis.IDENTITY, at) # forward is -Z
	for i in 3:
		await physics_frame


func _colour_of(node: MeshInstance3D) -> Color:
	var m: Material = node.material_override if node.material_override != null else node.mesh.surface_get_material(0)
	return (m as BaseMaterial3D).albedo_color if m is BaseMaterial3D else Color.BLACK


func _near_colour(a: Color, b: Color) -> bool:
	## (a look put back is rebuilt from the colour's 8-bit hex: within a 255th)
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01 and absf(a.a - b.a) < 0.01


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
	backend.tokens["tok-1"] = true
	var registry = main._tablet.registry
	var view_ids_before: Array = registry.tools_of(registry.category("view")).map(func(t) -> String: return t.id)
	_check(view_ids_before.has("navigate") and view_ids_before.has("scale") and not view_ids_before.has("cursor") and not view_ids_before.has("share") and not view_ids_before.has("my_view"), "a presenter's View hub has Navigate and Scale, and none of the observer-only tools (%s)" % str(view_ids_before))
	presenter = Client.new()
	presenter.transport_factory = hub.make_transport
	root.add_child(presenter)
	presenter.host("wss://hub.test", hub.key, {"name": "Alex", "device": "quest", "client": "test", "model": {"kind": "backend", "root_part_id": "part-root", "rev": 3, "quality": 0.5, "tier": "full", "title": "Gearbox"},
		"backend_url": "https://cad.test", "view_token": "tok-1", "view_expires_at": 99999999999.0})
	await _wait(0.3)
	var code: String = str(presenter.room["code"])
	var place := [0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 0.02, 0.0, BENCH, 0.0]
	presenter.send_state({"t": "place", "xf": place})
	presenter.send_state({"t": "poses", "full": true, "items": [{"path": "", "xf": _xf(0, 0, 0)}, {"path": "occ-bolt", "xf": _xf(30, 0, 0)}, {"path": "occ-nut", "xf": _xf(0, 30, 0)}]})
	var joined: Dictionary = await main.session.join_session("wss://hub.test", code)
	await _wait(0.5)
	_check(joined["ok"] and main.is_observer() and main.session_world_parts().size() == 3, "an observer is in, the model is on show")
	var me: int = int(main.session.client.me["id"])
	var presenter_id: int = int(presenter.me["id"])
	cursor = main.session.cursor
	own = main.session.own_view
	cursor.aim = func() -> Dictionary: return {"origin": aim_origin, "direction": aim_direction}
	cursor.stick = func() -> Vector2: return Vector2.ZERO
	cursor.set_enabled(true)
	var hands: Array = main.session_hands()
	var requests_at_start: int = backend.log.size()
	# --- who gets what: the flags and the tablet
	_check(hands[0].view_only and hands[1].view_only and hands[0].own_view_input and hands[1].own_view_input, "view_only stays on, and the narrower own-view input is on beside it")
	_check(main._appearance_tool.local_only and main._measure_tool.local_only, "the Appearance and Measure tools are in their local-only mode (no backend, nothing sent)")
	var view_ids: Array = registry.tools_of(registry.category("view")).map(func(t) -> String: return t.id)
	var inspect_ids: Array = registry.tools_of(registry.category("inspect")).map(func(t) -> String: return t.id)
	_check(view_ids == ["cursor", "share", "my_view", "visibility", "shoot_hide", "display", "paint", "environment"] and inspect_ids == ["measure", "sections"], "an observer's View hub: the cursor, Share, My view, then Visibility, Hide tool, Display, Appearance, Environment; Inspect: Measure, Sections (%s)" % str(view_ids))
	var tile_ids: Array = registry.categories().map(func(c) -> String: return c.id)
	_check(tile_ids.all(func(i: String) -> bool: return Array(main.OBSERVER_CATEGORIES).has(i)) and tile_ids.has("view") and tile_ids.has("inspect") and not tile_ids.has("assemble") and not tile_ids.has("files") and not tile_ids.has("design"), "the tablet's tiles: View and Inspect added, still no Assemble, Files or Design (%s)" % str(tile_ids))
	# --- hand input: still narrow
	hands[1]._on_button_pressed("grip_click")
	hands[1]._on_button_pressed("trigger_click")
	_check(hands[1].held_node == null and hands[1].selected_node == null, "with no own-view tool on, a grip and a trigger still do nothing")
	var bolt := _part("occ-bolt")
	var nut := _part("occ-nut")
	var mount := _part("")
	# --- hide tool: the trigger hides what the laser touches, for this person
	await _point_hand(hands[1], Vector3(0.6, BENCH, 1.0))
	hands[1].hide_tool_active = true
	hands[1]._on_button_pressed("trigger_click")
	hands[1]._on_button_released("trigger_click")
	hands[1].hide_tool_active = false
	_check(not bolt.visible and nut.visible and mount.visible, "the Hide tool's trigger hid the bolt the laser touched, for this person")
	bolt.visible = true
	# --- the cursor picks; hide and isolate; the presenter's hide list is applied as changes
	await _aim_cursor(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.8)
	_check(cursor.selection().get("node") == bolt, "the cursor has the bolt")
	_check(own.hide_selection(cursor.selection()) == 1 and not bolt.visible, "Hide it: the bolt is hidden here")
	presenter.send_state({"t": "visibility", "hidden": ["occ-nut"]})
	await _wait(0.2)
	_check(not nut.visible and not bolt.visible, "the presenter hides the nut: it goes, and the bolt this person hid stays hidden")
	presenter.send_state({"t": "visibility", "hidden": []})
	await _wait(0.2)
	_check(nut.visible and not bolt.visible and own.differs()["hidden"] == 1, "the presenter shows the nut again: it comes back; the bolt is still hidden (it differs from the presenter's view: %d)" % own.differs()["hidden"])
	presenter.send_state({"t": "visibility", "hidden": ["occ-bolt"]})
	await _wait(0.2)
	presenter.send_state({"t": "visibility", "hidden": []})
	await _wait(0.2)
	_check(bolt.visible and own.differs()["hidden"] == 0, "the presenter hides the bolt and then shows it: that is a change to that very part, so it is shown")
	await _aim_cursor(Vector3(0.0, BENCH + 0.6, 1.0), Vector3(0, 0, -1), 0.8)
	_check(cursor.selection().get("node") == nut and own.isolate_selection(cursor.selection()) == 1 and nut.visible and not bolt.visible and not mount.visible, "Isolate it: only the nut shows")
	own.show_all()
	_check(bolt.visible and nut.visible and mount.visible, "Show everything")
	# --- colour and see-through: the glb's own looks are kept for everything not painted
	var base_nut := _colour_of(nut)
	await _aim_cursor(Vector3(0.6, BENCH, 1.0), Vector3(0, 0, -1), 0.8)
	var painted: Dictionary = await own.paint_selection({"colour": "#FF0000"}, cursor.selection())
	_check(painted.get("ok", false) and _colour_of(bolt).is_equal_approx(Color.html("#FF0000")) and _colour_of(nut).is_equal_approx(base_nut) and nut.material_override == null, "Colour: the bolt is red; the nut keeps the glb's own look, untouched (not even restyled)")
	var see: Dictionary = await own.paint_selection({"opacity": 0.25}, cursor.selection())
	var bolt_look := _colour_of(bolt)
	_check(see.get("ok", false) and is_equal_approx(bolt_look.a, 0.25) and is_equal_approx(bolt_look.r, 1.0) and (bolt.material_override as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED, "See-through: the same bolt is now 25% opaque, and still red")
	await _aim_cursor(Vector3(0.0, BENCH + 0.6, 1.0), Vector3(0, 0, -1), 0.8)
	var ghost: Dictionary = await own.paint_selection({"opacity": 0.25}, cursor.selection())
	var nut_look := _colour_of(nut)
	_check(ghost.get("ok", false) and is_equal_approx(nut_look.a, 0.25) and absf(nut_look.r - base_nut.r) < 0.01 and absf(nut_look.b - base_nut.b) < 0.01, "See-through on the nut keeps the glb's colour (only the opacity is the paint)")
	_check(main._appearance_tool.temporary_count() == 3 or main._appearance_tool.temporary_count() == 2, "the paint is the temporary layer (%d records)" % main._appearance_tool.temporary_count())
	# --- the paint survives a refetch (the nodes are new)
	backend.bump()
	presenter.send_state({"t": "doc_changed", "rev": backend.rev, "all": true})
	await _wait(0.6)
	bolt = _part("occ-bolt")
	nut = _part("occ-nut")
	_check(_colour_of(bolt).is_equal_approx(Color(1, 0, 0, 0.25)) and is_equal_approx(_colour_of(nut).a, 0.25), "after the presenter's model is refetched (new nodes) this person's paint is put back on them")
	# --- the cut
	var camera: Node3D = main.session_camera()
	main._section_tool.set_active(true, camera)
	var own_origin: Vector3 = main._section_tool.world_plane()["origin"]
	_check(own.own_section_active() and not main.session.observer.remote_section_on, "this person's own cut is on")
	presenter.send_state({"t": "section", "on": true, "point": [15.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0]})
	await _wait(0.2)
	_check(main._section_tool.active and (main._section_tool.world_plane()["origin"] as Vector3).is_equal_approx(own_origin), "the presenter's cut arrives and is held back: this person's own stays where it is")
	# --- measure, client-side
	var asked: int = backend.log.size()
	main._measure_tool.set_active(true)
	hands[1].measure_tool_active = true
	await _point_hand(hands[1], Vector3(0.6, BENCH, 1.0))
	hands[1]._on_button_pressed("trigger_click")
	hands[1]._on_button_released("trigger_click")
	await _point_hand(hands[1], Vector3(0.0, BENCH + 0.6, 1.0))
	hands[1]._on_button_pressed("trigger_click")
	hands[1]._on_button_released("trigger_click")
	await _wait(0.1)
	var measured: Dictionary = main._measure_tool.result
	_check(measured.has("distance") and absf(float(measured["distance"]) - 30.0 * sqrt(2.0)) < 0.1, "Measure: the two spots the laser touched are %.3f mm apart (30 mm along x, 30 mm along y: 42.426)" % float(measured.get("distance", -1)))
	_check(main._measure_tool.picked_points().size() == 2 and backend.log.size() == asked, "...worked out here: two picks, and the backend was asked nothing")
	hands[1].measure_tool_active = false
	main._measure_tool.set_active(false)
	# --- pulling a part out
	await _point_hand(hands[1], Vector3(0.6, BENCH, 0.0)) # the hand is inside the bolt
	hands[1]._on_button_pressed("grip_click")
	_check(hands[1].held_node == null, "with Pull a part out off, a grip on a part takes nothing")
	own.set_pull_out(true)
	hands[1].steadiness = 0
	hands[1]._on_button_pressed("grip_click")
	_check(hands[1].held_node == bolt, "with it on, the grip takes the part the hand is in")
	await _point_hand(hands[1], Vector3(0.6, BENCH + 0.5, 0.0))
	hands[1]._on_button_released("grip_click")
	var pulled_to: Vector3 = bolt.global_position
	_check(hands[1].held_node == null and absf(pulled_to.y - (BENCH + 0.5)) < 0.01 and own.is_pulled(bolt), "pulled 0.5 m up and let go: it stays there, and it is this person's now")
	presenter.send_state({"t": "poses", "full": false, "items": [{"path": "occ-bolt", "xf": _xf(30, 5, 0)}]})
	await _wait(0.3)
	_check(bolt.global_position.is_equal_approx(pulled_to) and own.differs()["moved"] == 1, "the presenter moves the bolt: this person's pulled bolt does not follow")
	_check(main._mates_tool._persist.is_empty() and main._mates_tool.backend_url == "", "...and no pose was queued for any backend (an observer's mates tool has none)")
	# --- what this person has changed, then Reset my view
	_check(own.summary().contains("pulled out") and own.summary().contains("colour") and own.summary().contains("your own cut"), "the tablet says how this view differs: %s" % own.summary())
	nut.visible = false
	main._measure_tool.set_active(true)
	main._measure_tool.try_pick(bolt, -1, {}, bolt.global_position)
	own.reset_my_view()
	await _wait(0.2)
	var back := _model_mm(bolt)
	_check(back.distance_to(Vector3(30, 5, 0)) < 0.01, "Reset my view: the pulled bolt is at the presenter's latest pose for it (%s)" % str(back))
	_check(nut.visible and bolt.visible, "...every part shown as the presenter has it")
	_check(main._appearance_tool.temporary_count() == 0, "...the temporary paint is gone")
	_check(main._section_tool.active and (main._section_tool.world_plane()["origin"] as Vector3).is_equal_approx(main.session_scene_root().global_transform * Vector3(15, 0, 0)), "...the cut is the presenter's, not this person's own")
	_check(main._measure_tool.picked_points().is_empty(), "...the measurement is cleared")
	_check(own.summary() == "Your view is the presenter's.", "...and the view says it is the presenter's again (%s)" % own.summary())
	presenter.send_state({"t": "section", "on": false})
	await _wait(0.2)
	_check(not main._section_tool.active, "the presenter takes their cut off: it goes here too")
	_check(_near_colour(_colour_of(bolt), base_nut) and _near_colour(_colour_of(nut), base_nut), "colours and see-through are gone: the glb's own looks are back (%s) (read once the cut, whose clip shader wears every part, is off)" % str(_colour_of(bolt)))
	# --- Put pulled parts back
	await _point_hand(hands[1], Vector3(0.6, BENCH + 0.05, 0.0))
	hands[1]._on_button_pressed("grip_click")
	await _point_hand(hands[1], Vector3(0.9, BENCH + 0.05, 0.0))
	hands[1]._on_button_released("grip_click")
	_check(own.differs()["moved"] == 1 and own.put_pulled_back() == 1 and _model_mm(bolt).distance_to(Vector3(30, 5, 0)) < 0.01 and own.differs()["moved"] == 0, "Put pulled parts back: just the pulled parts go back to the presenter's poses")
	# --- none of it reached the hub's presenter-only messages, the presenter, or the backend
	var kinds: Array = (hub.sent_by[me] as Array).map(func(m: Dictionary) -> String: return str(m["t"]))
	var odd: Array = kinds.filter(func(k: String) -> bool: return k != "presence")
	_check(odd.is_empty() and not hub.ignored.has(me), "everything this observer sent the hub was presence: no state, no marks, nothing the hub had to drop (%s)" % str(odd))
	var to_presenter: Array = (hub.received_by[presenter_id] as Array).filter(func(m: Dictionary) -> bool: return int(m.get("from", 0)) == me and str(m.get("t", "")) != "presence")
	_check(to_presenter.is_empty(), "the presenter was sent nothing by this observer but presence")
	var after: Array = backend.log.slice(requests_at_start).filter(func(r: Dictionary) -> bool: return not str(r["path"]).ends_with("assembly-mesh.glb") and not str(r["path"]).ends_with("/health"))
	_check(after.is_empty() and backend.log.all(func(r: Dictionary) -> bool: return not r["headers"].has("x-api-key") and r["method"] == HTTPClient.METHOD_GET), "the backend saw only GETs of the model with the view token: no key, no PUT, no POST (%d other requests)" % after.size())
	# --- leaving puts everything back
	await main.session.leave_session()
	await process_frame
	_check(not hands[1].view_only and not hands[1].own_view_input and not main._appearance_tool.local_only and not main._measure_tool.local_only and hands[1].own_view_ref == null, "leaving: the hands, the Appearance and the Measure tools are as they were")
	var view_ids_after: Array = registry.tools_of(registry.category("view")).map(func(t) -> String: return t.id)
	_check(view_ids_after == view_ids_before, "...and the tablet's View hub is the presenter's again")
	quit()
