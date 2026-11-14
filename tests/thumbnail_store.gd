extends SceneTree
## S4: scripts/thumbnail_store.gd, the kept pictures behind the landing's Continue tile, headless (it renders nothing; tests/thumbnail_render.gd draws a real one under Xvfb):
## a stable key, save then load (scaled down to a requested side), a picture that is too big is shrunk, nothing for an unknown file or an empty image, a damaged file is
## removed instead of crashing, a cut-off write is cleaned up, the folder is pruned to a count and to a size (the oldest first), and forgetting.
## Run: "$GODOT" --headless --path . --script res://tests/thumbnail_store.gd  (see tests/README.md)

const ThumbnailStore := preload("res://scripts/thumbnail_store.gd")


func _check(ok: bool, label: String) -> void:
	print("SMOKE ", label, ": ", ok)


func _image(side: int, colour: Color) -> Image:
	var image := Image.create(side, side, false, Image.FORMAT_RGBA8)
	image.fill(colour)
	return image


func _wipe() -> void:
	var folder := DirAccess.open(ThumbnailStore.dir())
	if folder != null:
		for name in folder.get_files():
			DirAccess.remove_absolute(ThumbnailStore.dir().path_join(name))


func _initialize() -> void:
	OS.set_environment(ThumbnailStore.DIR_ENV, "user://thumbnails_test")
	DirAccess.make_dir_recursive_absolute(ThumbnailStore.dir())
	_wipe()
	_check(ThumbnailStore.key_for("/a/b.didsa") == ThumbnailStore.key_for(" /a/b.didsa ") and ThumbnailStore.key_for("/a/b.didsa") != ThumbnailStore.key_for("/a/c.didsa") and ThumbnailStore.key_for("x").length() == 32, "a picture's key is a stable hash of the file it shows")
	_check(not ThumbnailStore.has("/a/b.didsa") and ThumbnailStore.load_texture("/a/b.didsa") == null, "no picture kept yet: none")
	_check(ThumbnailStore.save("/a/b.didsa", _image(64, Color(1, 0, 0))) and ThumbnailStore.has("/a/b.didsa"), "a picture is kept")
	var back: Texture2D = ThumbnailStore.load_texture("/a/b.didsa")
	_check(back != null and back.get_width() == 64 and back.get_image().get_pixel(10, 10).is_equal_approx(Color(1, 0, 0)), "...and comes back the same")
	var small: Texture2D = ThumbnailStore.load_texture("/a/b.didsa", 32)
	_check(small != null and small.get_width() == 32, "...or scaled to fit a side")
	ThumbnailStore.save("/a/big.didsa", _image(1024, Color(0, 1, 0)))
	_check(ThumbnailStore.load_texture("/a/big.didsa").get_width() == ThumbnailStore.MAX_SIDE, "a picture bigger than the limit is shrunk when kept")
	_check(not ThumbnailStore.save("", _image(8, Color.WHITE)) and not ThumbnailStore.save("/a/n.didsa", null) and not ThumbnailStore.save("/a/e.didsa", Image.new()), "no name, no image or an empty image keeps nothing")
	# a damaged file
	var f := FileAccess.open(ThumbnailStore.file_for("/a/bad.didsa"), FileAccess.WRITE)
	f.store_string("this is not a png")
	f.close()
	_check(ThumbnailStore.load_texture("/a/bad.didsa") == null and not FileAccess.file_exists(ThumbnailStore.file_for("/a/bad.didsa")), "a damaged picture is no picture, and is removed")
	# a cut-off write
	var t := FileAccess.open(ThumbnailStore.file_for("/a/cut.didsa") + ".tmp", FileAccess.WRITE)
	t.store_string("half")
	t.close()
	ThumbnailStore.prune()
	_check(not FileAccess.file_exists(ThumbnailStore.file_for("/a/cut.didsa") + ".tmp"), "a half-written temp file is cleaned up")
	# the count limit
	_wipe()
	for i in 10:
		ThumbnailStore.save("/f/%d.didsa" % i, _image(16, Color(0.1 * i, 0, 0)))
	ThumbnailStore.prune(4, ThumbnailStore.MAX_BYTES)
	var left := 0
	for i in 10:
		if ThumbnailStore.has("/f/%d.didsa" % i):
			left += 1
	_check(left == 4, "the folder is pruned to the file count (%d left of 10, limit 4)" % left)
	# the size limit
	ThumbnailStore.prune(100, 1)
	var after := DirAccess.open(ThumbnailStore.dir()).get_files().size()
	_check(after == 0, "...and to the size in bytes (a 1-byte limit empties it)")
	ThumbnailStore.save("/g.didsa", _image(8, Color.BLUE))
	ThumbnailStore.forget("/g.didsa")
	_check(not ThumbnailStore.has("/g.didsa"), "a picture can be forgotten")
	_wipe()
	quit()
