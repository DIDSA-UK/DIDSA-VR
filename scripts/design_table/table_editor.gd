extends Node
## What happens on the design table once a part is on it: the laser, the sketch, the features. design_table.gd is the
## console (slab, deck, seating); this is the editing session that rides on it, one per seated part.
##
## States:
##   idle        nothing is on the table (or there is no backend to edit against)
##   pick_plane  the part is on the table and no sketch is open: aim at one of its flat faces or one of the three reference
##               planes and pull the trigger. The face under the laser lights up; on the pick the part turns to lie on the
##               table with that plane flat, and the sketch opens
##   opening     the backend is making the plane and the sketch
##   sketch      a sketch is open: the laser meets the SKETCH SHEET (a plane through the part), snapped, and the trigger
##               places points / picks entities / types dimensions, per the active tool
##   pick_edges  Fillet / Chamfer: aim at the part's edges and pull the trigger to add or remove them
##   pick_faces  Shell: the same with faces (the ones to open)
## Mirror needs no state of its own: it uses plane picking (pick_plane) and, instead of opening a sketch, mirrors the part across the plane or flat face.
##
## Extrude, Fillet and Chamfer are applied from the options row under the tool row; each ends with a fresh mesh of the part
## fetched from the backend, put on the table AND on every arena instance of it.
##
## The laser claims the shared "ui_hover" meta whenever it's on the part or the sheet (unless the deck already did), the same
## protocol every floating panel uses, so a trigger here never also selects something in the arena.

signal state_changed(state: String)
signal geometry_changed ## the part's mesh was replaced after an edit
signal view_changed ## only what the table's copy shows changed (Hide / Show, rollback): the part itself did not

const LaserPick := preload("res://scripts/laser_pick.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const SketchView := preload("res://scripts/design_table/sketch_view.gd")
const SketchClip := preload("res://scripts/design_table/sketch_clip.gd")
const SketchPicks := preload("res://scripts/design_table/sketch_picks.gd")
const PartReferences := preload("res://scripts/design_table/part_references.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")
const PlaneMarkers := preload("res://scripts/design_table/plane_markers.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const FeatureTools := preload("res://scripts/design_table/features/feature_tools.gd")
const FeaturePreview := preload("res://scripts/design_table/feature_preview.gd")
const BuildTree := preload("res://scripts/design_table/build_tree.gd")
const MateHealth := preload("res://scripts/design_table/mate_health.gd")
const FaceHighlight := preload("res://scripts/face_highlight.gd")
const SketchSelection := preload("res://scripts/design_table/sketch_selection.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const SKETCH_TOOLS := ["line", "rectangle", "circle", "arc", "polygon", "point", "slot"]
const SelectMenuIds := ["horizontal", "vertical", "parallel", "perpendicular", "equal_length", "collinear", "concentric", "equal_radius", "tangent", "coincident", "point_on_line", "at_midpoint", "point_on_curve", "fix", "construction", "delete", "clear"]
const EDIT_TOOLS := ["trim", "offset"] ## sketch tools that act on a picked entity (not on taps)
const SELECT_TOOL := "select" ## picks any entity; the menu under the tool row says what the selection can do
const CONSTRAIN_TOOLS := ["horizontal", "vertical", "parallel", "perpendicular", "coincident"]
const PICK_STATES := ["pick_edges", "pick_faces", "pick_bodies", "pick_curves"] ## the states where the laser picks things on the part itself
const PICK_FROM_STATES := ["sketch", "pick_plane", "extrude", "pick_edges", "pick_faces", "pick_bodies", "pick_curves"] ## where choosing a picking tool is allowed to switch the state
const CURVE_REACH := 0.012 ## world metres around the laser in which a curve of an earlier sketch is picked
const SIGNED_OPTIONS := ["mb_dx", "mb_dy", "mb_dz"] ## settings that may be negative or zero (a move along an axis)
const PICK_RANGE := 4.0 ## metres: how far the laser reaches onto the table
const SNAP_RADIUS := 0.012 ## world metres around the laser in which a snap is taken
const PICK_RADIUS := 0.014 ## world metres around the laser in which an entity is picked
const GHOST_RADIUS := 0.030
const MENU_SLOTS := 6 ## buttons in the options row

var table ## design_table.gd
var api ## cad_api.gd, or anything with request(method, path, body) and fetch_bytes(path); null = no backend
var state := "idle"
var session: RefCounted = null ## sketch_session.gd while a sketch is open
var features: RefCounted = null ## part_features.gd
var tools: Dictionary = FeatureTools.make_all() ## tool id -> features/feature_tool.gd: what each feature tool shows, does on a pick and sends
var view: Node3D = null ## sketch_view.gd, a child of the table's copy
var repick_point := "" ## a flagged reference point the user is choosing a replacement corner for ("" = not re-picking)
var _repick_queue: Array = [] ## the flagged points still to do, in order
var clip := SketchClip.new() ## clips the copy to the sketch window while a sketch is open (sketch_clip.gd)
var markers: Node3D = null ## plane_markers.gd, a child of the table's copy
var highlight: Node = null ## this table's own face_highlight.gd (so Mates / Measure never see it)
var part_id := "" ## the PART DEFINITION being edited (every instance of it changes), resolved from the seated node's occurrence
var chosen_face := {} ## {body_id, index} when the sketch is on a face of the part
var chosen_plane := "" ## "XY" | "XZ" | "YZ" when it's on a reference plane
var edges: Array = [] ## picked edge entities (Fillet / Chamfer)
var redo_stack: Array = [] ## what Undo took back, newest last: {kind: "create", type, route, body} (the create request, sent again by Redo: the feature gets a new id) or {kind: "edit", entry} (a Build-tree edit: its new value is put back). Any new action clears it
var created_requests := {} ## id of a feature made here -> {type, route, body}: how to make it again
var feature_stack: Array = [] ## what Undo takes back after the sketch is spent, newest last: the id of a feature made here (taken back by deleting it), or {kind: "edit", id, type, payload} for a value changed in the Build tree (taken back by putting the old value back)
var options := {"boss": true, "flip": false, "new_body": false, "depth": 10.0, "radius": 2.0, "distance": 2.0, "angle": 360.0, "thickness": 2.0, "shell_direction": "inward", "mirror_fuse": false, "plane_offset": 10.0, "plane_flip": false, "ruled": false, "mf_offset": 5.0, "mf_flip": false, "mb_dx": 0.0, "mb_dy": 0.0, "mb_dz": 0.0, "mb_copy": false, "sb_factor": 1.5, "offset_dist": 5.0, "offset_flip": false, "bool_op": "subtract", "bool_consume": true,
	"pat_type": "rectangular", "pat_dir1": "x", "pat_count1": 3.0, "pat_spacing1": 20.0, "pat_rev1": false, "pat_dir2": "none", "pat_count2": 2.0, "pat_spacing2": 20.0, "pat_rev2": false,
	"pat_count_ang": 4.0, "pat_angle": 360.0, "pat_rev_ang": false, "pat_merge": false, "pat_pick": "bodies"}
var faces: Array = [] ## picked face entities (Shell)
var bodies: Array = [] ## picked body entities {kind: "body", body_id, key} (Pattern, Boolean, Merge...: the laser lights the whole body)
var curve_picks: Array = [] ## picked curves of earlier sketches {kind: "curve", sketch_feature_id, sketch_id, entity_type, entity_id, key} in pick order (Loft sections, Sweep paths, Pattern directions)
var curve_limit := 0 ## how many curves one pick may hold (0 = any number)
var sketch_picks: Node3D = null ## sketch_picks.gd while curves are being picked: the lines and curves of the finished sketches, on the copy
var preview := FeaturePreview.new() ## the translucent result before Apply
var preview_enabled := true ## off: nothing is created or drawn until Apply
var preview_feature_id := "" ## the feature an eager preview created (PATCHed as the settings change, deleted on Cancel, kept by Apply)
var _preview_running := false
var _preview_again := false
var editing: Dictionary = {} ## a feature opened from its Build row in its own tool: {id, type, original (the row)}; Apply PATCHes it, Undo puts the old values back
var plane_base: Dictionary = {} ## what Create Plane offsets from: {fixed} | {face} | {plane_feature_id, plane}
var body_limit := 0 ## how many bodies one pick may hold (0 = any number); a pick over the limit replaces the oldest
var revolve_axis := "" ## the id of the sketch line Revolve spins the profile about ("" = not picked yet)
var fixing: Dictionary = {} ## a flagged Build row being mended (begin_fix): {feature_id, type, kind ("edge" | "face"), paths, state_before}: the laser picks one replacement per path on the part as the feature saw it, then Apply fix
var hovering := false ## the laser is on the part or the sheet this frame, and this editor holds the claim

var _hover_uv: Variant = null
var _snap: Dictionary = {}
var _hover_entity: Dictionary = {}
var _hover_plane := ""
var _hover_face: Dictionary = {}
var part_refs: RefCounted = null ## part_references.gd: the part's vertices and edges projected onto the sketch plane (null if they can't be used)
var _sheet_vertices: Array = []
var _last_view_key := ""
var _orient_tween: Tween = null
var _opened_revision := 0 ## the sketch session's revision when the sketch was opened
var _menu_key := ""
var _menu_page := 0 ## which page of the Select tool's menu is showing
var _canvas_msec := 0 ## when the drawing was last rebuilt for a zoom
var _canvas_stale := false ## a zoom has changed the part's scale since the drawing was last rebuilt
var _edited_nodes: Array = [] ## the arena nodes the last refresh updated: every instance of the part


func setup(p_table, p_api) -> void:
	table = p_table
	api = p_api
	features = PartFeatures.new(Callable(self, "_call"))
	table._right.button_pressed.connect(_on_right_pressed)


func _call(method: int, path: String, body) -> Dictionary:
	## The api Callable the sketch session and the feature calls share. A missing backend is an ordinary failed call.
	if api == null:
		return {"ok": false, "code": 0, "json": null, "error": "no backend configured"}
	return await api.request(method, path, body)


func set_state(new_state: String) -> void:
	if state == new_state:
		return
	if state == "pick_curves" and sketch_picks != null and is_instance_valid(sketch_picks):
		sketch_picks.clear() # leaving curve picking: the earlier sketches' lines go from the part (a tool that switches between picking kinds keeps its picks)
	state = new_state
	state_changed.emit(state)
	_update_options()


# --- Lifecycle ------------------------------------------------------------------------

func on_seated() -> void:
	## A part has just been put on the table. Finds which PART it is (the node only names the assembly that owns the
	## occurrence), then opens plane picking.
	_reset()
	var copy: MeshInstance3D = table.table_copy
	var aabb := copy.get_aabb()
	var extent := aabb.size.length() * 1.25
	markers = PlaneMarkers.new()
	markers.name = "PlaneMarkers"
	copy.add_child(markers)
	markers.setup(extent, aabb.get_center(), table.fit_scale)
	highlight = FaceHighlight.new()
	highlight.name = "EditHighlight"
	table.add_child(highlight)
	if api == null or not api.is_configured():
		set_state("idle")
		table.set_status("Editing needs the DIDSA-CAD backend, and none is configured.")
		return
	set_state("opening")
	table.set_status("Looking up the part...")
	var node: Node3D = table.seated
	var found: String = await resolve_definition(str(node.get_meta("owner_part_id", "")), str(node.get_meta("occurrence_id", "")))
	if table.seated != node or table.table_copy == null:
		return # lifted or closed while we were asking
	if found.begins_with("!"):
		var message := found.substr(1)
		table.return_part()
		table.set_status(message)
		return
	part_id = found
	set_state("pick_plane")
	_say_pick_plane()


func resolve_definition(owner_id: String, occurrence_id: String) -> String:
	## The id of the PART an arena node shows. A node's "owner_part_id" is the assembly that holds it, not the part itself
	## (the glb doesn't name that), so it's looked up through the owner's occurrences. Returns "!reason" if it can't be edited
	## here: an assembly of other parts, or no part behind it.
	var definition := owner_id # root content: the owner's own geometry
	if occurrence_id != "":
		var rows := await _occurrence_rows(owner_id)
		definition = str(rows.get(occurrence_id, ""))
		if definition == "":
			return "!That placed part doesn't point at a part the backend can edit."
	var children: Dictionary = await _call(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % definition, null)
	if children["ok"] and children["json"] is Array and not (children["json"] as Array).is_empty():
		return "!That is an assembly of other parts. Put one of its parts on the table instead."
	return definition


func _occurrence_rows(owner_id: String) -> Dictionary:
	## occurrence id -> the part definition it places, for one owner.
	var r: Dictionary = await _call(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % owner_id, null)
	var rows := {}
	if r["ok"] and r["json"] is Array:
		for occ in r["json"]:
			var resolved = occ.get("resolved_part_id")
			rows[str(occ.get("id", ""))] = str(resolved) if resolved != null else ""
	return rows


func arena_nodes_of(definition_id: String) -> Array:
	## Every arena node that shows this part, wherever it is placed.
	var out: Array = []
	var cache := {}
	for node in table.get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is MeshInstance3D) or not node.has_meta("owner_part_id"):
			continue
		var owner_id := str(node.get_meta("owner_part_id"))
		var occurrence_id := str(node.get_meta("occurrence_id", ""))
		var found := owner_id
		if occurrence_id != "":
			if not cache.has(owner_id):
				cache[owner_id] = await _occurrence_rows(owner_id)
			found = str((cache[owner_id] as Dictionary).get(occurrence_id, ""))
		if found == definition_id:
			out.append(node)
	return out


func on_cleared() -> void:
	## The part left the table (lifted, or the table closed).
	_reset()
	set_state("idle")


func _reset() -> void:
	cancel_preview()
	editing = {}
	if _orient_tween and _orient_tween.is_valid():
		_orient_tween.kill()
	clip.end()
	repick_point = ""
	_repick_queue.clear()
	session = null
	part_id = "" # no part behind the table now: nothing keyed on it (the Build tree) may read from the backend
	view = null
	markers = null
	if highlight != null and is_instance_valid(highlight):
		highlight.queue_free()
	highlight = null
	chosen_face = {}
	chosen_plane = ""
	revolve_axis = ""
	edges.clear()
	faces.clear()
	feature_stack.clear()
	hovering = false
	_hover_uv = null
	_snap = {}
	_hover_entity = {}
	_hover_plane = ""
	_hover_face = {}
	_sheet_vertices.clear()
	_last_view_key = ""
	redo_stack.clear()
	created_requests.clear()
	table.ui.set_undo_enabled(false)
	table.ui.set_redo_enabled(false)
	table.ui.set_options([])
	table.ui.set_sketching(false)


func _say_pick_plane() -> void:
	if table.is_blank():
		table.set_status("%s is empty. Aim at one of the three reference planes and pull the trigger to sketch on it." % table.seated.name)
		return
	table.set_status("Aim at a flat face or a reference plane and pull the trigger to sketch on it.")


# --- Per frame ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	hovering = false
	if state == "idle" or not table.is_open() or table.table_copy == null:
		return
	var origin: Vector3 = table._right.global_position
	var dir: Vector3 = -table._right.global_transform.basis.z.normalized()
	match state:
		"pick_plane":
			_hover_pick_plane(origin, dir)
		"sketch":
			_follow_window()
			if view != null and is_instance_valid(view):
				view.refresh_references()
			_settle_canvas()
			_hover_sketch(origin, dir)
		"pick_edges":
			_hover_edges(origin, dir)
		"pick_faces":
			_hover_faces(origin, dir)
		"pick_bodies":
			_hover_bodies(origin, dir)
		"pick_curves":
			_hover_curves(origin, dir)
	if state != "pick_plane" and markers != null:
		markers.set_hover("")


func _claim(distance: float) -> bool:
	## Takes the laser for the part / sheet, unless something else (the deck, a window) already has this frame.
	var right: XRController3D = table._right
	if right.get_meta("ui_hover", false):
		return false
	right.set_meta("ui_hover", true)
	right.set_meta("ui_hit_distance", distance)
	return true


func _copy_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	return LaserPick.ray(table.get_world_3d(), origin, dir, PICK_RANGE, func(part: Node3D) -> int:
		return LaserPick.HIT if part == table.table_copy else LaserPick.BLOCK, table.TABLE_LAYER)


func _hover_pick_plane(origin: Vector3, dir: Vector3) -> void:
	var face_hit := _copy_ray(origin, dir)
	var face_distance: float = face_hit.get("distance", INF) if not face_hit.is_empty() else INF
	var plane_hit := {}
	var plane_distance := INF
	if markers != null:
		var to_local: Transform3D = table.table_copy.global_transform.affine_inverse()
		var local_origin := to_local * origin
		var local_dir := to_local.basis * dir
		plane_hit = markers.intersect(local_origin, local_dir)
		if not plane_hit.is_empty():
			plane_distance = origin.distance_to(table.table_copy.global_transform * (plane_hit["point"] as Vector3))
	_hover_plane = ""
	_hover_face = {}
	if face_distance <= plane_distance and not face_hit.is_empty():
		_hover_face = TopologyPick.face_entity(table.table_copy, int(face_hit.get("face_index", -1)))
	elif not plane_hit.is_empty():
		_hover_plane = str(plane_hit["plane"])
	var nearest := minf(face_distance, plane_distance)
	hovering = nearest < INF and _claim(nearest)
	if not hovering:
		_hover_face = {}
		_hover_plane = ""
	if markers != null:
		markers.set_hover(_hover_plane)
	highlight.set_hover_entity(table._right, table.table_copy, _hover_face)


func _hover_sketch(origin: Vector3, dir: Vector3) -> void:
	_hover_uv = null
	_hover_entity = {}
	if session == null or view == null:
		return
	var uv: Variant = _sheet_hit(origin, dir)
	if uv == null:
		view.set_cursor(null)
		view.set_preview("", [], null)
		view.set_reference_hover({})
		return
	var copy_xf: Transform3D = table.table_copy.global_transform
	var plane: Dictionary = session.plane
	var hit_world: Vector3 = copy_xf * SketchMath.from_sheet(uv, plane)
	hovering = _claim(origin.distance_to(hit_world))
	if not hovering:
		view.set_cursor(null)
		return
	_hover_uv = uv
	var radius_mm: float = SNAP_RADIUS / view.canvas_scale # the snap and pick reaches are a size in the world: they shrink in sketch mm as you zoom in
	var tool: String = table.active_tool
	if SKETCH_TOOLS.has(tool):
		var line_start: Variant = null
		if tool == "line" and session.pending.size() == 1:
			var first: Dictionary = session.pending[0]
			line_start = session.points.get(str(first.get("id", "")), first.get("uv"))
		_snap = SnapResolver.resolve(uv, session, radius_mm, table.snap_enabled, _sheet_vertices, line_start, part_refs)
		view.set_cursor(_snap["uv"], str(_snap["kind"]))
		view.set_reference_hover(_snap.get("ref", {}))
		var taps: Array = session.pending.map(func(p): return session.points.get(str(p.get("id", "")), p["uv"]))
		view.set_preview(tool, taps, _snap["uv"], session.polygon_sides)
	elif CONSTRAIN_TOOLS.has(tool) or tool == "dimension" or tool == SELECT_TOOL or tool == "revolve" or EDIT_TOOLS.has(tool):
		var pick_mm: float = PICK_RADIUS / view.canvas_scale
		var kinds: Array = ["point", "line", "circle", "arc"]
		if tool in ["horizontal", "vertical", "parallel", "perpendicular", "revolve"]:
			kinds = ["line"]
		if EDIT_TOOLS.has(tool):
			kinds = ["line", "circle", "arc"] if tool == "trim" else ["line", "arc"]
		_hover_entity = session.nearest_entity(uv, pick_mm, kinds) if repick_point == "" else {}
		if repick_point == "" and "point" in kinds and str(_hover_entity.get("kind", "")) != "point" and part_refs != null and session.references_ok and tool != "revolve":
			var corner: Dictionary = part_refs.pick(uv, pick_mm, ["point"]) # a point beats a line it is on, and the part's own corner or hole centre is a point (the sketch's helper for it is hidden)
			if not corner.is_empty():
				_hover_entity = corner
		if repick_point != "" and part_refs != null:
			_hover_entity = part_refs.pick(uv, pick_mm, ["point"]) # re-picking: only the part's own corners and hole centres, whatever the sketch has there
		if _hover_entity.is_empty() and repick_point == "" and part_refs != null and session.references_ok and tool != "revolve":
			_hover_entity = part_refs.pick(uv, pick_mm, kinds) # nothing of the sketch there: the part's own corner or edge, to dimension to
		view.set_cursor(uv, "hover" if not _hover_entity.is_empty() else "free")
		view.set_preview("", [], null)
		var key := "%s:%s:%s" % [_hover_entity.get("kind", ""), _hover_entity.get("id", ""), str(_hover_entity.get("ref", {}))]
		if key != _last_view_key:
			_last_view_key = key
			view.set_reference_hover(_hover_entity.get("ref", {}))
			_refresh_view() # the drawing is rebuilt only when what's under the laser changes
	else:
		view.set_cursor(uv, "free")
		view.set_preview("", [], null)


func _sheet_hit(origin: Vector3, dir: Vector3) -> Variant:
	## Where the laser meets the sketch window, as the sketch's (u, v) in mm, or null if it misses or is outside the window.
	var copy_xf: Transform3D = table.table_copy.global_transform
	var plane: Dictionary = session.plane
	var normal_w: Vector3 = (copy_xf.basis * (plane["n"] as Vector3)).normalized()
	var point_w: Vector3 = copy_xf * (plane["origin"] as Vector3)
	var hit: Variant = SketchMath.ray_plane(origin, dir, point_w, normal_w)
	if hit == null or origin.distance_to(hit) > PICK_RANGE:
		return null
	var uv := SketchMath.to_sheet(copy_xf.affine_inverse() * (hit as Vector3), plane)
	if not view.contains(uv):
		return null
	return uv


func _hover_faces(origin: Vector3, dir: Vector3) -> void:
	var hit := _copy_ray(origin, dir)
	_hover_face = {}
	if hit.is_empty():
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	hovering = _claim(float(hit["distance"]))
	if not hovering:
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	_hover_face = TopologyPick.face_entity(table.table_copy, int(hit.get("face_index", -1)))
	highlight.set_hover_entity(table._right, table.table_copy, _hover_face)


func _hover_bodies(origin: Vector3, dir: Vector3) -> void:
	var hit := _copy_ray(origin, dir)
	_hover_face = {}
	if hit.is_empty():
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	hovering = _claim(float(hit["distance"]))
	if not hovering:
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	_hover_face = TopologyPick.body_entity(table.table_copy, int(hit.get("face_index", -1)))
	highlight.set_hover_entity(table._right, table.table_copy, _hover_face)


func _hover_curves(origin: Vector3, dir: Vector3) -> void:
	_hover_face = {}
	if sketch_picks == null or not is_instance_valid(sketch_picks):
		return
	var hit: Dictionary = sketch_picks.nearest(origin, dir, CURVE_REACH)
	if hit.is_empty():
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	hovering = _claim(float(hit["distance"]))
	if not hovering:
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	_hover_face = hit
	highlight.set_hover_entity(table._right, table.table_copy, _hover_face)


func _hover_edges(origin: Vector3, dir: Vector3) -> void:
	var hit := _copy_ray(origin, dir)
	_hover_face = {}
	if hit.is_empty():
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	hovering = _claim(float(hit["distance"]))
	if not hovering:
		highlight.set_hover_entity(table._right, table.table_copy, {})
		return
	var entity := LaserPick.entity_for(table.table_copy, hit, origin)
	_hover_face = entity if str(entity.get("kind", "")) == "edge" else {}
	highlight.set_hover_entity(table._right, table.table_copy, _hover_face)


# --- The trigger ----------------------------------------------------------------------------

func _on_right_pressed(action: String) -> void:
	if action != table.click_action or not hovering or not table.is_open():
		return
	UiFeedback.haptic(table._right, "press")
	match state:
		"pick_plane":
			await _pick_plane()
		"sketch":
			await _sketch_trigger()
		"pick_edges":
			_toggle_edge()
		"pick_faces":
			_toggle_face()
		"pick_bodies":
			_toggle_body()
		"pick_curves":
			_toggle_curve()


func _pick_plane() -> void:
	var spec := {}
	if _hover_plane.begins_with("plane:"):
		var made: Dictionary = table.build.row(_hover_plane.substr(6))
		spec = {"plane_feature_id": _hover_plane.substr(6), "plane": SketchMath.basis_from_plane_response(made)}
	elif _hover_plane != "":
		spec = {"fixed": _hover_plane}
	elif not _hover_face.is_empty():
		var body := str(_hover_face["body_id"])
		var index := int(_hover_face["index"])
		if not TopologyPick.is_planar_face(table.table_copy, body, index):
			table.set_status("That face isn't flat. Pick a flat face or one of the reference planes.")
			UiFeedback.haptic(table._right, "error")
			return
		spec = {"face": {"body_id": body, "index": index}}
	else:
		return
	var feature_tool = tools.get(table.active_tool)
	if feature_tool != null and feature_tool.wants_plane_pick():
		await feature_tool.on_plane_picked(self, spec)
		return
	await begin_sketch(spec)


func sync_plane_markers() -> void:
	## The planes the user made (Create Plane, or any plane not just sitting on a face a sketch was started on) are drawn with the three reference planes.
	if markers == null or not is_instance_valid(markers) or table == null or table.build == null:
		return
	var wanted := {}
	for row in table.build.features:
		if str(row.get("type", "")) != "create_plane":
			continue
		if str(row.get("plane_type", "")) == "offset_face" and is_zero_approx(float(row.get("offset", 0.0))):
			continue # the plane a sketch on a face made, lying on the face itself
		var basis: Dictionary = SketchMath.basis_from_plane_response(row)
		if not basis.is_empty():
			wanted["plane:%s" % str(row["id"])] = [basis, BuildTree.name_of(table.build.features, str(row["id"]))]
	var stale := false
	for key in markers._custom.keys():
		if not wanted.has(key):
			stale = true
	if stale:
		markers.clear_custom()
	for key in wanted:
		markers.add_plane(key, wanted[key][0], str(wanted[key][1]))


func mirror_across(spec: Dictionary) -> bool:
	## The Mirror tool's pull: reflects every body of the part across the picked reference plane ({"fixed": "XY"}) or flat face
	## ({"face": {body_id, index}}). One feature, taken back by Undo like the others.
	if api == null or table.table_copy == null:
		return false
	if table.build.is_rolled_back_any():
		table.set_status("The part is rolled back. Roll forward in the Build tree before adding to it.")
		UiFeedback.haptic(table._right, "error")
		return false
	table.set_status("Mirroring...")
	var mirror_request: Dictionary = tools["mirror"].request(self, {"spec": spec})
	var result: Dictionary = await features.post(part_id, mirror_request)
	if not result["ok"]:
		table.set_status("Couldn't mirror it: %s" % str(result["error"]))
		UiFeedback.haptic(table._right, "error")
		return false
	feature_stack.append(str(result["id"]))
	created_requests[str(result["id"])] = {"type": "mirror", "route": mirror_request["route"], "body": mirror_request["body"]}
	redo_stack.clear()
	var refreshed: bool = await refresh_geometry()
	UiFeedback.haptic(table._right, "confirm")
	table.set_status("Mirrored." if refreshed else "Mirrored, but the new shape couldn't be fetched.")
	table.notify_edited(part_id, _edited_nodes)
	_update_options()
	return true


func begin_sketch(spec: Dictionary) -> bool:
	## Opens a sketch on a reference plane ({"fixed": "XY"}) or a flat face ({"face": {body_id, index}}) of the part on
	## the table: turns the part to lay the plane flat, and shows the sheet. False if the backend refused.
	if state == "opening" or table.table_copy == null:
		return false
	if spec.has("face"):
		chosen_face = {"body_id": str(spec["face"]["body_id"]), "index": int(spec["face"]["index"])}
		chosen_plane = ""
	elif spec.has("fixed"):
		chosen_plane = str(spec["fixed"])
		chosen_face = {}
	elif spec.has("plane_feature_id"):
		chosen_plane = "plane:%s" % str(spec["plane_feature_id"])
		chosen_face = {}
	set_state("opening")
	table.set_status("Opening a sketch...")
	var new_session := SketchSession.new(Callable(self, "_call"))
	new_session.owner_part_id = part_id
	new_session.status.connect(func(text: String) -> void: table.set_status(text))
	var ok: bool = await new_session.open_sketch(spec)
	if not ok or table.table_copy == null:
		chosen_face = {}
		chosen_plane = ""
		if state == "opening":
			set_state("pick_plane")
		return false
	session = new_session
	_opened_revision = session.revision
	session.changed.connect(_on_session_changed)
	_light_chosen_plane()
	_build_view()
	table.orient_to_plane(session.plane)
	set_state("sketch")
	_sync_deck()
	if SKETCH_TOOLS.has(table.active_tool) or CONSTRAIN_TOOLS.has(table.active_tool) or table.active_tool in ["dimension", SELECT_TOOL, "revolve"] or EDIT_TOOLS.has(table.active_tool):
		session.set_tool(table.active_tool)
	elif table.active_tool == "":
		table.manager.activate(SELECT_TOOL) # a sketch opens ready to pick things; choose a drawing tool to draw
	table.set_status(_sketch_hint())
	return true


func reopen_sketch(feature_id: String) -> bool:
	## Opens a sketch the part already has, from its row in the Build tree: reads its entities, turns the part to stand its plane up like a
	## new sketch, and carries on in Select. Editing it changes the part as soon as Done is pressed (anything built on the sketch follows).
	if state == "opening" or table.table_copy == null or part_id == "" or session != null:
		if session != null:
			table.set_status("Finish the open sketch first (Done), then open another.")
		return false
	var row: Dictionary = table.build.row(feature_id)
	if row.is_empty() or str(row.get("type", "")) != "sketch" or str(row.get("sketch_id", "")) == "":
		return false
	set_state("opening")
	table.set_status("Opening the sketch...")
	var described: Dictionary = await _call(HTTPClient.METHOD_GET, "/sketch/sketches/%s" % str(row["sketch_id"]), null)
	if not described["ok"] or not (described["json"] is Dictionary):
		set_state("pick_plane")
		table.set_status("Couldn't read that sketch: %s" % str(described["error"]))
		return false
	var info: Dictionary = described["json"]
	var plane: Dictionary = {}
	chosen_plane = ""
	chosen_face = {}
	if info.get("plane") is String:
		plane = SketchMath.fixed_basis(str(info["plane"]))
		chosen_plane = str(info["plane"])
	elif row.get("plane_feature_id") != null:
		var plane_row: Dictionary = table.build.row(str(row["plane_feature_id"]))
		plane = SketchMath.basis_from_plane_response(plane_row)
		var refs: Array = plane_row.get("face_refs", [])
		if not refs.is_empty() and refs[0] is Dictionary:
			var ref: Dictionary = (refs[0] as Dictionary).get("face_ref", refs[0])
			chosen_face = {"body_id": str(ref.get("body_id", "")), "index": int(ref.get("index", 0))}
	if plane.is_empty() or bool(info.get("flip", false)) or int(info.get("rotation_quarter_turns", 0)) != 0:
		chosen_plane = ""
		chosen_face = {}
		set_state("pick_plane")
		table.set_status("That sketch is flipped or turned in the flat app, or its plane can't be found, so it can't be opened here yet.")
		return false
	var new_session := SketchSession.new(Callable(self, "_call"))
	new_session.owner_part_id = part_id
	new_session.status.connect(func(text: String) -> void: table.set_status(text))
	var ok: bool = await new_session.reopen(row, plane)
	if not ok or table.table_copy == null:
		chosen_plane = ""
		chosen_face = {}
		if state == "opening":
			set_state("pick_plane")
		return false
	session = new_session
	_opened_revision = session.revision
	session.changed.connect(_on_session_changed)
	_light_chosen_plane()
	_build_view()
	table.orient_to_plane(session.plane)
	set_state("sketch")
	_sync_deck()
	table.manager.activate(SELECT_TOOL)
	table.set_status("Sketch open. Select things to change them, draw more, then press Done.")
	return true


func finish_sketch() -> void:
	## The deck's Done: leaves the open sketch. If it was changed the part is rebuilt (everything built on the sketch follows) and its
	## mates are flagged like any edit; an untouched sketch just closes.
	if session == null:
		return
	var changed_it: bool = session.revision > _opened_revision
	if table.active_tool != "":
		table.manager.deactivate()
	end_sketch()
	if not changed_it or api == null:
		return
	table.set_status("Rebuilding the part...")
	var refreshed: bool = await refresh_geometry()
	if refreshed:
		table.notify_edited(part_id, _edited_nodes)
		table.set_status("Sketch updated; the part is rebuilt.")
	else:
		table.set_status("The sketch changed, but the part couldn't be rebuilt from it. Undo or fix the sketch, then press Done again.")


func _light_chosen_plane() -> void:
	## "The chosen plane is highlighted on the part in the table space."
	highlight.set_hover_entity(table._right, table.table_copy, {})
	if not chosen_face.is_empty():
		highlight.set_picks([{"part": table.table_copy, "kind": "face", "body_id": chosen_face["body_id"], "index": chosen_face["index"],
			"face_index": -1, "key": TopologyPick.entity_key("face", str(chosen_face["body_id"]), int(chosen_face["index"]))}])
	else:
		highlight.set_picks([])
	if markers != null:
		markers.set_chosen(chosen_plane)
		markers.set_hover("")


func _build_view() -> void:
	if view != null and is_instance_valid(view):
		view.queue_free()
	var copy: MeshInstance3D = table.table_copy
	var aabb := copy.get_aabb()
	var plane: Dictionary = session.plane
	var centre := SketchMath.to_sheet(aabb.get_center(), plane)
	view = SketchView.new()
	view.name = "SketchView"
	copy.add_child(view)
	view.setup(plane, table.sheet_window_m, centre, table.effective_scale(), table.tokens)
	clip.begin(copy, table._main.view_modes)
	_follow_window()
	_canvas_stale = false
	_sheet_vertices.clear()
	part_refs = null
	session.references_ok = false
	view.set_references(null)
	if markers != null:
		markers.set_markers_visible(false)
	_refresh_view()
	_load_references() # a coroutine, not waited for: with nothing hidden or rolled back it finishes right here


func _load_references() -> void:
	## The part's own corners, edges and holes as references for the sketch that is open. They have to be the geometry the BACKEND resolves this sketch's
	## references against: the part as it stood at the sketch's place in the history (every feature built after it left out). That is the part the table
	## shows when nothing is hidden or rolled back and the sketch is the last thing built, and then the copy's own topology is used at once. Otherwise
	## (something hidden or rolled back, or a reopened sketch with features after it) the part is fetched again the way the Build tree does it, with
	## `rollback_excluded_feature_ids` for what came after the sketch, and only its topology is used; the picture on the table is not changed.
	var my_session = session
	var copy: MeshInstance3D = table.table_copy
	var plane: Dictionary = session.plane
	var excluded := _reference_excluded_ids()
	var topology: Dictionary = {}
	if excluded.is_empty() and not view_is_filtered():
		if copy.has_meta("topology"):
			topology = copy.get_meta("topology")
	else:
		topology = await _fetch_reference_topology(excluded)
		if session != my_session or table.table_copy != copy:
			return # the sketch was left, or the part changed, while the answer was on its way
	if topology.is_empty():
		return
	var refs := PartReferences.build(topology, plane)
	if refs.is_empty():
		return
	part_refs = refs
	session.references_ok = true
	view.set_references(part_refs)
	if view_is_filtered() or not excluded.is_empty():
		table.set_status("%s The part's corners and edges are the ones this sketch sees: features built after it do not count, hidden ones do." % _sketch_hint())


func _reference_excluded_ids() -> Array:
	## The features the backend leaves out when it resolves this sketch's references: every one after the sketch in the history (the sketch's causal snapshot).
	## None for a sketch that is not in the list yet (a new one: it is the last thing built).
	if session == null or session.feature_id == "":
		return []
	var at: int = table.build.index_of(session.feature_id)
	return [] if at < 0 else BuildTree.rolled_back_ids(table.build.features, at)


func _fetch_reference_topology(excluded: Array) -> Dictionary:
	## The part's topology (body id -> edges / vertices ...) with the features after the sketch left out, from the backend; {} if it cannot be had.
	if api == null or part_id == "":
		return {}
	if api.has_method("supports_view_filters") and not await api.supports_view_filters():
		table.set_status("This backend can't give the part as it was at this sketch, so the part's own corners and edges aren't offered here.")
		return {}
	var path := "/document/parts/%s/assembly-mesh.glb?quality=0.5" % part_id
	for id in excluded:
		path += "&rollback_excluded_feature_ids=%s" % str(id).uri_encode()
	var fetched: Dictionary = await api.fetch_bytes(path)
	if not fetched["ok"]:
		table.set_status("Couldn't read the part as this sketch sees it: %s" % str(fetched["error"]))
		return {}
	var parsed: Dictionary = table._main.mesh_from_glb(fetched["bytes"])
	if not parsed["ok"]:
		return {}
	return (parsed["metas"] as Dictionary).get("topology", {})


func sheet_reaches(world_point: Vector3) -> bool:
	## True if a world point is over the canvas window (inside its rectangle, within about 12 cm of its plane): a grip there takes the canvas.
	if session == null or view == null or table.table_copy == null:
		return false
	var local: Vector3 = table.table_copy.global_transform.affine_inverse() * world_point
	var plane: Dictionary = session.plane
	var off_plane: float = absf((local - (plane["origin"] as Vector3)).dot(plane["n"] as Vector3)) * table.effective_scale()
	return off_plane <= 0.12 and view.contains(SketchMath.to_sheet(local, plane))


func sketch_bounds() -> Rect2:
	## The sketch's extent in sheet mm: its points and the origin, with a margin; before anything is drawn, the part's own extent on the plane.
	var plane: Dictionary = session.plane
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for id in session.points:
		var p: Vector2 = session.points[id]
		lo = lo.min(p)
		hi = hi.max(p)
	if lo.x == INF or session.entity_count() == 0:
		var aabb: AABB = table.table_copy.get_aabb()
		var c := SketchMath.to_sheet(aabb.get_center(), plane)
		var half := aabb.size.length() * 0.5
		return Rect2(c - Vector2(half, half), Vector2(half, half) * 2.0)
	var size := hi - lo
	var pad := maxf(size.x, size.y) * 0.1 + 1.0
	return Rect2(lo - Vector2(pad, pad), size + Vector2(pad, pad) * 2.0)


func _sync_deck() -> void:
	table.ui.set_sketching(session != null)


func _follow_window() -> void:
	## The sketch window is fixed in the world while the part pans and zooms under it: every frame, tell the view which sketch spot is now
	## at the window's middle and how big the part is. A zoom also rebuilds the drawing (a few times a second at most, see _settle_canvas).
	if view == null or not is_instance_valid(view) or table.effective_scale() <= 0.0:
		return
	var local: Vector3 = table.table_copy.global_transform.affine_inverse() * table.to_global(table.window_anchor)
	if view.set_frame(table.effective_scale(), SketchMath.to_sheet(local, session.plane)):
		_canvas_stale = true
	var plane: Dictionary = session.plane
	var turn: Basis = table.table_copy.global_transform.basis
	clip.update(table.to_global(table.window_anchor), turn * (plane["x"] as Vector3), turn * (plane["y"] as Vector3), turn * (plane["n"] as Vector3), table.sheet_window_m)


func plane_uv_at(world_point: Vector3) -> Vector2:
	## Where a world point is over the sketch plane, in sketch uv: its height off the plane is dropped.
	return SketchMath.to_sheet(table.table_copy.global_transform.affine_inverse() * world_point, session.plane)


func _settle_canvas() -> void:
	if not _canvas_stale or view == null or not is_instance_valid(view):
		return
	var now := Time.get_ticks_msec()
	if now - _canvas_msec < 70:
		return
	_canvas_msec = now
	_canvas_stale = false
	_refresh_view()


static func _vertices_on_plane(part: Node3D, plane: Dictionary) -> Array:
	## The part's vertices lying in the sketch plane, as sheet positions: snap targets (the corners of the face you're on).
	var out: Array = []
	if not part.has_meta("topology"):
		return out
	for body_id in (part.get_meta("topology") as Dictionary):
		for index in (part.get_meta("topology")[body_id]["vertices"] as Dictionary):
			var v: Vector3 = part.get_meta("topology")[body_id]["vertices"][index]
			if absf((v - (plane["origin"] as Vector3)).dot(plane["n"])) < 0.05:
				out.append(SketchMath.to_sheet(v, plane))
	return out


func _on_session_changed() -> void:
	var selection_key := str(session.selection.map(func(e): return "%s:%s" % [e["kind"], e["id"]])) if session != null else ""
	if selection_key != _menu_key:
		_menu_key = selection_key
		_menu_page = 0 # a different selection starts its menu on the first page
	_refresh_view()
	_update_options()
	sync_undo_redo()


func _refresh_view() -> void:
	if view == null or session == null:
		return
	view.rebuild(session, session.selection, _hover_entity)
	view.show_ghosts(session.ghosts)


func _sketch_hint() -> String:
	var def = table.registry.tool_def(table.active_tool) if table.active_tool != "" else null
	var hint := "Sketch open. Pick a tool to draw or constrain."
	if def != null and def.hint != "":
		hint = def.hint
	var warning: String = session.reference_warning() if session != null else ""
	return hint if warning == "" else "%s  %s" % [warning, hint]


func _sketch_trigger() -> void:
	if session == null or session.busy or _hover_uv == null:
		return
	var tool: String = table.active_tool
	if SKETCH_TOOLS.has(tool):
		if _snap.is_empty():
			return
		var pick := {"uv": _snap["uv"], "id": _snap["id"]}
		if _snap.has("ref"):
			pick["ref"] = _snap["ref"] # a corner of the part: made a pinned point that follows the part when the shape is made
		if tool == "line" and session.pending.size() == 1:
			pick["infer"] = _snap.get("infer", "")
		await session.tap(pick)
	elif tool == SELECT_TOOL and repick_point != "":
		await _do_repick()
	elif tool == "dimension" or tool == SELECT_TOOL:
		var ghost: String = view.ghost_near(session.ghosts, _hover_uv, GHOST_RADIUS / view.canvas_scale)
		if ghost != "":
			if bool(session.ghost(ghost).get("driven", false)):
				await _keep_driven(ghost)
			else:
				_type_dimension(ghost)
		elif not _hover_entity.is_empty():
			await session.select(_hover_entity)
		else:
			session.clear_selection()
	elif tool == "trim":
		if not _hover_entity.is_empty() and str(_hover_entity.get("kind", "")) in ["line", "circle", "arc"]:
			await session.trim_at(_hover_entity, _hover_uv)
	elif tool == "offset":
		if not _hover_entity.is_empty():
			var signed := float(options["offset_dist"]) * (-1.0 if bool(options["offset_flip"]) else 1.0)
			await session.offset_entity(_hover_entity, signed)
			sync_undo_redo()
	elif tool == "revolve":
		if not _hover_entity.is_empty() and str(_hover_entity.get("kind", "")) == "line":
			revolve_axis = str(_hover_entity["id"])
			session.selection = [{"kind": "line", "id": revolve_axis}] # lit as the axis
			session.changed.emit()
			table.set_status("That line is the axis. Set Boss or Cut and the angle, then Apply.")
			_update_options()
			schedule_preview()
	elif CONSTRAIN_TOOLS.has(tool):
		if not _hover_entity.is_empty():
			await session.select(_hover_entity)


# --- Flagged references: lost, or may have moved (the backend's answer, after an upstream edit) ---------------------

func _start_repick() -> void:
	## "Fix": walks the flagged reference points (lost first) one by one. For each, point at the corner of the part (or the centre of the hole) it
	## should follow and pull the trigger; everything built on the point stays on it.
	if session == null:
		return
	_repick_queue = session.flagged_references()
	if _repick_queue.is_empty():
		return
	_set_repick(str(_repick_queue[0]["point_id"]))


func _set_repick(point_id: String) -> void:
	repick_point = point_id
	if view != null:
		view.repick_point = point_id
	_refresh_view()
	_update_options()
	var row := _repick_row()
	var wants_hole: bool = str(row.get("kind", "vertex")) == "circle_centre"
	var why := str(row.get("reason", ""))
	table.set_status("%s (%d to do). Point at %s of the part that this point should follow, then pull the trigger.%s" % [
		"Lost" if str(row.get("status", "")) == "lost" else "May have moved", _repick_queue.size(),
		"the centre of the hole" if wants_hole else "the corner", (" Why: %s." % why.replace("_", " ")) if why != "" else ""])


func _repick_row() -> Dictionary:
	for row in _repick_queue:
		if str(row["point_id"]) == repick_point:
			return row
	return {}


func _stop_repick(message: String = "") -> void:
	repick_point = ""
	_repick_queue.clear()
	if view != null:
		view.repick_point = ""
	_refresh_view()
	_update_options()
	if message != "":
		table.set_status(message)


func _do_repick() -> void:
	## The trigger while re-picking: the part's corner or hole under the laser becomes what the flagged point follows.
	var ref: Dictionary = _hover_entity.get("ref", {}) if _hover_entity.get("ref") is Dictionary else {}
	if ref.is_empty():
		table.set_status("Point at a corner of the part (or the centre of a hole), then pull the trigger.")
		UiFeedback.haptic(table._right, "error")
		return
	var done_point := repick_point
	var result: Dictionary = await session.reattach(done_point, ref)
	if not bool(result["ok"]):
		table.set_status(str(result["message"]))
		UiFeedback.haptic(table._right, "error")
		return
	UiFeedback.haptic(table._right, "confirm")
	_repick_queue = _repick_queue.filter(func(row) -> bool: return str(row["point_id"]) != done_point)
	var still: Array = session.flagged_references().filter(func(row) -> bool: return _repick_queue.any(func(q) -> bool: return str(q["point_id"]) == str(row["point_id"])))
	if still.is_empty():
		_stop_repick("References fixed. Press Done to rebuild the part from the sketch.")
		return
	_repick_queue = still
	_set_repick(str(_repick_queue[0]["point_id"]))


func _keep_moved() -> void:
	## "Keep moved ones": the user looked and the corners the backend found again are the right ones.
	var kept := 0
	for row in session.flagged_references():
		if str(row["status"]) == "potentially_moved":
			var result: Dictionary = await session.confirm_reference(str(row["point_id"]))
			kept += 1 if bool(result["ok"]) else 0
	table.set_status("Kept %d reference(s)." % kept if kept > 0 else "Nothing to keep.")
	_refresh_view()
	_update_options()


func _keep_driven(ghost_key: String) -> void:
	## A candidate between two pinned things has no value to type (nothing could move): pointing at it keeps it as a reference dimension.
	var result: Dictionary = await session.confirm_ghost(ghost_key, 0.0)
	if bool(result["ok"]):
		UiFeedback.haptic(table._right, "confirm")
		table.set_status("Reference dimension kept (in brackets: it measures, it does not drive). Undo takes it back.")


func _type_dimension(ghost_key: String) -> void:
	var g: Dictionary = session.ghost(ghost_key)
	if g.is_empty():
		return
	table._main.open_keyboard_for("%.2f" % float(g["value"]), func(text: String) -> void: await dimension_typed(ghost_key, text),
		{"title": "%s (%s)" % [g["label"], g["unit"]]})


func dimension_typed(ghost_key: String, text: String) -> void:
	## The numeric pad came back with `text`. Rejects anything that isn't a plain number; the session rejects zero and below.
	var cleaned := text.strip_edges()
	if not cleaned.is_valid_float():
		table.set_status("That isn't a number.")
		UiFeedback.haptic(table._right, "error")
		return
	var result: Dictionary = await session.confirm_ghost(ghost_key, cleaned.to_float())
	if bool(result["ok"]):
		UiFeedback.haptic(table._right, "confirm")
		table.set_status("Dimension set.")


# --- Tools and the options row -------------------------------------------------------------

func on_tool_changed(tool_id: String) -> void:
	if state == "idle" and table.table_copy == null:
		return
	if session != null:
		session.set_tool(tool_id if (SKETCH_TOOLS.has(tool_id) or CONSTRAIN_TOOLS.has(tool_id) or tool_id == "dimension" or tool_id == SELECT_TOOL or tool_id == "revolve" or EDIT_TOOLS.has(tool_id)) else "")
		if tool_id == "revolve" and revolve_axis != "":
			session.selection = [{"kind": "line", "id": revolve_axis}]
		_refresh_view()
	if not editing.is_empty() and tool_id != str(editing["type"]):
		editing = {}
	if preview_feature_id != "" or preview.is_showing():
		cancel_preview() # another tool: what the last one was showing goes (a feature it made for the preview is deleted first, in order)
	if tools.has(tool_id):
		tools[tool_id].on_activated(self)
		_update_options()
		schedule_preview()
		return
	match tool_id:
		"":
			if state in PICK_STATES or state == "extrude":
				set_state("sketch" if session != null else "pick_plane")
		_:
			if state in PICK_STATES or state == "extrude":
				set_state("sketch" if session != null else "pick_plane")
			if session == null and (SKETCH_TOOLS.has(tool_id) or CONSTRAIN_TOOLS.has(tool_id) or EDIT_TOOLS.has(tool_id) or tool_id in ["dimension", SELECT_TOOL]):
				table.set_status("Pick a flat face or a reference plane to sketch on first.")
	_update_options()


func _update_options() -> void:
	if table == null or table.ui == null:
		return
	var tool: String = table.active_tool
	var list: Array = []
	if not fixing.is_empty():
		var wanted: int = (fixing["paths"] as Array).size()
		var picked: int = edges.size() if str(fixing["kind"]) == "edge" else faces.size()
		table.ui.set_options([
			{"id": "fix_apply", "text": "Apply fix (%d of %d)" % [picked, wanted], "disabled": picked != wanted},
			{"id": "fix_clear", "text": "Clear"},
			{"id": "fix_cancel", "text": "Cancel"}])
		return
	if tools.has(tool):
		table.ui.set_options(tools[tool].options(self))
		return
	match tool:
		SELECT_TOOL:
			if session != null:
				list = _menu_options()
				if repick_point != "":
					list = [{"id": "refs_next", "text": "Skip", "disabled": _repick_queue.size() < 2}, {"id": "refs_cancel", "text": "Stop fixing"}]
				elif list.is_empty() and not session.flagged_references().is_empty():
					list = [{"id": "refs_fix", "text": "Fix %d reference(s)" % session.flagged_references().size()}]
					if session.flagged_references().any(func(row): return str(row["status"]) == "potentially_moved"):
						list.append({"id": "refs_keep", "text": "Keep moved ones"})
		"polygon":
			if session != null:
				list = [{"id": "sides_down", "text": "Fewer"}, {"id": "sides_label", "text": "%d sides" % session.polygon_sides, "disabled": true}, {"id": "sides_up", "text": "More"}]
		"line":
			list = [{"id": "finish_line", "text": "Finish line"}]
		"offset":
			list = [{"id": "offset_dist", "text": "Distance %.2f mm" % float(options["offset_dist"])}, {"id": "offset_flip", "text": "Reverse", "toggle": true, "pressed": bool(options["offset_flip"])}]
	table.ui.set_options(list)


func _menu_options() -> Array:
	## The Select tool's contextual menu for what is selected, one page of the options row (More turns the page).
	var page := SketchSelection.page(session.menu(), _menu_page, MENU_SLOTS)
	_menu_page = int(page["page"])
	var list: Array = (page["items"] as Array).duplicate(true)
	if bool(page["has_more"]):
		list.append({"id": "menu_more", "text": "More %d/%d" % [_menu_page + 1, int(page["pages"])]})
	return list


func on_option(option_id: String) -> void:
	if option_id == "fix_apply":
		await _finish_fix()
		return
	if option_id == "fix_clear":
		edges.clear()
		faces.clear()
		highlight.set_set(table.table_copy, [])
		_update_options()
		return
	if option_id == "fix_cancel":
		await _end_fix("Fix cancelled. The reference stays flagged.")
		return
	if option_id == "refs_fix":
		_start_repick()
		return
	if option_id == "refs_cancel":
		_stop_repick("Stopped. The flagged points stay as they are.")
		return
	if option_id == "refs_next":
		if _repick_queue.size() > 1:
			_repick_queue.push_back(_repick_queue.pop_front())
			_set_repick(str(_repick_queue[0]["point_id"]))
		return
	if option_id == "refs_keep":
		await _keep_moved()
		return
	if option_id == "menu_more":
		_menu_page += 1
		_update_options()
		return
	if option_id.begins_with("dim:"):
		_type_dimension(option_id.substr(4))
		return
	if session != null and session.tool == SELECT_TOOL and option_id in SelectMenuIds:
		_menu_page = 0
		var result: Dictionary = await session.apply_menu(option_id)
		if bool(result["ok"]):
			UiFeedback.haptic(table._right, "confirm")
		elif str(result["message"]) != "":
			table.set_status(str(result["message"]))
			UiFeedback.haptic(table._right, "error")
		_update_options()
		return
	var active_feature = tools.get(table.active_tool)
	if active_feature != null and option_id != "apply" and active_feature.handle_option(self, option_id):
		_update_options()
		schedule_preview()
		return
	match option_id:
		"sides_down":
			if session != null:
				session.polygon_sides = maxi(3, session.polygon_sides - 1)
		"sides_up":
			if session != null:
				session.polygon_sides = mini(24, session.polygon_sides + 1)
		"finish_line":
			if session != null:
				session.finish_chain()
		"offset_dist":
			type_option("offset_dist", "Offset distance (mm)")
		"offset_flip":
			options["offset_flip"] = not bool(options["offset_flip"])
		"apply":
			await apply_feature()
	_update_options()


func type_option(key: String, title: String) -> void:
	table._main.open_keyboard_for("%.2f" % float(options[key]), func(text: String) -> void: option_typed(key, text), {"title": title})


func option_typed(key: String, text: String) -> void:
	var cleaned := text.strip_edges()
	if SIGNED_OPTIONS.has(key):
		if not cleaned.is_valid_float():
			table.set_status("Enter a number (negative goes the other way).")
			UiFeedback.haptic(table._right, "error")
			return
		options[key] = cleaned.to_float()
		_update_options()
		schedule_preview()
		return
	if not cleaned.is_valid_float() or cleaned.to_float() <= 0.0:
		table.set_status("Enter a number bigger than zero.")
		UiFeedback.haptic(table._right, "error")
		return
	if (key == "angle" or key == "pat_angle") and cleaned.to_float() > 360.0:
		table.set_status("An angle can't be more than 360 degrees.")
		UiFeedback.haptic(table._right, "error")
		return
	options[key] = cleaned.to_float()
	_update_options()
	schedule_preview()


# --- Edges (Fillet / Chamfer) -----------------------------------------------------------------

func _toggle_face() -> void:
	if _hover_face.is_empty() or str(_hover_face.get("kind", "")) != "face":
		return
	for i in faces.size():
		if faces[i]["key"] == _hover_face["key"]:
			faces.remove_at(i)
			highlight.set_set(table.table_copy, faces)
			_update_options()
			schedule_preview()
			return
	if not faces.is_empty() and str(faces[0]["body_id"]) != str(_hover_face["body_id"]):
		table.set_status("A shell opens faces of ONE body. Clear to start again on another.")
		UiFeedback.haptic(table._right, "error")
		return
	if not fixing.is_empty():
		var cap: int = (fixing["paths"] as Array).size()
		if faces.size() >= cap:
			faces.clear() # one replacement per flagged reference: a new pick replaces the last one when all are chosen
		faces.append(_hover_face.duplicate())
		highlight.set_set(table.table_copy, faces)
		table.set_status("Picked %d of %d. %s" % [faces.size(), cap, "Apply fix when it is the right one." if faces.size() == cap else "Pick the next."])
		_update_options()
		schedule_preview()
		return
	faces.append(_hover_face.duplicate())
	highlight.set_set(table.table_copy, faces)
	table.set_status("%d face(s) will be opened. Set the wall thickness, then Apply." % faces.size())
	_update_options()
	schedule_preview()


func _refresh_lit() -> void:
	## Lights the picked bodies and curves together (a tool may hold both).
	highlight.set_set(table.table_copy, bodies + curve_picks)


func set_pick_mode(mode: String) -> void:
	## A tool that picks more than one kind of thing (Pattern: a body, then a line) switches what the laser picks without forgetting what was picked.
	## "bodies" | "curves" | "plane" (the reference planes and flat faces, for a tool that wants_plane_pick).
	match mode:
		"bodies":
			if state in PICK_FROM_STATES:
				set_state("pick_bodies")
		"curves":
			if state in PICK_FROM_STATES:
				set_state("pick_curves")
				if sketch_picks == null or not is_instance_valid(sketch_picks) or sketch_picks.curves.is_empty():
					await _load_sketch_picks()
		"plane":
			if state in PICK_FROM_STATES:
				set_state("pick_plane")
	_refresh_lit()


func _load_sketch_picks() -> void:
	if sketch_picks != null and is_instance_valid(sketch_picks):
		sketch_picks.queue_free()
	sketch_picks = SketchPicks.new()
	table.table_copy.add_child(sketch_picks)
	var count: int = await sketch_picks.load_sketches(Callable(self, "_call"), part_id, table.build.features, Callable(self, "_plane_for_row"), session.feature_id if session != null else "")
	if state == "pick_curves":
		table.set_status("Aim at a line or curve of an earlier sketch and pull the trigger (%d to pick from)." % count if count > 0 else "There is no finished sketch with lines to pick from yet.")
	_update_options()


func _toggle_curve() -> void:
	if _hover_face.is_empty() or str(_hover_face.get("kind", "")) != "curve":
		return
	for i in curve_picks.size():
		if curve_picks[i]["key"] == _hover_face["key"]:
			curve_picks.remove_at(i)
			_refresh_lit()
			_update_options()
			schedule_preview()
			return
	curve_picks.append(_hover_face.duplicate())
	if curve_limit > 0 and curve_picks.size() > curve_limit:
		curve_picks.pop_front()
	_refresh_lit()
	table.set_status("%d curve(s) picked." % curve_picks.size())
	_update_options()
	schedule_preview()


func _toggle_body() -> void:
	if _hover_face.is_empty() or str(_hover_face.get("kind", "")) != "body":
		return
	for i in bodies.size():
		if bodies[i]["key"] == _hover_face["key"]:
			bodies.remove_at(i)
			_refresh_lit()
			_update_options()
			schedule_preview()
			return
	bodies.append(_hover_face.duplicate())
	if body_limit > 0 and bodies.size() > body_limit:
		bodies.pop_front()
	_refresh_lit()
	table.set_status("%d bod%s picked." % [bodies.size(), "y" if bodies.size() == 1 else "ies"])
	_update_options()
	schedule_preview()


func _toggle_edge() -> void:
	if _hover_face.is_empty() or str(_hover_face.get("kind", "")) != "edge":
		return
	for i in edges.size():
		if edges[i]["key"] == _hover_face["key"]:
			edges.remove_at(i)
			highlight.set_set(table.table_copy, edges)
			_update_options()
			schedule_preview()
			return
	if not fixing.is_empty():
		var cap: int = (fixing["paths"] as Array).size()
		if edges.size() >= cap:
			edges.clear()
		edges.append(_hover_face.duplicate())
		highlight.set_set(table.table_copy, edges)
		table.set_status("Picked %d of %d. %s" % [edges.size(), cap, "Apply fix when it is the right one." if edges.size() == cap else "Pick the next."])
		_update_options()
		schedule_preview()
		return
	edges.append(_hover_face.duplicate())
	highlight.set_set(table.table_copy, edges)
	table.set_status("%d edge(s) picked. Set the size, then Apply." % edges.size())
	_update_options()
	schedule_preview()


# --- Fixing a flagged feature (Build row > Fix) -------------------------------------------------

func begin_fix(feature_id: String) -> void:
	## A fillet, chamfer, shell, mirror or create-plane whose reference the backend flagged lost / moved is mended by picking its replacement. The edges and
	## faces a feature names are numbered on the part AS IT SAW IT (every feature before it built, itself and everything after left out), so the table's copy is
	## shown that way (the Build tree's roll back, to the row before) and the laser picks on it: edges for a fillet / chamfer, faces for a shell / mirror / plane.
	## Apply fix PATCHes the feature with the new reference (the backend re-measures it and the flag clears) and rolls forward; Cancel changes nothing.
	var build = table.build
	var f: Dictionary = build.row(feature_id)
	var target: Dictionary = BuildTree.fix_target(f)
	if target.is_empty() or api == null or table.table_copy == null:
		return
	var at: int = build.index_of(feature_id)
	if at < 1:
		table.set_status("That feature is the first thing built, so there is nothing before it to pick from.")
		return
	if not build.view_filters_ok:
		table.set_status("This backend can't show the part as it was before that feature, so the replacement can't be picked here.")
		return
	if session != null:
		table.set_status("Finish the sketch first (Done), then fix the reference.")
		return
	var state_before := state
	table.manager.deactivate()
	build.rollback_to = str(build.features[at - 1].get("id", ""))
	await refresh_view()
	fixing = {"feature_id": feature_id, "type": str(target["type"]), "kind": str(target["kind"]), "paths": target["paths"], "state_before": state_before}
	edges.clear()
	faces.clear()
	highlight.set_set(table.table_copy, [])
	set_state("pick_edges" if str(target["kind"]) == "edge" else "pick_faces")
	var noun: String = "edge" if str(target["kind"]) == "edge" else "face"
	table.set_status("%s: the part is shown as it was before %s. Aim at the replacement %s%s and pull the trigger, then Apply fix." % [
		build.names[at], build.names[at], noun, "s, one for each flagged reference" if (target["paths"] as Array).size() > 1 else ""])
	build.changed.emit()
	_update_options()


func _finish_fix() -> void:
	if fixing.is_empty() or api == null:
		return
	var build = table.build
	var f: Dictionary = build.row(str(fixing["feature_id"]))
	var picked: Array = edges if str(fixing["kind"]) == "edge" else faces
	var payload: Dictionary = BuildTree.fix_payload(f, fixing["paths"], picked)
	if payload.is_empty():
		table.set_status("Pick a replacement for each flagged reference first.")
		UiFeedback.haptic(table._right, "error")
		return
	table.set_status("Working...")
	var result: Dictionary = await features.update_feature(part_id, str(fixing["type"]), str(fixing["feature_id"]), payload)
	if not result["ok"]:
		table.set_status("Couldn't use that: %s" % str(result["error"]))
		UiFeedback.haptic(table._right, "error")
		return # still fixing: pick another
	await _end_fix("")
	var refreshed: bool = await refresh_geometry()
	table.notify_edited(part_id, _edited_nodes)
	await build.reload()
	UiFeedback.haptic(table._right, "confirm")
	table.set_status("Reference fixed." if refreshed else "Fixed, but the new shape couldn't be fetched.")


func _end_fix(message: String) -> void:
	## Back from fix mode: the part rolled forward again and the laser as it was. (No undo entry: the old reference was lost, so putting it back would fail.)
	if fixing.is_empty():
		return
	var before: String = str(fixing["state_before"])
	fixing = {}
	edges.clear()
	faces.clear()
	if highlight != null:
		highlight.set_set(table.table_copy, [])
	table.build.rollback_to = ""
	await refresh_view()
	set_state(before if before in ["pick_plane", "idle"] else "pick_plane")
	if message != "":
		table.set_status(message)
	table.build.changed.emit()
	_update_options()


# --- Applying a feature ---------------------------------------------------------------------

func body_ids() -> Array:
	## The part's body ids, one each.
	var seen := {}
	if table.table_copy != null and table.table_copy.has_meta("body_ids"):
		for id in table.table_copy.get_meta("body_ids"):
			seen[str(id)] = true
	return seen.keys()


func extrude_targets() -> Array:
	## Which bodies an extrude combines with. A boss fuses into the body you sketched on (or the part's only body) unless
	## "New body" is on; a cut cuts the body you sketched on, or all of them.
	var all := body_ids()
	var boss := bool(options["boss"])
	if boss and bool(options["new_body"]):
		return []
	if not chosen_face.is_empty():
		return [str(chosen_face["body_id"])]
	if boss:
		return all if all.size() == 1 else []
	return all


func extrude_distances() -> Array:
	## [start, end] along the sketch normal. A boss grows along it (out of a face); a cut goes the other way (into the part).
	var depth := float(options["depth"])
	var sign := 1.0 if bool(options["boss"]) else -1.0
	if bool(options["flip"]):
		sign = -sign
	return [0.0, depth * sign]


# --- Preview before Apply ---------------------------------------------------------------------------

func schedule_preview() -> void:
	## Something the active tool shows changed (a setting, a pick): refresh the translucent result. One request at a time; changes that come
	## while one is running are folded into one more run afterwards.
	if not preview_enabled or api == null or table == null or table.table_copy == null:
		return
	if _preview_running:
		_preview_again = true
		return
	_preview_running = true
	while true:
		_preview_again = false
		await _run_preview()
		if not _preview_again:
			break
	_preview_running = false


func _run_preview() -> void:
	var feature_tool = tools.get(table.active_tool)
	if feature_tool == null or not fixing.is_empty() or feature_tool.preview_mode() == "none" or table.build.is_rolled_back_any() or part_id == "":
		await cancel_preview()
		return
	if not editing.is_empty() and feature_tool.preview_mode() == "eager":
		return # editing a feature that exists: nothing is created for a preview, Apply changes it
	var req: Dictionary = feature_tool.request(self)
	if not bool(req["ok"]):
		await cancel_preview() # nothing valid to show (yet): what an earlier preview made goes
		return
	var tool_id := str(table.active_tool)
	var mesh: Mesh = null
	if feature_tool.preview_mode() == "coarse":
		var coarse: Dictionary = await _call(HTTPClient.METHOD_POST, "/document/parts/%s/%s?quality=%s" % [part_id, feature_tool.preview_route(), str(FeaturePreview.QUALITY)], req["body"])
		if not coarse["ok"] or not (coarse["json"] is Array):
			preview.clear()
			table.set_status("No preview: %s" % PartFeatures._plain(str(coarse["error"])))
			return
		mesh = FeaturePreview.mesh_from_bodies(coarse["json"])
	else:
		if preview_feature_id == "":
			var made: Dictionary = await features.post(part_id, req)
			if not made["ok"]:
				preview.clear()
				table.set_status("No preview: %s" % str(made["error"]))
				return
			preview_feature_id = str(made["id"])
		else:
			var patched: Dictionary = await features.update_feature(part_id, tool_id, preview_feature_id, feature_tool.patch_body(req))
			if not patched["ok"]:
				table.set_status("No preview: %s" % str(patched["error"]))
				return
		var fetched: Dictionary = await api.fetch_bytes(glb_path(view_is_filtered(), FeaturePreview.QUALITY))
		if not fetched["ok"]:
			return
		var parsed: Dictionary = table._main.mesh_from_glb(fetched["bytes"])
		mesh = parsed["mesh"] if parsed["ok"] else null
	if table.active_tool != tool_id or table.table_copy == null:
		await cancel_preview() # the tool changed while it was being fetched
		return
	if not preview.show(table.table_copy, mesh) and preview.skipped_over_budget:
		table.set_status("The preview is too heavy to draw here (%d triangles over the %d limit). Apply to see the result." % [FeaturePreview.triangle_count(mesh) - FeaturePreview.MAX_TRIANGLES, FeaturePreview.MAX_TRIANGLES])


func begin_tool_edit(feature_id: String) -> void:
	## The Build row's Edit for a feature with several settings: its own tool opens with the feature's settings (and picks) loaded, changes are shown
	## as the tool shows them, Apply PATCHes the feature (one step on Undo), changing tool leaves it as it was.
	var row: Dictionary = table.build.row(feature_id)
	var feature_tool = FeatureTools.for_type(str(row.get("type", "")))
	if row.is_empty() or feature_tool == null or not feature_tool.edits_in_tool() or session != null:
		if session != null:
			table.set_status("Finish the open sketch first (Done), then edit a feature.")
		return
	if table.build.is_rolled_back_any():
		table.set_status("The part is rolled back. Roll forward in the Build tree before editing.")
		return
	editing = {}
	if table.active_tool != feature_tool.id:
		table.manager.activate(feature_tool.id)
	else:
		feature_tool.on_activated(self)
	editing = {"id": feature_id, "type": feature_tool.id, "original": row.duplicate(true)}
	feature_tool.load_from_row(self, row)
	_update_options()
	schedule_preview()
	table.set_status("Editing %s. Change what you want, then Apply." % table.build.names[table.build.index_of(feature_id)])


func _apply_edit(feature_tool, req: Dictionary) -> void:
	if not bool(req["ok"]):
		table.set_status("Couldn't do that: %s" % str(req["error"]))
		UiFeedback.haptic(table._right, "error")
		return
	var body: Dictionary = feature_tool.patch_body(req)
	var edit := editing
	var result: Dictionary = await features.update_feature(part_id, str(edit["type"]), str(edit["id"]), body)
	if not result["ok"]:
		table.set_status("Couldn't change it: %s" % str(result["error"]))
		UiFeedback.haptic(table._right, "error")
		return
	feature_stack.append({"kind": "edit", "id": edit["id"], "type": edit["type"], "payload": feature_tool.row_payload(edit["original"]), "redo_payload": body})
	redo_stack.clear()
	editing = {}
	preview.clear()
	var refreshed: bool = await refresh_geometry()
	await table.build.reload()
	table.notify_edited(part_id, _edited_nodes)
	clear_picks()
	table.manager.deactivate()
	UiFeedback.haptic(table._right, "confirm")
	table.set_status("Changed." if refreshed else "Changed, but the new shape couldn't be fetched.")
	sync_undo_redo()


func cancel_preview() -> void:
	## Takes the preview away: the overlay goes, and a feature an eager preview made is deleted (it is the part's last feature).
	preview.clear()
	if preview_feature_id == "":
		return
	var id := preview_feature_id
	preview_feature_id = ""
	if api != null and part_id != "":
		await features.delete_feature(part_id, id)


func apply_feature() -> void:
	if table.table_copy == null or api == null:
		return
	if table.build.is_rolled_back_any():
		table.set_status("The part is rolled back. Roll forward in the Build tree before adding to it.")
		UiFeedback.haptic(table._right, "error")
		return
	var tool: String = table.active_tool
	var result: Dictionary
	table.set_status("Working...")
	var feature_tool = tools.get(tool)
	if feature_tool == null:
		return
	var req: Dictionary = feature_tool.request(self)
	if not editing.is_empty():
		await _apply_edit(feature_tool, req)
		return
	if preview_feature_id != "" and bool(req["ok"]):
		var patched: Dictionary = await features.update_feature(part_id, tool, preview_feature_id, feature_tool.patch_body(req))
		result = {"ok": patched["ok"], "id": preview_feature_id, "error": patched["error"]}
		if patched["ok"]:
			preview_feature_id = "" # the feature the preview made is the real one now
	else:
		if preview_feature_id != "":
			await cancel_preview()
		result = await features.post(part_id, req)
	preview.clear()
	if not result["ok"]:
		table.set_status("Couldn't do that: %s" % str(result["error"]))
		UiFeedback.haptic(table._right, "error")
		return
	feature_stack.append(str(result["id"]))
	created_requests[str(result["id"])] = {"type": tool, "route": req["route"], "body": req["body"]}
	redo_stack.clear() # a new action: what was taken back can't be put back any more
	var refreshed: bool = await refresh_geometry()
	if feature_tool.reload_build_after():
		await table.build.reload()
	if feature_tool.finishes_sketch():
		end_sketch()
	clear_picks()
	UiFeedback.haptic(table._right, "confirm")
	table.set_status(feature_tool.done_text() if refreshed else "Done, but the new shape couldn't be fetched.")
	table.notify_edited(part_id, _edited_nodes)
	_update_options()


func clear_picks() -> void:
	## Forgets the picked edges, faces and bodies (a feature tool's Clear).
	edges.clear()
	faces.clear()
	bodies.clear()
	curve_picks.clear()
	if highlight != null and table.table_copy != null:
		highlight.set_set(table.table_copy, [])


func start_curve_picks(limit := 0) -> void:
	## A tool that works on lines of earlier sketches was chosen (Loft, Sweep, Pattern): the finished sketches' curves are read and drawn on the
	## part, and the laser picks them. `limit` 0 = any number.
	curve_limit = limit
	if not state in PICK_FROM_STATES or table.table_copy == null or api == null:
		return
	clear_picks()
	set_state("pick_curves")
	await _load_sketch_picks()


func _plane_for_row(row: Dictionary) -> Dictionary:
	## The plane of a finished sketch (a Build row) as a basis in the part's frame, or {} when it can't be placed (flipped or turned in the flat app).
	var described: Dictionary = await _call(HTTPClient.METHOD_GET, "/sketch/sketches/%s" % str(row["sketch_id"]), null)
	if not described["ok"] or not (described["json"] is Dictionary):
		return {}
	var info: Dictionary = described["json"]
	if bool(info.get("flip", false)) or int(info.get("rotation_quarter_turns", 0)) != 0:
		return {}
	if info.get("plane") is String:
		return SketchMath.fixed_basis(str(info["plane"]))
	if row.get("plane_feature_id") != null:
		return SketchMath.basis_from_plane_response(table.build.row(str(row["plane_feature_id"])))
	return {}


func curve_refs() -> Array:
	return curve_picks.map(func(c): return sketch_picks.entity_ref(c) if sketch_picks != null and is_instance_valid(sketch_picks) else {"sketch_id": c["sketch_id"], "entity_type": c["entity_type"], "entity_id": c["entity_id"]})


func start_body_picks(limit := 0) -> void:
	## A tool that works on whole bodies was chosen: the laser lights and picks a body.
	body_limit = limit
	if state in PICK_FROM_STATES:
		clear_picks()
		set_state("pick_bodies")


func body_refs() -> Array:
	return bodies.map(func(b): return str(b["body_id"]))


func start_face_picks() -> void:
	## Shell / Move Face / Delete Face were chosen: pick faces of one body.
	if state in PICK_FROM_STATES:
		clear_picks()
		set_state("pick_faces")


func face_refs() -> Array:
	return faces.map(func(f): return PartFeatures.face_ref(str(f["body_id"]), int(f["index"])))


func start_edge_picks() -> void:
	## Fillet / Chamfer were chosen: pick edges on the part.
	if state in PICK_FROM_STATES:
		clear_picks()
		set_state("pick_edges")


func edge_refs() -> Array:
	return edges.map(func(e): return PartFeatures.edge_ref(str(e["body_id"]), int(e["index"])))


func glb_path(filtered: bool, quality := 0.5) -> String:
	## The part's own assembly-mesh.glb; `filtered` adds the Build tree's Hide / Show and rollback sets (DIDSA-CAD, 2026-10-03).
	var path := "/document/parts/%s/assembly-mesh.glb?quality=%s" % [part_id, str(quality)]
	if filtered:
		for id in table.build.hidden_ids():
			path += "&hidden_feature_ids=%s" % str(id).uri_encode()
		for id in table.build.rollback_excluded():
			path += "&rollback_excluded_feature_ids=%s" % str(id).uri_encode()
	return path


func view_is_filtered() -> bool:
	return not table.build.hidden_ids().is_empty() or not table.build.rollback_excluded().is_empty()


func refresh_view() -> void:
	## The Build tree hid, showed, rolled back or rolled forward something: the table's COPY is shown (or no longer) with that
	## applied. The arena's real part is not touched. With nothing hidden or rolled back the copy goes back to the whole part.
	if api == null or table.table_copy == null:
		return
	if not view_is_filtered():
		table.sync_copy_from_seated()
	else:
		var fetched: Dictionary = await api.fetch_bytes(glb_path(true))
		if not fetched["ok"] or table.table_copy == null:
			table.set_status("Couldn't update the picture: %s" % str(fetched["error"]))
			return
		table.show_filtered_view(fetched["bytes"])
	if highlight != null and table.table_copy != null:
		highlight.invalidate(table.table_copy)
	edges.clear()
	faces.clear()
	bodies.clear()
	view_changed.emit()


func forget_features(ids: Array) -> void:
	## Features were deleted behind the editor's back (the Build tree's cascade): Undo must not try to take them back again.
	feature_stack = feature_stack.filter(func(entry) -> bool:
		var entry_id: String = str(entry["id"]) if entry is Dictionary else str(entry)
		return not ids.has(entry_id))
	if session != null and ids.has(session.feature_id):
		end_sketch() # the sketch it was drawing on is gone
	sync_undo_redo()


func refresh_geometry() -> bool:
	## Fetches the part's new mesh and puts it on the table AND on every arena instance of the part.
	if api == null or table.table_copy == null:
		return false
	var fetched: Dictionary = await api.fetch_bytes(glb_path(false))
	if not fetched["ok"] or table.table_copy == null:
		return false
	var nodes := await arena_nodes_of(part_id)
	if table.seated != null and not nodes.has(table.seated):
		nodes.append(table.seated)
	_edited_nodes = nodes
	# Which face does each mate of the assembly name on this part? Recorded BEFORE the new mesh goes in: after an edit the backend's face
	# indices are renumbered, and a mate can end up joining different faces without any error (mate_health.gd).
	var captured: Array = []
	var mates_tool = table._mates_tool
	if mates_tool != null and table._main.current_root_part_id() != "":
		await mates_tool.refresh_mates(table._main.current_root_part_id())
		captured = MateHealth.capture(nodes, mates_tool.mates)
		table.add_mate_baseline(captured)
	var was_blank: bool = table.is_blank()
	if table._main.swap_part_mesh(nodes, fetched["bytes"]) == 0:
		return false
	table.update_mate_drift()
	var size_before: Vector3 = table.table_copy.get_aabb().size
	table.sync_copy_from_seated()
	if was_blank != table.is_blank() or not table.table_copy.get_aabb().size.is_equal_approx(size_before):
		_rebuild_markers() # the part changed size (or a new part got its first feature, or lost it): the plane squares were sized to the old shape
	if view_is_filtered():
		await refresh_view() # the table's copy shows the part with the Build tree's hidden / rolled-back features applied
	if highlight != null:
		highlight.invalidate(table.table_copy)
	edges.clear()
	faces.clear()
	bodies.clear()
	geometry_changed.emit()
	return true


func _rebuild_markers() -> void:
	## The three plane squares, sized to the part as it is now (they were built for the placeholder box of a new part).
	if markers == null or not is_instance_valid(markers):
		return
	var was_visible: bool = markers.visible
	var chosen_before: String = markers.chosen
	markers.queue_free()
	var copy: MeshInstance3D = table.table_copy
	var aabb := copy.get_aabb()
	markers = PlaneMarkers.new()
	markers.name = "PlaneMarkers"
	copy.add_child(markers)
	markers.setup(aabb.size.length() * 1.25, aabb.get_center(), table.fit_scale)
	markers.set_markers_visible(was_visible)
	if chosen_before != "":
		markers.set_chosen(chosen_before)
	sync_plane_markers()


func end_sketch() -> void:
	## The sketch is spent (extruded): back to choosing a plane.
	cancel_preview()
	repick_point = ""
	_repick_queue.clear()
	session = null
	clip.end()
	if view != null and is_instance_valid(view):
		view.queue_free()
	view = null
	chosen_face = {}
	chosen_plane = ""
	_sheet_vertices.clear()
	if markers != null:
		markers.set_chosen("")
		markers.set_markers_visible(true)
	if highlight != null:
		highlight.set_picks([])
	sync_undo_redo()
	_sync_deck()
	set_state("pick_plane" if state != "pick_plane" else state)
	revolve_axis = ""
	if table.active_tool in ["extrude", "revolve"]:
		table.manager.deactivate()
	_say_pick_plane()


# --- Undo -------------------------------------------------------------------------------------

func sync_undo_redo() -> void:
	table.ui.set_undo_enabled(can_undo())
	table.ui.set_redo_enabled(can_redo())


func can_undo() -> bool:
	return (session != null and session.can_undo()) or not feature_stack.is_empty()


func can_redo() -> bool:
	return not redo_stack.is_empty()


func undo() -> void:
	if session != null and session.can_undo():
		await session.undo()
		sync_undo_redo()
		return
	if feature_stack.is_empty() or api == null:
		return
	var entry = feature_stack.pop_back()
	var result: Dictionary
	if entry is Dictionary:
		result = await features.update_feature(part_id, str(entry["type"]), str(entry["id"]), entry["payload"])
	else:
		result = await features.delete_feature(part_id, str(entry))
	if not result["ok"]:
		feature_stack.append(entry)
		table.set_status("Couldn't take that back: %s" % str(result["error"]))
		return
	if entry is Dictionary:
		if entry.has("redo_payload"):
			redo_stack.append({"kind": "edit", "entry": entry})
	elif created_requests.has(str(entry)):
		var made: Dictionary = created_requests[str(entry)]
		redo_stack.append({"kind": "create", "type": made["type"], "route": made["route"], "body": made["body"]})
		created_requests.erase(str(entry))
	await refresh_geometry()
	table.notify_edited(part_id, _edited_nodes)
	sync_undo_redo()
	table.set_status("Put the old value back." if entry is Dictionary else "Took the last feature back.")


func redo() -> void:
	## Puts back what Undo took back (features and Build-tree edits only; a sketch step is not redone). A feature is made again from the request it
	## was made with and gets a new id, which is harmless because Undo is last-in first-out and nothing later depends on it.
	if redo_stack.is_empty() or api == null or table.table_copy == null:
		return
	if table.build.is_rolled_back_any():
		table.set_status("The part is rolled back. Roll forward in the Build tree before doing it again.")
		return
	var entry: Dictionary = redo_stack.pop_back()
	var result: Dictionary
	if str(entry["kind"]) == "create":
		result = await features.post(part_id, {"ok": true, "error": "", "route": entry["route"], "body": entry["body"]})
		if result["ok"]:
			feature_stack.append(str(result["id"]))
			created_requests[str(result["id"])] = {"type": entry["type"], "route": entry["route"], "body": entry["body"]}
	else:
		var edit: Dictionary = entry["entry"]
		result = await features.update_feature(part_id, str(edit["type"]), str(edit["id"]), edit["redo_payload"])
		if result["ok"]:
			feature_stack.append(edit)
	if not result["ok"]:
		redo_stack.append(entry)
		table.set_status("Couldn't do that again: %s" % str(result["error"]))
		UiFeedback.haptic(table._right, "error")
		return
	await refresh_geometry()
	table.notify_edited(part_id, _edited_nodes)
	sync_undo_redo()
	UiFeedback.haptic(table._right, "confirm")
	table.set_status("Did it again." if str(entry["kind"]) == "create" else "Put the new value back.")
