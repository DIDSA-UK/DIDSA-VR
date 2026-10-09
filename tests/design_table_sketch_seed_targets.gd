extends SceneTree
## TARGETS for a sketch picked in the viewport (Extrude, Revolve, Sweep, Loft with no sketch open): the bodies a Boss fuses into (a Cut cuts) are picked
## with the laser, none, one or many. The Targets button switches the laser to bodies and back (the seed and its lit lines survive the round trip; a Sweep's
## path lines are read again); pulling on a body picks it, again lets it go; none picked is a NEW body for a Boss and every body for a Cut; New body still
## wins; the targets are forgotten when the tool changes and after Apply. With a sketch open nothing changes. Fake backend (a part with two bodies).
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_seed_targets.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func body(id: String) -> Dictionary:
	return {"kind": "body", "key": "body:" + id, "body_id": id}


func pull_on_body(ed, id: String) -> void:
	ed._hover_face = body(id)
	ed._toggle_body()


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	var b = table.build
	fake.track_rows = true
	fake.filtered_mesh_bytes = fake.mesh_bytes
	ed.preview_enabled = false
	await rig.draw_rectangle()
	var sk: String = ed.session.feature_id
	fake.sketch_plane = "XY"
	fake.feature_rows["PART_BOX"] = [{"id": sk, "type": "sketch", "sketch_id": ed.session.sketch_id, "plane_feature_id": null}, {"id": "sk_b", "type": "sketch", "sketch_id": "skb_internal", "plane_feature_id": null}]
	rig.main.visibility_ruled_parts.append("PART_BOX")
	await b.reload()
	table.manager.deactivate()
	ed.end_sketch()
	await rig.frames(6)
	table.table_copy.set_meta("body_ids", ["body_box", "body_top"])
	var all: Array = ed.body_ids()
	print("SMOKE the fixture part has two bodies to choose between: ", all.size() == 2, " ", all)

	# --- Extrude
	table.manager.activate("extrude")
	await rig.frames(6)
	ed._hover_face = ed.rest_sketches.candidates().filter(func(c): return c["sketch_feature_id"] == sk)[0].duplicate()
	ed._pick_sketch()
	print("SMOKE with a sketch picked, Extrude offers a Targets button (none yet) and a Boss fuses into nothing: a new body: ", table.props.option_button("targets") != null and table.props.option_button("targets").text == "Targets: none" and ed.extrude_targets() == [])
	ed.options["boss"] = false
	print("SMOKE ...a Cut with none picked cuts every body: ", ed.extrude_targets() == all)
	ed.options["boss"] = true
	table.props.option_button("targets").pressed.emit()
	await rig.frames(3)
	print("SMOKE pressing Targets switches the laser to bodies and keeps the picked sketch: ", ed.state == "pick_bodies" and ed.seed_sketch == sk and table.props.option_button("targets").button_pressed)
	pull_on_body(ed, all[0])
	print("SMOKE a pull on a body picks it: one target, the Boss fuses into just that body: ", ed.extrude_targets() == [all[0]] and table.props.option_button("targets").text == "Targets: 1 picked" and table.props.selection_text().contains("Targets: 1"))
	pull_on_body(ed, all[1])
	print("SMOKE a second makes it many: ", ed.extrude_targets() == [all[0], all[1]])
	pull_on_body(ed, all[0])
	print("SMOKE a pull on a picked body lets it go: ", ed.extrude_targets() == [all[1]])
	ed.options["boss"] = false
	print("SMOKE a Cut with one target cuts just that body (not all): ", ed.extrude_targets() == [all[1]])
	ed.options["boss"] = true
	ed.options["new_body"] = true
	print("SMOKE New body still wins over picked targets: ", ed.extrude_targets() == [])
	ed.options["new_body"] = false
	table.props.option_button("targets").pressed.emit()
	await rig.frames(3)
	print("SMOKE pressing Targets again goes back to the sketches with the seed, its lines and the tint intact: ", ed.state == "pick_sketch" and ed.seed_sketch == sk and ed.rest_sketches.tint_on and ed.seed_ready() and not table.props.option_button("targets").button_pressed)
	fake.calls.clear()
	await ed.apply_feature()
	await rig.frames(4)
	var posted: Array = fake.calls.filter(func(c): return String(c[0]).begins_with("POST") and String(c[0]).ends_with("extrude-features"))
	print("SMOKE Apply sends the picked target(s) with the extrude: ", posted.size() == 1 and posted[0][1]["target_body_ids"] == [all[1]], " ", posted)
	print("SMOKE ...and the targets are forgotten for the next one: ", ed.bodies.is_empty() and table.props.option_button("targets").text == "Targets: none")

	# --- a tool change forgets them
	await b.toggle_hidden(sk)
	await rig.frames(4)
	table.props.option_button("targets").pressed.emit()
	await rig.frames(2)
	pull_on_body(ed, all[0])
	table.manager.deactivate()
	await rig.frames(3)
	table.manager.activate("extrude")
	await rig.frames(4)
	print("SMOKE leaving the tool forgets the targets (another tool's bodies are not this one's): ", ed.bodies.is_empty() and ed.state == "pick_sketch")
	table.manager.deactivate()
	await rig.frames(3)

	# --- Sweep: the path lines come back after the round trip
	await b.set_all_visible(true)
	rig.main.set_hidden_feature_ids([], false)
	b.auto_hidden.clear()
	await b.reload()
	await rig.frames(4)
	table.table_copy.set_meta("body_ids", ["body_box", "body_top"])
	table.manager.activate("sweep")
	await rig.frames(6)
	ed._hover_face = ed.rest_sketches.candidates().filter(func(c): return c["sketch_feature_id"] == sk)[0].duplicate()
	ed._pick_sketch()
	await rig.frames(8)
	print("SMOKE Sweep, profile picked, path state: Targets is offered: ", ed.state == "pick_curves" and table.props.option_button("targets") != null)
	table.props.option_button("targets").pressed.emit()
	await rig.frames(3)
	pull_on_body(ed, all[0])
	table.props.option_button("targets").pressed.emit()
	await rig.frames(10)
	print("SMOKE ...and after picking bodies it is back to the path lines with the profile kept and the lines read again: ", ed.state == "pick_curves" and ed.seed_sketch == sk and ed.sketch_picks != null and ed.sketch_picks.candidates().size() == 4 and ed.extrude_targets() == [all[0]])
	table.manager.deactivate()
	await rig.frames(3)

	# --- Loft
	table.table_copy.set_meta("body_ids", ["body_box", "body_top"]) # a reload seats a new copy
	table.manager.activate("loft")
	await rig.frames(6)
	for id in [sk, "sk_b"]:
		ed._hover_face = ed.rest_sketches.candidates().filter(func(c): return c["sketch_feature_id"] == id)[0].duplicate()
		ed._pick_sketch()
	table.props.option_button("targets").pressed.emit()
	await rig.frames(3)
	pull_on_body(ed, all[1])
	table.props.option_button("targets").pressed.emit()
	await rig.frames(4)
	var loft: Dictionary = ed.tools["loft"].request(ed)
	print("SMOKE Loft keeps its sections through the round trip and sends the target: ", ed.seed_sketches == [sk, "sk_b"] and loft["ok"] and loft["body"]["target_body_ids"] == [all[1]])
	table.manager.deactivate()
	table.close()
	await rig.frames(2)
	quit()
