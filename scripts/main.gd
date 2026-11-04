extends Node3D
## Main scene: imports a saved DIDSA-CAD assembly file straight
## into the backend's "default" session, then downloads the resulting
## GET /document/parts/{part_id}/assembly-mesh.glb node-instanced glTF and
## drops it into the world so it can be grabbed with controller.gd.
##
## Setup: drop a real assembly export (a .DIDSAprt/.didsa file whose root
## Part has occurrences on it — i.e. an assembly, not a bare single part)
## into this project folder, next to project.godot, named exactly what
## native_file_path below says (default "assembly.didsa"). Its
## document.root_part_id is read automatically — no part id to hunt for
## or type in by hand. Only backend_url and api_key need editing in the
## Inspector on the "Main" node.

const BackendSession := preload("res://scripts/backend_session.gd") ## the API key and this app's own X-Document-Session on every call
@export_group("Backend")
@export var backend_url: String = "" ## Loaded from secrets.cfg at runtime (see README) — don't hardcode a real
## URL/key here, this script is committed to git.
@export var api_key: String = "" ## Matches the backend's CAD_API_KEY. Also loaded from secrets.cfg.
@export var secrets_file_path: String = "res://secrets.cfg" ## Untracked (see .gitignore); holds the real
## backend_url/api_key for this machine. See secrets.cfg.example for the format.
@export var relay_url: String = "" ## Loaded from secrets.cfg's [browser_relay] section - the Browser window's
## own separate service (DIDSA-CAD repo, browser-relay/), not the CAD backend above.
@export var relay_api_key: String = "" ## Matches the relay's BROWSER_RELAY_API_KEY.
@export var native_file_path: String = "res://assembly.didsa" ## The exported native file to import before loading (only when the landing is off).
@export var landing_enabled: bool = OS.get_environment("DIDSA_NO_LANDING") == "" ## false: no landing at start, the old start-up import (the tests set DIDSA_NO_LANDING; see tests/README.md)
@export var landing_wait_seconds: float = 3.0 ## on a headset: how long to wait for tracking before placing the landing (a flat preview doesn't wait)
@export var part_id_override: String = "" ## Leave blank to auto-read root_part_id from native_file_path.
@export var quality: float = 0.5 ## 0..1, same slider as the JSON endpoint.
@export var include_hidden: bool = false
@export var tier: String = "" ## "" for full quality, or "coarse".

@export_group("Placement")
@export var spawn_position: Vector3 = Vector3(0, 1.0, -1.0)
@export var local_glb_scale: float = 1.0 ## Scale for a .glb loaded from disk with the tablet's Files tab.
## A bare glb is normally in metres per the glTF spec (unlike the backend's, which is mm), so 1.0.
@export var spawn_scale: float = 0.001 ## Backend native units are millimetres (see backend/app/document/models.py's
## Mate docstring), but glTF/Godot both treat raw coordinate values as metres.
## 0.001 converts mm -> m. If a part looks tiny/huge, check what units it was
## actually modelled in before touching this.

@onready var http_request: HTTPRequest = $HTTPRequest
@onready var assembly_root: Node3D = $AssemblyRoot
var _load_busy := false ## true while an Open/Add/import (or the startup import) is mid-flight — see _claim_load()
var status_text: String = "" ## what _set_status() last said — console-only now (see that function): no floating 3D text in the scene, per John's own real-headset feedback that it was distracting. Kept as a plain string (not just a print) so tests/e2e_*.gd can still poll it to know when a load finished.

var xr_interface: XRInterface
var _resolved_part_id: String = ""
var visibility_ruled_parts: Array = [] ## parts whose load-rule visibility (visibility.gd) is already applied since the file was loaded; session only, never saved
var _native_extras: Dictionary = {} ## top-level keys of the loaded native file the backend ignores (the flat app's hidden_feature_ids, section_planes...): kept so a save writes them back — see save_native_snapshot()
var command_stack := preload("res://scripts/command_stack.gd").new() ## shared undo/redo history — see command_stack.gd
signal dirty_changed(dirty: bool)
signal server_changed ## the backend this app talks to was switched (or went offline): see switch_server()
signal status_changed(text: String) ## every _set_status(): the landing's launcher shows it in the headset
signal discard_prompt_changed() ## a replace is waiting on "discard your unsaved changes?" (the Files page shows the choice), or no longer is
signal references_changed() ## the opened file's moved / missing references (reference_review()) changed: the Files > References page redraws
const ProjectFolder := preload("res://scripts/project_folder.gd") ## the project folder: default, probe, chooser helpers (T1)
const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")
const STALE_MATES_KEY := "vr_stale_mates" ## the native-file extra that carries the design table's "mates need redoing" flags
const DISCARD_CONFIRM_MS := 6000 ## how long a "this will discard your unsaved changes" warning stays armed for a second press
var _startup_composed: Dictionary = {} ## the startup file's compose result, for its references once its mesh is in
var _startup_compose_note := "" ## native_compose.gd's "N referenced files not loaded" for the startup file, shown once its mesh is in
var _reference_choices: Dictionary = {} ## finding moved files: native file -> {"<part id>/<occurrence id>": the file the user picked for it}
var _reference_review: Dictionary = {"root": "", "relinked": [], "review": [], "bases": []} ## the last opened file's moved / missing references
var _references_left: Dictionary = {} ## review keys the user chose to leave missing (hidden on the References page until the next open)
var _dirty_from_relink := false ## the only unsaved change is a moved file's corrected path: picking another reference re-opens without asking
var last_saved_path := "" ## the .didsa the last save wrote
var document_is_demo := false ## what is shown is a demo model shipped in the APK (res://demo/): read-only, so replacing it never asks (Quest 3 report, 21 Oct 2026)
var document_dirty := false ## the session has edits (a move, a mate, a design-table feature, a new part...) that no save has written: anything that REPLACES the document asks first
var _discard_armed_for := ""
var _discard_armed_until_ms := 0
var _pending_discard: Dictionary = {} ## {what, run: Callable}: the replace that hit unsaved changes, run by discard_and_continue()
var _settings := preload("res://scripts/app_settings.gd").new() ## project folder + last-picked scene — see app_settings.gd
@onready var _world_environment: WorldEnvironment = $WorldEnvironment ## Light/Dark/Mid/Passthrough — see environment_manager.gd
const NewDocument := preload("res://scripts/design_table/new_document.gd") ## New assembly / New part: the backend sequences
const BLANK_PART_SIZE_MM := 100.0 ## the placeholder box a brand-new, still empty part stands in with (see add_blank_part())
const RoomRegistry := preload("res://scripts/room/room_registry.gd")
const Landing := preload("res://scripts/landing/landing.gd") ## the first screen: a state of this world, see landing.gd
const RecentFile := preload("res://scripts/landing/recent_file.gd") ## the last file opened, for the landing's Continue tile
const ServerStore := preload("res://scripts/landing/server_store.gd") ## the servers this headset knows (user://servers.cfg)
const ServerProbe := preload("res://scripts/landing/server_probe.gd") ## the Servers page's Test button
const GraphicsOverrides := preload("res://scripts/graphics_overrides.gd") ## user://graphics.cfg: switches for finding a headset rendering fault without a rebuild
const NativeCompose := preload("res://scripts/native_compose.gd") ## multi-file assemblies: the files an occurrence references, folded in before import
const MeshIdentity := preload("res://scripts/mesh_identity.gd") ## occurrence/face identity tagging for mates/measure — see mesh_identity.gd

# Perf readout (see _process): the numbers milestone 1 exists to measure
# on-headset. Timestamps are Time.get_ticks_msec() values.
var face_highlight: Node ## face-level hover / pick highlight for Mates and Measure — see face_highlight.gd
var _two_hand: Node
var _tablet: Node
var _tool_wheel: Node3D ## tool_wheel.gd: right trigger + grip
var _wheel_flows: Node3D ## wheel_flows.gd: what the wheel offers and the prompt
var _measure_dimensions: Node3D ## measure_dimensions.gd: Measure results drawn in the world
var _keyboard: Node
var _mates_tool: Node
var _measure_tool: Node
var drive_tool: Node ## drive_tool.gd: turns a mated part continuously so its whole mechanism runs
var _appearance_tool: Node ## the Appearance tool (appearance_tool.gd): what paint does, where it goes
var scenes_tool: Node ## Scenes (scenes_tool.gd): show / save / update scenes on the sandbox; the tablet's Scenes page and the wheel use it
var _section_tool: Node
var _assembly_tree_window: Node
var _calculator_window: Node
var _image_viewer_window: Node
var _browser_window: Node
var room_manager: Node ## Assembly Rooms: opens a Part in a clipped box of space — see scripts/room/room_manager.gd and docs/assembly-rooms-scope.md
var design_table: Node ## milestone 2: the design table — see scripts/design_table/design_table.gd
var _worst_frame_ms := 0.0 ## longest frame since the readout last refreshed: steady ~22 ms = pacing/cap, spikes = hitches
var _perf_refresh_left := 0.0
var _import_started_ms := 0
var _download_started_ms := 0
var _parse_started_ms := 0
var _load_summary := ""
var _part_count := 0
var view_modes ## view_modes.gd: Shaded / Shaded + edges / Wireframe
var server_store := ServerStore.new() ## the servers this headset knows; secrets.cfg is a developer override on top (see _load_servers())
var active_server_id := "" ## "secrets" (res://secrets.cfg), a server_store id, or "" (offline)
var _secrets_server: Dictionary = {} ## what secrets.cfg gave, kept so it can be switched back to
var landing: Node ## landing.gd: logo, rocket garden, launcher and tips; enter()ed at start and by go_home()

# All endpoints below live under the backend's "/document" router prefix —
# see backend/app/document/router.py's `router = APIRouter(prefix="/document", ...)`.
const API_PREFIX := "/document"


func _ready() -> void:
	_settings.load_from_disk()
	UiThemes.set_fx(_settings.fx_enabled) # before anything is built, so the first frame already has the right look
	if not UiThemes.apply(_settings.ui_theme):
		UiThemes.apply("Navy")
	UiFeedback.reduce_motion = _settings.reduce_motion
	UiFeedback.set_haptics_level(_settings.haptics_level)
	UiFeedback.set_sound_enabled(_settings.sound_enabled)
	UiFeedback.set_volume(_settings.sound_volume)
	preload("res://scripts/ui/ui_sounds.gd").register_all() # the UI's synthesised sounds
	assembly_root.add_to_group("assembly_root")
	_add_two_hand_model()
	_add_mates_tool()
	_add_measure_tool()
	_add_drive_tool()
	_add_face_highlight()
	_add_appearance_tool()
	_add_scenes_tool()
	_add_section_tool()
	_add_view_modes() # after the section tool: its edge shader uses the section clip's global uniforms
	_add_room_manager() # before the tree window: its rows have a Room button
	_add_assembly_tree_window()
	_add_calculator_window()
	_add_image_viewer_window()
	_add_browser_window()
	_add_design_table()
	_add_wrist_tablet()
	_add_tool_wheel()
	_add_popup_keyboard()
	design_table.apply_settings(_settings) # the table's remembered size, zoom limit and what happens to a part sent back
	command_stack.changed.connect(mark_dirty) # only entries that change the document (a part's pose) fire it, not hide / navigate
	_mates_tool.document_changed.connect(mark_dirty)
	_appearance_tool.document_changed.connect(mark_dirty)
	_appearance_tool.configure(design_table.api, _settings) # the design table's own backend client: one request at a time, the app's document session
	scenes_tool.api = design_table.api
	$XROrigin3D/LeftController.command_stack = command_stack
	$XROrigin3D/RightController.command_stack = command_stack
	$XROrigin3D/LeftController.mates_tool = _mates_tool
	$XROrigin3D/RightController.mates_tool = _mates_tool
	$XROrigin3D/LeftController.measure_tool = _measure_tool
	$XROrigin3D/RightController.measure_tool = _measure_tool
	$XROrigin3D/LeftController.drive_tool = drive_tool
	$XROrigin3D/RightController.drive_tool = drive_tool
	$XROrigin3D/LeftController.appearance_tool = _appearance_tool
	$XROrigin3D/RightController.appearance_tool = _appearance_tool
	_appearance_tool.message.connect(_set_status)
	scenes_tool.message.connect(_set_status)
	$XROrigin3D/LeftController.section_tool = _section_tool
	$XROrigin3D/RightController.section_tool = _section_tool
	_apply_group_deadzone()
	$XROrigin3D/LeftController.group_message.connect(_set_status)
	$XROrigin3D/RightController.group_message.connect(_set_status)
	$XROrigin3D/LeftController.laser_select_enabled = false # real-headset feedback: left trigger-select blocked left-hand locomotion (controller.gd's is_manipulating()) — grip-grab stays on both hands, left laser is freed up for a later tool (context menu, multi-select — not decided yet)
	$XROrigin3D/RightController.button_pressed.connect(_on_right_stick_click)
	_load_secrets()
	_load_servers()
	_apply_backend()
	_start_xr()
	_world_environment.setup($DirectionalLight3D, xr_interface, get_viewport(), $Ground/MeshInstance3D.mesh.material as ShaderMaterial)
	# Never start in Passthrough: if it misbehaves on a headset (Quest 3, 21 Oct: a flicker in both eyes from the first frame) you would start blind,
	# with no way to see the menu that turns it off. Turn it on again from View > Environment or the landing's Scan / Graphics check pages.
	_world_environment.apply_saved_scene(startup_scene(_settings.last_scene))
	_add_landing()
	_apply_graphics_overrides()
	if landing_enabled and _settings.show_landing:
		_set_status(startup_status())
		_enter_landing_at_start() # no start-up import: the landing offers Continue, Open and the demos
		return
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("No backend configured (see secrets.cfg.example). Turn your left wrist up and use the Files tab to load a local .glb.")
		return
	http_request.request_completed.connect(_on_import_completed)
	_begin_import()


func _add_two_hand_model() -> void:
	var two_hand := preload("res://scripts/two_hand_model.gd").new()
	two_hand.name = "TwoHandModel"
	add_child(two_hand)
	two_hand.setup(assembly_root, $XROrigin3D/LeftController, $XROrigin3D/RightController, spawn_scale, command_stack)
	_two_hand = two_hand


func _add_mates_tool() -> void:
	var mates := preload("res://scripts/mates_tool.gd").new()
	mates.name = "MatesTool"
	add_child(mates)
	mates.setup(command_stack)
	_mates_tool = mates
	mates.sandbox_ghosts = _settings.sandbox_ghosts
	mates.sandbox_lines = _settings.sandbox_lines


func _add_measure_tool() -> void:
	var measure := preload("res://scripts/measure_tool.gd").new()
	measure.name = "MeasureTool"
	add_child(measure)
	_measure_tool = measure


func _add_drive_tool() -> void:
	var drive := preload("res://scripts/drive_tool.gd").new()
	drive.name = "DriveTool"
	drive.mates_tool = _mates_tool
	add_child(drive)
	drive_tool = drive


func _add_face_highlight() -> void:
	## Lights up just the hovered / picked FACE for Mates and Measure (see face_highlight.gd).
	var highlight := preload("res://scripts/face_highlight.gd").new()
	highlight.name = "FaceHighlight"
	add_child(highlight)
	face_highlight = highlight
	var refresh := func() -> void:
		var entries: Array = []
		if _mates_tool.active:
			entries = _mates_tool.picked_entities()
		elif _measure_tool.active:
			entries = _measure_tool.picked_entities()
		highlight.set_picks(entries)
	_mates_tool.picks_changed.connect(refresh)
	_measure_tool.picks_changed.connect(refresh)
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		hand.face_highlight = highlight


func _add_appearance_tool() -> void:
	var appearance := preload("res://scripts/appearance_tool.gd").new()
	appearance.name = "AppearanceTool"
	appearance.mates_tool = _mates_tool # painting is temporary while mates are relaxed (the sandbox)
	appearance.face_highlight = face_highlight
	appearance.command_stack = command_stack
	add_child(appearance)
	_appearance_tool = appearance


func _add_scenes_tool() -> void:
	var scenes := preload("res://scripts/scenes_tool.gd").new()
	scenes.name = "ScenesTool"
	scenes.mates_tool = _mates_tool
	scenes.appearance_tool = _appearance_tool
	scenes.camera = $XROrigin3D/XRCamera3D
	scenes.scopes = scene_scopes
	add_child(scenes)
	scenes_tool = scenes


func scene_scopes() -> Array:
	## Where scenes live (scenes_tool.gd): the world's assembly (its glb's root under AssemblyRoot, which a viewpoint moves) and each
	## open Assembly Room's Part (a viewpoint doesn't move a room).
	var out: Array = []
	if _resolved_part_id != "" and assembly_root.get_child_count() > 0:
		out.append({"root": _resolved_part_id, "scene": assembly_root.get_child(0), "view": assembly_root})
	if room_manager != null:
		for room in room_manager.rooms:
			if is_instance_valid(room) and room.content_root != null and room.content_root.get_child_count() > 0:
				out.append({"root": room.part_id, "scene": room.content_root.get_child(0), "view": null})
	return out


func scope_name(root: String) -> String:
	## The Scenes page's name for a scope: World, or the room's label.
	if root == _resolved_part_id:
		return "World"
	if room_manager != null:
		for room in room_manager.rooms:
			if is_instance_valid(room) and room.part_id == root:
				return str(room.label)
	return root


func _add_section_tool() -> void:
	var sections := preload("res://scripts/section_tool.gd").new()
	sections.name = "SectionTool"
	add_child(sections)
	sections.setup(command_stack)
	_section_tool = sections


func _add_view_modes() -> void:
	view_modes = preload("res://scripts/view_modes.gd").new()
	view_modes.name = "ViewModes"
	add_child(view_modes)
	view_modes.setup(self, _settings.view_render_mode)


func app_settings() -> RefCounted:
	return _settings


func save_view_mode(mode: int) -> void:
	_settings.set_view_render_mode(mode)


func _add_room_manager() -> void:
	RoomRegistry.set_max_rooms(_settings.max_rooms)
	room_manager = preload("res://scripts/room/room_manager.gd").new()
	room_manager.name = "RoomManager"
	add_child(room_manager)
	room_manager.setup(self, view_modes)
	room_manager.glass = _settings.room_glass
	room_manager.pedestal = _settings.room_pedestal
	room_manager.preview_live = _settings.world_preview_auto
	room_manager.preview_pulse = _settings.world_preview_pulse
	room_manager.status.connect(_set_status)
	_two_hand.focus = func(hand: Node3D) -> bool: return RoomRegistry.room_at(hand.global_position) == -1 # a grip on empty space inside a room is the room's


func sandbox_ghosts() -> bool:
	return _settings.sandbox_ghosts


func set_sandbox_ghosts(on: bool) -> void:
	_settings.set_sandbox_ghosts(on)
	_mates_tool.sandbox_ghosts = on


func sandbox_lines() -> bool:
	return _settings.sandbox_lines


func set_sandbox_lines(on: bool) -> void:
	_settings.set_sandbox_lines(on)
	_mates_tool.sandbox_lines = on


func room_pedestal() -> bool:
	return _settings.room_pedestal


func set_room_pedestal(on: bool) -> void:
	_settings.set_room_pedestal(on)
	room_manager.set_pedestal(on)


func room_glass() -> bool:
	return _settings.room_glass


func set_room_glass(on: bool) -> void:
	_settings.set_room_glass(on)
	room_manager.set_glass(on)


func world_preview_auto() -> bool:
	return _settings.world_preview_auto


func set_world_preview_auto(on: bool) -> void:
	_settings.set_world_preview_auto(on)
	room_manager.set_preview_live(on)


func world_preview_pulse() -> bool:
	return _settings.world_preview_pulse


func set_world_preview_pulse(on: bool) -> void:
	_settings.set_world_preview_pulse(on)
	room_manager.set_preview_pulse(on)


const GROUP_DEADZONES := [0.0, 0.02, 0.04] ## metres, by AppSettings.group_deadzone

func group_deadzone_level() -> int:
	return _settings.group_deadzone


func set_group_deadzone(level: int) -> void:
	_settings.set_group_deadzone(level)
	_apply_group_deadzone()


func _apply_group_deadzone() -> void:
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		hand.group_deadzone = GROUP_DEADZONES[clampi(_settings.group_deadzone, 0, 2)]


func max_rooms() -> int:
	return RoomRegistry.max_rooms


func set_max_rooms(count: int) -> void:
	_settings.set_max_rooms(count)
	RoomRegistry.set_max_rooms(count)


func _add_assembly_tree_window() -> void:
	## Milestone 3: the vision brief's interactive assembly tree — browse
	## and select occurrences without laser-pointing at their geometry
	## first. See assembly_tree_window.gd's own docstring.
	var window := preload("res://scripts/assembly_tree_window.gd").new()
	window.name = "AssemblyTreeWindow"
	add_child(window)
	window.setup_tree($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, self)
	_assembly_tree_window = window


func _add_calculator_window() -> void:
	## Milestone 3's Calculator window — see calculator_window.gd's own docstring.
	var window := preload("res://scripts/calculator_window.gd").new()
	window.name = "CalculatorWindow"
	add_child(window)
	window.setup_calculator($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_calculator_window = window


func _add_image_viewer_window() -> void:
	## Milestone 3's Image Viewer window — see image_viewer_window.gd's own docstring.
	var window := preload("res://scripts/image_viewer_window.gd").new()
	window.name = "ImageViewerWindow"
	add_child(window)
	window.setup_image_viewer($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_image_viewer_window = window


func _add_browser_window() -> void:
	## Milestone 3's Browser window (and, via Chrome's own built-in PDF
	## viewer, its PDF reader too) - see browser_window.gd's own docstring.
	var window := preload("res://scripts/browser_window.gd").new()
	window.name = "BrowserWindow"
	add_child(window)
	window.setup_browser($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)
	_browser_window = window


## Browser and Image Viewer windows can be open several at a time (real-
## headset request). The tablet's button calls open_window(): it opens the
## primary window if that's closed, otherwise spawns another (each with its own
## close, its own picture/page, staggered so they don't stack exactly).
## Extras delete themselves when closed. The browser relay caps concurrent
## sessions server-side (BROWSER_RELAY_MAX_SESSIONS) — beyond that an extra
## Browser's status line says it couldn't connect.
var _extra_windows: Array = []

func open_window(kind: String) -> Node:
	var primary: Node = _browser_window if kind == "browser" else _image_viewer_window
	if not primary.is_open():
		primary.open()
		return primary
	return spawn_window(kind)


func spawn_window(kind: String) -> Node:
	var left := $XROrigin3D/LeftController
	var right := $XROrigin3D/RightController
	var camera := $XROrigin3D/XRCamera3D
	var window: Node
	var siblings := 1 # the primary
	for w in _extra_windows:
		if is_instance_valid(w) and w.get_meta("window_kind", "") == kind:
			siblings += 1
	if kind == "browser":
		window = preload("res://scripts/browser_window.gd").new()
		window.name = "BrowserWindowExtra%d" % siblings
		add_child(window)
		window.setup_browser(left, right, camera)
		window.configure_relay(relay_url, relay_api_key)
		window.set_keyboard(_keyboard)
	else:
		window = preload("res://scripts/image_viewer_window.gd").new()
		window.name = "ImageViewerWindowExtra%d" % siblings
		add_child(window)
		window.setup_image_viewer(left, right, camera)
	window.set_meta("window_kind", kind)
	# Stagger each new window sideways and back a little, so they fan out
	# instead of stacking exactly on top of one another.
	window.open_lateral_offset += 0.12 * siblings * (1.0 if siblings % 2 == 1 else -1.0)
	window.open_distance += 0.03 * siblings
	window.free_on_close = true
	_extra_windows.append(window)
	window.tree_exited.connect(func() -> void: _extra_windows.erase(window))
	window.open()
	return window


func open_window_count(kind: String) -> int:
	## How many windows of this kind are open right now (primary + extras).
	var primary: Node = _browser_window if kind == "browser" else _image_viewer_window
	var n := 1 if primary.is_open() else 0
	for w in _extra_windows:
		if is_instance_valid(w) and w.get_meta("window_kind", "") == kind and w.is_open():
			n += 1
	return n


func _add_design_table() -> void:
	## Milestone 2: the summonable design table — see design_table.gd's own docstring.
	var table := preload("res://scripts/design_table/design_table.gd").new()
	table.name = "DesignTable"
	add_child(table)
	table.setup($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, self, _mates_tool)
	design_table = table


func _add_wrist_tablet() -> void:
	var tablet: Node = preload("res://scripts/ui/wrist_tablet.gd").new()
	tablet.name = "WristTablet"
	tablet.setup($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, _two_hand, $XROrigin3D, self, command_stack, _mates_tool, _appearance_tool, _section_tool, _measure_tool, _assembly_tree_window, _calculator_window, _image_viewer_window, _browser_window, design_table)
	_tablet = tablet


func _add_tool_wheel() -> void:
	## The tool wheel (right trigger + grip), the prompt that leads you through a tool, and Measure's in-world dimensions.
	var tokens: Resource = _tablet.tokens
	_wheel_flows = preload("res://scripts/ui/wheel_flows.gd").new()
	_wheel_flows.name = "WheelFlows"
	add_child(_wheel_flows)
	_wheel_flows.setup({
		"main": self, "tablet": _tablet, "mates_tool": _mates_tool, "measure_tool": _measure_tool,
		"hand": $XROrigin3D/RightController, "design_table": design_table, "camera": $XROrigin3D/XRCamera3D,
		"swatches": preload("res://scripts/ui/tablet_pages.gd").COLOUR_SWATCHES,
	}, tokens)
	_tool_wheel = preload("res://scripts/ui/tool_wheel.gd").new()
	_tool_wheel.name = "ToolWheel"
	add_child(_tool_wheel)
	_tool_wheel.setup($XROrigin3D/RightController, $XROrigin3D/XRCamera3D, tokens, _wheel_flows.entries)
	_tool_wheel.title_provider = _wheel_flows.ring_title
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		hand.tool_message.connect(_set_status)
		hand.tool_message.connect(_wheel_flows.say)
	_tool_wheel.pill_provider = _wheel_flows.pill_entry
	_tool_wheel.summary_changed.connect(_wheel_flows.on_wheel_summary)
	_tool_wheel.shown_changed.connect(func(shown: bool) -> void:
		# While the ring is up the wrist panel sits under it: hanging off the hand (the ring's centre) it covered the wedges round it.
		if shown:
			_wheel_flows.hint_panel().dock_under(_tool_wheel, _tool_wheel.clear_drop)
		else:
			_wheel_flows.hint_panel().undock())
	_tool_wheel.shown_changed.connect(_wheel_flows.on_ring_shown)
	_tool_wheel.set_size(_settings.wheel_size)
	_tool_wheel.set_enabled(_settings.wheel_enabled)
	_measure_dimensions = preload("res://scripts/measure_dimensions.gd").new()
	_measure_dimensions.name = "MeasureDimensions"
	add_child(_measure_dimensions)
	_measure_dimensions.setup(_measure_tool, $XROrigin3D/XRCamera3D)


func _add_landing() -> void:
	landing = Landing.new()
	landing.name = "Landing"
	add_child(landing)
	landing.setup(self, $XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D)


func _enter_landing_at_start() -> void:
	## On a headset the camera has no pose in the first frames, so wait (a few seconds at most) until it is up at head height; a flat
	## preview has no tracking to wait for.
	var waited := 0.0
	var camera: Node3D = $XROrigin3D/XRCamera3D
	while xr_interface != null and xr_interface.is_initialized() and camera.position.y < 0.3 and waited < landing_wait_seconds:
		await get_tree().process_frame
		waited += get_process_delta_time()
	await get_tree().process_frame
	if is_inside_tree() and not landing.is_active() and _part_count == 0:
		landing.enter()


func go_home() -> void:
	## The Home tile (wrist tablet) and the wheel's Home: back to the landing, in front of where you are looking now.
	if _tablet.is_open():
		_tablet.close_tablet()
	landing.enter()


func open_tablet_at(category_id: String) -> void:
	## Opens the wrist tablet on a category (the landing's Open... and Settings tiles).
	if not _tablet.is_open():
		_tablet.open_tablet()
	_tablet.ui.select_category(category_id)


func show_landing_on_start() -> bool:
	return _settings.show_landing


func set_show_landing_on_start(on: bool) -> void:
	_settings.set_show_landing(on)


func show_tips() -> bool:
	return _settings.show_tips


func set_show_tips(on: bool) -> void:
	_settings.set_show_tips(on)
	landing.set_show_tips(on)


func has_backend() -> bool:
	return not backend_url.is_empty() and not api_key.is_empty()


func connection_text() -> String:
	## The landing's connection pill. A server is "set", not "checked": nothing has called it yet.
	if not has_backend():
		return "Offline: demo models only"
	return "Server: %s" % _backend_host()


func server_note() -> String:
	## The Servers tile's small line.
	return "Offline" if not has_backend() else _backend_host()


func server_detail() -> String:
	if not has_backend():
		return "No server is set, so everything that needs DIDSA-CAD (opening native files, mates, measuring, painting) is greyed out. The demo models work offline."
	var origin := "From secrets.cfg" if active_server_id == "secrets" else "From servers.cfg"
	return "%s: %s. Use Test to check it answers." % [origin, backend_url]


func _backend_host() -> String:
	var host := backend_url.trim_prefix("https://").trim_prefix("http://")
	return host.get_slice("/", 0)


func startup_status() -> String:
	return "Offline: demo models only. Pick a rocket under Demo models, or point at the wrist icon for the tablet." if not has_backend() else "Server: %s. Pick Continue, Open or a demo." % _backend_host()


func say(text: String) -> void:
	## A status message from the landing (or anything else without its own line): console and headset.
	_set_status(text)


func place_model(world_transform: Transform3D, scale_value: float) -> void:
	## Puts the model that was just shown (a demo: landing.gd) at a pose and scale of its own instead of in front of the user.
	assembly_root.transform = Transform3D(world_transform.basis.scaled(Vector3.ONE * scale_value), world_transform.origin)
	_two_hand.set_real_life_scale(scale_value)
	_two_hand.remember_home()


func wheel_enabled() -> bool:
	return _settings.wheel_enabled


func set_wheel_enabled(on: bool) -> void:
	_settings.set_wheel_enabled(on)
	_tool_wheel.set_enabled(on)


func wheel_size() -> int:
	return _settings.wheel_size


func set_wheel_size(index: int) -> void:
	_settings.set_wheel_size(index)
	_tool_wheel.set_size(index)


func _add_popup_keyboard() -> void:
	## The vision brief's popup keyboard, reserved on the right thumbstick
	## click since the wrist tablet was built. First real use: typing an
	## exact scale multiple (see _on_right_stick_click below).
	var keyboard := preload("res://scripts/popup_keyboard.gd").new()
	keyboard.name = "PopupKeyboard"
	add_child(keyboard)
	keyboard.setup($XROrigin3D/RightController, $XROrigin3D/XRCamera3D, $XROrigin3D/LeftController)
	_keyboard = keyboard
	_browser_window.set_keyboard(keyboard) # the Browser types web addresses / page text on the full keyboard


func _on_right_stick_click(action_name: String) -> void:
	if action_name != "primary_click":
		return
	if _keyboard.is_open():
		_keyboard.close()
		return
	_keyboard.open_for(_trim_number(_two_hand.current_multiple()), _on_scale_typed)


func _on_scale_typed(text: String) -> void:
	var value := text.to_float()
	if value > 0.0:
		_two_hand.set_preset(value)


func open_keyboard_for(initial_text: String, on_confirm: Callable, options: Dictionary = {}) -> void:
	## Lets the wrist tablet's Mates tab reuse the same popup keyboard the
	## Scale tab's exact-value entry does (_on_right_stick_click above) —
	## only one thing needs it open at a time anyway. `options` picks the full
	## keyboard ({"mode": "full", "title": ..., "confirm_label": ...}) for real
	## text (hex colours, folder paths, web addresses); none = the numeric keypad.
	if _keyboard.is_open():
		_keyboard.close()
	_keyboard.open_for(initial_text, on_confirm, options)


func appearance_patterns() -> Dictionary:
	## The component pattern lists the Appearance tool has fetched (Part id -> rows), for naming pattern copies like the flat app; empty before it has any.
	return _appearance_tool.all_patterns() if _appearance_tool != null else {}


func current_root_part_id() -> String:
	## The loaded assembly's own root Part id — every top-level Occurrence's
	## own owner_part_id (see mesh_identity.gd) matches this, so it's what
	## the Mates tab's "Enforce all"/mate-list refresh (and the Assembly Tree
	## window's own root fetch) operate on. Empty if nothing backend-backed
	## is loaded yet (a bare local .glb, say).
	return _resolved_part_id


# --- Tools tab (wrist_tablet.gd): hide/show all, reverse visibility, isolate.
# Shoot-to-hide itself is per-hand (controller.gd's hide_tool_active/_try_shoot_hide);
# these are the whole-assembly operations, so they live here alongside
# list_model_files()/load_glb_file() — the other model-wide API the tablet calls into.

func hide_all_parts() -> void:
	_set_all_visibility(false, "hide all")


func show_all_parts() -> void:
	_set_all_visibility(true, "show all")


func _arena_parts(anchor: Node = null) -> Array:
	## The parts hide / show / reverse / isolate act on: the arena's, not counting the one sitting on the design table (hidden on purpose, and not for
	## them to bring back); or, when the user is standing in an Assembly Room (or the anchor part is in one), that room's.
	return room_manager.scope_parts(anchor)


func reverse_visibility() -> void:
	var parts := _arena_parts()
	if parts.is_empty():
		return
	var before := {}
	for p in parts:
		before[p] = p.visible
	for p in parts:
		p.visible = not p.visible
	_push_visibility_command("reverse visibility", before)


func isolate_selected() -> void:
	var target := current_selected_part()
	if target == null:
		return
	var parts := _arena_parts(target)
	var before := {}
	for p in parts:
		before[p] = p.visible
	for p in parts:
		p.visible = (p == target)
	_push_visibility_command("isolate %s" % target.name, before)


func current_selected_part() -> Node3D:
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		if hand.selected_node != null:
			return hand.selected_node
	return null


func select_part_by_occurrence_id(occurrence_id: String) -> bool:
	## The Assembly Tree window's tap-to-select (assembly_tree_window.gd):
	## finds the currently loaded mesh tagged (mesh_identity.gd) with this
	## occurrence id and selects it the same way laser-select would, via
	## RightController's select_external(). Returns false if nothing loaded
	## right now carries that id — e.g. the row is an intermediate sub-
	## assembly with no rendered geometry of its own (assembly-mesh.glb has
	## one node per placed *leaf* instance only — see mesh_identity.gd's own
	## docstring), or the occurrence is hidden.
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if node.has_meta("occurrence_id") and node.get_meta("occurrence_id") == occurrence_id and node.visible:
			$XROrigin3D/RightController.select_external(node, node.global_position)
			return true
	return false


func _set_all_visibility(vis: bool, label: String) -> void:
	var parts := _arena_parts()
	if parts.is_empty():
		return
	var before := {}
	var changed := false
	for p in parts:
		before[p] = p.visible
		if p.visible != vis:
			changed = true
	if not changed:
		return # nothing to undo if it was already all hidden/shown
	for p in parts:
		p.visible = vis
	_push_visibility_command(label, before)


func _push_visibility_command(label: String, before: Dictionary) -> void:
	var after := {}
	for p in before:
		after[p] = p.visible
	var undo_fn := func() -> void:
		for p in before:
			if is_instance_valid(p):
				p.visible = before[p]
	var redo_fn := func() -> void:
		for p in after:
			if is_instance_valid(p):
				p.visible = after[p]
	command_stack.push(label, undo_fn, redo_fn)


func _trim_number(x: float) -> String:
	return ("%.3f" % x).rstrip("0").rstrip(".")


func set_measuring(on: bool) -> void:
	## GPU/CPU render timing costs a little itself, so it only runs while the tablet is open.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), on)


func set_shadows(on: bool) -> void:
	$DirectionalLight3D.shadow_enabled = on


func set_render_scale(multiplier: float) -> void:
	## Fraction of the headset runtime's recommended resolution (per axis). The biggest
	## lever on a GPU-bound frame: 80% is ~64% of the pixels.
	if xr_interface and xr_interface.is_initialized():
		xr_interface.set("render_target_size_multiplier", multiplier)
	else:
		get_viewport().scaling_3d_scale = multiplier


func set_msaa(level: int) -> void:
	get_viewport().msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][level]


func msaa_level() -> int:
	return {Viewport.MSAA_DISABLED: 0, Viewport.MSAA_2X: 1, Viewport.MSAA_4X: 2}.get(get_viewport().msaa_3d, 1)


func _apply_graphics_overrides() -> void:
	## user://graphics.cfg (graphics_overrides.gd), then one log line with what rendering ended up with, so a headset log says it either way.
	var overrides := GraphicsOverrides.new()
	if overrides.load_from_disk():
		if overrides.has("foveation"):
			set_foveation_level(clampi(int(overrides.get_value("foveation")), 0, 3))
		if overrides.has("vrs"):
			get_viewport().vrs_mode = Viewport.VRS_XR if str(overrides.get_value("vrs")) == "xr" else Viewport.VRS_DISABLED
		if overrides.has("msaa"):
			set_msaa(clampi(int(overrides.get_value("msaa")), 0, 2))
		if landing != null:
			if overrides.has("sky") or overrides.has("fog"):
				landing.stage.set_look(str(overrides.get_value("sky", "plain" if landing.stage.plain_sky else "shader")) == "plain", bool(overrides.get_value("fog", landing.stage.fog_on)))
			if overrides.has("glow"):
				landing.set_halo_on(bool(overrides.get_value("glow")))
			if overrides.has("rockets"):
				landing.set_rockets_on(bool(overrides.get_value("rockets")))
		print("DIDSA VR: graphics.cfg: ", overrides.describe())
	print("DIDSA VR: rendering: foveation %d, vrs %s, msaa %d, render size %s" % [foveation_level(), "xr" if get_viewport().vrs_mode == Viewport.VRS_XR else str(get_viewport().vrs_mode), msaa_level(), str(xr_interface.get_render_target_size()) if xr_interface and xr_interface.is_initialized() else "no headset"])


func foveation_level() -> int:
	## The OpenXR foveated-rendering level (0 off .. 3 high), or -1 with no headset.
	if xr_interface and xr_interface.is_initialized() and "foveation_level" in xr_interface:
		return int(xr_interface.get("foveation_level"))
	return -1


func set_foveation_level(level: int) -> void:
	if xr_interface and xr_interface.is_initialized() and "foveation_level" in xr_interface:
		xr_interface.set("foveation_level", level)


# --- Environment (View > Environment tab): Light/Dark/Mid rendered presets
# plus Passthrough (OpenXR mixed reality) — see environment_manager.gd.

func available_scenes() -> Array[String]:
	return _world_environment.SCENES


static func startup_scene(saved: String) -> String:
	return "Mid" if saved == "Passthrough" else saved


func current_scene() -> String:
	return _world_environment.current_scene


func set_scene(scene_name: String) -> void:
	_world_environment.set_scene(scene_name)
	_settings.set_last_scene(scene_name)


func is_passthrough_supported() -> bool:
	return _world_environment.is_passthrough_supported()


func passthrough_status() -> String:
	## What Passthrough is doing and, if it can't, why (what the runtime offers): shown on the
	## tablet's Environment page. "" unless the Passthrough scene is selected.
	return _world_environment.passthrough_status()


# --- Comfort settings (the redesigned tablet's Settings page): Reduce motion and haptics
# intensity, persisted via app_settings.gd and applied through ui_feedback.gd's statics.

const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")

func ui_theme() -> String:
	return _settings.ui_theme


func set_ui_theme(theme_name: String) -> void:
	## Settings > Appearance: every tablet / window / keyboard re-themes itself in place.
	if UiThemes.apply(theme_name):
		_settings.set_ui_theme(theme_name)


func fx_enabled() -> bool:
	return _settings.fx_enabled


func set_fx_enabled(on: bool) -> void:
	_settings.set_fx_enabled(on)
	UiThemes.set_fx(on)


func reduce_motion() -> bool:
	return _settings.reduce_motion


func set_reduce_motion(on: bool) -> void:
	_settings.set_reduce_motion(on)
	UiFeedback.reduce_motion = on


func sound_enabled() -> bool:
	return _settings.sound_enabled


func set_sound_enabled(on: bool) -> void:
	_settings.set_sound_enabled(on)
	UiFeedback.set_sound_enabled(on)


func sound_volume() -> float:
	return _settings.sound_volume


func set_sound_volume(v: float) -> void:
	_settings.set_sound_volume(v)
	UiFeedback.set_volume(v)


func haptics_level() -> int:
	return _settings.haptics_level


func set_haptics_level(level: int) -> void:
	_settings.set_haptics_level(level)
	UiFeedback.set_haptics_level(level)


# --- Settings page: the project folder the Files tab scans, on top of the
# built-in res://models and user://models.

func project_folder() -> String:
	return _settings.project_folder


func set_project_folder(path: String) -> void:
	_settings.set_project_folder(path)


func folder_needs_asking() -> bool:
	## True until the user has answered "where should your projects be saved" (the landing's first-run card, T1).
	return not _settings.folder_asked


func use_project_folder(path: String) -> Dictionary:
	## Makes `path` the project folder if it can be used (ProjectFolder.probe): {ok, error, path}. A folder that can't be written is refused
	## with the reason, and nothing changes.
	var result := ProjectFolder.probe(path)
	if not (result["exists"] and result["readable"] and result["writable"]):
		_set_status("Can't use %s: %s" % [path, result["error"]])
		return {"ok": false, "error": result["error"], "path": path}
	_settings.set_project_folder(path)
	_set_status("Project folder: %s" % ProjectFolder.full_path(path))
	return {"ok": true, "error": "", "path": path}


func use_default_project_folder() -> Dictionary:
	return use_project_folder(ProjectFolder.default_folder())


func keep_in_app_storage() -> void:
	## "Keep in app storage": no project folder; saves go to user://models. The question counts as answered.
	_settings.set_project_folder("")
	_set_status("Project files stay in the app's own storage: %s" % ProjectSettings.globalize_path(ProjectFolder.APP_FOLDER))


const ALL_FILES_PERMISSION := "android.permission.MANAGE_EXTERNAL_STORAGE"

func all_files_access_text() -> String:
	## Settings > Project folder: the state of *All files access* in words. Only the Android build has it; whether OS.get_granted_permissions()
	## reports this particular permission on Horizon OS is not verified (docs/android-build.md), so "not granted" can also mean "not reported".
	if not OS.has_feature("android"):
		return "All files access: not needed on this platform."
	if ALL_FILES_PERMISSION in OS.get_granted_permissions():
		return "All files access: allowed. Any folder can be read."
	return "All files access: not allowed (or not reported). Files other apps put in the folder may not open."


func request_all_files_access() -> void:
	## Sends the user to the system's All files access page for this app (Android only).
	if not OS.has_feature("android"):
		_set_status("All files access is an Android setting; not needed here.")
		return
	OS.request_permission("MANAGE_EXTERNAL_STORAGE")
	_set_status("Allow All files access on the system page that opened, then come back.")


func save_dir() -> String:
	## Where saves go: the project folder if set, else the app's own user://models.
	return _settings.project_folder if not _settings.project_folder.is_empty() else ProjectFolder.APP_FOLDER


func folder_label() -> String:
	## "Project folder: Documents/DIDSA" (or "App storage"), for the Files page header.
	return "Project folder: %s" % ProjectFolder.short_name(_settings.project_folder)


func _process(delta: float) -> void:
	_worst_frame_ms = maxf(_worst_frame_ms, delta * 1000.0)
	if _section_tool.active: # no-ops internally when inactive, but skip the group lookup entirely when there's nothing to do
		_section_tool.reconcile(get_tree().get_nodes_in_group("grabbable_parts"))
	# Only while the tablet is open (nobody can see the numbers otherwise), and a few
	# times a second: rewriting the label every frame would make the readout itself a
	# cost and be unreadable anyway.
	if not _tablet.is_open():
		return
	_perf_refresh_left -= delta
	if _perf_refresh_left > 0.0:
		return
	_perf_refresh_left = 0.5
	var lines := PackedStringArray()
	lines.append("%d fps  %.1f ms/frame  (worst %.1f ms)" % [Engine.get_frames_per_second(), delta * 1000.0, _worst_frame_ms])
	_worst_frame_ms = 0.0
	var viewport_rid := get_viewport().get_viewport_rid()
	lines.append("render: cpu %.1f ms, gpu %.1f ms  |  scripts %.1f ms, physics %.1f ms" % [
		RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid),
		RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
	])
	if _part_count > 0:
		lines.append("%d parts  %d draw calls" % [_part_count, int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))])
	if _load_summary != "":
		lines.append(_load_summary)
	_tablet.set_info("\n".join(lines))


func _load_secrets() -> void:
	if not FileAccess.file_exists(secrets_file_path):
		return
	var config := ConfigFile.new()
	if config.load(secrets_file_path) != OK:
		push_warning("DIDSA VR: couldn't parse %s" % secrets_file_path)
		return
	backend_url = config.get_value("backend", "url", backend_url)
	api_key = config.get_value("backend", "api_key", api_key)
	BackendSession.set_session_id(str(config.get_value("backend", "document_session", ""))) # optional: a fixed document session id (default: a fresh one per launch)
	relay_url = config.get_value("browser_relay", "url", relay_url)
	relay_api_key = config.get_value("browser_relay", "api_key", relay_api_key)


func _load_servers() -> void:
	## Which server to start on: res://secrets.cfg when it names one (the developer override), else the one chosen last in servers.cfg, else none.
	if has_backend():
		_secrets_server = {"id": "secrets", "name": "From secrets.cfg", "url": backend_url, "api_key": api_key, "document_session": "",
			"relay_url": relay_url, "relay_api_key": relay_api_key, "readonly": true}
		active_server_id = "secrets"
	server_store.load_from_disk()
	if active_server_id == "":
		var saved := server_store.current()
		if not saved.is_empty():
			_set_backend_from(saved)
			active_server_id = str(saved["id"])


func _set_backend_from(entry: Dictionary) -> void:
	backend_url = str(entry.get("url", ""))
	api_key = str(entry.get("api_key", ""))
	relay_url = str(entry.get("relay_url", ""))
	relay_api_key = str(entry.get("relay_api_key", ""))
	BackendSession.set_session_id(str(entry.get("document_session", "")))


func _apply_backend() -> void:
	## Tells everything that talks to the backend where it is now. Called at start and again whenever the server changes, so no restart is needed.
	_mates_tool.configure_backend(backend_url, api_key)
	_measure_tool.configure_backend(backend_url, api_key)
	_assembly_tree_window.configure_backend(backend_url, api_key)
	room_manager.configure_backend(backend_url, api_key)
	design_table.configure_backend(backend_url, api_key)
	_browser_window.configure_relay(relay_url, relay_api_key)


func server_entries() -> Array[Dictionary]:
	## Every server the Servers page lists: secrets.cfg's first (read-only), then servers.cfg's. Each carries `current`.
	var out: Array[Dictionary] = []
	if not _secrets_server.is_empty():
		var first := _secrets_server.duplicate()
		first["current"] = active_server_id == "secrets"
		out.append(first)
	for entry in server_store.servers:
		var copy: Dictionary = entry.duplicate()
		copy["current"] = active_server_id == str(entry["id"])
		out.append(copy)
	return out


func switch_server(id: String) -> bool:
	## Use another server ("" = go offline) without a restart. What is loaded from the old server (a native file, a new assembly) is unloaded first,
	## since its part ids mean nothing to the new one; unsaved changes ask first, like any replace. True if it switched.
	var entry: Dictionary = {}
	if id == "secrets":
		entry = _secrets_server
	elif id != "":
		entry = server_store.find(id)
	if id != "" and entry.is_empty():
		_set_status("That server is not in the list any more.")
		return false
	if id == active_server_id:
		return true
	if _load_busy:
		_set_status("Busy: still working on the previous file. Try switching server again in a moment.")
		return false
	if _resolved_part_id != "" and not confirm_discard("Switch server"):
		return false
	if _resolved_part_id != "":
		unload_model()
	if id == "":
		backend_url = ""
		api_key = ""
		relay_url = ""
		relay_api_key = ""
	else:
		_set_backend_from(entry)
	active_server_id = id
	if id != "secrets":
		server_store.set_current(id) # secrets.cfg is not remembered: it is read at every start anyway
	_apply_backend()
	server_changed.emit()
	_set_status("Offline: demo models only." if id == "" else "Server: %s." % _backend_host())
	return true


func forget_server(id: String) -> bool:
	## Remove a server from servers.cfg; if it is the one in use, go offline first. secrets.cfg's entry cannot be forgotten.
	if id == "secrets" or server_store.find(id).is_empty():
		return false
	if id == active_server_id and not switch_server(""):
		return false
	return server_store.remove(id)


func add_server(fields: Dictionary, use_now: bool = true) -> Dictionary:
	## Saves a server (typed or scanned) and, by default, switches to it. Returns the stored entry, or {} when it is refused.
	var entry := server_store.add(fields, use_now)
	if entry.is_empty():
		return {}
	if use_now:
		if active_server_id == str(entry["id"]): # the same server added again with a new key or name: apply it where it is
			_set_backend_from(entry)
			_apply_backend()
			server_changed.emit()
		else:
			switch_server(str(entry["id"]))
	return entry


var test_server_override: Callable = Callable() ## tests only: (url, key) -> {ok, message, code} in place of the real request (a pairing code cannot name localhost, where a stub server would be)

func test_server(url: String, key: String) -> Dictionary:
	## {ok, message, code}: asks /health with the key (server_probe.gd).
	if test_server_override.is_valid():
		return await test_server_override.call(url, key)
	var probe := ServerProbe.new()
	add_child(probe)
	var result: Dictionary = await probe.check(url, key)
	probe.queue_free()
	return result


func unload_model() -> void:
	## Empties the world of what was loaded (the same clean-up _show_model() does before it puts a new model in), for a server switch.
	_appearance_tool.forget()
	scenes_tool.forget()
	_appearance_tool.world_root = ""
	room_manager.on_model_replaced(false)
	command_stack.clear()
	design_table.on_model_replaced()
	_mates_tool.clear_picks()
	_section_tool.reset()
	design_table.tree.mark_stale()
	_assembly_tree_window.mark_stale()
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		hand.reset_interaction()
	for old in assembly_root.get_children():
		assembly_root.remove_child(old)
		old.queue_free()
	_part_count = 0
	_resolved_part_id = ""
	_native_extras.clear()
	visibility_ruled_parts.clear()
	native_file_path = ""
	_load_summary = ""
	mark_clean()


func _start_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		get_viewport().use_xr = true
		# The headset runtime sets the pace. Vsync on the desktop mirror window would make
		# every frame also wait for the monitor's refresh, which can cap a 90 Hz headset
		# at about half rate (the classic Godot XR "stuck at 45-50 fps" trap).
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		print("DIDSA VR: OpenXR initialised, headset active.")
	else:
		push_warning("DIDSA VR: OpenXR not initialised — running as a flat desktop preview. On Quest this should initialise automatically; on desktop it's expected unless a PCVR runtime (e.g. Virtual Desktop) is actively streaming to a headset right now.")
		_spawn_desktop_camera()


func _spawn_desktop_camera() -> void:
	# XRCamera3D only drives the viewport once OpenXR is actually tracking a
	# headset — without one, nothing is set as the active camera and the
	# flat preview just renders blank even though the scene loaded fine.
	# This gives the desktop-preview path something to look through,
	# roughly aimed at spawn_position.
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = spawn_position + Vector3(0.0, 0.6, 2.2)
	camera.look_at(spawn_position, Vector3.UP)
	camera.current = true


func _begin_import() -> void:
	if not FileAccess.file_exists(native_file_path):
		if part_id_override.is_empty():
			_set_status("No file at %s and no part_id_override set — nothing to load." % native_file_path)
			return
		# No native file to import: assume the part is already loaded in the
		# backend's "default" session by some other means, and go straight
		# to the mesh fetch (the old, manual-part-id behaviour).
		_resolved_part_id = part_id_override
		_download_started_ms = Time.get_ticks_msec()
		_load_busy = true # released by _on_mesh_completed()
		_fetch_mesh()
		return

	var composed := compose_native(native_file_path, _reference_choices.get(native_file_path, {})) # the files its occurrences reference, folded in (native_compose.gd)
	if not composed["ok"]:
		_set_status(composed["error"])
		return
	var raw_text: String = composed["text"]
	var parsed = composed["parsed"]
	_startup_compose_note = NativeCompose.unresolved_note(composed)
	_startup_composed = composed

	var document_dict: Dictionary = parsed.get("document", {})
	var root_part_id: String = str(document_dict.get("root_part_id", ""))
	if not part_id_override.is_empty():
		root_part_id = part_id_override
	if root_part_id.is_empty():
		_set_status("File has no document.root_part_id and no part_id_override was given.")
		return
	_resolved_part_id = root_part_id
	_remember_native_extras(parsed)

	_set_status("Importing %s (part %s) into the backend..." % [native_file_path.get_file(), _resolved_part_id])
	_import_started_ms = Time.get_ticks_msec()

	var url := "%s%s/import/native" % [backend_url, API_PREFIX]
	var headers := BackendSession.headers(api_key, true)
	_load_busy = true # released by _on_import_completed() (on failure) or _on_mesh_completed()
	var error := http_request.request(url, headers, HTTPClient.METHOD_POST, raw_text)
	if error != OK:
		_load_busy = false
		_set_status("Import request failed to start (error %d)" % error)


func _on_import_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# First completion this session is always the import call; disconnect
	# and hook up the mesh-fetch handler for the second call so the same
	# HTTPRequest node can be reused sequentially.
	http_request.request_completed.disconnect(_on_import_completed)

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_load_busy = false
		_set_status("Import failed: %s" % _http_error_text(response_code, result, body))
		push_error("DIDSA VR: /import/native failed: result=%d code=%d body=%s" % [result, response_code, body.get_string_from_utf8()])
		return

	_set_status("Imported. Fetching assembly mesh...")
	_download_started_ms = Time.get_ticks_msec()
	http_request.request_completed.connect(_on_mesh_completed)
	_fetch_mesh()


func _fetch_mesh() -> void:
	var url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [
		backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()
	]
	if tier != "":
		url += "&tier=%s" % tier
	var headers := BackendSession.headers(api_key)
	var error := http_request.request(url, headers, HTTPClient.METHOD_GET)
	if error != OK:
		_set_status("Mesh request failed to start (error %d)" % error)


func _on_mesh_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_load_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_set_status("Mesh load failed: %s" % _http_error_text(response_code, result, body))
		push_error("DIDSA VR: assembly-mesh.glb fetch failed: result=%d code=%d" % [result, response_code])
		return

	_parse_started_ms = Time.get_ticks_msec()
	var download_ms := _parse_started_ms - _download_started_ms
	_set_status("Downloaded %d KB, parsing glTF..." % int(body.size() / 1024.0))
	if not _show_model(body, "", spawn_scale):
		return

	var import_ms := (_download_started_ms - _import_started_ms) if _import_started_ms > 0 else 0
	_load_summary = "load: import %d ms, download %d ms (%d KB), parse %d ms" % [
		import_ms, download_ms, int(body.size() / 1024.0), Time.get_ticks_msec() - _parse_started_ms
	]
	print("DIDSA VR: ", _load_summary)
	_note_references(native_file_path, _startup_composed)
	_set_status("Loaded %d part mesh(es). Grip a part to grab it.%s" % [_part_count, _startup_compose_note])


## source_format string for each extension the backend's ImportSourceFormat
## enum accepts (backend/app/document/models.py) — "step"/"stl"/"obj" go
## through the backend's importer; glb/gltf load straight into Godot with no
## backend round trip at all (see load_glb_file()).
const _BACKEND_IMPORT_FORMATS := {"step": "step", "stp": "step", "stl": "stl", "obj": "obj"}
const _NATIVE_FORMATS := ["didsa", "didsaprt", "didsacad"] ## a plain JSON native save/export, any of the extensions it has had (current first; native_compose.gd) — same file, no format difference.

func list_model_files() -> PackedStringArray:
	## Model files the tablet's Files tab offers: res://models (next to the
	## project, for running from the editor), user://models (which also
	## works in an exported build), and the Settings page's own project
	## folder if one's been set (an arbitrary absolute path — e.g. a shared
	## network mount — DirAccess.open() isn't limited to res://user://).
	## .glb/.gltf load locally; .step/.stp/.stl/.obj need a configured
	## backend (see load_model_file()); .didsa/.DIDSAprt also need one
	## (open_native_file()/add_component_file()).
	var found := PackedStringArray()
	var extensions := ["glb", "gltf"] + _NATIVE_FORMATS + _BACKEND_IMPORT_FORMATS.keys()
	var dirs := ["res://models", "user://models"]
	if not _settings.project_folder.is_empty():
		dirs.append(_settings.project_folder)
	for dir_path in dirs:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			continue
		for file_name in dir.get_files():
			if file_name.get_extension().to_lower() in extensions:
				found.append(dir_path.path_join(file_name))
	return found


func load_model_file(path: String) -> void:
	## Dispatches on extension: a bare .glb/.gltf loads straight from disk;
	## .didsa/.DIDSAprt is a full-replace open of a different native file at
	## runtime (open_native_file()); .step/.stp/.stl/.obj need the backend's
	## /import-features (it's the only thing that can decode them into
	## geometry Godot can render).
	var ext := path.get_extension().to_lower()
	if ext in ["glb", "gltf"]:
		load_glb_file(path)
	elif ext in _NATIVE_FORMATS:
		open_native_file(path)
	elif ext in _BACKEND_IMPORT_FORMATS:
		_import_external_file(path, _BACKEND_IMPORT_FORMATS[ext])
	else:
		_set_status("Don't know how to load %s (extension .%s)" % [path.get_file(), ext])


var _native_root_id_cache: Dictionary = {} ## path -> {"mtime": int, "id": String}

func native_file_root_part_id(path: String) -> String:
	## The root Part id a native .didsa/.DIDSAprt file would load as (its
	## document.root_part_id, else its first Part — the backend's own fallback),
	## or "" if unreadable. Quiet (no status message): the Files tab uses it to
	## hide "Add" on the file that IS the loaded root, since the backend rejects
	## that with 422 "Cannot insert a Part into itself". Cached per file mtime.
	var mtime := FileAccess.get_modified_time(path)
	var cached = _native_root_id_cache.get(path)
	if cached != null and cached["mtime"] == mtime:
		return cached["id"]
	var found := ""
	if not FileAccess.file_exists(path):
		return found
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary and parsed.get("document") is Dictionary:
		var document: Dictionary = parsed["document"]
		found = str(document.get("root_part_id", ""))
		if found.is_empty() and document.get("parts") is Array and not (document["parts"] as Array).is_empty():
			var first = document["parts"][0]
			if first is Dictionary:
				found = str(first.get("id", ""))
	_native_root_id_cache[path] = {"mtime": mtime, "id": found}
	return found


func native_search_dirs() -> Array:
	## Where a native file's `external_ref`s are looked for after its own folder: the project folder, then the models folders.
	var dirs := []
	if not _settings.project_folder.is_empty():
		dirs.append(_settings.project_folder)
	dirs.append_array(["res://models", "user://models"])
	return dirs


func compose_native(path: String, choices: Dictionary = {}) -> Dictionary:
	## `path` with every file its occurrences reference folded in, ready to POST (native_compose.gd's compose()); `choices` are the
	## user's picks for moved / missing references (reference_review()).
	return NativeCompose.compose(path, native_search_dirs(), choices)


# --- Finding moved files (DIDSA-CAD docs/moved-files-scope.md, F2) ------------------------------------------------------

func _note_references(path: String, composed: Dictionary) -> void:
	## After an open: what native_compose.gd found in new places and what it couldn't, for Files > References. A path corrected by id
	## is an unsaved change (the next save writes it), not something changed on disk behind the user's back.
	if _reference_review.get("root", "") != path:
		_references_left.clear()
	_reference_review = {"root": path, "relinked": composed.get("relinked", []), "review": composed.get("review", []), "bases": composed.get("bases", [])}
	if not _reference_review["relinked"].is_empty():
		mark_dirty()
		_dirty_from_relink = true
	references_changed.emit()


func reference_review() -> Dictionary:
	## {root, relinked, review (minus the ones left missing), bases}: see native_compose.gd's compose().
	var open: Array = []
	for item in _reference_review.get("review", []):
		if not _references_left.has(item["key"]):
			open.append(item)
	return {"root": _reference_review.get("root", ""), "relinked": _reference_review.get("relinked", []), "review": open, "bases": _reference_review.get("bases", [])}


func choose_reference(key: String, file: String) -> void:
	## Files > References: use `file` for the reference `key` and open the file again with it (a full re-open, as Open does). When the
	## only unsaved change is a corrected path from that same open, nothing is lost, so it doesn't ask.
	var root: String = _reference_review.get("root", "")
	if root == "":
		return
	var picks: Dictionary = _reference_choices.get(root, {})
	picks[key] = file
	_reference_choices[root] = picks
	if document_dirty and _dirty_from_relink:
		mark_clean()
	open_native_file(root)


func leave_reference_missing(key: String) -> void:
	_references_left[key] = true
	references_changed.emit()


func reference_files() -> Array:
	## Locate...: every native file in the folders the opened file's references are looked for in ([{path, file, part_id}]).
	return NativeCompose.FileIndex.build(_reference_review.get("bases", []))


func open_native_file(path: String) -> void:
	if not confirm_discard("Open " + path.get_file(), open_native_file.bind(path)):
		return
	if not _claim_load("Open"):
		return
	await _open_native_file_impl(path)
	_load_busy = false


func _open_native_file_impl(path: String) -> void:
	## Files tab "Open": a full-replace load of a different native .didsa/
	## .DIDSAprt file at runtime — mirrors _begin_import()'s startup flow
	## (import, then fetch+render), just callable at any time and from an
	## arbitrary path/root_part_id instead of the fixed native_file_path
	## this scene started with. Closes the first half of the "no in-VR way
	## to open a different native file" gap — see docs/status.md's "Real-
	## headset testing round 2" (mates blocker). The other half is
	## add_component_file() below, for adding rather than replacing.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("Open needs a backend (see secrets.cfg.example).")
		return
	var composed := compose_native(path, _reference_choices.get(path, {})) # the files its occurrences reference, folded in (native_compose.gd)
	if not composed["ok"]:
		_set_status(composed["error"])
		return
	var parsed: Dictionary = composed["parsed"]
	var raw_text: String = composed["text"] # the file's own text when nothing was referenced (re-serialising `parsed` would turn every integer into a float)
	var document_dict: Dictionary = parsed.get("document", {})
	var root_part_id: String = str(document_dict.get("root_part_id", ""))
	if root_part_id.is_empty():
		_set_status("%s has no document.root_part_id — can't tell which Part to load." % path.get_file())
		return

	var req := HTTPRequest.new() # a separate node from http_request, which is spoken for by the startup import chain
	add_child(req)
	var headers := BackendSession.headers(api_key, true)
	_set_status("Importing %s (part %s)..." % [path.get_file(), root_part_id])
	req.request("%s%s/import/native" % [backend_url, API_PREFIX], headers, HTTPClient.METHOD_POST, raw_text)
	var import_result: Array = await req.request_completed
	if _parse_import_response(import_result, "import %s" % path.get_file(), req) == null:
		return

	_resolved_part_id = root_part_id
	_remember_native_extras(parsed)
	_set_status("Imported. Fetching assembly mesh...")
	var mesh_url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [
		backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()
	]
	if tier != "":
		mesh_url += "&tier=%s" % tier
	var mesh_result: Array = await _get_mesh_result(req, mesh_url)
	req.queue_free()
	var mesh_result_code: int = mesh_result[0]
	var mesh_response_code: int = mesh_result[1]
	var mesh_body: PackedByteArray = mesh_result[3]
	if mesh_result_code != HTTPRequest.RESULT_SUCCESS or mesh_response_code != 200:
		_set_status("Mesh load for %s failed: %s" % [path.get_file(), _http_error_text(mesh_response_code, mesh_result_code, mesh_body)])
		return
	if not _show_model(mesh_body, "", spawn_scale):
		return
	_note_references(path, composed)
	RecentFile.remember(path)
	_set_status("Opened %s: %d part mesh(es).%s" % [path.get_file(), _part_count, NativeCompose.unresolved_note(composed)])


func add_component_file(path: String) -> void:
	var room: Node = room_manager.focus_room()
	if room != null:
		await room_manager.add_file_to_room(room, path) # standing in an Assembly Room: the file is added to THAT room's assembly
		return
	if not _claim_load("Add"):
		return
	await _add_component_file_impl(path)
	_load_busy = false


func _add_component_file_impl(path: String) -> void:
	## Files tab "Add": merges a second native file's own Part into the
	## *currently loaded* assembly's root Part as a new Occurrence, via the
	## backend's POST /parts/{root_id}/add-component
	## (backend/app/document/add_component.py, ported from the Flutter
	## client's own add_component.dart) — unlike open_native_file() above,
	## this does NOT replace the loaded scene; it adds to the live session
	## and re-fetches the assembly mesh to show the result. Needs a
	## currently backend-loaded assembly (current_root_part_id() non-empty)
	## — there's nothing to add an Occurrence onto otherwise. This is what
	## finally gives the Mates tool real Occurrences to test against on a
	## single-Part test file — see docs/status.md's "Real-headset testing
	## round 2" for the blocker this closes.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("Add needs a backend (see secrets.cfg.example).")
		return
	if _resolved_part_id.is_empty():
		_set_status("Load a backend-hosted assembly first — nothing to add %s onto." % path.get_file())
		return
	var composed := compose_native(path) # a sub-assembly file brings the files it references (native_compose.gd)
	if not composed["ok"]:
		_set_status(composed["error"])
		return
	var component_text: String = composed["text"]
	var e = room_manager.edit_api()
	if e != null:
		var refusal: String = await e.file_conflict(_resolved_part_id, component_text) # (the server only checks the file's root; see room_edit.gd)
		if refusal != "":
			_set_status(refusal)
			return

	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key, true)
	_set_status("Adding %s to the assembly..." % path.get_file())
	req.request(
		"%s%s/parts/%s/add-component" % [backend_url, API_PREFIX, _resolved_part_id], headers,
		HTTPClient.METHOD_POST, '{"component": %s}' % component_text # the file's own text (or native_compose.gd's): JSON.stringify would turn every integer into a float
	)
	var add_result: Array = await req.request_completed
	if _parse_import_response(add_result, "add %s to the assembly" % path.get_file(), req) == null:
		return

	_set_status("Added. Refreshing assembly mesh...")
	var mesh_url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [
		backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()
	]
	if tier != "":
		mesh_url += "&tier=%s" % tier
	var mesh_result: Array = await _get_mesh_result(req, mesh_url)
	req.queue_free()
	var mesh_result_code: int = mesh_result[0]
	var mesh_response_code: int = mesh_result[1]
	var mesh_body: PackedByteArray = mesh_result[3]
	if mesh_result_code != HTTPRequest.RESULT_SUCCESS or mesh_response_code != 200:
		_set_status("Mesh refresh after adding %s failed: %s" % [path.get_file(), _http_error_text(mesh_response_code, mesh_result_code, mesh_body)])
		return
	if not _show_model(mesh_body, "", spawn_scale):
		return
	mark_dirty() # a component was added to the live document: a save would now differ from the file it came from
	_set_status("Added %s. %d part mesh(es) now in the assembly." % [path.get_file(), _part_count])


var _reloading_world := false ## reload_world_model() is swapping the same document's model: open Assembly Rooms stay open


func reload_world_model(dirty: bool = true) -> bool:
	## Fetches the loaded root's mesh again and shows it, keeping where the user has put the world (position, turn, scale). For when the document
	## changed under the world without the world doing it (parts added to or deleted from a sub-assembly in a room, a delete from the tree): the
	## world's own copies are out of date. What it costs: the undo history (the parts it pointed at are rebuilt), and any open room (its hidden copy of
	## the world is rebuilt too). The unsaved-changes flag is raised if `dirty`.
	if backend_url.is_empty() or api_key.is_empty() or _resolved_part_id.is_empty():
		return false
	if not _claim_load("reload"):
		return false
	var pose := assembly_root.transform
	var req := HTTPRequest.new()
	add_child(req)
	var url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [backend_url, API_PREFIX, _resolved_part_id, str(quality), str(include_hidden).to_lower()]
	if tier != "":
		url += "&tier=%s" % tier
	var result: Array = await _get_mesh_result(req, url)
	req.queue_free()
	var shown := false
	if result[0] == HTTPRequest.RESULT_SUCCESS and int(result[1]) == 200:
		_reloading_world = true
		shown = _show_model(result[3], "", spawn_scale)
		_reloading_world = false
		if shown:
			assembly_root.transform = pose
			room_manager.reseed_rooms()
	else:
		_set_status("Couldn't refresh the world after the change: %s" % _http_error_text(int(result[1]), int(result[0]), result[3]))
	_load_busy = false
	if shown and dirty:
		mark_dirty()
	return shown


func load_glb_file(path: String, run_after_discard: Callable = Callable()) -> bool:
	## Load a bare .glb/.gltf straight from disk — no backend round trip. True if it is now what is shown. `run_after_discard` is what
	## "Discard and continue" runs if unsaved changes stop it (default: this load again); the landing passes its own demo placing, so the demo
	## is still placed full size or on the desk after a discard.
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return false
	if not confirm_discard("Open " + path.get_file(), run_after_discard if run_after_discard.is_valid() else load_glb_file.bind(path)):
		return false
	var started_ms := Time.get_ticks_msec()
	var bytes := FileAccess.get_file_as_bytes(path)
	if not _show_model(bytes, path.get_base_dir(), local_glb_scale, true):
		return false
	document_is_demo = path.begins_with("res://demo/")
	RecentFile.remember(path)
	_load_summary = "load: %s, %d KB, %d ms" % [path.get_file(), int(bytes.size() / 1024.0), Time.get_ticks_msec() - started_ms]
	print("DIDSA VR: ", _load_summary)
	_set_status("Loaded %s: %d part mesh(es)." % [path.get_file(), _part_count])
	return true


func _import_external_file(path: String, source_format: String) -> void:
	if not confirm_discard("Open " + path.get_file(), _import_external_file.bind(path, source_format)):
		return
	if not _claim_load("the import"):
		return
	await _import_external_file_impl(path, source_format)
	_load_busy = false


func _import_external_file_impl(path: String, source_format: String) -> void:
	## STEP/STL/OBJ, milestone 1's last "done when" item: the backend has no
	## bare "view this file" endpoint for these, so this creates a fresh Part
	## (POST /parts), imports the file into it as a fixed Body
	## (POST /parts/{id}/import-features), then fetches and renders it the
	## same way as any other backend part (GET .../assembly-mesh.glb) —
	## mirrors _begin_import()/_fetch_mesh()'s two-step flow, just starting
	## from a local file instead of a native document, and with a "create
	## part" step first since there's no existing part to import into.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("%s needs a backend (see secrets.cfg.example) — STEP/STL/OBJ can't be read without one." % path.get_file())
		return
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return

	var started_ms := Time.get_ticks_msec()
	_set_status("Reading %s..." % path.get_file())
	var bytes := FileAccess.get_file_as_bytes(path)
	var data_b64 := Marshalls.raw_to_base64(bytes)

	var req := HTTPRequest.new() # a separate node from http_request, which is spoken for by the startup import chain
	add_child(req)
	var headers := BackendSession.headers(api_key, true)

	_set_status("Creating a part for %s..." % path.get_file())
	# A clean document first: POST /parts only ever ADDS, so without this every import in one session piled another part onto
	# the same document (the bug the flat app fixed with POST /document/new), and a later Save exported the whole pile. What is
	# shown is replaced by the imported part anyway, so this matches what you see.
	req.request(backend_url + API_PREFIX + "/new", headers, HTTPClient.METHOD_POST, "{}")
	var cleared_result: Array = await req.request_completed
	if _parse_import_response(cleared_result, "start a fresh document for %s" % path.get_file(), req) == null:
		return
	_native_extras.clear()
	visibility_ruled_parts.clear()
	native_file_path = ""
	req.request(backend_url + API_PREFIX + "/parts", headers, HTTPClient.METHOD_POST, JSON.stringify({"name": path.get_file().get_basename()}))
	var create_result: Array = await req.request_completed
	var part_json = _parse_import_response(create_result, "create a part for %s" % path.get_file(), req)
	if part_json == null:
		return
	var new_part_id: String = part_json.get("id", "")
	if new_part_id.is_empty():
		_set_status("Create-part response for %s had no id." % path.get_file())
		req.queue_free()
		return
	_resolved_part_id = new_part_id # so a later Files-tab "Add" has something to add onto, same as a native open

	_set_status("Importing %s (part %s)..." % [path.get_file(), new_part_id])
	req.request(
		backend_url + API_PREFIX + "/parts/%s/import-features" % new_part_id, headers, HTTPClient.METHOD_POST,
		JSON.stringify({"source_format": source_format, "data_base64": data_b64})
	)
	var import_result: Array = await req.request_completed
	if _parse_import_response(import_result, "import %s into part %s" % [path.get_file(), new_part_id], req) == null:
		return

	_set_status("Imported. Fetching mesh...")
	var mesh_url := "%s%s/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=false" % [backend_url, API_PREFIX, new_part_id, str(quality)]
	var mesh_result: Array = await _get_mesh_result(req, mesh_url)
	req.queue_free()
	var mesh_result_code: int = mesh_result[0]
	var mesh_response_code: int = mesh_result[1]
	var mesh_body: PackedByteArray = mesh_result[3]
	if mesh_result_code != HTTPRequest.RESULT_SUCCESS or mesh_response_code != 200:
		_set_status("Mesh fetch for %s failed: %s" % [path.get_file(), _http_error_text(mesh_response_code, mesh_result_code, mesh_body)])
		return

	_set_status("Downloaded %d KB, parsing glTF..." % int(mesh_body.size() / 1024.0))
	if not _show_model(mesh_body, "", spawn_scale): # backend units are mm regardless of the source format — spawn_scale, not local_glb_scale
		return
	_load_summary = "load: %s (%s, via backend), %d KB, %d ms" % [path.get_file(), source_format, int(mesh_body.size() / 1024.0), Time.get_ticks_msec() - started_ms]
	print("DIDSA VR: ", _load_summary)
	_set_status("Loaded %s: %d part mesh(es)." % [path.get_file(), _part_count])


func _http_error_text(response_code: int, result_code: int, body: PackedByteArray) -> String:
	## "HTTP 422 (result 0): Cannot insert a Part into itself" — the backend's
	## own FastAPI `detail` is what says WHY, and the tablet's Files status
	## label is the only place it can be read from inside a headset.
	var text := "HTTP %d (result %d)" % [response_code, result_code]
	if body.size() > 0:
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if parsed is Dictionary and parsed.has("detail"):
			var detail = parsed["detail"]
			text += ": %s" % (detail if detail is String else JSON.stringify(detail))
	return text


func _get_mesh_result(req: HTTPRequest, url: String) -> Array:
	## GETs an assembly-mesh.glb, retrying ONCE after a 5xx (the backend keeps a
	## single global in-memory Document, so a request that overlaps another
	## client's import/add can 500 transiently). The failing body is logged so
	## a repeat is diagnosable from the console.
	var result: Array = []
	for attempt in 2:
		req.request(url, BackendSession.headers(api_key), HTTPClient.METHOD_GET)
		result = await req.request_completed
		if attempt == 0 and result[0] == HTTPRequest.RESULT_SUCCESS and int(result[1]) >= 500:
			push_error("DIDSA VR: assembly-mesh.glb fetch got HTTP %d, retrying once: %s" % [result[1], (result[3] as PackedByteArray).get_string_from_utf8().left(300)])
			await get_tree().create_timer(0.6).timeout
			continue
		break
	return result


func _claim_load(what: String) -> bool:
	## Open / Add / STEP-import each replace or mutate the backend's ONE global
	## Document across several awaited round trips, and each was an un-guarded
	## coroutine — a second tap (or a tap while the startup import was still in
	## flight) interleaved with the first and could 500 it or leave the session
	## in a state the client no longer matched (real-headset report: HTTP 500,
	## fixed by restarting). One at a time.
	if _load_busy:
		_set_status("Busy: still working on the previous file — try %s again in a moment." % what)
		return false
	_load_busy = true
	return true


func _parse_import_response(result: Array, step_description: String, req: HTTPRequest):
	## Common HTTP-result/JSON-parse checking for _import_external_file()'s
	## three sequential calls. Returns the parsed JSON Dictionary on success,
	## or null (having already set the status and freed req) on any failure.
	var result_code: int = result[0]
	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS or (response_code != 200 and response_code != 201):
		_set_status("Couldn't %s: %s" % [step_description, _http_error_text(response_code, result_code, body)])
		push_error("DIDSA VR: %s failed: result=%d code=%d body=%s" % [step_description, result_code, response_code, body.get_string_from_utf8()])
		req.queue_free()
		return null
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if parsed == null or not (parsed is Dictionary):
		_set_status("Couldn't parse the response for: %s" % step_description)
		req.queue_free()
		return null
	return parsed


func _show_model(glb_bytes: PackedByteArray, base_path: String, scale_value: float, pick_from_inside: bool = false) -> bool:
	## Parse glTF bytes and make them THE model, replacing whatever is loaded.
	## Returns false (with a status message) if it couldn't.
	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	var parse_error := gltf_document.append_from_buffer(glb_bytes, base_path, gltf_state)
	if parse_error != OK:
		_set_status("glTF parse failed (error %d)" % parse_error)
		push_error("DIDSA VR: glTF parse failed: %d" % parse_error)
		return false

	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		_set_status("glTF parsed but produced no scene.")
		return false
	document_is_demo = false # the old model is going; load_glb_file() sets this again for a demo
	MeshIdentity.tag_scene(gltf_state, scene) # occurrence/face identity for the mates/measure tools - see mesh_identity.gd
	_appearance_tool.forget() # the glb's materials are the looks now; the tool reads the lists again when it is next used
	scenes_tool.forget() # a shown scene's nodes are about to go
	_appearance_tool.world_root = _resolved_part_id

	# Nothing may still hold, or have selected, a part that's about to go —
	# and the undo/redo history can't point at nodes that are about to be freed.
	room_manager.on_model_replaced(_reloading_world) # rooms hold copies of parts of the model that is about to go (unless it is only being re-read)
	command_stack.clear()
	design_table.on_model_replaced() # the table's seated part is about to be freed with the rest
	_mates_tool.clear_picks()
	_section_tool.reset() # drops its stale per-part tracking before they're freed below; the gizmo/active state stay put — see that script's own reset() docstring
	design_table.tree.mark_stale() # the table's own copy of the tree, for the same reason
	_assembly_tree_window.mark_stale() # the Occurrence tree it's shown is about to point at parts that no longer exist — see that script's own mark_stale()
	for hand in [$XROrigin3D/LeftController, $XROrigin3D/RightController]:
		hand.reset_interaction()
	for old in assembly_root.get_children():
		assembly_root.remove_child(old)
		old.queue_free()

	assembly_root.add_child(scene)
	assembly_root.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_value), spawn_position)
	_two_hand.set_real_life_scale(scale_value)
	_two_hand.remember_home()
	if landing != null:
		landing.on_model_shown() # whatever loaded it, the landing is over

	_part_count = 0
	# The scene ROOT itself can be the mesh: a glTF whose only scene node is a
	# mesh (what most single-object OBJ/STL/glTF exports from other tools come
	# out as) is generated with that MeshInstance3D AS the root, and walking
	# only its descendants missed it — "Loaded ... 0 part mesh(es)", no group,
	# no collision, so it could be neither gripped nor laser-picked.
	var candidates: Array[Node] = _all_descendants(scene)
	candidates.push_front(scene)
	for node in candidates:
		if node is MeshInstance3D:
			node.add_to_group("grabbable_parts")
			node.create_trimesh_collision() # so controller.gd's laser-select can ray-test real geometry
			if pick_from_inside:
				_make_picks_double_sided(node)
			_part_count += 1
	# Which of these are grounded / mated (for is_locked()/constrained motion).
	# Fire and forget: it's a couple of GETs, and nothing in the scene waits on it.
	_mates_tool.refresh_state(_resolved_part_id)
	room_manager.index_world() # which sub-assembly each part is in (fire and forget; until it lands a grip takes single parts)
	view_modes.apply_all() # the saved view mode (edges / wireframe) for the parts that were just loaded
	mark_clean() # what is loaded is the baseline: nothing to lose yet
	restore_stale_mates()
	return true


# --- Unsaved changes -------------------------------------------------------------------

func mark_dirty() -> void:
	## An edit that a save would write. Set by the undo stack (moves, mates, colours...), by the design table (a feature, a value, a new
	## part, hide / show) and by adding a component; cleared by a save and by loading something (the loaded file is the new baseline).
	_dirty_from_relink = false
	if not document_dirty:
		document_dirty = true
		dirty_changed.emit(true)


func mark_clean() -> void:
	_discard_armed_for = ""
	_dirty_from_relink = false
	if document_dirty:
		document_dirty = false
		dirty_changed.emit(false)


func confirm_discard(what: String, run: Callable = Callable()) -> bool:
	## Ask before replacing the document. Clean: true at once. With unsaved edits the first call warns and returns false; the same
	## `what` again within DISCARD_CONFIRM_MS goes ahead and discards them. Different actions don't share a confirmation.
	## With `run` (the action itself, to call again) the warning is also a choice on the Files page: discard_and_continue() runs it,
	## save_and_continue() saves first, cancel_discard() drops it (owner's report, Oct 2026: a bare refusal read as an error).
	if not document_dirty or document_is_demo: # a demo is read-only and can't be saved offline: moving or painting it is not work to lose
		_clear_pending_discard()
		return true
	var now := Time.get_ticks_msec()
	if _discard_armed_for == what and now < _discard_armed_until_ms:
		_discard_armed_for = ""
		_clear_pending_discard()
		return true
	_discard_armed_for = what
	_discard_armed_until_ms = now + DISCARD_CONFIRM_MS
	if run.is_valid():
		_pending_discard = {"what": what, "run": run}
		discard_prompt_changed.emit()
		_set_status("You have unsaved changes that \"%s\" will lose. Discard them, save first, or cancel (%s)." % [what, "on the monolith" if landing != null and landing.is_active() else "Files page"])
	else:
		_set_status("You have unsaved changes. Save first (Files > Save as new file), or do \"%s\" again within a few seconds to discard them." % what)
	return false


func pending_discard() -> String:
	## What is waiting on "discard your unsaved changes?" ("Open bracket.didsa"), or "" for nothing.
	return str(_pending_discard.get("what", ""))


func discard_and_continue() -> void:
	## The user chose to lose the unsaved changes: run the waiting replace.
	if _pending_discard.is_empty():
		return
	var pending := _pending_discard
	_clear_pending_discard()
	_discard_armed_for = str(pending["what"])
	_discard_armed_until_ms = Time.get_ticks_msec() + DISCARD_CONFIRM_MS
	await (pending["run"] as Callable).call()


func save_and_continue() -> void:
	## Save as a new file first; only once that worked, run the waiting replace.
	if _pending_discard.is_empty():
		return
	var pending := _pending_discard
	if await save_native_snapshot() == "":
		return # the status line says why; the choice stays up
	if _pending_discard != pending:
		return # something else asked meanwhile
	_clear_pending_discard()
	await (pending["run"] as Callable).call()


func cancel_discard() -> void:
	_discard_armed_for = ""
	if not _pending_discard.is_empty():
		_set_status("Kept your unsaved changes; nothing was opened.")
	_clear_pending_discard()


func _clear_pending_discard() -> void:
	if _pending_discard.is_empty():
		return
	_pending_discard = {}
	discard_prompt_changed.emit()


# --- New assembly / new part -----------------------------------------------------------

func new_assembly(confirmed: bool = false) -> bool:
	## Files tab "New assembly": throws away what is loaded and starts an empty assembly (a fresh backend document with one empty
	## root part, so the design table's New part has somewhere to put parts). Needs the backend: a bare local file has no document
	## to start. True if it worked.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("New assembly needs a backend (see secrets.cfg.example).")
		return false
	if not confirmed and not confirm_discard("New assembly"):
		return false
	if not _claim_load("New assembly"):
		return false
	var ok := await _new_assembly_impl()
	_load_busy = false
	return ok


func _new_assembly_impl() -> bool:
	_set_status("Starting a new assembly...")
	var started: Dictionary = await NewDocument.new(Callable(design_table.api, "request")).start_assembly()
	if not started["ok"]:
		_set_status("Couldn't start a new assembly: %s" % started["error"])
		return false
	var root_id: String = started["root_id"]
	var mesh_path := "/document/parts/%s/assembly-mesh.glb?quality=%s&include_hidden=%s" % [root_id, str(quality), str(include_hidden).to_lower()]
	if tier != "":
		mesh_path += "&tier=%s" % tier
	var fetched: Dictionary = await design_table.api.fetch_bytes(mesh_path)
	if not fetched["ok"]:
		_set_status("The new assembly was made but its view failed: %s" % fetched["error"])
		return false
	var body: PackedByteArray = fetched["bytes"]
	_resolved_part_id = root_id # before _show_model: it refreshes the mates state for the part it is showing
	_native_extras.clear()
	visibility_ruled_parts.clear()
	native_file_path = "" # a save from here is named "assembly-vr-..." rather than after the file that was open before
	if not _show_model(body, "", spawn_scale):
		return false
	_set_status("New empty assembly. Open the design table and press New part.")
	return true


func refresh_assembly_tree() -> void:
	## The assembly changed under the Assembly Tree window (a part was added or taken off): its list is reloaded the next time
	## it is looked at, or now if it is open.
	_assembly_tree_window.mark_stale()


func add_blank_part(root_id: String, occurrence_id: String, local_pose: Transform3D) -> MeshInstance3D:
	## The arena node for a part that has no geometry yet (the design table's New part). The backend's glb has no mesh for an
	## empty part, so there is nothing to carry or seat; this stands in for it: a hidden-on-the-table placeholder box, tagged with
	## the occurrence it belongs to exactly like a loaded node, so the table's edit flow finds it. `blank` says it still is
	## only a placeholder: the first feature swaps the real mesh in (swap_part_mesh) and clears it.
	mark_dirty() # a new part is in the backend document
	var node := MeshInstance3D.new()
	node.mesh = blank_mesh()
	node.set_meta("occurrence_id", occurrence_id)
	node.set_meta("owner_part_id", root_id)
	node.set_meta("blank", true)
	node.set_meta("new_part", true)
	node.add_to_group("grabbable_parts")
	assembly_root.add_child(node)
	node.transform = local_pose
	_part_count += 1
	return node


static func blank_mesh() -> BoxMesh:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * BLANK_PART_SIZE_MM
	return box


# --- Saving ---------------------------------------------------------------------------
# DIDSA-CAD's backend holds the document in memory only and the client owns the files, so edits made in VR (or by the
# design table) exist nowhere on disk until this writes them. A SNAPSHOT of the whole session, in the same native format the
# flat app saves: its "bundle" shape (every Part in one file), which the flat app opens directly.

const _SNAPSHOT_SCHEMA_VERSION := 1

func _remember_native_extras(parsed: Dictionary) -> void:
	_native_extras.clear()
	visibility_ruled_parts.clear()
	for key in parsed:
		if key != "schema_version" and key != "document" and key != "sketches":
			_native_extras[key] = parsed[key]


func snapshot_path() -> String:
	## Where a snapshot is written: next to the Settings project folder if one is set, else user://models (which the Files tab
	## also scans, so it can be opened again), under a name that never overwrites the file the session came from.
	var dir := save_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var base := native_file_path.get_file().get_basename() if not native_file_path.is_empty() else "assembly"
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "-")
	return dir.path_join("%s-vr-%s.didsa" % [base, stamp])


func native_extras_to_add(exported: Dictionary) -> Dictionary:
	## The flat app's extra top-level keys from the file this session was opened from (the backend drops them on import) that
	## a save should write back, so saving from VR doesn't lose its hidden-feature or section state. Never a key the export
	## itself has.
	var out := {}
	for key in _native_extras:
		if not exported.has(key):
			out[key] = _native_extras[key]
	out.erase(STALE_MATES_KEY) # the live flags below replace whatever the file came with
	var stale: Array = stale_mate_occurrences()
	if not stale.is_empty() and not exported.has(STALE_MATES_KEY):
		out[STALE_MATES_KEY] = stale
	return out


func stale_mate_occurrences() -> Array:
	## The occurrence ids of the arena parts flagged "mates need redoing" (design_table/dirty_mates.gd), for a save to write as the VR-only
	## extra `vr_stale_mates` (the flat app ignores keys it does not know) so the flags survive a save and open.
	var out: Array = []
	for node in DirtyMates.dirty_nodes(get_tree()):
		var occurrence := str(node.get_meta("occurrence_id", ""))
		if occurrence != "" and not out.has(occurrence):
			out.append(occurrence)
	return out


func restore_stale_mates() -> void:
	## After a model is shown: flags the parts a saved file listed in `vr_stale_mates` (set by an earlier VR session that edited them).
	var listed = _native_extras.get(STALE_MATES_KEY, [])
	if not (listed is Array) or (listed as Array).is_empty():
		return
	for node in RoomRegistry.world_parts(get_tree()):
		if (listed as Array).has(str(node.get_meta("occurrence_id", ""))):
			DirtyMates.mark(node)


static func append_to_json_object(text: String, extras: Dictionary) -> String:
	## `text` (a JSON object, exactly as the backend wrote it) with `extras` added as further top-level keys. Done on the TEXT,
	## not by parsing and re-writing: Godot reads every JSON number as a float and would write `0` back as `0.0`, which the
	## backend refuses for the integer fields in sketches and mate references. "" if `text` isn't an object.
	var trimmed := text.strip_edges()
	if extras.is_empty():
		return trimmed
	if not trimmed.ends_with("}"):
		return ""
	var body := trimmed.substr(0, trimmed.length() - 1).strip_edges()
	var pieces: PackedStringArray = []
	for key in extras:
		pieces.append("%s: %s" % [JSON.stringify(str(key)), JSON.stringify(extras[key])])
	return "%s%s%s}" % [body, "" if body.ends_with("{") else ", ", ", ".join(pieces)]


func save_native_snapshot(path: String = "") -> String:
	## Writes the whole session (GET /document/export/native, no part_id) to a .didsa file. Returns the path written, or "" with
	## the reason in the status line. Coroutine.
	if backend_url.is_empty() or api_key.is_empty():
		_set_status("Saving needs a backend (see secrets.cfg.example).")
		return ""
	var target := path if not path.is_empty() else snapshot_path()
	var req := HTTPRequest.new()
	add_child(req)
	_set_status("Saving...")
	req.request("%s%s/export/native" % [backend_url, API_PREFIX], BackendSession.headers(api_key), HTTPClient.METHOD_GET)
	var result: Array = await req.request_completed
	req.queue_free()
	if result[0] != HTTPRequest.RESULT_SUCCESS or int(result[1]) != 200:
		_set_status("Couldn't save: %s" % _http_error_text(int(result[1]), int(result[0]), result[3]))
		return ""
	var text: String = (result[3] as PackedByteArray).get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary) or int(parsed.get("schema_version", 0)) != _SNAPSHOT_SCHEMA_VERSION:
		_set_status("Couldn't save: the backend sent something that isn't a native file.")
		return ""
	var out_text := append_to_json_object(text, native_extras_to_add(parsed))
	if out_text == "":
		_set_status("Couldn't save: the backend's file wasn't in the shape expected.")
		return ""
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		_set_status("Couldn't write %s (error %d)." % [target, FileAccess.get_open_error()])
		return ""
	file.store_string(out_text)
	file.close()
	_native_root_id_cache.erase(target)
	mark_clean()
	last_saved_path = target
	_set_status("Saved %s." % saved_location_text(target))
	return target


func saved_location_text(target: String) -> String:
	## "name.didsa in /full/folder": where a save really is. user:// is the app's own data folder (on a Quest, under Android/data/<app>/files,
	## which the Files app shows), so the full path is spelled out rather than left as user://.
	var dir := ProjectSettings.globalize_path(target.get_base_dir()) if target.begins_with("user://") or target.begins_with("res://") else target.get_base_dir()
	return "%s in %s" % [target.get_file(), dir]


func mesh_from_glb(glb_bytes: PackedByteArray) -> Dictionary:
	## A part's own assembly-mesh.glb as a mesh and the face / edge identity that goes with it: {ok, mesh (null if the part has no
	## geometry), metas: {face_ids, body_ids, topology}}. ok is false if the bytes are not a readable glb.
	var gltf_document := GLTFDocument.new()
	var gltf_state := GLTFState.new()
	if gltf_document.append_from_buffer(glb_bytes, "", gltf_state) != OK:
		return {"ok": false, "mesh": null, "metas": {}}
	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		return {"ok": false, "mesh": null, "metas": {}}
	MeshIdentity.tag_scene(gltf_state, scene)
	var candidates: Array[Node] = _all_descendants(scene)
	candidates.push_front(scene)
	var template: MeshInstance3D = null
	for node in candidates:
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			template = node
			break
	var metas := {}
	var mesh: Mesh = null
	if template != null:
		mesh = template.mesh
		for key in ["face_ids", "body_ids", "topology"]:
			if template.has_meta(key):
				metas[key] = template.get_meta(key)
	scene.free()
	return {"ok": true, "mesh": mesh, "metas": metas}


func swap_part_mesh(nodes: Array, glb_bytes: PackedByteArray) -> int:
	## The design table changed a part: puts its new mesh (and the face / edge identity that goes with it) on every arena node
	## in `nodes` — every placed instance of that part — leaving their poses, selection and the undo history alone (unlike
	## _show_model, which replaces everything). `glb_bytes` is the part's own assembly-mesh.glb: one node, in the part's own
	## frame, the same frame every instance's mesh is in. Returns how many nodes were updated.
	var parsed := mesh_from_glb(glb_bytes)
	if not parsed["ok"]:
		return 0
	if parsed["mesh"] == null:
		return _blank_out(nodes) # no geometry: a new part with nothing drawn yet, or any part whose last feature was deleted
	var updated := 0
	for node in nodes:
		if not is_instance_valid(node) or not (node is MeshInstance3D):
			continue
		var part := node as MeshInstance3D
		if part.has_meta("blank"):
			part.set_meta("blank", false) # a new part's placeholder is a real part from its first feature on
		part.mesh = parsed["mesh"]
		for key in ["face_ids", "body_ids", "topology"]:
			if (parsed["metas"] as Dictionary).has(key):
				part.set_meta(key, parsed["metas"][key])
			elif part.has_meta(key):
				part.remove_meta(key)
		for child in part.get_children():
			if child is StaticBody3D:
				part.remove_child(child)
				child.free()
		part.create_trimesh_collision()
		if face_highlight != null:
			face_highlight.invalidate(part)
		view_modes.apply_to(part) # the new shape's edges
		updated += 1
	if updated > 0:
		_appearance_tool.forget() # a painted face may have moved: its current index is read again
		_mates_tool.clear_picks() # face identities changed: a picked face may not exist any more
		_measure_tool.clear_picks()
	return updated


func hidden_feature_ids() -> Array:
	## The features hidden on the design table: the flat app's own `hidden_feature_ids` (a flat list of feature ids, kept with the
	## session's native extras so a save writes them back and the flat app reads them).
	return (_native_extras.get("hidden_feature_ids", []) as Array).duplicate()


func set_feature_hidden(feature_id: String, hidden: bool) -> void:
	var ids: Array = hidden_feature_ids()
	if hidden and not ids.has(feature_id):
		ids.append(feature_id)
	elif not hidden:
		ids.erase(feature_id)
	if ids.is_empty():
		_native_extras.erase("hidden_feature_ids")
	else:
		_native_extras["hidden_feature_ids"] = ids
	mark_dirty() # the hidden set is written into a save


func set_hidden_feature_ids(ids: Array, dirty := true) -> void:
	## Replaces the whole hidden list (a category button's batch edit, or the load rule, which is not an edit of the file: dirty = false).
	if ids.is_empty():
		_native_extras.erase("hidden_feature_ids")
	else:
		_native_extras["hidden_feature_ids"] = ids.duplicate()
	if dirty:
		mark_dirty()


func _blank_out(nodes: Array) -> int:
	## The part's glb has no geometry: a part made with the table's New part (nothing drawn on it yet, or its first feature taken back),
	## or ANY part whose last solid was deleted in the Build tree (the arena would otherwise keep showing the shape that is gone). Its node
	## goes back to the placeholder box, flagged blank.
	var updated := 0
	for node in nodes:
		if not is_instance_valid(node) or not (node is MeshInstance3D):
			continue
		var part := node as MeshInstance3D
		if not part.get_meta("blank", false):
			part.mesh = blank_mesh()
			part.set_meta("blank", true)
			for key in ["face_ids", "body_ids", "topology"]:
				if part.has_meta(key):
					part.remove_meta(key)
			for child in part.get_children():
				if child is StaticBody3D:
					part.remove_child(child)
					child.free()
			if face_highlight != null:
				face_highlight.invalidate(part)
			view_modes.apply_to(part)
		updated += 1
	return updated


func _make_picks_double_sided(part: MeshInstance3D) -> void:
	## Third-party meshes (a bare glTF/scan/converted file) often have flipped
	## winding or open surfaces, and a trimesh collider is one-sided by
	## default, so a laser from outside passed straight through them.
	## Backend-tessellated parts keep the proven one-sided behaviour (see the
	## BoxMesh-winding note in docs/status.md).
	for child in part.get_children():
		if child is StaticBody3D:
			for shape_owner in (child as StaticBody3D).get_children():
				if shape_owner is CollisionShape3D and (shape_owner as CollisionShape3D).shape is ConcavePolygonShape3D:
					((shape_owner as CollisionShape3D).shape as ConcavePolygonShape3D).backface_collision = true


func _all_descendants(root: Node) -> Array[Node]:
	var found: Array[Node] = []
	for child in root.get_children():
		found.append(child)
		found.append_array(_all_descendants(child))
	return found


func _set_status(text: String) -> void:
	print("DIDSA VR: ", text)
	status_text = text
	status_changed.emit(text)
