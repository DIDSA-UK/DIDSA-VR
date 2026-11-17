extends RefCounted
## N1c: what DIDSA-CAD says about a mate's references (docs/mates-storage-sessions-plan-2026-11-12.md "N1 plan" and "N1b results").
## Since N1b every MateResponse carries
##   lost_references      paths whose face is gone or cannot be told from its look-alikes (the mate is `broken`; nothing to confirm)
##   moved_references     paths bound on weak evidence, or an old file's reference nobody confirmed (the mate is `held`: out of every solve
##                        until PATCH {"confirm_references": true}); the listed `index` is the face it is bound to
##   followed_references  paths the server re-found after an edit (REPORTED ONCE: the next listing is clean)
##   reference_reasons    path -> reason
##   held                 bool
## A path reads `references[0].subshape_ref`, `references[1].midplane.b.face_ref`, ... (`references[i].<suffix>`).
## An older backend sends none of this: every function here then says "nothing", and mate_health.gd keeps its own drift check.
## Pure functions over a mate dictionary, no network. Tests: tests/mate_reference_state.gd and tests/mate_health_server.gd.

const KEYS := ["lost_references", "moved_references", "followed_references", "reference_reasons", "held"]

const REASON_TEXT := {
	"no_match": "its face is gone",
	"ambiguous": "it cannot be told from a look-alike face",
	"body_missing": "its body is gone",
	"unconfirmed": "this old file never confirmed which face it meant",
	"exact_place_among_twins": "it followed the identical face in the same place",
	"nearest_radius": "it followed the face of the same radius",
	"unique_fingerprint_far": "the face moved a long way",
	"potentially_moved": "the face may have moved",
}


static func has_server_state(mate: Dictionary) -> bool:
	## True for a mate that came from a backend that knows N1b (any one of its fields is present: `held` is always sent, the lists too).
	for key in KEYS:
		if mate.has(key):
			return true
	return false


static func paths(mate: Dictionary, key: String) -> Array:
	var out: Array = []
	var raw = mate.get(key)
	if raw is Array:
		for p in raw:
			out.append(str(p))
	return out


static func lost_paths(mate: Dictionary) -> Array:
	return paths(mate, "lost_references")


static func held_paths(mate: Dictionary) -> Array:
	return paths(mate, "moved_references")


static func followed_paths(mate: Dictionary) -> Array:
	return paths(mate, "followed_references")


static func is_lost(mate: Dictionary) -> bool:
	return not lost_paths(mate).is_empty()


static func is_held(mate: Dictionary) -> bool:
	## Held out of every solve until confirmed. A lost mate is never held (there is nothing to confirm).
	return bool(mate.get("held", false)) and not is_lost(mate)


static func is_followed(mate: Dictionary) -> bool:
	return not followed_paths(mate).is_empty()


static func reference_path(reference_index: int, suffix: String) -> String:
	return "references[%d].%s" % [reference_index, suffix]


static func state_of(mate: Dictionary, path: String) -> String:
	## "lost" | "held" | "followed" | "" for one reference path: what the server said about it (empty: it said nothing, the reference is fine).
	if path in lost_paths(mate):
		return "lost"
	if path in held_paths(mate):
		return "held"
	if path in followed_paths(mate):
		return "followed"
	return ""


static func reported(mate: Dictionary, path: String) -> bool:
	## The server reports this reference (followed, held or lost): the client's own drift check must not second-guess it.
	return state_of(mate, path) != ""


static func reason(mate: Dictionary, path: String) -> String:
	var reasons = mate.get("reference_reasons")
	return str(reasons.get(path, "")) if reasons is Dictionary else ""


static func reason_text(code: String) -> String:
	if code == "":
		return ""
	return str(REASON_TEXT.get(code, code.replace("_", " ")))


static func first_reason_text(mate: Dictionary, path_list: Array) -> String:
	## The reason for the first of `path_list` that has one, as a phrase ("its face is gone"); "" if the server gave none.
	for p in path_list:
		var text := reason_text(reason(mate, str(p)))
		if text != "":
			return text
	return ""


static func note_for(mate: Dictionary) -> Dictionary:
	## What the tablet shows for a mate: {kind: "" | "followed" | "held" | "lost", text}. Lost beats held beats followed (a mate can be both held and have
	## followed another reference). "" = nothing to say (an older backend says nothing, so it never has a note).
	if is_lost(mate):
		var why := first_reason_text(mate, lost_paths(mate))
		return {"kind": "lost", "text": "Lost a face%s. Make the mate again or delete it." % ("" if why == "" else ": " + why)}
	if is_held(mate):
		var why2 := first_reason_text(mate, held_paths(mate))
		return {"kind": "held", "text": "Check this mate%s. It is left out of every move until you confirm it." % ("" if why2 == "" else ": " + why2)}
	if is_followed(mate):
		return {"kind": "followed", "text": "Followed the edit: it now sits on the same face under its new number."}
	return {"kind": "", "text": ""}


static func held_mate_ids(response: Dictionary) -> Array:
	## The mates a solve left out (N-6): `held_mate_ids` in the JSON of a mate-motion / preview answer (absent when none), and the `X-Held-Mates`
	## header of a solve, create or PATCH answer (`held_mates`, set by MatesTool._api_request). Both, de-duplicated, in the order given.
	var out: Array = []
	var json = response.get("json")
	if json is Dictionary and json.get("held_mate_ids") is Array:
		for id in json["held_mate_ids"]:
			if str(id) not in out:
				out.append(str(id))
	if response.get("held_mates") is Array:
		for id in response["held_mates"]:
			if str(id) not in out:
				out.append(str(id))
	return out


static func parse_held_header(value: String) -> Array:
	## `X-Held-Mates: id,id` -> [id, id].
	var out: Array = []
	for part in value.split(","):
		var id := part.strip_edges()
		if id != "" and id not in out:
			out.append(id)
	return out


static func left_out_text(ids: Array, mates: Array) -> String:
	## "1 mate left out of the solve: Coincident (check it)". `mates` is the current list, for the type and the state of each id.
	if ids.is_empty():
		return ""
	var bits: Array[String] = []
	for id in ids:
		var label := "a mate"
		var why := "needs checking"
		for mate in mates:
			if str(mate.get("id", "")) == str(id):
				label = str(mate.get("type", "mate")).capitalize()
				why = "lost a face" if is_lost(mate) else "check it"
		bits.append("%s (%s)" % [label, why])
	return "%d mate%s left out of the solve: %s." % [ids.size(), "" if ids.size() == 1 else "s", ", ".join(bits)]


static func summary_text(mates: Array) -> String:
	## One line for the design table's status after an edit: how many mates the backend followed onto renumbered faces, how many need a check,
	## how many lost a face. "" when it flagged none (an older backend flags none).
	var followed := 0
	var held := 0
	var lost := 0
	for mate in mates:
		if not (mate is Dictionary):
			continue
		if is_lost(mate):
			lost += 1
		elif is_held(mate):
			held += 1
		elif is_followed(mate):
			followed += 1
	var bits: Array[String] = []
	if followed > 0:
		bits.append("%d mate%s followed the edit onto the renumbered face" % [followed, "" if followed == 1 else "s"])
	if held > 0:
		bits.append("%d need%s checking (Confirm on the Mates page)" % [held, "s" if held == 1 else ""])
	if lost > 0:
		bits.append("%d lost a face" % lost)
	return "" if bits.is_empty() else "; ".join(bits) + "."


static func merge_followed(listed: Array, notes: Dictionary) -> Dictionary:
	## A server reports a followed reference once; a listing read between the edit and the screen that shows it would otherwise swallow the news.
	## `notes` (mate id -> {followed: [paths], reasons: {path: reason}}) is what MatesTool kept from earlier listings: put it back into the freshly
	## listed mates (the same dictionaries, edited in place) and remember what this listing newly reported. Returns `notes` pruned of mates that are gone.
	var by_id := {}
	for mate in listed:
		if mate is Dictionary:
			by_id[str(mate.get("id", ""))] = true
	for id in notes.keys():
		if not by_id.has(id):
			notes.erase(id)
	for mate in listed:
		if not (mate is Dictionary):
			continue
		var id := str(mate.get("id", ""))
		var note: Dictionary = notes.get(id, {"followed": [], "reasons": {}})
		for p in followed_paths(mate):
			if p not in note["followed"]:
				note["followed"].append(p)
			var r := reason(mate, p)
			if r != "":
				note["reasons"][p] = r
		if not (note["followed"] as Array).is_empty():
			notes[id] = note
			var followed: Array = mate.get("followed_references", []) if mate.get("followed_references") is Array else []
			for p in note["followed"]:
				if p not in followed:
					followed.append(p)
			mate["followed_references"] = followed
			var reasons: Dictionary = mate.get("reference_reasons", {}) if mate.get("reference_reasons") is Dictionary else {}
			for p in note["reasons"]:
				if not reasons.has(p):
					reasons[p] = note["reasons"][p]
			mate["reference_reasons"] = reasons
	return notes
