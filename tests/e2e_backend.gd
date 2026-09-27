extends SceneTree
## One test that talks to a real backend: instantiates main.tscn pointed at
## the real secrets.cfg (LOCAL ONLY — never run this in CI or with a shared
## backend) and drives the full import/native -> assembly-mesh.glb -> Godot
## scene flow with the tracked assembly.didsa. Prints timings and part count;
## does not print or publish anything from the model itself.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_backend.gd
## Requires secrets.cfg to point at a running backend (see README/tests/README.md).

var main
var _done := false
var _timeout_ms: int

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
	# Deliberately using the REAL secrets.cfg here — this is the one test allowed to.
	main.secrets_file_path = "res://secrets.cfg"
	var started_ms := Time.get_ticks_msec()
	root.add_child(main)
	await process_frame

	if main.backend_url.is_empty() or main.api_key.is_empty():
		print("SMOKE FAILED: secrets.cfg present but backend_url/api_key empty after load")
		quit()
		return

	_timeout_ms = 60000
	while not _done and Time.get_ticks_msec() - started_ms < _timeout_ms:
		await process_frame
		var status: String = main.status_text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't parse") or status.contains("no document.root_part_id"):
			_done = true

	var elapsed_ms := Time.get_ticks_msec() - started_ms
	if not _done:
		print("SMOKE FAILED: timed out after %d ms waiting for load. Last status: %s" % [_timeout_ms, main.status_text])
		quit(1)
		return

	print("SMOKE final status: ", main.status_text)
	print("SMOKE part count: ", main._part_count)
	print("SMOKE total wall time (instantiate to loaded): %d ms" % elapsed_ms)
	print("SMOKE load summary: ", main._load_summary)

	if main._part_count <= 0 or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: model did not load successfully")
		quit(1)
		return

	print("SMOKE PASSED: end-to-end import/native -> assembly-mesh.glb -> scene load succeeded")
	quit()
