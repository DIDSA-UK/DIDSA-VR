extends "res://scripts/diegetic_panel.gd"
## Milestone 3's Image Viewer window: pick a local image from a list and it
## FILLS the window; a Back button in the header returns to the list.
## Sources from the same models/ / user://models folders and git-ignored-local-
## asset convention the wrist tablet's own Files tab already uses for .glb
## files - see main.gd's list_model_files().
##
## Two views in one window (real-headset feedback, 29 Sep 2026): the picker
## (a scrollable list — the right thumbstick scrolls it while the laser is on
## the window, see diegetic_panel.gd — so a long list is reachable) and the
## image view (the picture scaled to fill the content area, aspect kept, the
## file name in the title). No pan/zoom: resize the window instead (drag a
## corner) — the picture refits.
##
## Several image windows can be open at once (main.gd's open_window()/
## spawn_window()); each keeps its own picture.

const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp"]

var _status_label: Label
var _texture_rect: TextureRect
var _list_box: VBoxContainer
var _picker_view: Control
var _image_view: Control
var _back_button: Button
var _showing_image := false


func setup_image_viewer(left: XRController3D, right: XRController3D, camera: XRCamera3D) -> void:
	panel_title = "Image Viewer"
	panel_size = Vector2(0.30, 0.24)
	viewport_size = Vector2i(560, 440)
	open_distance = 0.55
	open_lateral_offset = 0.22
	super.setup(left, right, camera)


func _on_opened() -> void:
	# (Re)opening always starts at the picker, with a fresh list.
	show_picker()
	_rebuild_list()


func list_image_files() -> PackedStringArray:
	## Mirrors main.gd's own list_model_files() shape/folders exactly, just
	## filtered to image extensions - kept here rather than added to that
	## shared function since it's a different file-type concern (images
	## aren't "models"), not because the search folders differ at all.
	var found := PackedStringArray()
	for dir_path in ["res://models", "user://models"]:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file_name in dir.get_files():
			if file_name.get_extension().to_lower() in IMAGE_EXTENSIONS:
				found.append(dir_path.path_join(file_name))
	return found


func _rebuild_list() -> void:
	if _list_box == null:
		return
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	var files := list_image_files()
	if files.is_empty():
		var none := Label.new()
		none.text = "No images found.\nPut a .png/.jpg/.webp/.bmp in the project's models folder."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list_box.add_child(none)
		return
	for path in files:
		var button := Button.new()
		button.text = path.get_file()
		button.clip_text = true
		button.custom_minimum_size = Vector2(0, 56)
		button.pressed.connect(_load_image.bind(path))
		_list_box.add_child(button)


func _load_image(path: String) -> void:
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		_status_label.text = "Couldn't load %s (error %d)" % [path.get_file(), err]
		return
	_texture_rect.texture = ImageTexture.create_from_image(image)
	_show_image(path.get_file())


func _show_image(file_name: String) -> void:
	_showing_image = true
	_picker_view.visible = false
	_image_view.visible = true
	_back_button.visible = true
	set_title(file_name)
	scroll_target = null # nothing to scroll on the image view


func show_picker() -> void:
	## Back: return to the list (the picture stays loaded but hidden).
	_showing_image = false
	_picker_view.visible = true
	_image_view.visible = false
	_back_button.visible = false
	set_title(panel_title)
	scroll_target = _picker_scroll


var _picker_scroll: ScrollContainer


func is_showing_image() -> bool:
	return _showing_image


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	# Header Back button: only visible while a picture is up.
	_back_button = add_header_button("< Back", show_picker, true)
	_back_button.visible = false

	# --- picker view
	var picker := VBoxContainer.new()
	picker.add_theme_constant_override("separation", 8)
	picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(picker)
	_picker_view = picker

	_status_label = Label.new()
	_status_label.text = "Pick an image."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	picker.add_child(_status_label)

	var refresh := Button.new()
	refresh.text = "Refresh list"
	refresh.pressed.connect(_rebuild_list)
	picker.add_child(refresh)

	_picker_scroll = ScrollContainer.new()
	_picker_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_picker_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	picker.add_child(_picker_scroll)
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 4)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_picker_scroll.add_child(_list_box)
	scroll_target = _picker_scroll

	# --- image view: the picture fills the whole content area, aspect kept
	var image_view := VBoxContainer.new()
	image_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	image_view.visible = false
	box.add_child(image_view)
	_image_view = image_view
	_texture_rect = TextureRect.new()
	_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	image_view.add_child(_texture_rect)

	return box
