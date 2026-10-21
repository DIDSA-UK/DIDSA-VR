extends "res://scripts/diegetic_panel.gd"
## The landing's tips reel: one hint at a time (icon, title, a sentence), changing every Tips.CYCLE_SECONDS with a fade, with
## previous / pause / next. The list is scripts/landing/tips.gd; Settings > "Show tips" switches the reel off (landing.gd).
## The timer is driven by tick() so a test can run it without waiting.

const Tips := preload("res://scripts/landing/tips.gd")

var index := 0 ## into _tips
var paused := false
var _tips: Array[Dictionary] = []
var _connected := false
var _elapsed := 0.0
var _icon: TextureRect
var _title: Label
var _text: Label
var _counter: Label
var _pause_button: Button
var _fade: Tween


func setup_reel(left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	panel_title = "Tips"
	panel_size = Vector2(0.50, 0.30)
	viewport_size = Vector2i(800, 480)
	open_distance = 1.0
	open_lateral_offset = -0.85
	super.setup(left, right, camera)


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	box.add_child(head)
	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(56, 56)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_icon)
	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_title)
	_text = Label.new()
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_text)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	row.add_child(_nav_button("Previous", previous))
	_pause_button = _nav_button("Pause", toggle_pause)
	row.add_child(_pause_button)
	row.add_child(_nav_button("Next", next))
	_counter = Label.new()
	_counter.theme_type_variation = &"LabelDim"
	_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(_counter)
	return box


func _nav_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(120, 60)
	button.pressed.connect(callback)
	return button


func set_connected(connected: bool) -> void:
	## An offline build leaves out the tips about server features (Tips.for_connection()).
	_connected = connected
	var keep_id: String = str(_tips[index]["id"]) if index < _tips.size() else ""
	_tips = Tips.for_connection(connected)
	index = 0
	for i in _tips.size():
		if _tips[i]["id"] == keep_id:
			index = i
	_show_current(false)


func current() -> Dictionary:
	return _tips[index] if index < _tips.size() else {}


func tip_count() -> int:
	return _tips.size()


func next() -> void:
	_step(1)


func previous() -> void:
	_step(-1)


func toggle_pause() -> void:
	paused = not paused
	if _pause_button:
		_pause_button.text = "Play" if paused else "Pause"


func tick(delta: float) -> void:
	## Advances the clock by `delta` seconds; moves to the next tip every CYCLE_SECONDS unless paused.
	if paused or _tips.is_empty():
		return
	_elapsed += delta
	if _elapsed >= Tips.CYCLE_SECONDS:
		_step(1)


func _process(delta: float) -> void:
	super._process(delta)
	if is_open():
		tick(delta)


func _on_opened() -> void:
	if _tips.is_empty():
		set_connected(_connected)
	_show_current(false)


func _step(direction: int) -> void:
	if _tips.is_empty():
		return
	index = posmod(index + direction, _tips.size())
	_elapsed = 0.0
	_show_current(true)


func _show_current(animate: bool) -> void:
	if _title == null or _tips.is_empty():
		return
	var tip := _tips[index]
	_title.text = str(tip["title"])
	_text.text = str(tip["text"])
	_icon.texture = UiIcons.texture(str(tip["icon"]), 64)
	_counter.text = "%d / %d" % [index + 1, _tips.size()]
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_text.modulate.a = 1.0
	if animate and tokens.duration(0.35) > 0.0: # a short fade in, none under Reduce motion
		_text.modulate.a = 0.0
		_fade = create_tween()
		_fade.tween_property(_text, "modulate:a", 1.0, tokens.duration(0.35))
