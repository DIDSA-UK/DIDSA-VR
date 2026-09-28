extends SceneTree
## Assembly > Sections sub-tab (wrist_tablet.gd, section_tool.gd's real
## grab/reconcile pipeline): instantiates main.tscn (NO backend), loads a
## generated multi-part .glb the same way tools_tab.gd/tablet_scene.gd do,
## drives the real Sections buttons, and simulates a grip grab on the
## plane gizmo by calling controller.gd's own grab routines directly — same
## "a real grip press can't be faked headless" precedent tablet_scene.gd's
## own one-hand-drag check and tools_tab.gd's own grip-grab check both use.
## Run: "$GODOT" --headless --path . --script res://tests/section_tab.gd  (see tests/README.md)

var main
var tab
var stack
var l: XRController3D
var r: XRController3D

func find_button(pred: Callable) -> Button:
	var stack_nodes: Array = [tab._viewport]
	while not stack_nodes.is_empty():
		var n: Node = stack_nodes.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack_nodes.append_array(n.get_children())
	return null

func aim_and_click(b: Button) -> void:
	var c: Vector2 = b.global_position + b.size * 0.5
	var lx: float = (c.x / tab.viewport_size.x - 0.5) * tab.panel_size.x
	var ly: float = (0.5 - c.y / tab.viewport_size.y) * tab.panel_size.y
	r.position = Vector3(l.position.x + tab.mount_position.x + lx, 1.5, l.position.z + tab.mount_position.z - ly)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	main = packed.instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg" # no backend => no network
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	l.position = Vector3(0, 1.0, 0)
	cam.position = Vector3(0, 1.6, 0.07); cam.rotation_degrees.x = -90
	r.rotation_degrees.x = -90
	tab = l.get_node("WristTablet")
	stack = main.command_stack
	for i in 4:
		await process_frame

	# shoot the wrist bullseye to open the tablet (closed by default)
	r.position = Vector3(l.position.x + tab.target_position.x, 1.5, l.position.z + tab.target_position.z)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click"); await process_frame
	await create_timer(0.5).timeout # open_settle_seconds: ignores an immediate second pull

	# a real 2-box .glb, same technique tools_tab.gd uses
	var scene := Node3D.new()
	for i in 2:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(0.15, 0.15, 0.15)
		mi.mesh = bm; mi.name = "Part%d" % i
		mi.position = Vector3(i * 0.6, 0, 0)
		scene.add_child(mi)
	var gd := GLTFDocument.new(); var gs := GLTFState.new()
	gd.append_from_scene(scene, gs)
	DirAccess.make_dir_recursive_absolute("user://models")
	gd.write_to_filesystem(gs, "user://models/section_test.glb")
	main.load_glb_file("user://models/section_test.glb")
	await process_frame
	print("SMOKE loaded parts: ", main._part_count)
	var parts: Array = main.get_tree().get_nodes_in_group("grabbable_parts")

	await aim_and_click(find_button(func(b: Button) -> bool: return b.text == "Assembly"))
	var sections_tab := find_button(func(b: Button) -> bool: return b.text == "Sections")
	await aim_and_click(sections_tab)
	print("SMOKE Assembly > Sections opens: ", tab._pages["Assembly"].visible and sections_tab.button_pressed)
	print("SMOKE section tool starts off: ", main._section_tool.active == false)

	# turn the tool on: spawns a gizmo, no parts wrapped yet until the next process frame's reconcile()
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text.begins_with("Section tool")))
	print("SMOKE section tool active after toggling on: ", main._section_tool.active == true)
	print("SMOKE toggling on spawns a gizmo: ", main._section_tool.gizmo() != null)
	for i in 3:
		await process_frame # let main.gd's _process() reconcile() run
	print("SMOKE every part gets wrapped with the clip shader: ", parts.all(func(p: MeshInstance3D) -> bool: return p.material_override is ShaderMaterial))

	# grip near the gizmo grabs it, not a part. A real grip press can't be
	# faked headless, but a real button EMIT can — l.button_pressed.emit(...)
	# is the same idiom tablet_scene.gd/tools_tab.gd already use for the
	# right controller's trigger, applied to the left controller's grip here
	# so this exercises the actual _on_button_pressed() wiring this session
	# added (the "parts_enabled or section_tool.active" branch), not just
	# section_tool.gd's own try_grab() in isolation (already covered pure-
	# logic by tests/section_tool.gd).
	l.set_steadiness(0) # Off: an exact 1:1 read, same reason tests/section_tool.gd's own drag check passes steadiness_on=false to update_held() directly
	l.position = main._section_tool.gizmo().global_position
	await physics_frame; await physics_frame
	l.button_pressed.emit("grip_click")
	await physics_frame
	print("SMOKE grip near the gizmo grabs it, not a part: ", l.held_node == null and main._section_tool.gizmo() != null)
	var gizmo_before: Vector3 = main._section_tool.gizmo().global_position
	l.position += Vector3(0.2, 0, 0)
	await physics_frame # controller.gd's own _physics_process() calls section_tool.update_held() every physics frame while grabbed
	print("SMOKE dragging the gizmo by grip moves it: ", main._section_tool.gizmo().global_position.is_equal_approx(gizmo_before + Vector3(0.2, 0, 0)))
	l.button_released.emit("grip_click")
	await physics_frame
	print("SMOKE releasing grip drops the gizmo and pushes an undo command: ", stack.can_undo())
	stack.undo()

	# the gizmo never steals a real part-grab: move it well out of the way
	# first (this check should hold regardless of where the gizmo happens to
	# spawn by default) and grip right next to a real part
	main._section_tool.gizmo().global_position = Vector3(100, 100, 100)
	l.position = parts[0].global_position
	await physics_frame; await physics_frame
	l.button_pressed.emit("grip_click")
	await physics_frame
	print("SMOKE grip next to a real part still grabs the part (gizmo isn't in the way): ", l.held_node == parts[0])
	l.button_released.emit("grip_click")
	await physics_frame
	stack.clear()

	# Flip
	print("SMOKE flip starts off: ", main._section_tool.flipped == false)
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text == "Flip"))
	print("SMOKE flip toggles: ", main._section_tool.flipped == true)

	# turning the tool off restores every part's real material and drops the gizmo
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text.begins_with("Section tool")))
	print("SMOKE section tool off: gizmo dropped: ", main._section_tool.gizmo() == null)
	print("SMOKE every part's material_override is restored (none were ever colour_tool-overridden): ", parts.all(func(p: MeshInstance3D) -> bool: return p.material_override == null))

	# loading a different model doesn't crash reset()/reconcile() against stale part refs
	main.load_glb_file("user://models/section_test.glb")
	await process_frame
	print("SMOKE reload after using Sections doesn't error (part count still correct): ", main._part_count == 2)

	DirAccess.remove_absolute("user://models/section_test.glb")
	quit()
