extends SceneTree
## S3 (DIDSA-CAD docs/mates-storage-sessions-plan-2026-11-12.md, "S3. VR"): server projects, the local copy (a mirror folder) and offline, headless against a fake store
## (tests/fake_project_store.gd, as tests/mates_suggested_type.gd fakes the backend). scripts/cloud/cloud_project.gd end to end: reads and versioned writes (If-Match /
## If-None-Match, never a write without one), the stale single write, Save All as ONE commit (a 409 that writes nothing, and the retry after resolving), the three conflict
## choices and the copy's new Part id, a deleted or moved file as a clash, an offline save kept and sent on reconnect (the change feed first), a file dropped into / edited in
## / removed from the mirror (a create / an edit / NOTHING on the server), the queue surviving a restart, the store's statuses (401, 413, 400, a tunnel's limit), the feed and its
## bad-cursor fallback, and a file the open session holds not being refreshed under it.
## NOT covered: a real store (tests/e2e_cloud_store.gd), the screens (tests/cloud_ui.gd), a headset, a real permission prompt, how any of it feels.
## Run: "$GODOT" --headless --path . --script res://tests/cloud_sync.gd  (see tests/README.md)

const Rig := preload("res://tests/cloud_rig.gd")
const CloudRemint := preload("res://scripts/cloud/cloud_remint.gd")
const CloudProject := preload("res://scripts/cloud/cloud_project.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")

var _n := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _rig() -> Rig:
	_n += 1
	return Rig.new("sync_%d" % _n)


func _initialize() -> void:
	await _reads_and_versioned_writes()
	await _stale_single_write()
	await _save_all_one_commit()
	await _commit_409_writes_nothing()
	await _three_choices()
	await _deleted_and_moved()
	await _offline_queue_and_reconnect()
	await _mirror_edits_by_hand()
	await _statuses()
	await _feed_and_held()
	await _unsafe_paths()
	quit(0)


func _reads_and_versioned_writes() -> void:
	var r := _rig()
	r.put_remote("Bracket.didsa", Rig.native("p-bracket", "v1"))
	r.put_remote("notes.txt", "hello")
	var report: Dictionary = await r.project.sync()
	_check(report["reachable"] and r.project.state.tree.size() == 2 and not r.local_exists("Bracket.didsa"), "a first sync lists the project and downloads nothing (files are fetched when opened)")
	var got: Dictionary = await r.project.ensure_file("Bracket.didsa")
	_check(got["ok"] and got["downloaded"] and r.read_local("Bracket.didsa") == r.remote_text("Bracket.didsa"), "opening a file downloads it into the mirror, byte for byte")
	_check(int(r.project.state.files["Bracket.didsa"]["version"]) == 1, "...and records the version it was read at (1)")
	var again: Dictionary = await r.project.ensure_file("Bracket.didsa")
	_check(not again["downloaded"], "a file already in the mirror is not fetched again (a re-read cannot move its base)")
	var before := r.puts().size() + r.commits().size()
	await r.project.sync()
	_check(r.puts().size() + r.commits().size() == before, "an unchanged file is not sent")
	r.write_local("Bracket.didsa", r.read_local("Bracket.didsa")) # the same bytes written again (a save that changed nothing)
	await r.project.sync()
	_check(r.puts().size() + r.commits().size() == before, "a save whose bytes equal the version it was read at is not sent")
	r.write_local("Bracket.didsa", Rig.native("p-bracket", "v2"))
	report = await r.project.sync()
	_check(report["sent"] == ["Bracket.didsa"] and r.puts().size() == 1 and r.puts()[0]["if_match"] == "\"1\"", "an edit is sent as one PUT with If-Match of the version it was based on")
	_check(r.fake.version_of(r.name, "Bracket.didsa") == 2 and r.remote_text("Bracket.didsa") == r.read_local("Bracket.didsa"), "...the store has it as version 2")
	_check(r.project.state.queue.is_empty() and int(r.project.state.files["Bracket.didsa"]["version"]) == 2 and r.puts()[0]["device"] == "Quest 3", "...the queue is empty, the base is now 2, and the device name was sent")
	for request in r.fake.requests:
		if request["method"] == "PUT":
			assert(request["if_match"] != "" or request["if_none_match"] != "")
	_check(r.fake.requests.all(func(q: Dictionary) -> bool: return q["method"] != "PUT" or q["if_match"] != "" or q["if_none_match"] != ""), "no write was ever sent without a precondition")


func _stale_single_write() -> void:
	var r := _rig()
	r.put_remote("Shaft.didsa", Rig.native("p-shaft", "v1"))
	await r.project.sync()
	await r.project.ensure_file("Shaft.didsa")
	r.write_local("Shaft.didsa", Rig.native("p-shaft", "mine"))
	r.project.scan()
	var theirs := r.put_remote("Shaft.didsa", Rig.native("p-shaft", "theirs"), "Desktop")
	var outcome: Dictionary = await r.project._send_single("Shaft.didsa") # (the 412 path itself: the feed would have caught this one first)
	_check(r.puts().size() == 1 and r.puts()[0]["if_match"] == "\"1\"" and outcome.has("error"), "a stale single write is refused with 412")
	_check(r.remote_text("Shaft.didsa") == Rig.native("p-shaft", "theirs") and r.fake.version_of(r.name, "Shaft.didsa") == theirs, "...and nothing was written to the store")
	var clash: Dictionary = r.project.state.queue["Shaft.didsa"]["clash"]
	_check(clash != null and clash["reason"] == "changed" and clash["modified_by"] == "Desktop" and int(clash["current_version"]) == theirs, "...it is flagged as a clash with who changed it and which version")
	_check(r.project.state.queue["Shaft.didsa"]["base"] == 1 and r.read_local("Shaft.didsa") == Rig.native("p-shaft", "mine"), "...the queued save keeps its base and the mirror file is untouched (nothing lost)")
	var text: String = CloudProject.describe_clash("Shaft.didsa", clash)
	_check(text.begins_with("Changed by Desktop on 2026-11-13 "), "...the words match the flat app's: '%s'" % text)
	var report: Dictionary = await r.project.sync()
	_check(report["conflicts"].size() == 1 and r.puts().size() == 1, "a sync with a clash sends nothing more, and reports the clash")
	_check(r.project.summary()["symbol"] == "clash" and r.project.summary()["clash"] == 1, "the project's symbol is the clash")


func _save_all_one_commit() -> void:
	var r := _rig()
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		r.put_remote(f, Rig.native("p-" + f, "v1"))
	await r.project.sync()
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		await r.project.ensure_file(f)
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		r.write_local(f, Rig.native("p-" + f, "v2"))
	r.write_local("d.didsa", Rig.native("p-d", "new"))
	var report: Dictionary = await r.project.sync()
	_check(r.commits().size() == 1 and r.puts().size() == 0 and r.fake.requests_matching("POST", "/uploads").size() == 4, "Save All is ONE commit: an upload per file, then one POST commit, no single PUTs")
	_check(report["sent"].size() == 4 and r.fake.version_of(r.name, "a.didsa") == 2 and r.fake.version_of(r.name, "d.didsa") == 1, "...every file landed (the new one as version 1)")
	_check(r.project.state.queue.is_empty() and r.project.summary()["symbol"] == "synced", "...and the queue is empty")


func _commit_409_writes_nothing() -> void:
	var r := _rig()
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		r.put_remote(f, Rig.native("p-" + f, "v1"))
	await r.project.sync()
	for f in ["a.didsa", "b.didsa", "c.didsa"]:
		await r.project.ensure_file(f)
		r.write_local(f, Rig.native("p-" + f, "mine"))
	r.project.scan()
	r.put_remote("b.didsa", Rig.native("p-b.didsa", "theirs"), "Phone")
	var outcome: Dictionary = await r.project._send_commit(["a.didsa", "b.didsa", "c.didsa"]) # (straight to the commit: the feed would have flagged b first)
	_check(r.commits().size() == 1 and outcome.has("error"), "a commit with one stale file is refused whole (409)")
	_check(r.remote_text("a.didsa") == Rig.native("p-a.didsa", "v1") and r.remote_text("c.didsa") == Rig.native("p-c.didsa", "v1") and r.remote_text("b.didsa") == Rig.native("p-b.didsa", "theirs"), "...and NOTHING was written, not even the files that did not clash")
	var queue: Dictionary = r.project.state.queue
	_check(queue["b.didsa"]["clash"] != null and queue["a.didsa"]["clash"] == null and queue["c.didsa"]["clash"] == null and queue["b.didsa"]["clash"]["modified_by"] == "Phone", "...only the clashing file is flagged, with who changed it")
	var choice: Dictionary = await r.project.resolve({"b.didsa": CloudProject.KEEP_MINE})
	_check(choice["ok"] and queue["b.didsa"]["clash"] == null and queue["b.didsa"]["base"] == 2, "Keep mine re-bases the save on their version")
	var before := r.commits().size()
	var report: Dictionary = await r.project.sync()
	_check(r.commits().size() == before + 1 and report["sent"].size() == 3 and report["conflicts"].is_empty(), "the retry after resolving sends all three as one commit, and the feed's report of their change is not a new clash")
	_check(r.fake.version_of(r.name, "b.didsa") == 3 and r.remote_text("b.didsa") == Rig.native("p-b.didsa", "mine") and r.fake.version_of(r.name, "a.didsa") == 2, "...mine is the next version over theirs (3), the others are 2")
	# the same through a whole sync: the feed flags the clash first and nothing is sent
	var s := _rig()
	s.put_remote("x.didsa", Rig.native("p-x", "v1"))
	s.put_remote("y.didsa", Rig.native("p-y", "v1"))
	await s.project.sync()
	await s.project.ensure_file("x.didsa")
	await s.project.ensure_file("y.didsa")
	s.write_local("x.didsa", Rig.native("p-x", "mine"))
	s.write_local("y.didsa", Rig.native("p-y", "mine"))
	s.put_remote("y.didsa", Rig.native("p-y", "theirs"), "Desktop")
	var uploads_before: int = s.fake.requests_matching("POST", "/uploads").size()
	var report2: Dictionary = await s.project.sync()
	_check(report2["conflicts"].size() == 1 and report2["conflicts"][0]["path"] == "y.didsa" and s.commits().is_empty() and s.fake.requests_matching("POST", "/uploads").size() == uploads_before, "in a whole sync the change feed flags the stale save before anything is uploaded or committed")


func _three_choices() -> void:
	# Keep mine
	var r := _rig()
	r.put_remote("Shaft.didsa", Rig.native("p-shaft", "v1"))
	await r.project.sync()
	await r.project.ensure_file("Shaft.didsa")
	r.write_local("Shaft.didsa", Rig.native("p-shaft", "mine"))
	r.put_remote("Shaft.didsa", Rig.native("p-shaft", "theirs"), "Desktop")
	await r.project.sync()
	await r.project.resolve({"Shaft.didsa": CloudProject.KEEP_MINE})
	var report: Dictionary = await r.project.sync()
	_check(report["sent"] == ["Shaft.didsa"] and r.puts()[0]["if_match"] == "\"2\"" and r.remote_text("Shaft.didsa") == Rig.native("p-shaft", "mine") and r.fake.version_of(r.name, "Shaft.didsa") == 3, "Keep mine: sent with If-Match of THEIR version, so mine is the next version over theirs")
	# Take theirs
	var t := _rig()
	t.put_remote("Shaft.didsa", Rig.native("p-shaft", "v1"))
	await t.project.sync()
	await t.project.ensure_file("Shaft.didsa")
	var mine := Rig.native("p-shaft", "mine")
	t.write_local("Shaft.didsa", mine)
	t.put_remote("Shaft.didsa", Rig.native("p-shaft", "theirs"), "Desktop")
	await t.project.sync()
	var res: Dictionary = await t.project.resolve({"Shaft.didsa": CloudProject.TAKE_THEIRS})
	_check(res["ok"] and res["reload"] and t.read_local("Shaft.didsa") == Rig.native("p-shaft", "theirs"), "Take theirs: the mirror file is theirs (and the caller is told to reload)")
	_check(t.project.state.queue.is_empty() and t.project.state.get_mine("Shaft.didsa").get_string_from_utf8() == mine, "...mine is kept locally (in private storage)")
	await t.project.sync()
	_check(t.project.state.mine.has("Shaft.didsa") and t.puts().is_empty(), "...kept through the next sync (the one that finishes the resolution)")
	await t.project.sync()
	_check(not t.project.state.mine.has("Shaft.didsa"), "...and dropped by the one after")
	# Save mine as a copy
	var c := _rig()
	c.device = "Quest 3"
	c.restart()
	c.put_remote("Shaft.didsa", Rig.native("p-shaft", "v1"))
	await c.project.sync()
	await c.project.ensure_file("Shaft.didsa")
	var mine2 := Rig.native("p-shaft", "mine", [{"ref": "Pin.didsa", "id": "p-pin"}])
	c.write_local("Shaft.didsa", mine2)
	c.put_remote("Shaft.didsa", Rig.native("p-shaft", "theirs"), "Desktop")
	await c.project.sync()
	var copied: Dictionary = await c.project.resolve({"Shaft.didsa": CloudProject.SAVE_COPY})
	var date := Time.get_datetime_dict_from_system()
	var copy_path: String = copied["copies"].get("Shaft.didsa", "")
	_check(copied["ok"] and copy_path == "Shaft (Quest 3, %04d-%02d-%02d).didsa" % [date["year"], date["month"], date["day"]], "Save mine as a copy: '<name> (<device>, <date>).didsa' (%s)" % copy_path)
	_check(c.read_local("Shaft.didsa") == Rig.native("p-shaft", "theirs") and c.local_exists(copy_path), "...the original is theirs again and the copy is beside it")
	var copy_doc: Dictionary = JSON.parse_string(c.read_local(copy_path))
	var new_id: String = str(copy_doc["document"]["root_part_id"])
	_check(new_id != "p-shaft" and new_id != "" and copy_doc["document"]["parts"][0]["id"] == new_id and copy_doc["document"]["id"] != "doc-p-shaft", "...the copy has a NEW Part id (and document id), and the references to it followed")
	_check(copy_doc["document"]["parts"][0]["occurrences"][0]["resolved_part_id"] == "p-pin", "...while the Part it places is still the same Part")
	report = await c.project.sync()
	_check(report["sent"] == [copy_path] and c.fake.has_file(c.name, copy_path) and c.fake.version_of(c.name, "Shaft.didsa") == 2 and c.puts()[0]["if_none_match"] == "*", "the copy is sent as a new file (If-None-Match: *) and theirs is untouched")
	_check(str(c.fake._part_id(copy_path, c.fake.file_bytes(c.name, copy_path))) == new_id, "...and the store indexes the copy under its own Part id")


func _deleted_and_moved() -> void:
	var r := _rig()
	r.put_remote("Old.didsa", Rig.native("p-old", "v1"))
	r.put_remote("Moved.didsa", Rig.native("p-moved", "v1"))
	await r.project.sync()
	await r.project.ensure_file("Old.didsa")
	await r.project.ensure_file("Moved.didsa")
	r.write_local("Old.didsa", Rig.native("p-old", "mine"))
	r.write_local("Moved.didsa", Rig.native("p-moved", "mine"))
	r.fake.delete_direct(r.name, "Old.didsa", "Desktop")
	r.fake.delete_direct(r.name, "Moved.didsa", "Phone", "Moved-v2.didsa")
	r.put_remote("Moved-v2.didsa", Rig.native("p-moved", "v1"), "Phone")
	var report: Dictionary = await r.project.sync()
	var by_path := {}
	for c in report["conflicts"]:
		by_path[c["path"]] = c
	_check(by_path.has("Old.didsa") and by_path["Old.didsa"]["text"].begins_with("Deleted by Desktop"), "a file deleted elsewhere is a clash: '%s'" % by_path.get("Old.didsa", {}).get("text", ""))
	_check(by_path.has("Moved.didsa") and by_path["Moved.didsa"]["text"].begins_with("Renamed to Moved-v2.didsa by Phone"), "a moved file is a clash too: '%s'" % by_path.get("Moved.didsa", {}).get("text", ""))
	await r.project.resolve({"Old.didsa": CloudProject.KEEP_MINE, "Moved.didsa": CloudProject.TAKE_THEIRS})
	report = await r.project.sync()
	_check(r.remote_text("Old.didsa") == Rig.native("p-old", "mine") and r.fake.has_file(r.name, "Old.didsa"), "Keep mine on a deleted file writes it at the old path again")
	_check(not r.local_exists("Moved.didsa") and r.project.state.get_mine("Moved.didsa").get_string_from_utf8() == Rig.native("p-moved", "mine"), "Take theirs on a moved file drops it locally, with mine kept")


func _offline_queue_and_reconnect() -> void:
	var r := _rig()
	r.put_remote("Plate.didsa", Rig.native("p-plate", "v1"))
	await r.project.sync()
	await r.project.ensure_file("Plate.didsa")
	r.fake.offline = true
	r.write_local("Plate.didsa", Rig.native("p-plate", "offline"))
	var report: Dictionary = await r.project.sync()
	_check(not report["reachable"] and r.project.state.queue.has("Plate.didsa") and r.project.summary()["symbol"] == "offline", "an unreachable store: the save is queued, never lost, and the project reads offline")
	r.write_local("Fresh.didsa", Rig.native("p-fresh", "new"))
	await r.project.sync()
	_check(r.project.state.queue.size() == 2 and r.project.summary()["to_send"] == 2, "...a second one joins the queue")
	r.restart() # the app closed and opened again
	_check(r.project.state.queue.size() == 2 and r.project.state.queue["Plate.didsa"]["base"] == 1 and r.project.state.queue["Fresh.didsa"]["base"] == null, "the queue survives a restart (from private storage, with each base)")
	r.fake.offline = false
	r.put_remote("Other.didsa", Rig.native("p-other", "v1"), "Desktop")
	var mark: int = r.fake.requests.size()
	report = await r.project.sync()
	var after: Array = r.fake.requests.slice(mark)
	_check(after[0]["path"].contains("/changes") and after.filter(func(q: Dictionary) -> bool: return q["method"] == "POST" and q["path"].contains("/commit")).size() == 1, "on reconnect the change feed is asked FIRST, then the queue goes as one commit")
	_check(report["sent"].size() == 2 and r.remote_text("Plate.didsa") == Rig.native("p-plate", "offline") and r.fake.has_file(r.name, "Fresh.didsa") and r.project.state.queue.is_empty(), "...both saves landed")
	# the file the queue points at is gone from the mirror: warned about, nothing deleted, nothing lost from the queue
	var m := _rig()
	m.put_remote("Pin.didsa", Rig.native("p-pin", "v1"))
	await m.project.sync()
	await m.project.ensure_file("Pin.didsa")
	m.write_local("Pin.didsa", Rig.native("p-pin", "edited"))
	m.project.scan()
	m.remove_local("Pin.didsa")
	m.restart()
	report = await m.project.sync()
	_check(m.project.state.queue.has("Pin.didsa") and m.project.summary()["missing"] == ["Pin.didsa"] and not report["warnings"].is_empty() and report["warnings"][0].contains("Pin.didsa"), "a save the state says is unsent whose mirror file is gone is warned about")
	_check(m.fake.has_file(m.name, "Pin.didsa") and m.fake.requests_matching("DELETE", "").is_empty() and m.remote_text("Pin.didsa") == Rig.native("p-pin", "v1"), "...and nothing was deleted or overwritten on the server")


func _mirror_edits_by_hand() -> void:
	var r := _rig()
	r.put_remote("Keep.didsa", Rig.native("p-keep", "v1"))
	r.put_remote("Edit.didsa", Rig.native("p-edit", "v1"))
	r.put_remote("Gone.didsa", Rig.native("p-gone", "v1"))
	await r.project.sync()
	for f in ["Keep.didsa", "Edit.didsa", "Gone.didsa"]:
		await r.project.ensure_file(f)
	r.write_local("dropped/Notes.step", "ISO-10303-21; fake step") # a file dropped in by hand, in a new subfolder
	r.write_local("Edit.didsa", Rig.native("p-edit", "by hand")) # edited by hand
	r.remove_local("Gone.didsa") # deleted by hand
	r.write_local(".hidden.didsa", "x") # a dot-file is not a project file
	r.write_local("Keep.didsa.saving", "half") # project_save.gd's temp file is not either
	var scanned: Dictionary = r.project.scan()
	_check(scanned["new"] == ["dropped/Notes.step"] and scanned["changed"] == ["Edit.didsa"], "a dropped file is a queued create and an edited one a queued edit (dot-files and temp files are ignored)")
	_check(r.project.state.queue["dropped/Notes.step"]["base"] == null and r.project.state.queue["Edit.didsa"]["base"] == 1 and not r.project.state.queue.has("Gone.didsa"), "...the create has no base, the edit has the version it was based on, and the missing file is not queued")
	await r.project.sync()
	_check(r.puts().is_empty() and r.commits().size() == 1, "...they go as one commit")
	_check(r.fake.has_file(r.name, "dropped/Notes.step") and r.remote_text("Edit.didsa") == Rig.native("p-edit", "by hand") and r.fake.has_file(r.name, "Gone.didsa"), "a file deleted from the mirror is NOT deleted on the server")
	_check(r.fake.requests.all(func(q: Dictionary) -> bool: return q["method"] != "DELETE"), "...no DELETE was ever sent")
	_check(r.project.file_state("Gone.didsa") == "cloud" and (await r.project.ensure_file("Gone.didsa"))["downloaded"], "...it is only 'not downloaded', and opening it fetches it again")
	# a hand edit that races a running sync is never missed: bytes sent are what the store records, the next scan sees the difference
	r.write_local("Edit.didsa", Rig.native("p-edit", "second"))
	r.write_local("Edit.didsa", Rig.native("p-edit", "third"))
	await r.project.sync()
	_check(r.remote_text("Edit.didsa") == Rig.native("p-edit", "third") and r.fake.version_of(r.name, "Edit.didsa") == 3, "two edits between syncs are one save of the latest bytes")
	# lost state: the mirror's files that equal the store's are recognised, not queued as new
	var lost := _rig()
	lost.put_remote("Same.didsa", Rig.native("p-same", "v1"))
	lost.write_local("Same.didsa", Rig.native("p-same", "v1")) # already in the mirror, but this headset's state knows nothing
	lost.write_local("Different.didsa", Rig.native("p-diff", "v1"))
	lost.put_remote("Different.didsa", Rig.native("p-diff", "other"))
	var report: Dictionary = await lost.project.sync()
	_check(lost.puts().is_empty() and lost.commits().is_empty() and lost.project.state.files.has("Same.didsa") and lost.project.state.queue.has("Different.didsa") and lost.project.state.queue["Different.didsa"]["clash"] != null, "with the sync state lost, a file equal to the store's is recognised and a different one is a clash ('exists'), not a silent overwrite")
	_check(report["conflicts"].size() == 1 and report["conflicts"][0]["clash"]["reason"] == "exists", "...worded as 'a file with this name was added by ...'")


func _statuses() -> void:
	# 401 names the key; the save stays queued
	var r := _rig()
	r.put_remote("A.didsa", Rig.native("p-a", "v1"))
	await r.project.sync()
	await r.project.ensure_file("A.didsa")
	r.write_local("A.didsa", Rig.native("p-a", "mine"))
	r.client.api_key = "wrong-key"
	var report: Dictionary = await r.project.sync()
	_check(report["error"].contains("refused the key") and r.project.state.queue.has("A.didsa") and r.project.summary()["symbol"] == "offline" and r.project.summary()["auth_failed"], "401 names the key, keeps the save queued, and the project is shown as not syncing")
	r.client.api_key = r.fake.key
	report = await r.project.sync()
	_check(report["sent"] == ["A.didsa"] and not r.project.auth_failed, "...and a corrected key sends it")
	# 413 (the store's own limit): a clear message, the save stays, the timer does not hammer the store
	var t := _rig()
	t.put_remote("Big.didsa", "small")
	await t.project.sync()
	await t.project.ensure_file("Big.didsa")
	t.fake.max_bytes = 10
	t.write_local("Big.didsa", "this is much bigger than ten bytes")
	report = await t.project.sync()
	_check(report["error"].contains("too large") and t.project.problems.has("Big.didsa") and t.project.state.queue.has("Big.didsa"), "413 shows a clear message and keeps the save")
	var asked: int = t.puts().size()
	await t.project.sync()
	_check(t.puts().size() == asked, "...the timer's next sync does not retry it")
	await t.project.sync(true)
	_check(t.puts().size() == asked + 1, "...'Sync now' does")
	t.project.keep_local_only("Big.didsa")
	await t.project.sync()
	_check(t.project.state.queue.is_empty() and t.project.file_state("Big.didsa") == "local_only" and t.puts().size() == asked + 1, "...and Keep local only stops trying (the file stays in the mirror)")
	t.write_local("Big.didsa", "changed again, still bigger than ten")
	t.project.scan()
	_check(t.project.state.queue.has("Big.didsa"), "...a later change queues it again")
	# 400: the store's own message, verbatim
	var b := _rig()
	b.put_remote("B.didsa", "x")
	await b.project.sync()
	await b.project.ensure_file("B.didsa")
	b.write_local("B.didsa", "y")
	b.fake.fail_next("/files/", 400, {"error": "bad_path", "detail": "names can't end with a dot"})
	report = await b.project.sync()
	_check(report["error"].contains("names can't end with a dot") and b.project.state.queue.has("B.didsa"), "400 shows the store's message")
	# a file over the tunnel's limit: the connection is cut but the store still answers
	var u := _rig()
	u.put_remote("C.didsa", "x")
	await u.project.sync()
	await u.project.ensure_file("C.didsa")
	u.project.tunnel_limit = 8
	u.write_local("C.didsa", "more than eight bytes of text")
	u.fake.fail_next("/files/", 0)
	report = await u.project.sync(true)
	_check(report["error"].contains("Cloudflare tunnel") and u.project.state.queue.has("C.didsa") and u.project.summary()["online"] == true, "a big upload that fails while the store still answers is explained as the tunnel's limit (no chunking), and kept")
	# a connection that drops on a small file is just offline
	var d := _rig()
	d.put_remote("D.didsa", "x")
	await d.project.sync()
	await d.project.ensure_file("D.didsa")
	d.write_local("D.didsa", "yy")
	d.fake.fail_next("/files/", 0)
	report = await d.project.sync()
	_check(not report["reachable"] and d.project.state.queue.has("D.didsa"), "a dropped connection on a small file is offline: queued")


func _feed_and_held() -> void:
	var r := _rig()
	r.put_remote("One.didsa", Rig.native("p-one", "v1"))
	r.put_remote("Two.didsa", Rig.native("p-two", "v1"))
	await r.project.sync()
	await r.project.ensure_file("One.didsa")
	await r.project.ensure_file("Two.didsa")
	var mark: int = r.fake.requests.size()
	await r.project.sync()
	var quiet: Array = r.fake.requests.slice(mark).map(func(q: Dictionary) -> String: return q["path"].get_slice("?", 0).get_slice("/", 3))
	_check(quiet == ["changes"], "a quiet sync asks only the change feed: no tree, no files (%s)" % str(quiet))
	r.put_remote("One.didsa", Rig.native("p-one", "v2"), "Desktop")
	r.put_remote("Two.didsa", Rig.native("p-two", "v2"), "Desktop")
	r.held = ["Two.didsa"] # the open session was composed from Two
	var report: Dictionary = await r.project.sync()
	_check(report["refreshed"] == ["One.didsa"] and r.read_local("One.didsa") == Rig.native("p-one", "v2") and int(r.project.state.files["One.didsa"]["version"]) == 2, "a file others changed is refreshed in the mirror")
	_check(r.read_local("Two.didsa") == Rig.native("p-two", "v1") and int(r.project.state.files["Two.didsa"]["version"]) == 1 and r.project.state.behind.has("Two.didsa"), "...but a file the open session holds is NOT refreshed under it (its base stays)")
	r.write_local("Two.didsa", Rig.native("p-two", "mine"))
	report = await r.project.sync()
	_check(report["conflicts"].size() == 1 and report["conflicts"][0]["path"] == "Two.didsa", "...so saving it is a clash, never a silent overwrite")
	# a cursor the store refuses falls back to the tree
	var f := _rig()
	f.put_remote("Q.didsa", Rig.native("p-q", "v1"))
	await f.project.sync()
	await f.project.ensure_file("Q.didsa")
	f.put_remote("Q.didsa", Rig.native("p-q", "v2"), "Desktop")
	f.fake.forget_feed()
	report = await f.project.sync()
	_check(f.fake.requests_matching("GET", "/tree").size() == 2 and report["refreshed"] == ["Q.didsa"] and f.read_local("Q.didsa") == Rig.native("p-q", "v2"), "a refused cursor (400 bad_cursor) falls back to the tree and still refreshes what changed")
	# a file removed on the server is removed from a clean mirror
	var g := _rig()
	g.put_remote("Z.didsa", Rig.native("p-z", "v1"))
	await g.project.sync()
	await g.project.ensure_file("Z.didsa")
	g.fake.delete_direct(g.name, "Z.didsa", "Desktop")
	await g.project.sync()
	_check(not g.local_exists("Z.didsa") and not g.project.state.files.has("Z.didsa") and g.project.state.queue.is_empty(), "a file the server removed disappears from a clean local copy (it stays in the store's history) and is not queued back as new")
	await g.project.sync()
	_check(not g.fake.has_file(g.name, "Z.didsa"), "...and a later sync does not bring it back")


func _unsafe_paths() -> void:
	# a path the store names that would leave the mirror, or that the scan would never see, is never written
	var r := _rig()
	r.put_remote("Fine.didsa", Rig.native("p-fine", "v1"))
	r.put_remote("../escape.didsa", Rig.native("p-escape", ""))
	r.put_remote("sub/../../escape2.didsa", Rig.native("p-escape2", ""))
	r.put_remote(".hidden/Dot.didsa", Rig.native("p-dot", ""))
	r.put_remote("C:/win.didsa", Rig.native("p-win", ""))
	await r.project.sync()
	_check(r.project.state.tree.keys() == ["Fine.didsa"], "a store path that is absolute, has .. or a dot-folder or a drive is not listed")
	var got: Dictionary = await r.project.ensure_file("../escape.didsa")
	var got2: Dictionary = await r.project.ensure_file("sub/../../escape2.didsa")
	var parent := r.mirror.get_base_dir()
	_check(not got["ok"] and not got2["ok"] and not FileAccess.file_exists(parent + "/escape.didsa") and not FileAccess.file_exists(parent.get_base_dir() + "/escape2.didsa") and not FileAccess.file_exists(r.mirror + "/escape2.didsa"), "...and asking for one writes nothing outside the mirror")
	r.put_remote("Fine.didsa", Rig.native("p-fine", "v2"), "Desktop")
	r.fake.delete_direct(r.name, "../escape.didsa", "Desktop")
	var ok: Dictionary = await r.project.ensure_file("Fine.didsa")
	_check(ok["ok"] and r.read_local("Fine.didsa") == Rig.native("p-fine", "v2"), "a normal file in the same project still opens")
