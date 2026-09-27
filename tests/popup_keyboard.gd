extends SceneTree
## Popup keyboard (vision brief: "opens on a click of the right thumbstick,
## everywhere, for any text entry"), wired up in main.gd for its first real
## use — typing an exact scale multiple. Instantiates main.tscn (NO backend)
## and drives it with a simulated right thumbstick click plus a laser aimed
## at the popup's own keys (found via the panel's actual transform, not a
## hardcoded mount offset, so it works wherever the panel places itself in
## front of the camera).
## Run: "$GODOT" --headless --path . --script res://tests/popup_keyboard.gd  (see tests/README.md)

var main
var kb
var th
var stack
var l: XRController3D
var r: XRController3D

func find_button(viewport: SubViewport, pred: Callable) -> Button:
	var stack_nodes: Array = [viewport]
	while not stack_nodes.is_empty():
		var n: Node = stack_nodes.pop_back()
		if n is Button and n.is_visible_in_tree() and pred.call(n):
			return n
		stack_nodes.append_array(n.get_children())
	return null

func aim_and_click(b: Button) -> void:
	var c: Vector2 = b.global_position + b.size * 0.5
	var local_x: float = (c.x / kb.viewport_size.x - 0.5) * kb.panel_size.x
	var local_y: float = (0.5 - c.y / kb.viewport_size.y) * kb.panel_size.y
	var world: Vector3 = kb.global_transform * Vector3(local_x, local_y, 0)
	var standoff: Vector3 = kb.global_transform.basis.z.normalized() * 0.3 # in front of the panel's facing side
	r.global_position = world + standoff
	r.look_at(world, Vector3.UP)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame

func type_number(text: String) -> void:
	for ch in text:
		await aim_and_click(find_button(kb._viewport, func(b: Button) -> bool: return b.text == ch))

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
	cam.position = Vector3(0, 1.6, 0); cam.rotation = Vector3.ZERO
	l.position = Vector3(-0.2, 1.0, 0)
	r.position = Vector3(0.2, 1.0, 0)
	kb = main._keyboard
	th = main._two_hand
	stack = main.command_stack
	for i in 4:
		await process_frame

	print("SMOKE closed by default: ", not kb.is_open())
	r.button_pressed.emit("primary_click")
	await process_frame
	print("SMOKE opens on right thumbstick click: ", kb.is_open())
	print("SMOKE pre-filled with the model's current scale: ", kb._text, " (scale x", th.current_multiple(), ")")

	# a second thumbstick click while open closes it without applying anything
	var scale_before: float = th.current_multiple()
	r.button_pressed.emit("primary_click")
	await process_frame
	print("SMOKE second thumbstick click closes it: ", not kb.is_open())
	print("SMOKE nothing was applied: ", th.current_multiple() == scale_before)

	# open again, type "2.5", OK -> applies through two_hand_model's set_preset (so it's undoable)
	r.button_pressed.emit("primary_click")
	await process_frame
	await type_number("2.5")
	print("SMOKE typed text: ", kb._text)
	await aim_and_click(find_button(kb._viewport, func(b: Button) -> bool: return b.text == "OK"))
	print("SMOKE OK applies the typed value: closed=", not kb.is_open(), " scale=x", th.current_multiple())
	print("SMOKE typing a scale is undoable: ", stack.can_undo())
	stack.undo()
	print("SMOKE undo reverts it: x", th.current_multiple())

	# open, type something, Cancel -> nothing applied
	var before_cancel: float = th.current_multiple()
	r.button_pressed.emit("primary_click")
	await process_frame
	await type_number("9")
	await aim_and_click(find_button(kb._viewport, func(b: Button) -> bool: return b.text == "Cancel"))
	print("SMOKE Cancel closes without applying: closed=", not kb.is_open(), " scale unchanged=", th.current_multiple() == before_cancel)

	# backspace
	r.button_pressed.emit("primary_click")
	await process_frame
	await type_number("42")
	await aim_and_click(find_button(kb._viewport, func(b: Button) -> bool: return b.text == "<-"))
	print("SMOKE backspace removes the last digit: ", kb._text)

	# --- real-headset regression, same class of bug as tests/tablet_scene.gd's
	# own drift check: a real trigger squeeze isn't instantaneous, and Godot's
	# BaseButton cancels a press on ANY intervening motion event landing
	# outside its rect — see wrist_tablet.gd's _send_click() for the full
	# reasoning (popup_keyboard.gd shares the identical fix).
	if kb.is_open(): # backspace above left it open — primary_click toggles, so close first or the next click would close it instead of opening it
		kb.close()
	r.button_pressed.emit("primary_click")
	await process_frame
	var five := find_button(kb._viewport, func(b: Button) -> bool: return b.text == "5")
	var c: Vector2 = five.global_position + five.size * 0.5
	var local_x: float = (c.x / kb.viewport_size.x - 0.5) * kb.panel_size.x
	var local_y: float = (0.5 - c.y / kb.viewport_size.y) * kb.panel_size.y
	var world: Vector3 = kb.global_transform * Vector3(local_x, local_y, 0)
	var standoff: Vector3 = kb.global_transform.basis.z.normalized() * 0.3
	r.global_position = world + standoff
	r.look_at(world, Vector3.UP)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click") # DOWN squarely on "5"
	await process_frame
	r.global_position += kb.global_transform.basis.x * 0.03 # drift sideways along the panel mid-press, direction unchanged (no new look_at)
	for i in 3:
		await process_frame
	r.button_released.emit("trigger_click")
	await process_frame
	print("SMOKE a key press still registers despite drifting mid-press: ", kb._text.ends_with("5"))

	kb.close()
	quit()
