extends SceneTree
## Tree B7 (spec section 12): the Assembly Tree's remembered open rows in app_settings.gd, no scene. Its own file (next to the settings file), an explicit stored-at order that
## survives a save and a load (a ConfigFile sorts dictionary keys, so the order is a list), the limits applied on every change AND on load (64 documents, 2,000 keys a
## document, 400,000 characters in all, oldest-stored first, never the newest), and the write delayed (restarted by each change) so a run of changes is one write and settings.cfg is not rewritten.
## Run: "$GODOT" --headless --path . --script res://tests/tree_open_settings.gd  (see tests/README.md)

const AppSettings := preload("res://scripts/app_settings.gd")
const SETTINGS := "user://tree_open_settings_test.cfg"
const TREE_FILE := "user://tree_open_settings_test_tree_open.cfg"


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func fresh() -> RefCounted:
	return AppSettings.new()


func docs_of(s: RefCounted) -> Array:
	return s.tree_open_docs.map(func(e): return e["doc"])


func clean() -> void:
	for f in [SETTINGS, TREE_FILE]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


func _initialize() -> void:
	var previous_path := OS.get_environment(AppSettings.PATH_ENV)
	OS.set_environment(AppSettings.PATH_ENV, SETTINGS)
	clean()
	check("the remembered rows have their own file next to the settings file", AppSettings.tree_open_path() == TREE_FILE)

	# --- the order survives a save and a load (alphabetical would be a, m, z)
	var s := fresh()
	for d in ["z.didsa", "a.didsa", "m.didsa"]:
		s.set_tree_open_keys(d, ["x"])
	s.save_to_disk()
	var back := fresh()
	back.load_from_disk()
	check("the stored order (oldest first) comes back as it was, not sorted", docs_of(back) == ["z.didsa", "a.didsa", "m.didsa"])
	back.set_tree_open_keys("z.didsa", ["y"])
	check("storing a document again makes it the newest", docs_of(back) == ["a.didsa", "m.didsa", "z.didsa"] and back.tree_open_keys("z.didsa") == ["y"])
	check("a document with nothing stored reads null; an empty set is remembered", back.tree_open_keys("none") == null and back.tree_open_keys("") == null)
	back.set_tree_open_keys("e", [])
	check("...an empty list is an entry", back.tree_open_keys("e") == [])

	# --- eviction by that order after a restart
	var full := fresh()
	for i in AppSettings.TREE_OPEN_MAX_DOCS:
		full.set_tree_open_keys("doc_%02d" % (AppSettings.TREE_OPEN_MAX_DOCS - 1 - i), ["k"]) # (names run backwards: the first stored, doc_63, sorts last)
	full.save_to_disk()
	var restarted := fresh()
	restarted.load_from_disk()
	check("%d documents are stored and come back in the same order" % AppSettings.TREE_OPEN_MAX_DOCS, restarted.tree_open_docs.size() == AppSettings.TREE_OPEN_MAX_DOCS and docs_of(restarted)[0] == "doc_63")
	restarted.set_tree_open_keys("one_more", ["k"])
	check("one past the limit after a restart: the oldest-stored goes (doc_63), not the alphabetical first", restarted.tree_open_docs.size() == AppSettings.TREE_OPEN_MAX_DOCS and restarted.tree_open_keys("doc_63") == null and restarted.tree_open_keys("doc_00") != null and docs_of(restarted).back() == "one_more")

	# --- the limits apply on load too (a file written by hand or by an older build)
	var config := ConfigFile.new()
	var big: Array = []
	for i in 100:
		var keys: Array = []
		for j in 3000:
			keys.append("k%d" % j)
		big.append({"doc": "big_%03d" % i, "keys": keys})
	big.append({"doc": "", "keys": ["x"]})
	big.append({"doc": "no_keys"})
	big.append("not a dictionary")
	config.set_value("docs", "list", big)
	config.save(TREE_FILE)
	var loaded := fresh()
	loaded.load_from_disk()
	var total := 0
	for e in loaded.tree_open_docs:
		total += loaded._tree_open_weight(e)
	check("on load: at most 64 documents, 2,000 keys each, the characters within the cap, bad entries skipped", loaded.tree_open_docs.size() <= AppSettings.TREE_OPEN_MAX_DOCS and loaded.tree_open_docs.all(func(e): return (e["keys"] as Array).size() <= AppSettings.TREE_OPEN_MAX_KEYS) and total <= AppSettings.TREE_OPEN_MAX_CHARS and not loaded.tree_open_docs.is_empty())
	check("...and what the cap drops is the oldest-stored: the last document written is still there, the first is not", loaded.tree_open_keys("big_099") != null and loaded.tree_open_keys("big_000") == null)
	var heavy := fresh()
	var long_keys: Array = []
	for j in 2000:
		long_keys.append("#group:%s/%s" % ["a".repeat(30), str(j)])
	for i in 12:
		heavy.set_tree_open_keys("heavy_%02d" % i, long_keys)
	var heavy_total := 0
	for e in heavy.tree_open_docs:
		heavy_total += heavy._tree_open_weight(e)
	check("a change over the character cap drops the oldest-stored documents (%d characters kept in %d documents)" % [heavy_total, heavy.tree_open_docs.size()], heavy_total <= AppSettings.TREE_OPEN_MAX_CHARS and heavy.tree_open_keys("heavy_11") != null and heavy.tree_open_keys("heavy_00") == null)
	check("a document's key list is cut at 2,000 on a change too", fresh().tree_open_keys("x") == null and (func() -> bool:
		var t := fresh()
		t.set_tree_open_keys("many", range(5000).map(func(i): return "k%d" % i))
		return (t.tree_open_keys("many") as Array).size() == 2000).call())
	# --- the newest entry is never the one the cap evicts: its own keys are cut from the tail (the parents, first in the spec's order, stay) instead
	var capped := fresh()
	capped.set_tree_open_keys("small", ["a"])
	var wide: Array = []
	for j in 2000:
		wide.append("#group:%s/%04d" % ["b".repeat(280), j]) # (about 300 characters each: 600,000 in all, over the cap alone)
	capped.set_tree_open_keys("wide", wide)
	var capped_keys = capped.tree_open_keys("wide")
	var capped_total := 0
	for e in capped.tree_open_docs:
		capped_total += capped._tree_open_weight(e)
	check("the entry just stored survives the cap even when it alone is over it (the older documents go first)", capped_keys != null and capped.tree_open_keys("small") == null and docs_of(capped) == ["wide"])
	check("...its own keys are shortened to fit, from the tail (the head of its list, the parents, is kept)", capped_total <= AppSettings.TREE_OPEN_MAX_CHARS and not (capped_keys as Array).is_empty() and capped_keys[0] == wide[0] and capped_keys.back() != wide.back() and capped_keys == wide.slice(0, capped_keys.size()))
	capped.set_tree_open_keys("x".repeat(AppSettings.TREE_OPEN_MAX_CHARS + 1), ["a"])
	check("...a document name that alone is over the cap is not stored (the cap stays true)", capped.tree_open_keys("x".repeat(AppSettings.TREE_OPEN_MAX_CHARS + 1)) == null and docs_of(capped) == ["wide"])
	var big_name := "n".repeat(AppSettings.TREE_OPEN_MAX_CHARS - 2)
	capped.set_tree_open_keys(big_name, ["abc", "d"])
	check("...nor is a name whose first key cannot fit beside it", capped.tree_open_keys(big_name) == null and docs_of(capped) == ["wide"])
	capped.set_tree_open_keys(big_name, ["ab"])
	capped.set_tree_open_keys(big_name, ["abc", "d"])
	check("...and an older entry for such a name is removed, not left to come back as rows the person no longer has", capped.tree_open_keys(big_name) == null)
	capped.set_tree_open_keys(big_name, ["ab"])
	check("...while one whose first key just fits is (and the older entry makes way)", capped.tree_open_keys(big_name) == ["ab"])

	# --- on load: an entry whose name alone is over the cap, or whose first key cannot fit, is skipped (it would only be cut to nothing); the others stay
	var bad_file := ConfigFile.new()
	bad_file.set_value("docs", "list", [
		{"doc": "good_one", "keys": ["a"]},
		{"doc": "y".repeat(AppSettings.TREE_OPEN_MAX_CHARS + 1), "keys": ["a"]},
		{"doc": "w".repeat(AppSettings.TREE_OPEN_MAX_CHARS - 1), "keys": ["kk", "k"]},
		{"doc": "good_two", "keys": ["b"]},
	])
	bad_file.save(TREE_FILE)
	var skipping := fresh()
	skipping.load_tree_open()
	check("on load a name over the cap, and one whose first key cannot fit, are skipped; the entries around them stay in order: %s" % str(docs_of(skipping).map(func(d): return str(d).substr(0, 8))), docs_of(skipping) == ["good_one", "good_two"])
	clean()

	# --- the write is delayed: a run of changes is one write, and settings.cfg is not written
	var d := fresh()
	d.load_from_disk()
	for i in 10:
		d.set_tree_open_keys("run_%d" % i, ["a"])
	check("ten changes in a row: nothing written yet, a write is waiting", not FileAccess.file_exists(TREE_FILE) and d._tree_open_dirty)
	await create_timer(AppSettings.TREE_OPEN_SAVE_DELAY_S + 0.4).timeout
	check("...the delayed write has run (one file with all ten, in order), and settings.cfg was never written", FileAccess.file_exists(TREE_FILE) and not d._tree_open_dirty and not FileAccess.file_exists(SETTINGS))
	var again := fresh()
	again.load_tree_open()
	check("...and reads back", docs_of(again) == range(10).map(func(i): return "run_%d" % i))
	d.set_tree_open_keys("late", ["a"])
	d.flush_tree_open()
	var flushed := fresh()
	flushed.load_tree_open()
	check("flush_tree_open writes at once (what main.gd does when the app pauses or quits)", flushed.tree_open_keys("late") == ["a"] and not d._tree_open_dirty)

	# --- a debounce, not a throttle: each change restarts the wait
	var deb := fresh()
	deb.set_tree_open_keys("one", ["a"])
	await create_timer(AppSettings.TREE_OPEN_SAVE_DELAY_S * 0.6).timeout
	deb.set_tree_open_keys("two", ["a"]) # (0.9 s in: the first change's wait would end at 1.5 s)
	await create_timer(AppSettings.TREE_OPEN_SAVE_DELAY_S * 0.6).timeout
	check("a second change 0.9 s in moves the write: at 1.8 s nothing is written yet", deb._tree_open_dirty)
	await create_timer(AppSettings.TREE_OPEN_SAVE_DELAY_S * 0.6).timeout
	check("...and it is written the full delay after the last change, both documents in it", not deb._tree_open_dirty and (func() -> bool:
		var back2 := fresh()
		back2.load_tree_open()
		return docs_of(back2).has("one") and docs_of(back2).has("two")).call())

	# --- ...but a run of changes cannot hold the write back for ever: a maximum wait
	var capped_wait := fresh()
	capped_wait.tree_open_max_wait_s = 2.0
	for i in 5: # (0.9 s apart: the plain wait of 1.5 s never ends in between)
		capped_wait.set_tree_open_keys("run", [str(i)])
		await create_timer(0.9).timeout
	check("changes 0.9 s apart for 4.5 s are written within the maximum wait (2 s), not held back until they stop", FileAccess.file_exists(TREE_FILE) and (func() -> bool:
		var back3 := fresh()
		back3.load_tree_open()
		return back3.tree_open_keys("run") != null).call())
	capped_wait.flush_tree_open()

	# --- B8.1: a later stored entry that cannot be kept still replaces the earlier one for its document (storing removes the old one too)
	var unfit := ConfigFile.new()
	unfit.set_value("docs", "list", [{"doc": "same.didsa", "keys": ["early"]}, {"doc": "other.didsa", "keys": ["o"]}, {"doc": "same.didsa", "keys": ["x".repeat(AppSettings.TREE_OPEN_MAX_CHARS + 1)]}])
	unfit.save(TREE_FILE)
	var unfit_back := fresh()
	unfit_back.load_tree_open()
	check("B8.1 a later entry for a document that is over the cap drops the earlier one: the document reads as having nothing stored", unfit_back.tree_open_keys("same.didsa") == null and unfit_back.tree_open_keys("other.didsa") == ["o"])

	# --- Save As with no tree: the entry is copied
	var c := fresh()
	c.set_tree_open_keys("old.didsa", ["p", "q"])
	c.copy_tree_open_keys("old.didsa", "new.didsa")
	c.copy_tree_open_keys("never.didsa", "other.didsa")
	check("copy_tree_open_keys gives the new file the old one's rows (and does nothing for a file with none)", c.tree_open_keys("new.didsa") == ["p", "q"] and c.tree_open_keys("old.didsa") == ["p", "q"] and c.tree_open_keys("other.didsa") == null)
	c.flush_tree_open()
	clean()
	OS.set_environment(AppSettings.PATH_ENV, previous_path)
	quit(0)
