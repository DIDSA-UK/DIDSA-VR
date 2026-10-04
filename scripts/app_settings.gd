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
const PATH_ENV := "DIDSA_SETTINGS_PATH" ## set this environment variable to read and write a different file (tests/run_all.sh does, so a test run never touches the real settings)


static func path() -> String:
	var override := OS.get_environment(PATH_ENV)
	return override if override != "" else PATH

var project_folder: String = ""
var last_scene: String = "Mid"
var reduce_motion: bool = false
var ui_theme: String = "Navy" ## one of ui_themes.gd's ORDER
var fx_enabled: bool = true ## shader effects (the glass overlay, button glow)
var sound_enabled: bool = true
var sound_volume: float = 0.7
var view_render_mode: int = 0 ## 0 shaded, 1 shaded + edges, 2 wireframe (view_modes.gd): like the flat app's view_render_mode
var table_keep_turn: bool = false ## a part sent back to the arena keeps the turn it has on the design table (false: its original orientation)
var table_max_scale: float = 3.0 ## the biggest the part may be scaled to on the table (8x while a sketch is open regardless)
var table_slab_size: Vector2 = Vector2.ZERO ## the design table's slab as the user last dragged it (zero = never changed)
var haptics_level: int = 2 ## index into ui_feedback.gd's HAPTIC_LEVELS (Off / Low / Normal / High)


func load_from_disk() -> void:
	var config := ConfigFile.new()
	if config.load(path()) != OK:
		return # no settings saved yet, or unreadable — defaults stand
	project_folder = config.get_value("files", "project_folder", project_folder)
	last_scene = config.get_value("environment", "last_scene", last_scene)
	reduce_motion = bool(config.get_value("comfort", "reduce_motion", reduce_motion))
	haptics_level = int(config.get_value("comfort", "haptics_level", haptics_level))
	ui_theme = str(config.get_value("appearance", "theme", ui_theme))
	view_render_mode = clampi(int(config.get_value("appearance", "view_render_mode", view_render_mode)), 0, 2)
	fx_enabled = bool(config.get_value("appearance", "effects", fx_enabled))
	table_keep_turn = bool(config.get_value("table", "keep_turn", table_keep_turn))
	table_max_scale = clampf(float(config.get_value("table", "max_scale", table_max_scale)), 1.5, 8.0)
	table_slab_size = Vector2(float(config.get_value("table", "slab_w", 0.0)), float(config.get_value("table", "slab_d", 0.0)))
	sound_enabled = bool(config.get_value("comfort", "sound_enabled", sound_enabled))
	sound_volume = clampf(float(config.get_value("comfort", "sound_volume", sound_volume)), 0.0, 1.0)


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("files", "project_folder", project_folder)
	config.set_value("environment", "last_scene", last_scene)
	config.set_value("comfort", "reduce_motion", reduce_motion)
	config.set_value("comfort", "haptics_level", haptics_level)
	config.set_value("appearance", "theme", ui_theme)
	config.set_value("appearance", "view_render_mode", view_render_mode)
	config.set_value("appearance", "effects", fx_enabled)
	config.set_value("table", "keep_turn", table_keep_turn)
	config.set_value("table", "max_scale", table_max_scale)
	config.set_value("table", "slab_w", table_slab_size.x)
	config.set_value("table", "slab_d", table_slab_size.y)
	config.set_value("comfort", "sound_enabled", sound_enabled)
	config.set_value("comfort", "sound_volume", sound_volume)
	var err := config.save(path())
	if err != OK:
		push_warning("DIDSA VR: couldn't save %s (error %d)" % [path(), err])


func set_project_folder(path: String) -> void:
	project_folder = path
	save_to_disk()


func set_reduce_motion(on: bool) -> void:
	reduce_motion = on
	save_to_disk()


func set_view_render_mode(mode: int) -> void:
	view_render_mode = clampi(mode, 0, 2)
	save_to_disk()


func set_table_keep_turn(on: bool) -> void:
	table_keep_turn = on
	save_to_disk()


func set_table_max_scale(value: float) -> void:
	table_max_scale = clampf(value, 1.5, 8.0)
	save_to_disk()


func set_table_slab_size(size: Vector2) -> void:
	table_slab_size = size
	save_to_disk()


func set_ui_theme(theme_name: String) -> void:
	ui_theme = theme_name
	save_to_disk()


func set_fx_enabled(on: bool) -> void:
	fx_enabled = on
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
