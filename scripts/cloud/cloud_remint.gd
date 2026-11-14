extends RefCounted
## GDScript twin of DIDSA-CAD's `client/lib/assembly/remint_identity.dart` (and the backend's remint_identity.py): a native file with a fresh document id, a fresh Part
## id for every Part and a fresh id for every sketch, every reference to one of them following. VR had no Save As remint (its "Save as new file" writes a whole-session
## snapshot, and project_save.gd gives a NEW Part a new file, never a copy of an old one), so S3's "Save mine as a copy" needs this: a copy that kept the Part id would
## make the moved-files rule find two files with one id and ask every time.
##
## References are found by walking the whole JSON tree and replacing every string VALUE exactly equal to an old id (UUIDs are unique strings, so an exact match is never a
## false positive); object KEYS are left alone. The file is read with NativeCompose.parse_exact and written with to_json, so every number comes back exactly as written
## (the float trap: 0 stays 0, 20.0 stays 20.0) and nothing else in the file changes.

const NativeCompose := preload("res://scripts/native_compose.gd")


static func collect_ids(payload: Dictionary) -> Array:
	## document.id, each Part id and each sketch id (the session-global ones; feature, entity and point ids are scoped to their Part or sketch and stay).
	var ids: Array = []
	var document = payload.get("document")
	if document is Dictionary:
		if document.get("id") is String:
			ids.append(document["id"])
		if document.get("parts") is Array:
			for part in document["parts"]:
				if part is Dictionary and part.get("id") is String:
					ids.append(part["id"])
	if payload.get("sketches") is Array:
		for sketch in payload["sketches"]:
			if sketch is Dictionary and sketch.get("id") is String:
				ids.append(sketch["id"])
	return ids


static func remint_text(text: String, make_id: Callable = Callable()) -> String:
	## `text` with new identity, or `text` unchanged when it is not a native file (a glb, a STEP file, anything that isn't JSON with a `document`).
	var parsed = NativeCompose.parse_exact(text)
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("document") is Dictionary):
		return text
	var mapping := {}
	for old in collect_ids(parsed):
		mapping[old] = make_id.call() if make_id.is_valid() else new_uuid()
	return NativeCompose.to_json(_replace(parsed, mapping))


static func remint_bytes(bytes: PackedByteArray, make_id: Callable = Callable()) -> PackedByteArray:
	var text := bytes.get_string_from_utf8()
	var out := remint_text(text, make_id)
	return bytes if out == text else out.to_utf8_buffer()


static func _replace(node, mapping: Dictionary):
	match typeof(node):
		TYPE_STRING:
			return mapping.get(node, node)
		TYPE_ARRAY:
			var items := []
			for item in node:
				items.append(_replace(item, mapping))
			return items
		TYPE_DICTIONARY:
			var out := {}
			for key in node:
				out[key] = _replace(node[key], mapping) # keys are left alone
			return out
		_:
			return node # a number read by parse_exact is a StringName: kept as it is


static func new_uuid() -> String:
	## A random (version 4) UUID.
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var hex := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12)]
