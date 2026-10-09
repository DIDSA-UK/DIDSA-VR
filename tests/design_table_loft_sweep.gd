extends SceneTree
## LOFT and SWEEP (Phase 6.2 / 6.3), fake backend. Loft: picking curves of sketches makes the sections (distinct sketches, in pick order), two are needed,
## Boss / Cut / Ruled, the coarse preview POSTs loft-features/coarse-preview and creates nothing, Apply sends loft-features, the Build row reads
## "Boss, 2 sections", Edit opens the tool with the feature's settings and Apply PATCHes it (one Undo step restoring the old values, Redo the new).
## Sweep: with a profile sketch open, path lines picked from earlier sketches are the ordered path_refs, the preview creates the feature at once
## (eager) and Apply keeps it and spends the sketch, a PATCH never resends the profile sketch.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_loft_sweep.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")


func curve(sketch_feature: String, sketch: String, id: String) -> Dictionary:
	return {"kind": "curve", "sketch_feature_id": sketch_feature, "sketch_id": sketch, "entity_type": "line", "entity_id": id, "key": "curve:%s:%s" % [sketch, id]}


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	fake.coarse_bodies = [{"body_id": "coarse-preview", "source": "coarse", "mesh": {"vertices": [[0, 0, 0], [10, 0, 0], [0, 10, 0], [0, 0, 10]], "normals": [[0, 0, -1], [0, 0, -1], [0, 0, -1], [0, 0, -1]], "triangle_indices": [[0, 2, 1], [0, 1, 3], [0, 3, 2], [1, 2, 3]], "edges": []}}]
	# --- Loft
	table.manager.activate("loft")
	await rig.frames(3)
	print("SMOKE choosing Loft with no sketch open offers the visible sketches (pick_sketch) with Apply greyed: ", ed.state == "pick_sketch" and table.props.option_button("apply").disabled and table.props.option_ids() == ["boss", "cut", "ruled", "clear_curves", "apply"])
	ed.curve_picks = [curve("sk_a", "ska", "l1")]
	ed._update_options()
	print("SMOKE one sketch is not a loft: ", table.props.option_button("apply").disabled and not ed.tools["loft"].request(ed)["ok"])
	ed.curve_picks.append(curve("sk_a", "ska", "l2"))
	ed.curve_picks.append(curve("sk_b", "skb", "l9"))
	ed._update_options()
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview.is_showing())
	var req: Dictionary = ed.tools["loft"].request(ed)
	print("SMOKE two curves of one sketch and one of another are TWO sections, in pick order: ", LoftSections(ed) == ["sk_a", "sk_b"] and req["ok"] and req["body"]["sections"] == [{"sketch_feature_id": "sk_a"}, {"sketch_feature_id": "sk_b"}], " ", table.props.option_button("apply").text)
	var coarse: Array = rig.calls_to("coarse-preview")
	print("SMOKE the preview POSTs loft-features/coarse-preview with that body and creates nothing: ", coarse.size() >= 1 and String(coarse.back()[0]).contains("loft-features/coarse-preview") and rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/loft-features").is_empty() and ed.preview.is_showing())
	await ed.on_option("ruled")
	await ed.apply_feature()
	var made: Array = rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/loft-features")
	print("SMOKE Apply sends loft-features: boss, ruled, two sections: ", made.size() == 1 and made[0][1]["mode"] == "boss" and made[0][1]["ruled"] == true and made[0][1]["sections"].size() == 2, " ", made)
	var loft_id: String = ed.feature_stack.back()
	print("SMOKE ...it is on Undo's stack and the preview is gone: ", ed.feature_stack.size() == 1 and not ed.preview.is_showing())
	# Build row, Edit
	var row := {"id": loft_id, "type": "loft", "sections": [{"sketch_feature_id": "sk_a"}, {"sketch_feature_id": "sk_b"}], "mode": "boss", "ruled": true, "target_body_ids": []}
	fake.feature_rows["PART_BOX"] = [row]
	await table.build.reload()
	print("SMOKE the Build row reads Boss, 2 sections, ruled and Edit is offered: ", BuildTree.summary(table.build.features, 0) == "Boss, 2 sections, ruled" and table.build.can_edit(loft_id))
	table.manager.deactivate()
	await rig.frames(2)
	await ed.begin_tool_edit(loft_id)
	await rig.frames(3)
	print("SMOKE Edit opens Loft with the feature's settings (Ruled on, its two sections): ", table.active_tool == "loft" and ed.options["ruled"] == true and LoftSections(ed) == ["sk_a", "sk_b"] and not ed.editing.is_empty())
	await ed.on_option("ruled")
	await ed.on_option("cut")
	print("SMOKE ...a change shows (Cut is on) and nothing is sent yet: ", not ed.options["boss"] and rig.calls_to("PATCH /document/parts/PART_BOX/loft-features/").is_empty())
	ed.options["boss"] = true
	await ed.apply_feature()
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/loft-features/" + loft_id)
	print("SMOKE Apply PATCHes the loft (ruled now off, same sections) and leaves the tool: ", patched.size() == 1 and patched[0][1]["ruled"] == false and patched[0][1]["sections"].size() == 2 and table.active_tool == "" and ed.editing.is_empty(), " ", patched)
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/loft-features/" + loft_id)
	print("SMOKE Undo puts the old values back in one step (ruled true again): ", patched.size() == 2 and patched.back()[1]["ruled"] == true and ed.can_redo())
	await ed.redo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/loft-features/" + loft_id)
	print("SMOKE Redo puts the new ones back: ", patched.size() == 3 and patched.back()[1]["ruled"] == false)
	# --- Sweep
	fake.feature_rows["PART_BOX"] = []
	table.manager.deactivate()
	await rig.draw_rectangle()
	table.manager.activate("sweep")
	await rig.frames(3)
	print("SMOKE with the profile sketch open Sweep goes to curve picking and keeps the sketch: ", ed.state == "pick_curves" and ed.session != null and table.props.option_ids() == ["boss", "cut", "clear_curves", "apply"] and table.props.option_button("apply").disabled)
	ed.curve_picks = [curve("", "skp", "p1"), curve("", "skp", "p2")]
	ed._update_options()
	ed.schedule_preview()
	await rig.settle(func() -> bool: return ed.preview_feature_id != "")
	var sw: Array = rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/sweep-features")
	print("SMOKE two path lines make the eager preview: the sweep is created at once with the profile sketch and the path refs in order: ", sw.size() == 1 and sw[0][1]["sketch_feature_id"] == ed.session.feature_id and sw[0][1]["path_refs"] == [{"sketch_id": "skp", "entity_type": "line", "entity_id": "p1"}, {"sketch_id": "skp", "entity_type": "line", "entity_id": "p2"}] and sw[0][1]["mode"] == "boss")
	await ed.apply_feature()
	print("SMOKE Apply keeps it (no second create), spends the sketch and forgets the picks: ", rig.fake.calls.filter(func(c): return String(c[0]) == "POST /document/parts/PART_BOX/sweep-features").size() == 1 and ed.session == null and ed.curve_picks.is_empty() and ed.feature_stack.size() >= 1)
	var patch_req: Dictionary = {"ok": true, "body": {"sketch_feature_id": "x", "path_refs": [], "mode": "boss", "target_body_ids": []}}
	print("SMOKE a sweep PATCH never carries the profile sketch: ", not ed.tools["sweep"].patch_body(patch_req).has("sketch_feature_id"))
	print("SMOKE the Build row of a sweep: ", BuildTree.summary([{"type": "sweep", "mode": "cut", "path_refs": [{}, {}]}], 0) == "Cut along 2 path line(s)")
	quit()


func LoftSections(ed) -> Array:
	return ed.tools["loft"].sections(ed)
