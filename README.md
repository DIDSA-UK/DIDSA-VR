# DIDSA VR spike (Godot)

Milestone 0's engine spike (glTF endpoint + engine choice) is done: Godot
won, proven on a real assembly over PCVR. This project is now milestone 1's
working ground — "Import and viewport" — building out the real interaction
model and multi-format loading. Still plain Godot 4 core (no
`godot-xr-tools`, no addons).

**Picking this up fresh (including a new Claude Code session)?** Read
[`docs/status.md`](docs/status.md) first — what's built, what's open, the
known teleport bug, untested paths. [`docs/backend-api-notes.md`](docs/backend-api-notes.md)
covers the DIDSA-CAD endpoints this client depends on.
[`docs/vision-brief.md`](docs/vision-brief.md) is the fuller product vision
(milestones, interaction model, open decisions) — a point-in-time export, not
live-synced.

## What it does

1. On start, tries to activate OpenXR. On a headset (or a PCVR runtime on
   desktop) you're in VR; otherwise it runs as a flat 3D preview so you can
   sanity-check the download/parse step without a headset attached.
2. Reads `assembly.didsa` (or whatever `native_file_path` points at) from
   this project folder and `POST`s it to `{backend_url}/document/import/native`
   — this is the same "load a project" step the Flutter app does, just done
   once at startup here so the backend actually has your assembly in memory.
   The part id to load is read straight out of that file's own
   `document.root_part_id` field — nothing to look up or type in by hand.
3. Downloads `GET {backend_url}/document/parts/{part_id}/assembly-mesh.glb`
   with your `X-API-Key`, parses it with Godot's built-in `GLTFDocument`, and
   drops the result about a metre in front of you.
4. Each mesh can be manipulated two ways ("Individual part manipulation" in
   the vision brief), and the two are independent of each other: **grip**
   grabs the part your hand is touching — anywhere on it, not just near its
   middle (inside its bounding box or within 5 cm of it; a light cyan
   highlight shows what a grip would take). The part stays attached exactly
   where you took hold, so turning your hand turns it about that spot; its
   position (not its rotation) goes through the same Steadiness filter as
   whole-model moves, so a held hand's tremor doesn't reach it — it drops on
   release, regardless of what's selected. Separately, point
   at a part from a distance — a real ray test against its actual geometry
   (not just a cone around its origin point, so big and overlapping parts
   pick correctly; nearest hit wins) highlights it pale yellow and shows its
   name — and pull the **trigger** to select it (trigger again, or aim at
   nothing, to deselect) — while selected, the **thumbstick** rotates it
   about the point the ray hit (or its centre), relative to how you're
   currently looking (left/right spins it, up/down tips it away/towards you,
   not around the part's own possibly-tilted axes), and **A/X**/**B/Y** pull
   it nearer or push it farther — at a speed proportional to how far the part
   is from your hand (0.18 m/s at 30 cm, 0.6 m/s at 1 m, 3 m/s at 5 m), so far
   parts travel quickly and near ones can be placed finely. A thin cyan laser
   shows where you're aiming; selected parts get a yellow highlight. Every
   part move (grip-drag or laser rotate/nudge) is undoable — see the wrist
   tablet's Undo/Redo below.
5. Walk with the **left thumbstick** (relative to where you're looking); the
   **right thumbstick**'s X axis snap-turns, its Y axis aims and blinks a
   teleport (push forward and point the right hand's laser at the floor — a
   cyan ring marks where it lands, within 5 m — release to jump there). Either stick backs off automatically while that hand has a
   part selected, so rotating a part never also turns or teleports you.
6. Grip on **empty space** (not near a part) to grab the whole model. With
   **one hand** it follows that hand (moves only, so a wrist twitch never
   spins it). The one-hand drag scales with the model: 1:1 for anything up
   to about 1.2 m across, then proportionally faster (a model 12 m across
   moves 10 cm for every 1 cm of hand, capped at 15x), so big models don't
   need endless re-grabbing. With **both hands** it moves with them (dragging
   is amplified by that same size-based gain, so a big model doesn't need
   endless re-grabbing two-handed either), turns as you swing the line
   between your hands, and scales (3x as sensitive as the raw hand spread,
   `scale_gain`) as you spread or close them — turning and scaling are
   deliberately left at their own raw sensitivity, not gain-amplified, so a
   given wrist swing always turns the model by the same angle regardless of
   its size. Pivots on the midpoint between your hands (or, once the drag
   gain has carried the model away from your hands on a big model, a virtual
   point that tracks it). Every turn builds on the model's current
   orientation, so you can rotate about one axis and then another naturally.
   Switching between one and two hands never makes the model jump.
7. **Wrist tablet.** A small cyan bullseye floats above your left wrist.
   Point the right hand's laser at it (it turns yellow) and pull the trigger
   to open the tablet; press the **X** on the tablet to close it. It never
   opens by itself, so looking at your wrist can't trigger it. While the
   laser is over the bullseye or the tablet, the trigger presses those
   instead of selecting a part. **Undo**/**Redo** buttons sit above the tabs,
   visible whatever tab is open — see item 9 below. Tabs:
   - **Modes** — switch model movement, user movement and part manipulation
     on or off independently, and set **Steadiness** (Off / Light / Medium /
     Strong): an adaptive filter on your hands while you hold the model *or*
     grip a single part, so a held hand doesn't shake it but deliberate moves
     stay direct (measured: Medium removes ~80% of a simulated 2 mm hand
     tremor and adds about 1 mm of lag on a slow 2 cm/s move — same numbers
     either way, whole-model or a single held part).
   - **Scale** — jump to 1:10, 1:5, 1:2, 1:1 (real life), 2:1, 5:1 or 10:1
     about the model's centre; lock the scale (also stops the two-hand
     spread/close and Fit from resizing); **Fit to view** brings the whole
     model in front of you at a comfortable size; **Home** returns it to
     where it first loaded (not while the scale is locked). For an exact
     value, click the **right thumbstick** — see item 8.
   - **Tools** — see item 10.
   - **Files** — load a `.glb`/`.gltf` from the `models/` folder next to
     `project.godot` (or `user://models`, which also works in an exported
     build) with no backend at all. Local files are read as metres, so 1:1
     is the file's own size; change `local_glb_scale` on Main if yours are
     in millimetres. The `models/` contents are git-ignored.
   - **Perf** — fps, CPU/GPU render time, script and physics time, part
     count, draw calls, load times; plus the levers for speed: **Shadows**,
     **Resolution** (100/80/65% of the headset runtime's size) and **MSAA**.
     Read GPU vs CPU ms first: over about 11 ms GPU (at 90 Hz) means lower
     Resolution or MSAA; high CPU means scripts. The tablet only renders and
     measures while open.

   With no `secrets.cfg` the app now starts anyway, ready for a local file.
8. **Popup keyboard.** Click the **right thumbstick**, anywhere, to open a
   numeric keypad floating in front of you, pre-filled with the model's
   current scale multiple — its first real use, per the vision brief's "for
   any text entry" (reserved since the wrist tablet was built). Type a new
   number (the first keystroke replaces the pre-filled value rather than
   appending to it) and press **OK** to apply it — this goes through the
   same scale-preset code as the Scale tab's buttons, so it's undoable the
   same way; **Cancel**, or clicking the right thumbstick again, backs out
   without applying anything. Aim and click its keys with the right hand's
   laser and trigger, same as the wrist tablet.
9. **Undo/redo.** Every part move (grip-drag, or laser-select rotate/nudge),
   whole-model move (one/two-hand drag, and the Scale tab's presets/Fit/
   Home), and Tools-tab hide/show action goes onto one shared history —
   **Undo**/**Redo** on the wrist tablet step back/forward through it. A
   drag that ends up back where it started doesn't push anything. The
   history is cleared whenever the model is replaced (loading a different
   file), since it can't point at parts that no longer exist.
10. **Tools tab.** **Shoot to hide** — toggle it on, then point the right
    hand's laser at a part (same hover+name as normal selection) and pull
    the trigger to hide it. **Hide all** / **Show all** toggle every part at
    once. **Reverse visibility** flips every part's hidden/shown state.
    **Isolate selected** hides everything except whichever part is currently
    laser-selected (select it first, then press Isolate). All four are
    undoable. A hidden part is click-through for both the laser and grip —
    it's out of the way, not just invisible.
11. A floating status label shows what's happening (importing, downloading,
    parse errors, part count) since you won't have a terminal visible once
    you're in the headset.

## 1. Drop in a real assembly

Export or copy a saved assembly file — a `.DIDSAprt`/`.didsa` file whose
**root Part has occurrences on it** (an assembly, not a bare single part;
that's what makes the grab test meaningful) — into this project folder,
next to `project.godot`, named `assembly.didsa`. It's plain JSON regardless
of the extension on the original file, so a straight copy/rename works.

If you'd rather not rename your file, or want to keep several around, change
`native_file_path` on the Main node instead (see below).

## 2. Set up the backend connection

Copy `secrets.cfg.example` to `secrets.cfg` (same folder as `project.godot`)
and fill in the two real values — this file is gitignored, so it never gets
committed, unlike the old approach of typing them into the Inspector (which
saves them straight into the tracked `.tscn` scene file):

```ini
[backend]
url="http://your-backend-host"
api_key="your-CAD_API_KEY"
```

- `url` — your server's address. **Use your Cloudflare Tunnel HTTPS URL if
  you have one** (e.g. `https://cad-api.snail-shell.uk`) rather than a bare
  LAN IP — Android blocks plain HTTP to anything but `localhost` by default,
  and switching that off needs a custom Gradle build, which is more setup
  than this project needs. If you only want to test on the desktop preview
  (not on-headset), a LAN `http://` URL works fine since that restriction is
  Android-only.
- `api_key` — matches your backend's `CAD_API_KEY`.

If `secrets.cfg` is missing, the app shows that on the status label instead
of silently trying (and failing) to hit an empty URL.

A few more knobs live on the **Main** node's Inspector, under **Backend**,
if you need to change them from their defaults:

- `native_file_path` — defaults to `res://assembly.didsa`; only change this
  if you named your file something else.
- `part_id_override` — leave blank. It's only there for the rare case you
  want to skip the import step entirely and point straight at a part id
  that's already loaded in the backend's session some other way.
- `quality` / `tier` / `include_hidden` — same meaning as the JSON endpoint;
  the defaults (`0.5`, full tier, hidden omitted) are fine to start.

Note: the import call and the mesh-fetch call both go out with no
`X-Document-Session` header, so both land in the backend's `"default"`
session — consistent with each other, but a *different* session than
whatever the Flutter app is using if it's open on your tablet at the same
time (it sets its own session id per launch). Close the Flutter app's
connection to this backend or don't rely on it having the same in-memory
state while you're testing the spike, if that matters for what you're
checking.

## 3. Desktop preview (no headset needed first)

Press **F6** (run current scene) in the editor. You should see the console
log the import, then the download and part count, and the status label
update in the 3D view. This alone tells you whether the endpoint, API key
and glTF parse are all working, before you touch export/sideload at all.

## 4. Export to Quest

1. In the editor: **Editor → Manage Export Templates** → download templates
   matching your Godot version, if you haven't already.
2. **Project → Export → Add… → Android.** Point it at your Android SDK if
   this is the first Android export on this machine (Godot prompts for the
   SDK path).
3. On the Android preset, under **Xr Features**, set:
   - `Xr Mode` → `OpenXR`
   - `Hand Tracking` → off (spike uses controllers only)
4. Export a debug APK.

## 5. Sideload and run

```
adb install -r path/to/exported.apk
```

Put the headset on, launch **DIDSA VR Spike** from Unknown Sources /
App Library → Quest Link's sideload list (however you normally launch
sideloaded apps). Reach a hand toward the loaded part and squeeze the grip
button.

## What "done" looks like for milestone 1

- The model loads and is recognisably your assembly, at real-world scale —
  `spawn_scale` defaults to `0.001` because the backend's native units are
  millimetres, but a raw glTF coordinate is read as one metre by Godot (and
  by the glTF spec generally). If a part still looks wrong-sized, that's
  the ratio to check first, not the model itself.
- You can see roughly where your hands are (a small glowing marker on each
  controller — bare `XRController3D` draws nothing on its own).
- Two of the vision brief's four manipulation modes are built: individual
  part manipulation (grip to grab close, trigger-laser to select and then
  grip/thumbstick/A-B at a distance) and user movement (thumbstick walk,
  snap-turn, teleport). Still open: whole-model two-hand rotate/scale, and
  scale views (jump to real-life / preset scales, with a lock).
- Only native `.didsa`/`.DIDSAprt` import is wired up so far. STEP, glTF and
  OBJ/STL loading (the rest of milestone 1's "done when") aren't built yet —
  the backend already has the pieces (`POST /parts/{id}/import-features` for
  STEP/OBJ/STL, straight-to-Godot `GLTFDocument` for a bare `.glb`), they
  just aren't hooked up in this client yet.
- You have a felt sense of load time and frame rate on real Quest hardware,
  which is the actual point — the vision brief's payload estimates (~90–100
  KB for a 186-instance test assembly) were never measured on-headset.

## Known gaps this project doesn't solve yet

- **Cleartext HTTP on Quest** — see the `backend_url` note above. Worth
  solving for real once milestone 1 is further along, not now.
- **Drag latency** — grabbing (grip or the laser-select's nudge/rotate)
  moves things locally and instantly; it doesn't round-trip to the backend's
  mate solver at all. That's deliberately out of scope here (see the vision
  brief's "Drag latency" open decision).
- **No multi-file assemblies** — the import step sends exactly one file's
  own JSON (its own features/occurrences/mates). If your assembly's
  Occurrences point at *other* files via `external_ref`, those referenced
  parts won't resolve — that's the server-side composition work the vision
  brief already flags as a separate, unbuilt roadmap item, not something
  this project attempts.
- **No godot-xr-tools** — deliberate, so far, to keep measuring the bare
  engine. Worth revisiting once milestone 1's interaction model is proven
  out, rather than continuing to hand-roll everything.
