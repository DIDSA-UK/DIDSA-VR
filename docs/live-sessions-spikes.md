# Live sessions: the voice and Cardboard spikes (P0)

Part of P0 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md`. Plans written 2026-11-18; **the spike apps were built the
same day and are ready to run, but neither spike has been run on a device and no result below is claimed.** Both need the owner's
devices: a Quest 3 and an Android phone. The protocol they serve is DIDSA-CAD `docs/live-sessions-scope.md`; what a view-only build
must not load is in [`main-gd-split-audit.md`](main-gd-split-audit.md). Where the files are: [`../spikes/README.md`](../spikes/README.md).

**When they are needed:** the voice spike before P3 (it sets P3's size); the Cardboard spike before P5. P1 and P2 do not wait for them.

## What was checked here (one Linux machine, no device)

- **Godot 4.7.2, desktop build** (`ClassDB` from a headless script): `MobileVRInterface` exists ("Native mobile", with `iod`,
  `display_width`, `display_to_lens`, `oversample`, `k1`, `k2`; defaults k1 = k2 = 0.215, iod 6.0 cm); so do
  `AudioServer.get_input_frames`, `AudioEffectCapture`, `AudioStreamMicrophone`, `Input.get_gyroscope` / `get_gravity` and
  `WebSocketPeer.set_handshake_headers`. Whether they **work** on Android was not checked.
- **TwoVoip v6.6.2's release zip** (downloaded, SHA-256 `cce8bc13...6cdb3`, pinned in `tools/install_voip_plugin.sh`) **contains
  Android arm64 libraries** (debug and release), plus arm32, x86, Linux x86_64, Windows x86_64, macOS, iOS and web; its
  `.gdextension` says `compatibility_minimum = "4.6.0"`. **Not checked: that it loads in Godot 4.7** (running the downloaded native
  library was not allowed in this environment, so not even the Linux build was loaded).
- **The Cardboard spike scene runs headless** (`tests/cardboard_spike.gd`, in `run_all.sh`): it loads the demo rocket and two real
  assemblies (the gear train and the table, saved with `tools/save_assembly_glb.gd` from a local backend, then served over HTTP),
  walks every step and lists the results. The frame rates it printed are meaningless (no GPU).
- **The voice spike's own script parses and counts frames right without the add-on** (it says TwoVoip is missing instead of failing),
  and **`echo_relay.py` relays and echoes** with the sender id written in (two Python clients).
- **The main app still starts on `main.tscn`**: the `.phone` overrides added to `project.godot` apply only to an export with the
  `phone` feature tag.

---

## Spike V: voice

### The add-on (D9): TwoVoip

**TwoVoip** (`github.com/goatchurchprime/two-voip-godot-4`, MIT): microphone capture through Godot's `AudioServer`
(`set_input_device_active`, `get_input_frames`), Opus encode and decode (libopus 1.5.2), RNNoise, a jitter-buffer player. The other
Opus add-ons found only **play** Opus files, so they cannot do voice. It must work on **Android arm64** (Quest 3 and phone), **Linux
x86_64** (CI) and **Windows x86_64** (PCVR); the release carries all three. It is fetched and checked by
`tools/install_voip_plugin.sh` (pinned to v6.6.2, its SHA-256 checked, never committed), into the spike's own project for now; P3
decides whether the app takes it, and only then does `CLAUDE.md` list it as the second add-on exception.

Two things found in its helper code that P3 needs to know: the speaker's default jitter target is **0.6 s** (`audio_buffer_lag_time_target`),
too long for conversation, so the spike starts at 0.2 s and measures both; and each talk spurt starts and ends with a small **JSON
header / footer packet**, which the spike sends with flag bit 1 set in the scope's framing.

### What was built

`spikes/voice/`: its **own small Godot project** (so the app's audio and permission settings are untouched) with `voice_spike.tscn`
(Hold to talk, Open mic, Microphone on, Play my own voice back, the jitter target, Connect, **Encode benchmark**, and a live report),
`echo_relay.py` (forwards every frame to everyone else, and with `--echo` back to the sender for round-trip timing) and
`export_presets.cfg.example` (one Android preset for both devices: Internet and Record audio on, XR off, so the Quest runs it as a flat
panel app). Every 5 s it shows and logs (`DIDSA VR: voice:`): frames sent / received / lost / late, echo round trip p50 / p95,
kbit/s out and in, each jitter buffer, the mic level.

### Pass / fail

| # | Measure | Pass | Fail means |
|---|---|---|---|
| V1 | TwoVoip loads (the status line does not say "not installed") on the Quest, the phone and the PC | Loads on all three | Build from source (P3 grows) |
| V2 | Microphone permission on the Quest and the phone | Asked, granted, and the log says so | P3 cannot start until solved |
| V3 | Capture | The mic level moves when you speak and sits near 0 when quiet, on both | As V2 |
| V4 | **Encode benchmark** on the Quest (500 frames of 20 ms) | Mean **≤ 1000 µs**, worst ≤ 3000 µs | Encode on a thread or lower the complexity. (The cost inside the XR app's frame is measured in P3.) |
| V5 | Echo round trip on the local Wi-Fi | p95 ≤ **100 ms** | Check the Wi-Fi and the buffer first |
| V6 | Echo round trip **through the tunnel** | p95 ≤ **250 ms**, lost ≤ 1% over 2 minutes | Voice over the tunnel needs another route (P3 decides) |
| V7 | Quest to phone, 2 minutes of conversation through the tunnel, jitter target 0.2 s | Clear both ways, no crackle or dropouts you notice | Raise the target (0.3, 0.4...) and note where it becomes clear |
| V8 | Bandwidth per talker | ≤ **40 kbit/s** out | Lower the bitrate |
| V9 | Echo: Quest on open mic with its own speakers while the phone talks | Not pass / fail: does the phone hear itself back? Decides push-to-talk by default or echo cancellation in P3 (TwoVoip removes noise, not echo) | |

### Your steps (about an hour)

**Once, on the PC:**
1. `tools/install_voip_plugin.sh` (from the DIDSA-VR folder; it downloads about 120 MB and checks it).
2. Open `spikes/voice/` as a project in Godot 4.7.2 (Project Manager > Import > `spikes/voice/project.godot`), let it import, then
   press Play: the status line should **not** say "TwoVoip is not installed" (V1, PC). Press **Encode benchmark** for a PC baseline.
3. Copy `spikes/voice/export_presets.cfg.example` to `spikes/voice/export_presets.cfg`; Project > Export: check the preset shows
   Internet and Record audio ticked, then Export Project to an APK.
4. `pip install "websockets==13.*"`, then `python3 spikes/voice/echo_relay.py --echo` (leave it running). Note the PC's local IP.

**On each device (Quest and phone):**
5. `adb install -r build/didsa-voice-spike-debug.apk`, start **DIDSA Voice Spike** (on the Quest: Library > Unknown sources). Allow the
   microphone when asked (V2). The status line says TwoVoip loaded (V1).
6. Press **Encode benchmark** and write down the line (V4).
7. Type `ws://<PC IP>:8301/ws`, press **Connect**, hold **Hold to talk** and speak: you hear yourself back after the round trip. Watch
   the mic level (V3) and read the round trip and kbit/s (V5, V8) on screen.

**Through the tunnel:**
8. In the Cloudflare dashboard: Zero Trust > Networks > Tunnels > your tunnel > Public Hostname > Add: subdomain `voice`, your
   domain, service `http://localhost:8301` (WebSockets pass through). On both devices connect to `wss://voice.<your domain>/ws`;
   repeat step 7 for 2 minutes (V6).
9. Restart the relay **without** `--echo`, connect both devices, untick "Play my own voice back", and talk Quest to phone for 2
   minutes (V7). Then V9: on the Quest tick **Open mic**, put it down with its speakers on, talk from the phone.
10. Send me (or the next session) a photo of each device's screen after each step, or `adb logcat -s godot | grep "voice:"`, plus
    the phone's make and model and the Quest's OS version. Remove the tunnel hostname afterwards.

---

## Spike C: Cardboard (phone camera rig and render budget)

### What was built

In the app's own project, because the question is whether **the app's** project exports for a phone (D8): `scenes/spikes/cardboard_spike.tscn`
and `scripts/spikes/cardboard_spike.gd` (+ `frame_stats.gd`), using only the app's viewing core (`environment_manager.gd`,
`view_modes.gd`, the section clip, `mesh_identity.gd`); `project.godot` gains `.phone` overrides (OpenXR off, the Meta passthrough and
spatial-entity settings off, and **this scene as the main scene** for a `phone` export); `tools/android/phone_export_preset.cfg.example`
(the preset with the `phone` feature tag, XR Mode Regular, no Meta plugin); and `tools/save_assembly_glb.gd`, which turns any native
assembly file (multi-file ones too) into the glb the headset would load, through your backend.

The app opens on a **setup screen** (touch): two model URLs (the PC serves them), the lens values (eye spacing, k1, k2: from your
viewer's QR profile, or leave Godot's defaults), a collision switch, **Load both**, **Use the demo rocket** and **Start the run**.
The run uses Godot's built-in `MobileVRInterface` (side-by-side stereo, lens distortion, gyro head tracking). **Tap the screen** (the
viewer's button) or gamepad **A** for the next step, **B** to stop; the gamepad **D-pad** tunes k1 (up / down) and k2 (left / right). Each
step's numbers float in front of you and go to the log; **after the last step the setup screen lists every step's result**, so a photo of
the screen is the report.

| Step | What runs |
|---|---|
| C2 | The light model (gear train), stereo, edges on, section on, MSAA 2x |
| C3 | The heavy model, same settings; **leave it 10 minutes** for C4 |
| C3b / C3c / C3d | Heavy, then edges off, then MSAA off, then oversample 1.0: which change gets it to 60 |
| C8 | Magic window (mono, no viewer: the phone is a window you turn) |
| C5 | Drift: lay the phone flat and still for 60 s; the step reports the yaw drift |

### Pass / fail

The figures are for **your** phone (record make, model, chip, Android version).

| # | Measure | Pass | Fail means |
|---|---|---|---|
| C1 | The phone build starts without OpenXR (the first log line says `OpenXR initialised = false`, `feature tag 'phone' = true`), and the Quest build still starts in XR | Both | If the export refuses (it may insist OpenXR is on) or OpenXR still starts, note the message: the fallback is a separate small project for the phone (P5 decides) |
| C2 | Gear train | **PASS-60** in the step's line: p95 frame ≤ 16.7 ms, ≤ 1% of frames over 33 ms | Which of C3b to C3d gets it there |
| C3 | Heaviest assembly | **PASS-60** | Same; if none does, P5 starts with magic window and the LOD work (DIDSA-CAD `docs/lod-strategy/`) |
| C4 | C3 after 10 minutes (warm phone) | ≥ 50 fps | Thermal throttling: P5 needs a lower default |
| C5 | Yaw drift in 60 s, phone flat and still | ≤ **5°** | P5 writes its own sensor fusion from `Input.get_gyroscope` / `get_gravity` |
| C6 | Your judgement in the viewer: head turns feel immediate, picture sharp, straight lines straight after tuning k1 / k2 | Yes | Note what was wrong |
| C7 | Load of the heavy glb (the load line on the setup screen) with **collision on** | ≤ **5 s** in total; note collision's share | Build collision lazily (only when the drone cursor needs it) |
| C8 | Magic window | PASS-60 | |
| C9 | A Bluetooth gamepad | Its buttons appear in the log with its name, and A / B / D-pad work | P5's mapping table needs another layout |

### Your steps (about an hour)

**Once, on the PC (DIDSA-VR folder, backend running):**
1. Make the two glbs (the backend from `secrets.cfg`, or set `CAD_URL` and `CAD_KEY`):
   `godot --headless --path . --script res://tools/save_assembly_glb.gd -- demo/assemblies/gear_train/Gear_train.didsa build/gear_train.glb`
   and the same with your heaviest assembly's root `.didsa` file as `build/heavy.glb`. Each prints its size.
2. Serve them: `cd build && python3 -m http.server 8080`. Note the PC's local IP.
3. Godot's Android export templates as for the Quest (`docs/android-build.md`). Append `tools/android/phone_export_preset.cfg.example`
   to your `export_presets.cfg` (it is preset 1, after the Quest's), open Project > Export, check the phone preset shows custom feature
   `phone` and XR Mode Regular, and export it. **If the export refuses, that is C1's answer: send the message.**

**On the phone:**
4. Allow installing from USB, `adb install -r build/didsa-phone-spike-debug.apk`, start **DIDSA Phone Spike** (C1).
5. On the setup screen: type `http://<PC IP>:8080/gear_train.glb` and `.../heavy.glb`, switch **collision** on, press **Load both**:
   two load lines appear (C7). Type your viewer's lens values if you have them.
6. Press **Start the run**, put the phone in the viewer. Tap through C2; on C3 wait **10 minutes** (C4); tap through C3b to C3d and
   C8 (take the phone out of the viewer for C8); for C5 lay it flat on the table for 60 s. Tune k1 / k2 with the gamepad whenever lines
   look bent (C6), and press its buttons once (C9).
7. After the last step, **photograph the setup screen** (it lists every step's result). Send the photo, plus make / model / chip /
   Android version, to me or the next session.

---

## What each spike settles

- **Voice (V1 to V9)** sets P3's size: TwoVoip as is (P3 medium), built from source (larger), or no workable add-on (P3 blocked; D5 would
  need revisiting). It also says whether open mic needs echo handling and how big the jitter buffer must be.
- **Cardboard (C1 to C9)** sets P5's starting point: `MobileVRInterface` or a custom rig, the phone's default render settings, whether
  collision is built on load, whether magic window comes first, and whether the phone build can be the same project.
- Neither changes P1 or P2.
