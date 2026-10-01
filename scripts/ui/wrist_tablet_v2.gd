extends Node3D
## The redesigned wrist tablet (see docs/wrist-tablet-redesign-plan.md). Same job and
## same public API as wrist_tablet.gd — setup(), is_open(), open_tablet(),
## close_tablet(), set_info() — so main.gd can build either (Main > use_new_tablet).
## It is only the 3D half: the UI is tablet_ui.gd (+ side_panel_ui.gd), plain 2D
## Controls that also run in a desktop window (the UI Lab); the laser handling is the
## shared laser_surface.gd; what the UI shows is data (tablet_registry.gd, filled by
## tablet_pages.gd); and "one mode tool at a time" is tool_manager.gd.
##
## What stays exactly as before: the tablet floats above the left wrist, is closed by
## default and NEVER opens by itself — shoot the small wrist icon with the right laser
## and pull the trigger to open it; the X (top right) closes it. Right-hand laser only.
##
## What's new in this node:
##  * a contextual list panel just outside the tablet's right edge, angled up toward
##    you (side_yaw_degrees / side_pitch_degrees: tune in the Inspector, headset-only
##    feel), shown only when the viewed tool has a list (mates, measurements, models,
##    undo history);
##  * a badge on the right hand showing the active mode tool (tool_badge.gd), visible
##    with the tablet closed — a mode tool keeps working then.

const TabletRegistry := preload("res://scripts/ui/tablet_registry.gd")
const ToolManager := preload("res://scripts/ui/tool_manager.gd")
const TabletPages := preload("res://scripts/ui/tablet_pages.gd")
const TabletUI := preload("res://scripts/ui/tablet_ui.gd")
const SidePanelUI := preload("res://scripts/ui/side_panel_ui.gd")
const LaserSurface := preload("res://scripts/ui/laser_surface.gd")
const ToolBadge := preload("res://scripts/ui/tool_badge.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"

@export var panel_size := Vector2(0.40, 0.26) ## metres. 2667 px/m, the same physical text size as the old 0.3375 m tablet.
@export var pixels_per_metre: float = 2667.0
@export var side_width: float = 0.17 ## metres, the contextual list panel
@export var side_gap: float = 0.012 ## metres between the tablet's right edge and the list panel
@export var side_yaw_degrees: float = -10.0 ## fans the list panel's outer edge up toward you
@export var side_pitch_degrees: float = 8.0 ## tips its far edge up toward you
@export var mount_position := Vector3(0.0, 0.06, 0.07) ## relative to the left controller: above and a little behind it
@export var mount_tilt_degrees: float = 0.0
@export var target_position := Vector3(0.0, 0.05, 0.122) ## the wrist icon, relative to the left controller
@export var target_radius: float = 0.035 ## metres; how generous the "shot" hit area is
@export var max_point_distance: float = 2.0
@export var click_action: String = "trigger_click"
@export var open_settle_seconds: float = 0.4 ## presses are ignored this long after opening: the laser is still resting where the icon was

var viewport_size := Vector2i.ZERO ## derived from panel_size * pixels_per_metre
var tokens: Resource
var registry
var manager
var pages
var ui: Control
var side_ui: Control
var surface ## LaserSurface for the tablet
var side_surface ## LaserSurface for the list panel
var badge: Node3D

var _left: XRController3D
var _right: XRController3D
var _camera: XRCamera3D
var _main: Node
var _viewport: SubViewport
var _quad: MeshInstance3D
var _side_pivot: Node3D
var _side_viewport: SubViewport
var _side_quad: MeshInstance3D
var _side_open := false
var _target: Node3D
var _target_materials: Array[StandardMaterial3D] = []
var _target_hover := false
var _last_target_hover := false
var _open := false
var _refresh_left := 0.0


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D, two_hand: Node, locomotion: Node, main: Node, command_stack = null, mates_tool: Node = null, colour_tool: Node = null, section_tool: Node = null, measure_tool: Node = null, assembly_tree_window: Node = null, calculator_window: Node = null, image_viewer_window: Node = null, browser_window: Node = null) -> void:
	_left = left
	_right = right
	_camera = camera
	_main = main
	tokens = load(THEME_PATH)
	viewport_size = Vector2i((panel_size * pixels_per_metre).round())

	registry = TabletRegistry.new()
	manager = ToolManager.new()
	manager.setup(registry)
	pages = TabletPages.new()
	pages.setup({
		"left": left, "right": right, "camera": camera, "two_hand": two_hand, "locomotion": locomotion,
		"main": main, "command_stack": command_stack, "mates_tool": mates_tool, "colour_tool": colour_tool,
		"section_tool": section_tool, "measure_tool": measure_tool, "assembly_tree_window": assembly_tree_window,
		"calculator_window": calculator_window, "image_viewer_window": image_viewer_window, "browser_window": browser_window,
		"dragging": func() -> bool: return surface != null and surface.dragging_slider(),
	}, tokens, manager)
	pages.register(registry)

	_build_main_panel(command_stack)
	_build_side_panel()
	_left.add_child(self)
	position = mount_position
	rotation_degrees = Vector3(-90.0 + mount_tilt_degrees, 0.0, 0.0) # quad faces +Z; this turns it to face up out of the wrist
	_build_target()
	_right.button_pressed.connect(_on_right_pressed)

	pages.toast.connect(ui.toast)
	ui.close_requested.connect(close_tablet)
	ui.selection_changed.connect(_refresh_side)
	badge = ToolBadge.new()
	_right.add_child(badge)
	badge.setup(manager, registry, tokens)
	visible = false


func is_open() -> bool:
	return _open


func open_tablet() -> void:
	_open = true
	visible = true
	surface.arm()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_main.set_measuring(true)
	pages.refresh()
	_refresh_side()


func close_tablet() -> void:
	_open = false
	visible = false
	surface.release_all()
	side_surface.release_all()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_set_side_open(false)
	_main.set_measuring(false)


func set_info(text: String) -> void:
	if pages:
		pages.set_info(text)


# --- Building ------------------------------------------------------------------

func _build_main_panel(command_stack) -> void:
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while open
	add_child(_viewport)
	ui = TabletUI.new()
	ui.size = Vector2(viewport_size)
	ui.setup(tokens, registry, manager, {"command_stack": command_stack, "settings_builder": pages.settings_page})
	_viewport.add_child(ui)
	var cursor := LaserSurface.make_cursor()
	ui.add_child(cursor)
	_quad = _make_quad(_viewport, panel_size)
	add_child(_quad)

	surface = LaserSurface.new()
	surface.setup(self, _viewport, _right, panel_size)
	surface.claim_first = true
	surface.settle_seconds = open_settle_seconds
	surface.max_point_distance = max_point_distance
	surface.click_action = click_action
	surface.cursor = cursor
	surface.scroll_target = ui.pages_scroll
	for slider in ui.sliders:
		surface.add_slider(slider)


func _build_side_panel() -> void:
	var side_size := Vector2(side_width, panel_size.y)
	var side_px := Vector2i((side_size * pixels_per_metre).round())
	_side_pivot = Node3D.new()
	add_child(_side_pivot)
	_side_pivot.position = Vector3(panel_size.x * 0.5 + side_gap, 0.0, 0.004)
	_side_pivot.rotation_degrees = Vector3(side_pitch_degrees, side_yaw_degrees, 0.0)
	_side_viewport = SubViewport.new()
	_side_viewport.size = side_px
	_side_viewport.transparent_bg = false
	_side_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_side_viewport)
	side_ui = SidePanelUI.new()
	side_ui.setup(tokens, Vector2(side_px))
	_side_viewport.add_child(side_ui)
	var cursor := LaserSurface.make_cursor()
	side_ui.add_child(cursor)
	_side_quad = _make_quad(_side_viewport, side_size)
	_side_quad.position = Vector3(side_width * 0.5, 0.0, 0.0) # hinged on its left edge
	_side_pivot.add_child(_side_quad)
	_side_pivot.visible = false

	side_surface = LaserSurface.new()
	side_surface.setup(_side_quad, _side_viewport, _right, side_size)
	side_surface.claim_first = true
	side_surface.max_point_distance = max_point_distance
	side_surface.click_action = click_action
	side_surface.cursor = cursor
	side_surface.scroll_target = side_ui.scroll


func _make_quad(viewport: SubViewport, size: Vector2) -> MeshInstance3D:
	var quad := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	quad.mesh = mesh
	return quad


func _build_target() -> void:
	# The wrist icon: a thin ring with a landscape rectangle inside it (a stylised
	# tablet), thin white lines like the rest of the app. Shooting it opens the tablet.
	_target = Node3D.new()
	_left.add_child(_target)
	_target.position = target_position
	var ring := TorusMesh.new()
	ring.inner_radius = 0.027
	ring.outer_radius = 0.031
	_add_target_mesh(ring)
	var half_width := 0.017
	var half_height := 0.011
	var bar_thickness := 0.0025
	var bar_height := 0.001
	for bar in [
		{"size": Vector3(half_width * 2.0 + bar_thickness, bar_height, bar_thickness), "pos": Vector3(0.0, 0.0, -half_height)},
		{"size": Vector3(half_width * 2.0 + bar_thickness, bar_height, bar_thickness), "pos": Vector3(0.0, 0.0, half_height)},
		{"size": Vector3(bar_thickness, bar_height, half_height * 2.0 + bar_thickness), "pos": Vector3(-half_width, 0.0, 0.0)},
		{"size": Vector3(bar_thickness, bar_height, half_height * 2.0 + bar_thickness), "pos": Vector3(half_width, 0.0, 0.0)},
	]:
		var box := BoxMesh.new()
		box.size = bar["size"]
		_add_target_mesh(box).position = bar["pos"]


func _add_target_mesh(mesh: Mesh) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.8, 0.83, 0.87)
	mesh.material = mat
	_target_materials.append(mat)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	_target.add_child(instance)
	return instance


# --- Per frame -----------------------------------------------------------------------

func _process(delta: float) -> void:
	if _camera == null:
		return
	_target.visible = not _open
	_update_target_hover()
	surface.process(delta, _open)
	side_surface.process(delta, _open and _side_open)
	if not _open:
		return
	ui.tick(delta)
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = 0.25
		pages.refresh()
		_refresh_side()


func _update_target_hover() -> void:
	_target_hover = false
	var hit_distance := -1.0
	if not _open:
		var origin := _right.global_position
		var dir := -_right.global_transform.basis.z.normalized()
		var hits := Geometry3D.segment_intersects_sphere(origin, origin + dir * max_point_distance, _target.global_position, target_radius)
		if not hits.is_empty() and not _right.get_meta("ui_hover", false):
			_target_hover = true
			hit_distance = origin.distance_to(hits[0])
			_right.set_meta("ui_hover", true)
			_right.set_meta("ui_hit_distance", hit_distance)
	if _target_hover != _last_target_hover:
		_last_target_hover = _target_hover
		for mat in _target_materials:
			mat.albedo_color = Color(0.75, 0.85, 1.0) if _target_hover else Color(0.8, 0.83, 0.87) # a slight blue tint plus a swell on hover
		_target.scale = Vector3.ONE * (1.2 if _target_hover else 1.0)


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _target_hover and not _open:
		open_tablet()
		_right.trigger_haptic_pulse("haptic", 0.0, 0.6, 0.08, 0.0)


func _refresh_side() -> void:
	var src: Dictionary = ui.list_source() if ui else {}
	if src.is_empty() or not _open:
		_set_side_open(false)
		return
	side_ui.set_list(str(src["title"]), src["provider"].call(), str(src.get("empty", "")))
	_set_side_open(true)


func _set_side_open(on: bool) -> void:
	if on == _side_open:
		return
	_side_open = on
	_side_pivot.visible = on
	_side_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if not on:
		side_surface.release_all()
