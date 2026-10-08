extends Node3D
## The design table (milestone 2): a floating, tilted console summoned in front of you
## from the wrist tablet's Assembly > Table page. ONE part is edited on it at a time.
##
## Layout, from John's concept sketch (all in the console's own frame: origin at the middle
## of the slab, +X to your right, +Y up out of the slab, +Z towards you):
##   * the BUILD AREA, a slab. The part floats above it, scaled to fit.
##   * the GRAB HANDLE, a pill on the slab's front edge (scripts/ui/panel_handle.gd, the
##     same one every floating window has): grip it to move and turn the whole console
##     without touching the part on it.
##   * the TOOL DECK in front of the slab, tilted up towards you: a row of category
##     buttons and under it a row of tool buttons (scripts/design_table/table_ui.gd).
##   * the assembly TREE panel at the slab's left (added in a later step).
##
## Putting a part on the table: carry a part (grip) over the slab and let go. The arena's
## own node is left exactly where it was, hidden, and a COPY of it appears on the table,
## scaled to fit and floating at the middle of the slab. The copy is what gets edited; the
## arena node is only touched again when the part leaves the table. A copy rather than a
## reparent, because the arena's parts sit under a scaled root whose frame mates, pose saving
## and hide/section all assume (see docs/design-table.md).
##
## Handling the part on the table (table_manip.gd) is independent of the world: grip it to move
## it, grip it with both hands to turn and scale it, the right stick spins it, A / B push and
## pull it. It happens only while the table is ENGAGED, which is automatic (a hand on the part, or
## the right laser on it) and shown by the slab's frame glowing and a "Table active" chip on the
## deck. Leaving: let go of it over the slab to keep it there; carry it off the slab and let go
## and the real part goes back to the arena at that spot (at the arena's scale, in its original
## orientation: a normal move, undoable and saved); or press Return on the deck to put it back
## exactly where it came from.
##
## Laser: the deck is a LaserSurface like the tablet's, and it takes the shared
## "ui_hover" claim, so a trigger on the console never also selects an arena part.

signal part_seated(part: Node3D)
signal part_lifted(part: Node3D)
signal tool_changed(tool_id: String)
signal part_edited(part_id: String) ## a feature was added or taken back: the part's geometry changed
signal status_changed(text: String)
signal opened
signal closed

const TabletRegistry := preload("res://scripts/ui/tablet_registry.gd")
const ToolManager := preload("res://scripts/ui/tool_manager.gd")
const TableTools := preload("res://scripts/design_table/table_tools.gd")
const TableUI := preload("res://scripts/design_table/table_ui.gd")
const TableSeat := preload("res://scripts/design_table/table_seat.gd")
const TableManip := preload("res://scripts/design_table/table_manip.gd")
const TableResize := preload("res://scripts/design_table/table_resize.gd")
const NewDocument := preload("res://scripts/design_table/new_document.gd")
const TableBuild := preload("res://scripts/design_table/table_build.gd")
const MatesToolScript := preload("res://scripts/mates_tool.gd")
const GLASS_SHADER := preload("res://shaders/table_glass.gdshader")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const TablePose := preload("res://scripts/design_table/table_pose.gd")
const CadApi := preload("res://scripts/design_table/cad_api.gd")
const TableEditor := preload("res://scripts/design_table/table_editor.gd")
const TableTree := preload("res://scripts/design_table/table_tree_window.gd")
const PropsWindow := preload("res://scripts/design_table/table_props_window.gd")
const DirtyMates := preload("res://scripts/design_table/dirty_mates.gd")
const EnforceButton := preload("res://scripts/design_table/enforce_button.gd")
const MateHealth := preload("res://scripts/design_table/mate_health.gd")
const LaserSurface := preload("res://scripts/ui/laser_surface.gd")
const PanelHandle := preload("res://scripts/ui/panel_handle.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")
const UiThemes := preload("res://scripts/ui/ui_themes.gd")
const THEME_PATH := "res://ui/didsa_ui_theme.tres"
const ACTIVE_LINGER_MS := 1000
const IDLE_REFRESH_SECONDS := 0.25
const TABLE_LAYER := 1 << 10 ## physics layer of the table copy's collider (the arena's parts are on the default layer)
const COPIED_METAS := ["occurrence_id", "owner_part_id", "face_ids", "body_ids", "topology"]

@export var slab_size := Vector2(0.60, 0.40) ## metres, x by z
@export var slab_radius := 0.045 ## metres: the glass slab's rounded corners
@export var slab_border := 0.006 ## metres: the rim round the glass
@export var tools_size := Vector2(0.60, 0.15) ## the tool deck, metres
@export var pixels_per_metre: float = 2667.0 ## the same physical text size as the wrist tablet
@export var deck_lean_degrees: float = 30.0 ## how far the deck is tipped up from flat, towards you
@export var deck_gap := 0.05 ## metres between the slab's front edge and the deck's top edge
@export var lean_degrees: float = 22.0 ## the whole console leans back like a drafting table: its front edge is lower than its back edge, so the slab and the sketch sheet face you rather than lying nearly edge-on
@export var open_distance: float = 0.70 ## metres in front of you when summoned
@export var open_drop: float = 0.40 ## metres below your eyes when summoned
@export var hover_height: float = 0.20 ## metres above the slab where the part floats
@export var sketch_tilt_degrees: float = 60.0 ## while a sketch is open the sketch plane stands this far up from the slab, top edge away, facing you (flat on the slab was awkward to draw on)
@export var sheet_window_m := Vector2(0.80, 0.40) ## the sketch sheet's size in the WORLD, metres (wide by tall): a fixed window you draw in, however far the part is zoomed
@export var sketch_hover_height: float = 0.26 ## metres: the least height the part floats at while it is tilted, so the sheet's lower edge clears the slab
@export var fit_radius: float = 0.16 ## metres: the seated part's bounding sphere is this big
@export var lift_reach: float = 0.06 ## metres beyond the seated part's sphere that a grip still catches it
@export var drop_floor: float = -0.05 ## drop zone, metres above the slab
@export var drop_ceiling: float = 0.60
@export var max_point_distance: float = 2.0
@export var click_action: String = "trigger_click"
@export var grab_action: String = "grip_click"
@export var open_settle_seconds: float = 0.4

var tokens: Resource
var registry
var manager
var ui: Control ## table_ui.gd
var surface ## LaserSurface for the tool deck
var handle ## PanelHandle on the slab's front edge
var snap_enabled := true
var api ## cad_api.gd: the serial line to the backend
var editor ## table_editor.gd: the editing session on the seated part
var tree ## table_tree_window.gd: the assembly tree docked at the slab's left
var props ## table_props_window.gd: the active tool's settings, docked at the slab's right (the deck's old options row)
var enforce_button ## enforce_button.gd: "Enforce mates", shown where a part with stale mates is put down
var mate_baseline: Array = [] ## what each mate's faces looked like BEFORE the first edit this session (mate_health.capture)
var remake_plan: Array = [] ## the mates Enforce turned off that can be remade on the equivalent face (mate_health.gd remake_plan), offered on the button after it
var mate_drift: Dictionary = {} ## mate id -> [references] whose face is no longer the one the mate was made on (mate_health.gd)

var active_tool := ""
var keep_turn_on_return := false ## a part sent back to the arena keeps the turn it has on the table (default: its original orientation)
var max_scale_setting := 3.0 ## the biggest everyday scale of the part on the table (Settings; a sketch always allows more)
const DECK_MIN_WIDTH := 0.60 ## metres: the tool deck is as wide as the slab, between these two
const DECK_MAX_WIDTH := 1.00
var part_locked := true ## while a sketch is open: the part keeps the sketch tilt (two hands move and scale only, the stick leaves it alone); false = free to turn
var seated: MeshInstance3D = null ## the arena's own node that is on the table (hidden meanwhile)
var pivot: Node3D = null ## the copy's pivot, floating above the slab; its basis is the part's orientation on the table
var table_copy: MeshInstance3D = null ## what's edited; a child of pivot, in the part's own mm frame
var fit_scale := 0.0 ## metres per mm of the part at its fitted size
var window_anchor_normal := Vector3.ZERO ## console frame: the sketch plane's normal at that pose
var window_anchor := Vector3.ZERO ## console frame: the spot on the sketch plane that the sketch window is centred on (fixed while a sketch is open; the part slides under it)
var user_scale := 1.0 ## how much bigger / smaller than fitted the part has been made with two hands (the pivot carries it; fit_scale does not change)
var build ## table_build.gd: the Build tree of the part on the table (the tree window's Build tab is its view)
var manip ## table_manip.gd: gripping, turning, scaling and nudging the part, and whether the table is engaged

var _left: XRController3D
var _right: XRController3D
var _camera: XRCamera3D
var _main: Node
var _mates_tool: Node
var _open := false
var _viewport: SubViewport
var _deck: Node3D
var _deck_quad: MeshInstance3D
var _handle_frame: Node3D
var _handle_local := Transform3D.IDENTITY
var resizer ## table_resize.gd: the corner brackets that drag the slab to a new size
var _slab: MeshInstance3D
var _frame_material: ShaderMaterial ## the glass slab's: rounded rim, glow
var _ring: MeshInstance3D
var _ring_material: StandardMaterial3D
var _seen_revision := 0
var _activity_until_ms := 0
var _idle_left := 0.0
var _status := ""
var _seat_local_basis := Basis.IDENTITY ## the arena node's own basis (relative to its parent) when it was seated
var _seat_pose := Transform3D.IDENTITY ## its world transform when it was seated: what undo goes back to
var _last_drop_ok := false
var _engaged := false ## drawn: the slab's frame glows
var _leave_cue := false ## drawn: the frame turns amber because letting go here sends the part to the arena
var _seat_pivot_basis := Basis.IDENTITY ## the part's orientation on the table when it was put there (what Reset goes back to before a sketch plane is chosen)
var _last_suppressed := 0 ## mates the last Enforce suppressed because the edit changed their face
var _orient_tween: Tween = null
var _new_part_busy := false
var _view_empty := false ## the Build tree has hidden / rolled back everything: the copy shows nothing


func setup(left: XRController3D, right: XRController3D, camera: XRCamera3D, main: Node, mates_tool: Node = null) -> void:
	_left = left
	_right = right
	_camera = camera
	_main = main
	_mates_tool = mates_tool
	tokens = load(THEME_PATH)
	_seen_revision = UiThemes.revision

	registry = TabletRegistry.new()
	manager = ToolManager.new()
	manager.setup(registry)
	TableTools.register(registry, self)

	_build_slab()
	_build_deck()
	_build_handle()
	api = CadApi.new()
	api.name = "CadApi"
	add_child(api)
	editor = TableEditor.new()
	editor.name = "Editor"
	add_child(editor)
	editor.setup(self, api)
	tree = TableTree.new()
	tree.name = "Tree"
	add_child(tree)
	tree.setup_for_table(self, left, right, camera, main)
	props = PropsWindow.new()
	props.name = "Properties"
	add_child(props)
	props.setup_for_table(self, left, right, camera)
	props.option_pressed.connect(func(id: String) -> void: editor.on_option(id))
	ui.options_sink = props
	enforce_button = EnforceButton.new()
	enforce_button.name = "EnforceMates"
	main.add_child(enforce_button) # a sibling, not a child: it must stay visible when the table is put away
	enforce_button.setup(right, camera)
	enforce_button.pressed_enforce.connect(func() -> void:
		if remake_plan.is_empty():
			await enforce_mates()
		else:
			await remake_mates())
	if mates_tool != null:
		mates_tool.enforce_finished.connect(_on_enforce_finished)
	build = TableBuild.new()
	build.setup(self)
	tree.attach_build(build)
	resizer = TableResize.new()
	resizer.setup(self)
	manip = TableManip.new()
	manip.setup(self)
	manip.engaged_changed.connect(set_engaged)
	ui.undo_pressed.connect(func() -> void: editor.undo())
	ui.reset_pressed.connect(reset_pose)
	ui.part_lock_toggled.connect(func(on: bool) -> void:
		part_locked = on
		set_status("The part keeps its tilt: one hand slides it under the sketch window, two hands zoom it." if on else "The part is free: your hands move, turn and scale it anywhere, the stick spins it. Reset puts the tilt back."))
	ui.fit_pressed.connect(fit_sketch)
	ui.done_pressed.connect(func() -> void: editor.finish_sketch())
	ui.return_pressed.connect(return_to_arena)
	ui.option_pressed.connect(func(id: String) -> void: editor.on_option(id))
	add_to_group("design_tables") # controller.gd asks every table about seating / lifting
	add_to_group("diegetic_panels") # ...and about its grab handle, like every floating window (handle_in_reach below)
	visible = false


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	visible = true
	_place_in_front_of_camera()
	surface.arm()
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	poke_render()
	tree.open()
	props.set_wanted(props.has_options())
	set_status("Carry a part over the table and let go, or pick one in the tree, to edit it.")
	UiFeedback.play("open", self)
	opened.emit()


func close() -> void:
	if not _open:
		return
	return_part() # the real node comes back exactly where it was
	manager.deactivate()
	resizer.cancel()
	if tree.is_open():
		tree.close()
	props.set_wanted(false)
	_open = false
	visible = false
	surface.release_all()
	handle.clear()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _right:
		_right.set_meta("ui_hover", false)
		_right.set_meta("ui_hit_distance", -1.0)
	UiFeedback.play("close", self)
	closed.emit()


func recall() -> void:
	## Brings the console (and the part on it) back in front of you.
	_place_in_front_of_camera()
	poke_render()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func poke_render() -> void:
	## Something on screen is about to change: render every frame for a moment.
	_activity_until_ms = Time.get_ticks_msec() + ACTIVE_LINGER_MS


func set_status(text: String) -> void:
	_status = text
	if ui:
		ui.set_status(text)
	status_changed.emit(text)


func status() -> String:
	return _status


# --- Tools ---------------------------------------------------------------------------

func tool_activated(tool_id: String) -> void:
	active_tool = tool_id
	var def = registry.tool_def(tool_id)
	if def != null and def.hint != "":
		set_status(def.hint)
	editor.on_tool_changed(tool_id)
	_show_tool_in_props(tool_id)
	tool_changed.emit(tool_id)


func _show_tool_in_props(tool_id: String) -> void:
	var def = registry.tool_def(tool_id) if tool_id != "" else null
	var cat = registry.category_of(tool_id) if def != null else null
	props.set_tool(def.label if def != null else "", def.hint if def != null else "", cat.accent if cat != null else Color.WHITE)


func tool_deactivated(tool_id: String) -> void:
	if active_tool == tool_id:
		active_tool = ""
		editor.on_tool_changed("")
		_show_tool_in_props("")
		tool_changed.emit("")


# --- Building ------------------------------------------------------------------------

func _build_slab() -> void:
	## A pane of glass in the console's XZ plane (its top is the console's y = 0): rounded corners, a rim, a soft inner glow,
	## a clear middle. All drawn by one shader from the slab's size in metres, so it stays crisp however it is resized.
	_slab = MeshInstance3D.new()
	_slab.name = "Slab"
	var plane := PlaneMesh.new()
	plane.size = slab_size
	_frame_material = ShaderMaterial.new()
	_frame_material.shader = GLASS_SHADER
	_frame_material.render_priority = -1 # under the part's ring and the resize brackets
	plane.material = _frame_material
	_slab.mesh = plane
	_slab.position = Vector3(0.0, -0.001, 0.0)
	_slab.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_slab)
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = fit_radius - 0.004
	ring_mesh.outer_radius = fit_radius + 0.004
	ring_mesh.rings = 48
	_ring_material = StandardMaterial3D.new()
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.render_priority = 1
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mesh.material = _ring_material
	_ring.mesh = ring_mesh
	_ring.position = Vector3(0, 0.002, 0)
	_ring.scale = Vector3(1, 0.2, 1)
	add_child(_ring)
	_style_materials()


func _style_materials() -> void:
	## Colours from the live UI theme: re-run when the theme changes.
	var ring: Color = tokens.accent
	var rim: Color = tokens.warn if _leave_cue else (ring.lightened(0.45) if _engaged else ring)
	var fill: Color = tokens.bg_panel
	_frame_material.set_shader_parameter("size", slab_size)
	_frame_material.set_shader_parameter("radius", slab_radius)
	_frame_material.set_shader_parameter("border_width", slab_border)
	_frame_material.set_shader_parameter("fill_color", Color(fill.r, fill.g, fill.b, 0.30))
	_frame_material.set_shader_parameter("border_color", rim)
	_frame_material.set_shader_parameter("glow", 1.0 if (_engaged or _leave_cue) else 0.0)
	_ring_material.albedo_color = Color(ring.r, ring.g, ring.b, 0.85 if (_last_drop_ok or _engaged) else 0.30)


func _build_deck() -> void:
	var viewport_size := Vector2i((tools_size * pixels_per_metre).round())
	_viewport = SubViewport.new()
	_viewport.size = viewport_size
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED # only drawn while open
	add_child(_viewport)
	ui = TableUI.new()
	ui.size = Vector2(viewport_size)
	ui.setup(tokens, registry, manager)
	_viewport.add_child(ui)
	var cursor := LaserSurface.make_cursor()
	ui.add_child(cursor)

	_deck = Node3D.new()
	add_child(_deck)
	_deck.rotation_degrees = Vector3(-(90.0 - deck_lean_degrees), 0.0, 0.0) # the quad faces +Z; this lays it down, tipped up towards you
	_layout_deck()
	_deck_quad = MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = tools_size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	_deck_quad.mesh = mesh
	_deck.add_child(_deck_quad)

	surface = LaserSurface.new()
	surface.setup(_deck, _viewport, _right, tools_size)
	surface.claim_first = true
	surface.settle_seconds = open_settle_seconds
	surface.max_point_distance = max_point_distance
	surface.click_action = click_action
	surface.cursor = cursor

	ui.close_requested.connect(close)
	ui.feedback.connect(func(event: String) -> void:
		UiFeedback.haptic(_right, event)
		UiFeedback.play(event, self))
	ui.activity.connect(poke_render)
	ui.snap_toggled.connect(func(on: bool) -> void: snap_enabled = on)
	manager.active_changed.connect(func(_id: String) -> void: poke_render())


func deck_width_for(slab_width: float) -> float:
	## The tool deck is as wide as the slab it sits in front of, never narrower than the original 0.6 m or wider than 1 m: a wider slab
	## gives the buttons (Part: Locked, Fit, Done, Reset...) more room.
	return clampf(slab_width, DECK_MIN_WIDTH, DECK_MAX_WIDTH)


func _apply_deck_width() -> void:
	var width := deck_width_for(slab_size.x)
	if is_equal_approx(width, tools_size.x) or _viewport == null:
		return
	tools_size.x = width
	var viewport_size := Vector2i((tools_size * pixels_per_metre).round())
	_viewport.size = viewport_size
	ui.size = Vector2(viewport_size)
	(_deck_quad.mesh as QuadMesh).size = tools_size
	surface.panel_size = tools_size


func apply_settings(settings) -> void:
	## main.gd, once everything exists: what the user chose last time.
	keep_turn_on_return = settings.table_keep_turn
	max_scale_setting = settings.table_max_scale
	var saved: Vector2 = settings.table_slab_size
	if saved != Vector2.ZERO:
		set_slab_size(saved.clamp(resizer.min_size, resizer.max_size))


func remember_layout() -> void:
	## The slab was dragged to its size: remembered for next time.
	_main.app_settings().set_table_slab_size(slab_size)


func _layout_deck() -> void:
	## The deck's top edge starts deck_gap in front of the slab's front edge, just under it (moves with the slab when it is resized).
	var lean := deg_to_rad(90.0 - deck_lean_degrees)
	var top_edge := Vector3(0.0, -0.01, slab_size.y * 0.5 + deck_gap)
	_deck.position = top_edge + Vector3(0.0, -cos(lean) * tools_size.y * 0.5, sin(lean) * tools_size.y * 0.5) # its middle is half the deck's height down the slope from the top edge


func set_slab_size(new_size: Vector2) -> void:
	## The slab was dragged to a new size (table_resize.gd): the glass, the handle on its front edge, the deck in front of it and
	## the tree at its left follow. The part keeps its place relative to the slab's middle.
	slab_size = new_size
	(_slab.mesh as PlaneMesh).size = new_size
	_style_materials()
	handle.layout(new_size)
	_apply_deck_width()
	_layout_deck()
	var dock_x := -(new_size.x * 0.5 + 0.20)
	tree.position.x += dock_x - tree.dock_position.x # keeps wherever the tree has been carried to, relative to the slab's left edge
	tree.dock_position.x = dock_x
	var props_x := new_size.x * 0.5 + 0.20
	props.position.x += props_x - props.dock_position.x
	props.dock_position.x = props_x
	resizer.layout()
	poke_render()


func _build_handle() -> void:
	# The handle works in a "panel" frame whose +Z is the slab's normal and whose lower edge
	# is the slab's front edge, so the stock pill and halo land on the front edge and glow
	# round the slab. PanelHandle moves that frame; the console follows it (see _process).
	_handle_frame = Node3D.new()
	add_child(_handle_frame)
	_handle_local = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3.ZERO)
	_handle_frame.transform = _handle_local
	handle = PanelHandle.new()
	handle.setup(_handle_frame, _left, _right, func() -> bool: return _open, tokens)
	handle.grab_action = grab_action
	handle.camera = _camera
	handle.laser_reach = 0.0 # near grab only: a distance carry would stand the console upright and face it at you
	handle.build(slab_size)
	handle.set_hollow(true) # the slab is glass: the halo glows round it, not over it


func handle_in_reach(hand: Node3D) -> bool:
	## True if this open console's drag handle is within this hand's grab reach (controller.gd
	## asks every panel first, so a grip aimed at the handle never also grabs a part).
	return handle != null and handle.in_reach(hand)


# --- Per frame -------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _camera == null:
		return
	if _seen_revision != UiThemes.revision:
		_seen_revision = UiThemes.revision
		_style_materials()
		handle.set_colours(tokens.text_dim, tokens.accent)
		resizer.restyle()
		poke_render()
	if not _open:
		return
	if handle.follow(delta):
		# PanelHandle moved its own frame; carry the whole console with it.
		global_transform = _handle_frame.global_transform * _handle_local.affine_inverse()
		_handle_frame.transform = _handle_local
		surface.release_all()
		poke_render()
		return
	surface.process(delta, true)
	resizer.process()
	_update_drop_ring()
	manip.process(delta)
	_gate_rendering(delta)


func _update_drop_ring() -> void:
	var held := _held_part()
	var ok := held != null and seated == null and _in_drop_zone(held)
	if ok != _last_drop_ok:
		_last_drop_ok = ok
		_style_materials()


func _held_part() -> Node3D:
	if _left and _left.held_node != null:
		return _left.held_node
	if _right and _right.held_node != null:
		return _right.held_node
	return null


func _gate_rendering(delta: float) -> void:
	## Re-render the deck every frame only while something is happening (the laser is on it,
	## or it changed within the last second); idle, a few times a second.
	var now := Time.get_ticks_msec()
	if surface.hovering or surface.pressed:
		_activity_until_ms = now + ACTIVE_LINGER_MS
	_idle_left -= delta
	var tick := _idle_left <= 0.0
	if tick:
		_idle_left = IDLE_REFRESH_SECONDS
	if now < _activity_until_ms:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	elif tick:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	elif _viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _place_in_front_of_camera() -> void:
	if _camera == null:
		return
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	var position := _camera.global_position + forward * open_distance
	position.y = _camera.global_position.y - open_drop
	var upright := Basis.looking_at(forward, Vector3.UP) # +Z towards you
	global_transform = Transform3D(upright * Basis(Vector3.RIGHT, deg_to_rad(lean_degrees)), position)


# --- Seating and lifting -----------------------------------------------------------------

func _in_drop_zone(part: Node3D) -> bool:
	if not (part is MeshInstance3D):
		return false
	var centre_world: Vector3 = part.global_transform * (part as MeshInstance3D).get_aabb().get_center()
	return TableSeat.in_drop_zone(to_local(centre_world), slab_size, drop_floor, drop_ceiling)


func try_seat_released(part: Node3D, original_pose: Transform3D) -> bool:
	## controller.gd calls this when a hand lets go of a carried part. True if the table took
	## it (the controller then does nothing more); the arena node goes back to `original_pose`
	## first, so nothing about its place in the assembly changes.
	if not _open or seated != null or not _in_drop_zone(part):
		if _open and seated != null and _in_drop_zone(part) and part != seated:
			set_status("The table already holds %s. Lift it off first." % seated.name)
		return false
	if not part.has_meta("owner_part_id") or str(part.get_meta("owner_part_id")) == "":
		set_status("%s has no part behind it to edit (a local file, not the backend)." % part.name)
		return false
	part.global_transform = original_pose
	seat(part as MeshInstance3D)
	return true


func seat(part: MeshInstance3D) -> bool:
	## Puts the part on the table: hides the arena node and shows a scaled copy floating above the slab.
	if seated != null or part.mesh == null:
		return false
	var aabb := part.get_aabb()
	var scale := TableSeat.fit_scale(aabb, fit_radius)
	if scale <= 0.0:
		return false
	seated = part
	fit_scale = scale
	_seat_pose = part.global_transform
	_seat_local_basis = part.transform.basis
	part.set_meta("on_table", true)
	part.visible = false

	pivot = Node3D.new()
	pivot.name = "TablePivot"
	add_child(pivot)
	pivot.position = Vector3(0.0, hover_height, 0.0)
	# It keeps the orientation it had in the arena, upright as you saw it, not the console's lean.
	pivot.basis = (global_transform.basis.inverse() * part.global_transform.basis.orthonormalized()).orthonormalized()
	_seat_pivot_basis = pivot.basis
	user_scale = 1.0

	table_copy = MeshInstance3D.new()
	table_copy.name = "TableCopy"
	table_copy.mesh = part.mesh
	table_copy.material_override = part.material_override
	for key in COPIED_METAS:
		if part.has_meta(key):
			table_copy.set_meta(key, part.get_meta(key))
	table_copy.scale = Vector3.ONE * scale
	pivot.add_child(table_copy)
	table_copy.position = TableSeat.copy_offset(aabb, scale, Basis.IDENTITY) # the middle of its bounds at the pivot; the pivot turns both
	_give_copy_collider()
	set_status("Editing %s." % part.name)
	ui.set_part_present(true)
	poke_render()
	UiFeedback.haptic(_right, "confirm")
	part_seated.emit(part)
	editor.on_seated() # finds which part this is, then opens plane picking (a coroutine: not waited for)
	return true


func is_blank() -> bool:
	## The part on the table has no geometry yet (a New part nobody has drawn on): there is a placeholder to size things by,
	## but nothing to see or pick, only the reference planes to sketch on.
	return seated != null and bool(seated.get_meta("blank", false))


func _give_copy_collider() -> void:
	## The copy's collider on the table's own layer (so the laser can pick its faces) and, for a blank part, no collider and
	## no drawing of the placeholder box: the copy still stands in for its size and carries the plane squares and the sheet
	## (its children keep their own layers), but a fake cube is never shown or picked.
	_view_empty = false
	apply_view_mode()
	if is_blank():
		return
	table_copy.create_trimesh_collision()
	for child in table_copy.get_children():
		if child is StaticBody3D:
			(child as StaticBody3D).collision_layer = TABLE_LAYER
			(child as StaticBody3D).collision_mask = 0


func apply_view_mode() -> void:
	## The copy in the current view mode (view_modes.gd): its faces drawn or not (never for a blank part, or when the Build tree has hidden
	## everything), its edges built and shown or not (never for those two either: the placeholder box has no edges worth showing).
	if table_copy == null:
		return
	var nothing_to_draw := is_blank() or _view_empty
	table_copy.set_meta("no_edges", nothing_to_draw)
	_main.view_modes.apply_to(table_copy)
	table_copy.layers = 1 if (not nothing_to_draw and _main.view_modes.shows_faces()) else 0


func try_grab(hand: XRController3D) -> bool:
	## controller.gd calls this when a grip starts. True if the grip is on the part on the table (it moves with the hand,
	## and with a second hand it turns and scales; the arena is not involved).
	return manip.try_grab(hand)


func release_grab(hand: Object) -> bool:
	## controller.gd calls this when a grip lets go. True if that hand was holding the part on the table.
	return manip.release(hand)


func owns_stick(hand: Object) -> bool:
	## True for the right hand while the table is engaged: its stick and A / B handle the part on the table, not a selected arena part or walking.
	return _open and manip != null and manip.owns_stick(hand)


func editing_sketch() -> bool:
	## A sketch is open on the part on the table.
	return editor != null and editor.session != null


func sketch_locked() -> bool:
	## The part's turn is locked to the sketch tilt: a sketch is open and "Part: Locked" is on.
	return part_locked and editing_sketch()


func max_user_scale() -> float:
	## The biggest the part may be scaled to: much higher while sketching (zooming right in on the sketch under the window).
	return maxf(TablePose.SKETCH_MAX_SCALE, max_scale_setting) if editing_sketch() else max_scale_setting


func min_user_scale() -> float:
	## The smallest: much lower while sketching (panning out to a huge sketch).
	return TablePose.SKETCH_MIN_SCALE if editing_sketch() else TablePose.MIN_SCALE


func fit_sketch() -> void:
	## The Fit button: the part goes back to the sketch tilt and is scaled and slid so the sketch (or, with nothing drawn yet, the part)
	## fills most of the sketch window.
	if pivot == null or not editing_sketch() or editor.view == null:
		return
	var bounds: Rect2 = editor.sketch_bounds()
	var scale: float = TablePose.fit_scale(bounds.size, sheet_window_m, 0.8, fit_scale, max_user_scale(), min_user_scale())
	var rotation := sketch_rotation(editor.session.plane)
	var basis := rotation.orthonormalized() * scale
	var centre_in_pivot: Vector3 = table_copy.transform * SketchMath.from_sheet(bounds.get_center(), editor.session.plane)
	_animate_pose(rotation, window_anchor - basis * centre_in_pivot, scale)
	set_status("Sketch fitted to the window.")
	UiFeedback.haptic(_right, "confirm")


func pin_sketch_plane() -> void:
	## While a sketch is open and the part is locked, the part may only slide ALONG the sketch plane under the window: whatever moved
	## it off the plane (a hand, A / B, a scale about a point off the plane) is taken back out, so the window stays in the plane.
	if not sketch_locked() or pivot == null or table_copy == null or window_anchor_normal == Vector3.ZERO:
		return
	var plane: Dictionary = editor.session.plane
	var on_plane: Vector3 = pivot.position + pivot.basis * (table_copy.transform * (plane["origin"] as Vector3))
	pivot.position -= window_anchor_normal * window_anchor_normal.dot(on_plane - window_anchor)


func _set_window_anchor(rotation: Basis, centre: Vector3, scale: float, plane: Dictionary) -> void:
	## Fixes the sketch window where the sketch plane will be once the part has settled into `rotation`, `centre`, `scale`: on the
	## plane, as near the part's middle as it gets.
	var basis := rotation.orthonormalized() * scale
	var on_plane: Vector3 = centre + basis * (table_copy.transform * (plane["origin"] as Vector3))
	window_anchor_normal = (rotation.orthonormalized() * (table_copy.basis * (plane["n"] as Vector3))).normalized()
	window_anchor = centre - window_anchor_normal * window_anchor_normal.dot(centre - on_plane)


func part_radius() -> float:
	## Metres: the part's bounding sphere on the table now (the fitted radius times how much it has been scaled).
	return fit_radius * user_scale


func effective_scale() -> float:
	## Metres per part mm right now: the fitted scale times the user's own scaling.
	return fit_scale * user_scale


func set_engaged(on: bool) -> void:
	## The table has taken over (or let go of) the right stick and A / B: the slab's frame glows and the deck says so.
	if _engaged == on:
		return
	_engaged = on
	_style_materials()
	ui.set_engaged(on)
	poke_render()


func set_leave_cue(on: bool) -> void:
	## A hand is carrying the part past the slab: the frame turns amber, because letting go now sends it to the arena.
	if _leave_cue == on:
		return
	_leave_cue = on
	_style_materials()
	if on:
		set_status("Let go here to send it back to the arena, or bring it back over the slab to keep it.")
	elif seated != null and manip.is_gripping():
		set_status("Over the table: let go to keep it here.")
	poke_render()


func send_to_arena(world_centre: Vector3) -> void:
	## The part was let go of beyond the slab: the real node comes back at the arena's scale, in its original orientation (or, with
	## "keep turn" on, the turn it was given on the table), with
	## the middle of its bounds at `world_centre`, as an ordinary move (undoable, saved, its mates flagged if it was edited).
	if seated == null:
		return
	if is_blank():
		_discard_blank()
		return
	var node := seated
	if _mates_tool != null and (_mates_tool.is_constrained(node) or _mates_tool.is_locked(node)):
		return_to_arena() # held by its mates: free placement would break them, so it goes back where it came from
		set_status("%s is held by its mates, so it went back where it came from." % node.name)
		return
	var before := _seat_pose
	var turn := Basis.IDENTITY
	if keep_turn_on_return and pivot != null:
		# The turn the part was given on the table (a rotation in the console frame), carried over to the world frame.
		var delta := pivot.basis.orthonormalized() * _seat_pivot_basis.inverse()
		turn = (global_transform.basis.orthonormalized() * delta * global_transform.basis.orthonormalized().inverse()).orthonormalized()
	var after := TableSeat.lift_transform((node.get_parent() as Node3D).global_transform.basis, _seat_local_basis, node.get_aabb(), world_centre, turn)
	node.global_transform = after
	node.visible = true
	node.remove_meta("on_table")
	_clear_seat()
	_push_move("move %s" % node.name, node, before, after)
	_persist(node)
	set_status("Put %s back in the arena." % node.name)
	part_lifted.emit(node)
	part_put_down(node)
	UiFeedback.haptic(_right, "confirm")


func return_to_arena() -> void:
	## The Return button: the real part goes back exactly where it came from. The table is free for the next one.
	if seated == null:
		return
	var name_text := seated.name
	var was_blank := is_blank()
	return_part()
	if was_blank:
		return # a part nothing was drawn on is discarded, and return_part said so
	set_status("%s is back where it came from." % name_text)
	UiFeedback.haptic(_right, "confirm")


func return_part() -> void:
	## The table is closing (or the model was replaced): the arena node comes back untouched.
	if seated == null:
		return
	if is_blank():
		_discard_blank() # nothing was drawn on it: there is nothing to give back
		return
	var node := seated
	if is_instance_valid(node):
		node.visible = true
		if node.has_meta("on_table"):
			node.remove_meta("on_table")
	_clear_seat()
	if is_instance_valid(node):
		part_put_down(node) # edited and handed back: its mates need redoing


func _discard_blank() -> void:
	## A new part that never got any geometry leaves the table: it is taken off the assembly again rather than left behind as an
	## empty, invisible placed part (the part itself stays in the backend's document, unreferenced).
	var node := seated
	var name_text := node.name
	var root_id := str(node.get_meta("owner_part_id", ""))
	var occurrence_id := str(node.get_meta("occurrence_id", ""))
	_clear_seat()
	node.remove_from_group("grabbable_parts")
	node.queue_free()
	set_status("%s had nothing drawn on it, so it was discarded." % name_text)
	if root_id != "" and occurrence_id != "":
		NewDocument.new(Callable(api, "request")).remove_occurrence(root_id, occurrence_id) # queued behind any call still in flight
		_refresh_trees()


func _refresh_trees() -> void:
	tree.mark_stale()
	_main.refresh_assembly_tree()


func rename_part() -> void:
	## The Build tab's Rename: the full keyboard opens on the part's name; confirming renames the PART (every placed instance of it).
	if seated == null or editor.part_id == "":
		return
	var node := seated
	_main.open_keyboard_for(str(node.name), func(text: String) -> void: await rename_part_to(text), {"mode": "full", "title": "Part name", "confirm_label": "Rename"})


func rename_part_to(new_name: String) -> bool:
	## PATCH /document/parts/{id} {name}; the arena nodes that show the part take the name too, and the trees reload.
	var clean := new_name.strip_edges()
	if seated == null or editor.part_id == "" or clean == "":
		return false
	if clean == str(seated.name):
		return true
	var r: Dictionary = await api.request(HTTPClient.METHOD_PATCH, "/document/parts/%s" % editor.part_id, {"name": clean})
	if not r["ok"]:
		set_status("Couldn't rename it: %s" % str(r["error"]))
		UiFeedback.haptic(_right, "error")
		return false
	var nodes: Array = await editor.arena_nodes_of(editor.part_id)
	if seated != null and not nodes.has(seated):
		nodes.append(seated)
	for node in nodes:
		if is_instance_valid(node):
			node.name = clean
	_main.mark_dirty()
	_refresh_trees()
	build.changed.emit()
	set_status("Renamed to %s." % clean)
	return true


func new_part() -> void:
	## "New part" (the tree's + and the tablet's Table page): starts an empty part on the table, ready to be sketched on. The table
	## opens if it is closed, a part already on it goes back where it came from, and with no assembly loaded yet an empty one is
	## started first. Named "Part N". The part is placed on the assembly in front of you (so it is where it will be when it comes
	## off the table); until it has a feature it has no mesh, and nothing in the arena shows it.
	if _new_part_busy:
		return
	_new_part_busy = true
	await _new_part_impl()
	_new_part_busy = false


func _new_part_impl() -> void:
	if not api.is_configured():
		if not _open:
			open()
		set_status("New part needs the DIDSA-CAD backend, and none is configured.")
		return
	if not _open:
		open()
	if seated != null:
		var leaving := seated.name
		return_part()
		set_status("%s went back where it came from." % leaving)
	if _main.current_root_part_id() == "":
		if not await _main.new_assembly():
			return # new_assembly said why
	var root_id: String = _main.current_root_part_id()
	var doc := NewDocument.new(Callable(api, "request"))
	var part_name: String = await doc.next_part_name(root_id)
	var local_pose := _new_part_pose()
	var added: Dictionary = await doc.add_part(root_id, part_name, MatesToolScript.pose_to_json(local_pose))
	if not added["ok"]:
		set_status(str(added["error"]))
		UiFeedback.haptic(_right, "error")
		return
	if not _open or _main.current_root_part_id() != root_id:
		return # the table was put away, or the model replaced, while the backend was working
	var node: MeshInstance3D = _main.add_blank_part(root_id, str(added["occurrence_id"]), local_pose)
	node.name = part_name
	_refresh_trees()
	if not seat(node):
		node.remove_from_group("grabbable_parts")
		node.queue_free()
		set_status("Couldn't put %s on the table." % part_name)


func _new_part_pose() -> Transform3D:
	## Where a new part sits in the arena: to the right of the table and a little further off, in the assembly's own frame
	## (millimetres, the frame the backend stores an occurrence's transform in), turned the way the assembly is.
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	var right := forward.cross(Vector3.UP).normalized()
	var spot := _camera.global_position + forward * 0.8 + right * 0.55 + Vector3(0.0, -0.2, 0.0)
	var root: Node3D = _main.assembly_root
	return Transform3D(Basis.IDENTITY, root.global_transform.affine_inverse() * spot)


func on_model_replaced() -> void:
	## main.gd is about to free every arena node: forget the seated one without touching it.
	enforce_button.hide_button()
	mate_drift.clear() # a reload reads every mate fresh from the backend
	mate_baseline.clear()
	_clear_seat()


func _clear_seat() -> void:
	if manip != null:
		manip.cancel() # no grip outlives the part it was on
	if ui != null:
		ui.set_part_present(false)
	if editor != null:
		editor.on_cleared() # before the copy it hangs things on is freed
	if _orient_tween and _orient_tween.is_valid():
		_orient_tween.kill()
	if pivot != null and is_instance_valid(pivot):
		remove_child(pivot)
		pivot.queue_free()
	pivot = null
	table_copy = null
	seated = null
	fit_scale = 0.0
	user_scale = 1.0
	if build != null:
		build.clear() # after the seat is gone: the tree window sees an empty table and goes back to Parts


# --- Editing support (table_editor.gd) ----------------------------------------------------------

func configure_backend(url: String, key: String) -> void:
	api.configure(url, key)
	tree.configure_backend(url, key)


func node_for_occurrence(occurrence_id: String) -> Node3D:
	## The arena node showing this placed occurrence, if there is one that can be taken (visible, not already on a table).
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if node is MeshInstance3D and node.has_meta("occurrence_id") and str(node.get_meta("occurrence_id")) == occurrence_id \
				and node.visible and not node.has_meta("on_table") and not node.get_meta("held", false):
			return node
	return null


func seat_node(node: Node3D) -> String:
	## Puts an arena part on the table without carrying it there (the tree's "Table"). Returns a message for the status line.
	if not _open:
		return "Open the table first."
	if seated != null:
		return "The table already holds %s. Lift it off first." % seated.name
	if not (node is MeshInstance3D) or str(node.get_meta("owner_part_id", "")) == "":
		return "%s has no part behind it to edit (a local file, not the backend)." % node.name
	return "On the table." if seat(node as MeshInstance3D) else "Couldn't put that on the table."


func bring_part(node: Node3D) -> String:
	## Moves an arena part to a spot in front of you (the tree's "Bring"): an ordinary move, undoable, saved like any other.
	if _mates_tool != null and (_mates_tool.is_constrained(node) or _mates_tool.is_locked(node)):
		return "%s is held by its mates. Relax all mates first." % node.name
	var forward := -_camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	var spot := _camera.global_position + forward * 0.55 + Vector3(0.0, -0.25, 0.0)
	var before := node.global_transform
	var centre: Vector3 = node.global_transform * (node as MeshInstance3D).get_aabb().get_center()
	node.global_position += spot - centre
	_push_move("bring %s" % node.name, node, before, node.global_transform)
	_persist(node)
	return "Brought %s to you." % node.name


func _push_move(label: String, node: Node3D, before: Transform3D, after: Transform3D) -> void:
	## One undo step for an ordinary move of an arena part (undo goes back to `before`, redo to `after`, both saved).
	var stack = _main.command_stack
	if stack == null or before.is_equal_approx(after):
		return
	stack.push(label,
		func() -> void:
			if is_instance_valid(node):
				node.global_transform = before
				_persist(node),
		func() -> void:
			if is_instance_valid(node):
				node.global_transform = after
				_persist(node),
		true)


func _persist(node: Node3D) -> void:
	if _mates_tool != null:
		_mates_tool.persist_pose(node)


func orient_to_plane(plane: Dictionary) -> void:
	## Turns the part on the table so the sketch plane stands tilted up towards you (sketch_rotation), x to the right, y away. Where
	## it is (never lower than sketch_hover_height) and how big it is stay as the user left them.
	if pivot == null:
		return
	var at := pivot.position
	at.y = maxf(at.y, sketch_hover_height)
	_set_window_anchor(sketch_rotation(plane), at, user_scale, plane)
	_animate_pose(sketch_rotation(plane), at, user_scale)


func sketch_rotation(plane: Dictionary) -> Basis:
	## How the part is turned while a sketch on `plane` is open: the plane lies flat on the slab (x right, y away, normal up), then
	## tips up about the slab's x axis by sketch_tilt_degrees so its top edge goes away and its face comes towards you.
	return Basis(Vector3.RIGHT, deg_to_rad(sketch_tilt_degrees)) * SketchMath.orient_to_table(plane)


func reset_pose() -> void:
	## The Reset button: the part goes back to the middle of the slab at its fitted size, with the sketch plane flat (or, before
	## one is chosen, the way it was put on the table).
	if pivot == null:
		return
	var rotation := _seat_pivot_basis
	var text := "Back where it started."
	if editor != null and editor.session != null and not (editor.session.plane as Dictionary).is_empty():
		rotation = sketch_rotation(editor.session.plane)
		text = "Back to the sketch plane."
	var target := Vector3(0.0, sketch_hover_height if rotation != _seat_pivot_basis else hover_height, 0.0)
	if editing_sketch():
		_set_window_anchor(rotation, target, 1.0, editor.session.plane)
	_animate_pose(rotation, target, 1.0)
	set_status(text)
	UiFeedback.haptic(_right, "confirm")


func apply_pose(centre: Vector3, rotation: Basis, scale: float) -> void:
	## Sets the part's pose on the table: where its middle is (console frame), how it is turned and how much it is scaled
	## (a multiple of the fitted size). The scale lives on the pivot, so everything on the copy (the sketch sheet, the plane
	## markers, the drawing) follows it.
	user_scale = scale
	pivot.position = centre
	pivot.basis = rotation.orthonormalized() * scale


func stop_pose_tween() -> void:
	if _orient_tween and _orient_tween.is_valid():
		_orient_tween.kill()


func _animate_pose(target_rotation: Basis, target_position: Vector3, target_scale: float) -> void:
	stop_pose_tween()
	var duration: float = tokens.duration(tokens.anim_medium)
	if duration <= 0.0:
		apply_pose(target_position, target_rotation, target_scale)
		return
	var from := pivot.basis.orthonormalized().get_rotation_quaternion()
	var to := target_rotation.orthonormalized().get_rotation_quaternion()
	var from_position := pivot.position
	var from_scale := user_scale
	var target_pivot := pivot
	_orient_tween = create_tween()
	_orient_tween.tween_method(func(t: float) -> void:
		if is_instance_valid(target_pivot) and pivot == target_pivot:
			apply_pose(from_position.lerp(target_position, t), Basis(from.slerp(to, t)), lerpf(from_scale, target_scale, t)), 0.0, 1.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func sync_copy_from_seated() -> void:
	## The arena node's mesh was replaced after an edit: show the same on the table copy and re-centre it.
	if seated == null or table_copy == null:
		return
	table_copy.mesh = seated.mesh
	for key in COPIED_METAS:
		if seated.has_meta(key):
			table_copy.set_meta(key, seated.get_meta(key))
		elif table_copy.has_meta(key):
			table_copy.remove_meta(key)
	for child in table_copy.get_children():
		if child is StaticBody3D:
			table_copy.remove_child(child)
			child.free()
	_give_copy_collider()
	var aabb := table_copy.get_aabb()
	var refit := TableSeat.fit_scale(aabb, fit_radius)
	if refit > 0.0:
		fit_scale = refit
		table_copy.scale = Vector3.ONE * fit_scale
		table_copy.position = TableSeat.copy_offset(aabb, fit_scale, Basis.IDENTITY)
	poke_render()


func show_filtered_view(glb_bytes: PackedByteArray) -> bool:
	## The table's COPY shows the part as the Build tree has it (a hidden feature's body left out, or rolled back to an earlier
	## feature): this mesh goes on the copy only, in the place and at the size the whole part has, so nothing jumps. If nothing is
	## left to show the copy is not drawn and has no collider. The arena's nodes are never given it.
	if table_copy == null:
		return false
	var parsed: Dictionary = _main.mesh_from_glb(glb_bytes)
	if not parsed["ok"]:
		return false
	for child in table_copy.get_children():
		if child is StaticBody3D:
			table_copy.remove_child(child)
			child.free()
	for key in COPIED_METAS:
		if key in ["face_ids", "body_ids", "topology"] and table_copy.has_meta(key):
			table_copy.remove_meta(key)
	if parsed["mesh"] == null:
		_view_empty = true
		apply_view_mode()
	else:
		table_copy.mesh = parsed["mesh"]
		for key in (parsed["metas"] as Dictionary):
			table_copy.set_meta(key, parsed["metas"][key])
		_give_copy_collider()
	poke_render()
	return true


func notify_edited(edited_part_id: String, nodes: Array = []) -> void:
	## A feature was added or taken back on this part: every arena instance of it (they share one definition) has stale
	## mates now. They are flagged, and the Enforce button follows the one on the table.
	for node in nodes:
		DirtyMates.mark(node)
	if seated != null:
		DirtyMates.mark(seated)
	_main.mark_dirty()
	part_edited.emit(edited_part_id)


func part_put_down(part: Node3D) -> void:
	## controller.gd calls this when a hand lets go of a part in the arena: a part with stale mates gets the Enforce button.
	if DirtyMates.is_dirty(part):
		enforce_button.show_for(part)


func add_mate_baseline(captured: Array) -> void:
	## Remembers what mates' faces looked like before an edit — once per reference: the FIRST sight is the baseline, so a later edit
	## (or an undo that brings the old shape back) is compared with how the mate was made, not with the previous edit.
	for entry in captured:
		var known := false
		for existing in mate_baseline:
			if existing["mate_id"] == entry["mate_id"] and existing["occurrence_id"] == entry["occurrence_id"] and existing["index"] == entry["index"] and existing["body_id"] == entry["body_id"]:
				known = true
				break
		if not known:
			mate_baseline.append(entry)


func update_mate_drift() -> void:
	## After the part's mesh changed: which mates now name a different face than when they were made. Replaces the last answer, so
	## undoing an edit that brings the faces back also clears the warning.
	var arena := get_tree().get_nodes_in_group("grabbable_parts").filter(func(n): return n is MeshInstance3D)
	var drifted := MateHealth.drifted(mate_baseline, arena)
	mate_drift.clear()
	for d in drifted:
		var list: Array = mate_drift.get(str(d["mate_id"]), [])
		list.append(d)
		mate_drift[str(d["mate_id"])] = list
	if not mate_drift.is_empty():
		set_status("%d mate(s) now point at different faces than before the edit." % mate_drift.size())


func enforce_mates() -> void:
	## The Enforce mates button: re-solves every mate of the assembly. A mate whose face the edit changed is SUPPRESSED first, not solved:
	## the backend would accept it and join whatever faces now have those numbers. The flags are cleared only if all the rest could be met.
	if _mates_tool == null:
		return
	var owner_id: String = _main.current_root_part_id()
	if owner_id == "":
		enforce_button.set_message("There is no assembly loaded to enforce.")
		return
	enforce_button.set_busy(true)
	var suppressed := 0
	var arena_nodes := get_tree().get_nodes_in_group("grabbable_parts").filter(func(n): return n is MeshInstance3D)
	remake_plan = MateHealth.remake_plan(_mates_tool.mates, MateHealth.flatten_drift(mate_drift), mate_baseline, arena_nodes)
	for mate_id in mate_drift.keys():
		var r: Dictionary = await api.request(HTTPClient.METHOD_PATCH, "/document/parts/%s/mates/%s" % [owner_id, mate_id], {"suppressed": true})
		if r["ok"]:
			suppressed += 1
	mate_drift.clear()
	mate_baseline.clear() # the mates are consistent again after this: the next edit starts a new baseline
	_last_suppressed = suppressed
	await _mates_tool.enforce_all(owner_id)


func remake_mates() -> void:
	## The offer after Enforce: each turned-off mate whose face has an equivalent in the new shape is made again on that face (a new mate with
	## the same type and value; DIDSA-CAD never changes what a mate references) and the old one is deleted, then everything is solved again.
	var plan := remake_plan.duplicate(true)
	remake_plan.clear()
	var owner_id: String = _main.current_root_part_id()
	if _mates_tool == null or owner_id == "" or plan.is_empty():
		return
	enforce_button.set_busy(true)
	var made := 0
	var failed := 0
	for entry in plan:
		var body := {"type": entry["type"], "references": entry["references"], "flipped": entry["flipped"], "allow_rotation": entry["allow_rotation"]}
		if entry["value"] != null:
			body["value"] = entry["value"]
		var created: Dictionary = await api.request(HTTPClient.METHOD_POST, "/document/parts/%s/mates" % owner_id, body)
		if created["ok"]:
			await api.request(HTTPClient.METHOD_DELETE, "/document/parts/%s/mates/%s" % [owner_id, entry["mate_id"]], null)
			made += 1
		else:
			failed += 1
	_main.mark_dirty()
	await _mates_tool.refresh_mates(owner_id)
	var text := "%d mate(s) remade on the equivalent face.%s" % [made, "" if failed == 0 else " %d could not be (the backend refused): remake them from Assembly > Mates." % failed]
	enforce_button.reset_label()
	await _mates_tool.enforce_all(owner_id)
	enforce_button.set_message(text)
	enforce_button.set_busy(false)
	enforce_button.hide_after(8.0)
	set_status(text)


func _on_enforce_finished(result: Dictionary) -> void:
	enforce_button.set_busy(false)
	var suppressed := _last_suppressed
	_last_suppressed = 0
	if bool(result.get("ok", false)):
		var cleared := DirtyMates.clear_all(get_tree())
		if suppressed > 0 and not remake_plan.is_empty():
			var offer_text := "%d mate(s) turned off: the edit changed the face they were made on. %d can be remade on the face that is now the same one." % [suppressed, remake_plan.size()]
			enforce_button.offer("Remake %d mate(s)" % remake_plan.size(), offer_text)
			set_status(offer_text)
		elif suppressed > 0:
			var text := "%d mate(s) turned off: the edit changed the face they were made on. Remake them from Assembly > Mates." % suppressed
			enforce_button.set_message(text)
			enforce_button.hide_after(8.0) # long enough to read; the badges are gone, so this is the only place it's said
			set_status(text)
		else:
			enforce_button.hide_button()
			set_status("Mates enforced.%s" % ("" if cleared == 0 else " %d part(s) up to date." % cleared))
	else:
		enforce_button.set_message("Couldn't satisfy every mate: %s" % "; ".join(result.get("problems", [])))
