extends RefCounted
## Graphics switches read once at startup from user://graphics.cfg, to find a fault on the headset without a rebuild (docs/quest-first-run-fixes.md B2:
## on the Quest 3 each eye showed one flat colour, so the Graphics check page could not be seen). Push the file with adb (debug APK):
##   adb push graphics.cfg /data/local/tmp/graphics.cfg
##   adb shell run-as uk.didsa.vr cp /data/local/tmp/graphics.cfg files/graphics.cfg
## then restart the app. Every key is optional; what is applied is printed to the log ("DIDSA VR: graphics.cfg: ...").
##   [graphics]
##   foveation=0        ; OpenXR foveated rendering level 0 (off) .. 3, instead of the project setting
##   vrs="xr"           ; "xr": the viewport uses the headset's foveation map (Viewport.VRS_XR), "off": it does not
##   msaa=0             ; 0 off, 1 2x, 2 4x
##   sky="plain"        ; the landing's night sky: "shader" or "plain" (a flat colour)
##   fog=false          ; the landing's fog
##   rockets=false      ; the landing's rocket garden
##   glow=false         ; the glow behind the landing's logo

const PATH := "user://graphics.cfg"
const PATH_ENV := "DIDSA_GRAPHICS_PATH" ## tests point this at their own file

var values := {} ## only the keys the file sets


static func path() -> String:
	var override := OS.get_environment(PATH_ENV)
	return override if override != "" else PATH


func load_from_disk() -> bool:
	## True if a file was read.
	var config := ConfigFile.new()
	if config.load(path()) != OK:
		return false
	for key in ["foveation", "vrs", "msaa", "sky", "fog", "rockets", "glow"]:
		if config.has_section_key("graphics", key):
			values[key] = config.get_value("graphics", key)
	return true


func has(key: String) -> bool:
	return values.has(key)


func get_value(key: String, default: Variant = null) -> Variant:
	return values.get(key, default)


func describe() -> String:
	if values.is_empty():
		return "no overrides"
	var parts := PackedStringArray()
	for key in values:
		parts.append("%s=%s" % [key, str(values[key])])
	return ", ".join(parts)
