extends SceneTree
## View > Visibility sub-tab (main.gd's hide_all_parts/show_all_parts/
## reverse_visibility/isolate_selected, plus controller.gd's shoot-to-hide):
## instantiates main.tscn (NO backend), loads a generated multi-part .glb
## the same way tablet_scene.gd does, and drives the real Visibility buttons
## plus a simulated shoot-to-hide trigger pull.
## Run: "$GODOT" --headless --path . --script res://tests/tools_tab.gd  (see tests/README.md)

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
	# The tablet is tilted on the wrist: stand the controller along its normal and look straight at the button.
	var c: Vector2 = b.global_position + b.size * 0.5
	var lx: float = (c.x / tab.viewport_size.x - 0.5) * tab.panel_size.x
	var ly: float = (0.5 - c.y / tab.viewport_size.y) * tab.panel_size.y
	var xf: Transform3D = tab._quad.global_transform
	var p: Vector3 = xf * Vector3(lx, ly, 0.0)
	var n: Vector3 = xf.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * 0.4)
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
	r.rotation_degrees = Vector3(-90, 0, 0)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click"); await process_frame
	print("SMOKE tablet opened: ", tab._open)
	await create_timer(0.5).timeout # open_settle_seconds: ignores an immediate second pull

	# a real 3-box .glb, same technique tablet_scene.gd uses — spaced well
	# apart (not just offset by less than their own size) so aiming at one
	# doesn't ambiguously also hit its neighbours
	var scene := Node3D.new()
	for i in 3:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new(); bm.size = Vector3(0.15, 0.15, 0.15)
		mi.mesh = bm; mi.name = "Part%d" % i
		mi.position = Vector3(i * 0.6, 0, 0)
		scene.add_child(mi)
	var gd := GLTFDocument.new(); var gs := GLTFState.new()
	gd.append_from_scene(scene, gs)
	DirAccess.make_dir_recursive_absolute("user://models")
	gd.write_to_filesystem(gs, "user://models/tools_test.glb")
	main.load_glb_file("user://models/tools_test.glb")
	await process_frame
	print("SMOKE loaded parts: ", main._part_count)

	await aim_and_click(tab.ui.home_tile("view"))
	var visibility_tab: Button = tab.ui.hub_tile("visibility") # View is a hub: its tiles come first
	await aim_and_click(visibility_tab)
	print("SMOKE View > Visibility opens: ", tab.ui.selected_tool_id == "visibility")

	# hide all / show all
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text == "Hide all"))
	var parts: Array = main.get_tree().get_nodes_in_group("grabbable_parts")
	print("SMOKE hide all: every part hidden: ", parts.all(func(p: Node3D) -> bool: return not p.visible))
	print("SMOKE hide all is undoable: ", stack.can_undo())
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text == "Show all"))
	print("SMOKE show all: every part visible again: ", parts.all(func(p: Node3D) -> bool: return p.visible))
	stack.undo()
	print("SMOKE undo of show-all puts them back hidden: ", parts.all(func(p: Node3D) -> bool: return not p.visible))
	stack.undo()
	print("SMOKE undo of hide-all restores them: ", parts.all(func(p: Node3D) -> bool: return p.visible))

	# reverse visibility
	parts[0].visible = false
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text == "Reverse visibility"))
	print("SMOKE reverse visibility flips each part: ", parts[0].visible == true and parts[1].visible == false and parts[2].visible == false)
	stack.undo()
	print("SMOKE undo restores the exact prior mix: ", parts[0].visible == false and parts[1].visible == true and parts[2].visible == true)
	stack.redo()

	# isolate: select part 1 with the laser, isolate hides the rest
	stack.clear()
	for p in parts:
		p.visible = true
	r.rotation_degrees.x = 0
	r.position = parts[1].global_position + Vector3(0, 0, 2)
	r.look_at(parts[1].global_position, Vector3.UP)
	await physics_frame; await physics_frame
	r._try_select()
	print("SMOKE selected part1 for isolate: ", r.selected_node == parts[1])
	await aim_and_click(find_button(func(b: Button) -> bool: return b.text == "Isolate selected"))
	print("SMOKE isolate hides everything except the selected part: ", parts[0].visible == false and parts[1].visible == true and parts[2].visible == false)
	stack.undo()
	print("SMOKE undo of isolate restores all-visible: ", parts.all(func(p: Node3D) -> bool: return p.visible))

	# shoot-to-hide: toggle the tool on, aim at a part, pull the trigger
	stack.clear()
	await aim_and_click(tab.ui._back_button) # up to the View hub, then its Shoot hide tile
	await aim_and_click(tab.ui.hub_tile("shoot_hide"))
	print("SMOKE shoot-to-hide toggled on both hands (its hub tile turns it on): ", l.hide_tool_active and r.hide_tool_active and tab.manager.active_id == "shoot_hide")
	r.position = parts[2].global_position + Vector3(0, 0, 2)
	r.look_at(parts[2].global_position, Vector3.UP)
	await physics_frame; await physics_frame
	r.button_pressed.emit("trigger_click"); await physics_frame; r.button_released.emit("trigger_click")
	print("SMOKE shoot-to-hide hid the aimed-at part: ", parts[2].visible == false, " (others untouched: ", parts[0].visible and parts[1].visible, ")")
	print("SMOKE shoot-to-hide is undoable: ", stack.can_undo())
	stack.undo()
	print("SMOKE undo brings it back: ", parts[2].visible == true)

	# a hidden part is click-through for both the laser and grip-grab
	parts[2].visible = false
	var hit: Dictionary = r._raycast_part(r.global_transform.origin, -r.global_transform.basis.z.normalized(), r.select_max_distance)
	print("SMOKE hidden part is click-through for the laser: ", hit.get("part") != parts[2])
	l.position = parts[2].global_position
	await physics_frame; await physics_frame
	print("SMOKE hidden part can't be grip-grabbed: ", l._find_grab_target() != parts[2])
	quit()
