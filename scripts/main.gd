extends Node3D
## Engine-choice spike: imports a saved DIDSA-CAD assembly file straight
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
@export var native_file_path: String = "res://assembly.didsa" ## The exported native file to import before loading.
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
const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")
const STALE_MATES_KEY := "vr_stale_mates" ## the native-file extra that carries the design table's "mates need redoing" flags
const DISCARD_CONFIRM_MS := 6000 ## how long a "this will discard your unsaved changes" warning stays armed for a second press
var last_saved_path := "" ## the .didsa the last save wrote
var document_dirty := false ## the session has edits (a move, a mate, a design-table feature, a new part...) that no save has written: anything that REPLACES the document asks first
var _discard_armed_for := ""
var _discard_armed_until_ms := 0
var _settings := preload("res://scripts/app_settings.gd").new() ## project folder + last-picked scene — see app_settings.gd
@onready var _world_environment: WorldEnvironment = $WorldEnvironment ## Light/Dark/Mid/Passthrough — see environment_manager.gd
const NewDocument := preload("res://scripts/design_table/new_document.gd") ## New assembly / New part: the backend sequences
const BLANK_PART_SIZE_MM := 100.0 ## the placeholder box a brand-new, still empty part stands in with (see add_blank_part())
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
var _colour_tool: Node
var _section_tool: Node
var _assembly_tree_window: Node
var _calculator_window: Node
var _image_viewer_window: Node
var _browser_window: Node
var design_table: Node ## milestone 2: the design table — see scripts/design_table/design_table.gd
var _worst_frame_ms := 0.0 ## longest frame since the readout last refreshed: steady ~22 ms = pacing/cap, spikes = hitches
var _perf_refresh_left := 0.0
var _import_started_ms := 0
var _download_started_ms := 0
var _parse_started_ms := 0
var _load_summary := ""
var _part_count := 0
var view_modes ## view_modes.gd: Shaded / Shaded + edges / Wireframe

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
	_add_face_highlight()
	_add_colour_tool()
	_add_section_tool()
	_add_view_modes() # after the section tool: its edge shader uses the section clip's global uniforms
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
	_colour_tool.document_changed.connect(mark_dirty)
	$XROrigin3D/LeftController.command_stack = command_stack
	$XROrigin3D/RightController.command_stack = command_stack
	$XROrigin3D/LeftController.mates_tool = _mates_tool
	$XROrigin3D/RightController.mates_tool = _mates_tool
	$XROrigin3D/LeftController.measure_tool = _measure_tool
	$XROrigin3D/RightController.measure_tool = _measure_tool
	$XROrigin3D/LeftController.colour_tool = _colour_tool
	$XROrigin3D/RightController.colour_tool = _colour_tool
	$XROrigin3D/LeftController.section_tool = _section_tool
	$XROrigin3D/RightController.section_tool = _section_tool
	$XROrigin3D/LeftController.laser_select_enabled = false # real-headset feedback: left trigger-select blocked left-hand locomotion (controller.gd's is_manipulating()) — grip-grab stays on both hands, left laser is freed up for a later tool (context menu, multi-select — not decided yet)
	$XROrigin3D/RightController.button_pressed.connect(_on_right_stick_click)
	_load_secrets()
	_mates_tool.configure_backend(backend_url, api_key)
	_measure_tool.configure_backend(backend_url, api_key)
	_colour_tool.configure_backend(backend_url, api_key)
	_assembly_tree_window.configure_backend(backend_url, api_key)
	design_table.configure_backend(backend_url, api_key)
	_browser_window.configure_relay(relay_url, relay_api_key)
	_start_xr()
	_world_environment.setup($DirectionalLight3D, xr_interface, get_viewport(), $Ground/MeshInstance3D.mesh.material as ShaderMaterial)
	_world_environment.apply_saved_scene(_settings.last_scene)
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


func _add_measure_tool() -> void:
	var measure := preload("res://scripts/measure_tool.gd").new()
	measure.name = "MeasureTool"
	add_child(measure)
	_measure_tool = measure


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


func _add_colour_tool() -> void:
	var colours := preload("res://scripts/colour_tool.gd").new()
	colours.name = "ColourTool"
	add_child(colours)
	_colour_tool = colours


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
	tablet.setup($XROrigin3D/LeftController, $XROrigin3D/RightController, $XROrigin3D/XRCamera3D, _two_hand, $XROrigin3D, self, command_stack, _mates_tool, _colour_tool, _section_tool, _measure_tool, _assembly_tree_window, _calculator_window, _image_viewer_window, _browser_window, design_table)
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
	_tool_wheel.set_size(_settings.wheel_size)
	_tool_wheel.set_enabled(_settings.wheel_enabled)
	_measure_dimensions = preload("res://scripts/measure_dimensions.gd").new()
	_measure_dimensions.name = "MeasureDimensions"
	add_child(_measure_dimensions)
	_measure_dimensions.setup(_measure_tool, $XROrigin3D/XRCamera3D)


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


func _arena_parts() -> Array:
	## The arena's parts, not counting the one sitting on the design table (hidden on purpose,
	## and not for hide / show / isolate to bring back).
	return get_tree().get_nodes_in_group("grabbable_parts").filter(func(p: Node) -> bool: return not p.has_meta("on_table"))


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
	var parts := _arena_parts()
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


# --- Environment (View > Environment tab): Light/Dark/Mid rendered presets
# plus Passthrough (OpenXR mixed reality) — see environment_manager.gd.

func available_scenes() -> Array[String]:
	return _world_environment.SCENES


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
		push_warning("DIDSA VR spike: couldn't parse %s" % secrets_file_path)
		return
	backend_url = config.get_value("backend", "url", backend_url)
	api_key = config.get_value("backend", "api_key", api_key)
	BackendSession.set_session_id(str(config.get_value("backend", "document_session", ""))) # optional: a fixed document session id (default: a fresh one per launch)
	relay_url = config.get_value("browser_relay", "url", relay_url)
	relay_api_key = config.get_value("browser_relay", "api_key", relay_api_key)


func _start_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		get_viewport().use_xr = true
		# The headset runtime sets the pace. Vsync on the desktop mirror window would make
		# every frame also wait for the monitor's refresh, which can cap a 90 Hz headset
		# at about half rate (the classic Godot XR "stuck at 45-50 fps" trap).
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		print("DIDSA VR spike: OpenXR initialised, headset active.")
	else:
		push_warning("DIDSA VR spike: OpenXR not initialised — running as a flat desktop preview. On Quest this should initialise automatically; on desktop it's expected unless a PCVR runtime (e.g. Virtual Desktop) is actively streaming to a headset right now.")
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

	var file := FileAccess.open(native_file_path, FileAccess.READ)
	var raw_text := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(raw_text)
	if parsed == null or not (parsed is Dictionary):
		_set_status("Couldn't parse %s as JSON — is it a real exported .didsa/.DIDSAprt file?" % native_file_path)
		return

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
		push_error("DIDSA VR spike: /import/native failed: result=%d code=%d body=%s" % [result, response_code, body.get_string_from_utf8()])
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
		push_error("DIDSA VR spike: assembly-mesh.glb fetch failed: result=%d code=%d" % [result, response_code])
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
	print("DIDSA VR spike: ", _load_summary)
	_set_status("Loaded %d part mesh(es). Grip a part to grab it." % _part_count)


## source_format string for each extension the backend's ImportSourceFormat
## enum accepts (backend/app/document/models.py) — "step"/"stl"/"obj" go
## through the backend's importer; glb/gltf load straight into Godot with no
## backend round trip at all (see load_glb_file()).
const _BACKEND_IMPORT_FORMATS := {"step": "step", "stp": "step", "stl": "stl", "obj": "obj"}
const _NATIVE_FORMATS := ["didsa", "didsaprt"] ## a plain JSON native save/export, either extension (see README) — same file, no format difference.

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


func _read_native_json(path: String) -> Variant:
	## Shared by open_native_file()/add_component_file(): reads and JSON-
	## parses a local native file, or null (having already set the status)
	## if it can't. Same parse this scene already does for native_file_path
	## at startup (_begin_import()), factored out so both new runtime paths
	## share it instead of duplicating the read-and-parse boilerplate.
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	var raw_text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(raw_text)
	if parsed == null or not (parsed is Dictionary):
		_set_status("Couldn't parse %s as JSON — is it a real exported .didsa/.DIDSAprt file?" % path.get_file())
		return null
	return parsed


func open_native_file(path: String) -> void:
	if not confirm_discard("Open " + path.get_file()):
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
	var parsed = _read_native_json(path)
	if parsed == null:
		return
	var raw_text := FileAccess.get_file_as_string(path) # sent AS IS: re-serialising `parsed` would turn every integer into a float
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
	_set_status("Opened %s: %d part mesh(es)." % [path.get_file(), _part_count])


func add_component_file(path: String) -> void:
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
	var parsed = _read_native_json(path)
	if parsed == null:
		return

	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key, true)
	_set_status("Adding %s to the assembly..." % path.get_file())
	req.request(
		"%s%s/parts/%s/add-component" % [backend_url, API_PREFIX, _resolved_part_id], headers,
		HTTPClient.METHOD_POST, '{"component": %s}' % FileAccess.get_file_as_string(path) # the file's own text: re-serialising `parsed` would turn every integer into a float
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


func load_glb_file(path: String) -> void:
	## Load a bare .glb/.gltf straight from disk — no backend round trip.
	if not FileAccess.file_exists(path):
		_set_status("No such file: %s" % path)
		return
	if not confirm_discard("Open " + path.get_file()):
		return
	var started_ms := Time.get_ticks_msec()
	var bytes := FileAccess.get_file_as_bytes(path)
	if not _show_model(bytes, path.get_base_dir(), local_glb_scale, true):
		return
	_load_summary = "load: %s, %d KB, %d ms" % [path.get_file(), int(bytes.size() / 1024.0), Time.get_ticks_msec() - started_ms]
	print("DIDSA VR spike: ", _load_summary)
	_set_status("Loaded %s: %d part mesh(es)." % [path.get_file(), _part_count])


func _import_external_file(path: String, source_format: String) -> void:
	if not confirm_discard("Open " + path.get_file()):
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
	print("DIDSA VR spike: ", _load_summary)
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
		push_error("DIDSA VR spike: %s failed: result=%d code=%d body=%s" % [step_description, result_code, response_code, body.get_string_from_utf8()])
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
		push_error("DIDSA VR spike: glTF parse failed: %d" % parse_error)
		return false

	var scene := gltf_document.generate_scene(gltf_state)
	if scene == null:
		_set_status("glTF parsed but produced no scene.")
		return false
	MeshIdentity.tag_scene(gltf_state, scene) # occurrence/face identity for the mates/measure tools - see mesh_identity.gd

	# Nothing may still hold, or have selected, a part that's about to go —
	# and the undo/redo history can't point at nodes that are about to be freed.
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
	view_modes.apply_all() # the saved view mode (edges / wireframe) for the parts that were just loaded
	mark_clean() # what is loaded is the baseline: nothing to lose yet
	restore_stale_mates()
	return true


# --- Unsaved changes -------------------------------------------------------------------

func mark_dirty() -> void:
	## An edit that a save would write. Set by the undo stack (moves, mates, colours...), by the design table (a feature, a value, a new
	## part, hide / show) and by adding a component; cleared by a save and by loading something (the loaded file is the new baseline).
	if not document_dirty:
		document_dirty = true
		dirty_changed.emit(true)


func mark_clean() -> void:
	_discard_armed_for = ""
	if document_dirty:
		document_dirty = false
		dirty_changed.emit(false)


func confirm_discard(what: String) -> bool:
	## Ask before replacing the document. Clean: true at once. With unsaved edits the first call says so (and what to do) and returns false;
	## the same `what` again within DISCARD_CONFIRM_MS goes ahead and discards them. Different actions don't share a confirmation.
	if not document_dirty:
		return true
	var now := Time.get_ticks_msec()
	if _discard_armed_for == what and now < _discard_armed_until_ms:
		_discard_armed_for = ""
		return true
	_discard_armed_for = what
	_discard_armed_until_ms = now + DISCARD_CONFIRM_MS
	_set_status("You have unsaved changes. Save first (Files > Save as new file), or do \"%s\" again within a few seconds to discard them." % what)
	return false


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
	var dir := _settings.project_folder if not _settings.project_folder.is_empty() else "user://models"
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
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
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
	print("DIDSA VR spike: ", text)
	status_text = text
