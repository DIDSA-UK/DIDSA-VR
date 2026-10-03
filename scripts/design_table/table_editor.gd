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
##
## Extrude, Fillet and Chamfer are applied from the options row under the tool row; each ends with a fresh mesh of the part
## fetched from the backend, put on the table AND on every arena instance of it.
##
## The laser claims the shared "ui_hover" meta whenever it's on the part or the sheet (unless the deck already did), the same
## protocol every floating panel uses, so a trigger here never also selects something in the arena.

signal state_changed(state: String)
signal geometry_changed ## the part's mesh was replaced after an edit

const LaserPick := preload("res://scripts/laser_pick.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const SketchMath := preload("res://scripts/design_table/sketch_math.gd")
const SketchSession := preload("res://scripts/design_table/sketch_session.gd")
const SketchView := preload("res://scripts/design_table/sketch_view.gd")
const SnapResolver := preload("res://scripts/design_table/snap_resolver.gd")
const PlaneMarkers := preload("res://scripts/design_table/plane_markers.gd")
const PartFeatures := preload("res://scripts/design_table/part_features.gd")
const MateHealth := preload("res://scripts/design_table/mate_health.gd")
const FaceHighlight := preload("res://scripts/face_highlight.gd")
const UiFeedback := preload("res://scripts/ui/ui_feedback.gd")

const SKETCH_TOOLS := ["line", "rectangle", "circle", "arc", "polygon", "point"]
const CONSTRAIN_TOOLS := ["horizontal", "vertical", "parallel", "perpendicular", "coincident"]
const PICK_RANGE := 4.0 ## metres: how far the laser reaches onto the table
const SNAP_RADIUS := 0.012 ## world metres around the laser in which a snap is taken
const PICK_RADIUS := 0.014 ## world metres around the laser in which an entity is picked
const GHOST_RADIUS := 0.030

var table ## design_table.gd
var api ## cad_api.gd, or anything with request(method, path, body) and fetch_bytes(path); null = no backend
var state := "idle"
var session: RefCounted = null ## sketch_session.gd while a sketch is open
var features: RefCounted = null ## part_features.gd
var view: Node3D = null ## sketch_view.gd, a child of the table's copy
var markers: Node3D = null ## plane_markers.gd, a child of the table's copy
var highlight: Node = null ## this table's own face_highlight.gd (so Mates / Measure never see it)
var part_id := "" ## the PART DEFINITION being edited (every instance of it changes), resolved from the seated node's occurrence
var chosen_face := {} ## {body_id, index} when the sketch is on a face of the part
var chosen_plane := "" ## "XY" | "XZ" | "YZ" when it's on a reference plane
var edges: Array = [] ## picked edge entities (Fillet / Chamfer)
var feature_stack: Array = [] ## ids of the features made here, newest last: what Undo takes back after the sketch is spent
var options := {"boss": true, "flip": false, "new_body": false, "depth": 10.0, "radius": 2.0, "distance": 2.0}
var hovering := false ## the laser is on the part or the sheet this frame, and this editor holds the claim

var _hover_uv: Variant = null
var _snap: Dictionary = {}
var _hover_entity: Dictionary = {}
var _hover_plane := ""
var _hover_face: Dictionary = {}
var _sheet_vertices: Array = []
var _last_view_key := ""
var _orient_tween: Tween = null
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
	if _orient_tween and _orient_tween.is_valid():
		_orient_tween.kill()
	session = null
	view = null
	markers = null
	if highlight != null and is_instance_valid(highlight):
		highlight.queue_free()
	highlight = null
	chosen_face = {}
	chosen_plane = ""
	edges.clear()
	feature_stack.clear()
	hovering = false
	_hover_uv = null
	_snap = {}
	_hover_entity = {}
	_hover_plane = ""
	_hover_face = {}
	_sheet_vertices.clear()
	_last_view_key = ""
	table.ui.set_undo_enabled(false)
	table.ui.set_options([])


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
			_hover_sketch(origin, dir)
		"pick_edges":
			_hover_edges(origin, dir)
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
		return
	var copy_xf: Transform3D = table.table_copy.global_transform
	var plane: Dictionary = session.plane
	var hit_world: Vector3 = copy_xf * SketchMath.from_sheet(uv, plane)
	hovering = _claim(origin.distance_to(hit_world))
	if not hovering:
		view.set_cursor(null)
		return
	_hover_uv = uv
	var radius_mm: float = SNAP_RADIUS / maxf(table.effective_scale(), 0.000001)
	var tool: String = table.active_tool
	if SKETCH_TOOLS.has(tool):
		var line_start: Variant = null
		if tool == "line" and session.pending.size() == 1:
			var first: Dictionary = session.pending[0]
			line_start = session.points.get(str(first.get("id", "")), first.get("uv"))
		_snap = SnapResolver.resolve(uv, session, radius_mm, table.snap_enabled, _sheet_vertices, line_start)
		view.set_cursor(_snap["uv"], str(_snap["kind"]))
		var taps: Array = session.pending.map(func(p): return session.points.get(str(p.get("id", "")), p["uv"]))
		view.set_preview(tool, taps, _snap["uv"], session.polygon_sides)
	elif CONSTRAIN_TOOLS.has(tool) or tool == "dimension":
		var pick_mm: float = PICK_RADIUS / maxf(table.effective_scale(), 0.000001)
		var kinds: Array = ["point", "line", "circle", "arc"]
		if tool in ["horizontal", "vertical", "parallel", "perpendicular"]:
			kinds = ["line"]
		_hover_entity = session.nearest_entity(uv, pick_mm, kinds)
		view.set_cursor(uv, "hover" if not _hover_entity.is_empty() else "free")
		view.set_preview("", [], null)
		var key := "%s:%s" % [_hover_entity.get("kind", ""), _hover_entity.get("id", "")]
		if key != _last_view_key:
			_last_view_key = key
			_refresh_view() # the drawing is rebuilt only when what's under the laser changes
	else:
		view.set_cursor(uv, "free")
		view.set_preview("", [], null)


func _sheet_hit(origin: Vector3, dir: Vector3) -> Variant:
	## Where the laser meets the sketch sheet, as sheet (u, v) in mm, or null if it misses or is off the sheet.
	var copy_xf: Transform3D = table.table_copy.global_transform
	var plane: Dictionary = session.plane
	var normal_w: Vector3 = (copy_xf.basis * (plane["n"] as Vector3)).normalized()
	var point_w: Vector3 = copy_xf * (plane["origin"] as Vector3)
	var hit: Variant = SketchMath.ray_plane(origin, dir, point_w, normal_w)
	if hit == null or origin.distance_to(hit) > PICK_RANGE:
		return null
	var uv := SketchMath.to_sheet(copy_xf.affine_inverse() * (hit as Vector3), plane)
	var half: float = view.sheet_extent * 0.5
	if absf(uv.x - view.sheet_centre.x) > half or absf(uv.y - view.sheet_centre.y) > half:
		return null
	return uv


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


func _pick_plane() -> void:
	var spec := {}
	if _hover_plane != "":
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
	await begin_sketch(spec)


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
	session.changed.connect(_on_session_changed)
	_light_chosen_plane()
	_build_view()
	table.orient_to_plane(session.plane)
	set_state("sketch")
	if SKETCH_TOOLS.has(table.active_tool) or CONSTRAIN_TOOLS.has(table.active_tool) or table.active_tool == "dimension":
		session.set_tool(table.active_tool)
	table.set_status(_sketch_hint())
	return true


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
	var extent := aabb.size.length() * 1.3
	var centre := SketchMath.to_sheet(aabb.get_center(), plane)
	view = SketchView.new()
	view.name = "SketchView"
	copy.add_child(view)
	view.setup(plane, extent, centre, table.fit_scale, table.tokens)
	_sheet_vertices = _vertices_on_plane(copy, plane)
	if markers != null:
		markers.set_markers_visible(false)
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
	_refresh_view()
	_update_options()
	table.ui.set_undo_enabled(can_undo())


func _refresh_view() -> void:
	if view == null or session == null:
		return
	view.rebuild(session, session.selection, _hover_entity)
	view.show_ghosts(session.ghosts)


func _sketch_hint() -> String:
	var def = table.registry.tool_def(table.active_tool) if table.active_tool != "" else null
	if def != null and def.hint != "":
		return def.hint
	return "Sketch open. Pick a tool to draw or constrain."


func _sketch_trigger() -> void:
	if session == null or session.busy or _hover_uv == null:
		return
	var tool: String = table.active_tool
	if SKETCH_TOOLS.has(tool):
		if _snap.is_empty():
			return
		var pick := {"uv": _snap["uv"], "id": _snap["id"]}
		if tool == "line" and session.pending.size() == 1:
			pick["infer"] = _snap.get("infer", "")
		await session.tap(pick)
	elif tool == "dimension":
		var ghost: String = view.ghost_near(session.ghosts, _hover_uv, GHOST_RADIUS / maxf(table.effective_scale(), 0.000001))
		if ghost != "":
			_type_dimension(ghost)
		elif not _hover_entity.is_empty():
			await session.select(_hover_entity)
		else:
			session.clear_selection()
	elif CONSTRAIN_TOOLS.has(tool):
		if not _hover_entity.is_empty():
			await session.select(_hover_entity)


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
		session.set_tool(tool_id if (SKETCH_TOOLS.has(tool_id) or CONSTRAIN_TOOLS.has(tool_id) or tool_id == "dimension") else "")
		_refresh_view()
	match tool_id:
		"fillet", "chamfer":
			if state == "sketch" or state == "pick_plane" or state == "pick_edges" or state == "extrude":
				edges.clear()
				highlight.set_set(table.table_copy, [])
				set_state("pick_edges")
		"extrude":
			if session == null:
				table.set_status("Draw a closed shape on a plane first.")
			elif not session.profile_ok():
				table.set_status("The sketch needs a closed shape to extrude.")
			set_state("extrude" if session != null else state)
		"":
			if state in ["pick_edges", "extrude"]:
				set_state("sketch" if session != null else "pick_plane")
		_:
			if state in ["pick_edges", "extrude"]:
				set_state("sketch" if session != null else "pick_plane")
			if session == null and (SKETCH_TOOLS.has(tool_id) or CONSTRAIN_TOOLS.has(tool_id) or tool_id == "dimension"):
				table.set_status("Pick a flat face or a reference plane to sketch on first.")
	_update_options()


func _update_options() -> void:
	if table == null or table.ui == null:
		return
	var tool: String = table.active_tool
	var list: Array = []
	match tool:
		"polygon":
			if session != null:
				list = [{"id": "sides_down", "text": "Fewer"}, {"id": "sides_label", "text": "%d sides" % session.polygon_sides, "disabled": true}, {"id": "sides_up", "text": "More"}]
		"line":
			list = [{"id": "finish_line", "text": "Finish line"}]
		"extrude":
			list = [
				{"id": "boss", "text": "Boss", "toggle": true, "pressed": bool(options["boss"])},
				{"id": "cut", "text": "Cut", "toggle": true, "pressed": not bool(options["boss"])},
				{"id": "flip", "text": "Flip", "toggle": true, "pressed": bool(options["flip"])},
				{"id": "depth", "text": "Depth %.2f mm" % float(options["depth"])},
				{"id": "apply", "text": "Apply", "disabled": session == null or not session.profile_ok()},
			]
			if bool(options["boss"]):
				list.insert(3, {"id": "new_body", "text": "New body", "toggle": true, "pressed": bool(options["new_body"])})
		"fillet":
			list = [{"id": "radius", "text": "Radius %.2f mm" % float(options["radius"])}, {"id": "clear_edges", "text": "Clear"},
				{"id": "apply", "text": "Apply (%d)" % edges.size(), "disabled": edges.is_empty()}]
		"chamfer":
			list = [{"id": "distance", "text": "Distance %.2f mm" % float(options["distance"])}, {"id": "clear_edges", "text": "Clear"},
				{"id": "apply", "text": "Apply (%d)" % edges.size(), "disabled": edges.is_empty()}]
	table.ui.set_options(list)


func on_option(option_id: String) -> void:
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
		"boss":
			options["boss"] = true
		"cut":
			options["boss"] = false
		"flip":
			options["flip"] = not bool(options["flip"])
		"new_body":
			options["new_body"] = not bool(options["new_body"])
		"depth":
			_type_option("depth", "Depth (mm)")
		"radius":
			_type_option("radius", "Radius (mm)")
		"distance":
			_type_option("distance", "Distance (mm)")
		"clear_edges":
			edges.clear()
			highlight.set_set(table.table_copy, [])
		"apply":
			await apply_feature()
	_update_options()


func _type_option(key: String, title: String) -> void:
	table._main.open_keyboard_for("%.2f" % float(options[key]), func(text: String) -> void: option_typed(key, text), {"title": title})


func option_typed(key: String, text: String) -> void:
	var cleaned := text.strip_edges()
	if not cleaned.is_valid_float() or cleaned.to_float() <= 0.0:
		table.set_status("Enter a number bigger than zero.")
		UiFeedback.haptic(table._right, "error")
		return
	options[key] = cleaned.to_float()
	_update_options()


# --- Edges (Fillet / Chamfer) -----------------------------------------------------------------

func _toggle_edge() -> void:
	if _hover_face.is_empty() or str(_hover_face.get("kind", "")) != "edge":
		return
	for i in edges.size():
		if edges[i]["key"] == _hover_face["key"]:
			edges.remove_at(i)
			highlight.set_set(table.table_copy, edges)
			_update_options()
			return
	edges.append(_hover_face.duplicate())
	highlight.set_set(table.table_copy, edges)
	table.set_status("%d edge(s) picked. Set the size, then Apply." % edges.size())
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


func apply_feature() -> void:
	if table.table_copy == null or api == null:
		return
	var tool: String = table.active_tool
	var result: Dictionary
	table.set_status("Working...")
	match tool:
		"extrude":
			if session == null or not session.profile_ok():
				table.set_status("The sketch needs a closed shape to extrude.")
				return
			var d := extrude_distances()
			result = await features.extrude(part_id, session.feature_id, bool(options["boss"]), d[0], d[1], extrude_targets())
		"fillet":
			result = await features.fillet(part_id, _edge_refs(), float(options["radius"]))
		"chamfer":
			result = await features.chamfer(part_id, _edge_refs(), float(options["distance"]))
		_:
			return
	if not result["ok"]:
		table.set_status("Couldn't do that: %s" % str(result["error"]))
		UiFeedback.haptic(table._right, "error")
		return
	feature_stack.append(str(result["id"]))
	var refreshed: bool = await refresh_geometry()
	if tool == "extrude":
		end_sketch()
	edges.clear()
	if highlight != null:
		highlight.set_set(table.table_copy, [])
	UiFeedback.haptic(table._right, "confirm")
	table.set_status(("%s done." % tool.capitalize()) if refreshed else "Done, but the new shape couldn't be fetched.")
	table.notify_edited(part_id, _edited_nodes)
	_update_options()


func _edge_refs() -> Array:
	return edges.map(func(e): return PartFeatures.edge_ref(str(e["body_id"]), int(e["index"])))


func refresh_geometry() -> bool:
	## Fetches the part's new mesh and puts it on the table AND on every arena instance of the part.
	if api == null or table.table_copy == null:
		return false
	var fetched: Dictionary = await api.fetch_bytes("/document/parts/%s/assembly-mesh.glb?quality=0.5" % part_id)
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
	if highlight != null:
		highlight.invalidate(table.table_copy)
	edges.clear()
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


func end_sketch() -> void:
	## The sketch is spent (extruded): back to choosing a plane.
	session = null
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
	table.ui.set_undo_enabled(can_undo())
	set_state("pick_plane" if state != "pick_plane" else state)
	if table.active_tool in ["extrude"]:
		table.manager.deactivate()
	_say_pick_plane()


# --- Undo -------------------------------------------------------------------------------------

func can_undo() -> bool:
	return (session != null and session.can_undo()) or not feature_stack.is_empty()


func undo() -> void:
	if session != null and session.can_undo():
		await session.undo()
		table.ui.set_undo_enabled(can_undo())
		return
	if feature_stack.is_empty() or api == null:
		return
	var id: String = feature_stack.pop_back()
	var result: Dictionary = await features.delete_feature(part_id, id)
	if not result["ok"]:
		feature_stack.append(id)
		table.set_status("Couldn't take that back: %s" % str(result["error"]))
		return
	await refresh_geometry()
	table.notify_edited(part_id, _edited_nodes)
	table.ui.set_undo_enabled(can_undo())
	table.set_status("Took the last feature back.")
