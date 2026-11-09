extends Node
## The vision brief's "Mates workflow": start the tool, laser-target faces on
## two different parts, pick a mate type from the wrist tablet, type any
## value on the popup keyboard. Built as a thin client to DIDSA-CAD's real
## Mate endpoints (POST/GET/DELETE .../mates, POST .../occurrences/{id}/solve)
## — never a VR-only mate representation — so a mate authored here is
## immediately readable/editable in the flat app and vice versa (vision
## brief's 27 Sep cross-compatibility note; see docs/status.md).
##
## Scope for this pass: FACE-only picking (a raycast against a filled
## triangle mesh naturally resolves to a face — edge picking needs either a
## separate wireframe pickable or a nearest-boundary-edge heuristic on top of
## this, not built yet). Also restricted to top-level Occurrences of the
## loaded root Part: the backend only lets a Mate reference a top-level
## Occurrence of its own owning Part anyway (see MateEntityRef's own
## docstring in DIDSA-CAD), and this also happens to be exactly the case
## where a solved Mate's own local-to-parent transform IS the flattened,
## world-relative-to-root transform baked into that instance's Godot node
## (assembly-mesh.glb has no intermediate parenting at all — see
## _apply_solved_transform below).
##
## "Relax all mates" / "Enforce all mates" (vision brief's Assembly tools):
## there is no bulk-solve endpoint server-side, so "Enforce all" loops
## solve_for_occurrence over every occurrence any of this Part's Mates
## reference. `relaxed` suspends enforcement: no auto-solve after create_mate,
## and mated parts move freely.
##
## POSE SYNC + ENFORCED MOTION (29 Sep 2026, after real-headset testing of
## mates — see docs/status.md). Root cause of "enforce moves one part but they
## don't line up, and it flies off": grip-drags/nudges/rotates only ever moved
## the Godot node, so the backend solved every mate against STALE poses (its
## own copy of where each part was) — the moved peer looked misaligned, and
## the solver's free directions snapped back to the backend's old position.
## The flat app's flow is "PATCH the dragged pose, THEN solve" (the solve
## treats that pose as its initial guess and lands on the NEAREST mate-
## satisfying placement, leaving free directions where you put them). This tool
## now does the same:
##   * every move of a placed (top-level) part is saved to the backend
##     (persist_pose(), a latest-wins write queue per occurrence);
##   * while mates are enforced, dragging a mated, non-grounded part runs the
##     group-aware live projector (constrain_drag()/end_drag(), see "HOW A MATED
##     PART MOVES" below) so it slides along what its mates allow instead of
##     flying off, and the parts mated to it follow as the mates require;
##   * a GROUNDED (fixed) part that has mates can't be moved while enforced
##     (is_locked()); the tablet's Fix/Float toggle (toggle_fixed()) picks
##     which part is the anchor;
##   * solve failures and grounded-part refusals are reported on the tablet
##     instead of being swallowed.

const BackendSession := preload("res://scripts/backend_session.gd") ## the API key and this app's own X-Document-Session on every call
signal picks_changed()
signal sandbox_changed(on: bool) ## Relax all mates turned on (the sandbox) or off (the parts went home): the tablet's toggle and the wheel follow it
signal document_changed() ## a mate was made or deleted, or a part grounded / floated: what a save would write is different
signal mates_changed()
signal highlight_changed() ## a mate was selected on the tablet (or the selection went): what it lights changed (T3)
signal enforce_finished(result: Dictionary) ## enforce_all() ended: {ok, solved, problems}

const API_PREFIX := "/document"
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const COPY_UNIT_SCALE := 1.0 ## pattern-copy nodes sit in the backend's millimetres like every placed part (assembly_root's scale is above them): the glb's own units, no spawn_scale (see _apply_solved_transform)
const GroupIndex := preload("res://scripts/group_index.gd") ## base_segment: a pattern copy's segment folds to its source (mate_ref_top)
const Se3 := preload("res://scripts/motion/se3.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const MotionBlender := preload("res://scripts/motion/motion_blender.gd")
const DofHysteresis := preload("res://scripts/motion/dof_hysteresis.gd")
const ReanchorScheduler := preload("res://scripts/motion/reanchor_scheduler.gd")
const CopyPose := preload("res://scripts/motion/pattern_copy_pose.gd") ## where a pattern copy stands for a source at a pose (live, during a drag)
const LocalRetraction := preload("res://scripts/motion/local_retraction.gd") ## reads the limit mates of a version-6 model (their measured values); its solve is not run per frame (see _limit_stop)
const MATE_TYPES: Array[String] = ["coincident", "concentric", "parallel", "distance", "angle", "width", "symmetric", "gear", "rack_pinion", "screw", "limit_distance", "limit_angle"]
## The coupler ("motion") mates (docs/gears-and-motion-plan.md): they place nothing, they keep a relation between how far the two parts MOVE, so turning
## one turns the other. Two axis picks (a round face, a circular edge or a straight edge; the rack's second a straight edge), a value (gear: ratio, B
## turns per A turn; rack and pinion: mm of rack per pinion turn; screw: mm per turn) and a sense ("Reverse" / "Left-hand"). `mate_value` 0 is Auto for
## gear and rack and pinion (the backend reads the teeth); a screw needs its lead.
const COUPLER_TYPES: Array[String] = ["gear", "rack_pinion", "screw"]
## The limit mates (docs/limit-mates-scope.md): they place nothing and keep a distance or an angle between a minimum and a maximum (either may be left
## out). Two picks like Distance / Angle (a plane on at least one side for a distance; a hinge - a concentric mate between the same two parts - for an
## angle) and a range instead of a value. A drag stops at the bound.
const LIMIT_TYPES: Array[String] = ["limit_distance", "limit_angle"]
## The UI-only mate type of a Width mate (docs/width-mate-plan.md in DIDSA-CAD): four faces - the gap's two, then the two of the part(s) to
## centre in it - sent as a plain coincident (centred) or distance (offset from the centre) mate whose two references are mid-planes.
## Nothing is created for the mid-plane: it is worked out by the backend on every solve and never drawn.
const WIDTH_TYPE := "width"
## The UI-only mate type of a Symmetric mate (W5): two faces on two parts that mirror each other about a plane (a left and a right bracket
## either side of a centre part). Three picks - face 1, face 2, a face of the mirror plane (a third part). Sent as a plain coincident mate of
## [midplane(face 1, face 2), the mirror plane's face]: two faces mirror each other about P exactly when the plane midway between them is P,
## so no new mate type or reference exists. Faces only (points and axes would need a three-reference mate; not built).
const SYMMETRIC_TYPE := "symmetric"

var active := false ## wrist tablet's "Mates tool" toggle
var backend_url := ""
var api_key := ""
var command_stack = null ## set via setup(); shared undo/redo history

## What the mate being set up will be. Changing any of them re-runs the preview (a ghost of the part where the mate would put it).
var mate_type := "coincident":
	set(v):
		var crosses := (v in [WIDTH_TYPE, SYMMETRIC_TYPE] and v != mate_type) or (mate_type in [WIDTH_TYPE, SYMMETRIC_TYPE] and v != mate_type)
		if v != mate_type and (v in COUPLER_TYPES or mate_type in COUPLER_TYPES):
			mate_value = 0.0 # a distance typed for another kind of mate is not a ratio, a travel or a lead (0 = Auto)
		if v != mate_type:
			limit_min = null # a range typed for one limit is not another's
			limit_max = null
			preview_limit_value = null
		mate_type = v
		if crosses and not _picks.is_empty():
			clear_picks() # a Width mate and the two-pick types pick different things: start the picks over
			return
		reset_branch_choice() # a choice made for another kind of mate means nothing here
		request_preview()
## A Width mate's offset from the centre (mm, never negative: the side is the Flip side control); 0 = centred exactly.
var width_offset := 0.0:
	set(v):
		width_offset = v
		request_preview()
var mate_value := 0.0:
	set(v):
		mate_value = v
		request_preview()
## A limit mate's range (mm, or degrees for an angle): null = no bound on that side. Not both null.
var limit_min = null:
	set(v):
		limit_min = v
		request_preview()
var limit_max = null:
	set(v):
		limit_max = v
		request_preview()
var preview_limit_value = null ## a limit: the measured value of the picked pair now (the latest preview's `limit_value`), to type a range against
## The branch the user picked ("Closest" = not picked: the backend resolves it and the preview says which): "" or "aligned" /
## "anti_aligned", and -1 (auto) / 0 / 1 for the DISTANCE side, locked-CONCENTRIC half-turn or ANGLE supplement. Which of them mean
## anything for the picked geometry is the backend's call (`branch_controls`, from the preview).
var mate_alignment: String:
	get:
		return _alignment_choice
	set(v):
		_alignment_choice = v
		request_preview()
var mate_secondary_flip: int:
	get:
		return _flip_choice
	set(v):
		_flip_choice = v
		request_preview()
var mate_allow_rotation := true:
	set(v):
		mate_allow_rotation = v
		reset_branch_choice()
		request_preview()
## Mirrors the flat client's "Minimal movement" (MatePanel): move only the mated part when that is enough and let connected parts follow only
## when it is not (the backend's `auto` movement mode); off lets the whole connected group move (`group`). Preview, Create and Edit all use it.
var mate_minimal_movement := true:
	set(v):
		mate_minimal_movement = v
		request_preview()
var relaxed := false ## the SANDBOX (set_relaxed): mates are not enforced and every move is on screen only, until the parts go home
var return_glide_s := 0.45 ## how long the parts take to glide home when the sandbox ends (0: at once; tests)
var sandbox_ghosts := false ## while relaxed, a see-through copy of each moved part where it will go back to (Settings > Assemble)
var sandbox_lines := false ## while relaxed, a thin line from each moved part to its home (Settings > Assemble)

var mates: Array = [] ## last-fetched list for _current_owner_part_id, for the tablet's list UI
var occurrences: Dictionary = {} ## occurrence_id -> {"fixed": bool}, top-level occurrences of _current_owner_part_id (refresh_state())

var _labels: Dictionary = {} ## "owner|occurrence" -> a short readable name (part_label)
var _part_names: Dictionary = {} ## resolved part id -> the Part's own name, fetched once
var _mated_ids: Dictionary = {} ## occurrence_id -> true, for every occurrence any Mate references
var _drag: Dictionary = {} ## part -> live-drag state, see constrain_drag()
var _last_locked_notice_ms := -10000
var _persist: Dictionary = {} ## occurrence_id -> {"pose": Dictionary|null, "running": bool} — see persist_pose()

const GHOST_COLOUR := Color(0.31, 0.77, 1.0, 0.40)

var _picks: Array[Dictionary] = []
var _width_error := "" ## a Width pair whose two faces are not parallel (checked as soon as the pair is complete), else ""
var _width_seq := 0
var _ghosts: Array[Node3D] = [] ## the preview: a see-through copy of every part the mate would move (the driven one and any followers), where it would put it
var _preview_seq := 0 ## bumped on every change so a slow answer for an older setting is ignored
var _status := ""
var _alignment_choice := ""
var _flip_choice := -1
var branch_controls: Array = [] ## the preview's `controls`: the branch fields ("alignment", "secondary_flip") this geometry has
var branch_resolved: Dictionary = {} ## the preview's `resolved`: the branch the ghost shows
var branch_alternatives: Array = [] ## the preview's `alternatives`, nearest first: what "Next solution" steps through
var _branch_changes: Array = [] ## the earlier mates the latest preview needs on their other branch ([{mate_id, field, from, to}]); Create sends them back
var _branch_notice := "" ## the sentence telling the user so (branch_notice())
var _flip_base := -1 ## a coupler: the sense (0 / 1) the backend chose by default, which "Reverse" / "Left-hand" is measured from (-1 = not known yet)
var preview_coupler_value := -1.0 ## a coupler: the ratio / travel / lead the latest preview says the mate would be made with (-1 = none)
var _pending_edit: Dictionary = {} ## "mate_id|fields" -> the branch changes an edit was refused for; repeating that exact edit confirms them
var _busy := false
var _group_poses: Dictionary = {} ## "owner|occurrence" -> Transform3D of a sub-assembly occurrence, as last read or written (group_pose())
var _group_persist: Dictionary = {}
var _current_owner_part_id := "" ## the ACTIVE root: the one the Mates page lists and creates mates on (the world's loaded root)
var _pattern_cache: Dictionary = {} ## owner Part id -> its component pattern rows (`GET .../component-patterns`), fetched once per scope: what a live drag moves the copies by
var _pattern_fetching: Dictionary = {} ## owner Part id -> true while that fetch is in flight
var _other_states: Dictionary = {} ## owner Part id -> {"occurrences": {occ: {"fixed"}}, "mated": {occ: true}} for every OTHER root whose parts can be moved and saved: each open Assembly Room's Part (load_owner_state)
var _nested_states: Dictionary = {} ## sub-assembly Part id -> {"occurrences": {occ: {"fixed"}}, "mated": {occ: true}} for every Part below the active root (refresh_nested_state)
var _home: Dictionary = {} ## the sandbox's snapshot: part node -> its local transform when Relax went on (sandbox_snapshot() is the same, keyed for a scene)
var _sandbox_solve: Array = [] ## [{owner, occ}]: what mates made or edited while relaxed drive, solved once the parts are home
var _cues: Dictionary = {} ## part node -> {"ghost": Node3D, "line": MeshInstance3D}: the sandbox's optional cues
var _cue_tick := 0.0
var _nested_order: Array = [] ## those Parts, each after every Part below it: the order Enforce all solves them in
const MAX_NEST_DEPTH := 32


func setup(stack) -> void:
	command_stack = stack


func configure_backend(url: String, key: String) -> void:
	backend_url = url
	api_key = key
	_pattern_cache.clear() # another server, another document


func is_busy() -> bool:
	return _busy


func set_active(on: bool) -> void:
	active = on
	if on:
		clear_highlight() # picking starts: the pick colours are for the picks
	else:
		clear_picks()


# --- Selecting a mate on the tablet lights the two things it mates (T3) -------------------------------------------------------

var highlight_id := "" ## the mate selected on the tablet ("" = none)
var _highlight_entries: Array = []
var _pulse_sources: Array = []


func mate_highlight_entries() -> Array:
	## [{part, kind, body_id, index, key, colour_slot}] for face_highlight.gd's set_picks(): what the selected mate mates.
	return _highlight_entries


static func highlight_for(mate: Dictionary, nodes: Array) -> Dictionary:
	## The faces, edges and vertices a mate's references name, as face_highlight entries in the two pick colours (side 1: slot 0, side 2: slot 1; a
	## Width mate's gap faces are slot 0 and the part's slot 1, a Symmetric mate's mirrored pair slot 0 and its plane's face slot 1). `nodes` are the arena
	## nodes to look in (tagged with occurrence_id). Plane, point and axis-less references name no face and are skipped, with the reason.
	## Returns {entries, parts: [Node3D], skipped: [String]}.
	var entries: Array = []
	var parts: Array = []
	var skipped: Array = []
	var refs: Array = mate.get("references", [])
	for side in refs.size():
		var ref = refs[side]
		if not (ref is Dictionary):
			continue
		var occ := str(ref.get("occurrence_id", ""))
		if ref.get("subshape_ref") is Dictionary:
			_add_entity(entries, parts, skipped, nodes, occ, ref["subshape_ref"], side)
		elif ref.get("midplane") is Dictionary:
			var mid: Dictionary = ref["midplane"]
			for key in ["a", "b"]:
				var plane = mid.get(key)
				var occ_for := occ if key == "a" or mid.get("b_occurrence_id") == null else str(mid["b_occurrence_id"])
				if plane is Dictionary and plane.get("face_ref") is Dictionary:
					_add_entity(entries, parts, skipped, nodes, occ_for, plane["face_ref"], side)
				else:
					skipped.append("a plane")
		elif ref.get("plane_ref") != null:
			skipped.append("a plane")
		elif ref.get("point_ref") != null:
			skipped.append("a point")
	return {"entries": entries, "parts": parts, "skipped": skipped}


static func _add_entity(entries: Array, parts: Array, skipped: Array, nodes: Array, occurrence_id: String, subshape: Dictionary, side: int) -> void:
	var part := _node_for(nodes, occurrence_id)
	var kind := str(subshape.get("shape_type", "face"))
	if part == null:
		skipped.append("a part that is not on screen")
		return
	if kind not in ["face", "edge", "vertex"]:
		skipped.append(kind)
		return
	var body_id := str(subshape.get("body_id", ""))
	var index := int(subshape.get("index", -1))
	entries.append({"part": part, "kind": kind, "body_id": body_id, "index": index, "face_index": -1,
		"key": TopologyPick.entity_key(kind, body_id, index), "colour_slot": side})
	if part not in parts:
		parts.append(part)


static func _node_for(nodes: Array, occurrence_id: String) -> Node3D:
	## The arena node showing this occurrence: a visible one first (an open room's copy is the one you see, the world's is hidden under it).
	var fallback: Node3D = null
	for node in nodes:
		if not is_instance_valid(node) or not node.has_meta("occurrence_id") or str(node.get_meta("occurrence_id")) != occurrence_id:
			continue
		if node is Node3D and (node as Node3D).is_visible_in_tree():
			return node
		if fallback == null:
			fallback = node
	return fallback


static func direction_hint(camera_transform: Transform3D, point: Vector3, part_name: String) -> String:
	## "" when the point is in front of you; else which way to look ("Bracket is behind you", "...off to your left").
	var to_point := point - camera_transform.origin
	if to_point.length() < 0.001:
		return ""
	var forward := -camera_transform.basis.z
	var cos_angle := forward.dot(to_point.normalized())
	if cos_angle > 0.5: # inside about 60 degrees of straight ahead
		return ""
	if cos_angle < -0.3:
		return "%s is behind you." % part_name
	var side := camera_transform.basis.x.dot(to_point.normalized())
	if absf(camera_transform.basis.y.dot(to_point.normalized())) > absf(side):
		return "%s is %s you." % [part_name, "above" if camera_transform.basis.y.dot(to_point.normalized()) > 0.0 else "below"]
	return "%s is off to your %s." % [part_name, "right" if side > 0.0 else "left"]


func highlight_mate(mate_id: String, camera: Camera3D = null) -> bool:
	## Selecting a mate on the tablet (T3): lights the entities it mates (slot 0 and 1 pick colours), pulses the two parts' bodies for a moment so a
	## mate between hidden faces can still be found, and says in the status line if a part is out of view. "" (or the selected one again) clears it.
	## True when something was lit.
	clear_highlight(false)
	if mate_id == "":
		highlight_changed.emit()
		return false
	var found := {}
	for mate in mates:
		if str(mate.get("id", "")) == mate_id:
			found = mate
	if found.is_empty():
		highlight_changed.emit()
		return false
	var nodes: Array = get_tree().get_nodes_in_group("grabbable_parts") if is_inside_tree() else []
	var result := highlight_for(found, nodes)
	highlight_id = mate_id
	_highlight_entries = result["entries"]
	highlight_changed.emit()
	if camera != null:
		for part in result["parts"]:
			var centre: Vector3 = part.global_transform * (part as MeshInstance3D).get_aabb().get_center() if part is MeshInstance3D else part.global_position
			var hint := direction_hint(camera.global_transform, centre, str(part.name))
			if hint != "":
				_status = hint
				picks_changed.emit() # the tablet's status line reads status_text()
				break
	_pulse(result["entries"])
	return not _highlight_entries.is_empty()


func clear_highlight(announce: bool = true) -> void:
	_stop_pulse()
	if highlight_id == "" and _highlight_entries.is_empty():
		return
	highlight_id = ""
	_highlight_entries = []
	if announce:
		highlight_changed.emit()


const PULSE_SECONDS := 0.9
var _pulse_token := 0


func _pulse(entries: Array) -> void:
	## The two parts' referenced bodies outlined (face_highlight.gd's hover material, which is lighter than the pick colours) for a moment.
	var highlight = get_parent().get("face_highlight") if get_parent() != null else null
	if highlight == null or entries.is_empty():
		return
	_stop_pulse()
	_pulse_token += 1
	var token := _pulse_token
	var seen := {}
	for entry in entries:
		var key := "%d:%s" % [(entry["part"] as Node).get_instance_id(), entry["body_id"]]
		if seen.has(key):
			continue
		seen[key] = true
		var source := RefCounted.new()
		_pulse_sources.append(source)
		highlight.set_hover_entity(source, entry["part"], {"kind": "body", "body_id": entry["body_id"], "index": -1, "face_index": -1, "key": TopologyPick.body_key(str(entry["body_id"]))})
	if is_inside_tree():
		get_tree().create_timer(PULSE_SECONDS).timeout.connect(func() -> void:
			if token == _pulse_token:
				_stop_pulse())


func _stop_pulse() -> void:
	var highlight = get_parent().get("face_highlight") if get_parent() != null else null
	if highlight != null:
		for source in _pulse_sources:
			highlight.clear_hover(source)
	_pulse_sources.clear()


func clear_picks() -> void:
	_picks.clear()
	_status = ""
	_width_error = ""
	_width_seq += 1
	_branch_changes = []
	_branch_notice = ""
	branch_controls = []
	branch_resolved = {}
	branch_alternatives = []
	reset_branch_choice()
	request_preview() # two picks are gone, so the ghost goes with them
	picks_changed.emit()


func _exit_tree() -> void:
	_clear_ghost()


func is_width() -> bool:
	return mate_type == WIDTH_TYPE


func is_symmetric() -> bool:
	return mate_type == SYMMETRIC_TYPE


func is_coupler() -> bool:
	return mate_type in COUPLER_TYPES


func is_limit() -> bool:
	return mate_type in LIMIT_TYPES


func is_multi() -> bool:
	## A Width or Symmetric mate: picked as several faces rather than two entities.
	return is_width() or is_symmetric()


func pick_target() -> int:
	## How many picks the mate being set up needs: 4 faces for a Width mate, 3 for a Symmetric one, else 2 entities.
	return 4 if is_width() else (3 if is_symmetric() else 2)


static func symmetric_progress_text(count: int) -> String:
	## Pure - what to pick next for a Symmetric mate that has `count` faces so far ("N of 3").
	match count:
		0:
			return "Symmetric 1 of 3: pick the first face to mirror."
		1:
			return "Symmetric 2 of 3: pick the second face to mirror (on another part)."
		2:
			return "Symmetric 3 of 3: pick a face of the mirror plane (on a third part)."
	return "Symmetric 3 of 3: all three faces picked."


static func width_progress_text(count: int) -> String:
	## Pure - what to pick next for a Width mate that has `count` faces so far ("N of 4").
	match count:
		0:
			return "Width 1 of 4: pick the first face of the gap."
		1:
			return "Width 2 of 4: pick the second face of the gap (same part or another)."
		2:
			return "Width 3 of 4: pick the first face of the part to centre."
		3:
			return "Width 4 of 4: pick the second face of the part to centre."
	return "Width 4 of 4: all four faces picked."


func back_pick() -> void:
	## Takes back the last pick (a Width mate has four, so Clear alone is a heavy undo).
	if _picks.is_empty():
		return
	_picks.pop_back()
	_status = ""
	_width_error = ""
	_width_seq += 1
	reset_branch_choice()
	request_preview()
	picks_changed.emit()


func status_text() -> String:
	if _status != "":
		return _status
	if is_multi():
		if _width_error != "":
			return _width_error
		if _picks.size() < pick_target():
			return symmetric_progress_text(_picks.size()) if is_symmetric() else width_progress_text(_picks.size())
	match _picks.size():
		0:
			return "Pick a round face, a circular edge or a straight edge (the axis) on the first part." if is_coupler() else "Pick a face, edge or corner on the first part."
		1:
			if mate_type == "rack_pinion":
				return "Pick a straight edge along the rack on the second part."
			return "Pick a round face, a circular edge or a straight edge (the axis) on the second part." if is_coupler() else "Pick a face, edge or corner on the second part."
		_:
			if _branch_notice != "":
				return _branch_notice
			if mate_type == "screw" and mate_value <= 0.0:
				return "A screw needs its lead (mm per turn): press Set value."
			if is_limit():
				if limit_min == null and limit_max == null:
					return "%s Press Set value to type the range." % limit_now_text(mate_type, preview_limit_value)
				return "Moving the part past the range stops it at the bound. %s" % limit_now_text(mate_type, preview_limit_value)
			if is_coupler():
				var value_note := ""
				if mate_value <= 0.0 and preview_coupler_value > 0.0:
					value_note = " (%s, from the teeth)" % coupler_value_text(mate_type, preview_coupler_value)
				return "Turning one part will turn the other%s. Press Reverse if they should go the other way, then Create." % value_note
			if preview_visible():
				return "Preview shown in blue. If it is the wrong way press Flip or Next solution, then Create."
			return "Ready — choose a mate type and Create."
	return ""


func picked_entities() -> Array:
	## [{part, kind, body_id, index, face_index, key}] for face_highlight.gd, in pick order (a face, edge or vertex).
	var out := []
	for i in _picks.size():
		var p: Dictionary = _picks[i]
		var entity: Dictionary = (p.get("entity", {}) as Dictionary).duplicate()
		entity["part"] = p.get("part")
		if is_multi():
			entity["colour_slot"] = int(i / 2.0) # Width: the gap's two faces in one colour, the part to centre's in the other; Symmetric: the mirrored pair, then the mirror plane
		if not entity.has("face_index"):
			entity["face_index"] = p.get("face_index", -1)
		out.append(entity)
	return out


func picked_labels() -> Array:
	var out := []
	for p in _picks:
		out.append(p["label"])
	return out


func try_pick(part: Node3D, face_index: int, entity: Dictionary = {}) -> void:
	## Called by controller.gd's trigger handler while the tool is active.
	## Always sets status and emits picks_changed, even on rejection, so the
	## wrist tablet can show *why* a pick didn't count.
	if not active or _picks.size() >= pick_target():
		return
	clear_highlight() # picking starts: a mate selected on the tablet stops lighting its entities
	var occ_ref := MeshIdentity.occurrence_ref_for(part)
	if not occ_ref.is_empty() and str(occ_ref.get("occurrence_id", "")) == "":
		var copy_ref := copy_occurrence_ref(part)
		if not copy_ref.is_empty():
			occ_ref = copy_ref # a pattern copy: mated by its own segment (the backend lets its source's pose drive it)
	var subshape := MeshIdentity.subshape_ref_for_hit(part, face_index)
	var kind := "face"
	if not subshape.is_empty() and not entity.is_empty() and str(entity.get("kind", "face")) != "face":
		# The laser was on a straight / circular edge or a corner of that face (topology_pick.gd): mate that.
		kind = str(entity["kind"])
		subshape = {"body_id": str(entity["body_id"]), "shape_type": kind, "index": int(entity["index"])}
	if is_coupler() and kind != "face" and not subshape.is_empty() and not (mate_type == "rack_pinion" and _picks.size() == 1):
		# A coupler's turning side wants the AXIS. The laser on a round face (a bore, a shaft) snaps to that face's seam line or a corner of it when it is
		# near one, and the seam is a straight edge 4 mm off the axis: mating on it would turn the part about the wrong line. Take the round face itself.
		var hit_face := TopologyPick.face_entity(part, face_index)
		if not hit_face.is_empty() and TopologyPick.axis_kind(part, hit_face) == "cylinder" and TopologyPick.axis_kind(part, entity) in ["line", "vertex"]:
			kind = "face"
			entity = {}
			subshape = MeshIdentity.subshape_ref_for_hit(part, face_index)
	var rejection := _validate_pick(occ_ref, subshape)
	if rejection == "" and is_multi() and _width_error != "":
		rejection = "The last two faces are not parallel: press Undo pick first."
	if rejection == "" and is_multi() and kind != "face":
		rejection = "A Symmetric mate is made from faces." if is_symmetric() else "A Width mate is made from faces."
	if rejection == "" and is_coupler():
		rejection = coupler_rejection(mate_type, _picks.size(), TopologyPick.axis_kind(part, entity if kind != "face" else TopologyPick.face_entity(part, face_index)))
	if rejection == "" and not TopologyPick.is_mateable(part, entity if kind != "face" else TopologyPick.face_entity(part, face_index)):
		rejection = "A mate can only use a plane, a cylinder, a straight or circular edge, or a corner - this surface is none of those."
	if rejection != "":
		_status = rejection
		picks_changed.emit()
		return
	_picks.append({
		"owner_part_id": occ_ref["owner_part_id"],
		"occurrence_id": occ_ref["occurrence_id"],
		"subshape_ref": subshape,
		"label": label_or(part, str(part.name)), # Node.name is a StringName, not a String - cast once here so later == comparisons (tests, UI) behave
		"part": part, # for face_highlight.gd: the picked face / edge / corner stays lit
		"face_index": face_index,
		"entity": entity if kind != "face" else {},
		"kind": kind,
	})
	_status = ""
	_width_error = ""
	reset_branch_choice() # another face means another set of roots
	if is_multi() and (_picks.size() == 2 or (is_width() and _picks.size() == 4)):
		_check_width_pair(_picks[_picks.size() - 2], _picks[_picks.size() - 1])
	else:
		request_preview()
	picks_changed.emit()


static func width_rejection(picks: Array, occ_ref: Dictionary, subshape: Dictionary, symmetric := false) -> String:
	## Pure - why `subshape` (on `occ_ref`) cannot be the next face of a Width mate that has `picks`, or "". Either pair may be made of two
	## parts (two loose bars; a plate of two parts); the part(s) to centre just must not be a part of the gap.
	if not picks.is_empty() and picks[0]["owner_part_id"] != occ_ref["owner_part_id"]:
		return "All the parts must belong to the same assembly."
	for p in picks:
		if p["occurrence_id"] == occ_ref["occurrence_id"] and (p["subshape_ref"] as Dictionary) == subshape:
			return "That face is already picked."
	if symmetric and picks.size() == 1 and picks[0]["occurrence_id"] == occ_ref["occurrence_id"]:
		return "The two mirrored faces must be on different parts."
	if picks.size() >= 2 and (picks[0]["occurrence_id"] == occ_ref["occurrence_id"] or picks[1]["occurrence_id"] == occ_ref["occurrence_id"]):
		if symmetric:
			return "The mirror plane must be a face of a different part from the two faces being mirrored."
		return "The part to centre must be a different part from the gap."
	return ""


static func is_broken(mate: Dictionary) -> bool:
	## The backend's computed mate status (`MateResponse.status`, "ok" | "broken"; a suppressed mate is always "ok"). An older backend sends none: not broken.
	return str(mate.get("status", "ok")) == "broken" and not bool(mate.get("suppressed", false))


static func is_copy_id(occurrence_id: String) -> bool:
	## A pattern copy's segment (`A#pattern:P:1`): it is a fixed function of its source's pose, so it is never driven, and `#` never goes in a URL.
	return occurrence_id.contains(GroupIndex.PATTERN_SEGMENT)


static func copy_occurrence_ref(part: Node3D) -> Dictionary:
	## {owner_part_id, occurrence_id} for a node that is a pattern COPY (the glb gives it occurrence_id "" and an `instance_path` whose last segment is
	## `<source>#pattern:<pattern>:<index>`, read in the node's owner Part): the copy's own segment, which the backend accepts in a mate. Empty for
	## anything else (root content, an ordinary part, an older backend that wrote no instance_path).
	if not is_instance_valid(part) or not part.has_meta("owner_part_id"):
		return {}
	var path := str(part.get_meta("instance_path", ""))
	var last := path.get_slice("/", path.get_slice_count("/") - 1)
	if not is_copy_id(last):
		return {}
	return {"owner_part_id": part.get_meta("owner_part_id"), "occurrence_id": last}


func _validate_pick(occ_ref: Dictionary, subshape: Dictionary) -> String:
	## Pure, no network — "" means OK, else a user-facing rejection reason.
	if occ_ref.is_empty():
		return "This part has no backend identity yet (not loaded from the backend)."
	if occ_ref.get("occurrence_id", "") == "":
		return "Can't mate the assembly's own root content — pick a placed part."
	if subshape.is_empty():
		return "This part has no face identity yet (not loaded from the backend)."
	if is_multi():
		return width_rejection(_picks, occ_ref, subshape, is_symmetric())
	if not _picks.is_empty():
		var first: Dictionary = _picks[0]
		if first["owner_part_id"] != occ_ref["owner_part_id"]:
			return "Both parts must belong to the same assembly."
		if first["occurrence_id"] == occ_ref["occurrence_id"]:
			return "Pick two different parts, not the same one twice."
		if is_copy_id(str(first["occurrence_id"])) and is_copy_id(str(occ_ref["occurrence_id"])):
			return "Mate a pattern copy to an ordinary part, not to another copy."
		if GroupIndex.base_segment(str(first["occurrence_id"])) == GroupIndex.base_segment(str(occ_ref["occurrence_id"])):
			return "A pattern copy follows its source: pick a different part."
	return ""


# --- Preview: a ghost of the part where the mate would put it --------------------------

func preview_visible() -> bool:
	for ghost in _ghosts:
		if is_instance_valid(ghost):
			return true
	return false


func movement_param() -> String:
	## The backend's `movement` query value for `mate_minimal_movement` (the flat client's `_mateMovement`).
	return "auto" if mate_minimal_movement else "group"


func request_preview() -> void:
	## Re-runs the dry run for the mate as it is set up now (the backend's preview-mate-solve: same body as
	## Create, nothing stored, nothing moved). With fewer than two picks, or no backend, the ghost is removed.
	_preview_seq += 1
	if not active or _picks.size() != pick_target() or _width_error != "" or backend_url == "" or not is_inside_tree():
		_clear_ghost()
		return
	_run_preview(_preview_seq)


func _check_width_pair(first: Dictionary, second: Dictionary) -> void:
	## The moment a pair of a Width mate is complete: are its two faces parallel? (The backend's Measure answers `faces_parallel`.) A pair that is
	## not says so and stops the preview; the next pick change re-checks. Without a backend there is nothing to ask, so the pair stands.
	_width_seq += 1
	var seq := _width_seq
	if backend_url == "" or not is_inside_tree():
		request_preview()
		return
	var refs := [
		{"occurrence_id": first["occurrence_id"], "subshape_ref": first["subshape_ref"]},
		{"occurrence_id": second["occurrence_id"], "subshape_ref": second["subshape_ref"]},
	]
	var result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/measure" % str(first["owner_part_id"]), {"refs": refs})
	if seq != _width_seq or not is_multi():
		return # the picks changed while the answer was on its way
	var json = result.get("json")
	if result["ok"] and json is Dictionary and json.get("faces_parallel") == false:
		_width_error = "These two faces are not parallel - a Width mate needs a pair of parallel faces. Press Undo pick and choose another."
		_clear_ghost()
		picks_changed.emit()
		return
	request_preview()
	picks_changed.emit()


static func preview_members(preview: Dictionary, driven_id: String) -> Array:
	## Pure — [{occurrence_id, transform}] a converged preview moves: the backend's `members` (the driven part first, then every follower that
	## changed), or - for a backend that predates the field - just the driven part from `transform`. Empty when it did not converge.
	if not bool(preview.get("converged", false)):
		return []
	var members = preview.get("members")
	if members is Array and not (members as Array).is_empty():
		var out := []
		for m in members:
			if m is Dictionary and m.get("transform") is Dictionary:
				out.append({"occurrence_id": str(m.get("occurrence_id", "")), "transform": m["transform"]})
		return out
	if preview.get("transform") is Dictionary:
		return [{"occurrence_id": driven_id, "transform": preview["transform"]}]
	return []


static func branch_notice(changes: Array, blocked_by: Array, conflicting: Array, mates: Array) -> String:
	## Pure — the sentence for a preview that needs earlier mates on their other branch (`branch_changes`), or cannot get there
	## (`blocked_by`: mates the user set, `conflicting`: a genuine conflict). "" when there is nothing to say.
	var describe := func(ids: Array) -> String:
		var labels: Array[String] = []
		for id in ids:
			var label := "a mate"
			for mate in mates:
				if mate is Dictionary and str(mate.get("id", "")) == str(id):
					label = "%s mate" % str(mate.get("type", "")).capitalize()
			labels.append(label)
		return ", ".join(labels)
	if not changes.is_empty():
		var ids: Array = []
		for c in changes:
			if c is Dictionary and not ids.has(str(c.get("mate_id", ""))):
				ids.append(str(c.get("mate_id", "")))
		if ids.size() == 1:
			return "To fit, an earlier mate (%s) moves to its other side or orientation. Create applies it." % describe.call(ids)
		return "To fit, %d earlier mates (%s) move to their other side or orientation. Create applies them." % [ids.size(), describe.call(ids)]
	if not blocked_by.is_empty():
		return "A mate you set to one side or orientation stands in the way (%s). Change it to allow this mate." % describe.call(blocked_by)
	if not conflicting.is_empty():
		return "This mate conflicts with an earlier mate (%s)." % describe.call(conflicting)
	return ""


static func confirmed_changes(changes: Array) -> Array:
	## Pure — the confirmed form of the preview's `branch_changes` (the backend's BranchChangeRequest: no `from`).
	var out := []
	for c in changes:
		if c is Dictionary:
			out.append({"mate_id": c.get("mate_id", ""), "field": c.get("field", ""), "to": c.get("to")})
	return out


func reset_branch_choice() -> void:
	## Back to Closest, without re-running the preview (the caller does).
	_alignment_choice = ""
	_flip_choice = -1
	_flip_base = -1
	preview_coupler_value = -1.0


static func type_label(type: String) -> String:
	## Pure - the name of a mate type in lists.
	match type:
		"rack_pinion":
			return "Rack and pinion"
		"limit_distance":
			return "Limit distance"
		"limit_angle":
			return "Limit angle"
		"width", "symmetric", "gear", "screw":
			return type.capitalize()
	return type.capitalize()


static func limit_unit(type: String) -> String:
	return "\u00b0" if type == "limit_angle" else " mm"


static func limit_now_text(type: String, value) -> String:
	## Pure - "Now 20 mm." (the measured value of the pair), or "" when not known.
	if value == null:
		return ""
	return "Now %s%s." % [_trim_number(float(value)), limit_unit(type)]


static func limit_range_text(type: String, lo, hi) -> String:
	## Pure - a limit's range as the lists show it: "0 mm to 30 mm", "min 5 mm", "max 110\u00b0"; "" with neither bound.
	var unit := limit_unit(type)
	if lo != null and hi != null:
		return "%s%s to %s%s" % [_trim_number(float(lo)), unit, _trim_number(float(hi)), unit]
	if lo != null:
		return "min %s%s" % [_trim_number(float(lo)), unit]
	if hi != null:
		return "max %s%s" % [_trim_number(float(hi)), unit]
	return ""


static func _trim_number(x: float) -> String:
	return ("%.3f" % x).rstrip("0").rstrip(".")


static func parse_limit_bound(type: String, text: String) -> Dictionary:
	## Pure - one typed bound of a limit: {"ok", "value" (null = empty = no bound), "error"}. A number, or empty for no bound on that side; an angle within +-180.
	var trimmed := text.strip_edges()
	if trimmed == "":
		return {"ok": true, "value": null, "error": ""}
	if not trimmed.is_valid_float():
		return {"ok": false, "value": null, "error": "\"%s\" is not a number" % trimmed}
	var v := trimmed.to_float()
	if type == "limit_angle" and absf(v) > 180.0:
		return {"ok": false, "value": null, "error": "Angles run from -180 to 180 degrees"}
	return {"ok": true, "value": v, "error": ""}


static func limit_range_error(lo, hi) -> String:
	## Pure - why the range (either bound may be null) is not one the backend accepts, or "".
	if lo == null and hi == null:
		return "Type a minimum, a maximum, or both."
	if lo != null and hi != null and float(lo) > float(hi):
		return "The minimum is above the maximum."
	return ""


static func coupler_value_text(type: String, value) -> String:
	## Pure - a coupler's value as the lists show it: gear "1 : 2" (A turns for one of B), rack and pinion "62.832 mm per turn", screw "lead 2 mm";
	## "" for another type or no value.
	if value == null or float(value) <= 0.0 or not type in COUPLER_TYPES:
		return ""
	var v := float(value)
	var trim := func(x: float) -> String: return ("%.3f" % x).rstrip("0").rstrip(".")
	match type:
		"gear":
			return "1 : %s" % trim.call(1.0 / v)
		"rack_pinion":
			return "%s mm per turn" % trim.call(v)
	return "lead %s mm" % trim.call(v)


static func value_prompt(type: String) -> String:
	## Pure - what the value of `type` is called (the keyboard's title and the tablet's label).
	match type:
		"gear":
			return "Ratio (B turns per A turn; empty = Auto from the teeth)"
		"rack_pinion":
			return "Travel per turn (mm of rack per pinion turn; empty = Auto from the teeth)"
		"screw":
			return "Lead (mm per turn)"
		"angle":
			return "Angle (degrees)"
	return "Distance (mm)"


static func coupler_rejection(type: String, slot: int, kind: String) -> String:
	## Pure - why an entity of backend `kind` (TopologyPick.axis_kind) cannot be pick number `slot` (0 / 1) of a `type` coupler, or "". An unknown
	## kind ("") passes: the backend has the last word.
	if kind == "":
		return ""
	if type == "rack_pinion" and slot == 1:
		return "" if kind == "line" else "The rack side is a straight edge along the rack: pick one of its straight edges."
	if kind in ["cylinder", "circle", "line"]:
		return ""
	return "%s needs an axis: pick a round face, a circular edge or a straight edge." % type_label(type)


static func secondary_flip_label(type: String) -> String:
	## Pure — what the secondary flag means for a mate of `type`.
	match type:
		"gear", "rack_pinion":
			return "Reverse"
		"screw":
			return "Left-hand"
		"distance":
			return "Flip side"
		"concentric":
			return "Flip spin"
		"angle":
			return "Supplement"
	return "Flip"


static func parse_value(type: String, text: String, allow_auto := true) -> Dictionary:
	## Pure — a typed mate value: {"ok", "value", "error"}. Not a number is refused, and so is a negative DISTANCE (the side of a distance
	## is the Flip side control; the backend refuses a negative one, which used to leave the ghost blank with no word why). An angle may be negative.
	## A coupler's value is above zero; empty (value 0) means Auto for a gear and a rack and pinion when `allow_auto` (a new mate; an edit has no Auto).
	var trimmed := text.strip_edges()
	if type in COUPLER_TYPES:
		if trimmed == "" and allow_auto and type != "screw":
			return {"ok": true, "value": 0.0, "error": ""}
		if not trimmed.is_valid_float() or trimmed.to_float() <= 0.0:
			return {"ok": false, "value": 0.0, "error": "A %s value must be a number above zero%s" % [type_label(type).to_lower(), "" if type == "screw" or not allow_auto else " (or empty for Auto)"]}
		return {"ok": true, "value": trimmed.to_float(), "error": ""}
	if not trimmed.is_valid_float():
		return {"ok": false, "value": 0.0, "error": "\"%s\" is not a number" % trimmed}
	var value := trimmed.to_float()
	if type == "distance" and value < 0.0:
		return {"ok": false, "value": 0.0, "error": "A distance can't be negative - use Flip side"}
	return {"ok": true, "value": value, "error": ""}


static func alignment_title(type: String) -> String:
	## Pure — what the `alignment` control is called: the direction a lid swings about its hinge for an ANGLE, else the orientation.
	return "Swing" if type == "angle" else "Orientation"


static func alignment_label(type: String, alignment: String) -> String:
	## Pure — the value of the `alignment` control for a mate of `type`: "+" / "-" for an ANGLE's swing, Aligned / Anti-aligned otherwise.
	if type == "angle":
		return "+" if alignment == "aligned" else "-"
	return "Aligned" if alignment == "aligned" else "Anti-aligned"


static func effective_alignment(controls: Array, chosen: String, resolved: Dictionary) -> String:
	## Pure — the orientation the ghost shows: "" when the geometry has no alignment control.
	if not controls.has("alignment"):
		return ""
	return chosen if chosen != "" else str(resolved.get("alignment", "") if resolved.get("alignment") != null else "")


static func effective_secondary_flip(controls: Array, chosen: int, resolved: Dictionary) -> int:
	## Pure — the secondary flag the ghost shows (0 / 1), or -1 when the geometry has no such control.
	if not controls.has("secondary_flip"):
		return -1
	if chosen >= 0:
		return chosen
	return 1 if resolved.get("secondary_flip") == true else 0


static func alternative_index(alternatives: Array, alignment: String, flip: int) -> int:
	## Pure — where the placement being shown sits among `alternatives` (-1 if it matches none).
	for i in alternatives.size():
		var alt = alternatives[i]
		if not alt is Dictionary:
			continue
		var alt_alignment := str(alt.get("alignment", "")) if alt.get("alignment") != null else ""
		var alt_flip := -1 if alt.get("secondary_flip") == null else (1 if alt.get("secondary_flip") == true else 0)
		if alt_alignment == alignment and alt_flip == flip:
			return i
	return -1


static func next_alternative(alternatives: Array, alignment: String, flip: int) -> Dictionary:
	## Pure — "Next solution": the alternative after the one being shown (wrapping), the nearest one when none matches, {} when
	## there are fewer than two to step through.
	if alternatives.size() < 2:
		return {}
	var current := alternative_index(alternatives, alignment, flip)
	var next = alternatives[0 if current < 0 else (current + 1) % alternatives.size()]
	return next if next is Dictionary else {}


func shown_alignment() -> String:
	return effective_alignment(branch_controls, mate_alignment, branch_resolved)


func shown_secondary_flip() -> int:
	return effective_secondary_flip(branch_controls, mate_secondary_flip, branch_resolved)


func toggle_alignment() -> void:
	var shown := shown_alignment()
	if shown != "":
		mate_alignment = "anti_aligned" if shown == "aligned" else "aligned"


func flip_is_on() -> bool:
	## What the secondary-flip control shows as "on": the raw flag, except for a coupler, where it is "differs from the sense the backend chose by default"
	## (the raw flag depends on which way each axis happens to point, so it means nothing on its own).
	var shown := shown_secondary_flip()
	if is_coupler() and _flip_base >= 0:
		return shown >= 0 and shown != _flip_base
	return shown == 1


func toggle_secondary_flip() -> void:
	var shown := shown_secondary_flip()
	if shown >= 0:
		mate_secondary_flip = 0 if shown == 1 else 1


func flip_mate() -> void:
	## The wheel's single "Flip": turns the ghost round - the orientation if the geometry has one, else the side / spin / supplement.
	if branch_controls.has("alignment"):
		toggle_alignment()
	elif branch_controls.has("secondary_flip"):
		toggle_secondary_flip()


func next_solution() -> bool:
	## Steps to the next converging placement of this mate (`branch_alternatives`), naming its branch explicitly. False if there is none.
	var next := next_alternative(branch_alternatives, shown_alignment(), shown_secondary_flip())
	if next.is_empty():
		return false
	_alignment_choice = str(next.get("alignment", "")) if next.get("alignment") != null else ""
	_flip_choice = -1 if next.get("secondary_flip") == null else (1 if next.get("secondary_flip") == true else 0)
	request_preview() # one preview for both fields
	return true


func branch_text() -> String:
	## One line for the tablet: the orientation / flip as shown, "(auto)" while not picked, and where Next solution is.
	var parts: Array[String] = []
	var alignment := shown_alignment()
	if alignment != "":
		parts.append("%s%s" % [alignment_label(mate_type, alignment), " (auto)" if mate_alignment == "" else ""])
	var flip := shown_secondary_flip()
	if flip >= 0:
		parts.append("%s: %s%s" % [secondary_flip_label(mate_type), "on" if flip_is_on() else "off", " (auto)" if mate_secondary_flip < 0 and not is_coupler() else ""])
	if branch_alternatives.size() > 1:
		var index := alternative_index(branch_alternatives, alignment, flip)
		parts.append("solution %s of %d" % [str(index + 1) if index >= 0 else "-", branch_alternatives.size()])
	return " · ".join(parts)


func _run_preview(seq: int) -> void:
	var owner_part_id: String = _picks[0]["owner_part_id"]
	var driven_id: String = _driven_for_picks()
	var result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/preview-mate-solve?movement=%s" % [owner_part_id, driven_id, movement_param()], build_create_payload())
	if seq != _preview_seq or _picks.size() != pick_target():
		return # a newer setting (or Clear) has replaced this one
	var json = result.get("json")
	var members: Array = preview_members(json, driven_id) if result["ok"] and json is Dictionary else []
	_branch_changes = []
	_branch_notice = ""
	branch_controls = []
	branch_resolved = {}
	branch_alternatives = []
	if result["ok"] and json is Dictionary:
		branch_controls = json.get("controls", []) if json.get("controls") is Array else []
		branch_resolved = json.get("resolved", {}) if json.get("resolved") is Dictionary else {}
		branch_alternatives = json.get("alternatives", []) if json.get("alternatives") is Array else []
		preview_limit_value = float(json["limit_value"]) if is_limit() and json.get("limit_value") != null else null
		if is_coupler():
			preview_coupler_value = float(json["coupler_value"]) if json.get("coupler_value") != null else -1.0
			if _flip_choice < 0 and branch_resolved.get("secondary_flip") != null:
				_flip_base = 1 if branch_resolved["secondary_flip"] == true else 0 # the default sense: Reverse is measured from it
		var found = json.get("branch_changes", [])
		_branch_changes = found if found is Array else []
		_branch_notice = branch_notice(_branch_changes, json.get("blocked_by", []) if json.get("blocked_by") is Array else [], json.get("conflicting", []) if json.get("conflicting") is Array else [], mates)
	_clear_ghost()
	if is_coupler() or is_limit():
		members = [] # a coupler / limit places nothing: no ghost (the preview only brings the default value and sense)
	for member in members:
		var part := _find_loaded_part(owner_part_id, str(member["occurrence_id"]))
		if part != null:
			_show_ghost(part, json_to_pose(member["transform"]))
	# "No ghost to show yet" (nothing added above): a value still to be typed, geometry this type can't use, or a grounded part.
	picks_changed.emit()


func _show_ghost(part: Node3D, pose: Transform3D) -> void:
	if part.get_parent() == null:
		return
	var ghost := Node3D.new()
	ghost.name = "MateGhost"
	var material := StandardMaterial3D.new()
	material.albedo_color = GHOST_COLOUR
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_ghost_meshes(part, Transform3D.IDENTITY, ghost, material)
	part.get_parent().add_child(ghost)
	ghost.transform = pose # same frame as the part itself (see _apply_solved_transform)
	_ghosts.append(ghost)


func _add_ghost_meshes(node: Node3D, xf: Transform3D, ghost: Node3D, material: Material) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var copy := MeshInstance3D.new()
		copy.mesh = (node as MeshInstance3D).mesh
		copy.material_override = material
		copy.transform = xf
		copy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ghost.add_child(copy)
	for child in node.get_children():
		if child is Node3D and not (child is CollisionObject3D):
			_add_ghost_meshes(child, xf * (child as Node3D).transform, ghost, material)


func _clear_ghost() -> void:
	for ghost in _ghosts:
		if is_instance_valid(ghost):
			ghost.queue_free()
	_ghosts.clear()


func can_create() -> bool:
	return _picks.size() == pick_target() and _width_error == "" and not _busy and not (mate_type == "screw" and mate_value <= 0.0) \
		and not (is_limit() and limit_range_error(limit_min, limit_max) != "")


func build_create_payload(with_branch_changes := false) -> Dictionary:
	## Pure — the exact POST /parts/{owner_part_id}/mates body MateCreate
	## expects (DIDSA-CAD's app.document.schemas.MateCreate). `with_branch_changes` adds the earlier mates the preview showed on their
	## other branch (what Create confirms); the preview request itself never carries them.
	var references := []
	if is_symmetric():
		references = symmetric_references(_picks)
	elif is_width():
		references = width_references(_picks)
	else:
		for p in _picks:
			references.append({"occurrence_id": p["occurrence_id"], "subshape_ref": p["subshape_ref"]})
	var payload := {
		"type": width_wire_type(width_offset) if is_width() else ("coincident" if is_symmetric() else mate_type), "references": references,
		"allow_rotation": mate_allow_rotation,
	}
	# The branch is named only when the user picked it; left out, the backend resolves it (Closest) and the preview says which.
	if mate_alignment != "":
		payload["alignment"] = mate_alignment
	if mate_secondary_flip >= 0:
		payload["secondary_flip"] = mate_secondary_flip == 1
	if is_width():
		if width_wire_type(width_offset) == "distance":
			payload["value"] = width_offset
	elif is_symmetric():
		pass # a plain coincident mate: no value
	elif mate_type in ["distance", "angle"]:
		payload["value"] = mate_value
	elif is_coupler() and mate_value > 0.0:
		payload["value"] = mate_value # left out for Auto (gear, rack and pinion): the backend reads the teeth
	elif is_limit():
		if limit_min != null:
			payload["limit_min"] = float(limit_min)
		if limit_max != null:
			payload["limit_max"] = float(limit_max)
	if with_branch_changes and not _branch_changes.is_empty():
		payload["branch_changes"] = confirmed_changes(_branch_changes)
	return payload


static func width_wire_type(offset: float) -> String:
	## Pure - a centred Width is a coincident mate; with an offset from the centre it is a distance.
	return "distance" if offset > 0.0 else "coincident"


static func symmetric_references(picks: Array) -> Array:
	## Pure - the two references of three picked faces: [the mid-plane of faces 1 and 2, the mirror plane's face as an ordinary reference].
	var pair: Dictionary = width_references([picks[0], picks[1], picks[1], picks[1]])[0]
	return [pair, {"occurrence_id": picks[2]["occurrence_id"], "subshape_ref": picks[2]["subshape_ref"]}]


static func width_references(picks: Array) -> Array:
	## Pure - the two mid-plane references of four picked faces: the gap first, the part to centre second. Each is {occurrence_id,
	## midplane: {a, b, b_occurrence_id?}}, `a` / `b` plane refs naming a face; `b_occurrence_id` only when the second face is on another part.
	var out := []
	for pair in [[0, 1], [2, 3]]:
		var a: Dictionary = picks[pair[0]]
		var b: Dictionary = picks[pair[1]]
		var midplane := {"a": {"face_ref": a["subshape_ref"]}, "b": {"face_ref": b["subshape_ref"]}}
		if b["occurrence_id"] != a["occurrence_id"]:
			midplane["b_occurrence_id"] = b["occurrence_id"]
		out.append({"occurrence_id": a["occurrence_id"], "midplane": midplane})
	return out


func _driven_for_picks() -> String:
	## The occurrence a solve moves: the second pick by convention; for a Width mate the part(s) to centre before the gap's, skipping grounded ones
	## (the backend's own order).
	if not is_multi():
		return _choose_driven(_picks[0]["occurrence_id"], _picks[1]["occurrence_id"])
	var order := [0, 1, 2] if is_symmetric() else [2, 3, 0, 1]
	for i in order:
		var occ: String = _picks[i]["occurrence_id"]
		if not is_copy_id(occ) and not bool(occurrences.get(occ, {}).get("fixed", false)):
			return occ
	return _picks[0]["occurrence_id"] if is_symmetric() else _picks[2]["occurrence_id"]


func create_mate() -> Dictionary:
	## Returns {"ok":, "error":}. By convention the 2nd pick is the driven
	## occurrence (_choose_driven). Unless `relaxed`, creating is ATOMIC: the backend runs the same solve
	## the ghost showed and stores the mate together with every moved part's pose only if it converges
	## (`POST .../mates?solve=...`), so a refused mate is never left behind. The driven part's current pose
	## is saved first - the solver starts from the stored pose, so without that it would solve from
	## wherever the part used to be. Relaxed, or with the driven part grounded, only the mate is stored.
	if not can_create():
		return {"ok": false, "error": ("Pick the three faces first." if is_symmetric() else "Pick the four faces first.") if is_multi() else "Pick two entities first."}
	var owner_part_id: String = _picks[0]["owner_part_id"]
	var driven_occurrence_id: String = _driven_for_picks()
	var driven_fixed := bool(occurrence_state(owner_part_id).get("occurrences", {}).get(driven_occurrence_id, {}).get("fixed", false))
	var atomic := not relaxed and not driven_fixed
	_busy = true
	var part := _find_loaded_part(owner_part_id, driven_occurrence_id)
	if atomic and part != null:
		var patched := await _api_request(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [owner_part_id, driven_occurrence_id], {"transform": pose_to_json(_local_pose(part))})
		if not patched["ok"]:
			_busy = false
			return {"ok": false, "error": _friendly_error(patched)}
	var path := "/parts/%s/mates" % owner_part_id
	if atomic:
		path += "?" + atomic_query(movement_param(), driven_occurrence_id)
	var result := await _api_request(HTTPClient.METHOD_POST, path, build_create_payload(atomic))
	_busy = false
	if not result["ok"]:
		return {"ok": false, "error": _friendly_error(result) if atomic else result["error"]}
	clear_picks()
	document_changed.emit()
	if relaxed:
		note_sandbox_mate(owner_part_id, driven_occurrence_id)
	if atomic:
		await _adopt_backend_poses(owner_part_id, "mate %s" % (label_or(part, str(part.name)) if part != null else driven_occurrence_id))
	await refresh_mates(owner_part_id)
	if not relaxed and driven_fixed:
		_report("Mate created, but couldn't be applied: that part is grounded (fixed) — Float it first, or mate the other part to it")
	return {"ok": true, "error": ""}


static func atomic_query(movement: String, occurrence_id: String) -> String:
	## Pure — the `solve` / `occurrence_id` query of an atomic create or edit (see create_mate).
	return "solve=%s&occurrence_id=%s" % [movement, occurrence_id.uri_encode()]


func refresh_mates(owner_part_id: String) -> void:
	if _other_states.has(owner_part_id):
		# A room's Part (a mate was just made or deleted there): re-read ITS state, and leave the active root alone. Making it the active one would
		# stop the world's own parts being managed (saved, steered).
		await load_owner_state(owner_part_id)
		mates_changed.emit()
		return
	_current_owner_part_id = owner_part_id
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/mates" % owner_part_id, null)
	if result["ok"]:
		mates = result["json"]
		_rebuild_mated_ids()
		if highlight_id != "" and not mates.any(func(m) -> bool: return str(m.get("id", "")) == highlight_id):
			clear_highlight() # the selected mate was deleted
	mates_changed.emit()


func delete_mate(owner_part_id: String, mate_id: String) -> bool:
	_busy = true
	var result := await _api_request(HTTPClient.METHOD_DELETE, "/parts/%s/mates/%s" % [owner_part_id, mate_id], null)
	_busy = false
	if result["ok"]:
		document_changed.emit()
	await refresh_mates(owner_part_id)
	return result["ok"]


func update_mate(owner_part_id: String, mate_id: String, fields: Dictionary) -> Dictionary:
	## Edits a mate after it was made: any of value / flipped / allow_rotation / suppressed (what the backend's
	## PATCH accepts; the type and the two faces are never edited, make a new mate for those). Unless mates
	## are relaxed, the edit is ATOMIC like Create's: the driven part is solved with the edit and both are stored
	## together (one undo entry), or - if the edited mate cannot be met - the mate keeps its old values.
	if fields.is_empty():
		return {"ok": true, "error": ""}
	var refs: Array = []
	for mate in mates:
		if str(mate.get("id", "")) == mate_id:
			refs = mate.get("references", [])
	var driven_id := ""
	if refs.size() == 2:
		driven_id = _choose_driven(str(refs[0].get("occurrence_id", "")), str(refs[1].get("occurrence_id", "")))
	var driven_fixed := driven_id != "" and bool(occurrence_state(owner_part_id).get("occurrences", {}).get(driven_id, {}).get("fixed", false))
	var atomic := not relaxed and driven_id != "" and not driven_fixed
	_busy = true
	var part := _find_loaded_part(owner_part_id, driven_id) if atomic else null
	if part != null:
		var patched := await _api_request(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [owner_part_id, driven_id], {"transform": pose_to_json(_local_pose(part))})
		if not patched["ok"]:
			_busy = false
			return {"ok": false, "error": _friendly_error(patched)}
	var path := "/parts/%s/mates/%s" % [owner_part_id, mate_id]
	if atomic:
		path += "?" + atomic_query(movement_param(), driven_id)
	# An edit refused because earlier mates must change branch is confirmed by repeating it (there is no live preview for an edit
	# here): the refusal said what moves, and the same edit again sends exactly that.
	var edit_key := "%s|%s" % [mate_id, JSON.stringify(fields)]
	var body := fields
	if atomic and _pending_edit.has(edit_key):
		body = fields.duplicate()
		body["branch_changes"] = confirmed_changes(_pending_edit[edit_key])
	var result := await _api_request(HTTPClient.METHOD_PATCH, path, body)
	_busy = false
	_pending_edit.erase(edit_key)
	if not result["ok"]:
		var detail = result["json"].get("detail") if result.get("json") is Dictionary else null
		if detail is Dictionary and str(detail.get("type", "")) == "branch_change_needed" and detail.get("branch_changes") is Array:
			_pending_edit[edit_key] = detail["branch_changes"]
		return {"ok": false, "error": _friendly_error(result)}
	document_changed.emit()
	if relaxed:
		note_sandbox_mate(owner_part_id, driven_id)
	if atomic:
		await _adopt_backend_poses(owner_part_id, "edit mate %s" % (label_or(part, str(part.name)) if part != null else driven_id))
	await refresh_mates(owner_part_id)
	if not relaxed and driven_fixed:
		return {"ok": false, "error": "Mate changed, but couldn't be applied: that part is grounded (fixed) — Float it first, or mate the other part to it"}
	return {"ok": true, "error": ""}


func solve_occurrence(owner_part_id: String, occurrence_id: String) -> Dictionary:
	## Solves occurrence_id's Mates server-side and applies the result to
	## whichever loaded Godot part carries that identity. The part's CURRENT
	## pose is saved first (the flat app's "PATCH the dragged pose, then solve"
	## order): the solver's initial guess is the pose stored on the backend, so
	## without this it solved from wherever the part used to be, not where you
	## left it. A grounded (fixed) occurrence can't be the driven side — say so
	## rather than letting the backend's 422 vanish.
	if occurrence_id.contains("#") or occurrence_id.contains("/"):
		# A pattern copy's `#` would start a URL fragment (the request would hit the wrong occurrence), and a path is no occurrence id.
		push_error("MatesTool.solve_occurrence: not an occurrence id: %s" % occurrence_id)
		return {"ok": false, "error": "can't solve %s: not a top-level occurrence" % occurrence_id}
	if bool(occurrence_state(owner_part_id).get("occurrences", {}).get(occurrence_id, {}).get("fixed", false)):
		return {"ok": false, "error": "that part is grounded (fixed) — Float it first, or mate the other part to it"}
	_busy = true
	var part := _find_loaded_part(owner_part_id, occurrence_id)
	if part != null:
		var patched := await _api_request(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [owner_part_id, occurrence_id], {"transform": pose_to_json(_local_pose(part))})
		if not patched["ok"]:
			_busy = false
			return {"ok": false, "error": _friendly_error(patched)}
	var result := await _api_request(
		HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/solve" % [owner_part_id, occurrence_id], null
	)
	_busy = false
	if not result["ok"]:
		await refresh_mates(owner_part_id)
		return {"ok": false, "error": _friendly_error(result)}
	# /solve now moves the WHOLE mate-graph component (followers included) and stores it: adopt every
	# moved occurrence's stored pose, one undo entry for the lot.
	var adopted := await _adopt_backend_poses(owner_part_id, "solve %s" % (label_or(part, str(part.name)) if part != null else occurrence_id))
	if not adopted:
		var transform_json: Dictionary = result["json"].get("transform", {})
		if part != null and not transform_json.is_empty():
			_apply_solved_transform(part, transform_json)
	await refresh_mates(owner_part_id)
	return {"ok": true, "error": ""}


func enforce_all(owner_part_id: String) -> Dictionary:
	## Re-applies every mate in the loaded assembly, at every level: each sub-assembly's own Mates first, deepest first (a sub-assembly is
	## settled before the assembly it sits in is solved against it), then this Part's own. Every non-grounded occurrence a Mate moves is solved;
	## a reference into a sub-assembly (`outer/inner`) solves `outer`, the top-level occurrence it moves. Afterwards every part nested in a
	## sub-assembly is put back where the stored tree places it (a nested part moved by hand with mates relaxed moved on screen only).
	## Returns {ok, solved, problems} (ok = every mate was satisfied) and emits enforce_finished with the same.
	## In the sandbox the parts go home first: solving from a scattered layout is what the sandbox exists to avoid.
	if relaxed:
		await return_parts()
	await refresh_state(owner_part_id)
	var solved := 0
	var problems: Array[String] = []
	for pid in _nested_order:
		var state: Dictionary = _nested_states.get(pid, {})
		for occ_id in state.get("mated", {}):
			if bool(state.get("occurrences", {}).get(occ_id, {}).get("fixed", false)):
				continue
			_busy = true
			var result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/solve" % [pid, occ_id], null)
			_busy = false
			if result["ok"]:
				solved += 1
			else:
				problems.append("in sub-assembly %s: %s" % [await _part_label(pid), _friendly_error(result)])
	for occ_id in _mated_ids:
		if bool(occurrences.get(occ_id, {}).get("fixed", false)):
			continue # grounded: it's the anchor the others are solved against
		var result: Dictionary = await solve_occurrence(owner_part_id, occ_id)
		if result["ok"]:
			solved += 1
		else:
			problems.append(result["error"])
	await _adopt_nested_poses(owner_part_id)
	var copy_changes := await _copy_pose_changes(owner_part_id) # sub-assembly solves above moved parts whose copies stand elsewhere in the scope
	if not copy_changes.is_empty():
		_push_group_move("enforce mates (copies)", copy_changes)
	if problems.is_empty():
		_report("Enforced mates on %d part(s)." % solved if solved > 0 else "Nothing to enforce: every mated part is grounded, or there are no mates yet.")
	else:
		_report("Couldn't satisfy every mate: %s" % "; ".join(problems))
	var outcome := {"ok": problems.is_empty(), "solved": solved, "problems": problems}
	enforce_finished.emit(outcome)
	return outcome


func _part_label(part_id: String) -> String:
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s" % part_id, null)
	if result["ok"] and result["json"] is Dictionary and str(result["json"].get("name", "")) != "":
		return str(result["json"]["name"])
	return part_id


func _adopt_nested_poses(root_part_id: String) -> int:
	## Puts every world part nested in a sub-assembly (group_index.gd's group_path, two or more levels) where the stored occurrence tree places
	## it: the chain of its occurrences' transforms, root first (the glb flattens each instance onto its own node, so that chain IS its node's
	## transform). Covers what a sub-assembly solve moved and what a hand move put out of place on screen. No undo entry: a nested move was
	## never saved, so there is nothing to go back to. Returns how many nodes moved.
	var rows_by_part := {}
	var moved := 0
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not is_instance_valid(node) or node.has_meta("room_id") or bool(node.get_meta("held", false)):
			continue
		if str(node.get_meta("group_root", "")) != root_part_id:
			continue
		var path: Array = node.get_meta("group_path", [])
		var parts: Array = node.get_meta("group_parts", [])
		if path.size() < 2 or parts.size() != path.size():
			continue
		var pose := Transform3D.IDENTITY
		var ok := true
		for i in path.size():
			var pid: String = root_part_id if i == 0 else str(parts[i - 1])
			if not rows_by_part.has(pid):
				var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % pid, null)
				rows_by_part[pid] = result["json"] if result["ok"] and result["json"] is Array else []
			var row: Variant = null
			for r in rows_by_part[pid]:
				if str(r.get("id", "")) == str(path[i]):
					row = r
					break
			if row == null or not (row.get("transform") is Dictionary):
				ok = false
				break
			pose = pose * json_to_pose(row["transform"])
		if not ok or not is_instance_valid(node) or _local_pose(node).is_equal_approx(pose):
			continue
		node.transform = pose
		moved += 1
	return moved


func set_relaxed(on: bool) -> void:
	## Relax all mates is a SANDBOX. On: every placed part's pose is remembered, mates stop steering, and nothing that moves is saved, so parts
	## can be pulled about, grounded ones too, to look and to clear the way. Off: every remembered part glides back to exactly where it was (no
	## solve: a solve from a scattered layout can land on another branch or fail), then the mates made or edited meanwhile are solved from there.
	## Parts that appeared meanwhile (a reload, a room opened, a file added) were never remembered and stay put; deleted ones are just gone.
	if on == relaxed:
		return
	if on:
		_enter_sandbox({})
	else:
		await return_parts()


func is_sandboxed(part: Node3D) -> bool:
	## This part's moves are the sandbox's: on screen only, back home when Relax goes off.
	return relaxed and is_instance_valid(part) and _home.has(part)


func _enter_sandbox(home: Dictionary, arrangement: Dictionary = {}) -> void:
	relaxed = true
	_home.clear()
	if home.is_empty():
		for node in get_tree().get_nodes_in_group("grabbable_parts"):
			if is_instance_valid(node):
				_home[node] = (node as Node3D).transform
	else:
		for node in home:
			if is_instance_valid(node):
				_home[node] = home[node]
	for node in arrangement:
		if is_instance_valid(node):
			(node as Node3D).transform = arrangement[node]
	_report("Mates relaxed: move anything, nothing is saved. Return parts puts everything back.")
	sandbox_changed.emit(true)


func sandbox_home_of(node: Node) -> Variant:
	## Where a remembered part goes back to (its real pose), or null when it isn't remembered.
	return _home.get(node) if relaxed else null


func arrange_in_sandbox(home: Dictionary, arrangement: Dictionary) -> void:
	## Relaxes (or stays relaxed) with `home` as the real poses and puts the parts where `arrangement` says: a shown scene
	## (scenes_tool.gd). Return parts takes them home as usual.
	_enter_sandbox(home, arrangement)


func _rebase_sandbox() -> void:
	## A model (re)loaded while relaxed: its parts show their stored poses, which are their homes (nothing moved in the sandbox was saved).
	var kept := {}
	for node in _home:
		if is_instance_valid(node):
			kept[node] = _home[node]
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if is_instance_valid(node) and not kept.has(node):
			kept[node] = (node as Node3D).transform
	_home = kept


func sandbox_snapshot() -> Dictionary:
	## The remembered poses keyed the way a saved scene would name them: "<root>|<occurrence path>" (group_index.gd's path from the scope's
	## root, the same at every level) -> pose json in the frame its node sits in. Parts with no path (root content, pattern copies) are keyed
	## "<owner>|<occurrence>#<n>". Not saved anywhere yet: scenes are scoped separately.
	var out := {}
	for node in _home:
		if not is_instance_valid(node):
			continue
		var path: Array = node.get_meta("group_path", [])
		var key := ""
		if not path.is_empty():
			key = "%s|%s" % [str(node.get_meta("group_root", "")), "/".join(PackedStringArray(path.map(func(p) -> String: return str(p))))]
		else:
			var n := 0
			key = "%s|%s#%d" % [owner_of(node), _occ_id(node), n]
			while out.has(key):
				n += 1
				key = "%s|%s#%d" % [owner_of(node), _occ_id(node), n]
		if node.has_meta("room_id"):
			key = "room%d:%s" % [int(node.get_meta("room_id")), key]
		out[key] = pose_to_json(_home[node])
	return out


func return_parts(record_undo: bool = true) -> Dictionary:
	## Ends the sandbox: every remembered part glides home, ONE undo step (undoing it puts the arrangement back and relaxes again), then the
	## mates made or edited while relaxed are solved from the home poses. Returns {ok, moved, problems}. A coroutine.
	if not relaxed:
		return {"ok": true, "moved": 0, "problems": []}
	var homes := {}
	var arrangement := {}
	for node in _home:
		if is_instance_valid(node):
			homes[node] = _home[node]
			if not (node as Node3D).transform.is_equal_approx(_home[node]):
				arrangement[node] = (node as Node3D).transform
	relaxed = false
	_home.clear()
	_clear_cues()
	sandbox_changed.emit(false)
	if record_undo and command_stack != null and not arrangement.is_empty():
		command_stack.push("return parts",
			func() -> void: _enter_sandbox(homes, arrangement),
			func() -> void: return_parts(false))
	await _glide_home(arrangement.keys(), homes)
	var problems: Array[String] = []
	var solve := _sandbox_solve.duplicate()
	_sandbox_solve.clear()
	for item in solve:
		var result: Dictionary = await solve_occurrence(str(item["owner"]), str(item["occ"]))
		if not result["ok"]:
			problems.append(result["error"])
	if not solve.is_empty():
		# solve_occurrence adopted each solve's poses (copies included); a last pass settles any copy a later solve moved again
		var owners := {}
		for item in solve:
			owners[str(item["owner"])] = true
		var copy_changes: Array = []
		for owner in owners:
			copy_changes.append_array(await _copy_pose_changes(str(owner)))
		_push_group_move("return parts (copies)", copy_changes)
	if problems.is_empty():
		_report("Parts returned (%d moved back)." % arrangement.size() if not arrangement.is_empty() else "Mates enforced: nothing had moved.")
	else:
		_report("Parts returned, but a mate made while relaxed couldn't be met: %s" % "; ".join(problems))
	return {"ok": problems.is_empty(), "moved": arrangement.size(), "problems": problems}


func _glide_home(nodes: Array, homes: Dictionary) -> void:
	var live := nodes.filter(func(n) -> bool: return is_instance_valid(n))
	if live.is_empty():
		return
	if return_glide_s <= 0.0 or not is_inside_tree():
		for node in live:
			(node as Node3D).transform = homes[node]
		return
	var tween := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	for node in live:
		tween.tween_property(node, "transform", homes[node], return_glide_s)
	await tween.finished
	for node in live:
		if is_instance_valid(node):
			(node as Node3D).transform = homes[node] # exactly home, whatever the interpolation left


func note_sandbox_mate(owner_part_id: String, occurrence_id: String) -> void:
	## A mate was made or edited while relaxed (stored, not solved): its driven part is solved once the parts are home.
	if not relaxed or occurrence_id == "":
		return
	for item in _sandbox_solve:
		if item["owner"] == owner_part_id and item["occ"] == occurrence_id:
			return
	_sandbox_solve.append({"owner": owner_part_id, "occ": occurrence_id})


# --- the sandbox's optional cues: a ghost at home, a line to it ---

func _process(delta: float) -> void:
	if not relaxed or not (sandbox_ghosts or sandbox_lines):
		if not _cues.is_empty():
			_clear_cues()
		return
	_cue_tick += delta
	if _cue_tick < 0.1:
		return
	_cue_tick = 0.0
	update_cues()


func update_cues() -> void:
	## A ghost (and / or a line) for every remembered part that is away from home; none for one that is home. Public for tests.
	for node in _cues.keys():
		if not is_instance_valid(node) or not _home.has(node) or (node as Node3D).transform.is_equal_approx(_home[node]):
			_free_cue(node)
	if not relaxed:
		return
	for node in _home:
		if not is_instance_valid(node) or (node as Node3D).transform.is_equal_approx(_home[node]):
			continue
		var cue: Dictionary = _cues.get(node, {})
		var parent := (node as Node3D).get_parent() as Node3D
		var home_global: Transform3D = (parent.global_transform if parent != null else Transform3D.IDENTITY) * (_home[node] as Transform3D)
		if sandbox_ghosts and node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			if not cue.has("ghost"):
				var ghost := MeshInstance3D.new()
				ghost.name = "HomeGhost"
				ghost.mesh = (node as MeshInstance3D).mesh
				ghost.material_override = _ghost_material()
				ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(ghost)
				cue["ghost"] = ghost
			(cue["ghost"] as Node3D).global_transform = home_global
		elif cue.has("ghost"):
			(cue["ghost"] as Node).queue_free()
			cue.erase("ghost")
		if sandbox_lines:
			if not cue.has("line"):
				var line := MeshInstance3D.new()
				line.name = "HomeLine"
				line.mesh = ImmediateMesh.new()
				var mat := StandardMaterial3D.new()
				mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				mat.albedo_color = Color(GHOST_COLOUR, 0.6)
				line.material_override = mat
				line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				add_child(line)
				cue["line"] = line
			var a := _centre_of(node as Node3D, (node as Node3D).global_transform)
			var b := _centre_of(node as Node3D, home_global)
			var im := (cue["line"] as MeshInstance3D).mesh as ImmediateMesh
			(cue["line"] as Node3D).global_transform = Transform3D.IDENTITY
			im.clear_surfaces()
			im.surface_begin(Mesh.PRIMITIVE_LINES)
			im.surface_add_vertex(a)
			im.surface_add_vertex(b)
			im.surface_end()
		elif cue.has("line"):
			(cue["line"] as Node).queue_free()
			cue.erase("line")
		if cue.is_empty():
			_cues.erase(node)
		else:
			_cues[node] = cue


func cue_count() -> Dictionary:
	var ghosts := 0
	var lines := 0
	for node in _cues:
		ghosts += 1 if _cues[node].has("ghost") else 0
		lines += 1 if _cues[node].has("line") else 0
	return {"ghosts": ghosts, "lines": lines}


static func _centre_of(node: Node3D, at: Transform3D) -> Vector3:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return at * (node as MeshInstance3D).mesh.get_aabb().get_center()
	return at.origin


func _ghost_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(GHOST_COLOUR, 0.22)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	return mat


func _free_cue(node) -> void:
	var cue: Dictionary = _cues.get(node, {})
	for key in cue:
		if is_instance_valid(cue[key]):
			(cue[key] as Node).queue_free()
	_cues.erase(node)


func _clear_cues() -> void:
	for node in _cues.keys():
		_free_cue(node)
	_cues.clear()


# --- state, locking, and grounding ---

func refresh_state(owner_part_id: String) -> void:
	## Re-reads this assembly's top-level occurrences (for their `fixed` flags)
	## and Mates (for which parts are mated) — the two facts is_locked()/
	## is_constrained() need. Called after every model load and by
	## enforce_all(); mate create/delete/solve refresh the mate list themselves.
	_current_owner_part_id = owner_part_id
	occurrences.clear()
	_mated_ids.clear()
	_pattern_cache.erase(owner_part_id) # a (re)load: the patterns are read again at the next drag
	if backend_url.is_empty() or api_key.is_empty() or owner_part_id.is_empty():
		mates_changed.emit()
		return
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_part_id, null)
	if result["ok"] and result["json"] is Array:
		for occ in result["json"]:
			occurrences[str(occ.get("id", ""))] = {"fixed": bool(occ.get("fixed", false))}
		await _load_labels(owner_part_id, result["json"])
	await refresh_mates(owner_part_id)
	await refresh_nested_state(owner_part_id)
	if relaxed:
		_rebase_sandbox()


func part_label(node: Node3D) -> String:
	## A short readable name for a placed part (its name on the assembly, else the Part's own name, else its file's name), or "" when there is nothing
	## useful to say (the glb's own node names, "Mesh 1", mean nothing to a person).
	if not is_instance_valid(node):
		return ""
	return str(_labels.get("%s|%s" % [owner_of(node), _occ_id(node)], ""))


func label_or(node: Node3D, fallback: String) -> String:
	var label := part_label(node)
	return label if label != "" else fallback


static func shorten_label(raw: String, max_length: int = 18) -> String:
	## Trims a name for a status line; "" for a name that says nothing (empty, "Mesh 1", "Occurrence d3c1...", an id).
	var name := raw.strip_edges()
	if name.get_extension().to_lower() in ["didsa", "didsaprt", "didsacad", "step", "stp", "stl", "obj", "glb"]:
		name = name.get_basename()
	var lower := name.to_lower()
	var generic := RegEx.new()
	generic.compile("^(mesh|node|occurrence|part|object)[ _-]?[0-9a-f]*$")
	var id_like := RegEx.new()
	id_like.compile("^[0-9a-f]{8}(-[0-9a-f]{4}){0,4}$")
	if name == "" or generic.search(lower) != null or id_like.search(lower) != null:
		return ""
	return name if name.length() <= max_length else name.substr(0, max_length - 1).strip_edges() + "…"


func _load_labels(owner_part_id: String, rows: Array) -> void:
	## Names the owner's occurrences: name_override, else the Part's name (GET /parts/{id}, once per Part), else the file's base name.
	for occ in rows:
		var key := "%s|%s" % [owner_part_id, str(occ.get("id", ""))]
		var label := shorten_label(str(occ.get("name_override", "")) if occ.get("name_override") != null else "")
		if label == "":
			var part_id := str(occ.get("resolved_part_id", "")) if occ.get("resolved_part_id") != null else ""
			if part_id != "" and not _part_names.has(part_id):
				var fetched := await _api_request(HTTPClient.METHOD_GET, "/parts/%s" % part_id, null)
				_part_names[part_id] = str(fetched["json"].get("name", "")) if fetched["ok"] and fetched["json"] is Dictionary else ""
			label = shorten_label(str(_part_names.get(part_id, "")))
		if label == "" and occ.get("external_ref") != null:
			label = shorten_label(str(occ["external_ref"]).get_file())
		_labels[key] = label


func refresh_nested_state(root_part_id: String) -> void:
	## Reads every sub-assembly below the active root: its occurrences (their `fixed` flags) and its own Mates. A part nested in one is not
	## managed (its node's transform is root-relative, so a move of it is on screen only and never saved), but while mates are enforced a mated
	## one must stay where its mates put it (is_nested_locked), and Enforce all solves these Parts' mates too, deepest first (_nested_order).
	_nested_states.clear()
	_nested_order.clear()
	if backend_url.is_empty() or api_key.is_empty() or root_part_id.is_empty():
		return
	var rows_by_part := {}
	await _walk_nested(root_part_id, [root_part_id], rows_by_part)
	for pid in _nested_order:
		var occs := {}
		for row in rows_by_part.get(pid, []):
			occs[str(row.get("id", ""))] = {"fixed": bool(row.get("fixed", false))}
		var mated := {}
		var mate_result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/mates" % pid, null)
		if mate_result["ok"] and mate_result["json"] is Array:
			mated = mated_tops((mate_result["json"] as Array).filter(func(m) -> bool: return m is Dictionary and not bool(m.get("suppressed", false))))
		_nested_states[pid] = {"occurrences": occs, "mated": mated}
	mates_changed.emit()


func _walk_nested(part_id: String, ancestors: Array, rows_by_part: Dictionary) -> void:
	## Depth-first over the occurrence tree; a Part goes into _nested_order after every Part below it (so a sub-assembly's own mates are solved
	## before the mates of the assembly it sits in). A Part already on the path (a cycle) or seen before is not walked again.
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % part_id, null)
	var rows: Array = result["json"] if result["ok"] and result["json"] is Array else []
	rows_by_part[part_id] = rows
	if ancestors.size() > MAX_NEST_DEPTH:
		return
	for row in rows:
		if bool(row.get("suppressed", false)) or row.get("resolved_part_id") == null:
			continue
		var child := str(row["resolved_part_id"])
		if child == "" or ancestors.has(child) or rows_by_part.has(child):
			continue
		await _walk_nested(child, ancestors + [child], rows_by_part)
		_nested_order.append(child)


static func mate_ref_top(occurrence_id: String) -> String:
	## The top-level occurrence a mate reference moves. A reference into a sub-assembly is a `/`-joined path (`outer/inner`); the solver moves
	## `outer` as a whole (the backend's mate_ref_tops), so that is the occurrence that is mated, and the one Enforce all solves.
	## A pattern copy's segment (`A#pattern:P:1`) folds to its source `A` (the backend's mate_ref_drivers): the copy is a fixed function of
	## A's pose, so a mate on it is a mate on A, and `#` must never reach a URL.
	return GroupIndex.base_segment(occurrence_id.get_slice("/", 0))


static func mated_tops(mate_list: Array) -> Dictionary:
	## Every top-level occurrence the Mates involve -> true (the backend's mate_tops): each reference's own occurrence and, for a Width /
	## Symmetric mid-plane whose second face is on another part (`midplane.b_occurrence_id`), that one's too. Root content ("") is left out.
	var out := {}
	for mate in mate_list:
		if not (mate is Dictionary):
			continue
		for ref in mate.get("references", []):
			if not (ref is Dictionary):
				continue
			var ids: Array = [str(ref.get("occurrence_id", ""))]
			var mid = ref.get("midplane")
			if mid is Dictionary and mid.get("b_occurrence_id") != null:
				ids.append(str(mid["b_occurrence_id"]))
			for id in ids:
				var top := mate_ref_top(id)
				if top != "":
					out[top] = true
	return out


func _rebuild_mated_ids() -> void:
	_mated_ids = mated_tops(mates)


func is_managed(part: Node3D) -> bool:
	## A placed TOP-LEVEL occurrence of the loaded root Part, with a backend to
	## sync to — the only kind of part whose pose the backend can hold (a
	## nested occurrence's node transform is flattened root-relative, not its
	## owner-relative one, and root content has no occurrence at all).
	if backend_url.is_empty() or api_key.is_empty():
		return false
	var ref := MeshIdentity.occurrence_ref_for(part)
	if ref.is_empty() or ref.get("occurrence_id", "") == "":
		return false
	var owner := str(ref.get("owner_part_id", ""))
	return owner != "" and (owner == _current_owner_part_id or _other_states.has(owner))


func _occ_id(part: Node3D) -> String:
	return str(MeshIdentity.occurrence_ref_for(part).get("occurrence_id", ""))


func owner_of(part: Node3D) -> String:
	## The Part this node's occurrence sits directly on: whose occurrence list holds it, and so the path its pose and flags are saved under. For a part in
	## the world that is the loaded root; for a part in an Assembly Room it is the room's own Part (a room's root), because there the node's local
	## transform IS that Part's stored one (the room's glb is that Part's own, so its children are its top-level occurrences).
	return str(MeshIdentity.occurrence_ref_for(part).get("owner_part_id", ""))


func occurrence_state(owner_part_id: String) -> Dictionary:
	## {"occurrences": ..., "mated": ...} for a root this tool knows (the active one, or a room's), else {}.
	if owner_part_id == "":
		return {}
	if owner_part_id == _current_owner_part_id:
		return {"occurrences": occurrences, "mated": _mated_ids}
	return _other_states.get(owner_part_id, {})


func set_owner_state(owner_part_id: String, p_occurrences: Dictionary, p_mated: Dictionary) -> void:
	## Registers another root (an Assembly Room's Part) as one whose parts are managed: moves are saved to it, its mates are enforced. The dictionaries
	## are what refresh_state() builds for the active root: occurrence id -> {"fixed": bool}, and occurrence id -> true for every one a Mate references.
	if owner_part_id == "" or owner_part_id == _current_owner_part_id:
		return
	_other_states[owner_part_id] = {"occurrences": p_occurrences, "mated": p_mated}


func load_owner_state(owner_part_id: String) -> bool:
	## Reads a room's Part's top-level occurrences (their `fixed` flags) and Mates from the backend and registers it (set_owner_state). Does NOT touch the
	## active root. False if the backend could not be read (the room then stays unmanaged: parts show but are not saved or steered).
	if backend_url.is_empty() or api_key.is_empty() or owner_part_id.is_empty() or owner_part_id == _current_owner_part_id:
		return false
	var occ_result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_part_id, null)
	if not occ_result["ok"] or not (occ_result["json"] is Array):
		return false
	var occs := {}
	for occ in occ_result["json"]:
		occs[str(occ.get("id", ""))] = {"fixed": bool(occ.get("fixed", false))}
	await _load_labels(owner_part_id, occ_result["json"])
	var mated := {}
	var mate_result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/mates" % owner_part_id, null)
	if mate_result["ok"] and mate_result["json"] is Array:
		mated = mated_tops(mate_result["json"])
	set_owner_state(owner_part_id, occs, mated)
	if _nested_states.has(owner_part_id):
		_nested_states[owner_part_id] = {"occurrences": occs, "mated": mated} # a room's Part is also a sub-assembly of the world's root: its mates there are the same
	return true


func drop_owner_state(owner_part_id: String) -> void:
	_other_states.erase(owner_part_id)
	_pattern_cache.erase(owner_part_id)


func is_fixed(part: Node3D) -> bool:
	return is_managed(part) and bool(occurrence_state(owner_of(part)).get("occurrences", {}).get(_occ_id(part), {}).get("fixed", false))


func is_mated(part: Node3D) -> bool:
	return is_managed(part) and occurrence_state(owner_of(part)).get("mated", {}).has(_occ_id(part))


func is_locked(part: Node3D) -> bool:
	## Grounded + mated + enforced: it's the anchor its mates are solved
	## against, so it can't be moved on its own.
	return not relaxed and not _mates_dirty(part) and is_fixed(part) and is_mated(part)


func is_constrained(part: Node3D) -> bool:
	## Mated, free to move, and mates are enforced: its motion is steered by a
	## live solve (constrain_drag()).
	return not relaxed and not _mates_dirty(part) and is_managed(part) and is_mated(part) and not is_fixed(part)


func is_nested_locked(part: Node3D) -> bool:
	## A part inside a sub-assembly (one this tool doesn't manage) that its sub-assembly's own Mates move, while mates are enforced: it stays
	## where they put it. Its move could only ever be on screen (never saved) and would just break those mates. The sub-assembly as a whole
	## can still be taken (the grip's wider levels); Relax all mates moves the part anyway, and an Assembly Room of that sub-assembly edits it.
	if not is_instance_valid(part) or _mates_dirty(part) or is_managed(part):
		return false
	return nested_occurrence_locked(owner_of(part), _occ_id(part))


func nested_occurrence_locked(owner_part_id: String, occurrence_id: String) -> bool:
	## The occurrence `occurrence_id` of the sub-assembly Part `owner_part_id` is moved by that Part's own Mates, and mates are enforced: neither
	## the part it places nor (for a sub-assembly inside a sub-assembly) the group it places moves on its own.
	if relaxed or occurrence_id == "":
		return false
	return _nested_states.get(owner_part_id, {}).get("mated", {}).has(occurrence_id)


func notify_nested_locked(part: Node3D) -> void:
	if Time.get_ticks_msec() - _last_locked_notice_ms < 1500:
		return
	_last_locked_notice_ms = Time.get_ticks_msec()
	_report("%s is held by mates inside its sub-assembly: take the whole sub-assembly, Relax all mates, or open it as a room to move it." % label_or(part, "This part"))


func _mates_dirty(part: Node3D) -> bool:
	## The design table flagged this part's mates as stale (its geometry was edited, so the faces they reference may be gone or
	## different): until "Enforce mates", the part moves freely instead of being steered by them, and is no anchor.
	return is_instance_valid(part) and bool(part.get_meta("mates_dirty", false))


func has_drag(part: Node3D) -> bool:
	return _drag.has(part)


func notify_locked(part: Node3D) -> void:
	if Time.get_ticks_msec() - _last_locked_notice_ms < 1500:
		return # a held button would otherwise re-announce every physics frame
	_last_locked_notice_ms = Time.get_ticks_msec()
	_report("%s is grounded by a mate — Float it (Assembly > Mates) or Relax all mates to move it." % label_or(part, "This part"))


func toggle_fixed(part: Node3D) -> void:
	## Tablet's Fix/Float: flips the selected part's grounded flag on the
	## backend (the same field the flat app's Fix/Float toggle writes).
	if part == null or not is_managed(part):
		_report("Select a placed part first (laser-select it).")
		return
	var occ := _occ_id(part)
	var owner := owner_of(part)
	var occs: Dictionary = occurrence_state(owner).get("occurrences", {})
	var now_fixed := not bool(occs.get(occ, {}).get("fixed", false))
	var result := await _api_request(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [owner, occ], {"fixed": now_fixed})
	if not result["ok"]:
		_report("Couldn't %s %s: %s" % ["ground" if now_fixed else "float", label_or(part, "the part"), _friendly_error(result)])
		return
	occs[occ] = {"fixed": now_fixed}
	document_changed.emit()
	_report("%s is now %s." % [label_or(part, "The part"), "grounded (fixed)" if now_fixed else "floating (free to move)"])


func _choose_driven(first_occ: String, second_occ: String) -> String:
	## By convention the second pick is driven, unless it's grounded (a grounded
	## occurrence can never be the driven side — the backend 422s it) and the
	## first isn't. A pattern copy is never driven either (it follows its source): the other pick is.
	if is_copy_id(second_occ) and not is_copy_id(first_occ):
		return first_occ
	if is_copy_id(first_occ) and not is_copy_id(second_occ):
		return second_occ
	if bool(occurrences.get(second_occ, {}).get("fixed", false)) and not bool(occurrences.get(first_occ, {}).get("fixed", false)):
		return first_occ
	return second_occ


func _report(text: String) -> void:
	_status = text
	picks_changed.emit()


func _friendly_error(result: Dictionary) -> String:
	var json = result.get("json")
	var detail = json.get("detail") if json is Dictionary else null
	if detail is Dictionary:
		match str(detail.get("type", "")):
			"occurrence_is_fixed":
				return "that part is grounded (fixed)"
			"mate_solve_did_not_converge":
				return "the mates can't all be satisfied from there (over-constrained or conflicting)"
			"branch_change_needed":
				var changes: Array = detail.get("branch_changes", []) if detail.get("branch_changes") is Array else []
				return "%s Do the same again to confirm." % branch_notice(changes, [], [], mates).replace(" Create applies it.", "").replace(" Create applies them.", "")
			"mate_blocked_by_user_branch":
				return branch_notice([], detail.get("blocked_by", []) if detail.get("blocked_by") is Array else [], [], mates)
			"mate_conflict":
				return branch_notice([], [], detail.get("conflicting", []) if detail.get("conflicting") is Array else [], mates)
			"unsupported_mate_geometry":
				return "this mate type needs %s" % str(detail.get("needed", "different geometry"))
			"faces_not_parallel":
				return "the two faces of a pair are not parallel"
			"missing_reference":
				return "one of the picked faces no longer exists"
			"unresolved_mate_occurrence", "occurrence_not_found":
				return "a mate names a part that isn't in the assembly (%s): the sub-assembly may have changed since the mate was made" % str(detail.get("occurrence_id", "?"))
		return str(detail.get("type", detail))
	if detail != null:
		return str(detail)
	return str(result.get("error", "unknown error"))


# --- pose sync ---

func _local_pose(part: Node3D) -> Transform3D:
	## The part's pose in the frame the backend stores an Occurrence's transform
	## in (its node's local transform: the glb flattens every instance onto its
	## own node with no intermediate parenting; assembly_root's mm->m scale sits
	## above it). Basis re-orthonormalised: it is rotation-only by construction,
	## but a held part's is rebuilt each frame through float maths.
	return Transform3D(part.transform.basis.orthonormalized(), part.transform.origin)


static func pose_to_json(t: Transform3D) -> Dictionary:
	var q := t.basis.orthonormalized().get_rotation_quaternion()
	var axis := Vector3(0, 0, 1)
	var angle := 0.0
	if absf(q.w) < 0.9999999:
		angle = q.get_angle()
		axis = q.get_axis()
		if axis.length() < 0.0001:
			axis = Vector3(0, 0, 1)
	return {
		"translation": [t.origin.x, t.origin.y, t.origin.z],
		"rotation_axis": [axis.x, axis.y, axis.z],
		"rotation_angle_degrees": rad_to_deg(angle),
	}


static func json_to_pose(transform_json: Dictionary) -> Transform3D:
	var t: Array = transform_json.get("translation", [0.0, 0.0, 0.0])
	var axis: Array = transform_json.get("rotation_axis", [0.0, 0.0, 1.0])
	var angle_degrees: float = transform_json.get("rotation_angle_degrees", 0.0)
	var axis_vec := Vector3(axis[0], axis[1], axis[2])
	if axis_vec.length() < 0.0001:
		axis_vec = Vector3.UP
	return Transform3D(Basis(axis_vec.normalized(), deg_to_rad(angle_degrees)), Vector3(t[0], t[1], t[2]))


func persist_pose(part: Node3D) -> void:
	## Saves this part's current pose to the backend (fire and forget). Every
	## move of a placed part goes through here — grip-drag release, laser
	## rotate/nudge, undo/redo — so the backend's copy always matches what you
	## see, which every later mate solve depends on. Latest-wins per occurrence
	## (a burst of moves collapses to one write; writes never overlap).
	if not is_managed(part) or is_sandboxed(part):
		return # (a sandbox move is on screen only: set_relaxed)
	var occ := _occ_id(part)
	var entry: Dictionary = _persist.get_or_add(occ, {"pose": null, "running": false, "owner": ""})
	entry["pose"] = pose_to_json(_local_pose(part))
	entry["owner"] = owner_of(part)
	if not entry["running"]:
		_persist_loop(occ, entry)


# --- groups (a sub-assembly moved as one: group_set.gd) ---

func group_state(owner_part_id: String, occurrence_id: String) -> String:
	## Whether a move of the top-level occurrence `occurrence_id` of `owner_part_id` can be saved: "ok"; "grounded" (it is fixed); "mated" (a Mate names it, and
	## a mated sub-assembly can't be steered as a unit yet); or "unsaved" (no backend, or a root this tool doesn't manage).
	var state := occurrence_state(owner_part_id)
	if state.is_empty() or occurrence_id == "" or backend_url.is_empty() or api_key.is_empty():
		return "unsaved"
	if bool(state.get("occurrences", {}).get(occurrence_id, {}).get("fixed", false)):
		return "grounded"
	if bool(state.get("mated", {}).get(occurrence_id, false)):
		return "mated"
	return "ok"


func group_pose(owner_part_id: String, occurrence_id: String) -> Variant:
	## The occurrence's stored pose (a Transform3D, in the frame its node sits in), read from the backend unless this tool wrote or read it already.
	## null if it could not be read. A coroutine.
	var key := "%s|%s" % [owner_part_id, occurrence_id]
	if _group_poses.has(key):
		return _group_poses[key]
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_part_id, null)
	if not result["ok"] or not (result["json"] is Array):
		return null
	for row in result["json"]:
		if str(row.get("id", "")) == occurrence_id:
			_group_poses[key] = json_to_pose(row.get("transform", {}))
			return _group_poses[key]
	return null


func persist_group_pose(owner_part_id: String, occurrence_id: String, pose: Transform3D) -> void:
	## Saves a sub-assembly occurrence's pose (fire and forget, latest wins, like persist_pose).
	var key := "%s|%s" % [owner_part_id, occurrence_id]
	_group_poses[key] = pose
	var entry: Dictionary = _group_persist.get_or_add(key, {"pose": null, "running": false})
	entry["pose"] = pose_to_json(pose)
	if not entry["running"]:
		_group_persist_loop(owner_part_id, occurrence_id, entry)


func _group_persist_loop(owner_part_id: String, occurrence_id: String, entry: Dictionary) -> void:
	entry["running"] = true
	while entry["pose"] != null:
		var pose: Dictionary = entry["pose"]
		entry["pose"] = null
		var result := await _api_request(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [owner_part_id, occurrence_id], {"transform": pose})
		if not result["ok"]:
			_report("Couldn't save a sub-assembly move to the backend: %s" % _friendly_error(result))
	entry["running"] = false


func persist_path(part: Node3D) -> String:
	## Where a move of this part is saved: its own owner Part's occurrence (the loaded root's for the world, the room's Part for a part in a room).
	return "/parts/%s/occurrences/%s" % [owner_of(part), _occ_id(part)]


func _persist_loop(occ: String, entry: Dictionary) -> void:
	entry["running"] = true
	while entry["pose"] != null:
		var pose: Dictionary = entry["pose"]
		entry["pose"] = null
		var owner := str(entry.get("owner", _current_owner_part_id))
		var path := "/parts/%s/occurrences/%s" % [owner, occ]
		var fixed := bool(occurrence_state(owner).get("occurrences", {}).get(occ, {}).get("fixed", false))
		# The backend locks a grounded occurrence's transform: float it in the
		# same request as the move, then re-ground it.
		var body := {"transform": pose, "fixed": false} if fixed else {"transform": pose}
		var result := await _api_request(HTTPClient.METHOD_PATCH, path, body)
		if fixed and result["ok"]:
			await _api_request(HTTPClient.METHOD_PATCH, path, {"fixed": true})
		if not result["ok"]:
			_report("Couldn't save a move to the backend: %s" % _friendly_error(result))
	entry["running"] = false


# --- live, constrained motion (enforced mates) ---
##
## HOW A MATED PART MOVES (constrained-drag S5, DIDSA-CAD
## docs/constrained-drag-implementation-plan.md §3 and docs/motion/projector-spec.md
## — the spec is normative, scripts/motion/*.gd implement it and are pinned to
## DIDSA-CAD's golden vectors by tests/motion_vectors.gd). The backend says HOW the
## grabbed part and every part mated to it may move — one `mate-motion` answer
## carries the group's nearest satisfying poses (`members`, grabbed first) and an
## orthonormal free-motion `basis` — and the client applies the hand's motion
## LOCALLY every frame: the wish is projected onto that basis (followers in the
## metric), integrated as a screw, blended across re-anchors, and applied to ALL
## members, so followers move on screen. No network in the frame loop.
## Re-anchoring: one request in flight; every 150 ms (75 ms near a rank change) or
## when the client-side travel reaches the answer's `max_step`; every answer goes
## through the acceptance test (converged, residual, client-measured jump) before
## it replaces the model; a rejected / non-converged / failed answer HOLDS the
## last shown pose (never read as "all free"). Nothing is stored while dragging:
## the release sends ONE `commit:true` request with the release-time wish, and on
## success all members take the stored poses under a single undo entry; on
## converged:false or an error every member goes back to its pre-grab pose.

var stat_requests := 0 ## requests sent so far (diagnostics/tests: the point of the local model is that this stays low while dragging)
var stat_motion := {} ## instrumentation hooks (investigation §H), see reset_motion_stats()


func reset_motion_stats() -> void:
	stat_motion = {
		"anchor_requests": 0, "commit_requests": 0, "responses": 0, "transport_errors": 0,
		"anchors_accepted": 0, "anchors_rejected": {}, "holds": 0,
		"frames": 0, "projection_us_total": 0, "projection_us_max": 0,
	}


func _stat_add(key: String, amount: int = 1) -> void:
	if stat_motion.is_empty():
		reset_motion_stats()
	stat_motion[key] = int(stat_motion[key]) + amount


func _stat_reject(reason: String) -> void:
	if stat_motion.is_empty():
		reset_motion_stats()
	stat_motion["anchors_rejected"][reason] = int(stat_motion["anchors_rejected"].get(reason, 0)) + 1


func _now_ms() -> float:
	return float(Time.get_ticks_msec())


func constrain_drag(part: Node3D, desired_global: Transform3D) -> Transform3D:
	## Called every physics frame by controller.gd for a part being moved that
	## is_constrained(). `desired_global` is where the hand wants it; returns
	## the global pose to DISPLAY: that wish projected onto the motion the mates
	## allow (from the last accepted `mate-motion` anchor) — computed here, this
	## frame, no network — and the same frame the mated FOLLOWERS are moved to
	## their projected poses. Before the first anchor arrives it's the pose the
	## drag started from, so nothing jumps.
	var parent := part.get_parent() as Node3D
	var inv := parent.global_transform.affine_inverse()
	var state: Dictionary = _drag.get(part, {})
	if state.is_empty():
		state = _new_drag_state(part)
		_drag[part] = state
		_ensure_patterns(str(state["owner"])) # not awaited: the copies follow from the frame the answer is in (see _apply_copies)
	if bool(state["finishing"]):
		return parent.global_transform * state["shown_grabbed"] # released: the commit round trip is in flight, nothing follows the hand any more
	state["active"] = true
	state["desired"] = inv * desired_global
	state["wish"] = Se3.from_transform3d(state["desired"])
	if not state["running"]:
		_drag_loop(part, state)
	var hyst = state["hyst"]
	if hyst.active == null:
		return parent.global_transform * state["start"]
	var started := Time.get_ticks_usec()
	var poses := _frame_poses(state)
	var grabbed_pose: Transform3D = Se3.to_transform3d(poses[0])
	state["shown_grabbed"] = grabbed_pose
	state["shown_pose"] = poses[0]
	_apply_followers(state, poses)
	_apply_copies(state, poses)
	var elapsed := Time.get_ticks_usec() - started
	_stat_add("frames")
	_stat_add("projection_us_total", elapsed)
	stat_motion["projection_us_max"] = maxi(int(stat_motion["projection_us_max"]), elapsed)
	return parent.global_transform * grabbed_pose


func take_stuck_notice(part: Node3D) -> bool:
	## True once per drag, the first time it is asked after the backend said this part has no free motion (so the hand buzzes once).
	var state: Dictionary = _drag.get(part, {})
	if state.get("stuck") == false:
		state["stuck"] = true
		return true
	return false


func desired_global(part: Node3D) -> Transform3D:
	## The accumulated wish for a drag in progress (controller.gd's laser
	## rotate/nudge applies its per-frame increments on top of THIS, not the
	## displayed pose).
	var state: Dictionary = _drag.get(part, {})
	if state.is_empty() or state["desired"] == null:
		return part.global_transform
	return (part.get_parent() as Node3D).global_transform * state["desired"]


func end_drag(part: Node3D) -> bool:
	## Called on release/deselect. Returns true if this tool owned the drag (so
	## controller.gd skips its own undo bookkeeping): the loop stops, ONE
	## commit:true request stores the group, and the undo step is recorded.
	var state: Dictionary = _drag.get(part, {})
	if state.is_empty():
		return false
	state["active"] = false
	return true


func drag_member_nodes(part: Node3D) -> Dictionary:
	## The nodes of the members the drag in progress on `part` moves (occurrence id -> Node3D; the grabbed part's followers once an anchor has named them): the Drive tool reads their turning.
	var state: Dictionary = _drag.get(part, {})
	return {} if state.is_empty() else (state["nodes"] as Dictionary).duplicate()


func drag_at_limit(part: Node3D) -> bool:
	## True while the drag in progress on `part` is held at a limit mate's bound (the part is stopped by it).
	var state: Dictionary = _drag.get(part, {})
	return not state.is_empty() and bool(state["at_limit"])


func drag_model_ready(part: Node3D) -> bool:
	## True once an anchor has been accepted for this part's drag (tests wait on it).
	var state: Dictionary = _drag.get(part, {})
	return not state.is_empty() and state["hyst"].active != null


func _new_drag_state(part: Node3D) -> Dictionary:
	var lever := _lever_arm_for(part)
	return {
		"start": _local_pose(part), "desired": null, "wish": null,
		"active": true, "running": false, "finishing": false,
		"owner": owner_of(part), "occ": _occ_id(part), "part": part, # the grabbed node: which copy (the world's or a room's) the followers are looked up beside
		"lever_arm": lever, # sent until the first accepted answer; afterwards chart.lever_arm
		"hyst": DofHysteresis.new(), "blender": MotionBlender.new(1),
		"sched": ReanchorScheduler.new(_now_ms), "last_sent_ms": -100000.0,
		"members": [] as Array, "nodes": {}, "starts": {}, # occurrence id -> Node3D / pre-grab Transform3D
		"hold": false, "held": [], "shown": [], "shown_grabbed": _local_pose(part), "shown_pose": Se3.from_transform3d(_local_pose(part)),
		"last_error_ms": -100000.0,
		"limits": null, "at_limit": false, # a version-6 model (limit mates: read for their values) and whether the last frame was stopped by one
	}


func _lever_arm_for(part: Node3D) -> float:
	## Half the diagonal of the grabbed occurrence's bounding box in its OWN frame
	## (spec §6): the mesh AABB, in mm — the node's local frame is the backend's
	## occurrence frame. 0 = unknown (the request then omits lever_arm and the
	## backend uses its own bounding radius).
	var boxes: Array[AABB] = []
	_collect_aabbs(part, Transform3D.IDENTITY, boxes)
	if boxes.is_empty():
		return 0.0
	var box := boxes[0]
	for i in range(1, boxes.size()):
		box = box.merge(boxes[i])
	return box.size.length() / 2.0


func _collect_aabbs(node: Node3D, to_root: Transform3D, out: Array[AABB]) -> void:
	if node is VisualInstance3D:
		out.append(to_root * (node as VisualInstance3D).get_aabb())
	for child in node.get_children():
		if child is Node3D:
			_collect_aabbs(child, to_root * (child as Node3D).transform, out)


func _frame_poses(state: Dictionary) -> Array:
	## One frame's member poses (Se3 poses, grabbed first): the hysteresis' active
	## model projects the wish, the blender hides anchor steps; while holding, the
	## last shown poses are kept.
	if bool(state["hold"]):
		return state["held"]
	var hyst = state["hyst"]
	var blender = state["blender"]
	var frame: Dictionary = hyst.frame(state["wish"])
	var projected: Array = _limit_stop(state, frame["poses"], true)
	if frame["event"] == "adopted":
		blender.on_anchor(_limit_stop(state, frame["prev_poses"]), projected)
	var poses: Array = blender.shown(projected)
	state["shown"] = poses
	return poses


func _adopt_limit_model(state: Dictionary, model_json) -> void:
	## An anchor answer's `constraint_model`: kept (to read the limit mates' values) only when it holds a limit mate. A later answer that omits it keeps the one we
	## have; one without limits drops it. The model's own solve is NOT run per frame here: with the whole group in it (a gear train: pinion, gear, rack, crank, 42
	## rows) it costs 12 to 70 ms a frame in GDScript, which a headset cannot spare; the cheap stop below does the same job for the motion the mates allow.
	if model_json == null:
		return
	var model = LocalRetraction.try_parse(model_json, 8, 1024)
	state["limits"] = model if model != null and model.has_limits() else null


func _limit_stop(state: Dictionary, poses: Array, record := false) -> Array:
	## The projector (and so `poses`) is limit-blind: it would carry the part on through a stop and the next anchor would pop it back. This keeps the same motion
	## but stops it where a limit mate's range ends: the displacement from the anchor's poses (a screw per member, the projector's own chart) is scaled back by the
	## largest fraction that keeps every limit inside its range (bisection on the limit values, no derivatives). Exact for a rack or a hinge (one free motion), a
	## uniform slow-down for a diagonal drag into a stop (the nearest-point solve in the flat app slides along it instead). Nothing here when no limit is violated.
	## `record`: this is the frame being shown, so `state["at_limit"]` says whether it was stopped (the Drive readout and the release message read it).
	if record:
		state["at_limit"] = false
	var model = state["limits"]
	var hyst = state["hyst"]
	if model == null or hyst.active == null or model.member_ids != state["members"]:
		return poses
	if model.limits_in_range(poses):
		return poses
	var refs: Array = hyst.active.refs
	var twists: Array = []
	for i in poses.size():
		twists.append(Se3.screw_log(refs[i], poses[i]))
	var lo := 0.0
	var hi := 1.0
	var measured: Array = model.limit_member_indices() # only these members' poses decide a limit's value: the search moves only them
	for _step in 16: # the fraction to 1/65536: 56 mm of travel to a thousandth of a millimetre, 200 degrees to 0.003
		var mid := (lo + hi) / 2.0
		if model.limits_in_range(_scaled_poses(refs, twists, mid, measured)):
			lo = mid
		else:
			hi = mid
	if record:
		state["at_limit"] = true
	return _scaled_poses(refs, twists, lo)


static func _scaled_poses(refs: Array, twists: Array, fraction: float, only: Array = []) -> Array:
	## The anchor poses moved `fraction` of the way along their twists (every member, or only those in `only`: the rest stay at the anchor).
	var out: Array = []
	for i in refs.size():
		if not only.is_empty() and not only.has(i):
			out.append(refs[i])
			continue
		var d: Array = []
		for c in 6:
			d.append(float(twists[i][c]) * fraction)
		out.append(Se3.screw_exp(refs[i], d))
	return out


func _projected(state: Dictionary, wish) -> Array:
	## What the CURRENT model shows for `wish`, stopped at the limits (hyst.peek + _limit_stop).
	return _limit_stop(state, state["hyst"].peek(wish))


func _apply_followers(state: Dictionary, poses: Array) -> void:
	var members: Array = state["members"]
	for m in range(1, mini(members.size(), poses.size())):
		var node: Node3D = state["nodes"].get(members[m])
		if node != null and is_instance_valid(node):
			node.transform = Se3.to_transform3d(poses[m])


func _ensure_patterns(owner_part_id: String) -> void:
	## Reads the scope's component patterns once (a coroutine; nothing waits for it: a drag whose answer is not in yet moves no copies, and the commit
	## settles them anyway). A failed read is not cached: the next drag asks again.
	if owner_part_id == "" or _pattern_cache.has(owner_part_id) or _pattern_fetching.has(owner_part_id):
		return
	_pattern_fetching[owner_part_id] = true
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/component-patterns" % owner_part_id, null)
	_pattern_fetching.erase(owner_part_id)
	if result["ok"] and result["json"] is Array:
		_pattern_cache[owner_part_id] = result["json"]


func _copy_links(state: Dictionary) -> Array:
	## The pattern copies a drag moves live: [{member, pattern, index, node, nested: [{node, rel}]}], one per live copy of every non-suppressed pattern
	## whose source is a member of the group (the grabbed part or a follower), for the copy nodes of the dragged scope (the grabbed node's own copy of it: the
	## world's or a room's). `nested` are the nodes standing under a copy (`<source>#pattern:P:i/inner`) with their pose relative to it, so they move by the
	## same delta. Rebuilt when the members change; `copy_starts` keeps every copy node's pre-grab pose (the undo entry's "before"). Empty while the
	## scope's patterns are not read yet.
	var owner := str(state["owner"])
	var members: Array = state["members"]
	if not _pattern_cache.has(owner) or members.is_empty():
		return []
	if state.get("copy_links") != null and state["copy_links_for"] == members:
		return state["copy_links"]
	var part: Node3D = state["part"]
	var in_room: bool = is_instance_valid(part) and part.has_meta("room_id")
	var room_id = part.get_meta("room_id", 0) if is_instance_valid(part) else 0
	var by_first := {} # "<source>#pattern:P:i" -> the copy's node (path of one segment)
	var below := {} # the same key -> [nodes under it]
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is Node3D) or not is_instance_valid(node):
			continue
		var path := str(node.get_meta("instance_path", ""))
		if not path.contains(GroupIndex.PATTERN_SEGMENT) or str(node.get_meta("group_root", "")) != owner:
			continue
		if node.has_meta("room_id") != in_room or (in_room and node.get_meta("room_id", 0) != room_id):
			continue
		var first := path.get_slice("/", 0)
		if not CopyPose.parse_segment(first).has("source"):
			continue # a copy somewhere deeper inside a sub-assembly: its pose is not a function of a top-level source alone
		if path == first:
			by_first[first] = node
		else:
			if not below.has(first):
				below[first] = []
			below[first].append(node)
	var links: Array = []
	var starts: Dictionary = state.get("copy_starts", {})
	for m in members.size():
		for pattern in _pattern_cache[owner]:
			if not (pattern is Dictionary) or bool(pattern.get("suppressed", false)) or not (pattern.get("source_occurrence_ids", []) as Array).has(members[m]):
				continue
			for index in CopyPose.live_indices(pattern):
				var key := "%s%s%s:%d" % [members[m], GroupIndex.PATTERN_SEGMENT, str(pattern.get("id", "")), index]
				var copy: Node3D = by_first.get(key)
				if copy == null:
					continue
				var nested: Array = []
				for under in below.get(key, []):
					nested.append({"node": under, "rel": copy.transform.affine_inverse() * (under as Node3D).transform})
					if not starts.has(under):
						starts[under] = _local_pose(under)
				if not starts.has(copy):
					starts[copy] = _local_pose(copy)
				links.append({"member": m, "pattern": pattern, "index": index, "node": copy, "nested": nested})
	state["copy_starts"] = starts
	state["copy_links"] = links
	state["copy_links_for"] = members.duplicate()
	return links


func _apply_copies(state: Dictionary, poses: Array) -> void:
	## One frame: every copy of a moving member's pattern stands at `pattern_copy_pose(pattern, the member's pose this frame, index)`, and what is nested
	## under a copy keeps its place relative to it. Plain doubles (Se3) until the node's float32 transform. The backend stays the authority: the commit
	## (and every solve) puts the copies where the server says (`_copy_pose_changes`).
	for link in _copy_links(state):
		var m: int = link["member"]
		if m >= poses.size():
			continue
		var node: Node3D = link["node"]
		if not is_instance_valid(node):
			continue
		var pose := Se3.to_transform3d(CopyPose.copy_pose(link["pattern"], poses[m], int(link["index"])))
		node.transform = pose
		for under in link["nested"]:
			if is_instance_valid(under["node"]):
				(under["node"] as Node3D).transform = pose * (under["rel"] as Transform3D)


func _drag_loop(part: Node3D, state: Dictionary) -> void:
	## Anchor scheduling only (the per-frame display is constrain_drag()): at most
	## ONE request in flight; the first goes out at grab with `transform: null`.
	state["running"] = true
	var sched = state["sched"]
	while is_instance_valid(part) and bool(state["active"]):
		var hyst = state["hyst"]
		var due := false
		if hyst.active == null:
			due = true # no model yet: ask (the first anchor goes out at grab)
		elif bool(state["hold"]):
			due = bool(sched.check(0.0)["reanchor"]) # holding: the time cap only
		else:
			due = bool(sched.check(hyst.active.travel(state["shown_pose"]))["reanchor"])
		# after a miss keep the normal cadence: never re-ask faster than the time cap
		if due and sched.consecutive_misses > 0 and _now_ms() - float(state["last_sent_ms"]) < ReanchorScheduler.REANCHOR_MS:
			due = false
		if due:
			await _request_anchor(part, state)
		else:
			await get_tree().process_frame
	state["running"] = false
	if not is_instance_valid(part):
		_drag.erase(part)
	elif not bool(state["active"]) and not bool(state["finishing"]):
		_finish_drag(part, state)


func _anchor_body(state: Dictionary, wish, commit: bool) -> Dictionary:
	var body := {"transform": null if wish == null else Se3.pose_to_json(wish), "commit": commit}
	if float(state["lever_arm"]) > 0.0:
		body["lever_arm"] = float(state["lever_arm"])
	return body


func _request_anchor(part: Node3D, state: Dictionary) -> void:
	## ONE `mate-motion` request and the acceptance test on its answer (spec §7).
	var sched = state["sched"]
	var hyst = state["hyst"]
	var first: bool = hyst.active == null
	var wish_sent = null if first else state["wish"]
	var path := "/parts/%s/occurrences/%s/mate-motion" % [state["owner"], state["occ"]]
	sched.on_request_sent()
	state["last_sent_ms"] = _now_ms()
	_stat_add("anchor_requests")
	var response := await _api_request(HTTPClient.METHOD_POST, path, _anchor_body(state, wish_sent, false))
	_stat_add("responses")
	if not is_instance_valid(part):
		return
	if not bool(state["active"]):
		sched.invalidate() # released while in flight: the answer is ignored, the commit follows
		return
	handle_anchor_response(state, response, wish_sent)


func handle_anchor_response(state: Dictionary, response: Dictionary, wish_sent) -> void:
	## An anchor answer -> accept (new model, blend) or miss (hold). Only the
	## contract fields are read: members / basis / chart / quality / converged —
	## NOT the v0 aliases `transform` / `free_twists` (removed by CAD S9).
	## Public so tests can feed it synthetic answers without a network.
	var hyst = state["hyst"]
	var json = response["json"]
	var converged: bool = response["ok"] and json is Dictionary and bool(json.get("converged", false))
	var members: Array = []
	var quality: Dictionary = {}
	var lever := float(state["lever_arm"])
	var refs: Array = []
	var basis: Array = []
	if converged:
		members = json.get("members", [])
		quality = json.get("quality", {}) if json.get("quality") is Dictionary else {}
		var chart = json.get("chart")
		if chart is Dictionary and chart.get("lever_arm") != null:
			lever = float(chart["lever_arm"]) # ALWAYS the echoed value
		var raw_basis = json.get("basis")
		if members.is_empty() or not (raw_basis is Array) or lever <= 0.0:
			converged = false # no usable model: same as converged:false, never "all free"
		else:
			for mem in members:
				refs.append(Se3.pose_from_json(mem["transform"]))
			basis = raw_basis
			for row in basis:
				if not (row is Array) or (row as Array).size() != 6 * members.size():
					converged = false
	if converged:
		_adopt_limit_model(state, json.get("constraint_model")) # before the acceptance test and the blend: both read what the model shows, stopped at the limits
	var own = null
	if hyst.active != null and converged and wish_sent != null:
		own = _projected(state, wish_sent)[0] # the grabbed pose the CURRENT model projects the SAME wish to (stopped at the limits)
	var decision := ReanchorScheduler.accept_anchor(converged, quality.get("residual_inf"), refs[0] if converged else null, own, lever)
	if not bool(decision["accept"]):
		_anchor_missed(state, "transport" if not response["ok"] and int(response.get("code", 0)) == 0 else str(decision["reason"]), response)
		return
	_accept_anchor(state, members, refs, basis, lever, quality)


func _anchor_missed(state: Dictionary, reason: String, response: Dictionary) -> void:
	var sched = state["sched"]
	sched.on_miss()
	_stat_reject(reason)
	if reason == "transport":
		_stat_add("transport_errors")
	if not bool(state["hold"]) and state["hyst"].active != null:
		state["hold"] = true # HOLD the last shown pose; never read a failed answer as "all free"
		state["held"] = state["shown"] if not (state["shown"] as Array).is_empty() else state["hyst"].peek(state["wish"])
		_stat_add("holds")
	if sched.take_cue() and Time.get_ticks_msec() - int(state["last_error_ms"]) > 1000:
		state["last_error_ms"] = Time.get_ticks_msec()
		_report("Mate can't follow that move: %s" % _friendly_error(response if not response["ok"] else {"json": {"detail": {"type": "mate_solve_did_not_converge"}}}))


func _accept_anchor(state: Dictionary, members: Array, refs: Array, basis: Array, lever: float, quality: Dictionary) -> void:
	var hyst = state["hyst"]
	var blender = state["blender"]
	var ids: Array = []
	for mem in members:
		ids.append(str(mem["occurrence_id"]))
	var model = Projector.from_anchor(refs, basis, lever)
	if basis.is_empty() and not state.has("stuck"):
		# No free motion at all: the mates fix this part completely. Without saying so it just doesn't follow the hand, which reads as a dead grip.
		state["stuck"] = false # (false until the hand that holds it has buzzed: take_stuck_notice)
		var node: Node3D = state["part"]
		_report("%s is fully constrained by its mates: it can't move. Relax all mates (or remove a mate) to move it." % (label_or(node, "That part") if is_instance_valid(node) else "That part"))
	var wish = state["wish"]
	if ids != state["members"]:
		# first anchor, or the group changed under the drag: a fresh model and blender
		state["members"] = ids
		hyst.reset()
		blender = MotionBlender.new(ids.size())
		state["blender"] = blender
		for occ in ids:
			if not state["nodes"].has(occ):
				var node := _find_loaded_part(state["owner"], occ, state["part"])
				if node != null:
					state["nodes"][occ] = node
					if not state["starts"].has(occ):
						state["starts"][occ] = _local_pose(node) # followers have not moved yet: this is their pre-grab pose
		hyst.on_anchor(model)
		state["hold"] = false
	else:
		var holding: bool = bool(state["hold"])
		var old_projected: Array = state["held"] if holding else _projected(state, wish)
		if holding:
			blender.reset(ids.size()) # resume from the held pose with a normal blend
		hyst.on_anchor(model)
		blender.on_anchor(old_projected, _projected(state, wish))
		state["hold"] = false
	state["lever_arm"] = lever
	state["sched"].on_accepted(quality.get("max_step"), quality.get("sigma_gap"))
	_stat_add("anchors_accepted")


func _finish_drag(part: Node3D, state: Dictionary) -> void:
	## Release: stop the loop (done), then ONE `commit:true` request with the
	## release-time WISH (not the shown pose). Success -> every member takes the
	## stored pose, one undo entry for all. converged:false / error -> nothing was
	## stored, every member goes back to its pre-grab pose (spec §12).
	state["finishing"] = true
	state["sched"].invalidate()
	var path := "/parts/%s/occurrences/%s/mate-motion" % [state["owner"], state["occ"]]
	var wish = state["wish"]
	if wish == null:
		wish = Se3.from_transform3d(_local_pose(part))
	var result: Dictionary = {}
	for attempt in 2:
		_stat_add("commit_requests")
		result = await _api_request(HTTPClient.METHOD_POST, path, _anchor_body(state, wish, true))
		if result["ok"] or int(result["code"]) != 0:
			break # only a transport error (no HTTP answer at all) is retried, once
		_stat_add("transport_errors")
	if not is_instance_valid(part):
		_drag.erase(part)
		return
	var json = result["json"]
	var committed: bool = result["ok"] and json is Dictionary and bool(json.get("converged", false)) and bool(json.get("committed", false))
	var starts: Dictionary = state["starts"]
	starts[state["occ"]] = state["start"]
	var changes: Array = [] # {node, before, after}
	if committed:
		for mem in json.get("members", []):
			var occ := str(mem["occurrence_id"])
			var node: Node3D = part if occ == state["occ"] else state["nodes"].get(occ)
			if node == null or not is_instance_valid(node):
				node = _find_loaded_part(state["owner"], occ, state["part"])
			if node == null:
				continue
			var before: Transform3D = starts.get(occ, _local_pose(node))
			var after := json_to_pose(mem["transform"])
			node.transform = after
			if not before.is_equal_approx(after):
				changes.append({"node": node, "before": before, "after": after})
		# The copies of every moved member's pattern were shown live (`_apply_copies`): the server's poses are the authority, and the undo entry
		# restores each copy node to where the grab found it (a copy has no occurrence of its own, so nothing above covered it).
		var copy_starts: Dictionary = state.get("copy_starts", {})
		var copy_changes := await _copy_pose_changes(str(state["owner"]), copy_starts)
		if not is_instance_valid(part):
			_drag.erase(part)
			return
		var settled := {}
		for c in copy_changes:
			settled[c["node"]] = true
		for node in copy_starts:
			if not settled.has(node) and is_instance_valid(node) and not (copy_starts[node] as Transform3D).is_equal_approx(_local_pose(node)):
				copy_changes.append({"node": node, "before": copy_starts[node], "after": _local_pose(node)}) # the read failed: the live pose stays, undo still restores
		changes.append_array(copy_changes)
		_push_group_move("move %s" % label_or(part, str(part.name)), changes)
		if bool(state["at_limit"]):
			_report("%s stopped at its limit." % label_or(part, "The part"))
	else:
		# nothing is stored: put every member back where the grab found it
		for occ in starts:
			var node: Node3D = part if occ == state["occ"] else state["nodes"].get(occ)
			if node != null and is_instance_valid(node):
				node.transform = starts[occ]
		var copy_starts: Dictionary = state.get("copy_starts", {})
		for node in copy_starts:
			if is_instance_valid(node):
				node.transform = copy_starts[node] # the copies that followed the live drag go back too
		_report("Couldn't keep that move (nothing was changed): %s" % _friendly_error(result if not result["ok"] else {"json": {"detail": {"type": "mate_solve_did_not_converge"}}}))
	_drag.erase(part)


func _push_group_move(label: String, changes: Array) -> void:
	## ONE undo entry covering every member that moved.
	if command_stack == null or changes.is_empty():
		return
	command_stack.push(label,
		func() -> void:
			for c in changes:
				if is_instance_valid(c["node"]):
					c["node"].transform = c["before"]
					persist_pose(c["node"]),
		func() -> void:
			for c in changes:
				if is_instance_valid(c["node"]):
					c["node"].transform = c["after"]
					persist_pose(c["node"]),
		true)


static func copy_poses_from_instances(instances: Array, unit_scale: float = 1.0) -> Dictionary:
	## Pure — `instance_path` -> Transform3D for every instance of an assembly-mesh answer that sits on a pattern copy: its `occurrence_path` has a
	## `#pattern:` segment somewhere (the copy itself, a part nested inside a copied sub-assembly, a copy inside a sub-assembly). The path is joined
	## with "/" like the node's `instance_path`; the pose is the instance's `world_transform` (the backend composes the whole chain), its translation
	## times `unit_scale` (1 for a node in the backend's millimetres). Rows that are not shaped like an instance are ignored.
	var out := {}
	for instance in instances:
		if not (instance is Dictionary) or not (instance.get("occurrence_path") is Array) or not (instance.get("world_transform") is Dictionary):
			continue
		var segments := PackedStringArray((instance["occurrence_path"] as Array).map(func(x) -> String: return str(x)))
		var path := "/".join(segments)
		if not path.contains(GroupIndex.PATTERN_SEGMENT):
			continue
		var pose := json_to_pose(instance["world_transform"])
		out[path] = Transform3D(pose.basis, pose.origin * unit_scale)
	return out


func _copy_pose_changes(owner_part_id: String, before_poses: Dictionary = {}) -> Array:
	## [{node, before, after}] for every loaded pattern-copy node whose scope contains `owner_part_id` that is not where the backend now puts it: the scope
	## rooted at `owner_part_id` itself, AND every other loaded root with that Part somewhere below it (the world's root, an open room of it): a solve
	## inside a sub-assembly moves parts that the world's glb shows under the world root, and their copies stand there. A copy has no occurrence of its own,
	## so `GET .../occurrences` never moves it; with a copy mate the backend moves a part along with the copy's source (the copy is a fixed function of
	## it), and this is what keeps the copy on screen with its source. One lean request per distinct root (`geometry=false`: poses only); none at all when
	## no scope has a copy node. An older backend ignores the flag and sends the meshes too: slower, same answer.
	## `before_poses` (node -> Transform3D): where a node stood before something moved it on screen (a live drag's grab); it is the undo's "before", and a node
	## already shown at its `after` is still reported when that differs from it.
	var by_root := {} # group_root -> [copy nodes]
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		if not (node is Node3D) or not is_instance_valid(node) or not str(node.get_meta("instance_path", "")).contains(GroupIndex.PATTERN_SEGMENT):
			continue
		var root_id := str(node.get_meta("group_root", ""))
		if root_id == "":
			continue
		if root_id != owner_part_id and not (node.get_meta("group_parts", []) as Array).has(owner_part_id):
			continue
		if not by_root.has(root_id):
			by_root[root_id] = []
		by_root[root_id].append(node)
	var changes: Array = []
	for root_id in by_root:
		var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/assembly-mesh?geometry=false" % root_id, null)
		if not result["ok"] or not (result["json"] is Dictionary):
			continue
		var poses := copy_poses_from_instances(result["json"].get("instances", []), COPY_UNIT_SCALE)
		for node in by_root[root_id]:
			if not is_instance_valid(node):
				continue
			var key := str(node.get_meta("instance_path", ""))
			if not poses.has(key):
				continue
			var after: Transform3D = poses[key]
			var current := _local_pose(node)
			var before: Transform3D = before_poses.get(node, current)
			if current.is_equal_approx(after) and before.is_equal_approx(after):
				continue
			node.transform = after
			changes.append({"node": node, "before": before, "after": after})
	return changes


func _adopt_backend_poses(owner_part_id: String, label: String) -> bool:
	## Reads the stored occurrence poses and moves every LOADED node that differs
	## (what /solve just did to the driven part AND its followers) — one undo entry.
	## Nodes with a pose write still in flight are left alone (their write wins).
	## The copies of a patterned part follow in the same entry (`_copy_pose_changes`).
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_part_id, null)
	if not result["ok"] or not (result["json"] is Array):
		return false
	var changes: Array = []
	for occ in result["json"]:
		var occ_id := str(occ.get("id", ""))
		var entry: Dictionary = _persist.get(occ_id, {})
		if not entry.is_empty() and (bool(entry["running"]) or entry["pose"] != null):
			continue
		var node := _find_loaded_part(owner_part_id, occ_id)
		if node == null or not (occ.get("transform") is Dictionary):
			continue
		var before := _local_pose(node)
		var after := json_to_pose(occ["transform"])
		if before.is_equal_approx(after):
			continue
		node.transform = after
		changes.append({"node": node, "before": before, "after": after})
	changes.append_array(await _copy_pose_changes(owner_part_id))
	_push_group_move(label, changes)
	return true


func _find_loaded_part(owner_part_id: String, occurrence_id: String, near: Node3D = null) -> Node3D:
	## The node showing this occurrence. A sub-assembly's occurrences are on screen twice while its Assembly Room is open (the room's, and the world's
	## hidden copy, same owner and occurrence ids): `near` (a node in the same place) decides which, and without it a room's Part means the room's node.
	var fallback: Node3D = null
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		var ref := MeshIdentity.occurrence_ref_for(node)
		if ref.get("owner_part_id", "") != owner_part_id or ref.get("occurrence_id", "") != occurrence_id:
			continue
		var in_room: bool = node.has_meta("room_id")
		if near != null:
			if in_room == near.has_meta("room_id") and node.get_meta("room_id", 0) == near.get_meta("room_id", 0):
				return node
		elif in_room == _other_states.has(owner_part_id):
			return node
		elif fallback == null:
			fallback = node
	return fallback


func _apply_solved_transform(part: Node3D, transform_json: Dictionary) -> void:
	## Applies a solved RigidTransformResponse to `part`'s LOCAL transform
	## (relative to assembly_root) — valid because assembly-mesh.glb
	## flattens every instance's full world-relative-to-root transform onto
	## its own node with no intermediate parenting (mesh_export.py's
	## encode_assembly_glb), and because this tool only ever mates top-level
	## Occurrences (_validate_pick), so "local to its owning Part" and "the
	## instance's own baked node transform" are the same thing. Positions
	## stay in the backend's raw mm units, UNSCALED — assembly_root's own
	## basis already carries the mm->m (and any current scale-view multiple)
	## factor for its whole subtree, exactly like every other part's
	## position already does (see main.gd's _show_model()); multiplying by
	## spawn_scale here would double-apply it. (Verified against a real
	## backend: the applied pose equals the pose a fresh assembly-mesh.glb
	## fetch bakes in.)
	var before := _local_pose(part)
	var after := json_to_pose(transform_json)
	part.transform = after
	if command_stack and not before.is_equal_approx(after):
		command_stack.push("solve %s" % label_or(part, str(part.name)),
			func() -> void:
				if is_instance_valid(part):
					part.transform = before
					persist_pose(part),
			func() -> void:
				if is_instance_valid(part):
					part.transform = after
					persist_pose(part),
			true)


func _api_request(method: int, path: String, body_dict) -> Dictionary:
	## Returns {"ok":, "code":, "json":, "error":}. A fresh HTTPRequest per
	## call (mirroring main.gd's _import_external_file's own await-per-step
	## pattern) rather than one shared node, so overlapping calls (e.g. a
	## list refresh while a solve is in flight) never collide.
	if backend_url.is_empty() or api_key.is_empty(): # the server was switched away (or to none) while a refresh was still going
		return {"ok": false, "code": 0, "json": null, "error": "no backend configured"}
	stat_requests += 1
	var req := HTTPRequest.new()
	add_child(req)
	var headers := BackendSession.headers(api_key, true)
	var body := "" if body_dict == null else JSON.stringify(body_dict)
	var err := req.request(backend_url + API_PREFIX + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "json": null, "error": "request failed to start (error %d)" % err}
	var result: Array = await req.request_completed
	req.queue_free()
	var result_code: int = result[0]
	var response_code: int = result[1]
	var raw: PackedByteArray = result[3]
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": response_code, "json": null, "error": "network error (result %d)" % result_code}
	var parsed = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	var ok: bool = response_code >= 200 and response_code < 300
	return {"ok": ok, "code": response_code, "json": parsed, "error": ("" if ok else str(parsed))}
