extends SceneTree
## Talks to a real backend, same caveat as e2e_mates.gd/e2e_colour.gd
## (LOCAL ONLY — never run this in CI or against a shared backend):
## instantiates main.tscn against the real secrets.cfg, lets it load
## assembly.didsa for real, then drives measure_tool.gd's real
## POST /parts/{id}/measure against its own real occurrences - first a
## single-entity measurement (one real face), then a two-entity one (a
## real distance between two placed occurrences) - confirming actual
## geometry numbers come back, not just that the request didn't error.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_measure.gd
## Requires secrets.cfg to point at a running backend AND assembly.didsa to
## have at least 2 top-level occurrences (the tracked fixture does).

var main
var measure_tool


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
	main.secrets_file_path = "res://secrets.cfg" # the one test allowed to, same as e2e_mates.gd/e2e_colour.gd
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

	measure_tool = main._measure_tool
	measure_tool.set_active(true)

	var candidates: Array = []
	for node in get_root().get_tree().get_nodes_in_group("grabbable_parts"):
		var ref = measure_tool.MeshIdentity.occurrence_ref_for(node)
		if not ref.is_empty() and ref.get("occurrence_id", "") != "":
			candidates.append(node)
	print("SMOKE measurable occurrences found: ", candidates.size())
	if candidates.size() < 2:
		print("SMOKE FAILED: need at least 2 placed occurrences in assembly.didsa to test a two-entity measurement")
		quit(1)
		return

	# --- single-entity measurement: one real face on one real occurrence.
	measure_tool.try_pick(candidates[0], 0)
	var deadline := Time.get_ticks_msec() + 30000
	while measure_tool.is_busy() and Time.get_ticks_msec() < deadline:
		await process_frame
	print("SMOKE single-entity result: ", measure_tool.result)
	var single_populated: bool = (
		measure_tool.result.get("area") != null or measure_tool.result.get("length") != null
		or measure_tool.result.get("radius") != null or measure_tool.result.get("point") != null
	)
	print("SMOKE single-entity measurement returned a real geometry field: ", single_populated)
	if not single_populated:
		print("SMOKE FAILED: ", measure_tool.status_text())
		quit(1)
		return

	# --- two-entity measurement: a real distance between the two placed occurrences.
	measure_tool.clear_picks()
	measure_tool.try_pick(candidates[0], 0)
	measure_tool.try_pick(candidates[1], 0)
	deadline = Time.get_ticks_msec() + 30000
	while measure_tool.is_busy() and Time.get_ticks_msec() < deadline:
		await process_frame
	print("SMOKE two-entity result: ", measure_tool.result)
	var pair_populated: bool = (
		measure_tool.result.get("distance") != null and measure_tool.result.get("delta") != null
	)
	print("SMOKE two-entity measurement returned a real distance/delta: ", pair_populated)
	if not pair_populated:
		print("SMOKE FAILED: ", measure_tool.status_text())
		quit(1)
		return

	print("SMOKE PASSED: real single- and two-entity POST /measure round trips against a real backend")
	quit()
