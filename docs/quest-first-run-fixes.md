# Quest 3 first native run: bug report and fix plan (21 Oct 2026)

The owner's first run of the standalone APK on a Quest 3 (the L0 build from [`android-build.md`](android-build.md)). The app started on the landing and ran
natively; with demo models loaded it felt smooth. Five problems, each traced to the code below, then the plan. Nothing here has been fixed yet, and the causes of
B2 and B5 are the most likely ones found by reading the code and the OpenXR Vendors plugin's source (5.1.0-stable): **not yet confirmed on the headset**.

## The report

1. **B1** The laser's range is too short on the monolith.
2. **B2** Visuals are lost, with flickering colours (light / orange / dark), when looking up above a certain angle. It seemed to clear up after a while (perhaps after
   loading a model and coming back).
3. **B3** Open on the monolith throws you onto the wrist tablet instead of staying on the monolith.
4. **B4** After opening one demo and going back to the monolith, a second demo was refused with an unsaved-changes message. Discard / Cancel was offered only on
   the tablet, not on the monolith being used.
5. **B5** Passthrough turns the scene black. So a QR scan and adding a server could not be tried.

## B1: laser range on the monolith

**Cause.** The monolith (`landing_monolith.gd`) extends `launcher_window.gd`, which extends `diegetic_panel.gd`, where `max_point_distance` is **2.0 m**
(`scripts/diegetic_panel.gd:69`, passed to `laser_surface.gd`). The monolith stands 1.9 m from the eyes and is 2.6 m tall, so from a hand about 1.5 m away its top
and bottom rows are already about 1.8 to 1.9 m off; one step back and they are out of reach. (A floating window opens 0.6 m away, which is what 2 m was chosen for.
`panel_handle.laser_reach` is already 6 m, so hover works further than a press does.)

**Fix.**
- In `landing_monolith.gd`'s `_init()` set `max_point_distance = 5.0` (enough to stand well back; the laser already stops on the face it hits).
- Check that the laser's drawn length reaches the face at that distance (`controller.gd` `_update_laser_visual()`, `laser_length` 3 m, extended to
  `_hover_panel_distance`).
- Test: extend `tests/landing.gd`: a press from 3.5 m lands on a monolith row, one from 6 m does not.

## B2: flickering colours when looking up (landing sky)

**Third APK (21 Oct, Enable Meta Plugin on):** the headset asked for the spatial-data permission (new: the Meta part is in the APK now), but with Passthrough
on, each eye showed only flickering black / orange / light, the same colours as B2. In passthrough the landing does **not** draw the sky (the background is a
clear colour), so the star shader cannot be the whole cause. Note: black, orange and white are also the rockets' colours (Starship, SLS, Saturn V), and the rockets
are in view when you look up. A render test looking straight up (`tests/landing_render.gd`) shows the sky and the rockets drawn correctly under Mesa, so the fault is
specific to the Quest.

**Correction (22 Oct):** the owner never saw the room or the menu in that run; the flicker filled the view from the start. The app remembers the last Environment
scene, and the previous run had ended in Passthrough, so this one started in it. **The app now never starts in Passthrough** (`main.startup_scene()`: a
remembered Passthrough starts as Mid), so a broken passthrough can no longer leave you blind at launch. Also noted: every Meta passthrough sample in the Vendors
plugin (5.1.0) uses the Compatibility renderer, not Mobile, so Mobile + alpha-blend passthrough on a Quest is less well trodden.

**Each eye one flat colour (22 Oct):** the owner described the flicker more exactly: each eye shows a single colour at a time (navy, orange or light, the
landing's sky colours). That is what a tiny rendered region stretched over the whole eye looks like. **Suspect:** the Vendors plugin's Meta **dynamic
resolution** (`xr/openxr/extensions/meta/dynamic_resolution`, **on by default** in the plugin's `register_types.cpp`). Each frame it asks the runtime for a
recommended size (`XR_META_recommended_layer_resolution`) and calls `set_render_region()` with it. It is registered whenever the plugin's library loads on
the headset, whether or not Enable Meta Plugin is ticked, so it could explain the first run's flicker too. **Turned off** in `project.godot` (fixed full
resolution; also steadier for the frame-rate numbers still to be measured), checked by `tests/android_config.gd`. Not yet tried on the headset.

**First log (22 Oct, 13 s of `adb logcat -d`, taken after the app had started, so none of Godot's own lines):** the app was drawing and handing over frames
on time: `VrApi FPS=72/72, Stale=0, App=7.4 ms` (GPU), `LCnt=2`, `SF=1.00`, `Fov=2`, and the passthrough service listed `uk.didsa.vr, PT=0` (not in passthrough).
So it is not a hang or dropped frames: the frames themselves are wrong. The owner still saw nothing. Not known yet whether that APK had dynamic resolution off.
The app runs at 72 Hz (the Quest 3 default) while physics runs at 90 Hz; unrelated, but worth setting the refresh rate later.

**Built for this (21 Oct):** the star fixes (1 and 2 below) and **Settings > Graphics check** on the monolith (3 below), with live switches: night sky shader,
fog, glow behind the logo, rockets, MSAA 2x, foveated rendering (headset only) and Passthrough with its status line. Each change goes to the status line and the
log (`adb logcat -s godot`, "Graphics check: ..."). Nothing is saved. **How to use it:** reproduce the flicker (Passthrough on, or looking up), then turn the
switches off one at a time. Note which one stops it, and whether the flicker shows in a Quest screen recording: if it does, Godot drew it; if not, it happens in
the headset's compositor.

**What is above you on the landing:** only the sky (`shaders/landing_sky.gdshader`), the logo and its additive halo. The one thing in the scene that switches on at
an angle is the **star field**: `smoothstep(0.06, 0.35, h)` turns stars on above about 3.5 degrees.

**Most likely cause: the star code is not safe on a mobile GPU.**
- `hash13()` (a Dave Hoskins hash) multiplies values in the tens of thousands before `fract()`. That needs full 32-bit float precision. If the Adreno driver or the
  Mobile renderer runs the sky at half precision, the hash returns rubbish, and with it `step(1.0 - star_chance, r)` turns large patches of sky into "stars" at up to
  2x brightness, white or warm-tinted. As the head moves the cells change: light / orange / dark flicker, only above the horizon.
- `smoothstep(0.30, 0.0, length(f))` has edge0 > edge1, which the GLSL spec leaves **undefined**. A driver may return NaN; NaN times anything is NaN, and a NaN
  pixel can spread through MSAA resolve and the tonemap as black or garbage.
- Neither shows on the PC (desktop GPUs run full precision and return the "expected" value for a reversed smoothstep), which fits it never being seen before.

**Other suspects, to rule out if the fix above does not cure it:** the sky's radiance cubemap being regenerated (the "cleared up after a bit" clue; the metallic
monolith body reflects it), fog (`landing_stage.gd` turns it on), MSAA 2x, foveation level 2. A frame-rate drop would make the compositor reproject, which can
show black edges; the tablet's Display page (fps, cpu / gpu ms) tells that apart.

**Fix.**
1. Rewrite the stars to be precision-safe: `1.0 - smoothstep(0.0, 0.30, length(f))` instead of the reversed smoothstep; a hash that keeps its numbers small
   (wrap the cell id first, e.g. `mod(id, 289.0)`, then a small-magnitude hash), and `highp` on the hash's variables. Clamp the final colour to 0..4 and guard
   against NaN (`col = max(col, vec3(0.0))`).
2. Keep the sky's reflections but set `_sky.process_mode = Sky.PROCESS_MODE_QUALITY` in `landing_stage.gd`, so the radiance is made once and completely,
   not incrementally (rules out the "clears up after a while" route).
3. Add a hidden diagnostic switch (Settings on the monolith or `settings.cfg` key `landing_sky = shader | plain`) so the owner can bisect on the headset without a
   rebuild: plain gradient (no stars), stars, fog off.
4. Test: a headless check that the shader compiles and has no reversed `smoothstep` (a source lint); a render test under Xvfb looking straight up at the landing sky
   (`tests/landing_render.gd`) that every pixel is finite and within the sky's colour range. **The render test cannot show a half-precision fault**: only the
   headset can.

## B3: Open on the monolith goes to the tablet

**Cause.** `landing.gd` `open_files()` is `main.open_tablet_at("files")`; Settings does the same (`open_tablet_settings`). The monolith has no file list of its own.

**Fix.**
- A **Files page on the monolith** (`launcher_window.gd`, a new `"open"` page in `show_page()` / `press_tile()`): the recent files first (`RecentFile`), then the
  model files found in the models / project folders, the same list the tablet's Files page builds (`tablet_pages.gd` `_rescan_files()` via `file_index.gd`).
  Move that scan out of `tablet_pages.gd` into a small shared helper (`scripts/file_lookup.gd` or a new `file_list.gd`) so both pages use the same code. Rows open
  through the same main.gd calls (`load_model_file`, `open_native_file`, `load_glb_file`); a long list scrolls with the stick like the other pages.
- Keep "More on the wrist tablet" as a small link at the page's foot for the things only the tablet has (save, references, project folder).
- Test: `tests/landing.gd`: pressing Open shows the monolith's Files page and leaves the tablet closed; pressing a row loads that file.

## B4: unsaved-changes prompt on a demo, and only on the tablet

**Causes (three).**
1. **A demo becomes "unsaved" just by being handled.** Any move goes through the undo stack, and `command_stack.changed` calls `mark_dirty()`
   (`main.gd:150`). Demos are read-only files shipped in the APK (`res://demo/`), and offline there is nowhere to save them, so the warning protects nothing. (It
   also offers "Save first", which needs a backend.)
2. **The choice lives only on the tablet.** `confirm_discard()` (`main.gd:1808`) fills `_pending_discard` and says "(Files page)"; only `tablet_pages.gd`
   listens to `discard_prompt_changed`.
3. **Discard would lose the demo's placement.** `show_demo()` calls `load_glb_file(path)`, which records `load_glb_file.bind(path)` as the action to rerun. After
   Discard the demo loads but is not placed at full size ahead or on the desk plinth, because the placing is in `show_demo()`, after the load.

**Fix.**
1. Replacing a demo never asks: when the loaded document is a demo (`path.begins_with("res://demo/")`), `confirm_discard()` returns true. Painting a demo is
   lost the same way, which is right for a read-only demo; the status line says "Demo changes are not kept."
2. The monolith shows the same choice: `launcher_window.gd` connects `main.discard_prompt_changed` and, while the landing is up, shows a card on the monolith's
   face (Discard and continue / Save first (only with a server) / Cancel) calling `main.discard_and_continue()`, `save_and_continue()`, `cancel_discard()`. The
   status text drops "(Files page)" when the landing is up. The tablet keeps its box; whichever is pressed clears both.
3. `show_demo()` passes itself as the rerun: give `load_glb_file()` an optional `run: Callable` (default its own bind) and have `show_demo()` pass
   `show_demo.bind(model, desk)`.
4. Tests: `tests/landing.gd`: (a) grab-move a demo, open a second demo: it loads without asking; (b) with a non-demo file made dirty, a demo pressed on the monolith
   shows the card on the monolith, Discard loads the demo at full size (its placement checked), Cancel keeps the old model and its changes.

## B5: passthrough is black on the Quest

**Status (21 Oct, later):** the owner's status line read *"It offers blend modes: opaque. The headset's passthrough layer is available but failed to
start"*. So the extension was on in the app (the `.android` override applied), but the runtime would not create the passthrough layer, and so never offered alpha
blend. That is what an app with no passthrough feature in its manifest gets, which fits the cause below. **Done:** `.editor_hint` overrides in `project.godot` (fix
2 below, the way that leaves PC runs unchanged), the example preset's note, the Android advice in `passthrough_report`, the landing fog (fix 4), `android-build.md`
corrected. **Still to do:** rebuild, check the manifest (fix 1), try it on the headset; the `openxr_fb_passthrough_state_changed` listener.

**Second APK (21 Oct, later still):** the same *blend modes: opaque*, and the Scan page said *Marker tracking present: yes, QR codes supported: no, Scene
permission: refused*. Refusal without a prompt means `USE_SCENE` is not in the manifest either, so the Meta part wrote nothing at all. In the plugin's source
every Meta manifest step is gated on the export option **`xr_features/enable_meta_plugin`** (XR Features > Enable Meta Plugin, **off by default**), not only on
the project setting. `android-build.md` had said that toggle does not exist, so a preset made in the dialog rather than copied from the example has it off. Next:
check `export_presets.cfg` for `xr_features/enable_meta_plugin=true` and `meta_xr_features/passthrough=1`, rebuild, and run the `aapt2` check (fix 1).
**Confirmed** by the owner: their `export_presets.cfg` had `xr_features/enable_meta_plugin=false`. Next APK: with it true; passthrough and the QR scan not yet tried with it.
With it true (the third APK), the spatial-data permission is asked for. Passthrough then gave the B2 flicker instead of the room: see B2.

**What the code does** (`environment_manager.gd` `_enable_passthrough()`): if the runtime offers ALPHA_BLEND it sets that blend mode and a transparent viewport.
This is the documented way, and the plugin's own sample does the same. Black means the runtime has no camera layer under our transparent frame.

**Most likely cause: the APK's manifest never asked for passthrough.** The Vendors plugin writes `<uses-feature android:name="com.oculus.feature.PASSTHROUGH">`
only when `xr/openxr/extensions/meta/passthrough` reads true (`plugin/src/main/cpp/export/meta_export_plugin.cpp`, around line 387), and it reads the setting with
`ProjectSettings.get_setting_with_override()` **in the editor at export time**. Our `project.godot` sets only `openxr/extensions/meta/passthrough.android=true`. The
`.android` override applies when the *running* OS is Android, not when the editor exports *for* Android, so on the Windows editor the plugin sees **false**: no
passthrough feature in the manifest. This also explains a line in `android-build.md` ("There is no Passthrough toggle in that dialog"): the plugin's
`meta_xr_features/passthrough` export option exists, but is hidden when that same setting reads false. On the headset the `.android` override does apply, so the
app asks for the extension and sets alpha blend, but Horizon OS gives no camera layer to an app that did not declare the feature: black.

**The same fault hits the QR scan:** `USE_SCENE` and `USE_ANCHOR_API` are written only when `xr/openxr/extensions/spatial_entity/enabled` reads true, which it
also does only through `.android`. So the Scan page would have failed next, even with passthrough working.

**Fix.**
1. **Confirm first (no rebuild):** `aapt2 dump xmltree --file AndroidManifest.xml build/didsa-vr-debug.apk | grep -iE "PASSTHROUGH|USE_SCENE|USE_ANCHOR"` (or
   open the APK in Android Studio's APK Analyzer). Expected today: none of the three. Also note the Environment page's status line when Passthrough is picked
   (`passthrough_report`): "Passthrough ON (alpha blend)" means the manifest is the fault; "NOT available" lists what the runtime offered.
2. **Fix the settings** so the export sees them (done with `.editor_hint` overrides instead of base keys: the editor sees them, a running game does not). The first idea was to set the base keys too (`openxr/extensions/meta/passthrough=true`,
   `openxr/extensions/spatial_entity/enabled=true` and its two marker-tracking keys). On the PC they only ask a PC runtime for extensions it may offer (Link's
   passthrough uses the same `XR_FB_passthrough`); the existing rule of starting passthrough only once the session has focus stays. If a PC-link test shows trouble,
   the fallback is to keep the keys Android-only and add the three manifest entries through a Gradle-template overlay like `tools/android/apply_cleartext_overlay.sh`.
3. Set `meta_xr_features/passthrough` to Optional in `tools/android/export_presets.cfg.example` explicitly, and correct `android-build.md` (the toggle exists once
   the setting reads true; the `.android`-only setting was the trap).
4. While there: in passthrough, turn the landing's fog off (`landing_stage.gd` `_apply()` returns early and leaves the night fog on over virtual parts) and listen
   to the plugin's `openxr_fb_passthrough_state_changed` signal so a runtime error shows in `passthrough_report` instead of a silent black.
5. Tests: `tests/android_config.gd`: the base keys are true (so the export sees them), not just the `.android` ones; the example preset has passthrough Optional.
   `tests/landing.gd` / an environment test: fog is off while Passthrough is on the landing and back on after.
6. Rebuild the APK, check the manifest (step 1), then on the headset: Passthrough on the Environment page and on the Scan page, then a QR scan of DIDSA-CAD's code
   (the `android-build.md` checklist, items 2 to 4).

## Order of work

| # | Fix | Size | Needs the headset to confirm |
|---|---|---|---|
| 1 | B5 manifest check (no code), then the settings fix | small | yes (rebuild + run) |
| 2 | B1 monolith reach | tiny | the feel only |
| 3 | B4 demo replace never asks; Discard keeps the demo's placement; the choice on the monolith | small to medium | no |
| 4 | B2 precision-safe stars, radiance once, diagnostic switch | small | yes: only the headset shows a half-precision fault |
| 5 | B3 Files page on the monolith (shared file-list helper) | medium | no |

B5 first because it blocks the QR scan and pairing tests (L5, L6), the next things the headset has to answer. Every step adds its tests to `tests/run_all.sh` as
needed and updates [`status.md`](status.md).
