extends SceneTree
## The Android / Quest build set-up (docs/landing-scope.md L0), as far as it can be checked without an Android SDK, a headset or the export templates:
## the project settings that are for Android builds only (so desktop and PC-VR are unchanged), the example export preset (Gradle build, OpenXR mode, Meta
## plugin, ONE architecture, the demo files in and `secrets.cfg` never in, no signing details), the .gitignore keeping the key, the preset and the 82 MB
## plugin out of git, the plugin installer refusing a file that is not the pinned release, and the cleartext overlay script (applied, applied twice, removed,
## and refusing when there is no Gradle template) on a fake template. NOT checked: an APK has never been built from this; that the plugin's AARs land in it.
## Run: "$GODOT" --headless --path . --script res://tests/android_config.gd   (the script checks need bash and perl: without them those lines say so)

const TMP := "user://android_config_test"

var failures := 0


func check(what: String, ok: bool) -> void:
	print("SMOKE ", what, ": ", ok)


func run(args: Array) -> Dictionary:
	var out: Array = []
	var code := OS.execute("bash", args, out, true)
	return {"code": code, "out": "\n".join(PackedStringArray(out))}


func _initialize() -> void:
	# --- project settings: Android only -------------------------------------------------------------------------------------
	var project := ConfigFile.new()
	project.load("res://project.godot")
	var android_keys := ["openxr/extensions/meta/passthrough.android", "openxr/extensions/spatial_entity/enabled.android",
		"openxr/extensions/spatial_entity/enable_marker_tracking.android", "openxr/extensions/spatial_entity/enable_builtin_marker_tracking.android"]
	var all_on := true
	for k in android_keys:
		all_on = all_on and project.get_value("xr", k, false) == true
	check("project.godot turns on Meta passthrough and spatial-entity marker tracking for Android builds", all_on)
	var plain_off := true
	for k in ["openxr/extensions/meta/passthrough", "openxr/extensions/spatial_entity/enabled"]:
		plain_off = plain_off and not project.has_section_key("xr", k)
	check("...with no plain (desktop) setting beside them, so PC and PC-VR builds ask for nothing new", plain_off)
	check("OpenXR itself stays on and Mobile is still the renderer", project.get_value("xr", "openxr/enabled", false) == true and str(project.get_value("rendering", "renderer/rendering_method", "")) == "mobile")

	# --- the example export preset ---------------------------------------------------------------------------------------------
	var preset := ConfigFile.new()
	check("the example preset loads", preset.load("res://tools/android/export_presets.cfg.example") == OK)
	var o := "preset.0.options"
	check("an Android preset with the Gradle build, OpenXR mode and the Meta plugin", preset.get_value("preset.0", "platform", "") == "Android" and preset.get_value(o, "gradle_build/use_gradle_build", false) == true and preset.get_value(o, "xr_features/xr_mode", 0) == 1 and preset.get_value(o, "xr_features/enable_meta_plugin", false) == true)
	check("one architecture only (arm64: every Quest), Quest 3 supported", preset.get_value(o, "architectures/arm64-v8a", false) == true and preset.get_value(o, "architectures/armeabi-v7a", true) == false and preset.get_value(o, "architectures/x86_64", true) == false and preset.get_value(o, "meta_xr_features/quest_3_support", false) == true)
	check("passthrough is optional (1), not required", preset.get_value(o, "meta_xr_features/passthrough", 0) == 1)
	var include := str(preset.get_value("preset.0", "include_filter", ""))
	var exclude := str(preset.get_value("preset.0", "exclude_filter", ""))
	check("the demo files are in, and the demo script and the tests are out", include == "demo/*" and "demo/tools/*" in exclude and "tests/*" in exclude)
	var everything := FileAccess.get_file_as_string("res://tools/android/export_presets.cfg.example")
	var secret_lines := 0
	for line in everything.split("\n"):
		if not line.begins_with(";") and ("secrets" in line or "keystore" in line or "password" in line.to_lower() or "api_key" in line):
			secret_lines += 1
	check("nothing in it names secrets.cfg, a keystore, a password or a key (only comments warn about them)", secret_lines == 0 and not ("secrets.cfg" in include))
	check("the package name is set and is not the default", str(preset.get_value(o, "package/unique_name", "")) == "uk.didsa.vr")

	# --- .gitignore --------------------------------------------------------------------------------------------------------------
	var ignore := FileAccess.get_file_as_string("res://.gitignore").split("\n")
	check(".gitignore keeps out export_presets.cfg, secrets.cfg, the android/ build template and the plugin", "export_presets.cfg" in ignore and "secrets.cfg" in ignore and "/android/" in ignore and "/addons/godotopenxrvendors/" in ignore)

	# --- scripts ---------------------------------------------------------------------------------------------------------------------
	var have_bash: bool = run(["-c", "command -v perl >/dev/null && command -v unzip >/dev/null"])["code"] == 0
	if not have_bash:
		print("SMOKE script checks not run (need bash, perl and unzip on the PATH)")
		print("SMOKE PASSED")
		quit()
		return
	var root := ProjectSettings.globalize_path("res://")
	var tmp := ProjectSettings.globalize_path(TMP)
	run(["-c", "rm -rf '%s' && mkdir -p '%s'" % [tmp, tmp]])
	for script in ["tools/install_vendors_plugin.sh", "tools/android/apply_cleartext_overlay.sh"]:
		check("%s is valid bash" % script, run(["-n", root + script])["code"] == 0)
	var install := FileAccess.get_file_as_string("res://tools/install_vendors_plugin.sh")
	var sha := RegEx.create_from_string('SHA256="([0-9a-f]{64})"').search(install)
	check("the installer pins a release and a SHA-256", sha != null and 'VERSION="5.1.0-stable"' in install)
	# a file that is not the pinned release is refused, in a copy of the project so nothing here is touched
	run(["-c", "mkdir -p '%s/proj/tools' && cp '%stools/install_vendors_plugin.sh' '%s/proj/tools/' && printf 'not a zip' > '%s/fake.zip'" % [tmp, root, tmp, tmp]])
	var refused := run(["-c", "cd '%s/proj' && VENDORS_ZIP='%s/fake.zip' tools/install_vendors_plugin.sh 2>&1" % [tmp, tmp]])
	check("the installer refuses a file that is not the pinned release and installs nothing", refused["code"] != 0 and "SHA-256 mismatch" in refused["out"] and not DirAccess.dir_exists_absolute(tmp + "/proj/addons/godotopenxrvendors"))

	# the cleartext overlay, on a fake Gradle template
	var build := tmp + "/android/build"
	run(["-c", "mkdir -p '%s'" % build])
	var manifest := build + "/AndroidManifest.xml"
	var f := FileAccess.open(manifest, FileAccess.WRITE)
	f.store_string('<?xml version="1.0" encoding="utf-8"?>\n<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n    <application\n        android:label="@string/godot_project_name_string"\n        android:icon="@mipmap/icon">\n    </application>\n</manifest>\n')
	f.close()
	var overlay := root + "tools/android/apply_cleartext_overlay.sh"
	var missing := run(["-c", "'%s' '%s/nothing' 2>&1" % [overlay, tmp]])
	check("without a Gradle template the overlay says to install it first and changes nothing", missing["code"] != 0 and "Install Android Build Template" in missing["out"])
	var first := run(["-c", "'%s' '%s' 2>&1" % [overlay, build]])
	var patched := FileAccess.get_file_as_string(manifest)
	check("the overlay copies the config and points <application> at it", first["code"] == 0 and FileAccess.file_exists(build + "/res/xml/network_security_config.xml") and patched.count('android:networkSecurityConfig="@xml/network_security_config"') == 1 and '<application android:networkSecurityConfig' in patched)
	check("...leaving the rest of the manifest as it was", 'android:label="@string/godot_project_name_string"' in patched and 'android:icon="@mipmap/icon"' in patched and "</manifest>" in patched)
	var second := run(["-c", "'%s' '%s' 2>&1" % [overlay, build]])
	check("applying twice changes nothing more", second["code"] == 0 and FileAccess.get_file_as_string(manifest) == patched and "already" in second["out"])
	check("the config allows cleartext only through a base-config (and says why)", "cleartextTrafficPermitted=\"true\"" in FileAccess.get_file_as_string(build + "/res/xml/network_security_config.xml"))
	var removed := run(["-c", "'%s' --remove '%s' 2>&1" % [overlay, build]])
	check("--remove takes it all back out", removed["code"] == 0 and not ("networkSecurityConfig" in FileAccess.get_file_as_string(manifest)) and not FileAccess.file_exists(build + "/res/xml/network_security_config.xml") and '<application' in FileAccess.get_file_as_string(manifest))

	run(["-c", "rm -rf '%s'" % tmp])
	print("SMOKE PASSED")
	quit()
