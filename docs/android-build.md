# Building the Quest APK (step L0)

Scope: [`landing-scope.md`](landing-scope.md) step L0. This page is what to do on **your machine** to get a standalone Quest build with passthrough. Everything
here was prepared in a cloud session with **no Android SDK, no export templates and no headset**, so **an APK has never been built from this**. What was
checked, and what was not, is at the end.

## What L0 adds

| Need | How |
|---|---|
| Passthrough on a standalone Quest (to see the screen with the pairing QR code, and mixed reality in general) | the **OpenXR Vendors plugin** (Meta part) in a **Gradle** Android build; project setting `xr/openxr/extensions/meta/passthrough` (on for Android builds, in `project.godot`) |
| The QR scan's Android permission | the plugin adds `com.oculus.permission.USE_SCENE` and `USE_ANCHOR_API` to the manifest by itself while `xr/openxr/extensions/spatial_entity/enabled` is on (it is, for Android builds). The app asks for the permission at run time when the Scan page starts |
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
   - **XR Mode: OpenXR**. With the plugin installed, the Export dialog (Options tab) gains **Android XR Features**, **Meta XR Features** (Quest 1 / 2 / 3 / Pro
     support, boundary mode, overlay keyboard, instant splash screen, experimental features) and **Pico XR Features**: leave Quest 2, Quest 3 and Quest Pro on for
     a Quest 3. **There is no Passthrough or "Enable Meta Plugin" toggle in that dialog** (an earlier version of this page said there was; that was written from the
     plugin's source, not from the dialog): passthrough comes from the Android-only project setting `xr/openxr/extensions/meta/passthrough` in `project.godot`.
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
