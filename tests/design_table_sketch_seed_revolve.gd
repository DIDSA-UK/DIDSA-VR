extends SceneTree
## SKETCH AS SEED, Revolve (plan step 6): with no sketch open Revolve offers the visible finished sketches like Extrude; the picked sketch is the
## profile and a second pull on one of ITS lines is the axis (the same line again lets it go; a circle or arc is refused). Apply stays off until
## both are set; the request names the sketch's feature id, its own id and the axis line; leaving or picking another sketch forgets the axis;
## Apply spends nothing that was open and the step-5 auto-hide hides the profile sketch. Fake backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_seed_revolve.gd  (see tests/README.md)

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
	ed.preview_enabled = false
	await rig.draw_rectangle()
	var sk: String = ed.session.feature_id
	var sketch_id: String = ed.session.sketch_id
	fake.sketch_plane = "XY"
	fake.entities[0]["construction"] = true # one of the lines is a construction line: an ordinary line for picking
	fake.feature_rows["PART_BOX"] = [{"id": sk, "type": "sketch", "sketch_id": sketch_id, "plane_feature_id": null}, {"id": "sk_b", "type": "sketch", "sketch_id": "skb_internal", "plane_feature_id": null}]
	rig.main.visibility_ruled_parts.append("PART_BOX")
	await b.reload()
	table.manager.deactivate()
	ed.end_sketch()
	await rig.frames(6)

	table.manager.activate("revolve")
	await rig.frames(6)
	print("SMOKE Revolve with no sketch open offers the finished sketches (pick_sketch, closed shapes tinted): ", ed.state == "pick_sketch" and ed.rest_sketches.tint_on and table.status().contains("Aim at a line"))
	var lines: Array = ed.rest_sketches.candidates()
	ed._hover_face = lines[0].duplicate()
	ed._pick_sketch()
	print("SMOKE a pull picks the sketch as the profile and the status asks for the axis: ", ed.seed_sketch == sk and ed.revolve_axis == "" and table.status().contains("spin it about"))
	print("SMOKE ...Selected says the axis is not picked yet and Apply is off: ", table.props.selection_text().contains("Axis: not picked yet") and table.props.option_button("apply").disabled and table.props.option_button("axis").text == "Axis: pick")

	# a circle or arc cannot be the axis
	var as_circle: Dictionary = lines[0].duplicate()
	as_circle["entity_type"] = "circle"
	ed._hover_face = as_circle
	ed._pick_sketch()
	print("SMOKE a circle or arc is refused as the axis: ", ed.revolve_axis == "" and table.status().contains("straight line"))

	# a second pull on a line of the same sketch is the axis
	ed._hover_face = lines[1].duplicate()
	ed._pick_sketch()
	print("SMOKE a second pull on a line of that sketch is the axis, and the seed stays: ", ed.revolve_axis == lines[1]["entity_id"] and ed.seed_sketch == sk and table.props.option_button("axis").text == "Axis: set")
	print("SMOKE ...Apply comes on: ", not table.props.option_button("apply").disabled and ed.seed_ready())
	var req: Dictionary = ed.tools["revolve"].request(ed)
	print("SMOKE ...the request names the sketch's feature id, its own id and the axis line: ", req["ok"] and req["route"] == "revolve-features" and req["body"]["sketch_feature_id"] == sk and req["body"]["axis_ref"] == {"sketch_id": sketch_id, "entity_type": "line", "entity_id": lines[1]["entity_id"]}, " ", req["body"])

	# the same line again lets the axis go
	ed._hover_face = lines[1].duplicate()
	ed._pick_sketch()
	print("SMOKE the same line again lets the axis go (Apply off again): ", ed.revolve_axis == "" and table.props.option_button("apply").disabled)
	ed._hover_face = lines[1].duplicate()
	ed._pick_sketch()

	# Apply
	fake.calls.clear()
	await ed.apply_feature()
	await rig.frames(4)
	var posted: Array = fake.calls.filter(func(c): return String(c[0]).begins_with("POST") and String(c[0]).ends_with("revolve-features"))
	print("SMOKE Apply revolves the picked sketch about that line: ", posted.size() == 1 and posted[0][1]["sketch_feature_id"] == sk and posted[0][1]["axis_ref"]["entity_id"] == lines[1]["entity_id"])
	print("SMOKE ...the profile sketch is auto-hidden and the editor is ready for the next (no axis kept): ", b.is_hidden(sk) and b.auto_note(sk) == "seed of Revolve 1" and ed.seed_sketch == "" and ed.revolve_axis == "")

	# the axis can be a line of ANOTHER sketch, a construction line counts, and Clear forgets both picks
	await b.toggle_hidden(sk)
	await rig.frames(4)
	var of_a: Array = ed.rest_sketches.candidates().filter(func(c): return c["sketch_feature_id"] == sk)
	var of_b: Array = ed.rest_sketches.candidates().filter(func(c): return c["sketch_feature_id"] == "sk_b")
	ed._hover_face = of_a[1].duplicate()
	ed._pick_sketch()
	ed._hover_face = of_b[0].duplicate()
	ed._pick_sketch()
	print("SMOKE with the profile picked, a line of ANOTHER sketch is the axis (the profile stays): ", ed.seed_sketch == sk and ed.revolve_axis == of_b[0]["entity_id"] and ed.revolve_axis_sketch == "skb_internal")
	var other: Dictionary = ed.tools["revolve"].request(ed)
	print("SMOKE ...and the request's axis_ref names that sketch: ", other["ok"] and other["body"]["axis_ref"]["sketch_id"] == "skb_internal" and other["body"]["sketch_feature_id"] == sk)
	var construction_line: Dictionary = of_a.filter(func(c): return c["construction"])[0]
	ed._hover_face = construction_line.duplicate()
	ed._pick_sketch()
	print("SMOKE a construction line is pickable as the axis like any line: ", ed.revolve_axis == construction_line["entity_id"] and ed.revolve_axis_sketch == sketch_id)
	print("SMOKE Revolve offers Clear once a profile is picked, and it forgets profile and axis: ", table.props.option_button("clear_seed") != null)
	await ed.on_option("clear_seed")
	print("SMOKE ...Clear leaves nothing picked: ", ed.seed_sketch == "" and ed.revolve_axis == "" and ed.revolve_axis_sketch == "" and table.props.option_button("clear_seed") == null)
	ed._hover_face = ed.rest_sketches.candidates()[0].duplicate()
	ed._pick_sketch()
	ed._hover_face = ed.rest_sketches.candidates()[1].duplicate()
	ed._pick_sketch()
	table.manager.deactivate()
	await rig.frames(3)
	print("SMOKE leaving the tool forgets the seed and the axis: ", ed.seed_sketch == "" and ed.revolve_axis == "" and ed.state == "pick_plane")
	table.close()
	await rig.frames(2)
	quit()
