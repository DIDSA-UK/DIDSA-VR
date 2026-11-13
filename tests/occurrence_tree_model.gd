extends SceneTree
## V-7 / phase T1 (docs/feature-tree-review-2026-11-11.md), the Assembly Tree's pure model (scripts/tree/occurrence_tree_model.gd), no scene, no network:
## rows from OccurrenceResponse-shaped dicts (state flags, the path of occurrence ids), instance names "Bolt <2>" for a Part placed twice (and a plain name for one
## placed once), the state icon and hint per row, the bottom bar's actions per row kind (root, top-level, nested, missing file) with a reason when greyed, Delete's
## "edits all N placements" warning for a nested row (B3), finding a row by its path, a refresh that keeps what was expanded (B4), and the ancestors to expand for a path.
## Run: "$GODOT" --headless --path . --script res://tests/occurrence_tree_model.gd  (see tests/README.md)

const Model := preload("res://scripts/tree/occurrence_tree_model.gd")


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func ids(rows: Array) -> Array:
	return rows.map(func(r: Dictionary) -> String: return str(r["id"]))


func action(actions: Array, id: String) -> Dictionary:
	for a in actions:
		if a["id"] == id:
			return a
	return {}


func _initialize() -> void:
	var occ := [
		{"id": "a1", "resolved_part_id": "BOLT", "name_override": null, "fixed": false, "hidden": false, "suppressed": false},
		{"id": "a2", "resolved_part_id": "BOLT", "name_override": null, "fixed": true, "hidden": false, "suppressed": false},
		{"id": "a3", "resolved_part_id": "PLATE", "name_override": "Base plate", "fixed": false, "hidden": true, "suppressed": false},
		{"id": "a4", "resolved_part_id": null, "name_override": null, "fixed": false, "hidden": false, "suppressed": true},
	]
	var rows: Array = Model.rows_from_occurrences(occ, ["s1"])
	check("rows keep the order, the flags and a path under their parent's", ids(rows) == ["a1", "a2", "a3", "a4"] and rows[1]["fixed"] and rows[2]["backend_hidden"] and rows[3]["suppressed"] and rows[0]["path"] == ["s1", "a1"])
	check("a name override is the name; otherwise a placeholder until the Part's name arrives", rows[2]["name"] == "Base plate" and rows[2]["named"] and rows[0]["name"] == "Occurrence a1" and not rows[0]["named"])
	check("an occurrence with no resolved Part is a missing-file row", rows[3]["missing"] and not rows[0]["missing"])

	rows[0]["base_name"] = "Bolt"
	rows[1]["base_name"] = "Bolt"
	Model.apply_instance_names(rows)
	check("the same Part placed twice is told apart: Bolt <1>, Bolt <2>", rows[0]["name"] == "Bolt <1>" and rows[1]["name"] == "Bolt <2>")
	check("...a named or single placement keeps its plain name", rows[2]["name"] == "Base plate")
	var two_named: Array = Model.rows_from_occurrences([{"id": "n1", "resolved_part_id": "BOLT", "name_override": "Left"}, {"id": "n2", "resolved_part_id": "BOLT", "name_override": "Right"}], [])
	Model.apply_instance_names(two_named)
	check("...two placements the user named themselves keep their own names", two_named[0]["name"] == "Left" and two_named[1]["name"] == "Right")
	var single: Array = Model.rows_from_occurrences([occ[0]], [])
	single[0]["base_name"] = "Bolt"
	single[0]["name"] = "Bolt <1>" # (stale from an earlier list)
	Model.apply_instance_names(single)
	check("...a Part now placed once goes back to its plain name", single[0]["name"] == "Bolt")

	check("kinds: the root row, a top-level row, a nested row, a missing file", Model.kind_of({"id": ""}) == "root" and Model.kind_of(rows[0]) == "nested" and Model.kind_of(Model.rows_from_occurrences([occ[0]], [])[0]) == "top" and Model.kind_of(rows[3]) == "missing")

	check("the state icon: pin for fixed, the constraint status when known, a warning for a missing file, none for a free part",
		Model.state_icon(rows[1]) == "pin" and Model.state_icon(rows[0]) == "" and Model.state_icon(rows[3]) == "warning"
		and Model.state_icon({"status": "fully_constrained"}) == "lock" and Model.state_icon({"status": "under_constrained"}) == "lock_open"
		and Model.state_icon({"status": "over_constrained"}) == "warning" and Model.state_icon({"status": "fixed"}) == "pin" and Model.state_icon({"status": "", "fixed": true}) == "pin")
	# M5: rigid sets (`rigid_set` = the set's lead occurrence id)
	var set_rows := [{"id": "a", "name": "Plate", "rigid_set": "a"}, {"id": "b", "name": "Bolt", "rigid_set": "a"}, {"id": "c", "name": "Cover", "rigid_set": "a"}, {"id": "d", "name": "Loose", "rigid_set": ""}, {"id": "e", "name": "Arm", "rigid_set": "e"}, {"id": "f", "name": "Pin", "rigid_set": "e"}]
	check("the lead of a rigid set says how many parts move with it, the others name the lead, a loose part says nothing", Model.set_note(set_rows, set_rows[0]) == "moves with 2 other parts" and Model.set_note(set_rows, set_rows[1]) == "moves with Plate" and Model.set_note(set_rows, set_rows[3]) == "" and Model.set_note(set_rows, set_rows[4]) == "moves with 1 other part")
	check("one colour slot per set at a level, in id order; none outside a set", Model.set_colour_index(set_rows, "a") == 0 and Model.set_colour_index(set_rows, "e") == 1 and Model.set_colour_index(set_rows, "") == -1)
	check("the state hint names the state, with the DOF when it is under-constrained", Model.state_hint({"status": "under_constrained"}, 2) == "under-constrained (2 DOF)" and Model.state_hint(rows[3]) == "missing file" and Model.state_hint({"fixed": true}) == "fixed" and Model.state_hint({}) == "")

	var ctx := {"has_nodes": true, "hidden": false, "room_text": "Room"}
	var nested: Array = Model.actions_for(rows[0], ctx)
	check("a nested row gets Fix, Hide, Isolate, Rename, Room and Delete, in that order", nested.map(func(a): return a["id"]) == ["fix", "hide", "isolate", "rename", "room", "delete"] and action(nested, "fix")["label"] == "Fix")
	check("a fixed row's action reads Float; a hidden row's reads Show", action(Model.actions_for(rows[1], ctx), "fix")["label"] == "Float" and action(Model.actions_for(rows[0], {"has_nodes": true, "hidden": true}), "hide")["label"] == "Show")
	var root_actions: Array = Model.actions_for({"id": "", "path": []}, {"has_nodes": true})
	check("the root row can't be fixed, renamed or deleted, and says why; it can be hidden and isolated", not action(root_actions, "fix")["enabled"] and str(action(root_actions, "fix")["why"]) != "" and not action(root_actions, "rename")["enabled"] and not action(root_actions, "delete")["enabled"] and action(root_actions, "hide")["enabled"] and action(root_actions, "isolate")["enabled"] and action(root_actions, "room").is_empty())
	var missing_actions: Array = Model.actions_for(rows[3], {})
	check("a missing-file row can only be deleted; the rest is greyed with a reason", action(missing_actions, "delete")["enabled"] and not action(missing_actions, "fix")["enabled"] and str(action(missing_actions, "fix")["why"]).contains("missing") and not action(missing_actions, "hide")["enabled"] and str(action(missing_actions, "hide")["why"]) != "")

	check("Delete on a nested row warns that it edits every placement; a top-level row or a single placement does not", Model.delete_warning(rows[0], 3) == "edits all 3 placements of its assembly" and Model.delete_warning(rows[0], 1) == "" and Model.delete_warning(Model.rows_from_occurrences([occ[0]], [])[0], 3) == "")

	# find by path, and a refresh that keeps what was expanded
	var tree := Model.rows_from_occurrences([{"id": "s1", "resolved_part_id": "S"}, {"id": "s2", "resolved_part_id": "S"}], [])
	tree[0]["children"] = Model.rows_from_occurrences([{"id": "k1", "resolved_part_id": "K"}], ["s1"])
	tree[1]["children"] = Model.rows_from_occurrences([{"id": "k1", "resolved_part_id": "K"}], ["s2"])
	tree[0]["expanded"] = true
	check("two placements of one sub-assembly: the same child id has two different rows, found by their paths (B1)", Model.find_row(tree, ["s1", "k1"])["path"] == ["s1", "k1"] and Model.find_row(tree, ["s2", "k1"])["path"] == ["s2", "k1"] and Model.find_row(tree, ["s1", "k1"]) != Model.find_row(tree, ["s2", "k1"]))
	check("a path that is not fetched or does not exist is not found", Model.find_row(tree, ["s1", "zz"]).is_empty() and Model.find_row(tree, ["s3"]).is_empty())
	var fresh := Model.rows_from_occurrences([{"id": "s1", "resolved_part_id": "S"}, {"id": "s2", "resolved_part_id": "S"}, {"id": "s3", "resolved_part_id": "S"}], [])
	tree[0]["base_name"] = "Drive"
	tree[0]["named"] = true
	var merged := Model.merge_children(tree, fresh)
	check("a refreshed level keeps the expanded rows, their fetched children and their names, and adds the new row (B4)", merged[0]["expanded"] and merged[0]["children"] != null and merged[0]["name"] == "Drive" and not merged[1]["expanded"] and merged.size() == 3 and merged[2]["children"] == null)
	var swapped := Model.rows_from_occurrences([{"id": "s1", "resolved_part_id": "OTHER"}], [])
	check("...unless the occurrence now places a different Part", not Model.merge_children(tree, swapped)[0]["expanded"])

	check("ancestors to expand for a path: the root and each level above it", Model.ancestors_paths(["s1", "k1", "kb"]) == [[], ["s1"], ["s1", "k1"]] and Model.ancestors_paths([]).is_empty())
	check("a path's key", Model.path_key(["s1", "k1"]) == "s1/k1" and Model.path_key([]) == "")
	quit(0)
