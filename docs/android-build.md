# Building the Quest APK (step L0)

Scope: [`landing-scope.md`](landing-scope.md) step L0. This page is what to do on **your machine** to get a standalone Quest build with passthrough. Everything
here was prepared in a cloud session with **no Android SDK, no export templates and no headset**, so **an APK has never been built from this**. What was
checked, and what was not, is at the end.

## What L0 adds

| Need | How |
|---|---|
| Passthrough on a standalone Quest (to see the screen with the pairing QR code, and mixed reality in general) | the **OpenXR Vendors plugin** (Meta part) in a **Gradle** Android build; project setting `xr/openxr/extensions/meta/passthrough`, on in `project.godot` for Android (`.android`, the app on the headset) **and** for the editor (`.editor_hint`, which is when the plugin writes the manifest; see [the trap](#the-android-only-setting-trap)) |
| The QR scan's Android permission | the plugin adds `com.oculus.permission.USE_SCENE` and `USE_ANCHOR_API` to the manifest by itself while `xr/openxr/extensions/spatial_entity/enabled` reads true in the editor at export time (`.editor_hint`, as above). The app asks for the permission at run time when the Scan page starts |
| Plain `http://` to a LAN server | probably already works (Godot's `HTTPRequest` uses its own sockets). **Only if a headset test says it is blocked:** `tools/android/apply_cleartext_overlay.sh` |
| QR route B (camera + decoder) | not built; see [Route B](#route-b-if-route-a-fails) |

The plugin is an addon: **the project's one deliberate exception to "no addons"** (`CLAUDE.md`). It is not committed (82 MB of native libraries); a script
fetches it, pinned to one release and checked against its SHA-256.

## One-time set-up

1. **Tools:** JDK 17, the Android SDK (Android Studio, or the command-line tools with `sdkmanager`), and Godot 4.7.2 with its **export templates**
   (Editor > Manage Export Templates; the Android ones are `android_debug.apk`, `android_release.apk` and `android_source.zip`). Godot installs none of the JDK or
   the SDK. Versions, from Godot's 4.7 "Exporting for Android" page (check it for newer ones): **Platform-Tools 35.0.0+, Build-Tools 35.0.1, Platform
   android-35, Command-line Tools (latest), CMake 3.10.2.4988404, NDK 28.1.13356709**; `sdkmanager "platform-tools" "build-tools;35.0.1" "platforms;android-35"
   "cmdline-tools;latest" "cmake;3.10.2.4988404" "ndk;28.1.13356709"`. Godot's page recommends OpenJDK 17 and says newer is supported; a newer JDK may be refused
   by the Gradle version in the build template (then use 17). A debug APK was built from this set-up on Windows with JDK 17 and Android Studio's SDK (21 Oct 2026).
   In the editor: **Editor > Editor Settings > Export > Android**: set the **Android SDK path** (Android Studio's SDK Location, the folder that holds
   `platform-tools`), the **Java SDK path** (the JDK folder that holds `bin`) and a **debug keystore** (a file, not a folder: make one with
   `keytool -genkeypair -v -keystore debug.keystore -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 9999 -storepass android -keypass android
   -dname "CN=Android Debug,O=Android,C=US"` and set the user `androiddebugkey`, password `android`). For a headless export use the environment variables
   `GODOT_ANDROID_KEYSTORE_DEBUG_PATH`, `..._USER`, `..._PASSWORD`.
2. **Gradle build template:** open the project in the editor, **Project > Install Android Build Template**. It writes `android/` (git-ignored).
3. **The plugin:** `tools/install_vendors_plugin.sh` (needs bash, `curl` and `unzip`; or `VENDORS_ZIP=...` with the file from
   `https://github.com/GodotVR/godot_openxr_vendors/releases/tag/5.1.0-stable`, `godotopenxrvendorsaddon.zip`). Then **open the project in the editor once** so
   it imports the extension. (5.x is a GDExtension: there is no "enable plugin" tick.) Needs Godot 4.6 or later.
   **On Windows** `bash` is usually the WSL launcher, which fails ("execvpe(/bin/bash) failed") when no Linux distribution is installed, and Git Bash has no
   `unzip`. Do the same steps in PowerShell from the project folder (close the editor first; the last line should print `True`):
   ```
   $ver = "5.1.0-stable"
   $want = "6a838dbdf4115549e4511ebee0da9a5dcc8f9f6258d4cc2f2ee57a907a3e2911"   # the SHA-256 pinned in tools/install_vendors_plugin.sh
   $url = "https://github.com/GodotVR/godot_openxr_vendors/releases/download/$ver/godotopenxrvendorsaddon.zip"
   $zip = "$env:TEMP\vendors.zip"
   Invoke-WebRequest $url -OutFile $zip
   $got = (Get-FileHash $zip -Algorithm SHA256).Hash
   if ($got -ine $want) { throw "SHA-256 mismatch: expected $want, got $got. Not installing." }
   Remove-Item -Recurse -Force "$env:TEMP\vendors_x" -ErrorAction SilentlyContinue
   Expand-Archive $zip -DestinationPath "$env:TEMP\vendors_x"
   New-Item -ItemType Directory -Force addons | Out-Null
   Remove-Item -Recurse -Force addons\godotopenxrvendors -ErrorAction SilentlyContinue
   Copy-Item -Recurse "$env:TEMP\vendors_x\asset\addons\godotopenxrvendors" addons\godotopenxrvendors
   Set-Content addons\godotopenxrvendors\.installed-version $ver
   Test-Path addons\godotopenxrvendors\plugin.gdextension
   ```
4. **The export preset:** copy `tools/android/export_presets.cfg.example` to `export_presets.cfg` (git-ignored: it can hold signing details; never commit it), or
   make the same choices in Project > Export. The choices that matter:
   - **Use Gradle Build** on; **arm64-v8a** only; package `uk.didsa.vr` (change it if you want another id).
   - **Permissions > Internet on.** Godot leaves it **off** by default, and then the app cannot reach any server: every Test or pairing says "Could not reach
     the server" (the first pairing on a Quest 3, 22 Oct 2026). The example preset has `permissions/internet=true`; on Android the app's message now names it.
   - **XR Mode: OpenXR**. With the plugin installed, the Export dialog (Options tab) gains **Android XR Features**, **Meta XR Features** (Quest 1 / 2 / 3 / Pro
     support, boundary mode, overlay keyboard, instant splash screen, experimental features) and **Pico XR Features**: leave Quest 2, Quest 3 and Quest Pro on for
     a Quest 3. **XR Features > Enable Meta Plugin must be ticked** (it is off by default; `xr_features/enable_meta_plugin=true` in `export_presets.cfg`).
     It sits in the **XR Features** group next to XR Mode, not in Meta XR Features, which shows its options whether the plugin is on or not. Untick it and the
     plugin writes **nothing** Meta into the APK (no passthrough feature, no scene or anchor permission, not its Meta library), with no warning: the plugin's
     export code returns early on every Meta step (`meta_export_plugin.cpp`). Never tick a second vendor (Pico, Android XR...) in the same preset.
     **Meta XR Features > Passthrough must also show, set to Optional.** The plugin shows that option only while the editor reads
     `xr/openxr/extensions/meta/passthrough` as true. If it is missing, the APK will have black passthrough: see [the trap](#the-android-only-setting-trap). (The first
     APK, 21 Oct 2026, was built while the setting was Android-only, and the option did not show.)
   - A project named with spaces gives the warning "the project name does not meet the requirement for the package name format": the package name above clears it.
   - Resources: **include filter `demo/*`**, **exclude `demo/tools/*, tests/*`**. **Never put `secrets.cfg` in an include filter**: the APK would carry your API key
     to everyone you give it to. (A pack export with this preset, 20 Oct 2026, contained the demo models and native files, the logo and the scripts, and no
     `secrets.cfg` or `export_presets.cfg`.)

## Building and installing

Editor: Project > Export > the preset > **Export Project** (debug). Or headless:

```
godot --headless --path . --export-debug "Quest 3 (debug APK)" build/didsa-vr-debug.apk
adb install -r build/didsa-vr-debug.apk
```

Then run it from the headset's Unknown Sources library. `adb logcat -s godot` shows the app's log (status lines, the Scan page's findings).

## First run on the headset: what to check and report

In this order; each answers an open question in the scope. Write the answers into [`servers.md`](servers.md) and the scope.

1. **It starts** on the landing: logo, garden, launcher, tips. Is anything missing (the demo models, the About credits)? That checks the export filter.
2. **Passthrough:** Landing > Servers > Scan, or View > Environment on the tablet. Does *Passthrough: ON* show your room? (If not, the page's status line says what
   the runtime offered.)
3. **The QR spike (step L5):** on the Scan page with passthrough on, look at DIDSA-CAD's *Connect a VR headset* code. Read the page's lines: *QR codes
   supported*, *Scene permission*, *Trackers seen*. Does the code get read? How close and how large must it be? If *Scene permission* says *refused*, grant it in the
   headset's app permissions.
4. **Pairing (step L6):** read a real code, press Connect. It should test the server, save it and open the Servers page.
5. **Plain http to a LAN server:** add a `http://192.168...` server (typed or by code), press Test. If it fails with "Could not reach" while the same address works from
   a phone browser on that Wi-Fi, apply the overlay below and rebuild.
6. **`adb push` of `servers.cfg`:** the Servers page prints the data folder at its foot. Push a file there and restart (`docs/servers.md`). Correct that page if the
   folder or the permissions are different.
7. **Frame rate and load time:** the landing's garden (about 175k triangles for the six rockets, loaded one rocket per frame), a 110 m Saturn V at full size, the tablet's Display page
   (fps, cpu / gpu ms).

## The Android-only setting trap

Found on the first headset run (21 Oct 2026; [`quest-first-run-fixes.md`](quest-first-run-fixes.md) B5): Passthrough reported *"It offers blend modes: opaque.
The headset's passthrough layer is available but failed to start"*. The Vendors plugin writes `com.oculus.feature.PASSTHROUGH`, `USE_SCENE` and
`USE_ANCHOR_API` into the manifest only when it reads the project settings as true, with `get_setting_with_override()`, **in the editor while it exports**. A
`.android` override applies when the *running* OS is Android, not when the editor exports *for* Android, so with only `.android` the plugin read false: the manifest
had no passthrough feature (and the scan would have had no scene permission). On the headset the `.android` override does apply, so the app asked for passthrough
and Horizon OS refused it.

`project.godot` now also sets each key with **`.editor_hint`**. Checked with Godot 4.7.2 here: an `.editor_hint` override reads true in the editor itself and
false when the game runs, whether from the editor (that is `editor_runtime`), on the desktop or on the headset (there `.android` turns it on). A plain `.editor`
override would also be true for a game run from the editor, so PC-VR would change too. PC and PC-VR runs are unchanged. `tests/android_config.gd` checks both
overrides. **Then the second trap, Enable Meta Plugin** (step 4 above): the second APK, with the settings fixed, still showed *blend modes: opaque* and
*Scene permission refused*, which is what an APK built with the Meta part switched off gets. **Checking an APK:** `aapt2 dump xmltree --file AndroidManifest.xml <apk> | grep -iE "PASSTHROUGH|USE_SCENE|USE_ANCHOR"` should print all three.

## Meta dynamic resolution is off

The plugin turns on `xr/openxr/extensions/meta/dynamic_resolution` by default: each frame the headset recommends a render size and only that region of each eye's
image is drawn. On the Quest 3 (22 Oct 2026) each eye showed one flat colour, which is what a tiny region stretched over the eye looks like, so `project.godot`
turns it off ([`quest-first-run-fixes.md`](quest-first-run-fixes.md) B2). Unlike the Meta manifest entries, it does not depend on Enable Meta Plugin: it runs
whenever the plugin's library is in the APK.

## Trying graphics settings without a rebuild

`user://graphics.cfg` is read once at startup (`scripts/graphics_overrides.gd`): foveation level, the viewport's VRS mode, MSAA, and the landing's sky,
fog, logo glow and rockets. Start from `tools/android/graphics.cfg.example` (it says how to push it with `adb shell run-as`, which needs a **debug** APK). The
log always has one line with what rendering ended up with, `DIDSA VR: rendering: foveation ..., vrs ..., msaa ..., render size ...`, and one more,
`DIDSA VR: graphics.cfg: ...`, when the file was read. Made for the Quest 3's one-colour-per-eye fault ([`quest-first-run-fixes.md`](quest-first-run-fixes.md)
B2), where the menu that has the same switches could not be seen.

## If plain http is blocked: the cleartext overlay

```
tools/android/apply_cleartext_overlay.sh              # after Install Android Build Template
tools/android/apply_cleartext_overlay.sh --remove     # take it back out
```

It copies `network_security_config.xml` (cleartext allowed) into `android/build/res/xml/` and adds `android:networkSecurityConfig` to the manifest's
`<application>`. Safe to run twice. The app still refuses plain http to anything but a local-network address (`server_address.gd`), so this does not open the
internet to cleartext requests the app itself would make. `android/` is git-ignored: re-run it after reinstalling the template.

## Route B, if route A fails

If a headset shows that marker tracking does not read a code on a screen: the Passthrough Camera API (Quest 3 and 3S, Horizon OS v74 or later) with a decoder.
The plugin has an export option (`permissions/camera`) that adds `horizonos.permission.HEADSET_CAMERA`; reading frames needs a small Kotlin Godot Android plugin
with ZXing (Meta's QuestCameraKit has a sample). **Not built**: it breaks "no addons" further and needs this Gradle build first.

## Storage on the Quest (T1, 4 Nov 2026)

Horizon OS is Android, so **scoped storage** applies as it does to the flat app: a plain path such as `/storage/emulated/0/Documents/DIDSA` can be read only for files the
app made itself, unless the app has *All files access*. Decision (owner, 4 Nov): **B + C**. The first run offers `Documents/DIDSA` as the project folder (no permission
needed for files the app creates), Settings > Project folder has a laser folder chooser and a **Allow opening files from other apps** button, and the example preset sets
`permissions/manage_external_storage=true` (a Store listing would have to justify that; a sideloaded APK does not). The flat app's Storage Access Framework picker (option
D) is **not** built: it needs a native plugin, which `CLAUDE.md` does not allow.

**To check on the headset (not verified; write the answers here):**

1. What the launcher's Servers page prints for `OS.get_user_data_dir()`: is it under `Android/data/<app>/files` (the Files app shows it) or `/data/data/<app>/files` (nothing can)? ____
2. Does a file saved to `Documents/DIDSA` show in the Quest Files app and over USB? ____
3. Can a file copied into `Documents/DIDSA` over USB be opened **without** All files access? (Expected: no.) With it? **Owner, 10 Nov (Quest 3): no.** `.didsa` files copied over USB do not show: the folder chooser opens the folder and counts 0 model files. The APK was exported with external storage read and write on, but the permission was never accepted on the headset. Read/write external storage does not cover other apps' non-media files on Android 11 and later; only All files access does. With it: ____
   If Horizon OS shows no All files access page, it can be granted over USB: `adb shell appops set uk.didsa.vr MANAGE_EXTERNAL_STORAGE allow` (the package name from the preset), then restart the app. Not tried.
4. Does *Allow opening files from other apps* open the system's All files access page for the app? Does Settings then say "allowed"? **Owner, 10 Nov (Quest 3): no page opened.** Cause: the app asked for `"MANAGE_EXTERNAL_STORAGE"`, and Godot's Android `PermissionsUtil` (read in the 4.5 source; the same file in 4.7 not checked) only opens the page for the full name `android.permission.MANAGE_EXTERNAL_STORAGE`; any other name fails its lookup and is skipped without a word. **Fixed 10 Nov:** the full name, and the app now asks **at every launch** (2 s after start) until it is allowed, as well as from the button. It is not a pop-up: Android opens a Settings page with a switch for the app; turn it on and come back. The permission must be in the APK: Export > Permissions > **Manage External Storage** ticked (the example preset has it; *Read/Write External Storage* is not the same thing), or the page has no switch for the app. Whether `OS.get_granted_permissions()` then reports it on Horizon OS (Godot checks `Environment.isExternalStorageManager()` for this one) is still to see. After the fixed build: ____

## Server projects: the mirror folder and its permission (S3, 14 Nov 2026)

A project on DIDSA-CAD's project store is copied into a **mirror folder**: `Documents/DIDSA-Cloud/<server host>/<project>/` (a sibling of `Documents/DIDSA`, visible, so
files can be dragged in by hand; `docs/server-projects.md`). That is a folder outside the app's own storage, so on the Quest it needs **All files access**, the
same permission as the local project folder (the *Allow opening files from other apps* button and the launch-time ask above). **Without it** (or when the folder cannot be
made or written) the mirror falls back to `user://DIDSA-Cloud` (on the Quest under `Android/data/<package>/files/`), and Files > Server projects and the Servers page say so.
The sync state (versions, the queue of unsent saves, the cursor) is always private, in `user://didsa-cloud-state/`, so deleting the mirror cannot delete the queue. The
mirror root is one setting (`[cloud] folder=` in `settings.cfg`, empty = the default) so it can move if the check below shows Documents too slow or small.

**To check on the headset (write the answers here; nothing here has been run on one):**
1. With All files access on, does `Documents/DIDSA-Cloud/<host>/<project>/` get made, and can the Files app or a PC over USB see it and put a file in it? ____
2. Does a dropped file go to the store at the next sync, and a file edited by hand? ____ Is a file removed by hand left on the server (it must be)? ____
3. With All files access off, does the fallback line appear and does the project still open and save? ____
4. How long does opening a real project and its first sync take? ____

### The storage check (S0 spike, 13 Nov 2026)

Where `user://` really is on the Quest, how much room it has,
and whether a file there can be seen from outside the app. **Launcher > Servers > Check storage** writes and reads back a 20 MB file and
shows the folder, the free space and the times; the same line goes to `adb logcat` (filter `DIDSA VR: storage`).

**To check on the headset (write the answers here):**
1. What does Check storage say for *App storage (user://)*? (Expected `/data/user/0/<package>/files` or `/storage/emulated/0/Android/data/<package>/files`.) ____
2. *Free there*? ____ And for *Documents*? ____
3. The 20 MB write and read times? ____
4. Can the Quest Files app, or a PC over USB, see that folder? (It matters only for support: the store's copy never needs to be opened by hand.) ____
5. After updating the app with `adb install -r`, is the folder's content still there? (It should be; an uninstall deletes it.) ____

## What was checked, and what was not

Checked (`tests/android_config.gd`, headless, plus by hand in a scratch copy of the project):

- `project.godot`'s Android-only settings are there and nothing changes for desktop; the example preset parses and has the choices above, no secrets, and only arm64.
- The plugin (5.1.0-stable, Godot 4.7.2 headless): its extension loads, `OpenXRFbPassthroughExtension` exists and `xr/openxr/extensions/meta/passthrough` is a real
  setting (our `.android` override is kept). Its source shows the manifest entries it writes.
- A **pack export** with the example preset and the plugin present succeeds (13.6 MB, before `tests/*` was excluded) and holds the demo files and no `secrets.cfg`.
- The installer refuses a file that is not the pinned release; the overlay script applies, is idempotent, removes itself and refuses without a template (on a fake one).

**Not checked:**

- **No APK was built in the build session.** No Android SDK, no export templates (a download of Google's SDK is blocked from the build environment), no headset.
  (The owner has since built a debug APK from this page on Windows, 21 Oct 2026. The manifest and the plugin's contents in it were not inspected here.)
- Passthrough, marker tracking, the permission prompt and plain http on an actual Quest.
- The preset's option names were taken from the plugin's source and Godot's usual Android options, not from the editor's Export dialog: open the preset once and
  check nothing was dropped (Godot ignores a key it does not know, and fills defaults).
- The enabled-by-default extensions are requested at OpenXR start-up on Android; if a runtime treated one as required the app could fail to start OpenXR. The
  plugin normally requests them as optional.
