extends SceneTree
## The popup keyboard's grab handle (scripts/ui/panel_handle.gd, same piece the floating
## windows use) and its restyle, full scene (main.tscn, no backend): the keyboard joins the
## "diegetic_panels" group so controller.gd defers to its handle; a grip near the handle
## carries the keyboard 1:1 (keeping the full keyboard's lean), release drops it; closing
## mid-carry clears the hand's window_held meta; the keyboard REOPENS where it was left
## (separately for the numeric and full layouts) and comes back in front of you if you've
## walked away; keys are still pressable by the laser at its moved position; the keys use
## the theme's accent for the confirming key.
## Run: "$GODOT" --headless --path . --script res://tests/keyboard_handle.gd  (see tests/README.md)

var main
var kb
var l: XRController3D
var r: XRController3D
var cam: XRCamera3D
var typed := []

func find_button(pred: Callable) -> Button:
	var stack: Array = [kb._viewport]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack.append_array(n.get_children())
	return null

func frames(n: int = 3) -> void:
	for i in n:
		await process_frame

func grab_at_handle() -> void:
	l.global_position = kb.handle.node.global_position
	await physics_frame
	l.button_pressed.emit("grip_click")

func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	cam = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	kb = main._keyboard
	await frames(3)

	print("SMOKE the keyboard is in the diegetic_panels group (controller.gd asks it about handle grabs): ", kb.is_in_group("diegetic_panels") and kb.has_method("handle_in_reach"))
	print("SMOKE it has a handle mesh at the centre of its lower edge: ", kb.handle != null and kb.handle.node != null and kb.handle.node.position.y < -kb.panel_size.y * 0.5 and absf(kb.handle.node.position.x) < 0.001)

	# --- numeric layout
	main.open_keyboard_for("1", func(t: String) -> void: typed.append(t))
	await frames(2)
	var spawn: Transform3D = kb.global_transform
	print("SMOKE it opens in front of the camera by default: ", kb.is_open() and kb.current_mode() == "numeric")
	l.global_position = kb.handle.node.global_position + Vector3(0.6, 0, 0)
	print("SMOKE a hand 60 cm from the handle is not in reach: ", not kb.handle_in_reach(l))
	await grab_at_handle()
	print("SMOKE a grip at the handle picks the keyboard up and sets window_held: ", kb.handle.held_by == l and l.get_meta("window_held", false) == true)
	var before: Vector3 = kb.global_position
	l.position += Vector3(0.3, 0.1, 0.0)
	await frames(3)
	print("SMOKE the keyboard follows the hand 1:1: ", (kb.global_position - before).is_equal_approx(Vector3(0.3, 0.1, 0.0)))
	print("SMOKE a carried keyboard is not hoverable (no stray key presses mid-carry): ", not kb._hovering)
	l.button_released.emit("grip_click")
	await frames(2)
	var dropped: Transform3D = kb.global_transform
	print("SMOKE releasing drops it and clears window_held: ", kb.handle.held_by == null and l.get_meta("window_held", true) == false)
	l.position += Vector3(1.0, 0, 0)
	await frames(2)
	print("SMOKE ...and it no longer follows the hand: ", kb.global_transform.is_equal_approx(dropped))
	kb.close()
	main.open_keyboard_for("2", func(t: String) -> void: typed.append(t))
	await frames(2)
	print("SMOKE it reopens where it was left (not back in front of the camera): ", kb.global_transform.is_equal_approx(dropped) and not kb.global_transform.is_equal_approx(spawn))

	# --- a key still presses at the moved position (laser aimed at the panel)
	typed.clear()
	var five := find_button(func(b): return b.text == "5")
	var c: Vector2 = five.global_position + five.size * 0.5
	var lx: float = (c.x / kb.viewport_size.x - 0.5) * kb.panel_size.x
	var ly: float = (0.5 - c.y / kb.viewport_size.y) * kb.panel_size.y
	var p: Vector3 = kb.global_transform * Vector3(lx, ly, 0.0)
	var n: Vector3 = kb.global_transform.basis.z.normalized()
	r.global_transform = Transform3D(Basis.looking_at(-n, Vector3.UP), p + n * 0.5)
	await frames(3)
	r.button_pressed.emit("trigger_click"); await process_frame; r.button_released.emit("trigger_click"); await process_frame
	kb._key_pressed("OK")
	print("SMOKE a key pressed by the laser at the moved position registers: ", typed.size() == 1 and typed[0] == "5" or typed == ["25"])

	# --- closing mid-carry must not leave the meta stuck
	kb.open_for("3", func(_t: String) -> void: pass)
	await frames(2)
	await grab_at_handle()
	var gripped: bool = l.get_meta("window_held", false) == true
	kb.close()
	print("SMOKE closing the keyboard mid-carry clears window_held: ", gripped and l.get_meta("window_held", true) == false)
	l.button_released.emit("grip_click")

	# --- the full layout keeps its own remembered spot, and its lean
	main.open_keyboard_for("", func(_t: String) -> void: pass, {"mode": "full", "title": "type"})
	await frames(2)
	var full_spawn: Transform3D = kb.global_transform
	print("SMOKE the full keyboard opens low and leaning back (its own spot, not the numeric one): ", kb.current_mode() == "full" and not full_spawn.origin.is_equal_approx(dropped.origin) and absf(full_spawn.basis.get_euler().x) > 0.3)
	await grab_at_handle()
	var lean_before: Vector3 = kb.global_transform.basis.z
	l.position += Vector3(0.0, 0.0, 0.4)
	await frames(3)
	var lean_after: Vector3 = kb.global_transform.basis.z
	l.button_released.emit("grip_click")
	await frames(2)
	var full_dropped: Transform3D = kb.global_transform
	print("SMOKE carrying keeps the lean (orientation unchanged): ", lean_before.is_equal_approx(lean_after))
	kb.close()
	main.open_keyboard_for("", func(_t: String) -> void: pass, {"mode": "full"})
	await frames(2)
	print("SMOKE the full keyboard reopens at ITS dropped spot: ", kb.global_transform.is_equal_approx(full_dropped))
	kb.close()
	main.open_keyboard_for("4", func(_t: String) -> void: pass)
	await frames(2)
	print("SMOKE ...while the numeric keypad still reopens at its own: ", kb.global_transform.is_equal_approx(dropped))

	# --- walk away: back in front of you
	kb.close()
	cam.global_position += Vector3(0, 0, 8.0)
	main.open_keyboard_for("5", func(_t: String) -> void: pass)
	await frames(2)
	print("SMOKE after walking >3 m away it comes back in front of the camera instead: ", kb.global_position.distance_to(cam.global_position) < 1.5)

	# --- look
	var ok := find_button(func(b): return b.text == "OK")
	var seven := find_button(func(b): return b.text == "7")
	print("SMOKE the confirming key is the accent variation, ordinary keys are not: ", ok != null and ok.theme_type_variation == &"ButtonAccent" and seven.theme_type_variation != &"ButtonAccent")
	kb.close()
	quit()
