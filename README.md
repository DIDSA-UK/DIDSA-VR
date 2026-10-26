# DIDSA Design Tools VR

> The name is a placeholder; the repository is still `DIDSA-VR`.

Build, assemble and model parametric CAD in VR. A Godot 4 / OpenXR client for [DIDSA-CAD](https://github.com/DIDSA-UK/DIDSA-CAD):
everything you author here is stored by the DIDSA-CAD backend and opens in the flat app, and the other way round.

Runs on a Quest (standalone, sideloaded), on a PC headset (PCVR), or as a flat 3D preview on a desktop with no headset.

- **Engine:** Godot 4.7, Mobile renderer, OpenXR. Plain core Godot: no addons, no `godot-xr-tools`.
- **Backend:** a running DIDSA-CAD server (HTTP API) and, for the Browser window, its browser relay.
- **Picking this up fresh?** Read [`docs/status.md`](docs/status.md), then [`docs/README.md`](docs/README.md). Working in this repo with Claude Code: [`CLAUDE.md`](CLAUDE.md).

## Status at a glance

Every feature is covered by headless tests, software renders and (where noted) a real backend. **Testing on a headset is ongoing and informal, so this README does not claim which features have been checked by hand**, and nothing has been measured on Quest hardware yet. The matrix, with dates, is in [`docs/status.md`](docs/status.md).

| Area | State |
|---|---|
| View and manipulate (grip, laser, whole-model move/turn/scale, steadiness, undo/redo, walk/turn/teleport) | Built |
| Assembly tools: Mates, Colours, Sections, Measure | Built; real backend |
| Floating windows: Tree, Browser (and PDF), Calculator, Images | Built; browser relay verified end to end |
| **Assembly Rooms**: clipped, resizable workspaces on a sub-assembly | Built; real backend |
| **Design table**: sketch, constrain and feature a single part | Built; real backend |
| Wrist tablet, tool wheel, themes | Built |
| Multiplayer / observer client | Not built (idea in the vision brief) |

Tests at the last recorded run (22 Oct 2026): 3519 headless SMOKE lines, 80 render lines, 508 live-backend lines, all passing (exact counts and what each covers: `docs/status.md`, `tests/README.md`).

## Quick start (desktop, no headset)

1. Install Godot 4.7.x and open this folder as a project.
2. Copy `secrets.cfg.example` to `secrets.cfg` and fill in your backend `url` and `api_key` (the file is git-ignored). With no `secrets.cfg` the app still starts, ready for a local `.glb`.
3. The app starts on the **landing** (logo, rocket garden of demo models, a launcher panel, tips); it no longer imports `assembly.didsa` by itself. To get the old start-up import (a saved assembly whose root Part has occurrences, next to `project.godot` as `assembly.didsa`; a sample is included), turn off Settings > **Show the landing on start**, or open the file from the launcher's Continue / Open... tiles.
4. Press **F6** in the editor. The console logs the import, the mesh download and the part count; you get a flat 3D preview.

To try the UI without a backend or headset, open `lab/ui_lab.tscn` and press F6.

## The three working spaces

- **World**: the main assembly at arena scale, with all the viewing, manipulation and assembly tools. The wrist tablet owns the world (scale, view, hide, mates, environment).
- **Rooms**: a glass-walled, clipped, resizable window onto one sub-assembly. Summon one with the laser from the tablet's **Rooms** tile or from a tree row, resize it by its eight corner handles, carry it by its move bar, and **drop a carried part inside to add it** to that assembly. A room has its own console (scale, Fit walls, delete, close, minimise); the Rooms tile lists the open rooms with a picture of each, Bring to me and Close and a **world preview** (Hidden / Ghost / Preview). Details: [`docs/assembly-rooms-scope.md`](docs/assembly-rooms-scope.md), [`docs/assembly-rooms-plan.md`](docs/assembly-rooms-plan.md).
- **Design table**: a tilted console in front of you for authoring one part. Pick a flat face or reference plane, sketch on it with the laser, type dimensions on the numeric pad, then add features. Uses DIDSA-CAD's own tool names: Sketch (Line, Rectangle, Circle, Arc, Polygon, Point, Slot), Constrain, and Feature (Extrude, Revolve, Fillet, Chamfer, Shell, Mirror, plus the depth options added in Phase 7). Details: [`docs/design-table.md`](docs/design-table.md).

## Controls

Right hand is the laser and the selector; left hand walks.

| Input | Does |
|---|---|
| **Grip** on a part (inside its box or within 5 cm) | Grab it where you took hold. Position is steadiness-filtered. Cyan highlight shows what a grip would take. |
| **Grip** on empty space | Grab the whole model. One hand moves it (drag gain grows with model size, capped x15); two hands move, turn and scale it. |
| **Right laser + trigger** | Select the part (yellow). Trigger again, or aim at nothing, to deselect. On a sub-assembly: the grip latches with a dead zone and the trigger cycles the level; a breadcrumb names what you hold. |
| **Right thumbstick** (part selected) | Rotate it about the hit point, relative to your view. |
| **A / X** and **B / Y** (part selected) | Pull it nearer / push it farther, speed proportional to distance. |
| **Left thumbstick** | Walk (speed slider on the tablet: 1.5 to 30 m/s). |
| **Right thumbstick** X / Y | Snap-turn / aim and blink a teleport (push forward, point at the floor, release). Scrolls a panel when the laser is on one. |
| **Right thumbstick click** | Numeric keypad pre-filled with the scale; type an exact scale and press OK (undoable). |
| **Right trigger + grip together** | Open the **tool wheel**: move your hand towards a tile and let go to choose; let go in the middle to cancel. Mates, Measure, Summon table, Section, **Drive**, **Appearance**, **Show / Hide** (Isolate part, Invert, the Hide tool, Show all), Undo, Scenes, **Home** (back to the landing); a **Clear tool** pill sits under every top-level ring. Tips appear on your right wrist. |
| **Laser at the wrist icon + trigger** | Open the **wrist tablet** (never opens by itself). |
| **Grip a handle** (centre of a window's or the keyboard's lower edge, a room's move bar, a table's front edge) | Carry it somewhere else. |

The left trigger and left thumbstick are deliberately unused for selection so they never block walking.
Every part move, whole-model move, scale change and Visibility action goes onto one shared undo history (Undo/Redo on the tablet; long-press Undo for the history list). Colour changes are not undoable.

## The wrist tablet

A 0.40 x 0.26 m panel with a **6 x 2 home grid** (all 12 tiles used). **Back** climbs one level; the top bar shows status chips (active tool, Unsaved, Table open) and **Undo / Redo / Settings / Close**.

| Tile | Opens |
|---|---|
| **Design** | Summons the design table, or brings it to you. |
| **Rooms** | **New room** (an empty sub-assembly, summoned with the laser), and a tile per open room: its picture, **Bring to me**, **Close**. |
| **Assemble** | Mates (face / edge / corner picking, Coincident, Concentric, Parallel, Distance, Angle, Gear / Rack and pinion / Screw (turning one part turns the other), Limit distance / Limit angle (a travel that stops at a minimum and a maximum), Drive (turn a mated part with the stick so its mechanism runs), Relax (a sandbox: moves are temporary and everything goes back) / Enforce all, Fix/Float). |
| **View** | Navigate, Scale (1:10 to 10:1, lock, Fit, Home), Visibility, Hide tool, Display, Colours, Environment (Light / Dark / Mid / Passthrough). |
| **Inspect** | Measure (vertex / edge / face, one or two picks) and Sections (a client-side clip plane). |
| **Files** | Open `.glb`/`.gltf` (local, no backend), `.step`/`.stp`/`.stl`/`.obj` (via the backend), `.didsa`/`.DIDSAprt` (Open, or Add to the loaded assembly or the room you are in); New assembly; Save as new file. An Open that would lose unsaved changes asks: Discard and open, Save then open, or Cancel. |
| **Home** | Back to the landing: the demo models, the launcher and the tips. (The tool wheel has a Home wedge too.) |
| **Tree**, **Calculator**, **Images**, **Browser** | Free-floating, resizable windows (several Images and Browsers at once). The Browser is a headless Chromium behind the browser relay, and doubles as the PDF reader. |
| **Settings** | Movement (Steadiness, travel speed), Display (fps/CPU/GPU, Shadows, Resolution, MSAA, Max rooms), Appearance (theme: Navy / Simple / Dark, shader effects, glass room walls), Comfort (reduce motion, haptics, sound, tool wheel), Project folder, Design table. |

One mode tool is on at a time (Mates, Measure, Sections, Hide tool); a badge above your right hand shows which. Anything needing real text opens a full QWERTY keyboard that you can carry by its handle.

## Architecture

```
Headset (OpenXR)        Godot client (this repo)                DIDSA-CAD
  controllers, HMD ──▶  scenes/main.tscn + scripts/   ──HTTP──▶ backend API (mates, occurrences,
                          controller.gd  two_hand_model.gd        measure, import, sketch/feature routes)
                          tools, windows, rooms, design_table  ─WebSocket (CDP)─▶ browser relay ─▶ Chromium
```

| Folder | Holds |
|---|---|
| `scripts/` | Core: `main.gd`, `controller.gd`, `two_hand_model.gd`, locomotion, tools, windows (on `diegetic_panel.gd`) |
| `scripts/room/` | Assembly Rooms |
| `scripts/design_table/` | The design table and its CAD API client |
| `scripts/ui/` | Wrist tablet, theming, shader effects |
| `scripts/motion/` | Constrained-drag projector and benchmarks |
| `shaders/`, `ui/themes/`, `lab/` | Shaders (clip, grid, room walls, effects), theme presets, the UI lab |
| `tests/` | Headless, render and live-backend tests; see [`tests/README.md`](tests/README.md) |
| `docs/` | Documentation; index in [`docs/README.md`](docs/README.md) |

Units: the backend works in millimetres, Godot reads glTF as metres, so `spawn_scale` defaults to `0.001`. Edits are never VR-only data: mates, colours, occurrences and features are the same records the flat app uses.

## Configuration

`secrets.cfg` (copy of `secrets.cfg.example`, git-ignored):

```ini
[backend]
url="https://your-backend-host"
api_key="your-CAD_API_KEY"
# document_session="vr-headset-1"   # optional: keep or share one backend document

[browser_relay]
url="ws://your-relay-host:8100"
api_key="your-BROWSER_RELAY_API_KEY"
```

- **On Quest, prefer an HTTPS URL** (for example a Cloudflare Tunnel). A LAN `http://` URL is fine for desktop preview and probably on Quest too: Android's cleartext-HTTP rule is enforced by its Java networking, and Godot's `HTTPRequest` uses its own sockets. Not yet tried on a headset; see [`docs/landing-scope.md`](docs/landing-scope.md#plain-http-on-the-quest).
- Without `[browser_relay]` the Browser window says "No browser relay configured".
- By default each launch uses its own backend document session (`vr-...`) so it never replaces what the flat app has open.
- Main node, Backend group: `native_file_path` (default `res://assembly.didsa`), `part_id_override` (rarely needed), `quality`, `tier`, `include_hidden`; `local_glb_scale` for local glTF files in millimetres.
- Local models: put `.glb`/`.gltf`/images in `models/` (git-ignored) or `user://models`, or set a project folder under Settings.

## Build and deploy to Quest

1. **Editor, Manage Export Templates**: install templates matching your Godot version.
2. **Project, Export, Add, Android**; set your Android SDK path on first use. Under **Xr Features**: `Xr Mode` = `OpenXR`; `Hand Tracking` = off (controllers only).
3. Export a debug APK, then `adb install -r path/to/exported.apk`.
4. Launch **DIDSA Design Tools VR** from the headset's Unknown Sources list. (Renamed from "DIDSA VR Spike", and the name is a placeholder; export presets are git-ignored, so check your local preset's name and package ID.)
5. **Standalone passthrough** (and the QR scan's permission) need the OpenXR Vendors plugin in a Gradle build: `tools/install_vendors_plugin.sh`, a ready export preset to copy, and a first-run checklist for the headset are in [`docs/android-build.md`](docs/android-build.md). Prepared without an Android SDK: no APK has been built from it yet.

## Testing

```
GODOT=/path/to/godot tests/run_all.sh     # headless suite; no GPU, headset or backend
GODOT=/path/to/godot tests/ci.sh          # as run_all, and fails on any `false` assertion (what CI runs)
GODOT=/path/to/godot tests/ci_render.sh   # render tests under Xvfb + Mesa
GODOT=/path/to/godot tests/ci_e2e.sh      # live-backend tests (list: tests/e2e_ci_list.txt)
```

CI (`.github/workflows`) runs the headless suite on every code push and PR, and the backend tests in a separate workflow, both on Godot 4.7.2.
Headless tests cannot fake a real grip press, render for real, or judge feel. Tests that instantiate `main.tscn` must point `secrets_file_path` at a nonexistent file first; see `tests/README.md`.

## Known limitations

- **No Quest-hardware measurements** yet (load time, frame rate, Quest 2). Headset testing is ongoing and informal.
- **Plain HTTP on Quest untested** (see Configuration).
- **Server does not stop cycles or unknown Part ids** when adding occurrences; the client refuses them.
- **Multi-file assemblies** resolve on Open and Add the way the flat app does (`scripts/native_compose.gd`): each `external_ref` is looked for beside the opened file, then in the project folder and the models folders, under any native extension (`.didsa`, `.DIDSAprt`, `.didsacad`). A file whose Part id clashes with another file's is left out (the flat app re-mints it; not ported) and the status line names it.
- **Rooms**: 0.5 to 40 m on a side, no overlapping rooms, no rooms inside rooms; the default room limit is 4 (Settings, Display).
- **Sections** are one client-side plane; the backend's section endpoint is too slow for real-time dragging.
- **Design table, not built**: surfacing, curves, constrained sketch drag, sketch pattern/mirror, loft guide curves, feature mirror/pattern, extrude profile selection, dragging tree rows out, sub-assemblies on the table. Current list: [`docs/design-table.md`](docs/design-table.md), [`docs/design-table-gaps.md`](docs/design-table-gaps.md).
- **"DIDSA-CAD as a flat window"** is not attempted; it needs a web build of the Flutter client.

Roadmap and cross-repo order: DIDSA-CAD `docs/roadmap.md`; product vision: [`docs/vision-brief.md`](docs/vision-brief.md); what changed when: [`CHANGELOG.md`](CHANGELOG.md).

## Related and licence

- Backend, flat app and browser relay: [DIDSA-UK/DIDSA-CAD](https://github.com/DIDSA-UK/DIDSA-CAD).
- This is a private repository and no licence has been granted. Do not redistribute.
