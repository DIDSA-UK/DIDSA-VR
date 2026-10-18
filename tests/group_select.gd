extends SceneTree
## Sub-assembly selection: which sub-assembly a part sits in (scripts/group_index.gd: replaying the occurrence tree over the flat glb order, so two instances of the
## same sub-assembly are told apart), the levels a grip can take, a group moved as one (scripts/group_set.gd), the dead zone and trigger cycling on a real
## controller (scripts/controller.gd), the laser's breadcrumb (scripts/group_breadcrumb.gd), and what is saved: a top-level sub-assembly's occurrence, undoably.
## Headless; the backend is the fake document, the mates tool a recording stand-in.
## Run: "$GODOT" --headless --path . --script res://tests/group_select.gd  (see tests/README.md)

const GroupIndex := preload("res://scripts/group_index.gd")
const GroupSet := preload("res://scripts/group_set.gd")
const GroupBreadcrumb := preload("res://scripts/group_breadcrumb.gd")
const RoomEdit := preload("res://scripts/room/room_edit.gd")
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const FakeApi := preload("res://tests/fake_room_api.gd")
const CommandStack := preload("res://scripts/command_stack.gd")

const STUB := "extends Node
var relaxed := false
var states := {}
var poses := {}
var saved := []
func group_state(owner, occ):
	return states.get(owner + '|' + occ, 'ok')
func group_pose(owner, occ):
	return poses.get(owner + '|' + occ, Transform3D.IDENTITY)
func persist_group_pose(owner, occ, pose):
	saved.append([owner, occ, pose])
func is_locked(_p):
	return false
func is_constrained(_p):
	return false
func is_nested_locked(_p):
	return false
func nested_occurrence_locked(_o, _c):
	return false
func is_sandboxed(_p):
	return false
func notify_nested_locked(_p):
	pass
func end_drag(_p):
	return false
func persist_pose(_p):
	pass
func notify_locked(_p):
	pass
"


func leaf(parent: Node, owner: String, occ: String, at: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = Vector3(0.1, 0.1, 0.1)
	m.mesh = b
	m.set_meta("owner_part_id", owner)
	m.set_meta("occurrence_id", occ)
	m.add_to_group("grabbable_parts")
	parent.add_child(m)
	m.position = at
	return m


func tick() -> void:
	## (physics_frame fires before the nodes' own physics step in that tick, so wait out two)
	await physics_frame
	await physics_frame


func _initialize() -> void:
	RoomRegistry.clear()
	RoomRegistry.set_max_rooms(4)

	# --- the tree: R holds sub-assembly S twice (s1, s2) and a bolt B (b0); S holds bracket K twice; K holds a bolt B
	var fake := FakeApi.new()
	fake.occurrences = {
		"R": [fake.row("s1", "S"), fake.row("s2", "S"), fake.row("b0", "B")],
		"S": [fake.row("k1", "K"), fake.row("k2", "K")],
		"K": [fake.row("kb", "B")],
		"B": [],
	}
	fake.names = {"R": "Root", "S": "Drive", "K": "Bracket", "B": "Bolt"}

	var main := Node3D.new()
	root.add_child(main)
	var world := Node3D.new()
	main.add_child(world)
	# the glb lists the four bolts inside the brackets, in walk order, then the top-level bolt; S and K have no geometry of their own
	var kb := [
		leaf(world, "K", "kb", Vector3(0, 1, -1)), leaf(world, "K", "kb", Vector3(0.3, 1, -1)),
		leaf(world, "K", "kb", Vector3(1, 1, -1)), leaf(world, "K", "kb", Vector3(1.3, 1, -1)),
	]
	var b0 := leaf(world, "R", "b0", Vector3(3, 1, -1))
	var nodes: Array = kb + [b0]
	await process_frame
	var tagged: int = await GroupIndex.index(RoomEdit.new(fake), "R", nodes)
	print("SMOKE the walk is replayed over the flat node list: every node found its place: ", tagged == 5)
	print("SMOKE ...two instances of the same sub-assembly are told apart by their order: the paths are s1/k1, s1/k2, s2/k1, s2/k2: ", GroupIndex.path_of(kb[0]) == ["s1", "k1", "kb"] and GroupIndex.path_of(kb[1]) == ["s1", "k2", "kb"] and GroupIndex.path_of(kb[2]) == ["s2", "k1", "kb"] and GroupIndex.path_of(kb[3]) == ["s2", "k2", "kb"])
	print("SMOKE ...a top-level part's path is just itself, and it is not inside any sub-assembly: ", GroupIndex.path_of(b0) == ["b0"] and not GroupIndex.has_groups(b0) and GroupIndex.has_groups(kb[0]))
	print("SMOKE ...the Parts each step resolves to, and their names, are carried: ", kb[0].get_meta("group_parts") == ["S", "K", "B"] and kb[0].get_meta("group_names") == ["Drive", "Bracket", "Bolt"] and kb[0].get_meta("group_root") == "R")

	# --- levels
	var levels := GroupIndex.levels(kb[0], nodes)
	print("SMOKE a bolt in a bracket in a drive offers the bolt, then the drive (a bracket holding only that bolt is the same thing, so it is not a separate step): ", levels.size() == 2 and levels[0]["depth"] == 0 and levels[1]["depth"] == 1 and (levels[1]["members"] as Array).size() == 2)
	print("SMOKE ...the drive takes this instance's two bolts, not the other drive's: ", (levels[1]["members"] as Array).has(kb[0]) and (levels[1]["members"] as Array).has(kb[1]) and not (levels[1]["members"] as Array).has(kb[2]))
	print("SMOKE ...labelled by name: ", levels[0]["label"] == "Bolt" and levels[1]["label"] == "Drive" and GroupIndex.breadcrumb(levels, 1) == "Bolt < [Drive]")
	print("SMOKE a part with no sub-assembly has a single level: ", GroupIndex.levels(b0, nodes).size() == 1)
	var box := GroupIndex.union_aabb(levels[1]["members"])
	print("SMOKE the group's bounds wrap its members (0.4 m across for two 0.1 m cubes 0.3 apart): ", absf(box.size.x - 0.4) < 0.001 and absf(box.size.y - 0.1) < 0.001)

	# --- a hidden occurrence the mesh left out: the rest still lines up
	fake.occurrences["R"][2]["hidden"] = true # b0 is hidden: the mesh has no node for it
	var shown: Array = kb
	for n in nodes:
		n.remove_meta("group_path")
	var edit := RoomEdit.new(fake)
	var t2: int = await GroupIndex.index(edit, "R", shown)
	print("SMOKE a hidden occurrence's own node is not in the mesh, so it is skipped in the walk and the rest still lines up: ", t2 == 4 and GroupIndex.path_of(kb[3]) == ["s2", "k2", "kb"] and GroupIndex.path_of(kb[0]) == ["s1", "k1", "kb"])
	edit.mesh_include_hidden = true
	for n in nodes:
		n.remove_meta("group_path")
	var t2b: int = await GroupIndex.index(edit, "R", nodes)
	print("SMOKE ...and with hidden parts included in the mesh it is placed too: ", t2b == 5 and GroupIndex.path_of(b0) == ["b0"])
	fake.occurrences["R"][2]["hidden"] = false
	var stray_node := leaf(world, "K", "nope", Vector3.ZERO)
	var t3: int = await GroupIndex.index(RoomEdit.new(fake), "R", nodes + [stray_node])
	print("SMOKE a node that matches nothing in the tree has no group (it behaves as a plain part): ", t3 == 5 and not stray_node.has_meta("group_path"))
	stray_node.free()
	kb[0].set_meta("room_id", 7)
	print("SMOKE rooms do not mix: another scope's parts are not members: ", GroupIndex.members_of(nodes, "R", ["s1"], 0).size() == 1 and GroupIndex.members_of(nodes, "R", ["s1"], 7).size() == 1)
	kb[0].remove_meta("room_id")

	# --- a group moves as one
	var gs := GroupSet.new(kb[0], levels[1])
	print("SMOKE a group holds its members, depth and the occurrence a move is saved on: ", gs.members.size() == 2 and gs.depth == 1 and gs.occurrence_id() == "s1" and gs.is_group() and gs.root_part_id == "R")
	kb[0].global_position += Vector3(0.5, 0.2, 0)
	gs.follow()
	print("SMOKE moving the anchor carries every other member by the same amount: ", absf(kb[1].global_position.x - 0.8) < 0.0001 and absf(kb[1].global_position.y - 1.2) < 0.0001 and gs.moved())
	print("SMOKE ...and nothing outside the group: ", kb[2].global_position.is_equal_approx(Vector3(1, 1, -1)))
	kb[0].rotate_y(PI / 2.0)
	gs.follow()
	print("SMOKE turning the anchor swings the others about it: ", absf(kb[1].global_position.z - (-1.0 - 0.3)) < 0.001 or absf(kb[1].global_position.z - (-1.0 + 0.3)) < 0.001)
	gs.restore()
	print("SMOKE restore puts every member back: ", kb[0].global_position.is_equal_approx(Vector3(0, 1, -1)) and kb[1].global_position.is_equal_approx(Vector3(0.3, 1, -1)))
	print("SMOKE a group deeper than the top has no occurrence to save on: ", GroupSet.new(kb[0], {"members": [kb[0], kb[1]], "depth": 2, "prefix": ["s1", "k1"], "label": "x"}).occurrence_id() == "")

	# --- the breadcrumb panel
	print("SMOKE the breadcrumb's rows are found from a point on the panel: ", GroupBreadcrumb.row_at(Vector2(0.1, 0.01), 3) == 0 and GroupBreadcrumb.row_at(Vector2(0.1, GroupBreadcrumb.ROW_H * 1.5), 3) == 1 and GroupBreadcrumb.row_at(Vector2(0.1, GroupBreadcrumb.ROW_H * 3.1), 3) == -1 and GroupBreadcrumb.row_at(Vector2(-0.1, 0.01), 3) == -1)

	# --- the controller
	var stub := GDScript.new()
	stub.source_code = STUB
	stub.reload()
	var mates := Node.new()
	mates.set_script(stub)
	main.add_child(mates)
	var stack := CommandStack.new()
	var origin := XROrigin3D.new()
	main.add_child(origin)
	var hand := XRController3D.new()
	hand.tracker = &"left_hand"
	hand.set_script(load("res://scripts/controller.gd"))
	hand.command_stack = stack
	hand.mates_tool = mates
	origin.add_child(hand)
	var camera := XRCamera3D.new()
	origin.add_child(camera)
	camera.global_position = Vector3(0.5, 1.6, 2.0)
	hand._camera = camera
	var messages: Array[String] = []
	hand.group_message.connect(func(t: String) -> void: messages.append(t))
	await process_frame
	hand.set_steadiness(0)
	hand.group_deadzone = 0.02
	for n in nodes:
		n.set_meta("group_root", "R")
	GroupIndex.index(RoomEdit.new(fake), "R", nodes) # (re-tag everything; a coroutine, but the fake answers at once)
	await process_frame
	await process_frame

	# a grip on a bolt inside a drive waits
	var p0: Vector3 = kb[0].global_position
	hand.global_position = p0
	hand._try_grab()
	print("SMOKE a grip on a part inside a sub-assembly latches but takes nothing yet: ", not hand._latch.is_empty() and hand.held_node == null)
	print("SMOKE ...a faint sphere marks the dead zone where the grip closed, and brackets show the part: ", root.find_child("GroupDeadZone", true, false) != null and root.find_child("GroupBrackets", true, false) != null)
	hand.global_position = p0 + Vector3(0.01, 0, 0)
	await tick()
	print("SMOKE moving the hand inside the dead zone commits nothing: ", not hand._latch.is_empty() and hand.held_node == null and kb[0].global_position.is_equal_approx(p0))
	hand._on_button_pressed("trigger_click")
	print("SMOKE a trigger click widens what will be taken by one level, and says so: ", hand._latch["level"] == 1 and messages.size() > 0 and messages.back() == "Bolt < [Drive]")
	hand._on_button_pressed("trigger_click")
	print("SMOKE ...and another comes back round to the part: ", hand._latch["level"] == 0)
	hand._on_button_pressed("trigger_click")
	var steps := stack.history_labels().size()
	hand.global_position = p0 + Vector3(0.1, 0, 0)
	await tick()
	print("SMOKE leaving the dead zone takes the chosen level: the whole drive is held, anchored on the bolt gripped: ", hand._latch.is_empty() and hand._held_group != null and hand.held_node == kb[0] and hand._held_group.members.size() == 2)
	print("SMOKE ...the sphere and brackets are gone: ", root.find_child("GroupDeadZone", true, false) == null and root.find_child("GroupBrackets", true, false) == null)
	hand.global_position = p0 + Vector3(0.4, 0.1, 0)
	await tick()
	var moved_by: Vector3 = kb[0].global_position - p0
	print("SMOKE the group follows the hand as one: ", absf(kb[1].global_position.x - 0.3 - moved_by.x) < 0.001 and kb[2].global_position.is_equal_approx(Vector3(1, 1, -1)) and moved_by.x > 0.2)
	print("SMOKE ...its parts are marked held so nothing else can take them: ", bool(kb[1].get_meta("held", false)))
	hand._try_release()
	await process_frame
	await process_frame
	print("SMOKE letting go records ONE undo step: ", stack.history_labels().size() == steps + 1 and stack.can_undo())
	print("SMOKE ...and saves the sub-assembly's own occurrence (s1 of the root) at the moved pose: ", mates.saved.size() == 1 and mates.saved[0][0] == "R" and mates.saved[0][1] == "s1" and absf((mates.saved[0][2] as Transform3D).origin.x - moved_by.x) < 0.001)
	print("SMOKE ...and the members' held marks are off: ", not bool(kb[1].get_meta("held", false)) and not bool(kb[0].get_meta("held", false)))
	var after0: Vector3 = kb[0].global_position
	var after1: Vector3 = kb[1].global_position
	stack.undo()
	print("SMOKE undo moves the whole drive back and saves the old pose: ", kb[0].global_position.is_equal_approx(p0) and kb[1].global_position.is_equal_approx(Vector3(0.3, 1, -1)) and mates.saved.size() == 2 and (mates.saved[1][2] as Transform3D).is_equal_approx(Transform3D.IDENTITY))
	stack.redo()
	print("SMOKE ...redo does it again: ", kb[0].global_position.is_equal_approx(after0) and kb[1].global_position.is_equal_approx(after1) and mates.saved.size() == 3)
	stack.undo()

	# letting go inside the dead zone does nothing
	steps = stack.history_labels().size()
	hand.global_position = kb[0].global_position
	hand._try_grab()
	hand._try_release()
	print("SMOKE letting go without leaving the dead zone: nothing taken, nothing recorded: ", hand._latch.is_empty() and hand.held_node == null and stack.history_labels().size() == steps)

	# the part alone
	hand.global_position = kb[0].global_position
	hand._try_grab()
	hand.global_position += Vector3(0.1, 0, 0)
	await tick()
	print("SMOKE leaving the dead zone without a trigger click takes just the part: ", hand.held_node == kb[0] and hand._held_group == null)
	hand.global_position += Vector3(0.0, 0.3, 0)
	await tick()
	hand._try_release()
	print("SMOKE ...the other bolt of the drive stayed where it was: ", kb[1].global_position.is_equal_approx(Vector3(0.3, 1, -1)))
	stack.undo()

	# refusals
	mates.states["R|s2"] = "mated"
	hand.global_position = kb[2].global_position
	hand._try_grab()
	hand._on_button_pressed("trigger_click")
	hand.global_position += Vector3(0.1, 0, 0)
	await tick()
	print("SMOKE a sub-assembly that has mates on it is not taken, and the hand is told why: ", hand._held_group == null and hand.held_node == null and messages.back().contains("mates"))
	hand._try_release()
	mates.states["R|s2"] = "grounded"
	hand.global_position = kb[2].global_position
	hand._try_grab()
	hand._on_button_pressed("trigger_click")
	hand.global_position += Vector3(0.1, 0, 0)
	await tick()
	print("SMOKE ...nor a grounded one: ", hand._held_group == null and messages.back().contains("grounded"))
	hand._try_release()
	mates.states.clear()

	# dead zone Off, and a top-level part
	hand.group_deadzone = 0.0
	hand.global_position = kb[0].global_position
	hand._try_grab()
	print("SMOKE with the dead zone off a grip takes the part at once, as it always did: ", hand._latch.is_empty() and hand.held_node == kb[0])
	hand._try_release()
	hand.group_deadzone = 0.02
	hand.global_position = b0.global_position
	hand._try_grab()
	print("SMOKE a top-level part is taken at once whatever the dead zone: ", hand._latch.is_empty() and hand.held_node == b0)
	hand._try_release()

	# selecting a group with the laser
	hand.select_group_level(kb[0], levels[1], kb[0].global_position)
	print("SMOKE selecting a group lights all its parts and anchors on the one chosen: ", hand._sel_group != null and hand.selected_node == kb[0] and kb[1].material_overlay != null and kb[2].material_overlay == null)
	kb[0].global_position += Vector3(0.0, 0.5, 0)
	await tick()
	print("SMOKE moving the anchor (as the thumbstick and A / B do) carries the group: ", absf(kb[1].global_position.y - 1.5) < 0.001)
	hand.global_position = kb[1].global_position
	hand._try_grab()
	print("SMOKE a grip on any part of the selected group carries the whole group at once, no choosing: ", hand._latch.is_empty() and hand._held_group != null and hand.held_node == kb[1])
	hand._try_release()
	hand.global_position = Vector3(20, 0, 0)
	await tick()
	steps = stack.history_labels().size()
	hand._clear_selection()
	await process_frame
	await process_frame
	print("SMOKE deselecting a moved group leaves its move as an undo step (the grip was already one, so not twice): ", hand._sel_group == null and kb[1].material_overlay == null and stack.history_labels().size() == steps)
	while stack.can_undo():
		stack.undo()

	# the breadcrumb under the laser
	hand.select_group_level(kb[0], levels[0], kb[0].global_position)
	# the press is faked as held for a second: a literal 0 is only "held" once the engine has run 450 ms, which a fast CI runner has not
	hand._select_down = true
	hand._crumb_press = {"ms": Time.get_ticks_msec() - 1000, "node": kb[0], "point": kb[0].global_position}
	await tick()
	print("SMOKE holding the trigger on a selected part in a sub-assembly opens the breadcrumb, part first: ", hand._crumb != null and hand._crumb.labels.size() == 2 and hand._crumb.labels[0] == "Bolt")
	var panel: Node3D = hand._crumb
	var row1: Vector3 = panel.global_transform * Vector3(GroupBreadcrumb.WIDTH * 0.5, -GroupBreadcrumb.ROW_H * 1.5, 0.0)
	var normal: Vector3 = panel.global_transform.basis.z
	hand.global_transform = Transform3D(Basis.looking_at(-normal, Vector3.UP), row1 + normal * 1.0)
	await tick()
	print("SMOKE swinging the laser over a row lights it: ", panel.hovered == 1)
	hand._on_button_released("trigger_click")
	print("SMOKE letting go on the drive row selects the drive as a group: ", hand._crumb == null and hand._sel_group != null and hand._sel_group.members.size() == 2)
	hand._clear_selection()
	hand.select_group_level(kb[0], levels[0], kb[0].global_position)
	hand._select_down = true
	hand._crumb_press = {"ms": Time.get_ticks_msec() - 1000, "node": kb[0], "point": kb[0].global_position}
	await tick()
	hand.global_transform = Transform3D(Basis.looking_at(-normal, Vector3.UP), row1 + Vector3(5, 0, 0) + normal * 1.0)
	await tick()
	hand._on_button_released("trigger_click")
	print("SMOKE letting go off the panel keeps the part selected: ", hand._crumb == null and hand._sel_group == null and hand.selected_node == kb[0])
	quit(0)
