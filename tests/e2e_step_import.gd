extends SceneTree
## STEP/OBJ/STL import through a running backend — milestone 1's last "done
## when" item (a bare .glb already loads with no backend at all; see
## load_glb_file()). Needs a real backend (the same one tests/e2e_backend.gd
## needs), since Godot itself can't decode these formats — that's exactly
## why main.gd's _import_external_file() round-trips through the backend's
## POST /parts -> POST /parts/{id}/import-features -> GET .../assembly-mesh.glb.
## Writes a tiny generated .obj cube (no proprietary geometry) to
## user://models, then drives that real flow through main.gd's
## load_model_file() dispatcher.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_step_import.gd  (see tests/README.md)

var main

func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg — this test needs a running local backend, see tests/README.md")
		quit()
		return

	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	# Deliberately using the REAL secrets.cfg — same exception e2e_backend.gd gets.
	main.secrets_file_path = "res://secrets.cfg"
	main.native_file_path = "res://__nonexistent__.didsa" # skip the startup native-import flow; this test drives the OBJ path itself
	root.add_child(main)
	await process_frame

	if main.backend_url.is_empty() or main.api_key.is_empty():
		print("SMOKE FAILED: secrets.cfg present but backend_url/api_key empty after load")
		quit()
		return

	DirAccess.make_dir_recursive_absolute("user://models")
	var obj_text := "\n".join([
		"v 0 0 0", "v 1 0 0", "v 1 1 0", "v 0 1 0",
		"v 0 0 1", "v 1 0 1", "v 1 1 1", "v 0 1 1",
		"f 1 2 3", "f 1 3 4", "f 5 7 6", "f 5 8 7",
		"f 1 6 2", "f 1 5 6", "f 2 7 3", "f 2 6 7",
		"f 3 8 4", "f 3 7 8", "f 4 5 1", "f 4 8 5",
	])
	var f := FileAccess.open("user://models/e2e_test_cube.obj", FileAccess.WRITE)
	f.store_string(obj_text)
	f.close()

	print("SMOKE model files include the generated .obj: ", "user://models/e2e_test_cube.obj" in main.list_model_files())

	var started_ms := Time.get_ticks_msec()
	main.load_model_file("user://models/e2e_test_cube.obj")

	var timeout_ms := 60000
	while Time.get_ticks_msec() - started_ms < timeout_ms:
		await process_frame
		var status: String = main.status_label.text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't") or status.contains("needs a backend"):
			break

	var elapsed_ms := Time.get_ticks_msec() - started_ms
	print("SMOKE final status: ", main.status_label.text)
	print("SMOKE part count: ", main._part_count)
	print("SMOKE total wall time: %d ms" % elapsed_ms)
	print("SMOKE load summary: ", main._load_summary)

	if main._part_count > 0 and main.status_label.text.begins_with("Loaded "):
		print("SMOKE PASSED: .obj -> create part -> import-features -> assembly-mesh.glb -> scene load succeeded")
	else:
		print("SMOKE FAILED: .obj import did not load successfully")

	# STL shares OBJ's downstream mesh-import code but is a genuinely
	# different text format to parse, so worth checking separately —
	# a single triangle is enough to prove the format-specific parsing works.
	var stl_text := "\n".join([
		"solid test", "facet normal 0 0 1", "outer loop",
		"vertex 0 0 0", "vertex 1 0 0", "vertex 0 1 0",
		"endloop", "endfacet", "endsolid test",
	])
	var stl_f := FileAccess.open("user://models/e2e_test_tri.stl", FileAccess.WRITE)
	stl_f.store_string(stl_text)
	stl_f.close()

	var stl_started_ms := Time.get_ticks_msec()
	main.load_model_file("user://models/e2e_test_tri.stl")
	while Time.get_ticks_msec() - stl_started_ms < timeout_ms:
		await process_frame
		var status: String = main.status_label.text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't") or status.contains("needs a backend"):
			break
	print("SMOKE .stl final status: ", main.status_label.text)
	if main._part_count > 0 and main.status_label.text.begins_with("Loaded "):
		print("SMOKE PASSED: .stl -> create part -> import-features -> assembly-mesh.glb -> scene load succeeded")
	else:
		print("SMOKE FAILED: .stl import did not load successfully")
	quit()
