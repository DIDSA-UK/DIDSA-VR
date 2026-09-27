extends Node
## Milestone 4's last Assembly tool (vision brief: "Colours, sections and
## measurements"). DIDSA-CAD's own sectioning endpoint
## (`backend/app/document/section.py::compute_section_mesh`) does a real OCCT
## `BRepAlgoAPI_Common` boolean per Body per plane, then re-tessellates the
## result, from scratch, on every single request — no caching, no persisted
## Feature (confirmed by reading that module directly, not just trusting
## `docs/backend-api-notes.md`'s own summary of it). That is much too slow to
## call every frame for a plane you're dragging with a real hand at 90 Hz, so
## this tool is entirely client-side and visual-only: a world-space clip
## plane, applied by a small shader (shaders/section_clip.gdshader) shared by
## every loaded part via a GLOBAL shader uniform (one RenderingServer.
## global_shader_parameter_set() call per frame, not one per part). It never
## calls the backend at all. Confirmed for real (not just headless) that the
## shader genuinely discards fragments on the excluded side, not just fades
## them, via a software (Mesa llvmpipe) render under Xvfb — see
## tests/section_tool.gd.
##
## Scope for this pass: ONE clip plane. The backend's own endpoint supports
## several (AND-combined, for a quarter-cutaway), but the vision brief's
## Assembly tools list doesn't call for that and one plane already covers the
## common "see inside the assembly" case — same kind of narrowing Mates made
## for face-only picking in its own first pass.
##
## Interaction: a single grabbable gizmo (a translucent disc plus a small
## arrow showing which side stays), toggled by the wrist tablet's Sections
## tab. GRIP drags/tilts it 1:1, exactly like grabbing a part — but this is
## its OWN mechanism, not a member of the "grabbable_parts" group: that group
## also feeds two_hand_model.gd's model-bounds/Fit-to-view math and main.gd's
## Tools-tab whole-assembly hide/isolate ops, and the gizmo must never be
## swept into either (it isn't part of the assembly, shouldn't move with a
## Scale-view change, and shouldn't be hidden by "Hide all"). So
## controller.gd calls try_grab()/release()/update_held() directly — three
## small hooks, mirroring exactly how mates_tool_active/hide_tool_active
## already redirect the TRIGGER for other tools, just applied to GRIP
## instead. This also makes a grab unambiguous: try_grab() is checked before
## controller.gd's own part-grab search, in the same synchronous call, so a
## hand can never grab both at once.
##
## The other real design problem: colour_tool.gd already owns
## `material_override` on parts (its optimistic local colour preview). Rather
## than touch that shipped, real-backend-confirmed code, this tool WRAPS
## whatever is currently in `material_override` (null, or colour_tool's own
## flat-colour StandardMaterial3D) into a clip-aware ShaderMaterial only
## while active, re-deriving the wrap every frame from whatever's actually
## there right now (self-healing if colour_tool changes a part's colour
## while sectioning is on — briefly unclipped for that one part until the
## next frame's reconcile, not a crash), and restoring exactly what was there
## before on deactivate. Zero changes needed to colour_tool.gd.

const OneEuro := preload("res://scripts/one_euro.gd")
const TwoHandModel := preload("res://scripts/two_hand_model.gd") ## just for its STEADINESS_* tables, same convention controller.gd's own preload uses
const ClipShader := preload("res://shaders/section_clip.gdshader")

signal changed() ## wrist tablet refresh, mirroring mates_tool.gd's picks_changed

@export var plane_radius: float = 0.4 ## metres; the gizmo disc's visual/grab radius — a fixed human-scale default (matching two_hand_model.gd's own fit_radius precedent) rather than sized to the model, so it stays predictable regardless of what's loaded
@export var grab_extra_reach: float = 0.08 ## metres beyond the disc's own edge — the disc is thin, so a bit of slack makes it easier to catch
@export var spawn_distance: float = 0.6 ## metres in front of the camera when the tool is switched on

var active := false
var flipped := false
var command_stack = null ## set via setup(); shared undo/redo history

var _gizmo: Node3D = null
var _held_by: Node3D = null ## typed as plain Node3D, not XRController3D, so tests can hand it a bare Node3D stand-in — try_grab()/release()/update_held() only ever use global_transform/global_position off it
var _grab_filter := OneEuro.new()
var _grab_offset := Transform3D.IDENTITY
var _gesture_start_transform := Transform3D.IDENTITY

var _wrapped: Dictionary = {} ## part (MeshInstance3D) -> the ShaderMaterial we installed as its material_override
var _unclipped_override: Dictionary = {} ## part -> whatever material_override it had right before we wrapped it (Material or null)

static var _params_registered := false ## RenderingServer's global shader parameters are process-wide, not per-instance — a `static var` (shared by every SectionTool instance, not one bool per instance) is the correct guard; re-adding an already-registered name is a real engine ERROR, not a no-op (confirmed headless — only ever hit here when more than one SectionTool exists in the same process, i.e. this project's own tests, not the real app, which creates exactly one)


func _init() -> void:
	_register_global_params()


func setup(stack) -> void:
	command_stack = stack


func _register_global_params() -> void:
	if _params_registered:
		return
	_params_registered = true
	RenderingServer.global_shader_parameter_add("section_plane_origin", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	RenderingServer.global_shader_parameter_add("section_plane_normal", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.UP)
	RenderingServer.global_shader_parameter_add("section_enabled", RenderingServer.GLOBAL_VAR_TYPE_BOOL, false)


func set_steadiness(level: int) -> void:
	var clamped := clampi(level, 0, TwoHandModel.STEADINESS_NAMES.size() - 1)
	_grab_filter.min_cutoff = maxf(TwoHandModel.STEADINESS_CUTOFF_HZ[clamped], 0.01)
	_grab_filter.beta = TwoHandModel.STEADINESS_BETA


func set_active(on: bool, camera: Node3D = null) -> void:
	if on == active:
		return
	active = on
	if on:
		_spawn_gizmo(camera)
		_update_global_plane()
	else:
		if _held_by != null:
			_held_by.set_meta("section_gizmo_held", false) # deactivated mid-grab: release() never ran, so this meta would otherwise stay stuck permanently on that hand
			_held_by = null
		_unwrap_all()
		RenderingServer.global_shader_parameter_set("section_enabled", false)
		_despawn_gizmo()
	changed.emit()


func set_flipped(on: bool) -> void:
	flipped = on
	_update_global_plane()
	changed.emit()


func reset() -> void:
	## Called when the model is about to be replaced: every tracked part is
	## about to be freed, so any reference to one in _wrapped/
	## _unclipped_override is about to be stale. Deliberately does NOT turn
	## the tool off or drop the gizmo — same precedent as mates_tool_active
	## staying on across a reload (only its picks are cleared) — a floating
	## clip plane is independent of which model is loaded; reconcile() just
	## treats every part of the new model as unwrapped and wraps it fresh.
	_wrapped.clear()
	_unclipped_override.clear()


func gizmo() -> Node3D:
	return _gizmo


func is_gizmo(node: Node) -> bool:
	return node == _gizmo


func try_grab(hand: Node3D, extra_reach: float = 0.0) -> bool:
	## Called from controller.gd's _try_grab(), BEFORE its own part-grab
	## search — grabbing the gizmo (if active, unheld, and this hand is
	## within reach of the disc) takes priority and returns true, so
	## controller.gd never also runs a part-grab for the same press. Reach is
	## measured from the disc's centre, not its actual thin-box geometry
	## (unlike controller.gd's own _reach_distance() for parts) — the gizmo
	## has no collider at all (deliberately: see the class docstring's
	## grabbable_parts reasoning), so this is a simple sphere test.
	if not active or _gizmo == null or _held_by != null:
		return false
	var reach := hand.global_position.distance_to(_gizmo.global_position)
	if reach > plane_radius + grab_extra_reach + extra_reach:
		return false
	_held_by = hand
	# Real-headset feedback: grabbing the gizmo also dragged the whole
	# model, because two_hand_model.gd's own _hand_free() only ever checks
	# controller.gd's held_node (which this deliberately never sets — see
	# the class docstring) to decide whether a hand is "free" to drag the
	# whole model. Same meta convention this tool already uses to talk to
	# controller.gd (ui_hover/ui_hit_distance) — two_hand_model.gd checks
	# this before falling through to its own held_node check.
	hand.set_meta("section_gizmo_held", true)
	_grab_offset = hand.global_transform.affine_inverse() * _gizmo.global_transform
	_grab_filter.reset(hand.global_position)
	_gesture_start_transform = _gizmo.global_transform
	return true


func release(hand: Node3D) -> bool:
	if _held_by != hand:
		return false
	_held_by = null
	hand.set_meta("section_gizmo_held", false)
	_push_move_command()
	return true


func update_held(hand: Node3D, delta: float, steadiness_on: bool = true) -> void:
	if _held_by != hand or _gizmo == null:
		return
	var filtered_pos: Vector3 = _grab_filter.filter(hand.global_position, delta) if steadiness_on else hand.global_position
	_gizmo.global_transform = Transform3D(hand.global_transform.basis, filtered_pos) * _grab_offset
	_update_global_plane()


func _push_move_command() -> void:
	if command_stack == null or _gizmo == null:
		return
	var before := _gesture_start_transform
	var after := _gizmo.global_transform
	if before.is_equal_approx(after):
		return # no net move: nothing worth undoing
	var gizmo := _gizmo
	command_stack.push("move section plane",
		func() -> void:
			gizmo.global_transform = before
			_update_global_plane(),
		func() -> void:
			gizmo.global_transform = after
			_update_global_plane())


func _spawn_gizmo(camera: Node3D) -> void:
	_gizmo = Node3D.new()
	_gizmo.name = "SectionPlaneGizmo"
	# Parented under this tool node itself, not under assembly_root or a
	# separately-passed node: main.gd already adds this tool as a child of
	# Main (a Node3D with identity transform) before anything can call
	# set_active(), and Godot's Node3D walks up through any number of plain
	# Node ancestors to find the nearest Node3D one for its own
	# global_transform — see this tool's own class docstring for why the
	# gizmo must NOT live under assembly_root (it isn't part of the model:
	# two_hand_model.gd's bounds/Fit-to-view math and main.gd's Tools-tab
	# whole-assembly ops must never see it).
	add_child(_gizmo)
	_gizmo.add_child(_build_disc())
	_gizmo.add_child(_build_arrow())
	_gizmo.add_child(_build_tail())
	_place_in_front_of(camera)


func _despawn_gizmo() -> void:
	if is_instance_valid(_gizmo):
		_gizmo.queue_free()
	_gizmo = null


func _place_in_front_of(camera: Node3D) -> void:
	if camera == null:
		_gizmo.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.2, -0.6))
		return
	# Yaw-only forward, same convention popup_keyboard.gd's own
	# _place_in_front_of_camera() uses: the plane appears upright and facing
	# you regardless of whether you're looking up or down when you toggle the
	# tool on. Its normal (the "kept" direction before any Flip) points back
	# at the camera, so the default cut immediately removes the half of the
	# model between you and the plane — visibly doing something the instant
	# it appears, rather than starting edge-on and invisible in effect.
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	forward = Vector3.FORWARD if forward.length() < 0.001 else forward.normalized()
	var origin := camera.global_position + forward * spawn_distance
	_gizmo.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), origin)


const ARROW_HEIGHT := 0.08 ## the arrowhead pyramid's own height along the gizmo's local Z
const ARROW_BASE_RADIUS := 0.03
const TAIL_RADIUS := 0.006

func _arrow_mid_offset() -> float:
	## Distance from the gizmo's own origin (the plane surface) to the
	## arrowhead's own local origin (its midpoint, since CylinderMesh/a
	## pyramid built from one is centred on its own origin) — shared by
	## _build_tail()'s own length and _update_global_plane()'s repositioning,
	## so the two never drift out of sync with each other.
	return plane_radius * 0.5 + 0.05


func _build_disc() -> MeshInstance3D:
	## A rectangle (real-headset feedback: a circular disc read ambiguously
	## as "the cut" vs "a grab handle" — a flat rectangular panel reads more
	## like a real cutting plane). BoxMesh's own size axes already sit along
	## local X/Y/Z with no rotation needed, unlike the CylinderMesh this
	## replaced (whose flat caps needed a 90° turn to face local Z).
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(plane_radius * 2.0, plane_radius * 2.0, 0.006)
	instance.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.3, 0.9, 1.0, 0.25)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	return instance


func _build_arrow() -> MeshInstance3D:
	## A square-based pyramid on the KEPT side (real-headset feedback: a
	## round cone here too), so which half the plane keeps is visible at a
	## glance without opening the tablet — flips to the other face when Flip
	## is toggled (_update_global_plane() below moves it). A CylinderMesh
	## with top_radius=0 and radial_segments=4 IS a square pyramid — same
	## mesh type the disc used to use, just a 4-gon cross-section instead of
	## a circle.
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = ARROW_BASE_RADIUS
	mesh.height = ARROW_HEIGHT
	mesh.radial_segments = 4
	instance.mesh = mesh
	instance.rotation_degrees.x = -90.0 # apex points local -Z by default after this, matching the disc's own front convention
	instance.name = "KeptSideArrow"
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.9)
	mesh.material = mat
	return instance


func _build_tail() -> MeshInstance3D:
	## A thin rod from the plane's own surface out to the arrowhead's base,
	## so the indicator reads as one continuous pin (plane → tail →
	## arrowhead) rather than a shape floating near the plane — real-headset
	## feedback. Length/position are set for real in _update_global_plane()
	## (which runs at spawn and on every drag/Flip); this just builds the
	## mesh with a placeholder length so the node exists to update.
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = TAIL_RADIUS
	mesh.bottom_radius = TAIL_RADIUS
	mesh.height = 0.01
	mesh.radial_segments = 8
	instance.mesh = mesh
	instance.rotation_degrees.x = -90.0 # same "long axis along local Z" convention as the arrow
	instance.name = "PlaneTail"
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.1, 0.7)
	mesh.material = mat
	return instance


func effective_normal() -> Vector3:
	## The direction whose side stays visible — local -Z of the gizmo
	## (matching the disc's own front-face convention above), negated by
	## Flip. Mirrors section.py's own _effective_normal() exactly (normal
	## negated on flip, nothing else recomputed) even though this is a
	## different, simpler, visual-only algorithm — deliberate parity so the
	## two "flip" concepts mean the same thing if this tool ever does call
	## the backend endpoint for something (e.g. a future precise cut export).
	if _gizmo == null:
		return Vector3.UP
	var normal := -_gizmo.global_transform.basis.z.normalized()
	return -normal if flipped else normal


func _update_global_plane() -> void:
	if _gizmo == null:
		return
	var normal := effective_normal()
	RenderingServer.global_shader_parameter_set("section_plane_origin", _gizmo.global_position)
	RenderingServer.global_shader_parameter_set("section_plane_normal", normal)
	RenderingServer.global_shader_parameter_set("section_enabled", true)
	# effective_normal() is always +/- the gizmo's own local -Z (Flip just
	# picks the sign) — so both the arrow's and the tail's own LOCAL offsets
	# are constants, no inverse-transform needed: local -Z when kept, local
	# +Z when flipped.
	var local_z := 1.0 if flipped else -1.0
	var arrow_mid_offset := _arrow_mid_offset()
	var arrow: Node3D = _gizmo.get_node_or_null("KeptSideArrow")
	if arrow:
		arrow.position = Vector3(0, 0, local_z * arrow_mid_offset)
	var tail: MeshInstance3D = _gizmo.get_node_or_null("PlaneTail")
	if tail:
		# Spans from the plane's own surface (gizmo origin) out to the
		# arrowhead's base (its midpoint minus half its own height — the
		# apex points further out, away from the plane).
		var tail_length: float = maxf(arrow_mid_offset - ARROW_HEIGHT * 0.5, 0.001)
		(tail.mesh as CylinderMesh).height = tail_length
		tail.position = Vector3(0, 0, local_z * tail_length * 0.5)


func reconcile(parts: Array) -> void:
	## Call once a frame while active: wraps any part whose material_override
	## isn't (currently, by reference) the ShaderMaterial this tool installed
	## for it — a freshly-loaded part, one colour_tool.gd just changed, or one
	## this tool has never seen — and leaves an already-correctly-wrapped part
	## untouched. Cheap (a dictionary lookup + reference compare per part) so
	## running it every frame while the tool is on is fine.
	if not active:
		return
	var still_present := {}
	for part in parts:
		if not (part is MeshInstance3D):
			continue
		still_present[part] = true
		if _wrapped.has(part) and _wrapped[part] == part.material_override:
			continue # already wrapped and untouched since — has() matters: a never-wrapped part's material_override is also null, which Dictionary.get()'s own "missing key" default would otherwise collide with
		_wrap(part)
	for part in _wrapped.keys():
		if not still_present.has(part):
			_wrapped.erase(part)
			_unclipped_override.erase(part)


func _wrap(part: MeshInstance3D) -> void:
	var current: Material = part.material_override
	_unclipped_override[part] = current
	var albedo := _albedo_of(current, part)
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = ClipShader
	shader_mat.set_shader_parameter("albedo_color", albedo)
	part.material_override = shader_mat
	_wrapped[part] = shader_mat


func _albedo_of(material: Material, part: MeshInstance3D) -> Color:
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).albedo_color
	# No override: read the part's own glTF-generated material (mesh_export.py
	# only ever sets baseColorFactor, so a StandardMaterial3D with just
	# albedo_color is exactly what GLTFDocument produces here — see
	# shaders/section_clip.gdshader's own docstring).
	var base := part.get_active_material(0)
	if base is BaseMaterial3D:
		return (base as BaseMaterial3D).albedo_color
	return Color(0.7, 0.7, 0.7, 1.0) ## same neutral default colour_tool.gd's DEFAULT_MATERIAL_COLOR uses, for a part with no material at all


func _unwrap_all() -> void:
	for part in _wrapped.keys():
		if is_instance_valid(part) and part.material_override == _wrapped[part]:
			part.material_override = _unclipped_override.get(part)
	_wrapped.clear()
	_unclipped_override.clear()
