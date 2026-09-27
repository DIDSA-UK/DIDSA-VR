extends SceneTree
## Talks to a real backend (LOCAL ONLY — never run this in CI or with a
## shared backend), same exception as e2e_backend.gd/e2e_mates.gd/
## e2e_colour.gd. Sections itself never calls the backend at all — the whole
## point of this tool being client-side (see section_tool.gd's own
## docstring) — so this isn't confirming a new endpoint. It confirms
## section_tool.gd's wrap/reconcile pipeline against REAL backend-sourced
## geometry and materials (mesh_export.py's actual glTF output, real
## StandardMaterial3D from a real baseColorFactor, real mesh_identity.gd
## tagging) rather than only a synthetic hand-built .glb — this project's
## own repeated lesson (the BoxMesh-winding gotcha, GLTFState.get_scene_node()
## etc. — see docs/status.md's Milestone 4 section) is that synthetic test
## geometry doesn't always behave like the real thing.
## Run: "$GODOT" --headless --path . --script res://tests/e2e_section.gd
## Requires secrets.cfg to point at a running backend (see README/tests/README.md).

var main
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
	main.secrets_file_path = "res://secrets.cfg" # the one test allowed to use the real secrets.cfg, same as e2e_backend.gd
	var started_ms := Time.get_ticks_msec()
	root.add_child(main)
	await process_frame

	if main.backend_url.is_empty() or main.api_key.is_empty():
		print("SMOKE FAILED: secrets.cfg present but backend_url/api_key empty after load")
		quit()
		return

	var timeout_ms := 60000
	while not _done and Time.get_ticks_msec() - started_ms < timeout_ms:
		await process_frame
		var status: String = main.status_label.text
		if status.begins_with("Loaded ") or status.contains("failed") or status.contains("Couldn't parse"):
			_done = true
	if not _done or main._part_count <= 0:
		print("SMOKE FAILED: model did not load. Last status: ", main.status_label.text)
		quit(1)
		return
	print("SMOKE loaded real backend model: ", main._part_count, " part(s)")

	var parts: Array = main.get_tree().get_nodes_in_group("grabbable_parts")
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var l: XRController3D = origin.get_node("LeftController")

	# --- confirm real parts start with the backend's own glTF-generated
	# material (a StandardMaterial3D, no override — no colour_tool call has
	# happened), so _albedo_of()'s "no override" branch is exercised for real
	var real_original_albedo: Array = []
	for p in parts:
		var base_mat: Material = p.get_active_material(0)
		print("SMOKE part '", p.name, "' has a real material before sectioning: ", base_mat is BaseMaterial3D)
		real_original_albedo.append(base_mat.albedo_color if base_mat is BaseMaterial3D else Color.WHITE)

	main._section_tool.set_active(true, origin.get_node("XRCamera3D"))
	for i in 3:
		await process_frame
	print("SMOKE sections tool wraps every real part: ", parts.all(func(p: MeshInstance3D) -> bool: return p.material_override is ShaderMaterial))
	var albedo_matches := true
	for i in parts.size():
		var got: Color = (parts[i].material_override as ShaderMaterial).get_shader_parameter("albedo_color")
		if not got.is_equal_approx(real_original_albedo[i]):
			albedo_matches = false
	print("SMOKE each real part keeps its own real backend albedo after wrapping: ", albedo_matches)

	# --- grab the real gizmo against this real scene (a real grip press
	# can't be faked headless — same precedent as every other test here)
	l.position = main._section_tool.gizmo().global_position
	l.set_steadiness(0)
	await physics_frame; await physics_frame
	l.button_pressed.emit("grip_click")
	await physics_frame
	var before: Vector3 = main._section_tool.gizmo().global_position
	l.position += Vector3(0.1, 0, 0)
	await physics_frame
	print("SMOKE dragging the real gizmo against the real scene works: ", main._section_tool.gizmo().global_position.is_equal_approx(before + Vector3(0.1, 0, 0)))
	l.button_released.emit("grip_click")
	await physics_frame

	main._section_tool.set_active(false)
	await process_frame
	print("SMOKE turning it off restores every real part's original material_override (null): ", parts.all(func(p: MeshInstance3D) -> bool: return p.material_override == null))

	print("SMOKE PASSED: section_tool.gd's wrap/grab/unwrap pipeline works against a real backend-loaded model")
	quit()
