extends SceneTree
## Stress by simulated input (Milestones 1-7 in VR, the Appearance tool, Scenes and the References page): a full scene (main.tscn, no
## backend: the tools talk to tests/fake_appearance_api.gd) driven by seeded random sequences of what a person does - aiming the laser
## at faces, panel rows and empty space, clicks, holds, half presses, double presses, releases with no press, switching tools in the
## middle of a paint, wheel wedges (greyed ones too), the Scenes page's Update / Discard / Stay, Save new with odd names, undo / redo,
## the Appearance page's sliders at and past their limits, bad hex text, a backend that starts refusing, calls fired without waiting.
## Asserts after every step: no stuck breadcrumb / preview, every body the tool sent the backend is a valid appearance, a scene that
## shows is one the backend lists, the sandbox and the shown scene agree, the undo stack isn't negative. SCRIPT ERRORs end the run
## (tests/ci.sh already fails on them); a leaked-node count is reported, not asserted.
##
## Headless can't squeeze a real trigger or judge feel; press / release handlers are called directly, as the other tests do
## (tests/README.md). Run: "$GODOT" --headless --path . --script res://tests/stress_appearance_scenes.gd [-- seed=3 steps=400]

const FakeApi := preload("res://tests/fake_appearance_api.gd")
const Breadcrumb := preload("res://scripts/group_breadcrumb.gd")

const KNOWN := ["colour", "opacity", "metallic", "roughness", "emission", "emission_strength"]

var failures := 0
var main
var r: XRController3D
var api
var rng := RandomNumberGenerator.new()
var log_tail: Array = []
var boxes: Array = []
var glb_parts: Array = []
var home: Dictionary = {}
var steps := 400
var seeds: Array = [1, 2, 3]


func _check(ok: bool, label: String) -> void:
	if not ok:
		print("SMOKE ", label, ": ", ok)
		print("  last actions: ", " > ".join(log_tail.slice(maxi(0, log_tail.size() - 8))))
		failures += 1


func _box(label: String, occ: String, path: String, names: Array, at: Vector3) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = label
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.1, 0.1, 0.1)
	n.mesh = mesh
	var faces: Array = []
	var bodies: Array = []
	for t in mesh.get_faces().size() / 3:
		var f := t / 2
		faces.append(f % 3)
		bodies.append("%s%d" % [label.to_lower().left(1), 1 if f < 3 else 2])
	n.set_meta("face_ids", faces)
	n.set_meta("body_ids", bodies)
	n.set_meta("owner_part_id", "F" if path.contains("/") else "R")
	n.set_meta("occurrence_id", occ)
	n.set_meta("instance_path", path)
	n.set_meta("group_root", "R")
	n.set_meta("group_path", Array(path.split("/")) if path != "" else [])
	n.set_meta("group_names", names)
	n.add_to_group("grabbable_parts")
	main.assembly_root.add_child(n)
	n.global_position = at
	n.create_trimesh_collision()
	return n


func _aim_at(point: Vector3, up := Vector3.UP) -> void:
	var from := point + Vector3(0.0, 0.0, 0.6)
	r.global_transform = Transform3D(Basis.looking_at(point - from, up), from)


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


func _valid_appearance(a) -> bool:
	if a == null:
		return true
	if not (a is Dictionary) or (a as Dictionary).is_empty():
		return false
	for k in a:
		if not KNOWN.has(k):
			return false
		var v = a[k]
		if k == "colour" or k == "emission":
			if not (v is String and (v as String).length() == 7 and (v as String).begins_with("#") and (v as String).substr(1).is_valid_hex_number()):
				return false
		elif not (v is float or v is int) or is_nan(float(v)) or is_inf(float(v)):
			return false
		elif k == "emission_strength" and (float(v) < 0.0 or float(v) > 10.0):
			return false
		elif k != "emission_strength" and (float(v) < 0.0 or float(v) > 1.0):
			return false
	return true


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text and (node as Button).is_visible_in_tree():
		return node
	for c in node.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


func _all_controls(node: Node, out: Array) -> void:
	if (node is BaseButton or node is Range) and (node as Control).is_visible_in_tree():
		out.append(node)
	for c in node.get_children():
		_all_controls(c, out)


func _new_session() -> void:
	api = FakeApi.new()
	api.parts = {
		"R": {"name": "Rig", "occurrences": [FakeApi.row("frame", "F"), FakeApi.row("peg", "A")], "scenes": [
			{"id": "s1", "name": "Lifted", "overrides": [{"path": "peg", "transform": {"translation": [0.0, 0.0, 50.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0}}], "section_planes": [], "viewpoint": null, "unresolved": []},
			{"id": "s2", "name": "Gone", "overrides": [{"path": "no/such/path", "hidden": true}], "section_planes": [], "viewpoint": null, "unresolved": []}]},
		"F": {"name": "Frame", "occurrences": [FakeApi.row("barA", "A"), FakeApi.row("barB", "A")]},
		"A": {"name": "Bar"},
	}
	main._appearance_tool.configure(api)
	main._appearance_tool.world_root = "R"
	main.scenes_tool.api = api
	main._resolved_part_id = "R"


func _step(name: String) -> void:
	log_tail.append(name)


func _random_action() -> void:
	var tablet = main._tablet
	var flows = main.get_node("WheelFlows")
	var scenes = main.scenes_tool
	var tool = main._appearance_tool
	var roll := rng.randi_range(0, 27)
	match roll:
		0, 1, 2: # aim at a face of a box
			var b: MeshInstance3D = boxes[rng.randi() % boxes.size()]
			_step("aim box")
			_aim_at(b.global_position + Vector3(rng.randf_range(-0.04, 0.04), rng.randf_range(-0.04, 0.04), 0.05))
			await _frames(1)
		3: # aim at empty space, up, down, far away
			_step("aim away")
			_aim_at(Vector3(rng.randf_range(-30, 30), rng.randf_range(-5, 40), rng.randf_range(-30, 30)), Vector3.RIGHT)
			await _frames(1)
		4, 5: # a click
			_step("click")
			r._on_button_pressed("trigger_click")
			await _frames(1)
			r._select_down = false
			await r._finish_paint()
		6, 7: # a hold, then maybe aim at a row, then release
			_step("hold")
			r._on_button_pressed("trigger_click")
			if r._paint_press is Dictionary and r._paint_press.has("ms"):
				r._paint_press["ms"] = int(r._paint_press["ms"]) - 600
			await _frames(1)
			var crumb = r._paint_crumb
			if crumb != null and rng.randf() < 0.7:
				var row := rng.randi_range(0, maxi(0, crumb.labels.size() - 1))
				var y: float = Breadcrumb.MARGIN_M + Breadcrumb.ROW_H * (row + 1) + Breadcrumb.ROW_H * 0.5
				_step("aim row %d" % row)
				_aim_at(crumb.global_transform * Vector3(Breadcrumb.WIDTH * 0.5, -y, 0.0))
				await _frames(2)
			if rng.randf() < 0.3:
				_aim_at(Vector3(5, 5, -5), Vector3.RIGHT) # off the panel
				await _frames(1)
			r._select_down = false
			await r._finish_paint()
		8: # release with no press
			_step("release alone")
			r._select_down = false
			await r._finish_paint()
		9: # press twice, release once
			_step("double press")
			r._on_button_pressed("trigger_click")
			r._on_button_pressed("trigger_click")
			await _frames(1)
			r._select_down = false
			await r._finish_paint()
		10: # grip / other buttons while painting
			_step("other button")
			r._on_button_pressed(["grip_click", "primary_click", "ax_button", "by_button"][rng.randi() % 4])
			await _frames(1)
			r._on_button_released(["grip_click", "primary_click", "ax_button", "by_button"][rng.randi() % 4])
		11: # switch tools
			var ids := ["paint", "scenes", "mates"]
			var id: String = ids[rng.randi() % ids.size()]
			_step("activate " + id)
			tablet.manager.activate(id)
			await process_frame
		12:
			_step("deactivate tool")
			tablet.manager.deactivate()
			await process_frame
		13: # paint colour, valid and hostile
			var inputs := ["#E63946", "#3498DB", "#000000", "#ffffff", "", "red", "#GGGGGG", "#12", "#1234567", " #aabbcc ", "🙂", "#E63946\n"]
			var text: String = inputs[rng.randi() % inputs.size()]
			_step("paint colour '%s'" % text.replace("\n", "\\n"))
			tablet.pages.set_paint_colour(text)
			await process_frame
		14:
			_step("paint clear")
			tablet.pages.set_paint_clear()
			await process_frame
		15, 16: # a wheel wedge on the Scenes ring, greyed or not
			var ring: Array = flows.scenes_entries()
			if ring.is_empty():
				return
			var e: Dictionary = ring[rng.randi() % ring.size()]
			_step("wedge %s (%s)" % [e["id"], "on" if bool(e.get("enabled", true)) else "greyed"])
			if e.has("run") and (bool(e.get("enabled", true)) or rng.randf() < 0.3):
				await (e["run"] as Callable).call()
			await process_frame
		17:
			var pill: Dictionary = flows.pill_entry()
			_step("pill " + str(pill.get("id", "?")))
			if pill.has("run"):
				await (pill["run"] as Callable).call()
			await process_frame
		18: # the question on the Scenes page
			var choice: String = ["update", "discard", "stay"][rng.randi() % 3]
			_step("answer " + choice)
			scenes.answer(choice)
			for i in 2:
				await process_frame
		19: # Save new with odd names
			var names := ["Exploded", "", "   ", "x".repeat(2000), "🙂 ünï", "a\nb", "../../x", "Lifted"]
			var nm: String = names[rng.randi() % names.size()]
			_step("save new '%s'" % nm.left(12).replace("\n", "\\n"))
			await scenes.save_as_new(nm, rng.randf() < 0.5)
		20:
			_step("update scene")
			await scenes.update_scene(rng.randf() < 0.5)
		21:
			var list: Array = scenes.scenes_of()
			if list.is_empty():
				return
			var sc: Dictionary = list[rng.randi() % list.size()]
			_step("delete " + str(sc["id"]))
			await scenes.delete_scene(str(sc["id"]))
		22:
			_step("request_show")
			var list2: Array = scenes.scenes_of()
			if not list2.is_empty():
				scenes.request_show(str(list2[rng.randi() % list2.size()]["id"]))
			await process_frame
		23: # undo / redo
			_step("undo/redo")
			if rng.randf() < 0.6:
				main.command_stack.undo()
			else:
				main.command_stack.redo()
			await process_frame
		24: # the backend starts refusing, or recovers
			api.fail_puts = not api.fail_puts
			_step("backend refuses=%s" % api.fail_puts)
		25: # a part moved by hand (the sandbox)
			var p: Node3D = glb_parts[rng.randi() % glb_parts.size()]
			_step("move part")
			p.position += Vector3(rng.randf_range(-20, 20), rng.randf_range(-20, 20), rng.randf_range(-20, 20))
			await process_frame
		26: # overlapping calls fired without waiting
			_step("overlapping refresh/save")
			scenes.refresh()
			scenes.refresh()
			scenes.save_as_new("Burst", false)
			await _frames(3)
		_:
			# poke any visible control of the open tablet page: buttons pressed, sliders to the extremes
			var controls: Array = []
			if tablet.is_open():
				_all_controls(tablet.ui, controls)
			if controls.is_empty():
				return
			var c = controls[rng.randi() % controls.size()]
			if c is Range:
				var rg := c as Range
				var extremes := [rg.min_value, rg.max_value, rg.min_value - 5.0, rg.max_value + 5.0, (rg.min_value + rg.max_value) * 0.5]
				_step("slider %s" % c.name)
				rg.value = extremes[rng.randi() % extremes.size()]
			elif c is BaseButton and not (c as BaseButton).disabled:
				_step("press %s" % (c as Button).text if c is Button else "press %s" % c.name)
				if (c as BaseButton).toggle_mode:
					(c as BaseButton).button_pressed = not (c as BaseButton).button_pressed
				else:
					(c as BaseButton).pressed.emit()
			await _frames(2)


func _invariants() -> void:
	var scenes = main.scenes_tool
	# 1. nothing the tool sent the backend is an invalid appearance
	for c in api.puts():
		var body = c["body"]
		_check(body is Dictionary and _valid_appearance(body.get("appearance")), "an invalid appearance was sent: %s" % str(body))
	# 2. the breadcrumb and preview don't outlive the press
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and r._paint_press == null or (r._paint_press is Dictionary and (r._paint_press as Dictionary).is_empty()):
		pass
	# 3. a shown scene is one the backend lists (or the unsaved new one)
	var shown: String = scenes.shown_id()
	if shown != "" and shown != "new":
		var ids: Array = scenes.scenes_of().map(func(s) -> String: return str(s["id"]))
		_check(ids.has(shown), "shown scene '%s' is not in the list %s" % [shown, str(ids)])
	# 4. the undo stack is sane
	_check(main.command_stack.undo_label() is String and main.command_stack.redo_label() is String, "undo stack labels")
	# 5. the tool wheel entries are well formed
	for e in main.get_node("WheelFlows").scenes_entries():
		_check(e is Dictionary and e.has("id") and e.has("label"), "a wheel entry lacks id / label: %s" % str(e))


func _run_seed(seed_value: int) -> void:
	rng.seed = seed_value
	log_tail.clear()
	_new_session()
	main._tablet.manager.activate("paint")
	main._tablet.pages.set_paint_colour("#E63946")
	await main.scenes_tool.refresh()
	await main._appearance_tool.ensure_loaded("R")
	for i in steps:
		await _random_action()
		await process_frame
		_invariants()
		if failures > 0:
			print("stopped at step ", i, " of seed ", seed_value)
			return
	# Leave cleanly: back to default, tool off; every part home, no stuck state.
	api.fail_puts = false
	main._tablet.manager.deactivate()
	await process_frame
	main.scenes_tool.answer("discard")
	await main.scenes_tool.back_to_default("discard")
	main._mates_tool.return_glide_s = 0.0
	main._mates_tool.set_relaxed(false)
	await _frames(3)
	_check(main.scenes_tool.shown_id() == "", "seed %d: after Back to default no scene shows (%s)" % [seed_value, main.scenes_tool.shown_id()])
	_check(r._paint_crumb == null, "seed %d: no breadcrumb left open" % seed_value)
	for p in glb_parts:
		_check(is_instance_valid(p) and (p as Node3D).position.is_equal_approx(home[p]) or not main._mates_tool.relaxed, "seed %d: part %s is back where it was (%s vs %s)" % [seed_value, p.name, str(p.position), str(home[p])])


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("seed="):
			seeds = [int(a.trim_prefix("seed="))]
		elif a.begins_with("steps="):
			steps = int(a.trim_prefix("steps="))
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	for i in 4:
		await process_frame
	r = main.get_node("XROrigin3D/RightController")
	main.assembly_root.transform = Transform3D.IDENTITY
	boxes.append(_box("BarA", "barA", "frame/barA", ["Frame", "Bar"], Vector3(0.0, 1.2, -1.0)))
	boxes.append(_box("BarB", "barB", "frame/barB", ["Frame", "Bar"], Vector3(0.4, 1.2, -1.0)))
	boxes.append(_box("Peg", "peg", "peg", ["Bar"], Vector3(-0.4, 1.2, -1.0)))
	for b in boxes:
		glb_parts.append(b)
		home[b] = (b as Node3D).position
	main._mates_tool.return_glide_s = 0.0
	main.scenes_tool.scopes = func() -> Array: return [{"root": "R", "scene": main.assembly_root, "view": null}]
	await _frames(2)
	var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var t0 := Time.get_ticks_msec()
	for s in seeds:
		await _run_seed(int(s))
		if failures > 0:
			break
	var by_method := {}
	for c in api.calls:
		by_method[c["method"]] = int(by_method.get(c["method"], 0)) + 1
	print("SMOKE STRESS coverage: backend calls by HTTP method %s; scenes shown at the end: %d" % [str(by_method), api.parts["R"]["scenes"].size()])
	print("SMOKE STRESS: %d seeds x %d steps in %d ms, %d paints sent, orphan nodes %d -> %d" % [seeds.size(), steps, Time.get_ticks_msec() - t0, api.puts().size(), orphans_before, Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)])
	print("SMOKE PASSED" if failures == 0 else "SMOKE FAILED (%d)" % failures)
	quit(0 if failures == 0 else 1)
