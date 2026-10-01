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
##
## Phase 3 of the UI redesign (docs/wrist-tablet-redesign-plan.md): the laser
## handling is the shared scripts/ui/laser_surface.gd (every real-headset fix
## that used to be copied in here is in force there, unchanged); the look comes
## from the UI theme resource (ui/didsa_ui_theme.tres); and, like the floating
## windows, it has a GRAB HANDLE at the centre of its lower edge
## (scripts/ui/panel_handle.gd): grip it with either hand to carry the keyboard
## somewhere more comfortable, release to drop it. It reopens where you left it
## (one remembered spot per layout, numeric / full) until you walk more than
## moved_pose_reach from it, when it comes back in front of you.

@export var panel_size := Vector2(0.22, 0.26) ## metres
@export var viewport_size := Vector2i(420, 520) ## pixels the UI is laid out in
@export var open_distance: float = 0.6 ## metres in front of the camera when opened
@export var max_point_distance: float = 2.0 ## metres; laser reach for pressing keys
@export var click_action: String = "trigger_click"
@export var moved_pose_reach: float = 3.0 ## metres: a moved keyboard is only reopened in place while it's within this of you

const LaserSurface := preload("res://scripts/ui/laser_surface.gd")
const PanelHandle := preload("res://scripts/ui/panel_handle.gd")
const UiIcons := preload("res://scripts/ui/ui_icons.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"

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
var tokens: Resource ## ui/didsa_ui_theme.tres
var surface ## LaserSurface: hover, claim, frozen press
var handle ## PanelHandle: the grab pill at the lower edge
var _moved_poses := {} ## layout ("numeric" / "full") -> the Transform3D the user last dropped the keyboard at
var _hovering: bool:
	get: return surface != null and surface.hovering
var _pressed: bool:
	get: return surface != null and surface.pressed
var _pointer_px: Vector2:
	get: return surface.pointer_px if surface else Vector2.ZERO


func setup(right: XRController3D, camera: XRCamera3D, left: XRController3D = null) -> void:
	_right = right
	_camera = camera
	if left == null:
		left = right.get_parent().get_node_or_null("LeftController") as XRController3D # callers that predate the handle pass only the right hand
	tokens = load(THEME_PATH)
	_build_viewport()
	_build_quad()
	surface = LaserSurface.new()
	surface.setup(self, _viewport, _right, panel_size)
	surface.claim_first = false # a popup keyboard wins over a window it overlaps
	surface.max_point_distance = max_point_distance
	surface.click_action = click_action
	surface.cursor = _cursor
	handle = PanelHandle.new()
	handle.setup(self, left if left != null else right, right, func() -> bool: return _open, tokens)
	handle.build(panel_size)
	handle.dropped.connect(_on_handle_dropped)
	add_to_group("diegetic_panels") # controller.gd asks every panel via handle_in_reach() before running its own part-grab
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
	if surface:
		surface.release_all()
	if handle:
		handle.clear()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_right.set_meta("ui_hover", false)
	_right.set_meta("ui_hit_distance", -1.0) # the surface only runs while open, so this has to be reset explicitly here too — otherwise the laser could stay shortened to a stale distance after closing


func handle_in_reach(hand: Node3D) -> bool:
	## True if this open keyboard's drag handle is within the hand's grab reach —
	## controller.gd defers to it, so a grip at the handle never also grabs a part.
	return handle != null and handle.in_reach(hand)


func _on_handle_dropped(_hand: XRController3D) -> void:
	_moved_poses[_mode] = global_transform


func _place_in_front_of_camera() -> void:
	if _camera == null:
		return
	if _moved_poses.has(_mode):
		var kept: Transform3D = _moved_poses[_mode]
		if kept.origin.distance_to(_camera.global_position) <= moved_pose_reach:
			global_transform = kept # where you left it
			return
		_moved_poses.erase(_mode) # you've walked away from it: start fresh in front of you
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


func _process(delta: float) -> void:
	if not _open or _camera == null:
		return
	if handle.follow():
		surface.release_all() # being carried by its handle: not also hoverable/clickable (and no stale hover left to click a key with)
		return
	surface.panel_size = panel_size
	surface.process(delta, true)


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
	if surface:
		surface.panel_size = panel_size
	if handle:
		handle.layout(panel_size)
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
	else:
		button.custom_minimum_size = Vector2(0, 64)
	if toggled:
		button.toggle_mode = true
		button.set_pressed_no_signal(true)
	if key == "OK" or key == "Done" or (key == "Enter" and not _live.is_valid()):
		button.theme_type_variation = &"ButtonAccent" # the key that finishes the entry
	button.pressed.connect(_key_pressed.bind(key))
	return button


func _add_row(specs: Array) -> void:
	## specs: [[label, key, stretch?, toggled?, disabled?], ...]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", tokens.gap)
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
	var root := Control.new()
	root.theme = tokens.build_theme() # the same theme the tablet and windows use: panel chrome, keys, toggled-key highlight
	root.theme.default_font_size = 30 # keys have always been larger than the tablet's body text
	root.size = Vector2(viewport_size)

	var panel := PanelContainer.new() # the theme's panel chrome (rounded, outlined)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", tokens.gap + 2)
	panel.add_child(column)

	_hint = null
	if _mode == "full":
		_hint = Label.new()
		_hint.theme_type_variation = &"LabelDim"
		column.add_child(_hint)

	# The typed text sits in an inset field, like a text box.
	var field := PanelContainer.new()
	field.theme_type_variation = &"PanelRaised"
	column.add_child(field)
	_display = Label.new()
	_display.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if _mode == "full" else HORIZONTAL_ALIGNMENT_RIGHT
	_display.clip_text = true
	_display.add_theme_font_size_override("font_size", 40 if _mode == "full" else 44)
	field.add_child(_display)

	_keys_box = VBoxContainer.new()
	_keys_box.add_theme_constant_override("separation", tokens.gap)
	column.add_child(_keys_box)
	_rebuild_keys()
	_update_display()

	# A soft glow where the laser terminates (see laser_surface.gd's make_cursor()).
	_cursor = LaserSurface.make_cursor()
	root.add_child(_cursor)
	if surface:
		surface.cursor = _cursor # a layout switch rebuilds this tree and so the cursor

	return root
