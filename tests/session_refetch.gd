extends SceneTree
## The observer's whole-model refetch (session_observer._refetch_all) against a slow fetch: the bytes that come back belong to the model it asked for. If the session ended
## or another model came in while it was fetched, nothing of them is shown, indexed, made visible or placed (and a failed fetch of the old one is not reported either).
## A stub observer (the fetch and what follows it are counted, no scene, no hub). NOT covered: a real hub or backend (tests/e2e_session_observer.gd).
## Run: "$GODOT" --headless --path . --script res://tests/session_refetch.gd  (see tests/README.md)


class FakeMain extends Node:
	var shown: Array = []
	var placed := 0

	func session_show_model(_bytes: PackedByteArray, same_document: bool = false) -> bool:
		shown.append(same_document)
		return true

	func session_apply_place(_place) -> void:
		placed += 1


class StubObserver extends "res://scripts/session/session_observer.gd":
	var gate := false
	var fetch_ok := true
	var indexed := 0
	var visibility := 0
	var sections := 0

	func _fetch_glb(_part_id: String, _model: Dictionary) -> Dictionary:
		while not gate:
			await Engine.get_main_loop().process_frame
		return {"ok": fetch_ok, "changed": true, "bytes": PackedByteArray([1, 2, 3]), "error": "boom"}

	func _index() -> void:
		indexed += 1

	func _apply_visibility(_arg: bool = false) -> void:
		visibility += 1

	func _apply_section() -> void:
		sections += 1


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func frames(n: int = 3) -> void:
	for i in n:
		await process_frame


func fresh() -> Array:
	var fake := FakeMain.new()
	var obs := StubObserver.new()
	obs.main = fake
	obs.active = true
	obs.model_source = {"kind": "backend", "root_part_id": "R", "path": ""}
	root.add_child(fake)
	root.add_child(obs)
	return [obs, fake]


func untouched(obs, fake) -> bool:
	return fake.shown.is_empty() and fake.placed == 0 and obs.indexed == 0 and obs.visibility == 0 and obs.sections == 0 and obs.last_error == ""


func _initialize() -> void:
	var pair := fresh()
	var obs = pair[0]
	var fake = pair[1]
	obs._refetch_all()
	await frames(2)
	obs.gate = true
	await frames(3)
	check("(setup) a refetch of the model still shown is shown once, as the same document, then indexed and made visible", fake.shown == [true] and obs.indexed == 1 and obs.visibility == 1 and obs.sections == 1)
	obs.queue_free()
	fake.queue_free()

	pair = fresh()
	obs = pair[0]
	fake = pair[1]
	obs._refetch_all()
	await frames(2)
	obs.active = false # (the session ended while the model was being fetched)
	obs.gate = true
	await frames(3)
	check("2. the session ended while the bytes were on the way: nothing shown, indexed, made visible or placed", untouched(obs, fake))
	obs.queue_free()
	fake.queue_free()

	pair = fresh()
	obs = pair[0]
	fake = pair[1]
	obs._have_place = true
	obs._refetch_all()
	await frames(2)
	obs.model_source = {"kind": "backend", "root_part_id": "OTHER", "path": ""} # (another model came in)
	obs.gate = true
	await frames(3)
	check("2. another model came in meanwhile: the old document's bytes are dropped (no show, index, visibility or placement)", untouched(obs, fake))
	obs.queue_free()
	fake.queue_free()

	pair = fresh()
	obs = pair[0]
	fake = pair[1]
	obs.fetch_ok = false
	obs._refetch_all()
	await frames(2)
	obs.model_source = {"kind": "backend", "root_part_id": "OTHER", "path": ""}
	obs.gate = true
	await frames(3)
	check("2. ...and a failed fetch of the old model is not reported against the new one", untouched(obs, fake))
	obs.queue_free()
	fake.queue_free()
	await frames(2)
	quit(0)
