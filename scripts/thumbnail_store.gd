extends RefCounted
## S4: small pictures of files kept between runs, for the landing's Continue tile (and anything else that wants to show a file before it is opened). PNGs in
## user://thumbnails/<key>.png, `key` a hash of what the picture is OF (a file path). A picture older than the file it shows is the caller's business (it saves a new one
## whenever it opens the file); here: save, load, and a size limit so the folder can never grow without bound (the oldest go first). Nothing here renders anything.

const DIR := "user://thumbnails"
const DIR_ENV := "DIDSA_THUMBNAIL_DIR" ## tests: another folder
const MAX_FILES := 64
const MAX_BYTES := 8 * 1024 * 1024
const MAX_SIDE := 512 ## a picture larger than this is scaled down before it is kept


static func dir() -> String:
	var override := OS.get_environment(DIR_ENV)
	return override if override != "" else DIR


static func key_for(identity: String) -> String:
	return identity.strip_edges().sha256_text().substr(0, 32)


static func file_for(identity: String) -> String:
	return dir().path_join(key_for(identity) + ".png")


static func save(identity: String, image: Image) -> bool:
	## Keeps `image` as the picture of `identity`; false when there is no image or it can't be written. Prunes afterwards.
	if identity.strip_edges() == "" or image == null or image.is_empty():
		return false
	var keep := image.duplicate() as Image
	if maxi(keep.get_width(), keep.get_height()) > MAX_SIDE:
		var scale := float(MAX_SIDE) / float(maxi(keep.get_width(), keep.get_height()))
		keep.resize(maxi(1, int(keep.get_width() * scale)), maxi(1, int(keep.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	if not DirAccess.dir_exists_absolute(dir()):
		DirAccess.make_dir_recursive_absolute(dir())
	var target := file_for(identity)
	var temp := target + ".tmp"
	if keep.save_png(temp) != OK:
		DirAccess.remove_absolute(temp)
		return false
	if DirAccess.rename_absolute(temp, target) != OK:
		DirAccess.remove_absolute(temp)
		return false
	prune()
	return true


static func load_texture(identity: String, side: int = 0) -> Texture2D:
	## The kept picture (scaled to fit `side` pixels when that is > 0), or null (none kept, or the file is damaged: a damaged one is removed).
	var file := file_for(identity)
	if identity.strip_edges() == "" or not FileAccess.file_exists(file):
		return null
	var image := Image.new()
	if image.load(file) != OK or image.is_empty():
		DirAccess.remove_absolute(file)
		return null
	if side > 0 and maxi(image.get_width(), image.get_height()) > side:
		var scale := float(side) / float(maxi(image.get_width(), image.get_height()))
		image.resize(maxi(1, int(image.get_width() * scale)), maxi(1, int(image.get_height() * scale)), Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(image)


static func has(identity: String) -> bool:
	return identity.strip_edges() != "" and FileAccess.file_exists(file_for(identity))


static func forget(identity: String) -> void:
	if FileAccess.file_exists(file_for(identity)):
		DirAccess.remove_absolute(file_for(identity))


static func prune(max_files: int = MAX_FILES, max_bytes: int = MAX_BYTES) -> void:
	## At most `max_files` pictures and `max_bytes` together; the least recently written go first.
	var folder := DirAccess.open(dir())
	if folder == null:
		return
	var items: Array = []
	var total := 0
	for name in folder.get_files():
		var full := dir().path_join(name)
		if name.ends_with(".tmp"):
			DirAccess.remove_absolute(full) # (a write that was cut off)
			continue
		if not name.ends_with(".png"):
			continue
		var size := FileAccess.get_file_as_bytes(full).size()
		items.append({"path": full, "size": size, "at": FileAccess.get_modified_time(full)})
		total += size
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["at"]) < int(b["at"]))
	while not items.is_empty() and (items.size() > max_files or total > max_bytes):
		var oldest: Dictionary = items.pop_front()
		DirAccess.remove_absolute(str(oldest["path"]))
		total -= int(oldest["size"])
