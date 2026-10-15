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
signal document_changed() ## a mate was made or deleted, or a part grounded / floated: what a save would write is different
signal mates_changed()
signal enforce_finished(result: Dictionary) ## enforce_all() ended: {ok, solved, problems}

const API_PREFIX := "/document"
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const TopologyPick := preload("res://scripts/topology_pick.gd")
const Se3 := preload("res://scripts/motion/se3.gd")
const Projector := preload("res://scripts/motion/free_motion_projector.gd")
const MotionBlender := preload("res://scripts/motion/motion_blender.gd")
const DofHysteresis := preload("res://scripts/motion/dof_hysteresis.gd")
const ReanchorScheduler := preload("res://scripts/motion/reanchor_scheduler.gd")
const MATE_TYPES: Array[String] = ["coincident", "concentric", "parallel", "distance", "angle"]

var active := false ## wrist tablet's "Mates tool" toggle
var backend_url := ""
var api_key := ""
var command_stack = null ## set via setup(); shared undo/redo history

## What the mate being set up will be. Changing any of them re-runs the preview (a ghost of the part where the mate would put it).
var mate_type := "coincident":
	set(v):
		mate_type = v
		reset_branch_choice() # a choice made for another kind of mate means nothing here
		request_preview()
var mate_value := 0.0:
	set(v):
		mate_value = v
		request_preview()
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
var relaxed := false

var mates: Array = [] ## last-fetched list for _current_owner_part_id, for the tablet's list UI
var occurrences: Dictionary = {} ## occurrence_id -> {"fixed": bool}, top-level occurrences of _current_owner_part_id (refresh_state())

var _mated_ids: Dictionary = {} ## occurrence_id -> true, for every occurrence any Mate references
var _drag: Dictionary = {} ## part -> live-drag state, see constrain_drag()
var _last_locked_notice_ms := -10000
var _persist: Dictionary = {} ## occurrence_id -> {"pose": Dictionary|null, "running": bool} — see persist_pose()

const GHOST_COLOUR := Color(0.31, 0.77, 1.0, 0.40)

var _picks: Array[Dictionary] = []
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
var _pending_edit: Dictionary = {} ## "mate_id|fields" -> the branch changes an edit was refused for; repeating that exact edit confirms them
var _busy := false
var _group_poses: Dictionary = {} ## "owner|occurrence" -> Transform3D of a sub-assembly occurrence, as last read or written (group_pose())
var _group_persist: Dictionary = {}
var _current_owner_part_id := "" ## the ACTIVE root: the one the Mates page lists and creates mates on (the world's loaded root)
var _other_states: Dictionary = {} ## owner Part id -> {"occurrences": {occ: {"fixed"}}, "mated": {occ: true}} for every OTHER root whose parts can be moved and saved: each open Assembly Room's Part (load_owner_state)


func setup(stack) -> void:
	command_stack = stack


func configure_backend(url: String, key: String) -> void:
	backend_url = url
	api_key = key


func is_busy() -> bool:
	return _busy


func set_active(on: bool) -> void:
	active = on
	if not on:
		clear_picks()


func clear_picks() -> void:
	_picks.clear()
	_status = ""
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


func status_text() -> String:
	if _status != "":
		return _status
	match _picks.size():
		0:
			return "Pick a face, edge or corner on the first part."
		1:
			return "Pick a face, edge or corner on the second part."
		_:
			if _branch_notice != "":
				return _branch_notice
			if preview_visible():
				return "Preview shown in blue. If it is the wrong way press Flip or Next solution, then Create."
			return "Ready — choose a mate type and Create."
	return ""


func picked_entities() -> Array:
	## [{part, kind, body_id, index, face_index, key}] for face_highlight.gd, in pick order (a face, edge or vertex).
	var out := []
	for p in _picks:
		var entity: Dictionary = (p.get("entity", {}) as Dictionary).duplicate()
		entity["part"] = p.get("part")
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
	if not active or _picks.size() >= 2:
		return
	var occ_ref := MeshIdentity.occurrence_ref_for(part)
	var subshape := MeshIdentity.subshape_ref_for_hit(part, face_index)
	var kind := "face"
	if not subshape.is_empty() and not entity.is_empty() and str(entity.get("kind", "face")) != "face":
		# The laser was on a straight / circular edge or a corner of that face (topology_pick.gd): mate that.
		kind = str(entity["kind"])
		subshape = {"body_id": str(entity["body_id"]), "shape_type": kind, "index": int(entity["index"])}
	var rejection := _validate_pick(occ_ref, subshape)
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
		"label": str(part.name), # Node.name is a StringName, not a String - cast once here so later == comparisons (tests, UI) behave
		"part": part, # for face_highlight.gd: the picked face / edge / corner stays lit
		"face_index": face_index,
		"entity": entity if kind != "face" else {},
		"kind": kind,
	})
	_status = ""
	reset_branch_choice() # another face means another set of roots
	request_preview()
	picks_changed.emit()


func _validate_pick(occ_ref: Dictionary, subshape: Dictionary) -> String:
	## Pure, no network — "" means OK, else a user-facing rejection reason.
	if occ_ref.is_empty():
		return "This part has no backend identity yet (not loaded from the backend)."
	if occ_ref.get("occurrence_id", "") == "":
		return "Can't mate the assembly's own root content — pick a placed part."
	if subshape.is_empty():
		return "This part has no face identity yet (not loaded from the backend)."
	if not _picks.is_empty():
		var first: Dictionary = _picks[0]
		if first["owner_part_id"] != occ_ref["owner_part_id"]:
			return "Both parts must belong to the same assembly."
		if first["occurrence_id"] == occ_ref["occurrence_id"]:
			return "Pick two different parts, not the same one twice."
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
	if not active or _picks.size() != 2 or backend_url == "" or not is_inside_tree():
		_clear_ghost()
		return
	_run_preview(_preview_seq)


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


static func secondary_flip_label(type: String) -> String:
	## Pure — what the secondary flag means for a mate of `type`.
	match type:
		"distance":
			return "Flip side"
		"concentric":
			return "Flip spin"
		"angle":
			return "Supplement"
	return "Flip"


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
		parts.append("%s%s" % ["Aligned" if alignment == "aligned" else "Anti-aligned", " (auto)" if mate_alignment == "" else ""])
	var flip := shown_secondary_flip()
	if flip >= 0:
		parts.append("%s: %s%s" % [secondary_flip_label(mate_type), "on" if flip == 1 else "off", " (auto)" if mate_secondary_flip < 0 else ""])
	if branch_alternatives.size() > 1:
		var index := alternative_index(branch_alternatives, alignment, flip)
		parts.append("solution %s of %d" % [str(index + 1) if index >= 0 else "-", branch_alternatives.size()])
	return " · ".join(parts)


func _run_preview(seq: int) -> void:
	var owner_part_id: String = _picks[0]["owner_part_id"]
	var driven_id: String = _choose_driven(_picks[0]["occurrence_id"], _picks[1]["occurrence_id"])
	var result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/occurrences/%s/preview-mate-solve?movement=%s" % [owner_part_id, driven_id, movement_param()], build_create_payload())
	if seq != _preview_seq or _picks.size() != 2:
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
		var found = json.get("branch_changes", [])
		_branch_changes = found if found is Array else []
		_branch_notice = branch_notice(_branch_changes, json.get("blocked_by", []) if json.get("blocked_by") is Array else [], json.get("conflicting", []) if json.get("conflicting") is Array else [], mates)
	_clear_ghost()
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
	return _picks.size() == 2 and not _busy


func build_create_payload(with_branch_changes := false) -> Dictionary:
	## Pure — the exact POST /parts/{owner_part_id}/mates body MateCreate
	## expects (DIDSA-CAD's app.document.schemas.MateCreate). `with_branch_changes` adds the earlier mates the preview showed on their
	## other branch (what Create confirms); the preview request itself never carries them.
	var references := []
	for p in _picks:
		references.append({"occurrence_id": p["occurrence_id"], "subshape_ref": p["subshape_ref"]})
	var payload := {
		"type": mate_type, "references": references,
		"allow_rotation": mate_allow_rotation,
	}
	# The branch is named only when the user picked it; left out, the backend resolves it (Closest) and the preview says which.
	if mate_alignment != "":
		payload["alignment"] = mate_alignment
	if mate_secondary_flip >= 0:
		payload["secondary_flip"] = mate_secondary_flip == 1
	if mate_type in ["distance", "angle"]:
		payload["value"] = mate_value
	if with_branch_changes and not _branch_changes.is_empty():
		payload["branch_changes"] = confirmed_changes(_branch_changes)
	return payload


func create_mate() -> Dictionary:
	## Returns {"ok":, "error":}. By convention the 2nd pick is the driven
	## occurrence (_choose_driven). Unless `relaxed`, creating is ATOMIC: the backend runs the same solve
	## the ghost showed and stores the mate together with every moved part's pose only if it converges
	## (`POST .../mates?solve=...`), so a refused mate is never left behind. The driven part's current pose
	## is saved first - the solver starts from the stored pose, so without that it would solve from
	## wherever the part used to be. Relaxed, or with the driven part grounded, only the mate is stored.
	if not can_create():
		return {"ok": false, "error": "Pick two entities first."}
	var owner_part_id: String = _picks[0]["owner_part_id"]
	var driven_occurrence_id: String = _choose_driven(_picks[0]["occurrence_id"], _picks[1]["occurrence_id"])
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
	if atomic:
		await _adopt_backend_poses(owner_part_id, "mate %s" % (str(part.name) if part != null else driven_occurrence_id))
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
	if atomic:
		await _adopt_backend_poses(owner_part_id, "edit mate %s" % (str(part.name) if part != null else driven_id))
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
	var adopted := await _adopt_backend_poses(owner_part_id, "solve %s" % (str(part.name) if part != null else occurrence_id))
	if not adopted:
		var transform_json: Dictionary = result["json"].get("transform", {})
		if part != null and not transform_json.is_empty():
			_apply_solved_transform(part, transform_json)
	await refresh_mates(owner_part_id)
	return {"ok": true, "error": ""}


func enforce_all(owner_part_id: String) -> Dictionary:
	## Solves every non-grounded occurrence any of this Part's own Mates
	## reference, and reports the outcome on the tablet. Returns {ok, solved, problems}
	## (ok = every mate was satisfied) and emits enforce_finished with the same.
	await refresh_state(owner_part_id)
	var solved := 0
	var problems: Array[String] = []
	for occ_id in _mated_ids:
		if bool(occurrences.get(occ_id, {}).get("fixed", false)):
			continue # grounded: it's the anchor the others are solved against
		var result: Dictionary = await solve_occurrence(owner_part_id, occ_id)
		if result["ok"]:
			solved += 1
		else:
			problems.append(result["error"])
	if problems.is_empty():
		_report("Enforced mates on %d part(s)." % solved if solved > 0 else "Nothing to enforce: every mated part is grounded, or there are no mates yet.")
	else:
		_report("Couldn't satisfy every mate: %s" % "; ".join(problems))
	var outcome := {"ok": problems.is_empty(), "solved": solved, "problems": problems}
	enforce_finished.emit(outcome)
	return outcome


func set_relaxed(on: bool) -> void:
	relaxed = on


# --- state, locking, and grounding ---

func refresh_state(owner_part_id: String) -> void:
	## Re-reads this assembly's top-level occurrences (for their `fixed` flags)
	## and Mates (for which parts are mated) — the two facts is_locked()/
	## is_constrained() need. Called after every model load and by
	## enforce_all(); mate create/delete/solve refresh the mate list themselves.
	_current_owner_part_id = owner_part_id
	occurrences.clear()
	_mated_ids.clear()
	if backend_url.is_empty() or api_key.is_empty() or owner_part_id.is_empty():
		mates_changed.emit()
		return
	var result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/occurrences" % owner_part_id, null)
	if result["ok"] and result["json"] is Array:
		for occ in result["json"]:
			occurrences[str(occ.get("id", ""))] = {"fixed": bool(occ.get("fixed", false))}
	await refresh_mates(owner_part_id)


func _rebuild_mated_ids() -> void:
	_mated_ids.clear()
	for mate in mates:
		for ref in mate.get("references", []):
			_mated_ids[str(ref.get("occurrence_id", ""))] = true


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
	var mated := {}
	var mate_result := await _api_request(HTTPClient.METHOD_GET, "/parts/%s/mates" % owner_part_id, null)
	if mate_result["ok"] and mate_result["json"] is Array:
		for mate in mate_result["json"]:
			for ref in mate.get("references", []):
				mated[str(ref.get("occurrence_id", ""))] = true
	set_owner_state(owner_part_id, occs, mated)
	return true


func drop_owner_state(owner_part_id: String) -> void:
	_other_states.erase(owner_part_id)


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
	_report("%s is grounded by a mate — Float it (Assembly > Mates) or Relax all mates to move it." % str(part.name))


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
		_report("Couldn't %s %s: %s" % ["ground" if now_fixed else "float", str(part.name), _friendly_error(result)])
		return
	occs[occ] = {"fixed": now_fixed}
	document_changed.emit()
	_report("%s is now %s." % [str(part.name), "grounded (fixed)" if now_fixed else "floating (free to move)"])


func _choose_driven(first_occ: String, second_occ: String) -> String:
	## By convention the second pick is driven, unless it's grounded (a grounded
	## occurrence can never be the driven side — the backend 422s it) and the
	## first isn't.
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
	if not is_managed(part):
		return
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
	var elapsed := Time.get_ticks_usec() - started
	_stat_add("frames")
	_stat_add("projection_us_total", elapsed)
	stat_motion["projection_us_max"] = maxi(int(stat_motion["projection_us_max"]), elapsed)
	return parent.global_transform * grabbed_pose


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
	if frame["event"] == "adopted":
		blender.on_anchor(frame["prev_poses"], frame["poses"])
	var poses: Array = blender.shown(frame["poses"])
	state["shown"] = poses
	return poses


func _apply_followers(state: Dictionary, poses: Array) -> void:
	var members: Array = state["members"]
	for m in range(1, mini(members.size(), poses.size())):
		var node: Node3D = state["nodes"].get(members[m])
		if node != null and is_instance_valid(node):
			node.transform = Se3.to_transform3d(poses[m])


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
	var own = null
	if hyst.active != null and converged and wish_sent != null:
		own = hyst.peek(wish_sent)[0] # the grabbed pose the CURRENT model projects the SAME wish to
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
		var old_projected: Array = state["held"] if holding else hyst.peek(wish)
		if holding:
			blender.reset(ids.size()) # resume from the held pose with a normal blend
		hyst.on_anchor(model)
		blender.on_anchor(old_projected, hyst.peek(wish))
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
		_push_group_move("move %s" % part.name, changes)
	else:
		# nothing is stored: put every member back where the grab found it
		for occ in starts:
			var node: Node3D = part if occ == state["occ"] else state["nodes"].get(occ)
			if node != null and is_instance_valid(node):
				node.transform = starts[occ]
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


func _adopt_backend_poses(owner_part_id: String, label: String) -> bool:
	## Reads the stored occurrence poses and moves every LOADED node that differs
	## (what /solve just did to the driven part AND its followers) — one undo entry.
	## Nodes with a pose write still in flight are left alone (their write wins).
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
		command_stack.push("solve %s" % part.name,
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
