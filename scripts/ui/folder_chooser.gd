extends VBoxContainer
## A laser list of folders (T1): up, into a folder, New folder, Use this folder, and "Type a path..." as the secondary route (network mounts).
## One control, used by the landing's first-run page and by Settings > Project folder. It lists with DirAccess, so on the Quest it shows only what
## the app is allowed to see; every pick goes through ProjectFolder.probe(), and a folder that can't be written is refused with the reason.

const ProjectFolder := preload("res://scripts/project_folder.gd")

signal chosen(path: String) ## "Use this folder" and the folder passed probe()
signal cancelled
signal file_chosen(path: String) ## files mode: a model file was picked

var files_mode := false ## pick a FILE (T2's Open assembly... / Open part...) instead of a folder: no "Use this folder"; the files of `extensions` are listed under the folders
var extensions: Array = [] ## files mode: the extensions listed (lower case, no dot); empty = every model file

var main: Node ## main.gd: the keyboard for New folder / Type a path, and use_project_folder()
var current := "" ## the folder being looked at
var _message: Label
var _list: VBoxContainer


func setup(p_main: Node, start: String, p_files_mode := false, p_extensions: Array = []) -> void:
	main = p_main
	files_mode = p_files_mode
	extensions = p_extensions
	add_theme_constant_override("separation", 8)
	current = ProjectFolder.start_dir(start)
	refresh()


func refresh() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var here := Label.new()
	here.name = "Here"
	here.text = ProjectFolder.full_path(current)
	here.theme_type_variation = &"LabelTitle"
	here.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	add_child(here)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	add_child(top)
	var up := _button("Up", _go_up, 120)
	up.name = "Up"
	up.disabled = ProjectFolder.parent_of(current).is_empty()
	top.add_child(up)
	var new_folder := _button("New folder...", _new_folder, 0)
	new_folder.name = "NewFolder"
	top.add_child(new_folder)
	if not files_mode:
		var use := _button("Use this folder", _use_current, 0)
		use.name = "UseThis"
		top.add_child(use)
	_message = Label.new()
	_message.name = "Message"
	_message.theme_type_variation = &"LabelSmall"
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_message)
	_list = VBoxContainer.new()
	_list.name = "List"
	_list.add_theme_constant_override("separation", 6)
	add_child(_list)
	var names := ProjectFolder.subfolders(current)
	if names.is_empty():
		var none := Label.new()
		none.text = "No folders in here. Use this folder, or make a New folder."
		none.theme_type_variation = &"LabelDim"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(none)
	for i in mini(names.size(), ProjectFolder.LISTED_MAX):
		var row := _button("%s   (%d model file(s))" % [names[i], ProjectFolder.model_files(current.path_join(names[i])).size()], _enter.bind(names[i]), 0)
		row.name = "Folder_" + str(names[i]).validate_node_name()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_list.add_child(row)
	if files_mode:
		var listed := ProjectFolder.model_files(current)
		var shown := 0
		for file_name in listed:
			if not extensions.is_empty() and str(file_name).get_extension().to_lower() not in extensions:
				continue
			var file_button := _button(str(file_name), func() -> void: file_chosen.emit(current.path_join(file_name)), 0)
			file_button.name = "File_" + str(file_name).validate_node_name()
			file_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			_list.add_child(file_button)
			shown += 1
		if shown == 0:
			var no_files := Label.new()
			no_files.name = "NoFiles"
			no_files.text = "No files of the right kind in this folder."
			no_files.theme_type_variation = &"LabelDim"
			_list.add_child(no_files)
	if names.size() > ProjectFolder.LISTED_MAX:
		var more := Label.new()
		more.text = "%d more not shown: type the path instead." % (names.size() - ProjectFolder.LISTED_MAX)
		more.theme_type_variation = &"LabelDim"
		_list.add_child(more)
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	add_child(bottom)
	var typed := _button("Type a path...", _type_path, 0)
	typed.name = "TypePath"
	if not files_mode:
		bottom.add_child(typed)
	else:
		typed.free()
	var cancel := _button("Cancel", func() -> void: cancelled.emit(), 0)
	cancel.name = "Cancel"
	bottom.add_child(cancel)


func _button(text: String, callback: Callable, min_width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(min_width, 56)
	if min_width == 0.0:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	return button


func _go_up() -> void:
	var parent := ProjectFolder.parent_of(current)
	if not parent.is_empty():
		current = parent
		refresh()


func _enter(name: String) -> void:
	current = current.path_join(name)
	refresh()


func _say(text: String) -> void:
	if _message != null:
		_message.text = text


func _new_folder() -> void:
	if main == null:
		return
	main.open_keyboard_for("", func(text: String) -> void:
		var made := ProjectFolder.make_subfolder(current, text)
		if not made["ok"]:
			_say(made["error"])
			return
		current = made["path"]
		refresh()
		_say("Made %s." % made["path"].get_file()), {"mode": "full", "title": "New folder in %s" % current.get_file(), "confirm_label": "Make"})


func _type_path() -> void:
	if main == null:
		return
	main.open_keyboard_for(current, func(text: String) -> void:
		var path := text.strip_edges()
		if path.is_empty():
			return
		current = path
		_use_current(), {"mode": "full", "title": "Folder (absolute path)", "confirm_label": "Use"})


func _use_current() -> void:
	## The pick: probe it; refuse with the reason, or report it chosen.
	var result: Dictionary = main.use_project_folder(current) if main != null else ProjectFolder.probe(current)
	if main != null and not result.get("ok", false):
		_say("Can't use this folder: %s" % result["error"])
		return
	if main == null and not (result["exists"] and result["writable"]):
		_say("Can't use this folder: %s" % result["error"])
		return
	chosen.emit(current)
