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
var reduce_motion: bool = false
var sound_enabled: bool = true
var sound_volume: float = 0.7
var haptics_level: int = 2 ## index into ui_feedback.gd's HAPTIC_LEVELS (Off / Low / Normal / High)


func load_from_disk() -> void:
	var config := ConfigFile.new()
	if config.load(PATH) != OK:
		return # no settings saved yet, or unreadable — defaults stand
	project_folder = config.get_value("files", "project_folder", project_folder)
	last_scene = config.get_value("environment", "last_scene", last_scene)
	reduce_motion = bool(config.get_value("comfort", "reduce_motion", reduce_motion))
	haptics_level = int(config.get_value("comfort", "haptics_level", haptics_level))
	sound_enabled = bool(config.get_value("comfort", "sound_enabled", sound_enabled))
	sound_volume = clampf(float(config.get_value("comfort", "sound_volume", sound_volume)), 0.0, 1.0)


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("files", "project_folder", project_folder)
	config.set_value("environment", "last_scene", last_scene)
	config.set_value("comfort", "reduce_motion", reduce_motion)
	config.set_value("comfort", "haptics_level", haptics_level)
	config.set_value("comfort", "sound_enabled", sound_enabled)
	config.set_value("comfort", "sound_volume", sound_volume)
	var err := config.save(PATH)
	if err != OK:
		push_warning("DIDSA VR: couldn't save %s (error %d)" % [PATH, err])


func set_project_folder(path: String) -> void:
	project_folder = path
	save_to_disk()


func set_reduce_motion(on: bool) -> void:
	reduce_motion = on
	save_to_disk()


func set_sound_enabled(on: bool) -> void:
	sound_enabled = on
	save_to_disk()


func set_sound_volume(v: float) -> void:
	sound_volume = clampf(v, 0.0, 1.0)
	save_to_disk()


func set_haptics_level(level: int) -> void:
	haptics_level = level
	save_to_disk()


func set_last_scene(scene_name: String) -> void:
	last_scene = scene_name
	save_to_disk()
