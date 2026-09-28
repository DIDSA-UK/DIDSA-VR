extends RefCounted
## Small persisted "set and forget" settings for the wrist tablet's Settings
## page: the project folder the Files tab scans in addition to res://models
## and user://models, and the last-picked Environment scene. Loaded once at
## startup (main.gd's _ready()) and saved back on each change — same
## ConfigFile technique main.gd's own _load_secrets() already uses for
## secrets.cfg, just a separate writable file: secrets.cfg is a checked-in-
## adjacent, untracked credentials file meant to be hand-edited once per
## machine, where this is genuinely mutable app state written at runtime, so
## it lives under user:// where an exported build can actually write to it.

const PATH := "user://settings.cfg"

var project_folder: String = ""
var last_scene: String = "Mid"


func load_from_disk() -> void:
	var config := ConfigFile.new()
	if config.load(PATH) != OK:
		return # no settings saved yet, or unreadable — defaults stand
	project_folder = config.get_value("files", "project_folder", project_folder)
	last_scene = config.get_value("environment", "last_scene", last_scene)


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("files", "project_folder", project_folder)
	config.set_value("environment", "last_scene", last_scene)
	var err := config.save(PATH)
	if err != OK:
		push_warning("DIDSA VR: couldn't save %s (error %d)" % [PATH, err])


func set_project_folder(path: String) -> void:
	project_folder = path
	save_to_disk()


func set_last_scene(scene_name: String) -> void:
	last_scene = scene_name
	save_to_disk()
