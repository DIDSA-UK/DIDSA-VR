extends SceneTree
## The AUTO-HIDE lifecycle (plan step 5; table_build.gd note_applied / note_removed / edit_begun, table_editor.gd's Apply, Undo and Redo). Fake backend
## that keeps the part's feature rows (fake.track_rows). A confirmed extrude hides the sketch it consumed (a failed Apply changes nothing); the tree
## says "seed of Extrude 1"; Undo brings the sketch back, Redo hides it again; a sketch the user showed is not re-hidden, one the user hid by hand is
## never auto-shown; the load rule records the same relation; rolling every consumer back shows the sketch while rolled back and hides it again on
## roll-forward; a feature open for editing shows its seed sketch and gives it back afterwards. Nothing of this is saved except hidden_feature_ids.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_visibility_auto.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	var b = table.build
	var main = rig.main
	ed.preview_enabled = false
	fake.track_rows = true
	fake.filtered_mesh_bytes = fake.mesh_bytes
	await rig.draw_rectangle()
	var sk: String = ed.session.feature_id
	fake.feature_rows["PART_BOX"] = [{"id": sk, "type": "sketch", "sketch_id": ed.session.sketch_id, "plane_feature_id": null}]
	main.visibility_ruled_parts.append("PART_BOX") # the load rule has met this part
	await b.reload()
	print("SMOKE a new sketch is visible: ", not b.is_hidden(sk) and b.auto_hidden.is_empty())

	# a failed Apply changes nothing
	table.manager.activate("extrude")
	fake.fail = "extrude-features"
	await ed.apply_feature()
	fake.fail = ""
	print("SMOKE a failed Apply hides nothing and records nothing: ", not b.is_hidden(sk) and b.auto_hidden.is_empty() and main.hidden_feature_ids().is_empty())

	# Apply
	await ed.apply_feature()
	var ex: String = ed.feature_stack.back()
	print("SMOKE a confirmed extrude hides the sketch it consumed: ", b.is_hidden(sk) and main.hidden_feature_ids() == [sk] and b.auto_hidden.get(sk, []) == [ex])
	print("SMOKE ...the tree row says 'seed of Extrude 1', not just 'hidden': ", b.auto_note(sk) == "seed of Extrude 1" and table.tree._build_rows.find_children("*", "Button", true, false).any(func(x): return x.text.begins_with("Sketch 1") and x.text.contains("seed of Extrude 1")))
	print("SMOKE ...and the extrude itself is not hidden: ", not b.is_hidden(ex))

	# Undo / Redo
	await ed.undo()
	print("SMOKE Undo of that feature brings the sketch back: ", not b.is_hidden(sk) and b.auto_hidden.is_empty() and main.hidden_feature_ids().is_empty())
	await ed.redo()
	var ex2: String = ed.feature_stack.back()
	print("SMOKE Redo hides it again (the new feature consumes it): ", b.is_hidden(sk) and b.auto_hidden.get(sk, []) == [ex2])

	# the user shows it by hand: it stays shown, and the record is gone
	await b.toggle_hidden(sk)
	await rig.frames(2)
	print("SMOKE showing it by hand keeps it shown and forgets the auto-hide: ", not b.is_hidden(sk) and b.auto_hidden.is_empty())
	await b.reload()
	print("SMOKE ...a reload does not hide it again: ", not b.is_hidden(sk))

	# hidden by hand: never auto-shown
	await b.toggle_hidden(sk)
	print("SMOKE hidden by hand it has no auto-hide record: ", b.is_hidden(sk) and b.auto_hidden.is_empty() and b.auto_note(sk) == "")
	await ed.undo()
	print("SMOKE Undo of the feature does not show a sketch the user hid by hand: ", b.is_hidden(sk))
	main.set_hidden_feature_ids([], false)

	# rollback (rows kept by the fake: sketch, then a feature that consumes it)
	fake.feature_rows["PART_BOX"] = [{"id": "sk1", "type": "sketch", "sketch_id": "s1"}, {"id": "ex1", "type": "extrude", "sketch_feature_id": "sk1"}, {"id": "fi1", "type": "fillet"}]
	main.visibility_ruled_parts.clear()
	await b.reload()
	print("SMOKE the load rule records who consumed each hidden sketch: ", b.is_hidden("sk1") and b.auto_hidden.get("sk1", []) == ["ex1"] and b.auto_note("sk1") == "seed of Extrude 1")
	b.rollback_to = "sk1" # rolled back to the sketch: the extrude and the fillet are skipped
	print("SMOKE rolled back past its consumer, the sketch shows again (not consumed any more): ", not b.is_hidden("sk1") and b.auto_note("sk1") == "")
	b.rollback_to = "ex1" # rolled back to the extrude: it still counts
	print("SMOKE rolled back to the consumer itself it stays hidden: ", b.is_hidden("sk1"))
	b.rollback_to = ""
	print("SMOKE rolling forward hides it again: ", b.is_hidden("sk1"))

	# editing a feature shows its seed
	b.edit_begun("ex1")
	print("SMOKE a feature open for editing shows its seed sketch: ", not b.is_hidden("sk1"))
	b.edit_ended()
	print("SMOKE ...and gives it back when the edit is over: ", b.is_hidden("sk1"))
	ed._clear_editing()
	print("SMOKE nothing else is saved but hidden_feature_ids: ", main.native_extras_to_add({}).keys().filter(func(k): return str(k).contains("auto") or str(k).contains("seed") or (str(k).begins_with("vr_") and str(k) != "vr_stale_mates")).is_empty())
	table.close()
	await rig.frames(2)
	quit()
