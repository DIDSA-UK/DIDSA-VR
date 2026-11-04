extends SceneTree
## Talks to a real backend, LOCAL ONLY (same caveat as e2e_mates.gd): T3's mate highlight on real geometry. assembly.didsa loads through the real import, a real
## coincident mate is made between the first faces of two placed parts, listed, and selected as the wrist tablet's list row does it (mates_tool.highlight_mate):
## two pick nodes light up, one on each part, and their keys are the faces the mate really references. A second mate row is selected, then none; the mate is deleted
## and the highlight goes with it.
## Run: DIDSA_NO_LANDING=1 DIDSA_SETTINGS_PATH=user://settings_test.cfg "$GODOT" --headless --path . --script res://tests/e2e_mate_highlight.gd
## Needs secrets.cfg to point at a running backend and assembly.didsa in the project root.

var main


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg") or not FileAccess.file_exists("res://assembly.didsa"):
		print("SMOKE SKIPPED: needs secrets.cfg (a running backend) and assembly.didsa in the project root")
		quit()
		return
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://secrets.cfg"
	root.add_child(main)
	await process_frame
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 60000 and not (main.status_text.begins_with("Loaded ") or main.status_text.contains("failed")):
		await process_frame
	if not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: the model did not load: ", main.status_text)
		quit(1)
		return
	var tool = main._mates_tool
	var fh = main.face_highlight
	tool.set_active(true)
	var candidates: Array = []
	for node in get_nodes_in_group("grabbable_parts"):
		if not tool.MeshIdentity.occurrence_ref_for(node).is_empty() and str(tool.MeshIdentity.occurrence_ref_for(node).get("occurrence_id", "")) != "":
			candidates.append(node)
	check("two placed parts to mate", candidates.size() >= 2)
	tool.try_pick(candidates[0], 0)
	tool.try_pick(candidates[1], 0)
	var owner_id: String = tool._picks[0]["owner_part_id"]
	tool.mate_type = "coincident"
	var made: Dictionary = await tool.create_mate()
	check("a real coincident mate is created", made["ok"])
	tool.set_active(false)
	await tool.refresh_mates(owner_id)
	var mate: Dictionary = tool.mates.back()
	check("it is in the list, with two subshape references", tool.mates.size() >= 1 and (mate["references"] as Array).size() == 2 and mate["references"][0].get("subshape_ref") != null)
	var lit: bool = tool.highlight_mate(str(mate["id"]))
	await frames(3)
	check("selecting it lights two entities, one on each part", lit and fh.pick_nodes().size() == 2 and (fh.pick_nodes()[0] as Node).get_parent() != (fh.pick_nodes()[1] as Node).get_parent())
	var keys: Array = []
	for e in tool.mate_highlight_entries():
		keys.append(e["key"])
	var want: Array = []
	for ref in mate["references"]:
		want.append("%s:%d" % [ref["subshape_ref"]["body_id"], int(ref["subshape_ref"]["index"])])
	check("...whose keys are the faces the backend says the mate references", keys == want)
	tool.highlight_mate("")
	await frames(1)
	check("selecting nothing puts them out", fh.pick_nodes().size() == 0)
	tool.highlight_mate(str(mate["id"]))
	var deleted: bool = await tool.delete_mate(owner_id, str(mate["id"]))
	await frames(2)
	check("deleting the selected mate clears the highlight", deleted and tool.highlight_id == "" and fh.pick_nodes().size() == 0)
	quit()
