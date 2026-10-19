extends SceneTree
## Scenes in VR (scripts/scenes_tool.gd), headless, against in-memory backends (tests/fake_appearance_api.gd for the scenes and the
## model, tests/fake_mates_tool.gd for the sandbox). The assembly is the one DIDSA-CAD's scene vectors use
## (tests/fixtures/scene_vectors.json): a flat glb-like scene, one node per placed instance at its pose in the root's frame, the
## frame a sub-assembly with no geometry of its own (a plain Node3D), the leg hidden in the model and not loaded.
## Checked: Show poses every node as the vectors say (exploded), relaxed; what shows captures back to the same scene (nothing
## unsaved); a move is unsaved and Back to default asks (Stay keeps it, Update PATCHes it, then it returns); hidden follows the
## nearest scene `hidden` (and the hidden part can't be lasered); a scene's looks are the top layer; Save as new POSTs a moved pattern
## copy by its path, a group move as one override on the sub-assembly, leaves the root's own moves out, and leaves out a paint on
## every placement; the viewpoint turns and places the model at the scale it has; Return parts from elsewhere ends the scene.
## Run: "$GODOT" --headless --path . --script res://tests/scenes_tool.gd

const FakeApi := preload("res://tests/fake_appearance_api.gd")
const FakeMates := preload("res://tests/fake_mates_tool.gd")
const CommandStack := preload("res://scripts/command_stack.gd")
const ScenesTool := preload("res://scripts/scenes_tool.gd")
const Compose := preload("res://scripts/appearance/scene_compose.gd")

var failures := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)
	if not ok:
		failures += 1


func _close(a: Transform3D, b: Transform3D, eps: float = 0.001) -> bool:
	if a.origin.distance_to(b.origin) > eps:
		return false
	for i in 3:
		if (a.basis[i] - b.basis[i]).length() > eps:
			return false
	return true


func _vectors() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/scene_vectors.json"))


func _case(doc: Dictionary, name: String) -> Dictionary:
	for c in doc["cases"]:
		if c["name"] == name:
			return c
	return {}


func _initialize() -> void:
	await process_frame
	var doc := _vectors()
	var defaults: Dictionary = _case(doc, "default")["expected"]

	# --- the assembly: flat, one node per placed instance (the leg is hidden in the model and not loaded)
	var holder := Node3D.new()
	holder.name = "AssemblyRoot"
	root.add_child(holder)
	var glb := Node3D.new()
	glb.name = "Glb"
	holder.add_child(glb)
	var nodes := {}
	for n in doc["nodes"]:
		var path := str(n["path"])
		if path == "leg":
			continue
		var node: Node3D
		if path == "frame":
			node = Node3D.new()
		else:
			var mesh := MeshInstance3D.new()
			mesh.mesh = BoxMesh.new()
			mesh.add_to_group("grabbable_parts")
			node = mesh
		node.name = path.replace("/", "_").replace("#", "_").replace(":", "_") if path != "" else "RootContent"
		node.set_meta("instance_path", path)
		glb.add_child(node)
		node.transform = Compose.to_transform(defaults[path]["world"])
		if node is MeshInstance3D:
			(node as MeshInstance3D).create_trimesh_collision()
		nodes[path] = node
	var real := {}
	for p in nodes:
		real[p] = (nodes[p] as Node3D).transform

	var api := FakeApi.new()
	api.parts = {
		"R": {"name": "Rig", "occurrences": [FakeApi.row("frame", "F"), FakeApi.row("bolt", "B"), FakeApi.row("leg", "L")],
			"overrides": [{"path": "frame", "appearance": {"colour": "#2F6FD6"}}]},
		"F": {"name": "Frame", "occurrences": [FakeApi.row("barA", "A"), FakeApi.row("barB", "A")]},
		"A": {"name": "Bar", "appearance": {"roughness": 0.6}, "body_appearances": {"a2": {"colour": "#8B5A2B"}}},
		"B": {"name": "Bolt"}, "L": {"name": "Leg"},
	}
	api.parts["R"]["occurrences"][2]["hidden"] = true
	var listed: Array = []
	for name in ["exploded", "hidden", "looks"]:
		var scene: Dictionary = (_case(doc, name)["scene"] as Dictionary).duplicate(true)
		scene["id"] = "s-" + name
		scene["name"] = name.capitalize()
		scene["unresolved"] = []
		listed.append(scene)
	api.parts["R"]["scenes"] = listed

	var stack := CommandStack.new()
	var mates = FakeMates.new()
	holder.add_child(mates)
	mates.setup(stack)
	mates.return_glide_s = 0.0
	var appearance = preload("res://scripts/appearance_tool.gd").new()
	appearance.mates_tool = mates
	appearance.world_root = "R"
	root.add_child(appearance)
	appearance.configure(api)
	var tool = ScenesTool.new()
	tool.api = api
	tool.mates_tool = mates
	tool.appearance_tool = appearance
	tool.scopes = func() -> Array: return [{"root": "R", "scene": glb, "view": holder}]
	root.add_child(tool)
	var messages: Array = []
	tool.message.connect(func(t: String) -> void: messages.append(t))
	await process_frame

	var got: Array = await tool.refresh()
	_check(got.size() == 3 and tool.current_root() == "R", "the scope's scenes are listed (3)")
	_check(tool.nodes_of("R").size() == 7, "every placed instance is a node of the scope, the frame without geometry too (7)")

	# --- Show: the vectors' poses, relaxed
	var shown: String = await tool.show_scene("s-exploded")
	var expected: Dictionary = _case(doc, "exploded")["expected"]
	var all_posed := true
	for p in nodes:
		if not _close((nodes[p] as Node3D).transform, Compose.to_transform(expected[p]["world"])):
			all_posed = false
			print("  ", p, " at ", (nodes[p] as Node3D).transform, " want ", Compose.to_transform(expected[p]["world"]))
	_check(shown == "shown" and mates.relaxed and tool.shown_id() == "s-exploded", "Show relaxes the mates and shows the scene")
	_check(all_posed, "every node is where the vectors put it (the frame carries both bars, barA's own move in the frame's frame, one copy alone)")
	_check(not tool.has_unsaved(), "what shows captures back to the same scene: nothing unsaved")

	# --- a move is unsaved; Back to default asks
	var bar_b: Node3D = nodes["frame/barB"]
	bar_b.position += Vector3(0, 0, 25)
	_check(tool.has_unsaved(), "moving a bar makes the scene unsaved")
	_check(await tool.back_to_default() == "ask", "Back to default asks first")
	_check(await tool.back_to_default("stay") == "stay" and mates.relaxed and tool.shown_id() == "s-exploded", "Stay keeps the scene on screen")
	var patches_before: int = api.calls.filter(func(c) -> bool: return c["method"] == HTTPClient.METHOD_PATCH).size()
	var back: String = await tool.back_to_default("update")
	var patches: Array = api.calls.filter(func(c) -> bool: return c["method"] == HTTPClient.METHOD_PATCH)
	var patched: Array = (patches[patches.size() - 1]["body"] as Dictionary).get("overrides", []) if patches.size() > patches_before else []
	var bar_b_override := patched.filter(func(o) -> bool: return o["path"] == "frame/barB")
	var bar_b_ok: bool = bar_b_override.size() == 1 and absf(float(bar_b_override[0]["transform"]["translation"][2]) - 25.0) < 0.01 \
		and absf(float(bar_b_override[0]["transform"]["translation"][1]) - 800.0) < 0.01
	_check(back == "returned" and patches.size() == patches_before + 1 and patched.size() == 4 and bar_b_ok,
		"Update PATCHes the scene (4 overrides, barB 25 mm up in the frame's frame), then the parts return")
	var all_home := true
	for p in nodes:
		if not _close((nodes[p] as Node3D).transform, real[p]):
			all_home = false
	_check(all_home and not mates.relaxed and tool.shown_id() == "", "after Back to default every node is home and no scene shows")

	# --- hidden: the nearest scene `hidden` wins; the model-hidden leg isn't loaded and says so
	messages.clear()
	await tool.show_scene("s-hidden")
	_check(not (nodes["frame/barA"] as Node3D).visible and (nodes["frame/barB"] as Node3D).visible, "hiding the frame hides barA; barB is shown again (nearest wins)")
	_check(not (nodes["bolt#pattern:p1:1"] as Node3D).visible and (nodes["bolt#pattern:p1:2"] as Node3D).visible, "one pattern copy hides alone")
	var body_a: CollisionObject3D = (nodes["frame/barA"] as Node).get_child(0) as CollisionObject3D
	_check(body_a != null and body_a.collision_layer == 0, "a hidden part can't be lasered (its collider is off)")
	_check(messages.size() > 0 and str(messages[messages.size() - 1]).contains("1 part(s) it shows are hidden in the model"), "showing a part the model hides (not loaded) says so")
	_check(not tool.has_unsaved(), "the hidden scene captures back to itself")
	await tool.back_to_default()
	_check((nodes["frame/barA"] as Node3D).visible and body_a.collision_layer != 0, "Back to default shows it again, collider back")

	# --- looks: the scene's appearance is the top layer
	await tool.show_scene("s-looks")
	var a_whole: Dictionary = appearance.resolved_at(nodes["frame/barA"], "R")
	var b_a2: Dictionary = appearance.resolved_at(nodes["frame/barB"], "R", "a2")
	var copy2: Dictionary = appearance.resolved_at(nodes["bolt#pattern:p1:2"], "R")
	_check(a_whole.get("colour") == "#D63A2F" and is_equal_approx(float(a_whole.get("opacity", 0)), 0.3), "the scene's frame colour beats the model's (red, 0.3)")
	_check(is_equal_approx(float(b_a2.get("metallic", 0)), 1.0) and b_a2.get("colour") == "#D63A2F", "one body field by field: metallic on barB's a2, the colour from above")
	_check(is_equal_approx(float(copy2.get("emission_strength", 0)), 2.0), "a pattern copy glows on its own")
	_check(not tool.has_unsaved(), "the looks scene captures back to itself")
	await tool.back_to_default()
	_check(appearance.resolved_at(nodes["frame/barA"], "R").get("colour") == "#2F6FD6", "Back to default: the model's own looks again")

	# --- Save as new from the default: a moved pattern copy, a group move, the root's own content, a paint on every placement
	mates.set_relaxed(true)
	(nodes["bolt#pattern:p1:2"] as Node3D).position += Vector3(0, 30, 0)
	(nodes["frame/barA"] as Node3D).position += Vector3(0, 0, 40)
	(nodes["frame/barB"] as Node3D).position += Vector3(0, 0, 40)
	(nodes[""] as Node3D).position += Vector3(5, 0, 0)
	appearance._temporary["R"] = [{"path": "bolt", "scope": "same_part", "part_id": "B", "appearance": {"colour": "#00FF00"}},
		{"path": "bolt", "appearance": {"colour": "#0000FF"}}]
	var saved: Dictionary = await tool.save_as_new("Moved", false)
	var posts: Array = api.calls.filter(func(c) -> bool: return c["method"] == HTTPClient.METHOD_POST)
	var posted: Array = posts[posts.size() - 1]["body"]["overrides"] if not posts.is_empty() else []
	var by_path := {}
	for o in posted:
		by_path[str(o["path"])] = o
	print("  posted: ", posted)
	_check(saved["ok"] and tool.shown_id() == str(saved["scene"]["id"]) and tool.scenes_of().size() == 4, "Save as new POSTs the scene; it shows and is listed")
	_check(by_path.has("bolt#pattern:p1:2") and absf(float(by_path["bolt#pattern:p1:2"]["transform"]["translation"][1]) - 30.0) < 0.01, "a moved pattern copy is saved by its path")
	_check(by_path.has("frame") and absf(float(by_path["frame"]["transform"]["translation"][2]) - 40.0) < 0.01 and not by_path.has("frame/barA") and not by_path.has("frame/barB"),
		"both bars moved alike: one override on the frame (no geometry of its own), none on the bars")
	_check(not by_path.has("") and tool.last_capture["root_moves"] == 1, "the root's own content moved: left out and counted")
	_check(tool.last_capture["skipped_paint"] == 1 and by_path.has("bolt") and by_path["bolt"]["appearance"]["colour"] == "#0000FF", "a paint on every placement is left out; one on the bolt is saved")
	_check(posted.size() == 3, "three overrides in all (copy, frame, bolt paint)")

	# --- Return parts from elsewhere ends the scene
	await mates.return_parts()
	_check(tool.shown_id() == "" and not mates.relaxed, "Return parts (the wheel's pill) ends the scene too")

	# --- the viewpoint: turned and placed, the scale kept
	var vp := {"eye": [0, 0, 1000], "target": [0, 0, 0], "up": [0, 1, 0]}
	var head := Transform3D(Basis.IDENTITY, Vector3(0, 1.6, 0))
	var pose: Transform3D = ScenesTool.viewpoint_pose(vp, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.001), Vector3(3, 0, 3)), head)
	_check(is_equal_approx(pose.basis.get_scale().x, 0.001), "the viewpoint keeps the scale (0.001)")
	_check((pose * Vector3(0, 0, 1000)).distance_to(head.origin) < 1e-4 and (pose * Vector3.ZERO).distance_to(Vector3(0, 1.6, -1)) < 1e-4, "the eye lands at the head, the target 1 m ahead")
	var turned := Transform3D(Basis(Vector3.UP, deg_to_rad(90)), Vector3(0, 1.6, 0))
	var vp2 := {"eye": [1000, 500, 0], "target": [0, 500, 0], "up": [0, 0, 1]}
	var pose2: Transform3D = ScenesTool.viewpoint_pose(vp2, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.002), Vector3.ZERO), turned)
	var ahead := -turned.basis.z
	var tgt := pose2 * Vector3(0, 500, 0)
	_check((pose2.basis * Vector3(0, 0, 1)).normalized().distance_to(Vector3.UP) < 1e-4, "the model's up turns to the world's up (z-up model)")
	_check((tgt - turned.origin).normalized().distance_to(ahead) < 1e-4 and is_equal_approx((tgt - turned.origin).length(), 2.0), "the target is where the head faces, 1000 mm at 0.002 = 2 m")

	_check(failures == 0, "no failures")
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(1 if failures > 0 else 0)
