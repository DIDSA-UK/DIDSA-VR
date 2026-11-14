extends SceneTree
## LOCAL REAL STORE (DIDSA-CAD `project-store/`), in `e2e_ci_list.txt`; tests/ci_e2e.sh starts a throwaway store when DIDSA_STORE_URL is not set. S3 (server projects) against the
## REAL thing instead of tests/fake_project_store.gd: the real HTTP transport (cloud_http_transport.gd) and the sync layer (scripts/cloud/) with two "devices" (two mirrors, two
## private states, two device names) on one project: create, read, a versioned write, the change feed refreshing the other device, a stale write refused and settled by Keep mine,
## Save All as ONE commit and a real 409 that writes nothing, Take theirs and Save as a copy (the copy found by the store's part index under its NEW Part id), the moved-files
## lookup through GET .../parts, a deleted file as a clash, an unreachable store queueing and the reconnect, a wrong key (401), a refused name (400), and a file dropped into the mirror.
## Run by hand: DIDSA_STORE_URL=http://127.0.0.1:8200 DIDSA_STORE_KEY=dev "$GODOT" --headless --path . --script res://tests/e2e_cloud_store.gd
## (cd ../DIDSA-CAD/project-store && PROJECT_STORE_API_KEY=dev PROJECT_STORE_ROOT=/tmp/store python -m uvicorn app.main:app --port 8200; one worker).
## NOT covered: a Raspberry Pi, a Cloudflare tunnel (the 100 MB limit), a synced Drive / NAS root, a 413 (the store's limit is 200 MB; the status is tests/cloud_sync.gd's), a headset.

const Rig := preload("res://tests/cloud_rig.gd")
const CloudHttpTransport := preload("res://scripts/cloud/cloud_http_transport.gd")
const CloudStoreClient := preload("res://scripts/cloud/cloud_store_client.gd")
const CloudProject := preload("res://scripts/cloud/cloud_project.gd")
const CloudState := preload("res://scripts/cloud/cloud_state.gd")
const CloudFiles := preload("res://scripts/cloud/cloud_files.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")

var url := ""
var key := ""
var transport
var project_name := ""


class Device:
	extends RefCounted
	var name := ""
	var mirror := ""
	var project
	var client
	var state_dir := ""
	var held: Array = []

	func local(path: String) -> String:
		return mirror.path_join(path)

	func write(path: String, text: String) -> void:
		CloudFiles.write_bytes_atomic(local(path), text.to_utf8_buffer())

	func read(path: String) -> String:
		return FileAccess.get_file_as_string(local(path))


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _device(device_name: String, store_key: String = "") -> Device:
	var d := Device.new()
	d.name = device_name
	var base := ProjectSettings.globalize_path("user://cloud_test/e2e_%s_%s" % [project_name, device_name.replace(" ", "_")])
	Rig.wipe(base)
	d.mirror = base + "/mirror"
	d.state_dir = base + "/state"
	DirAccess.make_dir_recursive_absolute(d.mirror)
	d.client = CloudStoreClient.new(transport, url, key if store_key == "" else store_key, device_name)
	d.project = CloudProject.new(d.client, project_name, d.mirror, CloudState.open(d.state_dir))
	d.project.held_provider = func() -> Array: return d.held
	return d


func _restart(d: Device) -> void:
	d.project = CloudProject.new(d.client, project_name, d.mirror, CloudState.open(d.state_dir))
	d.project.held_provider = func() -> Array: return d.held


func _initialize() -> void:
	url = OS.get_environment("DIDSA_STORE_URL")
	key = OS.get_environment("DIDSA_STORE_KEY")
	if url == "" or key == "":
		print("SMOKE SKIPPED: needs DIDSA_STORE_URL and DIDSA_STORE_KEY (a running DIDSA-CAD project-store; tests/ci_e2e.sh starts one)")
		quit()
		return
	transport = CloudHttpTransport.new()
	root.add_child(transport)
	await process_frame
	project_name = "E2E-%d" % Time.get_ticks_msec()
	await _run()
	quit(0)


func _run() -> void:
	var probe := CloudStoreClient.new(transport, url, key, "Probe")
	var health: Dictionary = await probe.health()
	_check(health["ok"] and "files.if_match" in health["json"].get("api_features", []) and "commit.all_or_nothing" in health["json"].get("api_features", []), "the real store answers /health with the features S3 needs")
	var made: Dictionary = await probe.create_project(project_name)
	var listed: Dictionary = await probe.list_projects()
	_check(made["ok"] and listed["json"]["projects"].any(func(p: Dictionary) -> bool: return p["name"] == project_name), "a project is created and listed")
	var again: Dictionary = await probe.create_project(project_name)
	_check(not again["ok"] and again["kind"] == "conflict", "...a name that is taken is a 409")

	var a := _device("Quest 3")
	var b := _device("Desktop")

	# --- a file created on A, read on B
	a.write("Shaft.didsa", Rig.native("p-shaft", "v1"))
	var report: Dictionary = await a.project.sync()
	_check(report["sent"] == ["Shaft.didsa"] and report["reachable"] and a.project.state.files["Shaft.didsa"]["version"] == 1, "a new file in A's mirror is created on the real store (If-None-Match), version 1")
	await b.project.sync()
	var got: Dictionary = await b.project.ensure_file("Shaft.didsa")
	_check(got["ok"] and got["downloaded"] and b.read("Shaft.didsa") == a.read("Shaft.didsa") and b.project.state.files["Shaft.didsa"]["version"] == 1, "B's first sync lists it and opening it downloads the same bytes at version 1")
	_check(b.project.state.tree["Shaft.didsa"]["modified_by"] == "Quest 3" and b.project.state.tree["Shaft.didsa"]["part_id"] == "p-shaft", "...with who made it (X-Device-Name) and the store's own Part id")

	# --- a versioned write, and the feed refreshing the other device
	b.write("Shaft.didsa", Rig.native("p-shaft", "v2 from the desktop"))
	report = await b.project.sync()
	_check(report["sent"] == ["Shaft.didsa"] and b.project.state.files["Shaft.didsa"]["version"] == 2, "an edit is a PUT with If-Match: version 2")
	report = await a.project.sync()
	_check(report["refreshed"] == ["Shaft.didsa"] and a.read("Shaft.didsa") == b.read("Shaft.didsa") and a.project.state.files["Shaft.didsa"]["version"] == 2, "the change feed refreshes A's copy of a file B changed")
	report = await a.project.sync()
	_check(report["sent"].is_empty() and report["refreshed"].is_empty() and report["conflicts"].is_empty(), "a quiet sync does nothing")

	# --- a clash through the real feed, settled by Keep mine
	a.write("Shaft.didsa", Rig.native("p-shaft", "A's edit"))
	b.write("Shaft.didsa", Rig.native("p-shaft", "B's edit"))
	await b.project.sync()
	report = await a.project.sync()
	_check(report["conflicts"].size() == 1 and report["conflicts"][0]["clash"]["modified_by"] == "Desktop" and report["conflicts"][0]["text"].begins_with("Changed by Desktop on "), "A's stale save is a clash naming who changed it: %s" % str(report["conflicts"][0]["text"] if not report["conflicts"].is_empty() else ""))
	var kept: Dictionary = await a.project.resolve({"Shaft.didsa": CloudProject.KEEP_MINE})
	report = await a.project.sync()
	_check(kept["ok"] and report["sent"] == ["Shaft.didsa"] and a.project.state.files["Shaft.didsa"]["version"] == 4, "Keep mine writes mine as the next version over theirs (4)")
	var history: Dictionary = await _versions("Shaft.didsa")
	_check(history["versions"].size() == 4 and history["versions"][0]["by"] == "Quest 3" and history["versions"][1]["by"] == "Desktop", "...and theirs stays in the store's history")
	await b.project.sync()
	_check(b.read("Shaft.didsa") == a.read("Shaft.didsa"), "B follows")

	# --- Save All: one commit, and a real 409 that writes nothing
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		a.write(f, Rig.native("p-" + f, "v1"))
	report = await a.project.sync()
	_check(report["sent"].size() == 3 and a.project.state.files["a.didsa"]["version"] == 1, "three new files go as one commit")
	await b.project.sync()
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		await b.project.ensure_file(f)
		a.write(f, Rig.native("p-" + f, "A v2"))
	a.project.scan()
	b.write("b.didsa", Rig.native("p-b.didsa", "B v2"))
	await b.project.sync() # B's b.didsa is version 2 before A tries
	var refused: Dictionary = await a.project._send_commit(["a.didsa", "b.didsa", "c.didsa"]) # (straight to the commit: the feed would have flagged b first)
	var tree := await _tree()
	var by_path := {}
	for f in tree["files"]:
		by_path[f["path"]] = f
	_check(refused.has("error") and by_path["a.didsa"]["version"] == 1 and by_path["c.didsa"]["version"] == 1 and by_path["b.didsa"]["version"] == 2, "a real commit 409 writes NOTHING: the files that did not clash are still version 1")
	_check(a.project.state.queue["b.didsa"]["clash"] != null and a.project.state.queue["a.didsa"]["clash"] == null and a.project.state.queue["b.didsa"]["clash"]["modified_by"] == "Desktop", "...and only the clashing one is flagged, naming Desktop")
	await a.project.resolve({"b.didsa": CloudProject.KEEP_MINE})
	report = await a.project.sync()
	_check(report["sent"].size() == 3 and (await _tree())["files"].filter(func(f: Dictionary) -> bool: return f["path"] in ["a.didsa", "c.didsa"] and f["version"] == 2).size() == 2, "after resolving, the retry sends all three as one commit")

	# --- Take theirs, then Save mine as a copy (a new Part id the store's index finds)
	a.write("Shaft.didsa", Rig.native("p-shaft", "A wants this", [{"ref": "Pin.didsa", "id": "p-pin"}]))
	b.write("Shaft.didsa", Rig.native("p-shaft", "B's later"))
	await b.project.sync()
	report = await a.project.sync()
	var theirs: Dictionary = await a.project.resolve({"Shaft.didsa": CloudProject.SAVE_COPY})
	var copy_path: String = theirs["copies"].get("Shaft.didsa", "")
	await a.project.sync()
	var copy_id := str(JSON.parse_string(a.read(copy_path))["document"]["root_part_id"]) if copy_path != "" else ""
	var by_id: Dictionary = await probe.parts(project_name, copy_id)
	_check(copy_path.begins_with("Shaft (Quest 3, ") and copy_id != "p-shaft" and by_id["json"]["files"].size() == 1 and by_id["json"]["files"][0]["path"] == copy_path, "Save mine as a copy: '%s', indexed by the real store under its NEW Part id" % copy_path)
	_check(a.read("Shaft.didsa") == b.read("Shaft.didsa"), "...and the original is theirs")
	a.write("Shaft.didsa", Rig.native("p-shaft", "A once more"))
	b.write("Shaft.didsa", Rig.native("p-shaft", "B once more"))
	await b.project.sync()
	await a.project.sync()
	var mine: String = a.read("Shaft.didsa")
	var took: Dictionary = await a.project.resolve({"Shaft.didsa": CloudProject.TAKE_THEIRS})
	_check(took["ok"] and a.read("Shaft.didsa") == b.read("Shaft.didsa") and a.project.state.get_mine("Shaft.didsa").get_string_from_utf8() == mine, "Take theirs loads theirs and keeps mine locally")

	# --- the moved-files rule through the real part index
	var asm := Rig.native("p-asm", "", [{"ref": "Gear.didsa", "id": "p-gear"}])
	a.write("Asm.didsa", asm)
	a.write("parts/Gear.didsa", Rig.native("p-gear", "moved into parts"))
	await a.project.sync()
	await b.project.sync()
	var opened: Dictionary = await b.project.prepare_open("Asm.didsa")
	var composed: Dictionary = NativeCompose.compose(b.local("Asm.didsa"), [b.mirror])
	_check(opened["ok"] and FileAccess.file_exists(b.local("parts/Gear.didsa")) and composed["ok"] and composed["unresolved"].is_empty() and composed["relinked"].size() == 1 and composed["relinked"][0]["via"] == "id", "a moved Part is found through GET .../parts/{id} and native_compose.gd, reading the mirror unchanged, relinks it by id")

	# --- a file deleted on the store is a clash for a save
	b.write("b.didsa", Rig.native("p-b.didsa", "B edits before the delete"))
	var gone: Dictionary = await transport.request("DELETE", url + CloudStoreClient.file_path(project_name, "b.didsa"), {"X-API-Key": key, "X-Device-Name": "Phone", "If-Match": "\"%d\"" % int((await _tree())["files"].filter(func(f: Dictionary) -> bool: return f["path"] == "b.didsa")[0]["version"])}, PackedByteArray())
	_check(int(gone["status"]) == 200, "(the file is deleted on the store by another device)")
	report = await b.project.sync()
	_check(report["conflicts"].size() == 1 and report["conflicts"][0]["clash"]["deleted"] and report["conflicts"][0]["text"].begins_with("Deleted by Phone"), "a save of a file deleted elsewhere is a clash: %s" % str(report["conflicts"][0]["text"] if not report["conflicts"].is_empty() else ""))
	await b.project.resolve({"b.didsa": CloudProject.KEEP_MINE})
	report = await b.project.sync()
	_check(report["sent"] == ["b.didsa"] and (await _tree())["files"].any(func(f: Dictionary) -> bool: return f["path"] == "b.didsa"), "Keep mine writes it back at the old path")

	# --- dropped in by hand, and a delete by hand is not a delete on the store
	b.write("notes/readme.txt", "dropped in by hand")
	DirAccess.remove_absolute(b.local("c.didsa"))
	report = await b.project.sync()
	var after: Dictionary = await _tree()
	_check(after["files"].any(func(f: Dictionary) -> bool: return f["path"] == "notes/readme.txt") and after["files"].any(func(f: Dictionary) -> bool: return f["path"] == "c.didsa"), "a file dropped into the mirror is created on the store; one removed by hand is NOT deleted there")

	# --- offline: queued, then the reconnect asks the feed first and sends
	var c := _device("Offline Phone")
	await c.project.sync()
	await c.project.ensure_file("Asm.didsa")
	var real_client = c.client
	c.client = CloudStoreClient.new(transport, "http://127.0.0.1:1", key, "Offline Phone")
	c.project.client = c.client
	c.write("Asm.didsa", Rig.native("p-asm", "edited offline", [{"ref": "Gear.didsa", "id": "p-gear"}]))
	report = await c.project.sync()
	_check(not report["reachable"] and c.project.state.queue.has("Asm.didsa") and c.project.summary()["symbol"] == "offline", "an unreachable store (a refused connection) queues the save, never loses it")
	c.project.client = real_client
	c.client = real_client
	_restart(c)
	_check(c.project.state.queue.has("Asm.didsa"), "...the queue survives a restart")
	report = await c.project.sync()
	_check(report["sent"] == ["Asm.didsa"] and report["reachable"], "...and goes when the store is back")

	# --- a wrong key is a 401 that names the key; a refused name is a 400 with the store's words
	var d := _device("Wrong Key", "not-the-key")
	d.write("X.didsa", Rig.native("p-x", ""))
	report = await d.project.sync()
	_check(report["error"].contains("refused the key") and d.project.state.queue.has("X.didsa"), "a wrong key is a 401 that names the key, and the save stays queued")
	var e := _device("Bad Name")
	e.write("bad:name.didsa", Rig.native("p-bad", ""))
	await e.project.sync()
	report = await e.project.sync(true)
	_check(report["error"] != "" and e.project.state.queue.has("bad:name.didsa") and e.project.problems.has("bad:name.didsa"), "a name the store refuses (400) shows the store's own words and keeps the save: '%s'" % report["error"].left(120))
	e.project.keep_local_only("bad:name.didsa")
	report = await e.project.sync()
	_check(e.project.state.queue.is_empty() and e.project.file_state("bad:name.didsa") == "local_only", "...and Keep local only stops trying")


func _tree() -> Dictionary:
	var c := CloudStoreClient.new(transport, url, key, "Checker")
	var answer: Dictionary = await c.tree(project_name)
	return answer["json"]


func _versions(path: String) -> Dictionary:
	var answer: Dictionary = await transport.request("GET", url + CloudStoreClient.file_path(project_name, path) + "/versions", {"X-API-Key": key}, PackedByteArray())
	return JSON.parse_string((answer["body"] as PackedByteArray).get_string_from_utf8())
