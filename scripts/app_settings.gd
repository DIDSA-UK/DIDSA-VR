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
var folder_asked: bool = false ## the first-run "where should projects be saved" question has been answered (an empty project_folder alone never means "not asked": it can be the app's own storage, chosen)
var cloud_cache_mb: int = 2048 ## S4: how much disk the local copies of server projects may take across all projects (0 = no limit); clean-up removes only files that are synced, closed and not waiting to send, least recently used first
var cloud_folder: String = "" ## where the local copies of server projects live ("" = Documents/DIDSA-Cloud; scripts/cloud/cloud_paths.gd): ONE setting, so it can move
var device_name: String = "" ## what this headset calls itself to the project store ("" = the platform's name): shown to other devices as "who changed it", never identity
var last_session_hub: String = "" ## P2: the hub address a join last used (a join code that carries none, or a typed code, starts from it)
var last_scene: String = "Mid"
var reduce_motion: bool = false
var ui_theme: String = "Navy" ## one of ui_themes.gd's ORDER
var fx_enabled: bool = true ## shader effects (the glass overlay, button glow)
var sound_enabled: bool = true
var sound_volume: float = 0.7
var view_render_mode: int = 0 ## 0 shaded, 1 shaded + edges, 2 wireframe (view_modes.gd): like the flat app's view_render_mode
var table_keep_turn: bool = false ## a part sent back to the arena keeps the turn it has on the design table (false: its original orientation)
var table_sheet_front: bool = true ## the sketch sheet hinged at the slab's front edge, tilted back (false: floating at the slab's middle at 60 degrees, as before T4)
var table_sheet_lean: int = 15 ## degrees the front-hinged sheet leans back from vertical: 10, 15 or 25
var table_max_scale: float = 3.0 ## the biggest the part may be scaled to on the table (8x while a sketch is open regardless)
var table_slab_size: Vector2 = Vector2.ZERO ## the design table's slab as the user last dragged it (zero = never changed)
var wheel_enabled: bool = true ## the tool wheel (right trigger + grip)
var wheel_size: int = 1 ## index into tool_wheel.gd's SIZE_SCALES (Small / Normal / Large)
var haptics_level: int = 2 ## index into ui_feedback.gd's HAPTIC_LEVELS (Off / Low / Normal / High)
var max_rooms: int = 4 ## the most Assembly Rooms open at once (room_registry.gd; 1..16)
var room_pedestal: bool = true ## the faint column from a room's console down to the floor
var world_preview_auto: bool = true ## a room's world preview follows its parts as they move (off: it shows the last Push)
var world_preview_pulse: bool = false ## the world preview breathes (aesthetic)
var group_deadzone: int = 1 ## the dead zone when you grip a part inside a sub-assembly (controller.gd group_deadzone): 0 Off, 1 Small (2 cm), 2 Medium (4 cm)
var sandbox_ghosts: bool = false ## Relax all mates: a see-through copy of each moved part where it goes back to (mates_tool.gd)
var sandbox_lines: bool = false ## Relax all mates: a thin line from each moved part to where it goes back to
var room_glass: bool = true ## Assembly Room walls drawn as see-through glass with a grid near your hands (off: thin wireframe only)
var tree_group_repeats: bool = true ## the Assembly Tree folds 4 or more identical siblings into one "Bolt M4 x4" row (docs/assembly-tree spec section 4; the header switch of assembly_tree_window.gd)
var show_landing: bool = true ## the landing (logo, rocket garden, launcher) on every start; off: the old start-up import
var show_tips: bool = true ## the landing's tips reel
var paint_recent: Array = [] ## the Appearance tool's recent colours ("#RRGGBB", newest first, appearance_tool.gd RECENT_MAX)
var paint_saved: Array = [] ## the Appearance tool's own saved appearances: [{name, appearance}] (the presets are built in, appearance_tool.gd)


func load_from_disk() -> void:
	var config := ConfigFile.new()
	if config.load(path()) != OK:
		return # no settings saved yet, or unreadable — defaults stand
	project_folder = config.get_value("files", "project_folder", project_folder)
	folder_asked = bool(config.get_value("files", "folder_asked", folder_asked or not project_folder.is_empty())) # an older settings file that already has a folder counts as asked
	cloud_folder = str(config.get_value("cloud", "folder", cloud_folder))
	cloud_cache_mb = maxi(0, int(config.get_value("cloud", "cache_mb", cloud_cache_mb)))
	device_name = str(config.get_value("cloud", "device_name", device_name))
	last_session_hub = str(config.get_value("session", "last_hub", last_session_hub))
	last_scene = config.get_value("environment", "last_scene", last_scene)
	reduce_motion = bool(config.get_value("comfort", "reduce_motion", reduce_motion))
	haptics_level = int(config.get_value("comfort", "haptics_level", haptics_level))
	wheel_enabled = bool(config.get_value("comfort", "wheel_enabled", wheel_enabled))
	max_rooms = clampi(int(config.get_value("rooms", "max_rooms", max_rooms)), 1, 16)
	room_glass = bool(config.get_value("rooms", "glass", room_glass))
	tree_group_repeats = bool(config.get_value("tree", "group_repeats", tree_group_repeats))
	world_preview_auto = bool(config.get_value("rooms", "preview_auto", world_preview_auto))
	world_preview_pulse = bool(config.get_value("rooms", "preview_pulse", world_preview_pulse))
	group_deadzone = clampi(int(config.get_value("rooms", "group_deadzone", group_deadzone)), 0, 2)
	room_pedestal = bool(config.get_value("rooms", "pedestal", room_pedestal))
	sandbox_ghosts = bool(config.get_value("mates", "sandbox_ghosts", sandbox_ghosts))
	sandbox_lines = bool(config.get_value("mates", "sandbox_lines", sandbox_lines))
	wheel_size = clampi(int(config.get_value("comfort", "wheel_size", wheel_size)), 0, 2)
	ui_theme = str(config.get_value("appearance", "theme", ui_theme))
	view_render_mode = clampi(int(config.get_value("appearance", "view_render_mode", view_render_mode)), 0, 2)
	fx_enabled = bool(config.get_value("appearance", "effects", fx_enabled))
	table_keep_turn = bool(config.get_value("table", "keep_turn", table_keep_turn))
	table_max_scale = clampf(float(config.get_value("table", "max_scale", table_max_scale)), 1.5, 8.0)
	table_sheet_front = bool(config.get_value("table", "sheet_front", table_sheet_front))
	table_sheet_lean = clampi(int(config.get_value("table", "sheet_lean", table_sheet_lean)), 5, 45)
	table_slab_size = Vector2(float(config.get_value("table", "slab_w", 0.0)), float(config.get_value("table", "slab_d", 0.0)))
	sound_enabled = bool(config.get_value("comfort", "sound_enabled", sound_enabled))
	sound_volume = clampf(float(config.get_value("comfort", "sound_volume", sound_volume)), 0.0, 1.0)
	show_landing = bool(config.get_value("landing", "show_landing", show_landing))
	show_tips = bool(config.get_value("landing", "show_tips", show_tips))
	var recent = config.get_value("paint", "recent", paint_recent)
	paint_recent = recent if recent is Array else []
	var saved = config.get_value("paint", "saved", paint_saved)
	paint_saved = saved if saved is Array else []


func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value("files", "project_folder", project_folder)
	config.set_value("files", "folder_asked", folder_asked)
	config.set_value("cloud", "folder", cloud_folder)
	config.set_value("cloud", "cache_mb", cloud_cache_mb)
	config.set_value("cloud", "device_name", device_name)
	config.set_value("session", "last_hub", last_session_hub)
	config.set_value("environment", "last_scene", last_scene)
	config.set_value("comfort", "reduce_motion", reduce_motion)
	config.set_value("comfort", "haptics_level", haptics_level)
	config.set_value("comfort", "wheel_enabled", wheel_enabled)
	config.set_value("rooms", "max_rooms", max_rooms)
	config.set_value("rooms", "glass", room_glass)
	config.set_value("tree", "group_repeats", tree_group_repeats)
	config.set_value("rooms", "group_deadzone", group_deadzone)
	config.set_value("rooms", "preview_auto", world_preview_auto)
	config.set_value("rooms", "preview_pulse", world_preview_pulse)
	config.set_value("rooms", "pedestal", room_pedestal)
	config.set_value("mates", "sandbox_ghosts", sandbox_ghosts)
	config.set_value("mates", "sandbox_lines", sandbox_lines)
	config.set_value("comfort", "wheel_size", wheel_size)
	config.set_value("appearance", "theme", ui_theme)
	config.set_value("appearance", "view_render_mode", view_render_mode)
	config.set_value("appearance", "effects", fx_enabled)
	config.set_value("table", "keep_turn", table_keep_turn)
	config.set_value("table", "max_scale", table_max_scale)
	config.set_value("table", "sheet_front", table_sheet_front)
	config.set_value("table", "sheet_lean", table_sheet_lean)
	config.set_value("table", "slab_w", table_slab_size.x)
	config.set_value("table", "slab_d", table_slab_size.y)
	config.set_value("comfort", "sound_enabled", sound_enabled)
	config.set_value("comfort", "sound_volume", sound_volume)
	config.set_value("landing", "show_landing", show_landing)
	config.set_value("landing", "show_tips", show_tips)
	config.set_value("paint", "recent", paint_recent)
	config.set_value("paint", "saved", paint_saved)
	var err := config.save(path())
	if err != OK:
		push_warning("DIDSA VR: couldn't save %s (error %d)" % [path(), err])


func set_cloud_cache_mb(value: int) -> void:
	cloud_cache_mb = maxi(0, value)
	save_to_disk()


func set_cloud_folder(path: String) -> void:
	cloud_folder = path.strip_edges()
	save_to_disk()


func set_last_session_hub(value: String) -> void:
	last_session_hub = value.strip_edges().substr(0, 256)
	save_to_disk()


func set_device_name(value: String) -> void:
	device_name = value.strip_edges().substr(0, 40)
	save_to_disk()


func set_project_folder(path: String) -> void:
	project_folder = path
	folder_asked = true # choosing, clearing or typing a folder all answer the question
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


func set_table_sheet(front: bool, lean: int) -> void:
	table_sheet_front = front
	table_sheet_lean = clampi(lean, 5, 45)
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


func set_wheel_enabled(on: bool) -> void:
	wheel_enabled = on
	save_to_disk()


func set_wheel_size(index: int) -> void:
	wheel_size = clampi(index, 0, 2)
	save_to_disk()


func set_room_pedestal(on: bool) -> void:
	room_pedestal = on
	save_to_disk()


func set_sandbox_ghosts(on: bool) -> void:
	sandbox_ghosts = on
	save_to_disk()


func set_sandbox_lines(on: bool) -> void:
	sandbox_lines = on
	save_to_disk()


func set_room_glass(on: bool) -> void:
	room_glass = on
	save_to_disk()


func set_tree_group_repeats(on: bool) -> void:
	tree_group_repeats = on
	save_to_disk()


func set_world_preview_auto(on: bool) -> void:
	world_preview_auto = on
	save_to_disk()


func set_world_preview_pulse(on: bool) -> void:
	world_preview_pulse = on
	save_to_disk()


func set_group_deadzone(level: int) -> void:
	group_deadzone = clampi(level, 0, 2)
	save_to_disk()


func set_max_rooms(count: int) -> void:
	max_rooms = clampi(count, 1, 16)
	save_to_disk()


func set_haptics_level(level: int) -> void:
	haptics_level = level
	save_to_disk()


func set_last_scene(scene_name: String) -> void:
	last_scene = scene_name
	save_to_disk()


func set_show_landing(on: bool) -> void:
	show_landing = on
	save_to_disk()


func set_show_tips(on: bool) -> void:
	show_tips = on
	save_to_disk()


func set_paint_recent(colours: Array) -> void:
	paint_recent = colours.duplicate()
	save_to_disk()


func set_paint_saved(entries: Array) -> void:
	paint_saved = entries.duplicate(true)
	save_to_disk()
