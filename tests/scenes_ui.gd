extends SceneTree
## Scenes in the real scene (main.tscn, no backend: the Scenes tool and the Appearance tool talk to tests/fake_appearance_api.gd,
## and a little flat assembly stands in for a loaded glb): the wheel's Scenes sub-wheel (Default, Update, Save new, a wedge per
## scene), showing a scene from it, the Return pill asking on the tablet's Scenes page when the scene has unsaved changes
## (Update / Discard / Stay there), the Mates page's Return parts asking the same way, and the plain sandbox returning without asking.
## Headless can't press a real grip, so wheel entries are run directly (tests/README.md).
## Run: "$GODOT" --headless --path . --script res://tests/scenes_ui.gd

const FakeApi := preload("res://tests/fake_appearance_api.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _ids(entries: Array) -> Array:
	return entries.map(func(e: Dictionary) -> String: return str(e["id"]))


func _entry(entries: Array, id: String) -> Dictionary:
	for e in entries:
		if e["id"] == id:
			return e
	return {}


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text and (node as Button).is_visible_in_tree():
		return node
	for c in node.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _initialize() -> void:
	var main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	for i in 4:
		await process_frame

	# A loaded assembly, as the glb makes it: flat, one node per placed instance.
	var glb := Node3D.new()
	glb.name = "Glb"
	main.assembly_root.add_child(glb)
	var a := MeshInstance3D.new()
	a.mesh = BoxMesh.new()
	a.set_meta("instance_path", "a")
	a.add_to_group("grabbable_parts")
	glb.add_child(a)
	var b := MeshInstance3D.new()
	b.mesh = BoxMesh.new()
	b.set_meta("instance_path", "b")
	b.add_to_group("grabbable_parts")
	glb.add_child(b)
	b.position = Vector3(100, 0, 0)
	main._resolved_part_id = "R"
	var api := FakeApi.new()
	api.parts = {"R": {"name": "Rig", "occurrences": [FakeApi.row("a", "P"), FakeApi.row("b", "P")],
		"scenes": [{"id": "s1", "name": "Lifted", "overrides": [{"path": "a", "transform": {"translation": [0.0, 0.0, 50.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}}], "section_planes": [], "viewpoint": null, "unresolved": []}]},
		"P": {"name": "Plate"}}
	var scenes = main.scenes_tool
	scenes.api = api
	main._appearance_tool.api = api
	main._appearance_tool.world_root = "R"
	main._mates_tool.return_glide_s = 0.0
	await scenes.refresh()
	var flows = main.get_node("WheelFlows")
	var tablet = main._tablet

	_check(_ids(flows.root_entries()).has("scenes") and flows.root_entries()[_ids(flows.root_entries()).find("scenes")].has("children"), "the root ring has a Scenes sub-wheel")
	var ring: Array = flows.scenes_entries()
	_check(_ids(ring) == ["scene_start", "scene_s1", "scene_abandon", "scene_update", "scene_new"], "the Scenes sub-wheel: Start scene, the scene, Abandon, Update, Save new")
	_check(bool(_entry(ring, "scene_start")["enabled"]) and not bool(_entry(ring, "scene_abandon")["enabled"]) and not bool(_entry(ring, "scene_update")["enabled"]), "outside a scene Start is on, Abandon and Update are greyed")
	_check(_entry(ring, "scene_start")["tint"] != _entry(ring, "scene_abandon")["tint"] and _entry(ring, "scene_start")["tint"].g > _entry(ring, "scene_start")["tint"].r and _entry(ring, "scene_abandon")["tint"].r > _entry(ring, "scene_abandon")["tint"].g, "Start is filled green and Abandon red")

	await (_entry(ring, "scene_s1")["run"] as Callable).call()
	_check(main._mates_tool.relaxed and scenes.shown_id() == "s1" and a.position.is_equal_approx(Vector3(0, 0, 50)), "a scene's wedge shows it (relaxed, part a lifted 50 mm)")
	ring = flows.scenes_entries()
	_check(bool(_entry(ring, "scene_update")["enabled"]) and bool(_entry(ring, "scene_s1")["active"]), "then Update is offered and the scene's wedge is lit")
	_check(not bool(_entry(ring, "scene_start")["enabled"]) and bool(_entry(ring, "scene_abandon")["enabled"]), "inside a scene Start is greyed and Abandon is on")
	_check(flows.pill_entry()["id"] == "return_parts", "the pill under the ring is Return parts")

	# --- unsaved: the Return pill asks on the tablet instead of losing it
	b.position += Vector3(0, 30, 0)
	await (flows.pill_entry()["run"] as Callable).call()
	await process_frame
	_check(main._mates_tool.relaxed and scenes.shown_id() == "s1" and b.position.is_equal_approx(Vector3(100, 30, 0)), "with unsaved changes the Return pill doesn't return")
	_check(tablet.is_open() and tablet.ui.selected_tool_id == "scenes" and not scenes.pending_ask.is_empty(), "...it opens the tablet's Scenes page with the question")
	for i in 2:
		await process_frame
	var page_root: Node = tablet.ui
	_check(_find_button(page_root, "Update") != null and _find_button(page_root, "Discard") != null and _find_button(page_root, "Stay") != null, "the page asks: Update / Discard / Stay")
	_find_button(page_root, "Stay").pressed.emit()
	for i in 4:
		await process_frame
	_check(main._mates_tool.relaxed and scenes.pending_ask.is_empty(), "Stay keeps the scene on screen")

	# --- the Mates page's Return parts asks too; Discard returns without saving
	tablet.ui.select_tool("mates")
	for i in 2:
		await process_frame
	var relax: Button = tablet.pages._mates_relax_button
	relax.toggled.emit(false) # (Return parts on the Mates page)
	for i in 4:
		await process_frame
	_check(relax.button_pressed and main._mates_tool.relaxed and not scenes.pending_ask.is_empty() and tablet.ui.selected_tool_id == "scenes",
		"the Mates page's Return parts asks on the Scenes page too (the button stays on)")
	_find_button(page_root, "Discard").pressed.emit()
	for i in 6:
		await process_frame
	var patched := api.calls.filter(func(c) -> bool: return c["method"] == HTTPClient.METHOD_PATCH).size()
	_check(not main._mates_tool.relaxed and scenes.shown_id() == "" and a.position.is_equal_approx(Vector3.ZERO) and b.position.is_equal_approx(Vector3(100, 0, 0)) and patched == 0,
		"Discard: every part back, no scene, nothing sent")

	# --- the plain sandbox (no scene shown) returns without asking, as before
	main._mates_tool.set_relaxed(true)
	a.position += Vector3(10, 0, 0)
	await (flows.pill_entry()["run"] as Callable).call()
	_check(not main._mates_tool.relaxed and a.position.is_equal_approx(Vector3.ZERO) and scenes.pending_ask.is_empty(), "with no scene shown, Return parts returns without asking")

	# --- the Scenes ring's own entry and exit: Start scene relaxes the mates, Abandon puts everything back
	ring = flows.scenes_entries()
	await (_entry(ring, "scene_start")["run"] as Callable).call()
	_check(main._mates_tool.relaxed and not bool(_entry(flows.scenes_entries(), "scene_start")["enabled"]) and bool(_entry(flows.scenes_entries(), "scene_abandon")["enabled"]), "Start scene relaxes the mates; then Start is greyed and Abandon is on")
	a.position += Vector3(10, 0, 0)
	await (_entry(flows.scenes_entries(), "scene_abandon")["run"] as Callable).call()
	await process_frame
	_check(not main._mates_tool.relaxed and a.position.is_equal_approx(Vector3.ZERO) and bool(_entry(flows.scenes_entries(), "scene_start")["enabled"]), "Abandon puts every part back and the ring is back to Start")

	_check(failures == 0, "no failures")
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
