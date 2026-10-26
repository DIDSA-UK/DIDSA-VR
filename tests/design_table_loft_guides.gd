extends SceneTree
## LOFT GUIDES (DIDSA-CAD docs/loft-gordon-and-helix-plan.md, milestone 4), fake backend: Add guide picks the curves of one guide with the laser (each pull adds a curve, again takes it
## out), Done keeps it, any number of guides, each can be removed; a guide that is being picked greys Apply; the request carries `guide_curves` (an empty list always, so an edit can clear them);
## Ruled turns the guide rows off and sends none; Edit loads a loft's guides and PATCHes them back; the Build row says how many; the backend's warnings come after "Loft done."; a guide that
## misses a section reads as the backend's own sentence. Needs no sketch geometry: the curves are the picks the laser would have made.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_loft_guides.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const CadApi := preload("res://scripts/design_table/cad_api.gd")
const Visibility := preload("res://scripts/design_table/visibility.gd")


func curve(sketch_feature: String, sketch: String, id: String) -> Dictionary:
	return {"kind": "curve", "sketch_feature_id": sketch_feature, "sketch_id": sketch, "entity_type": "line", "entity_id": id, "key": "curve:%s:%s" % [sketch, id]}


func pull(ed, c: Dictionary) -> void:
	ed._hover_face = c
	ed._toggle_curve()


func ref(sketch: String, id: String) -> Dictionary:
	return {"sketch_id": sketch, "entity_type": "line", "entity_id": id}


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	fake.track_rows = true
	ed.preview_enabled = false
	fake.coarse_bodies = [{"body_id": "coarse-preview", "source": "coarse", "mesh": {"vertices": [[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], "normals": [[0, 0, -1], [0, 0, -1], [0, 0, -1], [0, 0, -1]], "triangle_indices": [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]], "edges": []}}]

	table.manager.activate("loft")
	await rig.frames(3)
	ed.seed_sketches = ["sk_a", "sk_b"] # the two sections, as the laser's pulls on their lines make them
	ed._update_options()
	var ids: Array = table.props.option_ids()
	print("SMOKE with two sections the Loft panel offers Add guide (before Clear and Apply): ", ids == ["boss", "cut", "ruled", "lo_thin", "guide_add", "clear_curves", "targets", "apply"] and not table.props.option_button("apply").disabled, " ", ids)
	var req: Dictionary = ed.tools["loft"].request(ed)
	print("SMOKE ...a loft with no guide sends guide_curves: [] (so an edit can clear them): ", req["ok"] and req["body"]["guide_curves"] == [])

	# a guide
	await ed.on_option("guide_add")
	await rig.frames(2)
	print("SMOKE Add guide moves the laser to curve picking and keeps the sections: ", ed.state == "pick_curves" and ed.seed_sketches == ["sk_a", "sk_b"] and ed.is_picking_guide())
	ids = table.props.option_ids()
	print("SMOKE ...the panel offers Done (greyed with no curve yet) and Cancel guide, and Apply is off: ", ids.has("guide_done") and ids.has("guide_cancel") and not ids.has("guide_add") and table.props.option_button("guide_done").disabled and table.props.option_button("apply").disabled)
	pull(ed, curve("sk_g", "skg", "l1"))
	pull(ed, curve("sk_g", "skg", "l2"))
	print("SMOKE each pull adds a curve to the guide being built, in order; the sections' picks are not touched: ", ed.guide_draft.size() == 2 and ed.curve_picks.is_empty() and ed.guides.is_empty() and table.props.option_button("guide_done").text == "Done: guide 1 (2 curves)")
	pull(ed, curve("sk_g", "skg", "l2"))
	print("SMOKE ...a second pull on the same curve takes it out again: ", ed.guide_draft.size() == 1 and ed.guide_draft[0]["entity_id"] == "l1")
	pull(ed, curve("sk_g", "skg", "l2"))
	await ed.on_option("guide_done")
	await rig.frames(2)
	print("SMOKE Done keeps it as guide 1 and goes back to picking sections (pick_sketch), Apply on again: ", ed.guides.size() == 1 and ed.state == "pick_sketch" and not ed.is_picking_guide() and ed.seed_sketches == ["sk_a", "sk_b"] and not table.props.option_button("apply").disabled)
	print("SMOKE ...the panel lists it with a Remove row and Add guide again: ", table.props.option_ids().has("guide_del_0") and table.props.option_ids().has("guide_add") and table.props.option_button("guide_del_0").text == "Remove guide 1 (2 curves)")

	# a second guide, cancelled, then a real one
	await ed.on_option("guide_add")
	await rig.frames(2)
	pull(ed, curve("sk_g", "skg", "l9"))
	await ed.on_option("guide_cancel")
	await rig.frames(2)
	print("SMOKE Cancel guide drops the one being built and keeps the finished one: ", ed.guides.size() == 1 and ed.guide_draft.is_empty() and ed.state == "pick_sketch")
	await ed.on_option("guide_add")
	await rig.frames(2)
	pull(ed, curve("sk_h", "skh", "m1"))
	await ed.on_option("guide_done")
	await rig.frames(2)
	req = ed.tools["loft"].request(ed)
	print("SMOKE two guides are sent as guide_curves, each the ordered chain of its sketch entity refs: ", req["ok"] and req["body"]["guide_curves"] == [[ref("skg", "l1"), ref("skg", "l2")], [ref("skh", "m1")]], " ", req["body"].get("guide_curves"))

	# remove one
	await ed.on_option("guide_del_0")
	req = ed.tools["loft"].request(ed)
	print("SMOKE Remove guide 1 leaves the second: ", ed.guides.size() == 1 and req["body"]["guide_curves"] == [[ref("skh", "m1")]])
	await ed.on_option("guide_add")
	await rig.frames(2)
	pull(ed, curve("sk_g", "skg", "l1"))
	await ed.on_option("guide_done")
	await rig.frames(2)

	# ruled
	await ed.on_option("ruled")
	req = ed.tools["loft"].request(ed)
	print("SMOKE Ruled hides the guide rows and sends no guides (the backend refuses the pair), the guides are kept: ", not table.props.option_ids().has("guide_add") and req["body"]["guide_curves"] == [] and req["body"]["ruled"] == true and ed.guides.size() == 2)
	await ed.on_option("ruled")
	print("SMOKE ...Ruled off brings them back: ", table.props.option_ids().has("guide_add") and (ed.tools["loft"].request(ed)["body"]["guide_curves"] as Array).size() == 2)

	# apply, with a warning from the backend
	fake.feature_warnings = ["Guide 2 misses section 2 by 0.30 mm; the surface was bent to meet both, so it deviates from the guide by up to that much."]
	await ed.apply_feature()
	var made: Array = rig.calls_to("POST /document/parts/PART_BOX/loft-features")
	made = made.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/loft-features")
	print("SMOKE Apply sends the loft with its two guides: ", made.size() == 1 and (made[0][1]["guide_curves"] as Array).size() == 2 and made[0][1]["sections"].size() == 2)
	print("SMOKE ...the backend's warning follows 'Loft done.' on the status line: ", table.status().begins_with("Loft done.") and table.status().contains("misses section 2"), " ", table.status())
	print("SMOKE ...and the guides are forgotten for the next loft: ", ed.guides.is_empty() and ed.guide_draft.is_empty())
	var loft_id: String = ed.feature_stack.back()

	# Build row and Edit
	fake.feature_warnings = []
	var row := {"id": loft_id, "type": "loft", "sections": [{"sketch_feature_id": "sk_a"}, {"sketch_feature_id": "sk_b"}], "mode": "boss", "ruled": false, "target_body_ids": [],
		"guide_curves": [[ref("skg", "l1"), ref("skg", "l2")], [ref("skh", "m1")]]}
	fake.feature_rows["PART_BOX"] = [row]
	await table.build.reload()
	print("SMOKE the Build row reads '2 sections, 2 guides' and Edit is offered: ", BuildTree.summary(table.build.features, 0) == "Boss, 2 sections, 2 guides" and table.build.can_edit(loft_id))
	var one := row.duplicate(true)
	one["guide_curves"] = [[ref("skg", "l1")]]
	print("SMOKE ...one guide reads '1 guide': ", BuildTree.summary([one], 0) == "Boss, 2 sections, 1 guide")
	var by_sketch := {"skg": "sk_g", "skh": "sk_h"}
	print("SMOKE ...the guides' sketches are consumed by the loft, like a sweep's path (hidden with it): ", Visibility._seeds_of_row(row, by_sketch).has("sk_g") and Visibility._seeds_of_row(row, by_sketch).has("sk_h") and Visibility._seeds_of_row(row, by_sketch).has("sk_a"))
	table.manager.deactivate()
	await rig.frames(2)
	await ed.begin_tool_edit(loft_id)
	await rig.frames(3)
	print("SMOKE Edit loads the loft's guides (two, the first of two curves): ", table.active_tool == "loft" and ed.guides.size() == 2 and (ed.guides[0] as Array).size() == 2 and (ed.guides[1] as Array).size() == 1 and table.props.option_ids().has("guide_del_1"))
	await ed.on_option("guide_del_1")
	await ed.apply_feature()
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/loft-features/" + loft_id)
	print("SMOKE ...removing the second guide and Apply PATCHes guide_curves with the first only: ", patched.size() == 1 and patched[0][1]["guide_curves"] == [[ref("skg", "l1"), ref("skg", "l2")]], " ", patched)
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/loft-features/" + loft_id)
	print("SMOKE Undo puts both guides back (the row's old guide_curves): ", patched.size() == 2 and (patched.back()[1]["guide_curves"] as Array).size() == 2)

	# a guide that misses: the backend's own sentence
	var parsed := {"detail": {"type": "invalid_guide_curve_ref", "index": 1, "section": 0, "detail": "guide 2 passes 30.00 mm from section 1; it has to reach every section (within 1.70 mm)"}}
	print("SMOKE a guide that misses a section is reported in the backend's own words (guide and section named): ", CadApi.error_text(parsed).begins_with("guide 2 passes 30.00 mm from section 1"))
	print("SMOKE ...other 422s still read as their type: ", CadApi.error_text({"detail": {"type": "loft_failed", "detail": "x"}}) == "loft_failed")
	print("SMOKE the request refuses an empty guide: ", not PartFeatures.loft_request(["a", "b"], true, false, [], 0.0, false, [[]])["ok"])
	quit()
