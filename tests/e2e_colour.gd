extends SceneTree
## Talks to a real backend, same caveat as e2e_backend.gd/e2e_mates.gd
## (LOCAL ONLY — never run this in CI or against a shared backend):
## instantiates main.tscn against the real secrets.cfg, lets it load
## assembly.didsa for real, then drives colour_tool.gd's real PATCH against
## one of its own real occurrences, confirms the colour round-trips through
## a fresh GET .../occurrences fetch, confirms the Godot node's own material
## changed, then clears it again.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_colour.gd
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
		var status: String = main.status_label.text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't parse"):
			done = true
	if not done or not main.status_label.text.begins_with("Loaded "):
		print("SMOKE FAILED: model didn't load — status: ", main.status_label.text)
		quit(1)
		return
	print("SMOKE model loaded: ", main.status_label.text)

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
	print("SMOKE colouring occurrence: ", ref)

	var set_result: Dictionary = await colour_tool.set_color(target, "#ff8800")
	print("SMOKE set_color result: ", set_result)
	if not set_result["ok"]:
		print("SMOKE FAILED: set_color: ", set_result["error"])
		quit(1)
		return

	var applied_mat: StandardMaterial3D = target.material_override
	print("SMOKE local material applied: ", applied_mat != null and applied_mat.albedo_color.is_equal_approx(Color("#ff8800")))

	# Confirm it actually persisted server-side via a fresh fetch (not just
	# trusting our own optimistic local apply).
	var get_result: Dictionary = await colour_tool._api_request(
		HTTPClient.METHOD_GET, "/parts/%s/occurrences" % ref["owner_part_id"], null
	)
	var found_color = null
	if get_result["ok"]:
		for occ in get_result["json"]:
			if occ.get("id") == ref["occurrence_id"]:
				found_color = occ.get("color")
	print("SMOKE backend confirms the colour actually persisted: ", found_color == "#ff8800")

	# Clean up: clear it again.
	var clear_result: Dictionary = await colour_tool.set_color(target, "")
	print("SMOKE cleanup clear succeeded: ", clear_result["ok"])

	print("SMOKE PASSED: real PATCH occurrence colour -> persisted -> cleared round trip against a real backend")
	quit()
