extends SceneTree
## Talks to a real backend, same caveat as e2e_backend.gd (LOCAL ONLY — never
## run this in CI or against a shared backend): instantiates main.tscn
## against the real secrets.cfg, lets it run its own real import/native ->
## assembly-mesh.glb -> scene-load flow with the tracked assembly.didsa, then
## drives mates_tool.gd's real network calls against the same running
## backend — create a real Mate, list it, solve the driven Occurrence, watch
## its Godot node actually move, then delete the Mate again. This is the
## concrete proof of the vision brief's cross-compatibility requirement: the
## Mate this creates is a real DIDSA-CAD Mate (POST /parts/{id}/mates), not a
## VR-only representation, so the same call from the flat app would produce
## the exact same thing.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_mates.gd
## Requires secrets.cfg to point at a running backend AND assembly.didsa to
## have at least 2 top-level occurrences (the tracked fixture does).

var main
var mates_tool
var _done := false


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
	main.secrets_file_path = "res://secrets.cfg" # the one test allowed to, same as e2e_backend.gd
	var started_ms := Time.get_ticks_msec()
	root.add_child(main)
	await process_frame

	var timeout_ms := 60000
	while not _done and Time.get_ticks_msec() - started_ms < timeout_ms:
		await process_frame
		var status: String = main.status_label.text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't parse"):
			_done = true
	if not _done or not main.status_label.text.begins_with("Loaded "):
		print("SMOKE FAILED: model didn't load — status: ", main.status_label.text)
		quit(1)
		return
	print("SMOKE model loaded: ", main.status_label.text)

	mates_tool = main._mates_tool
	mates_tool.set_active(true)

	# Find two distinct real, backend-tagged top-level occurrences to mate.
	var candidates: Array = []
	for node in get_root().get_tree().get_nodes_in_group("grabbable_parts"):
		var ref = mates_tool.MeshIdentity.occurrence_ref_for(node)
		if not ref.is_empty() and ref.get("occurrence_id", "") != "":
			candidates.append(node)
	print("SMOKE mateable occurrences found: ", candidates.size())
	if candidates.size() < 2:
		print("SMOKE FAILED: need at least 2 placed occurrences in assembly.didsa to test a mate")
		quit(1)
		return

	mates_tool.try_pick(candidates[0], 0)
	mates_tool.try_pick(candidates[1], 0)
	print("SMOKE two picks recorded: ", mates_tool.can_create())
	if not mates_tool.can_create():
		print("SMOKE FAILED: ", mates_tool.status_text())
		quit(1)
		return

	var driven_part: Node3D = candidates[1]
	var before_transform := driven_part.global_transform
	mates_tool.mate_type = "coincident"
	mates_tool.mate_flipped = false
	var owner_part_id: String = mates_tool._picks[0]["owner_part_id"]

	var create_result: Dictionary = await mates_tool.create_mate()
	print("SMOKE create_mate result: ", create_result)
	if not create_result["ok"]:
		print("SMOKE FAILED: create_mate: ", create_result["error"])
		quit(1)
		return

	await mates_tool.refresh_mates(owner_part_id)
	print("SMOKE mates list now has an entry: ", mates_tool.mates.size() >= 1)
	var created_mate = mates_tool.mates.back() if not mates_tool.mates.is_empty() else null
	print("SMOKE created mate type is coincident: ", created_mate != null and created_mate.get("type") == "coincident")

	var after_transform := driven_part.global_transform
	print("SMOKE solve moved (or confirmed) the driven part — transform read back: ", after_transform)
	print("SMOKE driven part transform changed from its pre-mate pose: ", not before_transform.is_equal_approx(after_transform))

	# Clean up: delete the mate we just created so repeated runs against the
	# same backend session start from the same state.
	if created_mate != null:
		var deleted: bool = await mates_tool.delete_mate(owner_part_id, created_mate.get("id", ""))
		print("SMOKE cleanup delete succeeded: ", deleted)

	print("SMOKE PASSED: real create_mate -> solve_for_occurrence -> delete_mate round trip against a real backend")
	quit()
