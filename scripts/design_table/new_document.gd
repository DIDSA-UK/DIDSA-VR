extends RefCounted
## Starting from nothing: a new empty assembly, and a new part inside it. Thin on purpose, like part_features.gd: DIDSA-CAD owns
## the document model, VR only calls the same routes the flat app does. Every call goes through `api`, a Callable (method, path,
## body) -> Dictionary {ok, code, json, error}, so tests give it a fake.
##
## The backend rules this leans on (checked in DIDSA-CAD, app/document/router.py and models.py):
##   * POST /document/new starts a fresh, empty Document and clears the sketch store (a full replace). POST /document/parts
##     only ever ADDS to the session's Document, and the FIRST part ever added becomes the document's root_part_id, which is the
##     part a saved native file (and the flat app) opens. So a new assembly is: /document/new, then ONE part (the root).
##   * A "new part" is a new Part plus an Occurrence of it on the root: POST /document/parts/{root}/occurrences with a
##     CLIENT-supplied id and `resolved_part_id` naming the new part (honoured only if the part already exists in the document).
##     That is the same shape Add component and a saved bundle already use, so the flat app reads it unchanged.

const ROOT_NAME := "Assembly"

var api: Callable


func _init(p_api: Callable = Callable()) -> void:
	api = p_api


func start_assembly(name: String = ROOT_NAME) -> Dictionary:
	## A fresh empty document with one empty root part. {ok, root_id, error}.
	var cleared: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/new", {})
	if not cleared["ok"]:
		return {"ok": false, "root_id": "", "error": str(cleared["error"])}
	var made: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/parts", {"name": name})
	if not made["ok"] or not (made["json"] is Dictionary) or str((made["json"] as Dictionary).get("id", "")) == "":
		return {"ok": false, "root_id": "", "error": str(made["error"]) if not made["ok"] else "The backend made no part."}
	return {"ok": true, "root_id": str((made["json"] as Dictionary)["id"]), "error": ""}


func next_part_name(root_id: String) -> String:
	## "Part N", N one more than the occurrences the root already has (a failed lookup just starts at 1).
	var listed: Dictionary = await api.call(HTTPClient.METHOD_GET, "/document/parts/%s/occurrences" % root_id, null)
	var count := 0
	if listed["ok"] and listed["json"] is Array:
		count = (listed["json"] as Array).size()
	return "Part %d" % (count + 1)


func add_part(root_id: String, name: String, pose_json: Dictionary) -> Dictionary:
	## A new empty part placed on the root at `pose_json` ({translation (mm), rotation_axis, rotation_angle_degrees}, the
	## assembly's own frame). {ok, part_id, occurrence_id, error}. If placing it fails the new part is left in the document
	## unplaced (harmless: nothing shows it), and the error says so.
	var made: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/parts", {"name": name})
	if not made["ok"] or not (made["json"] is Dictionary) or str((made["json"] as Dictionary).get("id", "")) == "":
		return {"ok": false, "part_id": "", "occurrence_id": "", "error": str(made["error"]) if not made["ok"] else "The backend made no part."}
	var part_id := str((made["json"] as Dictionary)["id"])
	var occurrence_id := new_occurrence_id()
	var placed: Dictionary = await api.call(HTTPClient.METHOD_POST, "/document/parts/%s/occurrences" % root_id, {
		"id": occurrence_id,
		"resolved_part_id": part_id,
		"name_override": name,
		"transform": pose_json,
	})
	if not placed["ok"]:
		return {"ok": false, "part_id": part_id, "occurrence_id": "", "error": "Couldn't place the new part: %s" % str(placed["error"])}
	return {"ok": true, "part_id": part_id, "occurrence_id": occurrence_id, "error": ""}


func remove_occurrence(root_id: String, occurrence_id: String) -> bool:
	## Takes a placed part off the assembly again (an empty part nobody drew anything on). The part itself stays in the
	## document, unreferenced and invisible.
	var r: Dictionary = await api.call(HTTPClient.METHOD_DELETE, "/document/parts/%s/occurrences/%s" % [root_id, occurrence_id], null)
	return bool(r["ok"])


static func new_occurrence_id() -> String:
	## A fresh id the client invents (the backend requires one): "occ_" and 16 random bytes in hex.
	return "occ_" + Crypto.new().generate_random_bytes(16).hex_encode()
