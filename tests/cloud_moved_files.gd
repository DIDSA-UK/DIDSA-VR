extends SceneTree
## S3: the moved-files rule against the store (DIDSA-CAD docs/moved-files-scope.md; docs/shared-storage-scope.md section 9): opening a server project's assembly brings into the
## mirror the file at each reference's path and, for a reference whose file moved, the file the STORE'S part index names (GET .../parts/{part_id}, or the tree's own part ids
## offline) instead of reading every file; native_compose.gd then reads the mirror UNCHANGED and finds the moved Part by its id. Counted by requests on a fake store.
## NOT covered: the real store's index (tests/e2e_cloud_store.gd), many copies of one id on the real store (the rule's own tests are tests/moved_files.gd).
## Run: "$GODOT" --headless --path . --script res://tests/cloud_moved_files.gd  (see tests/README.md)

const Rig := preload("res://tests/cloud_rig.gd")
const NativeCompose := preload("res://scripts/native_compose.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _fill(r: Rig) -> void:
	r.put_remote("Asm.didsa", Rig.native("p-asm", "", [{"ref": "Shaft.didsa", "id": "p-shaft"}, {"ref": "Pin.didsa", "id": "p-pin"}]))
	r.put_remote("parts/Shaft.didsa", Rig.native("p-shaft", "moved"))
	r.put_remote("Pin.didsa", Rig.native("p-pin", "in place"))
	r.put_remote("other/Decoy.didsa", Rig.native("p-decoy", "never needed"))
	r.put_remote("readme.txt", "not a model")


func _initialize() -> void:
	var r := Rig.new("moved_1")
	_fill(r)
	await r.project.sync()
	var mark: int = r.fake.requests.size()
	var opened: Dictionary = await r.project.prepare_open("Asm.didsa")
	var gets: Array = r.fake.requests.slice(mark).filter(func(q: Dictionary) -> bool: return q["method"] == "GET" and "/files/" in q["path"]).map(func(q: Dictionary) -> String: return q["path"].get_slice("/files/", 1).uri_decode())
	gets.sort()
	_check(opened["ok"] and opened["missing"].is_empty() and gets == ["Asm.didsa", "Pin.didsa", "parts/Shaft.didsa"], "opening an assembly downloads it, the file at a reference's path and the file the part index names, nothing else (%s)" % str(gets))
	_check(not r.local_exists("other/Decoy.didsa") and not r.local_exists("readme.txt"), "...the files nothing placed are not downloaded")
	var asked: Array = r.fake.requests_matching("GET", "/projects/Gearbox/parts/")
	_check(asked.size() == 1 and asked[0]["path"].ends_with("/parts/p-shaft"), "the moved reference is looked up with ONE call to the store's part index, not by reading files")
	var composed: Dictionary = NativeCompose.compose(r.local("Asm.didsa"), [r.mirror])
	var relinked: Array = composed["relinked"]
	_check(composed["ok"] and composed["unresolved"].is_empty() and relinked.size() == 1 and relinked[0]["via"] == "id" and relinked[0]["path"] == "parts/Shaft.didsa", "native_compose.gd reads the mirror unchanged and finds the moved Part by its id, via the index")
	_check(composed["part_files"].has("p-shaft") and str(composed["part_files"]["p-shaft"]).ends_with("/parts/Shaft.didsa"), "...so a save writes the Part back to its file in the mirror")
	# the index call fails (connection drops): the tree's own part ids answer
	var t := Rig.new("moved_2")
	_fill(t)
	await t.project.sync()
	t.fake.fail_next("/projects/Gearbox/parts/", 0)
	opened = await t.project.prepare_open("Asm.didsa")
	_check(opened["ok"] and t.local_exists("parts/Shaft.didsa") and t.fake.requests_matching("GET", "/projects/Gearbox/parts/").size() == 1, "if the part index can't be reached, the tree's part ids answer, and the file is still fetched")
	# offline: what is in the mirror opens; what is not says so
	var o := Rig.new("moved_3")
	_fill(o)
	await o.project.sync()
	await o.project.ensure_file("Asm.didsa")
	await o.project.ensure_file("Pin.didsa")
	o.restart()
	o.fake.offline = true
	opened = await o.project.prepare_open("Asm.didsa")
	_check(opened["ok"] and opened["missing"].size() == 1 and not o.local_exists("parts/Shaft.didsa"), "offline, the files already in the mirror open and a file that was never downloaded is reported missing, not an error")
	var n := Rig.new("moved_4")
	opened = await n.project.prepare_open("Nope.didsa")
	_check(not opened["ok"] and opened["error"].contains("Nope.didsa"), "a root file that is neither here nor in the store is an error that names it")
	# a file whose reference is by name only (no part id) is found by its extension-less name
	var e := Rig.new("moved_5")
	e.put_remote("Asm.didsa", JSON.stringify({"schema_version": 1, "document": {"id": "d", "root_part_id": "p-asm", "parts": [{"id": "p-asm", "name": "A", "occurrences": [{"id": "o1", "resolved_part_id": "p-gear", "external_ref": "Gear.DIDSAprt"}]}]}, "sketches": []}))
	e.put_remote("Gear.didsa", Rig.native("p-gear", ""))
	await e.project.sync()
	opened = await e.project.prepare_open("Asm.didsa")
	_check(opened["ok"] and e.local_exists("Gear.didsa"), "a reference written under another native extension still finds its file (native_compose.gd's rule)")
	quit(0)
