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
## arena node is only touched again when the part is lifted off (grip it) or the table is
## closed. Lifting it brings the real node back at the arena's scale, in its original
## orientation, where the copy was, and from then on it's an ordinary part: put it down
## anywhere and that pose is saved like any other move. A copy rather than a reparent,
## because the arena's parts sit under a scaled root whose frame mates, pose saving and
## hide/section all assume (see docs/design-table.md).
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
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const CadApi := preload("res://scripts/design_table/cad_api.gd")
const TableEditor := preload("res://scripts/design_table/table_editor.gd")
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
@export var slab_thickness := 0.015
@export var tools_size := Vector2(0.60, 0.15) ## the tool deck, metres
@export var pixels_per_metre: float = 2667.0 ## the same physical text size as the wrist tablet
@export var deck_lean_degrees: float = 30.0 ## how far the deck is tipped up from flat, towards you
@export var deck_gap := 0.05 ## metres between the slab's front edge and the deck's top edge
@export var lean_degrees: float = 10.0 ## the whole console leans back a little: its front edge is lower than its back edge
@export var open_distance: float = 0.70 ## metres in front of you when summoned
@export var open_drop: float = 0.45 ## metres below your eyes when summoned
@export var hover_height: float = 0.20 ## metres above the slab where the part floats
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

var active_tool := ""
var seated: MeshInstance3D = null ## the arena's own node that is on the table (hidden meanwhile)
var pivot: Node3D = null ## the copy's pivot, floating above the slab; its basis is the part's orientation on the table
var table_copy: MeshInstance3D = null ## what's edited; a child of pivot, in the part's own mm frame
var fit_scale := 0.0 ## metres per mm of the part

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
var _slab: MeshInstance3D
var _slab_material: StandardMaterial3D
var _frame_material: StandardMaterial3D
var _ring: MeshInstance3D
var _ring_material: StandardMaterial3D
var _seen_revision := 0
var _activity_until_ms := 0
var _idle_left := 0.0
var _status := ""
var _seat_local_basis := Basis.IDENTITY ## the arena node's own basis (relative to its parent) when it was seated
var _seat_pose := Transform3D.IDENTITY ## its world transform when it was seated: what undo goes back to
var _last_drop_ok := false
var _orient_tween: Tween = null


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
	ui.undo_pressed.connect(func() -> void: editor.undo())
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
	set_status("Carry a part over the table and let go to edit it.")
	UiFeedback.play("open", self)
	opened.emit()


func close() -> void:
	if not _open:
		return
	return_part() # the real node comes back exactly where it was
	manager.deactivate()
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
	tool_changed.emit(tool_id)


func tool_deactivated(tool_id: String) -> void:
	if active_tool == tool_id:
		active_tool = ""
		editor.on_tool_changed("")
		tool_changed.emit("")


# --- Building ------------------------------------------------------------------------

func _build_slab() -> void:
	_slab = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(slab_size.x, slab_thickness, slab_size.y)
	_slab_material = StandardMaterial3D.new()
	_slab_material.roughness = 0.55
	_slab_material.metallic = 0.1
	box.material = _slab_material
	_slab.mesh = box
	_slab.position = Vector3(0.0, -slab_thickness * 0.5, 0.0) # its top face is the console's y = 0
	add_child(_slab)

	# A thin accent frame round the slab's top edge, and a ring under the part: where it floats.
	_frame_material = StandardMaterial3D.new()
	_frame_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var t := 0.006
	for spec in [
		{"size": Vector3(slab_size.x, t, t), "pos": Vector3(0, 0, slab_size.y * 0.5 - t * 0.5)},
		{"size": Vector3(slab_size.x, t, t), "pos": Vector3(0, 0, -slab_size.y * 0.5 + t * 0.5)},
		{"size": Vector3(t, t, slab_size.y), "pos": Vector3(slab_size.x * 0.5 - t * 0.5, 0, 0)},
		{"size": Vector3(t, t, slab_size.y), "pos": Vector3(-slab_size.x * 0.5 + t * 0.5, 0, 0)},
	]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = spec["size"]
		bar_mesh.material = _frame_material
		bar.mesh = bar_mesh
		bar.position = spec["pos"]
		add_child(bar)
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	ring_mesh.inner_radius = fit_radius - 0.004
	ring_mesh.outer_radius = fit_radius + 0.004
	ring_mesh.rings = 48
	_ring_material = StandardMaterial3D.new()
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mesh.material = _ring_material
	_ring.mesh = ring_mesh
	_ring.position = Vector3(0, 0.002, 0)
	_ring.scale = Vector3(1, 0.2, 1)
	add_child(_ring)
	_style_materials()


func _style_materials() -> void:
	## Colours from the live UI theme: re-run when the theme changes.
	_slab_material.albedo_color = tokens.bg_raised
	_frame_material.albedo_color = tokens.accent
	var ring: Color = tokens.accent
	_ring_material.albedo_color = Color(ring.r, ring.g, ring.b, 0.85 if _last_drop_ok else 0.30)


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
	var lean := deg_to_rad(90.0 - deck_lean_degrees)
	# The deck's top edge starts deck_gap in front of the slab's front edge, just under it.
	var top_edge := Vector3(0.0, -0.01, slab_size.y * 0.5 + deck_gap)
	_deck.position = top_edge + Vector3(0.0, -cos(lean) * tools_size.y * 0.5, sin(lean) * tools_size.y * 0.5) # its middle is half the deck's height down the slope from the top edge
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
	_update_drop_ring()
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
	table_copy.create_trimesh_collision()
	for child in table_copy.get_children():
		if child is StaticBody3D:
			(child as StaticBody3D).collision_layer = TABLE_LAYER
			(child as StaticBody3D).collision_mask = 0
	set_status("Editing %s." % part.name)
	poke_render()
	UiFeedback.haptic(_right, "confirm")
	part_seated.emit(part)
	editor.on_seated() # finds which part this is, then opens plane picking (a coroutine: not waited for)
	return true


func try_lift(hand: XRController3D) -> Dictionary:
	## controller.gd calls this when a grip starts. If the hand is on the seated part, the arena
	## node comes back at the arena's scale and its original orientation, where the copy was,
	## ready to be carried. {} if not; else {node, start} (start = the pose undo goes back to).
	if not _open or seated == null or pivot == null:
		return {}
	if hand.global_position.distance_to(pivot.global_position) > fit_radius + lift_reach:
		return {}
	var node := seated
	var start := _seat_pose
	var lifted_pose := TableSeat.lift_transform(
		(node.get_parent() as Node3D).global_transform.basis, _seat_local_basis, node.get_aabb(), pivot.global_position)
	node.global_transform = lifted_pose
	node.visible = true
	node.remove_meta("on_table")
	_clear_seat()
	set_status("Put it down anywhere, or back on the table to keep editing.")
	part_lifted.emit(node)
	return {"node": node, "start": start}


func return_part() -> void:
	## The table is closing (or the model was replaced): the arena node comes back untouched.
	if seated == null:
		return
	var node := seated
	if is_instance_valid(node):
		node.visible = true
		if node.has_meta("on_table"):
			node.remove_meta("on_table")
	_clear_seat()


func on_model_replaced() -> void:
	## main.gd is about to free every arena node: forget the seated one without touching it.
	_clear_seat()


func _clear_seat() -> void:
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


# --- Editing support (table_editor.gd) ----------------------------------------------------------

func configure_backend(url: String, key: String) -> void:
	api.configure(url, key)


func orient_to_plane(plane: Dictionary) -> void:
	## Turns the part on the table so the sketch plane lies flat, x to the right, y away from you.
	if pivot == null:
		return
	var target := SketchMath.orient_to_table(plane)
	if _orient_tween and _orient_tween.is_valid():
		_orient_tween.kill()
	var duration: float = tokens.duration(tokens.anim_medium)
	if duration <= 0.0:
		pivot.basis = target
		return
	var from := pivot.basis.get_rotation_quaternion()
	var to := target.get_rotation_quaternion()
	var target_pivot := pivot
	_orient_tween = create_tween()
	_orient_tween.tween_method(func(t: float) -> void:
		if is_instance_valid(target_pivot):
			target_pivot.basis = Basis(from.slerp(to, t)), 0.0, 1.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


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
	table_copy.create_trimesh_collision()
	for child in table_copy.get_children():
		if child is StaticBody3D:
			(child as StaticBody3D).collision_layer = TABLE_LAYER
			(child as StaticBody3D).collision_mask = 0
	var aabb := table_copy.get_aabb()
	var refit := TableSeat.fit_scale(aabb, fit_radius)
	if refit > 0.0:
		fit_scale = refit
		table_copy.scale = Vector3.ONE * fit_scale
		table_copy.position = TableSeat.copy_offset(aabb, fit_scale, Basis.IDENTITY)
	poke_render()


func notify_edited(edited_part_id: String) -> void:
	## A feature was added or taken back on this part.
	part_edited.emit(edited_part_id)
