extends SceneTree
## The popup keyboard's FULL layout (29 Sep 2026) — needed to type web
## addresses into the Browser window (and hex colours, folder paths): letters,
## Shift/Caps, a symbols layer, URL keys, confirm mode and live mode (keys
## streamed to a callback, which the Browser turns into CDP key events).
## Instantiates main.tscn (NO backend) and drives the keyboard with a laser
## and real button_pressed/released signals, same as tests/popup_keyboard.gd.
## Run: "$GODOT" --headless --path . --script res://tests/full_keyboard.gd  (see tests/README.md)

var main
var kb
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


func click_key(label: String) -> void:
	var b := find_button(kb._viewport, func(x: Button) -> bool: return x.text == label)
	if b == null:
		print("SMOKE MISSING KEY: ", label)
		return
	var c: Vector2 = b.global_position + b.size * 0.5
	var local_x: float = (c.x / kb.viewport_size.x - 0.5) * kb.panel_size.x
	var local_y: float = (0.5 - c.y / kb.viewport_size.y) * kb.panel_size.y
	var world: Vector3 = kb.global_transform * Vector3(local_x, local_y, 0)
	r.global_position = world + kb.global_transform.basis.z.normalized() * 0.3
	r.look_at(world, Vector3.UP)
	for i in 3:
		await process_frame
	r.button_pressed.emit("trigger_click")
	await process_frame
	r.button_released.emit("trigger_click")
	await process_frame
	await process_frame # a key that rebuilds the key set (Shift, ?123) frees its own button: let that settle


func type_keys(text: String) -> void:
	for ch in text:
		await click_key(ch)


func has_keys(labels: Array) -> bool:
	for label in labels:
		if find_button(kb._viewport, func(x: Button) -> bool: return x.text == label) == null:
			return false
	return true


func _initialize() -> void:
	main = load("res://scenes/main.tscn").instantiate()
	main.secrets_file_path = "res://__nonexistent__.cfg"
	root.add_child(main)
	await process_frame
	var origin: XROrigin3D = main.get_node("XROrigin3D")
	var cam: XRCamera3D = origin.get_node("XRCamera3D")
	l = origin.get_node("LeftController")
	r = origin.get_node("RightController")
	cam.position = Vector3(0, 1.6, 0)
	cam.rotation = Vector3.ZERO
	l.position = Vector3(-0.2, 1.0, 0)
	r.position = Vector3(0.2, 1.0, 0)
	kb = main._keyboard
	for i in 3:
		await process_frame

	# --- the default is still the numeric keypad
	main.open_keyboard_for("1", func(_t: String) -> void: pass)
	await process_frame
	print("SMOKE the default (no options) is still the numeric keypad: ", kb.current_mode() == "numeric" and kb.panel_size.x < 0.3 and not has_keys(["q", "w"]))
	kb.close()

	# --- full keyboard, confirm mode
	var got := []
	main.open_keyboard_for("https://old.example", func(t: String) -> void: got.append(t), {"mode": "full", "title": "Web address", "confirm_label": "Go"})
	for i in 3:
		await process_frame
	print("SMOKE the full keyboard is wide and opens: ", kb.is_open() and kb.current_mode() == "full" and kb.panel_size.x > 0.5 and kb.viewport_size.x >= 1000)
	print("SMOKE it has a full QWERTY set, digits, Space, Shift, Caps, ?123 and the confirm key labelled Go: ", has_keys(["q", "p", "a", "l", "z", "m", "1", "0", "Space", "Shift", "Caps", "?123", "Go", "Cancel", "/", ":", ".com"]))
	var to_cam: Vector3 = (cam.global_position - kb.global_position).normalized()
	print("SMOKE it sits below eye level and leans back (front face tilted up towards you): ", kb.global_position.y < cam.global_position.y - 0.3 and kb.global_transform.basis.z.y > 0.3 and kb.global_transform.basis.z.dot(to_cam) > 0.5)
	print("SMOKE the hint line shows the title: ", kb._hint.text == "Web address")

	await type_keys("example")
	print("SMOKE typing over the pre-filled address replaces it: ", kb._text == "example")
	await click_key(".com")
	print("SMOKE the '.com' key appends '.com': ", kb._text == "example.com")
	await click_key("<-")
	print("SMOKE backspace removes the last character: ", kb._text == "example.co")
	await click_key("m")

	# Shift is one-shot
	await click_key("Shift")
	print("SMOKE Shift turns the letter keys capital: ", has_keys(["Q", "A"]) and not has_keys(["q"]))
	await click_key("Q")
	print("SMOKE ...types one capital and then turns itself off: ", kb._text == "example.comQ" and has_keys(["q", "a"]) and not has_keys(["Q"]))
	await click_key("<-")
	# Caps stays on
	await click_key("Caps")
	await click_key("A")
	await click_key("B")
	print("SMOKE Caps keeps capitals on: ", kb._text == "example.comAB" and has_keys(["Q"]))
	await click_key("Caps")
	await click_key("<-")
	await click_key("<-")

	# symbols layer
	await click_key("?123")
	print("SMOKE the ?123 layer offers symbols and a way back: ", has_keys(["@", "#", "?", "&", "=", "%", "abc", "Space"]) and not has_keys(["q"]))
	await click_key("/")
	await click_key("?")
	await click_key("=")
	await click_key("abc")
	print("SMOKE symbols typed into the address, and abc returns to letters: ", kb._text == "example.com/?=" and has_keys(["q"]))
	await click_key("Space")
	print("SMOKE Space types a space: ", kb._text == "example.com/?= ")
	await click_key("Clear")
	print("SMOKE Clear empties it: ", kb._text == "")
	await type_keys("x1")
	await click_key("Go")
	print("SMOKE the confirm key calls back once with the typed text and closes the keyboard: ", got == ["x1"] and not kb.is_open())

	# Enter confirms in confirm mode; Cancel doesn't call back
	got.clear()
	main.open_keyboard_for("", func(t: String) -> void: got.append(t), {"mode": "full", "confirm_label": "Go"})
	await process_frame
	await type_keys("ab")
	# The row-3 Enter key wears the confirm label ("Go") outside live mode: same effect as OK.
	print("SMOKE outside live mode there's a second confirm key on the home row (Enter, labelled Go): ", find_button(kb._viewport, func(x: Button) -> bool: return x.text == "Go") != null)
	kb._key_pressed("Enter")
	print("SMOKE Enter also confirms outside live mode: ", got == ["ab"] and not kb.is_open())
	main.open_keyboard_for("keep", func(t: String) -> void: got.append(t), {"mode": "full"})
	await process_frame
	await click_key("Cancel")
	print("SMOKE Cancel closes without calling back: ", got == ["ab"] and not kb.is_open())

	# backspace on an untouched pre-filled address clears it all (URL-bar behaviour)
	main.open_keyboard_for("https://example.com", func(_t: String) -> void: pass, {"mode": "full"})
	await process_frame
	await click_key("<-")
	print("SMOKE backspace on the untouched pre-filled address clears it: ", kb._text == "")
	kb.close()

	# --- live mode: keys streamed to the callback (what the Browser turns into CDP events)
	var log := []
	main.open_keyboard_for("", Callable(), {"mode": "full", "live": true, "title": "Typing into the page", "on_input": func(kind: String, value: String) -> void: log.append([kind, value])})
	await process_frame
	print("SMOKE live mode shows Done (not Cancel/OK) and Enter/Tab are live: ", has_keys(["Done", "Enter", "Tab"]) and not has_keys(["Cancel", "OK", "Go"]))
	await type_keys("hi")
	await click_key("Space")
	await click_key("<-")
	await click_key("Enter")
	await click_key("Tab")
	await click_key("Shift")
	await click_key("Z")
	print("calibration — live log: ", log)
	print("SMOKE live keys arrive as they're pressed (text vs key events): ", log == [["text", "h"], ["text", "i"], ["text", " "], ["key", "Backspace"], ["key", "Enter"], ["key", "Tab"], ["text", "Z"]])
	print("SMOKE live mode stays open between keys: ", kb.is_open())
	await click_key("Done")
	print("SMOKE Done closes it: ", not kb.is_open())

	# --- the Browser window: address bar -> full keyboard -> normalised navigation
	var browser = main._browser_window
	browser.open()
	await process_frame
	browser._url_bar.text = "https://old.example/page"
	browser.edit_address()
	await process_frame
	print("SMOKE the Browser's address editor opens the full keyboard pre-filled with the address: ", kb.is_open() and kb.current_mode() == "full" and kb._text == "https://old.example/page")
	await type_keys("news")
	await click_key(".")
	await type_keys("test")
	await click_key("Go")
	print("SMOKE typing an address and Go puts the normalised URL in the bar: ", browser._url_bar.text == "https://news.test")
	# poking the address bar itself opens the keyboard too
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	browser._url_bar.gui_input.emit(press)
	await process_frame
	print("SMOKE poking the address bar opens the keyboard: ", kb.is_open() and kb._text == "https://news.test")
	kb.close()
	print("SMOKE the address bar isn't directly editable (no physical keyboard): ", not browser._url_bar.editable)
	browser.type_into_page()
	await process_frame
	print("SMOKE the Browser's 'Aa' opens the keyboard in live mode: ", kb.is_open() and kb._live.is_valid() and has_keys(["Done"]))
	kb.close()
	browser.close()

	# --- callers that need real text now get the full keyboard; numbers stay numeric
	var tablet = l.get_node("WristTablet")
	tablet.pages._on_custom_colour_pressed()
	await process_frame
	print("SMOKE the Custom colour hex entry uses the full keyboard (it needs a-f): ", kb.is_open() and kb.current_mode() == "full")
	kb.close()
	tablet.pages._on_set_project_folder_pressed()
	await process_frame
	print("SMOKE the project-folder entry uses the full keyboard (it's a path): ", kb.is_open() and kb.current_mode() == "full")
	kb.close()

	quit()
