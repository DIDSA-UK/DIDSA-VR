extends SceneTree
## SKETCH AS SEED, Loft and Sweep (plan step 6). Loft with no sketch open: each pull on a visible sketch adds it as the next section (pick order), another
## pull takes it out, a sketch with no closed shape is refused, Apply needs two, the request lists the sections in order, hiding a section drops it, Apply
## makes the loft and the auto-hide hides every section. Sweep with no sketch open: a pull picks the PROFILE sketch, the editor then offers the lines of the
## OTHER sketches for the path (the profile stays), the request names the profile and the path refs, and Apply hides the profile and the path sketch.
## A Build row's Edit still opens Loft / Sweep on their own line picking (design_table_loft_sweep.gd). Fake backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_sketch_seed_more.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func lines_of(ed, sketch: String) -> Array:
	return ed.rest_sketches.candidates().filter(func(c): return str(c["sketch_feature_id"]) == sketch)


func pull_on(ed, sketch: String) -> void:
	ed._hover_face = lines_of(ed, sketch)[0].duplicate()
	ed._pick_sketch()


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
	var sk_a: String = ed.session.feature_id
	var id_a: String = ed.session.sketch_id
	fake.sketch_plane = "XY"
	fake.feature_rows["PART_BOX"] = [
		{"id": sk_a, "type": "sketch", "sketch_id": id_a, "plane_feature_id": null},
		{"id": "sk_b", "type": "sketch", "sketch_id": "skb_internal", "plane_feature_id": null},
	]
	rig.main.visibility_ruled_parts.append("PART_BOX")
	await b.reload()
	table.manager.deactivate()
	ed.end_sketch()
	await rig.frames(6)

	# --- Loft
	table.manager.activate("loft")
	await rig.frames(6)
	print("SMOKE Loft with no sketch open offers the visible sketches, both of them tinted and drawn: ", ed.state == "pick_sketch" and ed.rest_sketches.candidates().size() == 8 and ed.rest_sketches.tint_on)
	pull_on(ed, sk_a)
	print("SMOKE a pull adds that sketch as the first section; one section is not a loft: ", ed.seed_sketches == [sk_a] and table.props.option_button("apply").disabled and table.props.selection_text().contains("Sections: Sketch 1"))
	pull_on(ed, "sk_b")
	print("SMOKE a pull on another sketch adds the second, in pick order, and Apply comes on: ", ed.seed_sketches == [sk_a, "sk_b"] and not table.props.option_button("apply").disabled and ed.tools["loft"].sections(ed) == [sk_a, "sk_b"])
	var req: Dictionary = ed.tools["loft"].request(ed)
	print("SMOKE ...the request lists the sections in that order: ", req["ok"] and req["body"]["sections"] == [{"sketch_feature_id": sk_a}, {"sketch_feature_id": "sk_b"}])
	pull_on(ed, sk_a)
	print("SMOKE another pull on a picked sketch takes it out (the order of the rest stays): ", ed.seed_sketches == ["sk_b"] and table.props.option_button("apply").disabled)
	pull_on(ed, sk_a)
	print("SMOKE ...and putting it back makes it the LAST section: ", ed.seed_sketches == ["sk_b", sk_a])
	rig.main.set_feature_hidden("sk_b", true)
	b.changed.emit()
	await rig.frames(4)
	print("SMOKE hiding a section drops it: ", ed.seed_sketches == [sk_a])
	rig.main.set_feature_hidden("sk_b", false)
	b.changed.emit()
	await rig.frames(4)
	pull_on(ed, "sk_b")
	ed.rest_sketches.sketches[sk_a]["closed"] = false
	ed.seed_sketches = ["sk_b"]
	pull_on(ed, sk_a)
	print("SMOKE a sketch with no closed shape is refused as a section: ", ed.seed_sketches == ["sk_b"] and table.status().contains("has no closed shape"))
	ed.rest_sketches.sketches[sk_a]["closed"] = true
	pull_on(ed, sk_a)
	fake.calls.clear()
	await ed.apply_feature()
	await rig.frames(4)
	var lofts: Array = fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/loft-features")
	print("SMOKE Apply makes the loft through the two picked sketches: ", lofts.size() == 1 and lofts[0][1]["sections"] == [{"sketch_feature_id": "sk_b"}, {"sketch_feature_id": sk_a}])
	print("SMOKE ...every section is auto-hidden ('seed of Loft 1') and the sections are forgotten: ", b.is_hidden(sk_a) and b.is_hidden("sk_b") and b.auto_note("sk_b") == "seed of Loft 1" and ed.seed_sketches.is_empty() and ed.state == "pick_sketch")
	table.manager.deactivate()
	await rig.frames(3)

	# --- Sweep: show the sketches again, new tool
	await b.set_all_visible(true)
	fake.feature_rows["PART_BOX"] = [
		{"id": sk_a, "type": "sketch", "sketch_id": id_a, "plane_feature_id": null},
		{"id": "sk_b", "type": "sketch", "sketch_id": "skb_internal", "plane_feature_id": null},
	]
	rig.main.set_hidden_feature_ids([], false)
	b.auto_hidden.clear()
	await b.reload()
	await rig.frames(4)
	table.manager.activate("sweep")
	await rig.frames(6)
	print("SMOKE Sweep with no sketch open offers the visible sketches for the PROFILE first: ", ed.state == "pick_sketch" and table.status().contains("Aim at a line"))
	pull_on(ed, sk_a)
	await rig.frames(8)
	print("SMOKE a pull picks the profile and the editor moves on to the path: pick_curves, the profile kept, its own lines not offered: ", ed.state == "pick_curves" and ed.seed_sketch == sk_a and ed.sketch_picks != null and ed.sketch_picks.candidates().size() == 4 and ed.sketch_picks.candidates().all(func(c): return c["sketch_feature_id"] == "sk_b"))
	print("SMOKE ...Selected shows the profile and Apply is off until a path line is picked: ", table.props.selection_text().contains("Profile: Sketch 1") and table.props.option_button("apply").disabled)
	ed._hover_face = ed.sketch_picks.candidates()[0].duplicate()
	ed._toggle_curve()
	await rig.frames(2)
	var sw: Dictionary = ed.tools["sweep"].request(ed)
	print("SMOKE a path line makes it ready: the request names the profile sketch and the path ref: ", not table.props.option_button("apply").disabled and sw["ok"] and sw["body"]["sketch_feature_id"] == sk_a and sw["body"]["path_refs"].size() == 1 and sw["body"]["path_refs"][0]["sketch_id"] == "skb_internal", " ", sw)
	fake.calls.clear()
	await ed.apply_feature()
	await rig.frames(4)
	var sweeps: Array = fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/sweep-features")
	print("SMOKE Apply sweeps the picked profile along the path: ", sweeps.size() == 1 and sweeps[0][1]["sketch_feature_id"] == sk_a)
	print("SMOKE ...the profile AND the path sketch are auto-hidden, and the profile is forgotten: ", b.is_hidden(sk_a) and b.is_hidden("sk_b") and ed.seed_sketch == "" and ed.curve_picks.is_empty() and ed.state == "pick_sketch")
	table.manager.deactivate()
	table.close()
	await rig.frames(2)
	quit()
