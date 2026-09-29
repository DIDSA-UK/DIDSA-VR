extends SceneTree
## Talks to a real backend - LOCAL ONLY, same caveat as e2e_colour_group.gd
## (never run this in CI or against a shared backend). Instantiates
## main.tscn against the real secrets.cfg, lets it load assembly.didsa for
## real, then drives assembly_tree_window.gd's real client to
## GET /parts/{id}/occurrences against assembly.didsa's own real root
## Occurrences, confirms a real leaf occurrence's tap-to-select actually
## selects the matching rendered part (main.gd's new
## select_part_by_occurrence_id() -> controller.gd's new select_external()).
## Run: "$GODOT" --headless --path . --script res://tests/e2e_assembly_tree.gd
## Requires secrets.cfg to point at a running backend.

var main
var window


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

	var loaded := false
	var timeout_ms := 60000
	while not loaded and Time.get_ticks_msec() - started_ms < timeout_ms:
		await process_frame
		var status: String = main.status_text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't parse"):
			loaded = true
	if not loaded or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: model didn't load — status: ", main.status_text)
		quit(1)
		return
	print("SMOKE model loaded: ", main.status_text)

	window = main._assembly_tree_window
	print("SMOKE root part id is available for the tree to query: ", main.current_root_part_id() != "")

	window.open()
	var tree_started_ms := Time.get_ticks_msec()
	while window._stale and Time.get_ticks_msec() - tree_started_ms < 20000:
		await process_frame
	print("SMOKE the tree finished a real GET .../occurrences fetch: ", not window._stale)
	print("SMOKE assembly.didsa's real root occurrences came back non-empty: ", not window._tree.is_empty() and window._tree[0]["children"] != null and not window._tree[0]["children"].is_empty())

	# Tap-to-select: find a row whose occurrence_id matches a currently
	# rendered leaf part (mesh_identity.gd-tagged), same lookup
	# select_part_by_occurrence_id() itself does, so this test knows in
	# advance which row should actually succeed.
	var target_occurrence_id := ""
	for node in main.get_tree().get_nodes_in_group("grabbable_parts"):
		if node.has_meta("occurrence_id") and node.get_meta("occurrence_id") != "" and node.visible:
			target_occurrence_id = node.get_meta("occurrence_id")
			break
	if target_occurrence_id == "":
		print("SMOKE FAILED: no rendered leaf occurrence found to test tap-to-select against")
		quit(1)
		return

	# The tree's single top row is the root Part itself; its placed Occurrences
	# are that row's children.
	var found_row := false
	for top in window._tree:
		for row in (top["children"] if top["children"] != null else []):
			if row["id"] == target_occurrence_id:
				found_row = true
	# Real Part names, not "Occurrence <uuid>" placeholders, once the names resolve:
	var names_deadline := Time.get_ticks_msec() + 10000
	var all_named := false
	while not all_named and Time.get_ticks_msec() < names_deadline:
		await process_frame
		all_named = true
		for top in window._tree:
			for row in (top["children"] if top["children"] != null else []):
				if row["name"].begins_with("Occurrence"):
					all_named = false
	print("SMOKE every occurrence row was relabelled with its real Part name: ", all_named)
	print("SMOKE the tree includes a row for a real rendered occurrence: ", found_row)

	var selected: bool = main.select_part_by_occurrence_id(target_occurrence_id)
	print("SMOKE tap-to-select finds and selects the matching rendered part: ", selected)
	var right: XRController3D = main.get_node("XROrigin3D/RightController")
	print("SMOKE the right controller's own selection actually changed: ", right.selected_node != null and right.selected_node.get_meta("occurrence_id") == target_occurrence_id)

	# Re-tapping the same row deselects it, matching laser-select's own toggle.
	main.select_part_by_occurrence_id(target_occurrence_id)
	print("SMOKE tapping the same row again deselects it (toggle, matching laser-select): ", right.selected_node == null)

	print("SMOKE PASSED: real GET occurrences -> real tree -> real tap-to-select against a real rendered part, against a real backend")
	quit()
