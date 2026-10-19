extends Node3D
## The redesigned wrist tablet (see docs/wrist-tablet-redesign-plan.md). Same job and
## same public API as wrist_tablet.gd — setup(), is_open(), open_tablet(),
## close_tablet(), set_info() — so main.gd can talk to it.
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
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"
const ACTIVE_LINGER_MS := 1000 ## keep rendering every frame this long after the last activity
const IDLE_REFRESH_SECONDS := 0.25 ## an idle open tablet re-renders this often (live labels never go more than this stale)

@export var panel_size := Vector2(0.40, 0.26) ## metres. 2667 px/m, the same physical text size as the old 0.3375 m tablet.
@export var pixels_per_metre: float = 2667.0
@export var side_width: float = 0.17 ## metres, the contextual list panel
@export var side_gap: float = 0.012 ## metres between the tablet's right edge and the list panel
@export var side_yaw_degrees: float = -5.0 ## swings the list panel's outer (right) edge towards you, hinged on the tablet's right edge
@export var side_pitch_degrees: float = 0.0 ## keep 0: any pitch stops the list panel's left edge being parallel to the tablet's right edge
@export var mount_position := Vector3(0.0, 0.125, 0.0875) ## relative to the left controller: the tablet's CENTRE. With the default 30 degree tilt this is the position that keeps its near (lower) edge where the flat tablet's was, so it hinges up from there
@export var mount_tilt_degrees: float = 30.0 ## tips the tablet towards you (its top edge away and up) so your wrist can stay neutral while reading; 0 = flat on the wrist
@export var target_position := Vector3(0.0, 0.05, 0.153) ## the wrist icon ("watch"), relative to the left controller: moved back (towards you) by half its own diameter
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
var _watch_ring: StandardMaterial3D
var _watch_icon: StandardMaterial3D
var _watch_face: StandardMaterial3D
var _watch_glow: StandardMaterial3D
var _watch_glow_mesh: MeshInstance3D
var _target_hover := false
var _last_target_hover := false
var _open := false
var _refresh_left := 0.0
var _quad_material: StandardMaterial3D
var _anim: Tween
var _activity_until_ms := 0
var _idle_left := 0.0
var _seen_revision := 0


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D, two_hand: Node, locomotion: Node, main: Node, command_stack = null, mates_tool: Node = null, appearance_tool: Node = null, section_tool: Node = null, measure_tool: Node = null, assembly_tree_window: Node = null, calculator_window: Node = null, image_viewer_window: Node = null, browser_window: Node = null, design_table: Node = null) -> void:
	_left = left
	_right = right
	_camera = camera
	_main = main
	tokens = load(THEME_PATH)
	_seen_revision = UiThemes.revision
	viewport_size = Vector2i((panel_size * pixels_per_metre).round())

	registry = TabletRegistry.new()
	manager = ToolManager.new()
	manager.setup(registry)
	pages = TabletPages.new()
	pages.setup({
		"left": left, "right": right, "camera": camera, "two_hand": two_hand, "locomotion": locomotion,
		"main": main, "command_stack": command_stack, "mates_tool": mates_tool, "appearance_tool": appearance_tool,
		"section_tool": section_tool, "measure_tool": measure_tool, "assembly_tree_window": assembly_tree_window,
		"calculator_window": calculator_window, "image_viewer_window": image_viewer_window, "browser_window": browser_window, "design_table": design_table,
		"dragging": func() -> bool: return surface != null and surface.dragging_slider(),
		"navigate": func(category_id: String) -> void: ui.select_category(category_id),
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
	ui.feedback.connect(func(event: String) -> void:
		UiFeedback.haptic(_right, event)
		UiFeedback.play(event, self)
	)
	ui.activity.connect(poke_render)
	manager.active_changed.connect(func(_id: String) -> void: poke_render())
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
	poke_render()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_main.set_measuring(true)
	pages.refresh()
	_refresh_side()
	_play_open()


func close_tablet() -> void:
	## Logically closed at once (no hover, no claim, nothing rendering); with motion on, the
	## panel itself shrinks away over ~150 ms before it is hidden.
	_open = false
	surface.release_all()
	side_surface.release_all()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_set_side_open(false)
	_main.set_measuring(false)
	UiFeedback.play("close", self)
	_play_stow()


func poke_render() -> void:
	## Something on screen is about to change: render every frame for a moment.
	_activity_until_ms = Time.get_ticks_msec() + ACTIVE_LINGER_MS


# --- Open / stow animation ----------------------------------------------------------

func _play_open() -> void:
	if _anim and _anim.is_valid():
		_anim.kill()
	var d: float = tokens.duration(tokens.anim_slow * 0.9)
	if d <= 0.0:
		scale = Vector3.ONE
		_set_alpha(1.0)
		return
	scale = Vector3.ONE * 0.9
	_set_alpha(0.0)
	_anim = create_tween().set_parallel(true)
	_anim.tween_property(self, "scale", Vector3.ONE, d).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT) # a slight overshoot
	_anim.tween_method(_set_alpha, 0.0, 1.0, d)


func _play_stow() -> void:
	if _anim and _anim.is_valid():
		_anim.kill()
	var d: float = tokens.duration(tokens.anim_medium * 0.8)
	if d <= 0.0:
		visible = false
		scale = Vector3.ONE
		_set_alpha(1.0)
		return
	_anim = create_tween().set_parallel(true)
	_anim.tween_property(self, "scale", Vector3.ONE * 0.92, d).set_ease(Tween.EASE_IN)
	_anim.tween_method(_set_alpha, 1.0, 0.0, d)
	_anim.chain().tween_callback(func() -> void:
		if not _open:
			visible = false
			scale = Vector3.ONE
			_set_alpha(1.0)
	)


func _set_alpha(a: float) -> void:
	## The quad is opaque (cheap) except while it fades.
	_quad_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if a < 0.999 else BaseMaterial3D.TRANSPARENCY_DISABLED
	_quad_material.albedo_color = Color(1, 1, 1, a)


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
	ui.setup(tokens, registry, manager, {"command_stack": command_stack, "chips": pages.chips})
	_viewport.add_child(ui)
	var cursor := LaserSurface.make_cursor()
	ui.add_child(cursor)
	_quad = _make_quad(_viewport, panel_size)
	_quad_material = (_quad.mesh as QuadMesh).material
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
	# The wrist "watch": a small glass face (the theme's panel colour) in an accent ring, with a
	# landscape rectangle on it — a stylised tablet — and, with shader effects on, a soft glow
	# around it. Shooting it opens the tablet. Same design language as the tablet itself.
	_target = Node3D.new()
	_left.add_child(_target)
	_target.position = target_position

	_watch_glow = _flat_material(true)
	_watch_glow_mesh = _target_mesh(_watch_glow)
	var glow_ring := TorusMesh.new()
	glow_ring.inner_radius = 0.026
	glow_ring.outer_radius = 0.042
	_watch_glow_mesh.mesh = glow_ring
	_watch_glow_mesh.position.y = -0.0006

	_watch_face = _flat_material(false)
	var face := CylinderMesh.new()
	face.top_radius = 0.0295
	face.bottom_radius = 0.0295
	face.height = 0.0012
	face.radial_segments = 48
	_target_mesh(_watch_face).mesh = face

	_watch_ring = _flat_material(false)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.0272
	ring.outer_radius = 0.0312
	ring.rings = 48
	var ring_node := _target_mesh(_watch_ring)
	ring_node.mesh = ring
	ring_node.position.y = 0.0008

	_watch_icon = _flat_material(false)
	var half_width := 0.0155
	var half_height := 0.0100
	var bar := 0.0024
	for spec in [
		{"size": Vector3(half_width * 2.0 + bar, 0.0008, bar), "pos": Vector3(0.0, 0.0, -half_height)},
		{"size": Vector3(half_width * 2.0 + bar, 0.0008, bar), "pos": Vector3(0.0, 0.0, half_height)},
		{"size": Vector3(bar, 0.0008, half_height * 2.0 + bar), "pos": Vector3(-half_width, 0.0, 0.0)},
		{"size": Vector3(bar, 0.0008, half_height * 2.0 + bar), "pos": Vector3(half_width, 0.0, 0.0)},
	]:
		var box := BoxMesh.new()
		box.size = spec["size"]
		var n := _target_mesh(_watch_icon)
		n.mesh = box
		n.position = spec["pos"] + Vector3(0.0, 0.0012, 0.0)
	_style_watch()


func _flat_material(additive: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return mat


func _target_mesh(mat: StandardMaterial3D) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.material_override = mat
	_target.add_child(instance)
	return instance


func _style_watch() -> void:
	## The watch's colours from the live theme (and hover): re-run when the theme or the effects switch changes.
	var hover := _target_hover
	_watch_ring.albedo_color = tokens.accent.lightened(0.4) if hover else tokens.accent.darkened(0.1)
	_watch_icon.albedo_color = Color.WHITE if hover else tokens.text
	var face_colour: Color = tokens.surface_hover if hover else tokens.bg_panel
	_watch_face.albedo_color = Color(face_colour.r, face_colour.g, face_colour.b, 0.92)
	var glow: Color = tokens.accent
	var strength: float = 0.5 if hover else 0.2
	_watch_glow.albedo_color = Color(glow.r, glow.g, glow.b, strength)
	_watch_glow_mesh.visible = UiThemes.fx_enabled and tokens.fx_button_glow > 0.001
	_target.scale = Vector3.ONE * (1.2 if hover else 1.0) # a slight swell on hover


# --- Per frame -----------------------------------------------------------------------

func _process(delta: float) -> void:
	if _camera == null:
		return
	if _seen_revision != UiThemes.revision:
		_seen_revision = UiThemes.revision # the UIs re-theme themselves; this node redraws the badge and the panels
		badge.refresh()
		_style_watch()
		poke_render()
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
	_gate_rendering(delta)


func _gate_rendering(delta: float) -> void:
	## Re-render the UI every frame only while something is happening (the laser is on it, or
	## it changed within the last second); idle, only a few times a second. The worst case is a
	## live label 250 ms stale, never a frozen panel: a tablet left open costs almost nothing.
	var now := Time.get_ticks_msec()
	if surface.hovering or surface.pressed:
		_activity_until_ms = now + ACTIVE_LINGER_MS
	if _side_open and (side_surface.hovering or side_surface.pressed):
		_activity_until_ms = now + ACTIVE_LINGER_MS
	_idle_left -= delta
	var tick := _idle_left <= 0.0
	if tick:
		_idle_left = IDLE_REFRESH_SECONDS
	_set_update(_viewport, now < _activity_until_ms, tick)
	if _side_open:
		_set_update(_side_viewport, now < _activity_until_ms, tick)


func _set_update(vp: SubViewport, busy: bool, tick: bool) -> void:
	if busy:
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif tick:
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


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
		_style_watch()


func _on_right_pressed(action_name: String) -> void:
	if action_name == click_action and _target_hover and not _open:
		open_tablet()
		UiFeedback.haptic(_right, "open")
		UiFeedback.play("open", self)


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
	poke_render()
	if not on:
		side_surface.release_all()
		_side_pivot.scale = Vector3.ONE
		return
	# Unfolds from its hinge on the tablet's right edge with a little spring (instant with Reduce motion).
	side_ui.play_intro()
	var d: float = tokens.duration(tokens.anim_slow)
	if d > 0.0:
		_side_pivot.scale = Vector3(0.05, 1.0, 1.0)
		create_tween().tween_property(_side_pivot, "scale", Vector3.ONE, d).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
