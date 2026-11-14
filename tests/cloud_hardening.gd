extends SceneTree
## S4 (DIDSA-CAD docs/mates-storage-sessions-plan-2026-11-12.md, "S4. Hardening"): server projects when the network or the store misbehaves, headless against the fake store
## (tests/fake_project_store.gd, which can be switched off and on, dropped after N requests, or lose a reply AFTER applying the request).
##   * chunked upload for a file over the threshold (and for one a tunnel refuses), in order, the store's SHA-256 check, the single big file going through a commit;
##   * an upload cut off part-way, the store switched off and on, the app closed and opened again: the upload RESUMES from what the store has (no chunk is sent twice), and
##     one version results; a lost reply to a chunk; a commit that landed but whose reply was lost (no duplicate version, no lost save); an expired or damaged upload; a file
##     edited between attempts; a store too old for chunks (the clear message);
##   * two devices offline on the same file: the second to sync is told, nothing is overwritten, each choice (Keep mine, Take theirs, copy) ends consistent; the same edit
##     made on both is no clash;
##   * the hash cache kept across a restart (the shortcut is taken, a changed size or a racy mtime still re-hashes).
## NOT covered: a real store (tests/e2e_cloud_outage.gd), a Cloudflare tunnel (the fake imitates its 413), a headset, how any message reads.
## Run: "$GODOT" --headless --path . --script res://tests/cloud_hardening.gd  (see tests/README.md)

const Rig := preload("res://tests/cloud_rig.gd")
const CloudFiles := preload("res://scripts/cloud/cloud_files.gd")
const CloudProject := preload("res://scripts/cloud/cloud_project.gd")
const CloudManager := preload("res://scripts/cloud/cloud_manager.gd")
const AppSettings := preload("res://scripts/app_settings.gd")
const FakeStore := preload("res://tests/fake_project_store.gd")
const Launcher := preload("res://scripts/landing/launcher_window.gd")

var _n := 0


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _rig() -> Rig:
	_n += 1
	var r := Rig.new("hard_%d" % _n)
	r.project.chunk_threshold = 20 # (bytes: the real values are 90 MB and 32 MB)
	r.project.chunk_bytes = 10
	return r


func _big(tag: String = "a") -> String:
	return tag.repeat(55) # 55 bytes = 6 chunks of 10


func _fresh_project(r: Rig) -> void:
	## "the app was closed and opened again", keeping the test's chunk sizes.
	r.restart()
	r.project.chunk_threshold = 20
	r.project.chunk_bytes = 10


func _initialize() -> void:
	await _chunked_basics()
	await _interrupted()
	await _lost_replies()
	await _expired_and_damaged()
	await _old_store_and_tunnel()
	await _two_devices_offline()
	await _hash_cache()
	await _cache_cleanup()
	quit()


func _chunked_basics() -> void:
	var r := _rig()
	r.put_remote("Small.didsa", "x")
	await r.project.sync()
	await r.project.ensure_file("Small.didsa")
	r.write_local("Big.didsa", _big())
	var report: Dictionary = await r.project.sync()
	_check(report["sent"] == ["Big.didsa"] and r.remote_text("Big.didsa") == _big() and r.fake.chunks_received == 6, "a new file over the threshold goes up as 6 chunks and lands intact (%d chunks)" % r.fake.chunks_received)
	_check(r.puts().is_empty() and r.commits().size() == 1 and r.project.state.queue.is_empty() and r.project.state.uploads.is_empty(), "...through ONE commit (never a PUT of the whole file), and the upload session is forgotten")
	_check(r.fake.version_of(r.name, "Big.didsa") == 1, "...as one version")
	# an edit of a big file: replaces the version it was based on
	r.write_local("Big.didsa", _big("b"))
	report = await r.project.sync()
	_check(r.remote_text("Big.didsa") == _big("b") and r.fake.version_of(r.name, "Big.didsa") == 2 and r.puts().is_empty(), "an edited big file is a commit with its base version (v2), still no PUT")
	# a small file keeps the one-request path
	r.write_local("Small.didsa", "tiny")
	var before: int = r.fake.chunks_received
	await r.project.sync()
	_check(r.remote_text("Small.didsa") == "tiny" and r.fake.chunks_received == before and r.puts().size() == 1, "a file under the threshold is unchanged: one PUT, no chunks")
	# the chunk size is the store's advice when it is smaller
	r.fake.chunk_cap = 0
	r.write_local("Many.didsa", _big("m"))
	r.project.chunk_bytes = 1000 # larger than the 32 MB advice? (the fake advises 32 MB, so 1000 stays)
	before = r.fake.chunks_received
	await r.project.sync()
	_check(r.remote_text("Many.didsa") == _big("m") and r.fake.chunks_received == before + 1, "a chunk size larger than the file is one chunk")


func _interrupted() -> void:
	var r := _rig()
	r.write_local("Big.didsa", _big())
	r.fake.die_after(5) # session (after the health check), then chunks 1, 2, 3 land, then the store is gone
	var report: Dictionary = await r.project.sync()
	var got: int = r.fake.chunks_received
	_check(not report["reachable"] and r.project.state.queue.has("Big.didsa") and got > 0 and got < 6 and r.project.state.uploads.has("Big.didsa"), "a store that dies mid-upload: queued, %d of 6 chunks are on the store, the session is remembered" % got)
	var sessions_before: int = r.fake.requests_matching("POST", "/uploads/sessions").size()
	r.fake.restart_store()
	report = await r.project.sync()
	_check(r.remote_text("Big.didsa") == _big() and report["sent"] == ["Big.didsa"] and r.fake.chunks_received == 6, "...switched on again, the upload RESUMES: the file arrives and no chunk was sent twice (%d chunk requests applied in all)" % r.fake.chunks_received)
	_check(r.fake.requests_matching("POST", "/uploads/sessions").size() == sessions_before and r.fake.version_of(r.name, "Big.didsa") == 1, "...on the same session, and as exactly one version")
	# the app closed in between
	var c := _rig()
	c.write_local("Big.didsa", _big("c"))
	c.fake.die_after(4)
	await c.project.sync()
	var half: int = c.fake.chunks_received
	_fresh_project(c) # a new CloudProject over the same private state folder
	c.fake.restart_store()
	_check(c.project.state.uploads.has("Big.didsa"), "the half-sent upload is in the private state on disk (%d chunks were on the store)" % half)
	await c.project.sync()
	_check(c.remote_text("Big.didsa") == _big("c") and c.fake.chunks_received == 6, "...and a closed and reopened app resumes it (no chunk twice)")
	# the file is edited while the upload is half done: a new upload, the new bytes
	var e := _rig()
	e.write_local("Big.didsa", _big("e"))
	e.fake.die_after(4)
	await e.project.sync()
	e.write_local("Big.didsa", _big("f"))
	e.fake.restart_store()
	await e.project.sync()
	_check(e.fake.requests_matching("DELETE", "/uploads/").size() == 1, "...and the abandoned session is cancelled on the store, not left to expire")
	_check(e.remote_text("Big.didsa") == _big("f") and e.fake.version_of(e.name, "Big.didsa") == 1, "a file edited between attempts starts a new upload and the store gets only the new bytes")
	# the store away for several syncs, then back: nothing lost, nothing duplicated
	var o := _rig()
	o.write_local("Big.didsa", _big("o"))
	o.write_local("Other.didsa", "other")
	o.fake.offline = true
	for i in 3:
		await o.project.sync(true)
	_check(o.project.state.queue.size() == 2 and o.fake.live_paths(o.name).is_empty(), "three syncs while the store is off: both saves stay queued, nothing reaches it")
	o.fake.restart_store()
	await o.project.sync()
	_check(o.remote_text("Big.didsa") == _big("o") and o.remote_text("Other.didsa") == "other" and o.fake.version_of(o.name, "Big.didsa") == 1 and o.project.state.queue.is_empty(), "...then it is back: one commit with both, one version each")


func _lost_replies() -> void:
	# a chunk landed but the answer never came: the retry is told where the store really is
	var r := _rig()
	r.write_local("Big.didsa", _big("l"))
	r.fake.lose_reply_next("offset=10")
	var report: Dictionary = await r.project.sync()
	_check(r.remote_text("Big.didsa") == _big("l") and r.fake.chunks_received == 6 and report["sent"] == ["Big.didsa"], "a lost reply to a chunk: the same chunk is sent again, the store says it already has it (wrong_offset), the upload carries on without a duplicate byte")
	# the commit landed and its reply was lost: the next sync must not send a second version
	var c := _rig()
	c.put_remote("Doc.didsa", "v1")
	await c.project.sync()
	await c.project.ensure_file("Doc.didsa")
	c.write_local("Doc.didsa", "v2 mine, longer than twenty bytes")
	c.fake.lose_reply_next("/commit")
	report = await c.project.sync()
	_check(not report["reachable"] and c.remote_text("Doc.didsa") == "v2 mine, longer than twenty bytes" and c.fake.version_of(c.name, "Doc.didsa") == 2, "a commit that LANDED with its reply lost: the store has v2, this device does not know")
	report = await c.project.sync()
	_check(c.project.state.queue.is_empty() and c.fake.version_of(c.name, "Doc.didsa") == 2 and int(c.project.state.files["Doc.didsa"]["version"]) == 2 and report["conflicts"].is_empty(), "...the next sync recognises its own save: no clash, no third version, the queue is empty and the base is v2")
	# the same for a single-file PUT
	var p := _rig()
	p.put_remote("One.didsa", "v1")
	await p.project.sync()
	await p.project.ensure_file("One.didsa")
	p.write_local("One.didsa", "v2")
	p.fake.lose_reply_next("/files/")
	await p.project.sync()
	report = await p.project.sync()
	_check(p.fake.version_of(p.name, "One.didsa") == 2 and p.project.state.queue.is_empty() and report["conflicts"].is_empty(), "a PUT that landed with its reply lost is recognised the same way")


func _expired_and_damaged() -> void:
	var r := _rig()
	r.write_local("Big.didsa", _big("x"))
	r.fake.die_after(4)
	await r.project.sync()
	r.fake.restart_store()
	r.fake.expire_uploads() # the store forgot the session (it expires after an hour without a chunk)
	await r.project.sync()
	_check(r.remote_text("Big.didsa") == _big("x"), "an upload the store has forgotten is started again from the beginning, once, and lands")
	var d := _rig()
	d.write_local("Big.didsa", _big("d"))
	d.fake.fail_next("/complete", 400, {"error": "checksum_mismatch", "detail": "the bytes received do not match the declared SHA-256"})
	var report: Dictionary = await d.project.sync()
	_check(report["error"].contains("SHA-256") and d.project.state.queue.has("Big.didsa") and not d.project.state.uploads.has("Big.didsa") and not d.fake.has_file(d.name, "Big.didsa"), "a damaged upload (hash mismatch) writes nothing, shows the store's message and keeps the save queued")
	report = await d.project.sync(true)
	_check(d.remote_text("Big.didsa") == _big("d") and d.project.state.queue.is_empty(), "...and Sync now sends it again from the start")
	# a commit refused for a clash keeps the finished upload for the retry (no second upload of the file)
	var k := _rig()
	k.put_remote("Big.didsa", "old")
	await k.project.sync()
	await k.project.ensure_file("Big.didsa")
	k.write_local("Big.didsa", _big("k"))
	k.put_remote("Big.didsa", "theirs", "Desktop")
	await k.project.sync()
	_check(k.project.state.queue.has("Big.didsa") and k.project.state.queue["Big.didsa"]["clash"] != null and k.remote_text("Big.didsa") == "theirs", "a big file whose base went stale is a clash, nothing written")


func _old_store_and_tunnel() -> void:
	var r := _rig()
	r.fake.chunked = false
	r.write_local("Big.didsa", _big("o"))
	var report: Dictionary = await r.project.sync()
	_check(report["error"].contains("too old") and r.project.state.queue.has("Big.didsa") and not r.fake.has_file(r.name, "Big.didsa"), "a store without uploads.chunked: a clear message, the save kept, nothing half-uploaded")
	# a tunnel that refuses bodies over its limit although the file is under the threshold
	var t := _rig()
	t.project.chunk_threshold = 1000
	t.fake.chunk_cap = 110 # the tunnel's limit; the store's own limit is not involved (its 413 is JSON, this one is HTML)
	t.write_local("Mid.didsa", _big("t").repeat(3))
	report = await t.project.sync()
	_check(t.remote_text("Mid.didsa") == _big("t").repeat(3) and report["error"] == "", "a one-request upload refused by a tunnel (413, not the store's JSON) is retried in chunks")
	# ...and a single PUT refused the same way
	var s := _rig()
	s.put_remote("S.didsa", "v1")
	await s.project.sync()
	await s.project.ensure_file("S.didsa")
	s.project.chunk_threshold = 1000
	s.fake.chunk_cap = 110
	s.write_local("S.didsa", _big("s").repeat(3))
	await s.project.sync()
	_check(s.remote_text("S.didsa") == _big("s").repeat(3) and s.fake.version_of(s.name, "S.didsa") == 2, "a single save refused by a tunnel is also sent in chunks, as a commit with its base version")
	# the store's own limit is still reported
	var l := _rig()
	l.fake.max_bytes = 40
	l.write_local("Huge.didsa", _big("h"))
	report = await l.project.sync()
	_check(report["error"].contains("too large") and l.project.state.queue.has("Huge.didsa"), "the store's own size limit is still reported, with its message")


func _device_on(r: Rig, device_name: String, test_name: String) -> Rig:
	## A second device on the SAME store: its own mirror and private state.
	var other := Rig.new(test_name)
	other.fake = r.fake
	other.device = device_name
	other.restart()
	other.project.chunk_threshold = 20
	other.project.chunk_bytes = 10
	return other


func _two_devices_offline() -> void:
	var a := _rig()
	a.put_remote("Shared.didsa", "v1")
	var b := _device_on(a, "Phone", "hard_phone_1")
	await a.project.sync()
	await b.project.sync()
	await a.project.ensure_file("Shared.didsa")
	await b.project.ensure_file("Shared.didsa")
	a.fake.offline = true
	a.write_local("Shared.didsa", "from the Quest")
	b.write_local("Shared.didsa", "from the Phone, different")
	await a.project.sync(true)
	await b.project.sync(true)
	_check(a.project.state.queue.has("Shared.didsa") and b.project.state.queue.has("Shared.didsa") and a.fake.version_of(a.name, "Shared.didsa") == 1, "two devices edit the same file offline: both saves are queued, the store untouched")
	a.fake.offline = false
	await a.project.sync(true)
	var report: Dictionary = await b.project.sync(true)
	_check(a.remote_text("Shared.didsa") == "from the Quest" and a.fake.version_of(a.name, "Shared.didsa") == 2, "the first back online wins (v2)")
	var clash = b.project.state.queue["Shared.didsa"]["clash"]
	_check(clash != null and report["conflicts"].size() == 1 and str(clash["modified_by"]) == "Quest 3" and b.read_local("Shared.didsa") == "from the Phone, different", "the second is told who changed it, nothing is overwritten on the store, its own bytes stay in the mirror")
	var resolved: Dictionary = await b.project.resolve({"Shared.didsa": CloudProject.SAVE_COPY})
	await b.project.sync(true)
	var copies: Array = b.fake.live_paths(b.name).filter(func(p: String) -> bool: return p.begins_with("Shared (Phone"))
	_check(copies.size() == 1 and b.fake.file_bytes(b.name, copies[0]).get_string_from_utf8() == "from the Phone, different" and a.remote_text("Shared.didsa") == "from the Quest", "Save as a copy keeps both: the Phone's edit is a new file (%s), the Quest's stays" % str(copies))
	# Keep mine on a second clash
	var c := _rig()
	c.put_remote("K.didsa", "v1")
	var d := _device_on(c, "Phone", "hard_phone_2")
	await c.project.sync()
	await d.project.sync()
	await c.project.ensure_file("K.didsa")
	await d.project.ensure_file("K.didsa")
	c.write_local("K.didsa", "quest")
	await c.project.sync(true)
	d.write_local("K.didsa", "phone")
	await d.project.sync(true)
	await d.project.resolve({"K.didsa": CloudProject.KEEP_MINE})
	await d.project.sync(true)
	_check(d.remote_text("K.didsa") == "phone" and d.fake.version_of(d.name, "K.didsa") == 3 and d.project.state.queue.is_empty(), "Keep mine writes the Phone's file as v3 on top of the Quest's v2 (history keeps v2)")
	# Take theirs
	var e := _rig()
	e.put_remote("T.didsa", "v1")
	var f := _device_on(e, "Phone", "hard_phone_3")
	await e.project.sync()
	await f.project.sync()
	await e.project.ensure_file("T.didsa")
	await f.project.ensure_file("T.didsa")
	e.write_local("T.didsa", "quest wins")
	await e.project.sync(true)
	f.write_local("T.didsa", "phone loses")
	await f.project.sync(true)
	await f.project.resolve({"T.didsa": CloudProject.TAKE_THEIRS})
	_check(f.read_local("T.didsa") == "quest wins" and f.project.state.queue.is_empty() and f.fake.version_of(f.name, "T.didsa") == 2, "Take theirs loads the Quest's file; the Phone's edit is kept aside, the store has no third version")
	# the SAME edit on both: no clash
	var g := _rig()
	g.put_remote("Same.didsa", "v1")
	var h := _device_on(g, "Phone", "hard_phone_4")
	await g.project.sync()
	await h.project.sync()
	await g.project.ensure_file("Same.didsa")
	await h.project.ensure_file("Same.didsa")
	g.write_local("Same.didsa", "same edit")
	h.write_local("Same.didsa", "same edit")
	await g.project.sync(true)
	report = await h.project.sync(true)
	_check(report["conflicts"].is_empty() and h.project.state.queue.is_empty() and h.fake.version_of(h.name, "Same.didsa") == 2, "the same edit made on both devices is not a clash and is not saved twice")
	# two devices offline with a BIG file each: the loser's upload is not wasted work... but nothing is overwritten
	var i := _rig()
	i.put_remote("Big.didsa", "v1")
	var j := _device_on(i, "Phone", "hard_phone_5")
	await i.project.sync()
	await j.project.sync()
	await i.project.ensure_file("Big.didsa")
	await j.project.ensure_file("Big.didsa")
	i.write_local("Big.didsa", _big("q"))
	j.write_local("Big.didsa", _big("p"))
	await i.project.sync(true)
	report = await j.project.sync(true)
	_check(i.remote_text("Big.didsa") == _big("q") and not report["conflicts"].is_empty() and j.read_local("Big.didsa") == _big("p"), "two big edits offline: the first wins, the second is a clash (flagged at the feed, before it uploads 55 bytes for nothing)")


func _hash_cache() -> void:
	var r := _rig()
	r.write_local("A.didsa", "alpha")
	r.write_local("B.didsa", "bravo")
	r.project.scan()
	_check(r.project.state.stat.size() == 2 and str(r.project.state.stat["A.didsa"]["sha"]) == CloudFiles.hash_bytes("alpha".to_utf8_buffer()), "a scan records each file's size, mtime and hash")
	_fresh_project(r)
	_check(r.project.state.stat.size() == 2, "...and the record is on disk: it survives a restart")
	# prove the shortcut is taken: plant a wrong hash on a file whose size and mtime match and whose record is not racy
	var entry: Dictionary = r.project.state.stat["A.didsa"]
	entry["seen"] = int(entry["mtime"]) + 100
	entry["sha"] = "f".repeat(64)
	r.project.scan()
	_check(r.project.state.queue.has("A.didsa") and str(r.project.state.queue["A.didsa"]["sha"]) == "f".repeat(64), "a restart does not re-hash a file whose size and modified time are unchanged (the planted hash is believed)")
	# a changed size is always re-hashed
	var r2 := _rig()
	r2.write_local("A.didsa", "alpha")
	r2.project.scan()
	r2.project.state.stat["A.didsa"]["seen"] = int(r2.project.state.stat["A.didsa"]["mtime"]) + 100
	r2.project.state.stat["A.didsa"]["sha"] = "f".repeat(64)
	r2.write_local("A.didsa", "alpha plus")
	r2.project.scan()
	_check(str(r2.project.state.queue["A.didsa"]["sha"]) == CloudFiles.hash_bytes("alpha plus".to_utf8_buffer()), "a changed size is re-hashed whatever the record says")
	# a racy record (hashed within a second of the file's modification) is not trusted
	var r3 := _rig()
	r3.write_local("A.didsa", "alpha")
	r3.project.scan()
	r3.project.state.stat["A.didsa"]["sha"] = "e".repeat(64) # the record was taken the second the file was written: size and mtime cannot vouch for it
	r3.project.state.stat["A.didsa"]["seen"] = int(r3.project.state.stat["A.didsa"]["mtime"])
	r3.project.scan()
	_check(str(r3.project.state.queue["A.didsa"]["sha"]) == CloudFiles.hash_bytes("alpha".to_utf8_buffer()), "a record taken in the same second as the file's last write is re-hashed (the racy-timestamp rule)")
	# a file that left the mirror leaves the record
	r3.remove_local("A.didsa")
	r3.project.scan()
	_check(not r3.project.state.stat.has("A.didsa"), "a removed file's record is dropped")


func _cache_cleanup() -> void:
	# --- one project: what may go and what may never go
	var r := _rig()
	for name in ["Old", "Mid", "New", "Held", "Waiting", "Mine"]:
		r.put_remote(name + ".didsa", name.repeat(100))
	await r.project.sync()
	for name in ["Old", "Mid", "New", "Held", "Waiting", "Mine"]:
		await r.project.ensure_file(name + ".didsa")
	r.project.state.used["Old.didsa"] = 1000
	r.project.state.used["Mid.didsa"] = 2000
	r.project.state.used["New.didsa"] = 3000
	r.project.state.used["Held.didsa"] = 10
	r.project.state.used["Waiting.didsa"] = 20
	r.held = ["Held.didsa"]
	r.write_local("Waiting.didsa", "edited, not sent yet")
	r.write_local("Dragged.didsa", "dragged in by hand")
	r.project.scan()
	var order: Array = r.project.eviction_candidates().map(func(c: Dictionary) -> String: return c["path"])
	_check(order.slice(0, 3) == ["Mine.didsa", "Old.didsa", "Mid.didsa"] or order.slice(0, 3) == ["Old.didsa", "Mid.didsa", "New.didsa"] or (order.has("Old.didsa") and order.find("Old.didsa") < order.find("Mid.didsa") and order.find("Mid.didsa") < order.find("New.didsa")), "the clean-up candidates are the least recently used first (%s)" % str(order))
	_check(not order.has("Held.didsa") and not order.has("Waiting.didsa") and not order.has("Dragged.didsa"), "...and never a file the open session holds, one with a save waiting, or one that is only here")
	_check(not r.project.evict("Waiting.didsa") and not r.project.evict("Held.didsa") and not r.project.evict("Dragged.didsa") and r.local_exists("Waiting.didsa") and r.local_exists("Held.didsa") and r.local_exists("Dragged.didsa"), "...evicting one of those directly is refused and the files stay")
	_check(r.project.evict("Old.didsa") and not r.local_exists("Old.didsa") and r.project.file_state("Old.didsa") == "cloud" and r.project.state.queue.size() == 2, "an evicted file is 'in the cloud' (still listed, still on the store); nothing was queued or lost")
	var got: Dictionary = await r.project.ensure_file("Old.didsa")
	_check(got["ok"] and got["downloaded"] and r.read_local("Old.didsa") == "Old".repeat(100) and r.project.state.queue.size() == 2, "...and opening it downloads it again")
	# a file edited by hand after the sync is not clean: not evicted
	r.write_local("Mid.didsa", "changed on this headset")
	_check(not r.project.evict("Mid.didsa") and r.local_exists("Mid.didsa"), "a file changed since its sync is not clean: it cannot be evicted (it is a save)")

	# --- across projects, with the manager and the setting
	var base := ProjectSettings.globalize_path("user://cloud_test/hard_manager")
	Rig.wipe(base)
	var fake := FakeStore.new()
	for pname in ["Alpha", "Beta"]:
		fake.add_project(pname)
		for i in 3:
			fake.put_direct(pname, "F%d.didsa" % i, ("%s%d" % [pname, i]).repeat(1000), "Desktop") # 6-7 KB each
	var settings := AppSettings.new()
	settings.cloud_folder = base + "/DIDSA-Cloud"
	settings.cloud_cache_mb = 0
	var m := CloudManager.new()
	m.settings = settings
	m.transport = fake
	m.state_root = base + "/state"
	root.add_child(m)
	await process_frame
	m.configure("http://store.test", fake.key)
	await m.refresh_projects()
	for pname in ["Alpha", "Beta"]:
		await m.open_project(pname)
		for i in 3:
			await m.open_file(pname, "F%d.didsa" % i)
	var total: int = m.cache_used_bytes()
	_check(total > 30000 and m.cleanup_cache()["removed"].is_empty(), "with no limit (0) nothing is removed (%d bytes in use)" % total)
	m.project("Alpha").state.used["F0.didsa"] = 1
	m.project("Beta").state.used["F0.didsa"] = 2
	m.project("Alpha").state.used["F1.didsa"] = 3
	var limit := total - 12000
	var result: Dictionary = m.cleanup_cache(limit)
	var removed_names: Array = (result["removed"] as Array).map(func(x: Array) -> String: return "%s/%s" % [x[0], x[1]])
	_check(result["used"] <= limit and not result["over"] and removed_names.slice(0, 3) == ["Alpha/F0.didsa", "Beta/F0.didsa", "Alpha/F1.didsa"], "a limit below the total removes the least recently used files of ALL projects until it fits (%s)" % str(removed_names))
	_check(m.cache_used_bytes() == result["used"], "...and the sizes add up")
	# nothing but protected files left: the limit is reported as exceeded, nothing else is touched
	FileAccess.open(m.mirror_path("Beta") + "/F2.didsa", FileAccess.WRITE).store_string("edited, waiting")
	m.project("Beta").scan()
	var tiny: Dictionary = m.cleanup_cache(1)
	_check(tiny["over"] and FileAccess.file_exists(m.mirror_path("Beta") + "/F2.didsa") and m.project("Beta").state.queue.has("F2.didsa"), "when only a save waiting is left over the limit, it stays: the limit is reported exceeded, never met by deleting a save")
	# the setting and the page
	_check(Launcher.cache_text(2048) == "2 GB" and Launcher.cache_text(0) == "no limit" and Launcher.cache_text(512) == "512 MB" and Launcher.next_cache_mb(2048) == 5120 and Launcher.next_cache_mb(0) == 1024 and Launcher.next_cache_mb(777) == 1024, "the Servers page's size choices cycle 1 GB, 2 GB, 5 GB, 10 GB, no limit")
	settings.cloud_cache_mb = 3
	_check(m.cache_limit_bytes() == 3 * 1048576, "the limit is the setting in MB")
	m.queue_free()
