extends SceneTree
## REDO for features (Phase 5.6): Undo keeps how the feature was made (the create request); Redo sends it again (a new id, last-in first-out so
## nothing depends on the old one); any new action clears the redo stack; a Build-tree edit that was undone is redone with its NEW value; the
## deck has a Redo button that follows can_redo; a refused redo keeps its place; a rolled-back part refuses it. Fake backend.
## Run: "$GODOT" --headless --path . --script res://tests/design_table_redo.gd  (see tests/README.md)

const Rig := preload("res://tests/helpers/table_rig.gd")


func _initialize() -> void:
	var rig = Rig.new()
	await rig.boot(self)
	var ed = rig.ed
	var table = rig.table
	var fake = rig.fake
	ed.preview_enabled = false # the preview has its own test: here Apply creates
	print("SMOKE nothing to redo at the start, the deck's Redo is off: ", not ed.can_redo() and table.ui.redo_button().disabled)
	await rig.draw_rectangle()
	table.manager.activate("extrude")
	ed.options["depth"] = 12.0
	await ed.apply_feature()
	var first_id: String = ed.feature_stack.back()
	var made_body: Dictionary = ed.created_requests[first_id]["body"].duplicate(true)
	print("SMOKE Apply remembers how the feature was made: ", ed.created_requests.has(first_id) and ed.created_requests[first_id]["route"] == "extrude-features" and made_body["end_distance"] == 12.0)
	await ed.undo()
	print("SMOKE Undo takes it back and keeps the create request for Redo (the deck's Redo comes on): ", ed.can_redo() and ed.feature_stack.is_empty() and not table.ui.redo_button().disabled and not ed.created_requests.has(first_id))
	var posts_before: int = rig.calls_to("POST /document/parts/PART_BOX/extrude-features").size()
	await ed.redo()
	var posts: Array = rig.calls_to("POST /document/parts/PART_BOX/extrude-features")
	var second_id: String = ed.feature_stack.back() if not ed.feature_stack.is_empty() else ""
	print("SMOKE Redo sends the same create request again and gets a NEW id: ", posts.size() == posts_before + 1 and posts.back()[1] == made_body and second_id != "" and second_id != first_id)
	print("SMOKE ...it is back on Undo's stack, Redo is empty and off, and it can be made again: ", ed.feature_stack == [second_id] and not ed.can_redo() and table.ui.redo_button().disabled and ed.created_requests.has(second_id))
	await ed.undo()
	await ed.undo() # nothing left: no harm
	await ed.redo()
	await ed.undo()
	print("SMOKE undo, redo, undo again keeps working (one redo entry): ", ed.redo_stack.size() == 1 and ed.feature_stack.is_empty())
	# a new action clears redo
	await rig.draw_rectangle()
	table.manager.activate("extrude")
	ed.options["depth"] = 5.0
	await ed.apply_feature()
	print("SMOKE a new feature clears what could be redone: ", ed.redo_stack.is_empty() and table.ui.redo_button().disabled)
	var third_id: String = ed.feature_stack.back()
	# a Build-tree edit and its redo
	fake.feature_rows["PART_BOX"] = [{"id": third_id, "type": "extrude", "start_distance": 0.0, "end_distance": 5.0, "extrude_type": "boss", "name": "Extrude 1"}]
	await table.build.reload()
	await table.build.edit_typed(third_id, "9")
	var patched: Array = rig.calls_to("PATCH /document/parts/PART_BOX/extrude-features/" + third_id)
	print("SMOKE a Build-tree edit (PATCH) is on Undo's stack with its new value kept for Redo: ", patched.size() == 1 and patched[0][1]["end_distance"] == 9.0 and ed.feature_stack.back() is Dictionary and ed.feature_stack.back()["redo_payload"]["end_distance"] == 9.0)
	await ed.undo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/extrude-features/" + third_id)
	print("SMOKE Undo puts the old value back (PATCH), and the edit is redoable: ", patched.size() == 2 and patched.back()[1]["end_distance"] == 5.0 and ed.can_redo())
	await ed.redo()
	patched = rig.calls_to("PATCH /document/parts/PART_BOX/extrude-features/" + third_id)
	print("SMOKE Redo puts the NEW value back (PATCH with 9), and the edit is on Undo's stack again: ", patched.size() == 3 and patched.back()[1]["end_distance"] == 9.0 and ed.feature_stack.back() is Dictionary and not ed.can_redo())
	# a new Build edit clears redo
	await ed.undo()
	await table.build.reload()
	await table.build.edit_typed(third_id, "7")
	print("SMOKE a new edit clears the redo stack: ", ed.redo_stack.is_empty())
	# a refused redo keeps its place
	await ed.undo()
	fake.fail = "extrude-features"
	await ed.undo() # the feature itself
	fake.fail = ""
	await ed.undo()
	var before_refusal: int = ed.redo_stack.size()
	fake.fail = "extrude-features"
	await ed.redo()
	print("SMOKE a redo the backend refuses keeps its place on the stack, and says why: ", ed.redo_stack.size() == before_refusal and (table.status().contains("Couldn't") or before_refusal == 0), " ", before_refusal)
	fake.fail = ""
	# rolled back
	fake.feature_rows["PART_BOX"] = [{"id": "f1", "type": "extrude"}, {"id": "f2", "type": "extrude"}]
	await table.build.reload()
	table.build.rollback_to = "f1"
	var stack_before: int = ed.redo_stack.size()
	await ed.redo()
	print("SMOKE a rolled-back part refuses Redo (and keeps the entry): ", ed.redo_stack.size() == stack_before and table.status().contains("rolled back"))
	table.build.rollback_to = ""
	table.close()
	await rig.frames(2)
	print("SMOKE closing the table forgets the redo stack: ", ed.redo_stack.is_empty() and ed.created_requests.is_empty())
	quit()
