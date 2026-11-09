extends "res://scripts/diegetic_panel.gd"
## Two large laser buttons floating in an EMPTY space (T2, docs/test-report-30-oct-plan.md): in an empty Assembly Room "New assembly" and "Open assembly...",
## above an empty design table "New part" and "Open part...". Assembly files and part files are the same native files, so only the words differ; the callbacks
## are what the two spaces do. It is a window (it has the usual handle, so it can be moved out of the way) that shows only while `empty` and hides the
## moment the space holds anything. "Open..." swaps the buttons for a file list (folder_chooser.gd in files mode: the T1 folder list, native files only).
##
## One scene for both places: the owner builds it with setup_start() and says where it floats through `anchor` (a Callable returning a Transform3D in world space).

const FolderChooser := preload("res://scripts/ui/folder_chooser.gd")
const BUTTON_SIZE := Vector2(0.30, 0.12) ## metres: each of the two big buttons (the laser targets)
const PANEL_SIZE := Vector2(0.70, 0.40) ## metres: the buttons, their help line, and the file list when "Open..." is pressed
const NATIVE_EXTENSIONS := ["didsa", "didsaprt", "didsacad"]

var main: Node
var new_text := "New"
var open_text := "Open..."
var help_text := ""
var on_new: Callable
var on_open_file: Callable ## (path: String) -> void
var anchor: Callable ## () -> Transform3D, world space
var empty := false: ## set by the owner: shown only while true
	set(value):
		empty = value
		_sync()
var _holder: VBoxContainer
var _choosing := false


func setup_start(p_main: Node, left: XRController3D, right: XRController3D, camera: XRCamera3D, texts: Dictionary, p_on_new: Callable, p_on_open_file: Callable, p_anchor: Callable) -> void:
	main = p_main
	new_text = str(texts.get("new", "New"))
	open_text = str(texts.get("open", "Open..."))
	help_text = str(texts.get("help", ""))
	panel_title = str(texts.get("title", "Start"))
	on_new = p_on_new
	on_open_file = p_on_open_file
	anchor = p_anchor
	panel_size = PANEL_SIZE
	viewport_size = Vector2i(1000, 571)
	max_point_distance = 3.0
	super.setup(left, right, camera)
	set_title(panel_title)


func _place_in_front_of_camera() -> void:
	if anchor.is_valid():
		global_transform = anchor.call()
	else:
		super._place_in_front_of_camera()


func _build_content() -> Control:
	_holder = VBoxContainer.new()
	_holder.add_theme_constant_override("separation", 12)
	_show_buttons()
	return _holder


func _clear() -> void:
	for child in _holder.get_children():
		_holder.remove_child(child)
		child.queue_free()


func _show_buttons() -> void:
	if _holder == null:
		return
	_choosing = false
	_clear()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_holder.add_child(row)
	var px := _pixels_per_metre # the buttons are BUTTON_SIZE in metres on the panel
	var size_px := Vector2(BUTTON_SIZE.x * px, BUTTON_SIZE.y * px)
	var new_button := Button.new()
	new_button.name = "StartNew"
	new_button.text = new_text
	new_button.theme_type_variation = &"ButtonAccent"
	new_button.custom_minimum_size = size_px
	new_button.add_theme_font_size_override("font_size", 40)
	new_button.pressed.connect(_pressed_new)
	row.add_child(new_button)
	var open_button := Button.new()
	open_button.name = "StartOpen"
	open_button.text = open_text
	open_button.custom_minimum_size = size_px
	open_button.add_theme_font_size_override("font_size", 40)
	open_button.pressed.connect(show_chooser)
	row.add_child(open_button)
	var help := Label.new()
	help.name = "StartHelp"
	help.text = help_text
	help.theme_type_variation = &"LabelDim"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_holder.add_child(help)


func _pressed_new() -> void:
	if on_new.is_valid():
		on_new.call()


func show_chooser() -> void:
	## "Open...": the folder list, files only, native files. Picking one calls on_open_file(path) and puts the buttons back.
	if _holder == null:
		return
	_choosing = true
	_clear()
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_holder.add_child(scroll)
	scroll_target = scroll
	var chooser := FolderChooser.new()
	chooser.name = "Chooser"
	chooser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(chooser)
	var start: String = main.save_dir() if main != null and main.has_method("save_dir") else ""
	chooser.setup(main, start, true, NATIVE_EXTENSIONS)
	chooser.file_chosen.connect(func(path: String) -> void:
		_leave_chooser()
		if on_open_file.is_valid():
			on_open_file.call(path))
	chooser.cancelled.connect(_leave_chooser)
	if not _open:
		_sync_force_open()


func _leave_chooser() -> void:
	_show_buttons()
	if not empty:
		close() # the list was asked for on a space that already has parts (the room console's row)


func _sync_force_open() -> void:
	## Opened on its own (the room console's "Open assembly..." row on a room that has parts): shows the list even though the space is not empty.
	if _viewport != null:
		open()


func is_choosing() -> bool:
	return _choosing


func _sync() -> void:
	if _viewport == null: # not set up yet (a stand-in in a test)
		return
	if empty and not _open:
		_show_buttons()
		open()
	elif not empty and _open and not _choosing:
		close()
