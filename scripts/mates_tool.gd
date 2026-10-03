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

var mate_type := "coincident"
var mate_value := 0.0
var mate_flipped := false
var mate_allow_rotation := true
var relaxed := false

var mates: Array = [] ## last-fetched list for _current_owner_part_id, for the tablet's list UI
var occurrences: Dictionary = {} ## occurrence_id -> {"fixed": bool}, top-level occurrences of _current_owner_part_id (refresh_state())

var _mated_ids: Dictionary = {} ## occurrence_id -> true, for every occurrence any Mate references
var _drag: Dictionary = {} ## part -> live-drag state, see constrain_drag()
var _last_locked_notice_ms := -10000
var _persist: Dictionary = {} ## occurrence_id -> {"pose": Dictionary|null, "running": bool} — see persist_pose()

var _picks: Array[Dictionary] = []
var _status := ""
var _busy := false
var _current_owner_part_id := ""


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
	picks_changed.emit()


func status_text() -> String:
	if _status != "":
		return _status
	match _picks.size():
		0:
			return "Pick a face, edge or corner on the first part."
		1:
			return "Pick a face, edge or corner on the second part."
		_:
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


func can_create() -> bool:
	return _picks.size() == 2 and not _busy


func build_create_payload() -> Dictionary:
	## Pure — the exact POST /parts/{owner_part_id}/mates body MateCreate
	## expects (DIDSA-CAD's app.document.schemas.MateCreate).
	var references := []
	for p in _picks:
		references.append({"occurrence_id": p["occurrence_id"], "subshape_ref": p["subshape_ref"]})
	var payload := {
		"type": mate_type, "references": references,
		"flipped": mate_flipped, "allow_rotation": mate_allow_rotation,
	}
	if mate_type in ["distance", "angle"]:
		payload["value"] = mate_value
	return payload


func create_mate() -> Dictionary:
	## Returns {"ok":, "error":}. By convention the 2nd pick is the driven
	## occurrence solve_for_occurrence snaps into place afterward (unless
	## `relaxed`) — matching the flat app's own create-then-solve pairing.
	if not can_create():
		return {"ok": false, "error": "Pick two entities first."}
	var owner_part_id: String = _picks[0]["owner_part_id"]
	var driven_occurrence_id: String = _choose_driven(_picks[0]["occurrence_id"], _picks[1]["occurrence_id"])
	_busy = true
	var result := await _api_request(HTTPClient.METHOD_POST, "/parts/%s/mates" % owner_part_id, build_create_payload())
	_busy = false
	if not result["ok"]:
		return {"ok": false, "error": result["error"]}
	clear_picks()
	document_changed.emit()
	await refresh_mates(owner_part_id)
	if not relaxed:
		var solved: Dictionary = await solve_occurrence(owner_part_id, driven_occurrence_id)
		if not solved["ok"]:
			_report("Mate created, but couldn't be applied: %s" % solved["error"])
	return {"ok": true, "error": ""}


func refresh_mates(owner_part_id: String) -> void:
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


func solve_occurrence(owner_part_id: String, occurrence_id: String) -> Dictionary:
	## Solves occurrence_id's Mates server-side and applies the result to
	## whichever loaded Godot part carries that identity. The part's CURRENT
	## pose is saved first (the flat app's "PATCH the dragged pose, then solve"
	## order): the solver's initial guess is the pose stored on the backend, so
	## without this it solved from wherever the part used to be, not where you
	## left it. A grounded (fixed) occurrence can't be the driven side — say so
	## rather than letting the backend's 422 vanish.
	if bool(occurrences.get(occurrence_id, {}).get("fixed", false)):
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
	if backend_url.is_empty() or api_key.is_empty() or _current_owner_part_id.is_empty():
		return false
	var ref := MeshIdentity.occurrence_ref_for(part)
	return not ref.is_empty() and ref.get("occurrence_id", "") != "" and ref.get("owner_part_id", "") == _current_owner_part_id


func _occ_id(part: Node3D) -> String:
	return str(MeshIdentity.occurrence_ref_for(part).get("occurrence_id", ""))


func is_fixed(part: Node3D) -> bool:
	return is_managed(part) and bool(occurrences.get(_occ_id(part), {}).get("fixed", false))


func is_mated(part: Node3D) -> bool:
	return is_managed(part) and _mated_ids.has(_occ_id(part))


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
	var now_fixed := not bool(occurrences.get(occ, {}).get("fixed", false))
	var result := await _api_request(HTTPClient.METHOD_PATCH, "/parts/%s/occurrences/%s" % [_current_owner_part_id, occ], {"fixed": now_fixed})
	if not result["ok"]:
		_report("Couldn't %s %s: %s" % ["ground" if now_fixed else "float", str(part.name), _friendly_error(result)])
		return
	occurrences[occ] = {"fixed": now_fixed}
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
	var entry: Dictionary = _persist.get_or_add(occ, {"pose": null, "running": false})
	entry["pose"] = pose_to_json(_local_pose(part))
	if not entry["running"]:
		_persist_loop(occ, entry)


func _persist_loop(occ: String, entry: Dictionary) -> void:
	entry["running"] = true
	while entry["pose"] != null:
		var pose: Dictionary = entry["pose"]
		entry["pose"] = null
		var path := "/parts/%s/occurrences/%s" % [_current_owner_part_id, occ]
		var fixed := bool(occurrences.get(occ, {}).get("fixed", false))
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
		"owner": _current_owner_part_id, "occ": _occ_id(part),
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
				var node := _find_loaded_part(state["owner"], occ)
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
				node = _find_loaded_part(state["owner"], occ)
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


func _find_loaded_part(owner_part_id: String, occurrence_id: String) -> Node3D:
	for node in get_tree().get_nodes_in_group("grabbable_parts"):
		var ref := MeshIdentity.occurrence_ref_for(node)
		if ref.get("owner_part_id", "") == owner_part_id and ref.get("occurrence_id", "") == occurrence_id:
			return node
	return null


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
