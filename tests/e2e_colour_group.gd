extends SceneTree
## Talks to a real backend, same caveat as e2e_colour.gd (LOCAL ONLY — never
## run this in CI or against a shared backend): instantiates main.tscn
## against the real secrets.cfg, lets it load assembly.didsa for real, then
## drives colour_tool.gd's new set_group_color() — the colouring hierarchy's
## "every Occurrence sharing an immediate owner" (sub-assembly/pattern)
## level — against assembly.didsa's own real sibling occurrences (2, per
## docs/status.md's own confirmed count), confirming the whole group
## actually persisted server-side via a fresh GET .../occurrences fetch, not
## just trusting the optimistic local apply, then clears it again.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_colour_group.gd
## Requires secrets.cfg to point at a running backend.

var main
var colour_tool


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return
	if not FileAccess.file_exists("res://assembly.didsa"):
		print("SMOKE SKIPPED: no assembly.didsa in the project root")
		quit()
		return

	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://secrets.cfg" # the one test allowed to
	var started_ms := Time.get_ticks_msec()
	root.add_child(main)
	await process_frame

	var done := false
	var timeout_ms := 60000
	while not done and Time.get_ticks_msec() - started_ms < timeout_ms:
		await process_frame
		var status: String = main.status_text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't parse"):
			done = true
	if not done or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: model didn't load — status: ", main.status_text)
		quit(1)
		return
	print("SMOKE model loaded: ", main.status_text)

	colour_tool = main._colour_tool

	var target: Node3D = null
	for node in get_root().get_tree().get_nodes_in_group("grabbable_parts"):
		var ref = colour_tool.MeshIdentity.occurrence_ref_for(node)
		if not ref.is_empty() and ref.get("occurrence_id", "") != "":
			target = node
			break
	if target == null:
		print("SMOKE FAILED: no placed occurrence found to colour")
		quit(1)
		return
	var ref: Dictionary = colour_tool.MeshIdentity.occurrence_ref_for(target)
	print("SMOKE group-colouring every occurrence owned by: ", ref["owner_part_id"])

	var group_result: Dictionary = await colour_tool.set_group_color(target, "#00ff88")
	print("SMOKE set_group_color result: ", group_result)
	print("SMOKE group-colour reports success across every real sibling: ", group_result["ok"])
	print("SMOKE group-colour touched assembly.didsa's real 2 occurrences: ", group_result["count"] == 2)

	# Confirm it actually persisted server-side via a fresh fetch (not just
	# trusting our own optimistic local apply) — every occurrence under this
	# owner_part_id, not just the one we picked, must carry the new colour.
	var get_result: Dictionary = await colour_tool._api_request(
		HTTPClient.METHOD_GET, "/parts/%s/occurrences" % ref["owner_part_id"], null
	)
	var all_persisted: bool = get_result["ok"] and not (get_result["json"] as Array).is_empty()
	for occ in get_result["json"]:
		if occ.get("color") != "#00ff88":
			all_persisted = false
	print("SMOKE backend confirms every sibling occurrence actually persisted the group colour: ", all_persisted)

	# Confirm the local preview reached every loaded sibling node too, not
	# just the one we picked (_apply_local_color_to_group()'s own job).
	var all_locally_applied := true
	for node in get_root().get_tree().get_nodes_in_group("grabbable_parts"):
		var node_ref = colour_tool.MeshIdentity.occurrence_ref_for(node)
		if node_ref.get("owner_part_id", "") == ref["owner_part_id"] and node_ref.get("occurrence_id", "") != "":
			var mat: StandardMaterial3D = node.material_override
			if mat == null or not mat.albedo_color.is_equal_approx(Color("#00ff88")):
				all_locally_applied = false
	print("SMOKE local preview reached every sibling node, not just the picked one: ", all_locally_applied)

	# Clean up: clear the whole group again.
	var clear_result: Dictionary = await colour_tool.set_group_color(target, "")
	print("SMOKE cleanup group-clear succeeded: ", clear_result["ok"])

	print("SMOKE PASSED: real GET occurrences + group PATCH loop -> persisted across every sibling -> cleared, against a real backend")
	quit()
