extends SceneTree
## LOCAL REAL STORE (DIDSA-CAD `project-store/`), in `e2e_ci_list.txt`. S4 against the REAL store over the REAL HTTP transport, with the store SWITCHED OFF AND ON: this test starts
## its own store process (its own port and temp folder, so it can kill it), then
##   * a chunked upload of a 3 MB file (chunk 1 MB), the store killed part-way, started again on the same folder, and the upload RESUMES on the same session (the store's own
##     `received` decides; its sha-256 check passes; one version results);
##   * a store that is down when a save is made: queued, sent when it is back;
##   * two devices edit one file offline: the second is told, nothing is overwritten, Keep mine lands as the next version;
##   * the same cut with the app closed and opened again between the kill and the restart.
## It needs DIDSA_STORE_PROJECT_DIR (DIDSA-CAD's project-store/ folder) and DIDSA_STORE_PYTHON (a python with its requirements); tests/ci_e2e.sh sets them. Without them: SMOKE SKIPPED.
## Run by hand: DIDSA_STORE_PROJECT_DIR=../DIDSA-CAD/project-store DIDSA_STORE_PYTHON=python3 "$GODOT" --headless --path . --script res://tests/e2e_cloud_outage.gd
## NOT covered: a Cloudflare tunnel (the real 100 MB limit), a file anywhere near 100 MB (the sizes here are set so the chunking is exercised, not the limit), a headset.

const Rig := preload("res://tests/cloud_rig.gd")
const CloudHttpTransport := preload("res://scripts/cloud/cloud_http_transport.gd")
const CloudStoreClient := preload("res://scripts/cloud/cloud_store_client.gd")
const CloudProject := preload("res://scripts/cloud/cloud_project.gd")
const CloudState := preload("res://scripts/cloud/cloud_state.gd")
const CloudFiles := preload("res://scripts/cloud/cloud_files.gd")

const PORT := 8291
const KEY := "outage-test-key"
const MB := 1048576

var transport
var url := "http://127.0.0.1:%d" % PORT
var store_dir := ""
var python := ""
var data_root := ""
var pid := -1
var project_name := ""


class Device:
	extends RefCounted
	var name := ""
	var mirror := ""
	var state_dir := ""
	var client
	var project

	func local(path: String) -> String:
		return mirror.path_join(path)


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _initialize() -> void:
	store_dir = OS.get_environment("DIDSA_STORE_PROJECT_DIR")
	python = OS.get_environment("DIDSA_STORE_PYTHON")
	if store_dir == "" or python == "":
		print("SMOKE SKIPPED: needs DIDSA_STORE_PROJECT_DIR and DIDSA_STORE_PYTHON (tests/ci_e2e.sh sets them)")
		quit()
		return
	data_root = ProjectSettings.globalize_path("user://cloud_test/outage_store")
	Rig.wipe(data_root)
	DirAccess.make_dir_recursive_absolute(data_root)
	transport = CloudHttpTransport.new()
	root.add_child(transport)
	await process_frame
	project_name = "Outage-%d" % Time.get_ticks_msec()
	if not await _start_store():
		print("SMOKE SKIPPED: the throwaway store did not start (DIDSA_STORE_PROJECT_DIR=%s)" % store_dir)
		quit()
		return
	await _run()
	_stop_store()
	quit(0)


func _start_store() -> bool:
	var command := "cd '%s' && PROJECT_STORE_API_KEY='%s' PROJECT_STORE_ROOT='%s' exec '%s' -m uvicorn app.main:app --host 127.0.0.1 --port %d" % [store_dir, KEY, data_root, python, PORT]
	pid = OS.create_process("bash", ["-c", command])
	var probe := CloudStoreClient.new(transport, url, KEY, "Probe")
	for i in 40:
		await create_timer(0.5).timeout
		var health: Dictionary = await probe.health()
		if health["ok"]:
			return true
	return false


func _stop_store() -> void:
	if pid > 0:
		OS.kill(pid)
		pid = -1


func _store_down() -> bool:
	var probe := CloudStoreClient.new(transport, url, KEY, "Probe")
	var health: Dictionary = await probe.health()
	return health["kind"] == "unreachable"


func _device(device_name: String) -> Device:
	var d := Device.new()
	d.name = device_name
	var base := ProjectSettings.globalize_path("user://cloud_test/outage_%s" % device_name.replace(" ", "_"))
	Rig.wipe(base)
	d.mirror = base + "/mirror"
	d.state_dir = base + "/state"
	DirAccess.make_dir_recursive_absolute(d.mirror)
	d.client = CloudStoreClient.new(transport, url, KEY, device_name)
	_open(d)
	return d


func _open(d: Device) -> void:
	d.project = CloudProject.new(d.client, project_name, d.mirror, CloudState.open(d.state_dir))
	d.project.held_provider = func() -> Array: return []
	d.project.chunk_threshold = 2 * MB # (real values: 90 MB and 32 MB)
	d.project.chunk_bytes = MB


func _blob(tag: int, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(size)
	for i in size:
		out[i] = (i * 31 + tag) & 255
	return out


func _write(d: Device, path: String, bytes: PackedByteArray) -> void:
	CloudFiles.write_bytes_atomic(d.local(path), bytes)


func _store_json(path: String) -> Dictionary:
	var probe := CloudStoreClient.new(transport, url, KEY, "Probe")
	var answer: Dictionary = await probe._call("GET", path)
	return answer


func _run() -> void:
	var probe := CloudStoreClient.new(transport, url, KEY, "Probe")
	var health: Dictionary = await probe.health()
	_check(health["ok"] and "uploads.chunked" in health["json"].get("api_features", []), "the real store lists uploads.chunked")
	var made: Dictionary = await probe.create_project(project_name)
	_check(made["ok"], "a project is created")

	# --- a chunked upload, the store killed part-way, started again
	var a := _device("Quest 3")
	var big := _blob(3, 3 * MB)
	_write(a, "Big.didsa", big)
	var done_sync := [false]
	var report_holder := [{}]
	var runner := func() -> void:
		report_holder[0] = await a.project.sync()
		done_sync[0] = true
	runner.call()
	# let the first chunk land, then kill the store
	for i in 400:
		await create_timer(0.02).timeout
		var sessions: Dictionary = await _store_json("/projects/%s/uploads/%s" % [project_name, str(a.project.state.uploads.get("Big.didsa", {}).get("id", "none"))])
		if sessions["ok"] and int(sessions["json"].get("received", 0)) >= MB:
			break
	_stop_store()
	while not done_sync[0]:
		await create_timer(0.1).timeout
	var report: Dictionary = report_holder[0]
	_check(not report["reachable"] and a.project.state.queue.has("Big.didsa") and a.project.state.uploads.has("Big.didsa"), "the real store killed mid-upload: the save is queued and the upload session remembered")
	var session_id := str(a.project.state.uploads["Big.didsa"]["id"])
	_check(await _store_down(), "...the store is really off")
	_check(await _start_store(), "the store is started again on the same folder")
	var status: Dictionary = await _store_json("/projects/%s/uploads/%s" % [project_name, session_id])
	var had := int(status["json"].get("received", -1)) if status["ok"] else -1
	_check(status["ok"] and had >= MB and had < 3 * MB, "...it kept the chunks it had (%d of %d bytes) across the restart" % [had, 3 * MB])
	report = await a.project.sync()
	var got: Dictionary = await probe.get_file(project_name, "Big.didsa")
	_check(report["sent"] == ["Big.didsa"] and got["ok"] and CloudFiles.hash_bytes(got["body"]) == CloudFiles.hash_bytes(big) and got["version"] == 1, "the upload resumed and the store has the file byte for byte, as version 1")
	var tree: Dictionary = await probe.tree(project_name)
	_check(tree["ok"] and tree["json"]["files"].size() == 1, "...and nothing else (no duplicate file)")

	# --- the store is off when a save is made, and on again later
	_write(a, "Small.didsa", "small file".to_utf8_buffer())
	_stop_store()
	await create_timer(0.5).timeout
	report = await a.project.sync(true)
	_check(not report["reachable"] and a.project.state.queue.has("Small.didsa"), "a save made while the store is off is queued")
	_check(await _start_store(), "...store on again")
	report = await a.project.sync(true)
	_check(report["sent"] == ["Small.didsa"] and a.project.state.queue.is_empty(), "...and sent")

	# --- two devices offline on the same file
	var b := _device("Phone")
	await b.project.sync()
	await b.project.ensure_file("Small.didsa")
	_write(a, "Small.didsa", "from the Quest".to_utf8_buffer())
	_write(b, "Small.didsa", "from the Phone".to_utf8_buffer())
	_stop_store()
	await create_timer(0.5).timeout
	await a.project.sync(true)
	await b.project.sync(true)
	_check(a.project.state.queue.has("Small.didsa") and b.project.state.queue.has("Small.didsa"), "both devices saved the same file while the store was off: both queued")
	_check(await _start_store(), "...store on again")
	await a.project.sync(true)
	report = await b.project.sync(true)
	var current: Dictionary = await probe.get_file(project_name, "Small.didsa")
	_check(current["ok"] and current["body"].get_string_from_utf8() == "from the Quest" and not report["conflicts"].is_empty(), "the first back wins; the second is told, and nothing was overwritten on the store")
	await b.project.resolve({"Small.didsa": CloudProject.KEEP_MINE})
	await b.project.sync(true)
	current = await probe.get_file(project_name, "Small.didsa")
	_check(current["body"].get_string_from_utf8() == "from the Phone" and current["version"] == 3, "Keep mine lands the Phone's file as the next version (the Quest's stays in the store's history)")

	# --- the app closed and opened again between the kill and the restart
	var c := _device("Tablet")
	var big2 := _blob(7, 3 * MB)
	_write(c, "Big2.didsa", big2)
	done_sync[0] = false
	runner = func() -> void:
		report_holder[0] = await c.project.sync()
		done_sync[0] = true
	runner.call()
	for i in 400:
		await create_timer(0.02).timeout
		var s2: Dictionary = await _store_json("/projects/%s/uploads/%s" % [project_name, str(c.project.state.uploads.get("Big2.didsa", {}).get("id", "none"))])
		if s2["ok"] and int(s2["json"].get("received", 0)) >= MB:
			break
	_stop_store()
	while not done_sync[0]:
		await create_timer(0.1).timeout
	_open(c) # the app is closed and opened again: a new CloudProject over the same private state
	_check(c.project.state.uploads.has("Big2.didsa"), "the half-sent upload is in the private state on disk")
	_check(await _start_store(), "...store on again")
	await c.project.sync(true)
	var got2: Dictionary = await probe.get_file(project_name, "Big2.didsa")
	_check(got2["ok"] and CloudFiles.hash_bytes(got2["body"]) == CloudFiles.hash_bytes(big2), "a reopened app resumes the half-sent upload and the store has the file intact")
