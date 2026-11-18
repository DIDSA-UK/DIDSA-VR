# Live sessions: the voice and Cardboard spikes (P0)

Part of P0 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md`. Written 2026-11-18. **These are plans for the owner to run;
neither spike has been built or run, and no result below is claimed.** Both need the owner's devices: a Quest 3 and an Android phone.
The protocol they serve is DIDSA-CAD `docs/live-sessions-scope.md`; what a view-only build must not load is in
[`main-gd-split-audit.md`](main-gd-split-audit.md).

**Checked here, on the Godot 4.7.2 Linux desktop build only** (`tools/setup_test_env.sh godot`, a headless script asking `ClassDB`):
`MobileVRInterface` exists (`XRServer` lists it as "Native mobile", beside "OpenXR") with `eye_height`, `iod`, `display_width`,
`display_to_lens`, `oversample`, `k1`, `k2` and VRS settings; `AudioServer.get_input_frames`, `AudioEffectCapture`,
`AudioStreamMicrophone`, `AudioStreamGenerator`, `Input.get_gyroscope` / `get_gravity` and `WebSocketPeer.set_handshake_headers` exist.
Not checked: that any of them **work** on Android, or that they are in the Android export templates (they are core classes, so they
should be).

Both spikes live on a throwaway branch (`spike/p0-voice`, `spike/p0-cardboard`) and are **not merged**: what they teach goes into P3 and
P5. Neither touches `main.gd`.

---

## Spike V: voice

### The add-on (D9): recommendation

**TwoVoip** (`github.com/goatchurchprime/two-voip-godot-4`, MIT). It is the one Godot 4 GDExtension found that does the whole path
(microphone capture, Opus encode and decode, an optional RNNoise filter, a jitter buffer helper), built with libopus 1.5.2, and its
GitHub Actions build every platform Godot exports to. Its recent releases (v6.6.1, 13 Nov; v6.6.2, 16 Nov, "works in v4.8") are tested
on Godot 4.6; the native build is pinned to the 4.6-stable extension API, which 4.7 should load (GDExtensions are forward compatible
within 4.x), **not verified**. The other Opus add-ons found only **play** Opus files (no encoder), so they cannot do voice.

What it **must** build for, and the spike checks each: **Android arm64** (Quest 3 and the phone), **Linux x86_64** (CI and the
headless tests), **Windows x86_64** (PCVR). macOS is nice to have. Pinned like the OpenXR Vendors plugin: a
`tools/install_voip_plugin.sh` that fetches one release zip, checks its SHA-256, unpacks to `addons/twovoip/`, and is never committed
(`.gitignore`). If the release zip does not carry an Android arm64 library, the add-on fails this spike and the fallback is to build it
from source in CI (its repo has the workflow), which makes P3 larger.

### What to build (about half a day)

1. `tools/install_voip_plugin.sh` as above, pinned to the release the spike tests (v6.6.2 if it is still the latest), and
   `addons/twovoip` in `.gitignore`.
2. `project.godot`: `audio/driver/enable_input=true`. The example Quest preset (`tools/android/`) and a phone preset: **RECORD_AUDIO**
   permission ticked; the app asks for it at run time with `OS.request_permissions()` and logs the answer.
3. `spikes/voice/voice_spike.tscn`: a flat 2D screen (no XR needed; on the Quest it runs as a flat panel app is fine, or as the normal
   XR app with a world-space label) with a level meter, Talk (hold) and Open mic buttons, and a log. It captures from the default input
   at 48 kHz mono, encodes **20 ms Opus frames at 24 kbit/s** with TwoVoip, and sends each frame as one binary WebSocket message in
   the scope's framing (byte 0 version, byte 1 sender id, bytes 2-3 sequence, byte 4 flags, then the packet).
4. `spikes/voice/echo_relay.py`: a 40-line Python WebSocket relay (no auth, run by hand, never deployed) that forwards every binary
   frame to every other connection and, with `--echo`, back to the sender too. Run it on the PC and through the owner's tunnel.
5. Receive side: decode with TwoVoip's speaker into an `AudioStreamPlayer` (positional later, P3), with its jitter buffer.
6. Every 5 s, log one line (`adb logcat` filter `DIDSA VR: voice:`): frames sent / received / lost / late, the jitter buffer depth,
   encode time per frame (µs, mean and worst), decode time, round trip of a frame through the relay in `--echo` mode (the sequence
   number's send time against its echo), and the frame rate.

### What to measure, and pass / fail

| # | Measure | Pass | Fail means |
|---|---|---|---|
| V1 | The add-on loads on Quest 3, the phone, Linux and Windows (Godot 4.7.2) | No GDExtension load error in the log on all four | Build from source (P3 grows) or another add-on |
| V2 | Mic permission on Quest 3 standalone and on the phone | Asked, granted, and the log says so | P3 cannot start until solved |
| V3 | Capture works | The meter moves when speaking and sits near zero when quiet, on both devices; frames are 20 ms, 48 kHz | As V2 |
| V4 | Encode cost on the Quest | **≤ 1 ms per 20 ms frame** (mean), worst ≤ 3 ms; the XR app's frame rate unchanged (72 or 90 Hz) with open mic | Encode on a thread, or a lower complexity setting |
| V5 | Round trip through the relay **on the local Wi-Fi** | p95 ≤ **100 ms** | Look at the jitter buffer and Wi-Fi first |
| V6 | Round trip **through the tunnel** (the owner's Cloudflare tunnel, the relay behind it) | p95 ≤ **250 ms**; lost frames ≤ 1% over 2 minutes | Voice over the tunnel needs a different route (P3 decides) |
| V7 | Quest to phone conversation, one each side, through the tunnel | Speech clear both ways for 2 minutes, no crackle or dropouts the owner notices | Note what was wrong; tune buffer or bitrate |
| V8 | Bandwidth per talker | ≤ **40 kbit/s** including framing (the relay prints bytes per second) | Lower the bitrate |
| V9 | Echo: Quest with open mic and its own speakers, the phone talking | Record whether the phone hears itself back. Not pass / fail: it decides whether P3 defaults to push-to-talk or needs echo cancellation (TwoVoip has noise removal, not echo cancellation) | |

### The owner's steps

1. On the PC: `tools/install_voip_plugin.sh`; open the project in Godot 4.7.2 and check the editor log for the add-on (V1, desktop).
2. `python3 spikes/voice/echo_relay.py --port 8300 --echo` on the PC. Note the PC's LAN address.
3. Export `spikes/voice/voice_spike.tscn` as the main scene with the Quest preset (RECORD_AUDIO ticked) and install; same with the phone
   preset on the phone. Allow the microphone when asked (V2).
4. On each device, type `ws://<PC address>:8300/ws`, press Open mic, talk for a minute while watching the meter (V3). Read the log lines
   with `adb logcat -s godot | grep "voice:"` (V4, V5, V8).
5. Put the relay behind the tunnel (a second hostname to `localhost:8300`, as the relay and store have), switch both devices to
   `wss://<that hostname>/ws`, and repeat (V6). Turn `--echo` off and talk Quest to phone for two minutes (V7). Then V9.
6. Paste the log lines and a sentence per row into "P0 results" in the DIDSA-CAD plan (or send them to the next session). Note the
   phone's make and model and the Quest's OS version.

---

## Spike C: Cardboard (phone observer camera and render budget)

### What to build (about a day)

1. A phone export preset (`tools/android/` example, git-ignored real copy) with a custom feature tag **`phone`**, XR mode **Regular**,
   the Meta plugin **off**, and in `project.godot` the overrides `xr/openxr/enabled.phone=false` plus the `.android` passthrough and
   spatial-entity settings set back to false with `.phone` (the audit, section 2, point 9). **First check:** the phone build starts
   without OpenXR and logs "no OpenXR" (if Godot ignores the override, the fallback is to switch OpenXR off in code before the viewport
   uses it, or a separate project file: report which).
2. `spikes/cardboard/cardboard_spike.tscn` + a script: **Godot's built-in `MobileVRInterface`** first (`XRServer.find_interface("Native
   mobile")`, `initialize()`, `get_viewport().use_xr = true`): it already does side-by-side stereo with barrel distortion (`k1`, `k2`) and
   head orientation from the gyroscope, accelerometer and magnetometer. No add-on. Set `iod` to the owner's eye spacing (in centimetres: Godot's default is 6.0), `display_to_lens` and `k1` / `k2`
   from the viewer's own profile (the QR code printed on most viewers), else start from Godot's defaults (0.215, 0.215) and tune by eye.
3. Load **two real assemblies from glb files copied to the phone** (no backend, so the spike measures rendering, not the network): the
   gear-train demo's glb as the backend serves it (save it once from `GET /document/parts/{root}/assembly-mesh.glb`) and the owner's
   heaviest real assembly the same way. Load them through the same `GLTFDocument` + `mesh_identity.gd` path `main.gd` uses, with
   `create_trimesh_collision()` switchable on / off.
4. Today's look: the environment from `environment_manager.gd` (Mid), the infinite grid, the section-clip shader on every part with a
   plane set, and the edge overlay from `view_modes.gd` switchable.
5. A **magic window** mode (mono, full screen, the phone is a window you turn): the same rig with `MobileVRInterface` uninitialised and a
   plain `Camera3D` turned by the same orientation.
6. Gamepad: log every `InputEventJoypadButton` / `InputEventJoypadMotion` and `Input.get_joy_name()` for a Bluetooth controller.
7. An on-screen and logged readout every 2 s (`DIDSA VR: cardboard:`): fps, frame time mean / p95 / worst over the window, CPU and GPU
   render time (`RenderingServer.viewport_get_measured_render_time_*`), draw calls, triangles, glb load time (parse, scene, collision
   separately), and yaw drift (see C5).

### What to measure, and pass / fail

The phone must be a **mid-range phone the owner names** (make, model, chip, Android version recorded); the figures below are for that phone.

| # | Measure | Pass | Fail means |
|---|---|---|---|
| C1 | OpenXR off for the phone preset only | The phone starts with no OpenXR error; the Quest preset still starts in XR | Report which fallback was needed |
| C2 | Frame rate, stereo + distortion, **gear train**, edges on, section on | **≥ 60 fps sustained**: p95 frame ≤ 16.7 ms over 2 minutes, ≤ 1% of frames over 33 ms | Try MSAA off, `oversample` 1.0, edges off, then `tier=coarse` meshes; record which gets it there |
| C3 | The same with the owner's **heaviest real assembly** | Same as C2 | Same; if nothing reaches 60, P5 starts with magic window and the LOD work (`docs/lod-strategy/` in DIDSA-CAD) |
| C4 | After **10 minutes** of C3 (warm phone) | ≥ 50 fps p50 | Thermal throttling: record the curve; P5 needs a lower default |
| C5 | Head tracking drift: phone in the viewer, held still against a fixed mark for 60 s | Yaw drift ≤ **5°** in 60 s (the log measures it while the phone lies flat on a table for 60 s, and the owner checks by eye in the viewer) | `MobileVRInterface`'s fusion is not good enough: P5 writes its own fusion from `Input.get_gyroscope` / `get_gravity` |
| C6 | Comfort, the owner's judgement: does turning the head feel immediate, is the picture sharp, are straight lines straight at the edges after tuning `k1` / `k2` | Owner says yes | Note what was wrong |
| C7 | Load: the heaviest assembly's glb, parse + scene + collision | ≤ **5 s** total; record collision's share | Skip collision on the phone until the drone cursor needs it, or build it lazily |
| C8 | Magic window at the same settings | ≥ 60 fps (it renders one view) | |
| C9 | A Bluetooth gamepad (the owner's) | Its buttons and sticks appear in the log with names | P5's mapping table needs a different layout |

### The owner's steps

1. Install Godot 4.7.2's Android export templates (as for the Quest, `docs/android-build.md`). Copy the example phone preset into
   `export_presets.cfg` (git-ignored).
2. On a PC with the backend running and an assembly open in it, save the glb:
   `curl -H "X-API-Key: ..." -H "X-Document-Session: ..." "<backend>/document/parts/<root>/assembly-mesh.glb" -o heavy.glb`
   (or use the gear-train demo). Note its size and part count. Copy both glbs to the phone's `Documents/DIDSA/` folder.
3. Export `spikes/cardboard/cardboard_spike.tscn` with the phone preset, install on the phone (`adb install`), start it. C1.
4. Put the phone in the viewer; run C2, C3 with the on-screen switches; leave C3 running 10 minutes for C4. Read the log with
   `adb logcat -s godot | grep "cardboard:"`.
5. C5 (flat on a table 60 s, then in the viewer against a mark), C6, C7, C8 (the magic window switch), C9 (pair the gamepad first).
6. Paste the log lines, the phone's make / model / chip and a sentence per row into "P0 results" in the DIDSA-CAD plan.

---

## What each spike settles

- **Voice (V1 to V9)** sets P3's size: TwoVoip as is (P3 medium), TwoVoip built from source (P3 larger), or no workable add-on
  (P3 blocked; voice falls back to something outside Godot, which D5 would have to revisit). It also says whether open mic needs echo
  handling.
- **Cardboard (C1 to C9)** sets P5's starting point: `MobileVRInterface` or a custom rig, the phone's default render settings (MSAA,
  oversample, edges, mesh tier), whether collision is built on load, and whether magic window comes first.
- Neither result changes P1 or P2: the protocol (DIDSA-CAD `docs/live-sessions-scope.md`) does not depend on them, except that voice
  frames are Opus at 20 ms (V4 confirms the cost).
