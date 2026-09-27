extends Node
## The vision brief's Assembly tools "Colours": PATCH a placed Occurrence's
## real colour override via DIDSA-CAD's existing endpoint
## (PATCH /parts/{owner_part_id}/occurrences/{occurrence_id},
## OccurrenceTransformUpdate.color) — the same one the flat app's own
## colour-disc row uses, never a VR-only colour representation, so a colour
## set here round-trips with the flat app and with this VR client's own next
## assembly-mesh.glb fetch, exactly like the Mates tool (mates_tool.gd).
##
## Unlike Mates, this needs no picking tool of its own: it acts on whichever
## part is already laser-selected (main.gd's current_selected_part(), the
## same lookup the Tools tab's "Isolate selected" already uses) — the wrist
## tablet's Colours tab just offers a swatch palette plus a custom hex entry
## via the popup keyboard.
##
## Applies the new colour LOCALLY (material_override) as soon as the backend
## confirms the PATCH, so the change is visible immediately without a full
## assembly reload — an optimistic, client-only preview: it does not attempt
## to reconstruct the mesh's own true pre-colour material (not threaded
## through assembly-mesh.glb at all), so "Clear colour" shows a plain neutral
## grey rather than whatever the backend's own default might render on the
## next real fetch. Not undoable via command_stack, same precedent as the
## Mates tool's create/delete: a backend-committed action, not a purely
## local, instant transform.

const API_PREFIX := "/document"
const MeshIdentity := preload("res://scripts/mesh_identity.gd")
const DEFAULT_MATERIAL_COLOR := Color(0.7, 0.7, 0.7, 1.0) ## plain neutral grey shown after "Clear colour"

var backend_url := ""
var api_key := ""

var _busy := false


func configure_backend(url: String, key: String) -> void:
	backend_url = url
	api_key = key


func is_busy() -> bool:
	return _busy


func set_color(part: Node3D, hex: String) -> Dictionary:
	## hex: "#RRGGBB" to set, or "" to clear back to no backend override
	## (OccurrenceTransformUpdate.color's own None-omitted/""-clears
	## convention — see that field's own docstring in DIDSA-CAD). Returns
	## {"ok":, "error":}; applies the colour locally only once the backend
	## confirms it, so a rejected/failed PATCH never leaves the view lying
	## about what's actually stored.
	var ref := MeshIdentity.occurrence_ref_for(part)
	if ref.is_empty() or ref.get("occurrence_id", "") == "":
		return {"ok": false, "error": "Can't colour the assembly's own root content — laser-select a placed part first."}
	_busy = true
	var result := await _api_request(
		HTTPClient.METHOD_PATCH,
		"/parts/%s/occurrences/%s" % [ref["owner_part_id"], ref["occurrence_id"]],
		{"color": hex},
	)
	_busy = false
	if result["ok"]:
		_apply_local_color(part, hex)
	return {"ok": result["ok"], "error": result["error"]}


func _apply_local_color(part: Node3D, hex: String) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _hex_to_color(hex) if hex != "" else DEFAULT_MATERIAL_COLOR
	part.material_override = mat


static func _hex_to_color(hex: String) -> Color:
	## "#RRGGBB" -> Color, matching the backend's own straight 0-255 -> 0-1
	## channel scaling (mesh_export.py's _color_to_base_color_factor) with no
	## sRGB conversion — so this client-only preview renders the same shade
	## the backend's own glTF material would bake in on the next fetch.
	var digits := hex.lstrip("#")
	var r := digits.substr(0, 2).hex_to_int() / 255.0
	var g := digits.substr(2, 2).hex_to_int() / 255.0
	var b := digits.substr(4, 2).hex_to_int() / 255.0
	return Color(r, g, b, 1.0)


func _api_request(method: int, path: String, body_dict) -> Dictionary:
	## Same fresh-HTTPRequest-per-call pattern as mates_tool.gd's own
	## _api_request — see that function's docstring.
	var req := HTTPRequest.new()
	add_child(req)
	var headers := ["X-API-Key: %s" % api_key, "Content-Type: application/json"]
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
