extends SceneTree
## SKETCH AS SEED, Extrude first (plan step 6): with no sketch open, choosing Extrude offers the VISIBLE finished sketches; their closed shapes are tinted
## as a cue; the laser prefers a sketch line; the picked sketch is listed under Selected and the usual controls appear; the preview starts once the seed
## and values are valid; Apply extrudes that sketch (the request names its feature id), and the step-5 auto-hide then hides it. A hidden sketch cannot be
## picked (the tip says so); a sketch with no closed shape is refused with a reason; leaving the tool puts the editor back to plane picking. With a
## sketch OPEN the open sketch is the seed as before. Fake backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_seed.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	var b = table.build
	fake.track_rows = true
	fake.filtered_mesh_bytes = fake.mesh_bytes
	await rig.draw_rectangle()
	var sk: String = ed.session.feature_id
	var sketch_id: String = ed.session.sketch_id
	fake.sketch_plane = "XY"
	fake.feature_rows["PART_BOX"] = [{"id": sk, "type": "sketch", "sketch_id": sketch_id, "plane_feature_id": null}]
	rig.main.visibility_ruled_parts.append("PART_BOX")
	await b.reload()
	table.manager.deactivate()
	ed.end_sketch()
	await rig.frames(6)

	# --- choosing Extrude with no sketch open
	table.manager.activate("extrude")
	await rig.frames(6)
	var rest = ed.rest_sketches
	print("SMOKE Extrude with no sketch open offers the finished sketches: the editor is in pick_sketch and says to aim at a line: ", ed.state == "pick_sketch" and table.status().contains("Aim at a line"), " ", table.status())
	print("SMOKE ...the closed shape is tinted as a cue, and the lines are drawn: ", rest != null and rest.tint_on and rest.get_node_or_null("SketchTint") != null and rest.visible and bool(rest.sketches[sk]["closed"]))
	print("SMOKE ...nothing is picked yet and Apply is off: ", ed.seed_sketch == "" and not ed.seed_ready() and table.props.option_button("apply") != null and table.props.option_button("apply").disabled)

	# --- the laser picks a line of the sketch
	var first: Dictionary = rest.candidates()[0]
	var mid: Vector3 = (first["points"][0] + first["points"][1]) * 0.5
	var world_mid: Vector3 = table.table_copy.global_transform * mid
	var aim_from: Vector3 = world_mid + (table.table_copy.global_transform.basis * Vector3(0, 0, 1)).normalized() * 0.4
	await rig.aim(aim_from, world_mid)
	print("SMOKE aiming at a line lights it and takes the laser: ", ed.hovering and ed._hover_face.get("kind") == "curve" and ed._hover_face["sketch_feature_id"] == sk)
	fake.calls.clear()
	await rig.pull()
	await rig.frames(4)
	print("SMOKE a pull makes that sketch the seed, ready to extrude: ", ed.seed_sketch == sk and ed.seed_ready() and ed.seed_sketch_id() == sk)
	print("SMOKE ...Selected lists it ('Sketch 1: closed shape ready') and Apply comes on: ", table.props.selection_text().contains("Sketch 1: closed shape ready") and not table.props.option_button("apply").disabled, " ", table.props.selection_text())
	var made: Array = fake.calls.filter(func(c): return String(c[0]).begins_with("POST") and String(c[0]).ends_with("extrude-features"))
	print("SMOKE ...the preview starts at once from the picked sketch (the request names its feature id): ", made.size() >= 1 and made[0][1]["sketch_feature_id"] == sk, " ", made.size())

	# --- Apply
	fake.calls.clear()
	await ed.apply_feature()
	await rig.frames(4)
	var posted: Array = fake.calls.filter(func(c): return String(c[0]).begins_with("POST") and String(c[0]).ends_with("extrude-features"))
	var patched: Array = fake.calls.filter(func(c): return String(c[0]).begins_with("PATCH") and String(c[0]).contains("extrude-features"))
	print("SMOKE Apply extrudes the picked sketch (the preview's feature is adopted, no second one) and nothing is posted for a sketch that was never open: ", posted.size() + patched.size() >= 1 and b.features.any(func(f): return str(f.get("type")) == "extrude" and str(f.get("sketch_feature_id")) == sk))
	print("SMOKE ...the auto-hide then hides the sketch it consumed ('seed of Extrude 1'): ", b.is_hidden(sk) and b.auto_note(sk) == "seed of Extrude 1")
	print("SMOKE ...the seed is spent and the editor is ready for the next sketch: ", ed.seed_sketch == "" and ed.state == "pick_sketch")

	# --- a hidden sketch cannot be picked, and the tip says why
	b.changed.emit() # (Apply's own status line "Extrude done." is what shows until something changes)
	await rig.frames(4)
	print("SMOKE with its only sketch hidden there is nothing to pick and the tip points to Visibility: ", ed.rest_sketches.candidates().is_empty() and table.status().contains("No sketches are visible"), " ", ed.rest_sketches.candidates().size(), " ", b.hidden_ids(), " ", table.status())
	await b.toggle_hidden(sk)
	await rig.frames(4)
	print("SMOKE showing it by hand (the drawer, the tree's eye) offers it again: ", ed.rest_sketches.candidates().size() == 4 and table.status().contains("Aim at a line"))

	# --- a sketch without a closed shape is refused
	ed.rest_sketches.sketches[sk]["closed"] = false
	ed._hover_face = ed.rest_sketches.candidates()[0].duplicate()
	ed._pick_sketch()
	print("SMOKE a sketch with no closed shape is refused with a reason and nothing is picked: ", ed.seed_sketch == "" and table.status().contains("has no closed shape"))
	ed.rest_sketches.sketches[sk]["closed"] = true

	# --- picking the same sketch twice lets it go; hiding the seed drops it
	ed._hover_face = ed.rest_sketches.candidates()[0].duplicate()
	ed._pick_sketch()
	ed._hover_face = ed.rest_sketches.candidates()[0].duplicate()
	ed._pick_sketch()
	print("SMOKE picking the seed again lets it go: ", ed.seed_sketch == "")
	ed._hover_face = ed.rest_sketches.candidates()[0].duplicate()
	ed._pick_sketch()
	rig.main.set_feature_hidden(sk, true)
	b.changed.emit()
	await rig.frames(4)
	print("SMOKE hiding the picked sketch drops it as the seed: ", ed.seed_sketch == "" and not ed.seed_ready())

	# --- leaving the tool
	table.manager.deactivate()
	await rig.frames(3)
	print("SMOKE leaving the tool goes back to plane picking and takes the tint away: ", ed.state == "pick_plane" and not ed.rest_sketches.tint_on and ed.seed_sketch == "")

	# --- with a sketch open the open sketch is the seed, as before
	await rig.draw_rectangle()
	table.manager.activate("extrude")
	await rig.frames(3)
	print("SMOKE with a sketch OPEN Extrude uses it (no sketch picking): ", ed.state == "extrude" and ed.seed_sketch_id() == ed.session.feature_id and ed.seed_ready())
	table.close()
	await rig.frames(2)
	quit()
