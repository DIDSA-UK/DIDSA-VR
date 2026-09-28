extends "res://scripts/diegetic_panel.gd"
## Milestone 3's Image Viewer window: displays a local image file full-size
## on the panel. Sources from the same models/ / user://models folders and
## git-ignored-local-asset convention the wrist tablet's own Files tab
## already uses for .glb files - see main.gd's list_model_files().
## v1 is deliberately just "load and look at it" - no pan/zoom, matching
## the low ambition this window needs for a reference-image-during-review
## use case (see docs/status.md).

const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "bmp"]

var _status_label: Label
var _texture_rect: TextureRect
var _list_box: VBoxContainer


func setup_image_viewer(right: XRController3D, camera: XRCamera3D) -> void:
	panel_title = "Image Viewer"
	panel_size = Vector2(0.30, 0.24)
	viewport_size = Vector2i(560, 440)
	open_distance = 0.55
	open_lateral_offset = 0.22
	super.setup(right, camera)


func _on_opened() -> void:
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
		button.pressed.connect(_load_image.bind(path))
		_list_box.add_child(button)


func _load_image(path: String) -> void:
	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		_status_label.text = "Couldn't load %s (error %d)" % [path.get_file(), err]
		return
	_texture_rect.texture = ImageTexture.create_from_image(image)
	_status_label.text = path.get_file()


func _build_content() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.text = "Pick an image below."
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status_label)

	_texture_rect = TextureRect.new()
	_texture_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_texture_rect.custom_minimum_size = Vector2(0, 220)
	box.add_child(_texture_rect)

	var refresh := Button.new()
	refresh.text = "Refresh list"
	refresh.pressed.connect(_rebuild_list)
	box.add_child(refresh)

	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 4)
	box.add_child(_list_box)

	return box
