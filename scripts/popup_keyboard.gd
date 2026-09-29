extends Node3D
## The popup keyboard from the vision brief: "A popup keyboard opens on a
## click of the right thumbstick, everywhere, for any text entry." Reserved
## since milestone 1's wrist tablet was built (`primary_click` was left
## deliberately unused there). This first real use is a numeric keypad for
## typing an exact scale multiple (wired up by main.gd): press the right
## thumbstick to open it pre-filled with the model's current scale, type a
## new number, OK to apply it (goes through two_hand_model.gd's set_preset(),
## so it's undoable like any other scale change), Cancel/thumbstick-click-
## again to back out.
##
## TWO LAYOUTS (29 Sep 2026): the numeric keypad above (the default; scale
## multiple, mate value), and a FULL keyboard (options {"mode": "full"}) for any
## real text — web addresses, hex colours, folder paths, typing into a web
## page. Full layout: a letters layer with Shift (one-shot) and Caps, a
## symbols layer (?123 / abc), and URL-friendly keys (/ : . -, ".com"); it opens
## lower and tilted like a keyboard on your lap, so it doesn't cover a floating
## window in front of you. Two ways to use it:
##   * confirm mode — type, then OK (or Enter) calls on_confirm(text) once;
##     the first keystroke replaces the pre-filled text (like a URL bar).
##   * live mode (options {"live": true, "on_input": Callable}) — every key is
##     handed straight to on_input("text", "a") / on_input("key", "Backspace" |
##     "Enter" | "Tab") as it's pressed and the keyboard stays open until Done;
##     the Browser window uses this to type into whatever text box you clicked.
## Options: mode, title (hint line), confirm_label (the OK key's text, e.g. "Go").
##
## Same mechanism as wrist_tablet.gd: a Control UI in a SubViewport on a
## quad, hit-tested by hand against the right hand's laser (no physics), with
## mouse events pushed into the SubViewport. It isn't wrist-mounted — it pops
## up in front of wherever you're looking, since the brief says "everywhere",
## not tied to one tool or tab.

@export var panel_size := Vector2(0.22, 0.26) ## metres
@export var viewport_size := Vector2i(420, 520) ## pixels the UI is laid out in
@export var open_distance: float = 0.6 ## metres in front of the camera when opened
@export var max_point_distance: float = 2.0 ## metres; laser reach for pressing keys
@export var click_action: String = "trigger_click"

var _right: XRController3D
var _camera: XRCamera3D

var _viewport: SubViewport
var _quad: MeshInstance3D
var _cursor: Control
var _display: Label
var _hint: Label
var _ui_root: Control
var _keys_box: VBoxContainer
var _mode := "numeric"
var _options: Dictionary = {}
var _layer := "abc" ## full mode: "abc" letters or "sym" symbols
var _shift := false ## one-shot capital for the next letter
var _caps := false
var _live: Callable = Callable() ## live mode: on_input(kind, value); invalid = confirm mode
var _typed := "" ## live mode: what's been typed this session (display only)

var _open := false
var _text := ""
var _pristine := false ## true until the first keystroke: that keystroke clears the pre-filled value instead of appending to it
var _on_confirm: Callable = Callable()
var _hovering := false
var _pointer_px := Vector2.ZERO
var _press_px := Vector2.ZERO ## _pointer_px frozen at the moment the trigger went down — see _send_click()'s own docstring
var _last_sent_px := Vector2(-1, -1)
var _pressed := false


func setup(right: XRController3D, camera: XRCamera3D) -> void:
	_right = right
	_camera = camera
	_build_viewport()
	_build_quad()
	_right.button_pressed.connect(_on_right_pressed)
	_right.button_released.connect(_on_right_released)
	visible = false


func is_open() -> bool:
	return _open


func open_for(initial_text: String, on_confirm: Callable, options: Dictionary = {}) -> void:
	## initial_text pre-fills the display (e.g. the model's current scale);
	## on_confirm(text: String) is called once, with whatever was typed, when
	## OK is pressed — it decides how to parse/apply it (and can reject it by
	## just doing nothing). `options`: see this file's docstring (mode/title/
	## confirm_label/live/on_input). Existing numeric callers pass none.
	_options = options
	_mode = str(options.get("mode", "numeric"))
	_live = options.get("on_input", Callable()) if bool(options.get("live", false)) else Callable()
	_layer = "abc"
	_shift = false
	_caps = false
	_typed = ""
	_apply_layout()
	_text = initial_text
	_pristine = true
	_on_confirm = on_confirm
	_update_display()
	_place_in_front_of_camera()
	_open = true
	visible = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func current_mode() -> String:
	return _mode


func close() -> void:
	_open = false
	visible = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_right.set_meta("ui_hover", false)
	_right.set_meta("ui_hit_distance", -1.0) # _update_pointer() only runs while open, so this has to be reset explicitly here too — otherwise the laser could stay shortened to a stale distance after closing


func _place_in_front_of_camera() -> void:
	if _camera == null:
		return
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	# Yaw-only: ignores camera pitch/roll so the keyboard stays upright and
	# doesn't tilt away from you if you happen to be looking up or down when
	# you click the thumbstick. Its local -Z is set to `forward` (the
	# direction you're facing) so local +Z — the quad's textured front face —
	# points back at the camera, the same convention wrist_tablet.gd's "quad
	# faces +Z" comment describes, just built with looking_at() instead of a
	# fixed mount rotation since this panel can appear anywhere.
	var distance := open_distance
	var drop := 0.1
	var tilt := 0.0
	if _mode == "full":
		# A full keyboard sits low and leans back like one on your lap, so it
		# doesn't cover the window (Browser, etc.) you're typing into, which
		# opens roughly at eye level in front of you.
		distance = 0.5
		drop = 0.42
		tilt = deg_to_rad(30.0)
	var target_position := _camera.global_position + forward * distance
	target_position.y = _camera.global_position.y - drop
	var basis := Basis.looking_at(forward, Vector3.UP)
	if tilt != 0.0:
		basis = basis * Basis(Vector3.RIGHT, -tilt) # rotates the panel's +Z (front) face up towards the sky
	global_transform = Transform3D(basis, target_position)


func _process(_delta: float) -> void:
	if not _open or _camera == null:
		return
	_update_pointer()


func _update_pointer() -> void:
	var was_hovering := _hovering
	_hovering = false
	var normal := global_transform.basis.z.normalized()
	var origin := _right.global_position
	var dir := -_right.global_transform.basis.z.normalized()
	var hit_distance := -1.0 ## see wrist_tablet.gd's own _update_pointer() for what controller.gd does with this
	var hit = Plane(normal, global_position).intersects_ray(origin, dir)
	if hit != null and origin.distance_to(hit) <= max_point_distance:
		var local: Vector3 = global_transform.affine_inverse() * hit
		if absf(local.x) <= panel_size.x * 0.5 and absf(local.y) <= panel_size.y * 0.5:
			_hovering = true
			hit_distance = origin.distance_to(hit)
			if not _pressed: # frozen while a click is held — see _send_click()'s own docstring (Godot's BaseButton cancels a press on any motion event outside its rect, regardless of the eventual release event's own position)
				_pointer_px = Vector2(
					(local.x / panel_size.x + 0.5) * viewport_size.x,
					(0.5 - local.y / panel_size.y) * viewport_size.y
				)

	_right.set_meta("ui_hover", _hovering)
	_right.set_meta("ui_hit_distance", hit_distance)
	_cursor.visible = _hovering
	if _hovering:
		_cursor.position = _pointer_px - _cursor.size * 0.5
		if not _pressed and _pointer_px != _last_sent_px:
			var motion := InputEventMouseMotion.new()
			motion.position = _pointer_px
			motion.global_position = _pointer_px
			motion.relative = _pointer_px - (_last_sent_px if was_hovering else _pointer_px)
			_viewport.push_input(motion)
			_last_sent_px = _pointer_px
	elif was_hovering and _pressed:
		_send_click(false) # laser slid off mid-press: let go so nothing stays stuck down


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _hovering:
		_press_px = _pointer_px
		_send_click(true)
		_right.trigger_haptic_pulse("haptic", 0.0, 0.4, 0.05, 0.0)


func _on_right_released(action_name: String) -> void:
	if action_name == click_action and _pressed:
		_send_click(false)


func _send_click(down: bool) -> void:
	## Uses _press_px (frozen at press time), not the live _pointer_px, for
	## both down and up — see wrist_tablet.gd's own _send_click() for the
	## full real-headset bug this fixes (hover worked, activating never did:
	## a real trigger squeeze takes real time, during which _pointer_px kept
	## tracking the laser, so the "up" event landed wherever the aim had
	## drifted to by release rather than where it was at press).
	_pressed = down
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = down
	click.position = _press_px
	click.global_position = _press_px
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	_viewport.push_input(click)


func _key_pressed(key: String) -> void:
	if _mode == "full":
		_full_key_pressed(key)
		return
	if key == "OK":
		close()
		if _on_confirm.is_valid():
			_on_confirm.call(_text)
		return
	if key == "Cancel":
		close()
		return
	if _pristine:
		# First keystroke after opening replaces the pre-filled value (the
		# current scale, say) rather than appending to it — typing "2.5" over
		# a pre-filled "1" should give "2.5", not "12.5".
		_text = ""
		_pristine = false
	match key:
		"<-":
			_text = _text.substr(0, max(0, _text.length() - 1))
		"-":
			# only meaningful as a leading sign; typing it again removes it
			_text = _text.substr(1) if _text.begins_with("-") else "-" + _text
		".":
			if not "." in _text:
				_text += "."
		_:
			_text += key
	_update_display()


func _full_key_pressed(key: String) -> void:
	var live := _live.is_valid()
	match key:
		"Cancel", "Done":
			close()
			return
		"OK":
			_confirm()
			return
		"Enter":
			if live:
				_live.call("key", "Enter")
			else:
				_confirm()
			return
		"Shift":
			_shift = not _shift
			_rebuild_keys()
			return
		"Caps":
			_caps = not _caps
			_shift = false
			_rebuild_keys()
			return
		"?123":
			_layer = "sym"
			_rebuild_keys()
			return
		"abc":
			_layer = "abc"
			_rebuild_keys()
			return
		"Tab":
			if live:
				_live.call("key", "Tab")
			return
		"<-":
			if live:
				_live.call("key", "Backspace")
				_typed = _typed.substr(0, maxi(0, _typed.length() - 1))
			elif _pristine:
				_text = "" # backspace on the untouched pre-filled text clears it all, like a URL bar with its text selected
				_pristine = false
			else:
				_text = _text.substr(0, maxi(0, _text.length() - 1))
			_update_display()
			return
		"Clear":
			if live:
				_typed = ""
			else:
				_text = ""
				_pristine = false
			_update_display()
			return
		"Space":
			_insert(" ")
		_:
			_insert(key)


func _insert(text: String) -> void:
	if _live.is_valid():
		_live.call("text", text)
		_typed += text
	else:
		if _pristine:
			_text = "" # typing over the pre-filled text replaces it
			_pristine = false
		_text += text
	if _shift:
		_shift = false # one-shot
		_rebuild_keys()
	_update_display()


func _confirm() -> void:
	close()
	if _on_confirm.is_valid():
		_on_confirm.call(_text)


func _update_display() -> void:
	if _display == null:
		return
	if _mode != "full":
		_display.text = _text if _text != "" else "0"
		return
	var shown := _typed if _live.is_valid() else _text
	var max_chars := 44
	if shown.length() > max_chars:
		shown = "…" + shown.substr(shown.length() - max_chars + 1) # keep the END visible: that's where you're typing
	_display.text = shown + "▏"
	if _hint:
		_hint.text = str(_options.get("title", ""))


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while open
	add_child(_viewport)
	_ui_root = _build_ui()
	_viewport.add_child(_ui_root)


func _build_quad() -> void:
	_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = panel_size
	_quad.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	add_child(_quad)


func _apply_layout() -> void:
	## Sizes and key set for the current mode. The full keyboard is a wide,
	## low panel at roughly the same pixels-per-metre as the keypad, so keys
	## are the same physical size; switching rebuilds the UI tree.
	if _mode == "full":
		panel_size = Vector2(0.60, 0.30)
		viewport_size = Vector2i(1200, 600)
	else:
		panel_size = Vector2(0.22, 0.26)
		viewport_size = Vector2i(420, 520)
	_viewport.size = viewport_size
	(_quad.mesh as QuadMesh).size = panel_size
	if _ui_root:
		_viewport.remove_child(_ui_root)
		_ui_root.queue_free()
	_ui_root = _build_ui()
	_viewport.add_child(_ui_root)


func _rebuild_keys() -> void:
	if _keys_box == null:
		return
	for child in _keys_box.get_children():
		_keys_box.remove_child(child)
		child.queue_free()
	if _mode == "full":
		_build_full_keys()
	else:
		_build_numeric_keys()


func _key_button(label: String, key: String, stretch: float = 1.0, toggled: bool = false, disabled: bool = false) -> Button:
	var button := Button.new()
	button.text = label
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.size_flags_stretch_ratio = stretch
	button.focus_mode = Control.FOCUS_NONE
	button.disabled = disabled
	if _mode == "full":
		button.custom_minimum_size = Vector2(0, 72)
	if toggled:
		button.toggle_mode = true
		button.set_pressed_no_signal(true)
	button.pressed.connect(_key_pressed.bind(key))
	return button


func _add_row(specs: Array) -> void:
	## specs: [[label, key, stretch?, toggled?, disabled?], ...]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_keys_box.add_child(row)
	for spec in specs:
		row.add_child(_key_button(spec[0], spec[1], spec[2] if spec.size() > 2 else 1.0, spec[3] if spec.size() > 3 else false, spec[4] if spec.size() > 4 else false))


func _chars(text: String, upper: bool = false) -> Array:
	var out := []
	for ch in text:
		var c: String = ch.to_upper() if upper else ch
		out.append([c, c])
	return out


func _build_numeric_keys() -> void:
	for row_keys in [
		["7", "8", "9"],
		["4", "5", "6"],
		["1", "2", "3"],
		[".", "0", "-"],
		["<-", "Cancel", "OK"],
	]:
		var specs := []
		for key in row_keys:
			specs.append([key, key])
		_add_row(specs)


func _build_full_keys() -> void:
	var live := _live.is_valid()
	var upper := _shift or _caps
	var confirm_label := str(_options.get("confirm_label", "OK"))
	if _layer == "sym":
		_add_row(_chars("1234567890") + [["<-", "<-", 1.6]])
		_add_row(_chars("@#$%^&*()") + [["Clear", "Clear", 1.4]])
		_add_row(_chars("-_=+[]{}\\|"))
		_add_row(_chars("!?;:'\"`~<>"))
		_add_row([["abc", "abc", 1.5], ["/", "/"], [".", "."], [",", ","], [".com", ".com", 1.4], ["Space", "Space", 3.0]] + ([["Done", "Done", 2.0]] if live else [["Cancel", "Cancel", 1.6], [confirm_label, "OK", 1.6]]))
		return
	_add_row(_chars("1234567890") + [["<-", "<-", 1.6]])
	_add_row(_chars("qwertyuiop", upper))
	_add_row([["Tab", "Tab", 1.3, false, not live]] + _chars("asdfghjkl", upper) + [["Enter" if live else confirm_label, "Enter", 1.6]])
	_add_row([["Shift", "Shift", 1.6, _shift], ["Caps", "Caps", 1.2, _caps]] + _chars("zxcvbnm", upper) + [["-", "-"], ["_", "_"]])
	_add_row([["?123", "?123", 1.5], ["/", "/"], [":", ":"], [".", "."], [".com", ".com", 1.4], ["Space", "Space", 3.0], ["Clear", "Clear", 1.3]] + ([["Done", "Done", 2.0]] if live else [["Cancel", "Cancel", 1.6], [confirm_label, "OK", 1.6]]))


func _build_ui() -> Control:
	var theme := Theme.new()
	theme.default_font_size = 30
	# Toggle keys (Shift/Caps) need a visible "on" state, same fix and colour as
	# the wrist tablet's and windows' themes (Godot's default reads too faintly
	# on an unshaded quad at arm's length).
	var pressed_style := StyleBoxFlat.new()
	pressed_style.bg_color = Color(0.15, 0.55, 0.68)
	pressed_style.set_corner_radius_all(4)
	pressed_style.set_content_margin_all(6)
	theme.set_stylebox("pressed", "Button", pressed_style)
	theme.set_stylebox("hover_pressed", "Button", pressed_style)

	var root := Control.new()
	root.theme = theme
	root.size = Vector2(viewport_size)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.1, 0.13)
	bg.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", bg)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)

	_hint = null
	if _mode == "full":
		_hint = Label.new()
		_hint.add_theme_font_size_override("font_size", 22)
		_hint.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
		column.add_child(_hint)

	_display = Label.new()
	_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if _mode == "full" else HORIZONTAL_ALIGNMENT_RIGHT
	_display.clip_text = true
	_display.add_theme_font_size_override("font_size", 40 if _mode == "full" else 44)
	column.add_child(_display)

	_keys_box = VBoxContainer.new()
	_keys_box.add_theme_constant_override("separation", 8)
	column.add_child(_keys_box)
	_rebuild_keys()
	_update_display()

	# A soft glow where the laser terminates, same as wrist_tablet.gd's own
	# cursor and for the same real-headset reason — see that one's docstring.
	_cursor = Control.new()
	_cursor.size = Vector2(28, 28)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor.visible = false
	_cursor.draw.connect(func() -> void:
		var centre: Vector2 = _cursor.size * 0.5
		for i in range(6, 0, -1):
			_cursor.draw_circle(centre, float(i) * 2.0, Color(1.0, 0.85, 0.1, 0.06))
		_cursor.draw_circle(centre, 5.0, Color(1.0, 0.95, 0.7, 0.9))
	)
	root.add_child(_cursor)

	return root
