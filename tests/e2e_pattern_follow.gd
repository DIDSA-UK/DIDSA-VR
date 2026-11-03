extends SceneTree
## Real backend (LOCAL ONLY, see tests/README.md): a part mated to a PATTERN COPY follows when the copy's source moves (DIDSA-CAD
## docs/pattern-followers-and-dissolve-plan.md, F1 + V1 + V2). tests/data/pattern_follow.didsa (built by tests/data/make_pattern_follow_fixture.py): a root with two
## boxes, A ("src") and B ("mover"), a Linear pattern of A (copies 300 mm apart along x) and B's face mated to the first copy's face, stored satisfied.
## A is moved 100 mm along z (the way a grip release does: the pose is on the node) and solved. Checks against the real thing: the mate marks A as the mated part
## (V1: the copy's id is never a part of a URL), the backend moves B by the same 100 mm (F1: B follows the copy), B's node adopts it, and the copy's node - which
## has no occurrence of its own - is put at A's pose plus the pattern step by the `?geometry=false` read (V2); Enforce all then leaves everything where it is.
## Run: DIDSA_NO_LANDING=1 "$GODOT" --headless --path . --script res://tests/e2e_pattern_follow.gd  (needs secrets.cfg and a running backend from DIDSA-CAD with F1)

var main
var mt
var owner_id := ""


func wait_for(pred: Callable, frames := 1800) -> bool:
	for i in frames:
		if pred.call():
			return true
		await process_frame
	return false


func part_of(occurrence_id: String) -> Node3D:
	for n in main.get_tree().get_nodes_in_group("grabbable_parts"):
		if str(n.get_meta("occurrence_id", "")) == occurrence_id:
			return n
	return null


func copy_node() -> Node3D:
	for n in main.get_tree().get_nodes_in_group("grabbable_parts"):
		if str(n.get_meta("instance_path", "")).contains("#pattern:") and str(n.get_meta("instance_path", "")).ends_with(":1"):
			return n
	return null


func stored() -> Dictionary:
	var result: Dictionary = await mt._api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_id, null)
	var out := {}
	for o in result["json"]:
		out[str(o["id"])] = Vector3(o["transform"]["translation"][0], o["transform"]["translation"][1], o["transform"]["translation"][2])
	return out


func _initialize() -> void:
	if not FileAccess.file_exists("res://secrets.cfg"):
		print("SMOKE SKIPPED: no secrets.cfg, this test needs a running local backend, see tests/README.md")
		quit()
		return
	var secrets := ConfigFile.new()
	secrets.load("res://secrets.cfg")
	var secrets_path := "user://e2e_pattern_follow_secrets.cfg"
	secrets.save(secrets_path)
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = secrets_path
	main.native_file_path = "res://tests/data/pattern_follow.didsa"
	root.add_child(main)
	await process_frame
	var loaded: bool = await wait_for(func() -> bool: return main.status_text.begins_with("Loaded ") or main.status_text.contains("failed") or main.status_text.contains("Couldn't"), 3600)
	if not loaded or not main.status_text.begins_with("Loaded "):
		print("SMOKE FAILED: the pattern fixture did not load - status: ", main.status_text)
		quit(1)
		return
	mt = main._mates_tool
	owner_id = main.current_root_part_id()
	await mt.refresh_state(owner_id)
	var a := part_of("src")
	var b := part_of("mover")
	var copy := copy_node()
	var indexed: bool = await wait_for(func() -> bool: return copy != null and copy.has_meta("group_root"), 1800)
	print("SMOKE the file's three parts are on screen: A, B and A's first pattern copy (no occurrence id of its own): ", a != null and b != null and copy != null and str(copy.get_meta("occurrence_id", "x")) == "")
	print("SMOKE the mate on the copy marks A mated (V1), never the copy's id: ", mt._mated_ids.has("src") and mt._mated_ids.has("mover") and not mt._mated_ids.keys().any(func(k) -> bool: return str(k).contains("#")))
	if a == null or b == null or copy == null:
		quit(1)
		return
	var start_a: Vector3 = a.transform.origin
	var start_b: Vector3 = b.transform.origin
	var step: Vector3 = copy.transform.origin - start_a
	print("SMOKE the copy stands one pattern step (300 mm along x) from A, as stored: ", absf(step.x - 300.0) < 0.5 and absf(step.y) < 0.5 and absf(step.z) < 0.5, " ", step)

	# move A 100 mm along z the way a release does (the pose is on the node), then solve it
	a.transform = Transform3D(a.transform.basis, start_a + Vector3(0, 0, 100.0))
	var result: Dictionary = await mt.solve_occurrence(owner_id, "src")
	print("SMOKE solving A succeeds against the real backend: ", result["ok"], " ", result["error"])
	var now := await stored()
	var moved_b: Vector3 = now["mover"] - start_b
	print("SMOKE the backend moved B by the same 100 mm along z (F1: B follows the copy, and A stays where it was put): ", absf(moved_b.z - 100.0) < 0.2 and absf(now["src"].z - (start_a.z + 100.0)) < 0.2, " ", moved_b)
	print("SMOKE B's node adopted it: ", (b.transform.origin - (start_b + Vector3(0, 0, 100.0))).length() < 0.2, " ", b.transform.origin - start_b)
	var copy_now: Vector3 = copy.transform.origin
	print("SMOKE the copy's node follows A in the same step (V2): it stands at A's pose plus the pattern step (", copy_now - a.transform.origin, "): ", (copy_now - (a.transform.origin + step)).length() < 0.2)
	var outcome: Dictionary = await mt.enforce_all(owner_id)
	print("SMOKE Enforce all is happy, and nothing moves again: ", outcome["ok"] and (copy.transform.origin - (a.transform.origin + step)).length() < 0.2 and (b.transform.origin - (start_b + Vector3(0, 0, 100.0))).length() < 0.2)
	await process_frame
	quit()
