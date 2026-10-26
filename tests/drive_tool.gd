extends SceneTree
## The Drive tool (gears-and-motion plan M7), headless with a stand-in mates tool (tests/helpers/fake_drive_mates.gd): the axis of a picked round face / circular
## edge / straight edge, the pick rules, the stick-to-speed mapping and cap, the wish made every frame (turned about the axis through its centre, or slid along
## it), one end_drag per run, keep-running (A) and stop (B), and the readout (the driven part and every other turning member, signed against the drive axis).
## Run: "$GODOT" --headless --path . --script res://tests/drive_tool.gd  (see tests/README.md)

const Drive := preload("res://scripts/drive_tool.gd")
const Fake := preload("res://tests/helpers/fake_drive_mates.gd")

const CENTRE := Vector3(0.003, 0.002, 0.0)


func _circle(centre: Vector3, radius: float, normal_z := true) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var n := 24
	for i in n:
		var a := TAU * i / n
		var b := TAU * (i + 1) / n
		pts.append(centre + Vector3(cos(a), sin(a), 0.0) * radius)
		pts.append(centre + Vector3(cos(b), sin(b), 0.0) * radius)
	return pts


func _part(name: String) -> Node3D:
	var part := Node3D.new()
	part.name = name
	root.add_child(part)
	part.set_meta("face_ids", [0, 1])
	part.set_meta("body_ids", ["B", "B"])
	part.set_meta("topology", {"B": {
		"edges": {0: _circle(CENTRE, 0.01), 1: PackedVector3Array([Vector3(0, 0, 0), Vector3(0.05, 0, 0)]), 2: PackedVector3Array([Vector3.ZERO, Vector3(0, 0.01, 0.0)]), 3: PackedVector3Array([Vector3(0.013, 0.002, 0.0), Vector3(0.013, 0.002, 0.01)])},
		"edge_kinds": {0: "circle", 1: "line", 2: "spline", 3: "line"},
		"face_kinds": ["cylinder", "plane"],
		"face_edges": [PackedInt32Array([2, 0, 3]), PackedInt32Array([1])],
		"vertices": {}, "vertex_at": {},
	}})
	return part


func _edge(i: int) -> Dictionary:
	return {"kind": "edge", "body_id": "B", "index": i}


func _face(i: int) -> Dictionary:
	return {"kind": "face", "body_id": "B", "index": i}


func _initialize() -> void:
	await process_frame
	var part := _part("Gear A")
	var circle := Drive.axis_of(part, _edge(0))
	print("SMOKE a circular edge gives the axis through its centre, normal to it (spin): ", not circle.is_empty() and circle["kind"] == "spin" and absf((circle["dir"] as Vector3).dot(Vector3.BACK)) > 0.9999 and (circle["origin"] as Vector3).distance_to(CENTRE) < 0.0001)
	var cylinder := Drive.axis_of(part, _face(0))
	print("SMOKE a round face gives the axis of its circular boundary edge: ", not cylinder.is_empty() and cylinder["kind"] == "spin" and (cylinder["origin"] as Vector3).distance_to(CENTRE) < 0.0001)
	var line := Drive.axis_of(part, _edge(1))
	print("SMOKE a straight edge gives a slide along it: ", not line.is_empty() and line["kind"] == "slide" and (line["dir"] as Vector3).distance_to(Vector3.RIGHT) < 0.0001)
	print("SMOKE a flat face, a curved edge and a vertex give no axis: ", Drive.axis_of(part, _face(1)).is_empty() and Drive.axis_of(part, _edge(2)).is_empty() and Drive.axis_of(part, {"kind": "vertex", "body_id": "B", "index": 0}).is_empty())

	var fake: Node = Fake.new()
	root.add_child(fake)
	var tool: Node = Drive.new()
	tool.mates_tool = fake
	root.add_child(tool)
	tool.set_active(true)
	print("SMOKE the prompt before a pick asks for a round face or a straight edge: ", tool.status_text().begins_with("Pick a round face"))
	tool.try_pick(part, 0, _face(1))
	print("SMOKE a flat face is refused with the reason and nothing is picked: ", tool.part == null and tool.status_text().begins_with("Pick a round face to turn it"))
	fake.managed = false
	tool.try_pick(part, 0, _face(0))
	print("SMOKE a part the mates tool does not manage is refused: ", tool.part == null)
	fake.managed = true
	fake.locked = true
	tool.try_pick(part, 0, _face(0))
	print("SMOKE a grounded part is refused with the locked message: ", tool.part == null and fake.calls.has("locked") and tool.status_text().contains("grounded"))
	fake.locked = false
	fake.constrained = false
	tool.try_pick(part, 0, _face(0))
	print("SMOKE a part with no mates is refused (nothing couples to it): ", tool.part == null and tool.status_text().contains("no mates"))
	fake.constrained = true
	fake.relaxed = true
	tool.try_pick(part, 0, _face(0))
	print("SMOKE with the mates relaxed Drive says so (not 'no mates'): ", tool.part == null and tool.status_text().contains("relaxed"), " ", tool.status_text())
	fake.relaxed = false
	tool.try_pick(part, 0, _edge(3)) # triangle 0 is on the round face: the laser snapped to its seam line (4 mm off the axis)
	print("SMOKE the laser on a round face that snaps to its seam line or a corner still takes the round face, to spin about its axis: ", tool.part == part and tool.kind == "spin")
	tool.try_pick(part, 0, {"kind": "vertex", "body_id": "B", "index": 5})
	print("SMOKE ...and so does a corner of it: ", tool.part == part and tool.kind == "spin")
	tool.try_pick(part, 1, _edge(1)) # a straight edge of the flat face (triangle 1): a slide
	print("SMOKE a straight edge of a flat face is still a slide: ", tool.part == part and tool.kind == "slide")
	tool.try_pick(part, 0, _face(0))
	print("SMOKE a round face of a mated part is picked to spin: ", tool.part == part and tool.kind == "spin")

	print("SMOKE the stick maps to speed: dead zone 0, full 30 rpm either way, linear between: ", tool.speed_for(0.1) == 0.0 and absf(tool.speed_for(1.0) - 30.0) < 0.0001 and absf(tool.speed_for(-1.0) + 30.0) < 0.0001 and absf(tool.speed_for(0.575) - 15.0) < 0.0001)
	print("SMOKE ...and never above the 60 rpm cap: ", absf(tool.speed_for(5.0)) <= Drive.RPM_MAX)

	# a 1:2 pair, A driven at full stick for 60 frames at 90 Hz = 120 degrees
	var follower := _part("Gear B")
	await process_frame
	fake.followers = {"b": follower}
	var start := part.global_transform
	for i in 60:
		tool.feed(Vector2(1.0, 0.0), false, false)
		tool.tick(1.0 / 90.0)
	var turned := rad_to_deg(atan2(part.global_transform.basis.x.y, part.global_transform.basis.x.x))
	var follower_turned := rad_to_deg(atan2(follower.global_transform.basis.x.y, follower.global_transform.basis.x.x))
	print("SMOKE 60 frames at 30 rpm and 90 Hz turn the part 120 degrees: ", absf(turned - 120.0) < 0.01, " ", turned)
	print("SMOKE ...and the part's axis stays put (the pivot is the axis, not the part's origin): ", (part.global_transform * Vector3.ZERO).distance_to(start * Vector3.ZERO) > 0.001 and ((part.global_transform * CENTRE) - CENTRE).length() < 0.00001)
	print("SMOKE ...one constrain_drag per frame, no end_drag yet: ", fake.calls.count("constrain") == 60 and not fake.calls.has("end"))
	print("SMOKE the follower turned 60 degrees the other way: ", absf(follower_turned + 60.0) < 0.01, " ", follower_turned)
	var text: String = tool.readout_text()
	print("SMOKE the readout names the driven part and the follower with signed rpm: ", text.begins_with("Gear A 30 rpm") and text.contains("Gear B -1"), " ", text)
	print("SMOKE ...and the status line carries it: ", tool.status_text().begins_with("Gear A 30 rpm") or tool.status_text() == text)

	tool.on_grip()
	print("SMOKE a hand taking a part stops the run with ONE end_drag (the hand and the stick never both steer): ", not tool.running and fake.calls.count("end") == 1)
	tool.feed(Vector2(1.0, 0.0), false, false)
	tool.tick(1.0 / 90.0)
	print("SMOKE ...the stick, still pushed, does not take the part back from the hand: ", not tool.running and fake.calls.count("end") == 1)
	tool.feed(Vector2.ZERO, false, false)
	tool.tick(1.0 / 90.0)
	tool.feed(Vector2(1.0, 0.0), false, false)
	tool.tick(1.0 / 90.0)
	print("SMOKE ...but once it has been at rest it drives again: ", tool.running)
	tool.feed(Vector2.ZERO, false, false)
	tool.tick(1.0 / 90.0)
	print("SMOKE letting the stick go stops the run with another end_drag: ", not tool.running and fake.calls.count("end") == 2)
	tool.on_grip()
	print("SMOKE ...and a grip with nothing running does nothing: ", fake.calls.count("end") == 2)

	# keep running: A at 0.5 stick, then the stick at rest; B stops
	tool.feed(Vector2(0.575, 0.0), false, false)
	tool.tick(1.0 / 90.0)
	tool.feed(Vector2.ZERO, true, false)
	tool.tick(1.0 / 90.0)
	tool.feed(Vector2.ZERO, true, false)
	tool.tick(1.0 / 90.0)
	print("SMOKE A keeps it running at 15 rpm with the stick at rest: ", tool.running and tool.keep and absf(tool.speed - 15.0) < 0.0001)
	tool.feed(Vector2(-1.0, 0.0), false, false)
	tool.tick(1.0 / 90.0)
	print("SMOKE ...and a stick push takes the speed back (-30 rpm): ", absf(tool.speed + 30.0) < 0.0001)
	tool.feed(Vector2.ZERO, false, true)
	tool.tick(1.0 / 90.0)
	print("SMOKE B stops it: one more end_drag, speed 0, keep off: ", not tool.running and tool.speed == 0.0 and not tool.keep and fake.calls.count("end") == 3)

	# nothing can turn
	fake.stuck_once = true
	tool.feed(Vector2(1.0, 0.0), false, false)
	tool.tick(1.0 / 90.0)
	print("SMOKE a drive the mates hold fixed says so: ", tool.status_text() == "Held: nothing can turn.")
	tool.stop()

	# a rack that slides alongside the gears is read out in mm/s (a part scale of 0.001: 1 unit = 1 mm)
	var rack_node := _part("Rack")
	rack_node.scale = Vector3.ONE * 0.001
	await process_frame
	fake.followers["r"] = rack_node
	fake.sliders = [rack_node]
	fake.slide_step = 0.00001
	for i in 30:
		tool.feed(Vector2(1.0, 0.0), false, false)
		tool.tick(1.0 / 90.0)
	var with_rack: String = tool.readout_text()
	print("SMOKE a follower that slides (a rack) is read out in mm/s next to the turning gears: ", with_rack.contains("Rack 1 mm/s") and with_rack.contains("Gear B"), " ", with_rack)
	fake.sliders = []
	fake.followers.erase("r")
	rack_node.free()
	tool.stop()

	# a part with no readable name shows its numbers alone, never a node name
	fake.labels = false
	tool.feed(Vector2(1.0, 0.0), false, false)
	tool.tick(1.0 / 90.0)
	var unnamed: String = tool.readout_text()
	print("SMOKE with no readable names the readout is just the numbers: ", unnamed.begins_with("30 rpm") and not unnamed.contains("Gear") and not unnamed.contains("Mesh"), " ", unnamed)
	tool.stop()
	fake.labels = true

	# slide along a straight edge, in the part's scaled frame (1 unit of the backend = 0.001 world)
	var slider := _part("Rack")
	slider.scale = Vector3.ONE * 0.001
	await process_frame
	tool.try_pick(slider, 1, _edge(1))
	var x0 := slider.global_transform.origin.x
	for i in 90:
		tool.feed(Vector2(1.0, 0.0), false, false)
		tool.tick(1.0 / 90.0)
	var moved := slider.global_transform.origin.x - x0
	print("SMOKE a straight edge slides at 50 mm/s of the part's own units (50 x 0.001 per second): ", absf(moved - 0.05) < 0.0005, " ", moved)
	print("SMOKE ...and its readout is in mm/s: ", tool.readout_text() == "Rack 50 mm/s")
	tool.stop()
	var ends: int = fake.calls.count("end")
	tool.set_active(false)
	print("SMOKE switching the tool off stops, clears the pick and leaves no run: ", not tool.running and tool.part == null and not tool.owns_stick() and fake.calls.count("end") == ends)
	for n in [tool, fake, part, follower, slider]:
		n.free()
	quit()
