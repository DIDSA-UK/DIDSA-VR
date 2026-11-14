extends Node
## S3: the server projects of this headset, as the rest of the app sees them (main.gd owns one). It holds the store's address and key (from the current server entry:
## servers.cfg, or secrets.cfg's [project_store]), this device's name, the real HTTP transport and one CloudProject per project opened; says where the mirror is (one
## setting, with the fallback and the reason); lists the store's projects; opens a project or a file of it (a sync, then the downloads native_compose.gd needs); syncs the active
## project on a timer while it is open and on "Sync now"; and tells the landing and the Files page what is waiting, from the saved sync states, with no network.
## Nothing here draws anything: tablet_pages.gd, launcher_window.gd and main.gd call it.

const CloudPaths := preload("res://scripts/cloud/cloud_paths.gd")
const CloudState := preload("res://scripts/cloud/cloud_state.gd")
const CloudProject := preload("res://scripts/cloud/cloud_project.gd")
const CloudStoreClient := preload("res://scripts/cloud/cloud_store_client.gd")
const CloudHttpTransport := preload("res://scripts/cloud/cloud_http_transport.gd")

const SYNC_SECONDS := 20.0 ## while a server project is open (the flat app's interval)

signal changed ## what the screens show may have changed (a list, a sync, a choice)
signal message(text: String) ## a line for the status bar

var settings: RefCounted ## AppSettings (cloud_folder, device_name)
var transport: Object ## cloud_http_transport.gd, or a fake in tests
var store_url := ""
var store_key := ""
var on_android := func() -> bool: return OS.has_feature("android")
var all_files_granted := func() -> bool: return false
var held_provider := Callable() ## () -> Array of ABSOLUTE paths the open session was composed from
var state_root := "" ## tests: another private folder ("" = CloudPaths.state_root())
var remote_projects: Array = [] ## the store's last answer: [{name, file_count, total_size, last_change, last_device}]
var remote_error := ""
var remote_listed := false
var active: CloudProject
var _projects := {}
var _timer: Timer


func _ready() -> void:
	if transport == null:
		var real := CloudHttpTransport.new()
		add_child(real)
		transport = real
	_timer = Timer.new()
	_timer.wait_time = SYNC_SECONDS
	_timer.one_shot = false
	_timer.timeout.connect(_on_timer)
	add_child(_timer)


# --- configuration ------------------------------------------------------------------------------------------------------------------------

func configure(url: String, key: String) -> void:
	## The store this headset uses now ("" = none). A different store drops the open projects (their sync states stay on disk).
	url = url.strip_edges().trim_suffix("/")
	key = key.strip_edges()
	if url == store_url and key == store_key:
		return
	var other_store := url != store_url
	store_url = url
	store_key = key
	if other_store:
		_projects.clear()
		active = null
		remote_projects = []
		remote_listed = false
		remote_error = ""
		if _timer != null:
			_timer.stop()
	else:
		for name in _projects:
			(_projects[name] as CloudProject).client.api_key = key
	changed.emit()


func _arm() -> void:
	if _timer != null:
		_timer.start()


func is_configured() -> bool:
	return store_url != "" and store_key != ""


func device_name() -> String:
	var chosen: String = "" if settings == null else str(settings.device_name).strip_edges()
	return chosen if chosen != "" else default_device_name()


static func default_device_name() -> String:
	## The platform's name for this device ("Quest 3" when Android says so), never anything that identifies a person.
	var model := OS.get_model_name()
	if model != "" and model != "GenericDevice":
		return model.substr(0, 40)
	return OS.get_name()


func root_info() -> Dictionary:
	## {path, fallback, note}: where the mirrors live (CloudPaths.resolve_root).
	return CloudPaths.resolve_root("" if settings == null else str(settings.cloud_folder), bool(on_android.call()), bool(all_files_granted.call()))


func root_changed() -> void:
	## The folder setting changed: the open projects are re-made over the new folder at their next use (their private sync states stay). Files already in the old folder
	## are NOT moved (they stay there, and the next sync downloads what the new folder lacks).
	_projects.clear()
	active = null
	changed.emit()


# --- the size of the local copies (S4) ----------------------------------------------------------------------------------------------------

func cache_limit_bytes() -> int:
	## 0 = no limit. AppSettings.cloud_cache_mb (default 2048).
	return 0 if settings == null else maxi(0, int(settings.cloud_cache_mb)) * 1048576


func cache_used_bytes() -> int:
	var total := 0
	for name in known_projects():
		total += project(str(name)).local_bytes()
	return total


func cleanup_cache(limit_bytes: int = -1) -> Dictionary:
	## Removes the least recently used CLEAN local copies (all projects together) until the total fits the limit. {used, limit, freed, removed: [[project, path]], over: bool}
	## `over` is true when the limit is still exceeded because what is left is not allowed to go (a save waiting, a clash, an open file, a file only here). `limit_bytes` -1:
	## the setting; 0: no limit, nothing removed. A synced file removed here is fetched again the next time it is opened.
	var limit := cache_limit_bytes() if limit_bytes < 0 else limit_bytes
	var used := cache_used_bytes()
	var out := {"used": used, "limit": limit, "freed": 0, "removed": [], "over": false}
	if limit <= 0 or used <= limit:
		return out
	var all: Array = []
	for name in known_projects():
		all.append_array(project(str(name)).eviction_candidates())
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["used_ms"]) < int(b["used_ms"]))
	var touched := {}
	for item in all:
		if used <= limit:
			break
		var p: CloudProject = project(str(item["project"]))
		if p.evict(str(item["path"])):
			used -= int(item["bytes"])
			out["freed"] += int(item["bytes"])
			(out["removed"] as Array).append([item["project"], item["path"]])
			touched[item["project"]] = true
	for name in touched:
		project(str(name)).state.save()
	out["used"] = used
	out["over"] = used > limit
	if not (out["removed"] as Array).is_empty():
		changed.emit()
	return out


func mirror_path(project_name: String) -> String:
	return CloudPaths.mirror_dir(str(root_info()["path"]), store_url, project_name)


func _state_dir(project_name: String) -> String:
	return CloudPaths.state_dir(store_url, project_name, state_root)


# --- projects -----------------------------------------------------------------------------------------------------------------------------

func project(project_name: String) -> CloudProject:
	if _projects.has(project_name):
		return _projects[project_name]
	var client := CloudStoreClient.new(transport, store_url, store_key, device_name())
	var state := CloudState.open(_state_dir(project_name))
	state.store_url = store_url
	state.project = project_name
	var p := CloudProject.new(client, project_name, mirror_path(project_name), state)
	p.held_provider = func() -> Array:
		var out: Array = []
		if held_provider.is_valid():
			for full in held_provider.call():
				var rel := CloudPaths.relative(p.mirror_dir, str(full))
				if rel != "":
					out.append(rel)
		return out
	p.changed.connect(func() -> void: changed.emit())
	_projects[project_name] = p
	return p


func refresh_projects() -> Dictionary:
	## Asks the store for its projects. {ok, error}. Offline: the projects this headset already knows (known_projects()) stay listed.
	if not is_configured():
		remote_error = "No project store is set up for this server (Servers page)."
		changed.emit()
		return {"ok": false, "error": remote_error}
	var client := CloudStoreClient.new(transport, store_url, store_key, device_name())
	var answer: Dictionary = await client.list_projects()
	remote_listed = true
	if answer["ok"]:
		remote_projects = answer["json"].get("projects", [])
		remote_error = ""
	elif answer["kind"] == "unreachable":
		remote_error = "The project store can't be reached; showing the projects saved on this headset."
	elif answer["kind"] == "auth":
		remote_error = "The project store refused the key. Check the store key under Servers."
	else:
		remote_error = str(answer["message"])
	changed.emit()
	return {"ok": answer["ok"], "error": remote_error}


func known_projects() -> Array:
	## Names of the projects this headset has a saved sync state for, on the current store (no network), sorted.
	var names: Array = []
	var base := state_root if state_root != "" else CloudPaths.state_root()
	var dir := DirAccess.open(base)
	if dir != null:
		for sub in dir.get_directories():
			var state := CloudState.open(base.path_join(sub))
			if state.project != "" and state.store_url == store_url and not names.has(state.project):
				names.append(state.project)
	for name in _projects:
		if not names.has(name):
			names.append(name)
	names.sort()
	return names


func all_project_names() -> Array:
	## The store's projects (when listed) and the ones saved here, without duplicates, sorted.
	var names: Array = []
	for p in remote_projects:
		names.append(str(p["name"]))
	for name in known_projects():
		if not names.has(name):
			names.append(name)
	names.sort()
	return names


func create_project(project_name: String) -> Dictionary:
	if not is_configured():
		return {"ok": false, "error": "No project store is set up for this server (Servers page)."}
	var client := CloudStoreClient.new(transport, store_url, store_key, device_name())
	var answer: Dictionary = await client.create_project(project_name)
	if not answer["ok"]:
		return {"ok": false, "error": "The project store: %s" % answer["message"]}
	await refresh_projects()
	return {"ok": true, "error": ""}


func open_project(project_name: String) -> Dictionary:
	## Makes it the active project (the timer syncs it) and syncs it now. The sync report, plus `text`.
	var p := project(project_name)
	active = p
	_arm()
	var report: Dictionary = await p.sync()
	changed.emit()
	return _with_text(report, p)


func open_file(project_name: String, path: String) -> Dictionary:
	## Downloads `path` and what it places into the mirror. {ok, error, full_path, downloaded, missing}.
	var p := project(project_name)
	active = p
	_arm()
	if p.state.cursor == "" and is_configured():
		await p.sync() # the first contact: the tree, so the part index and the references know the project
	var result: Dictionary = await p.prepare_open(path)
	result["full_path"] = p.abs_path(path)
	changed.emit()
	return result


func sync_active(force: bool = false) -> Dictionary:
	if active == null:
		return {"busy": false, "reachable": true, "sent": [], "conflicts": [], "refreshed": [], "error": "", "warnings": [], "text": "No server project is open."}
	var report: Dictionary = await active.sync(force)
	changed.emit()
	return _with_text(report, active)


func note_path(full_path: String) -> void:
	## main.gd opened (or is about to open) a file: when it lives in a mirror, that project is the active one; otherwise none is.
	var owner := project_for_path(full_path)
	if owner == null:
		deactivate()
	elif owner != active:
		active = owner
		_arm()
		changed.emit()


func deactivate() -> void:
	if active != null:
		active = null
		if _timer != null:
			_timer.stop()
		changed.emit()


func project_for_path(full_path: String) -> CloudProject:
	if store_url == "" or full_path == "":
		return null
	var root := str(root_info()["path"])
	var prefix := root.path_join(CloudPaths.host_folder(store_url)).trim_suffix("/") + "/"
	var normal := full_path
	if normal.begins_with("user://"):
		normal = ProjectSettings.globalize_path(normal)
	var normal_prefix := ProjectSettings.globalize_path(prefix) if prefix.begins_with("user://") else prefix
	if not normal.begins_with(normal_prefix):
		return null
	var name := normal.substr(normal_prefix.length()).get_slice("/", 0)
	for known in all_project_names():
		if CloudPaths.safe_segment(str(known)) == name:
			return project(str(known))
	return null


func _on_timer() -> void:
	if active != null and is_configured() and not active.syncing:
		var report: Dictionary = await active.sync()
		cleanup_cache() # (cheap when under the limit: it only sums file sizes)
		var text := str(_with_text(report, active)["text"])
		if report["sent"].size() > 0 or not report["conflicts"].is_empty() or not report["refreshed"].is_empty():
			message.emit(text)
		changed.emit()


# --- what is waiting (the landing, the tablet chip) ---------------------------------------------------------------------------------------

func waiting() -> Dictionary:
	## {to_send, clash, offline: bool, projects: [{name, symbol, to_send, clash}]} across the projects saved here: from their sync states, no network.
	var out := {"to_send": 0, "clash": 0, "projects": []}
	if not is_configured():
		return out
	for name in known_projects():
		var s: Dictionary = project(str(name)).summary()
		out["to_send"] += int(s["to_send"])
		out["clash"] += int(s["clash"])
		if int(s["to_send"]) > 0 or int(s["clash"]) > 0 or not (s["missing"] as Array).is_empty():
			out["projects"].append({"name": name, "symbol": s["symbol"], "to_send": s["to_send"], "clash": s["clash"]})
	return out


func waiting_text() -> String:
	## "2 saves waiting to sync, 1 clash" or "" when nothing is.
	var w := waiting()
	var bits: PackedStringArray = []
	if int(w["to_send"]) > 0:
		bits.append("%d save%s waiting to sync" % [w["to_send"], "" if int(w["to_send"]) == 1 else "s"])
	if int(w["clash"]) > 0:
		bits.append("%d clash%s to settle" % [w["clash"], "" if int(w["clash"]) == 1 else "es"])
	return ", ".join(bits)


# --- words --------------------------------------------------------------------------------------------------------------------------------

func _with_text(report: Dictionary, p: CloudProject) -> Dictionary:
	var out := report.duplicate()
	out["text"] = report_text(report, p)
	return out


static func report_text(report: Dictionary, p: CloudProject = null) -> String:
	if bool(report.get("busy", false)):
		return "Syncing..."
	var summary: Dictionary = {} if p == null else p.summary()
	if not (report.get("conflicts", []) as Array).is_empty():
		var n: int = report["conflicts"].size()
		return "%d file%s changed on the server: choose Keep mine, Take theirs or Save as a copy on Files > Server projects." % [n, "" if n == 1 else "s"]
	if str(report.get("error", "")) != "":
		return str(report["error"])
	if not bool(report.get("reachable", true)):
		var waiting: int = int(summary.get("to_send", 0))
		return "The project store can't be reached. %s" % ("%d save%s kept on this headset to send later." % [waiting, "" if waiting == 1 else "s"] if waiting > 0 else "Working from the local copy.")
	var bits: PackedStringArray = []
	if not (report.get("sent", []) as Array).is_empty():
		bits.append("sent %d file%s" % [report["sent"].size(), "" if report["sent"].size() == 1 else "s"])
	if not (report.get("refreshed", []) as Array).is_empty():
		bits.append("updated %d from the server" % report["refreshed"].size())
	if not (report.get("warnings", []) as Array).is_empty():
		bits.append(str(report["warnings"][0]))
	return "Synced" + (": " + ", ".join(bits) if not bits.is_empty() else ": up to date") + "."
