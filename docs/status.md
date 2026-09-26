# Project status

Continuity notes for picking this project back up — what's built, what's
open, and how it's been worked on so far. See also `README.md` (setup/usage,
including every control) and `docs/backend-api-notes.md` (backend endpoints
this client depends on). The fuller product vision — milestones, interaction
model spec, open decisions, parked ideas — is `docs/vision-brief.md`, a
point-in-time export of a live Claude Docs artifact; ask John for the live
link if it's gone stale (it isn't kept in sync automatically — see "Vision
brief drift" below).

Last updated after commit `c426ac3`.

## Milestone 0 — glTF endpoint and engine choice: done

Backend built the node-instanced `assembly-mesh.glb` endpoint (PR #250,
merged). A hands-on Godot 4 OpenXR spike then proved the whole pipeline on a
real headset (PCVR via Virtual Desktop, not a sideloaded APK — see
"Untested paths" below): import a real assembly → fetch the glb → render at
correct real-world scale → grab a part → walk around. Godot won; no formal
Unity comparison was run since nothing surfaced that Godot couldn't do.

## Milestone 1 — Import and viewport: in progress

Two of the vision brief's four manipulation modes were already built; the
other two, plus the wrist tablet that switches between them, are now built
too. All of it is committed and pushed.

### Built

- **Native import and render.** `.didsa`/`.DIDSAprt` file → backend import →
  `assembly-mesh.glb` fetch → render at correct mm→m scale (`main.gd`).
- **Local `.glb`/`.gltf` loading, no backend.** From `models/` next to
  `project.godot` (git-ignored contents) or `user://models`, chosen on the
  tablet's Files tab. Local files are read as metres (`local_glb_scale`). The
  app also starts fine with no `secrets.cfg`. Loading replaces the model
  cleanly (hands release and deselect first).
- **Individual part manipulation** (`controller.gd`):
  - Grip grabs the part your hand is *touching* — inside its bounding box or
    within 5 cm (`grab_reach`); smallest part wins when several qualify; a
    light cyan highlight shows what a grip would take. The part is
    reparented keeping its world pose, so it pivots about where it was taken.
  - Laser-select (trigger): point and pull to select (trigger again, or aim
    at nothing, to deselect). Thumbstick rotates the selected part about
    world-up and the camera's flattened right axis (an earlier version used
    the part's own drifting axes and felt wrong). A/X and B/Y nudge it
    nearer/farther at a speed proportional to its distance from the hand
    (`nudge_rate`, 0.6 × distance per second, clamped 0.03–8 m/s).
  - **Known limitation:** laser-select still picks by angle to each part's
    *origin point* within a 12° cone, and rotation pivots on that origin.
    Both mis-behave on big or overlapping parts. Replacing it with a real ray
    test is the first item of the next phase.
- **User movement** (`locomotion.gd`): left thumbstick walks/strafes
  relative to view; right thumbstick X snap-turns, Y aims a teleport. The
  landing ring appears where the right laser meets the floor (within 5 m);
  releasing the stick moves your *head* onto the ring. Either stick backs off
  while that hand has a part selected (`is_manipulating()`).
- **Whole-model movement** (`two_hand_model.gd`): grip on empty space.
  One hand drags the model (translation only), amplified in proportion to
  model size (1:1 up to 0.6 m radius, capped at 15×). Two hands move, turn
  and scale it about the midpoint between them. Each frame applies only the
  change since the last frame, so a second rotation builds on the current
  orientation (measuring against the pose at grab start made the second
  rotation feel anchored to the first — fixed). Spread/close scaling has a
  3× gain (`scale_gain`).
- **Hand steadiness** (`one_euro.gd`): hand positions feed the model through
  an adaptive One Euro filter (Off/Light/Medium/Strong, default Medium).
  Simulated results: Medium removes ~80% of a 2 mm hand tremor for ~1 mm of
  lag on a slow 2 cm/s move and ~9 ms on a fast move. Applies to whole-model
  moves; a single held *part* is still raw.
- **Scale views**: presets 1:10 … 10:1 about the model's centre (limits are
  multiples of real life, 0.1×–50×, so they work for mm backend models and
  metre local files), scale lock, Fit to view, Home.
- **Wrist tablet** (`wrist_tablet.gd`): a Control UI in a SubViewport on a
  quad on the left wrist. Closed by default; shoot the wrist bullseye with the
  right laser + trigger to open, X to close (an earlier version auto-appeared
  when you looked at your wrist and gave false positives). Tabs: **Modes**
  (switch model movement / user movement / part manipulation on and off,
  Steadiness), **Scale**, **Files**, **Perf** (fps, worst frame, CPU/GPU/
  script/physics ms, part count, draw calls, load times; levers for Shadows,
  Resolution 100/80/65%, MSAA). It isn't rendered or measured while closed.
  While the laser is over the bullseye/tablet, the trigger belongs to them
  (`ui_hover` meta on the right controller, checked by `controller.gd`).
  The **right thumbstick click is deliberately unused**: the vision brief
  reserves it for the popup keyboard (not built yet).

### Frame rate

The scene is cheap: measured on the dev laptop's RTX 4080 at headset
resolution (2 × 2064×2208, MSAA 2×), it renders in ~1.4 ms GPU (shadows ~0.6
ms, MSAA ~0.9 ms of that). A 90 Hz budget is 11.1 ms. Early headset runs sat
at 20 ms / 46–50 fps with SSW filling in; the fix was disabling vsync in the
project and again when OpenXR starts (desktop-window vsync can hold a 90 Hz
headset near half rate) and running physics at 90 Hz. John reported frames
"much better" afterwards; exact figures weren't recorded, so check the Perf
tab if it regresses. If it does: a steady ~22 ms worst-frame is a rate cap
(vsync, Virtual Desktop's SSW setting), spikes are hitches in the app.

### Still open for milestone 1

- **STEP/OBJ/STL import in the client.** The backend already has the pieces
  (`POST /parts/{id}/import-features`, see `docs/backend-api-notes.md`); the
  client only imports native files and bare glb so far.
- **Measured on-headset numbers on Quest**, not just PCVR (see below).
- The popup keyboard (right thumbstick click) and the rest of the tablet's
  tool surface belong to the next phase.

## Next phase — "CAD foundations" (planned, not started)

In dependency order: (1) precise picking — a real ray test against the
parts with hover highlight and the part's name, pivoting on the hit point or
part centre; (2) undo/redo for part moves, model moves and hide/show, with
tablet buttons and a command stack later tools can push to; (3) the popup
keyboard on right thumbstick click, used for exact typed values; (4) a Tools
tab: shoot-to-hide, hide/show all, reverse visibility, isolate. Out of scope
for that phase: STEP/OBJ/STL import, the Quest APK / cleartext HTTP,
multiplayer, mates, sections, measurements.

## Untested paths

- **Standalone Quest APK.** Every test so far has been Godot editor +
  Virtual Desktop PCVR streaming to a headset from a desktop (John
  deliberately iterates on PCVR — faster). No APK has been exported or
  sideloaded; the README's cleartext-HTTP note is still theoretical. PCVR
  performance numbers say little about Quest's budget.
- **STEP/OBJ/STL import** — backend support exists, nothing in the client
  calls it.
- **Everything since `dd0db4e` has been verified headless, not yet in the
  headset, except where John reported results.** Reported in the headset:
  the teleport ring at the laser point was "better", and frame rate is
  "much better" after the vsync/physics change. Not yet headset-confirmed:
  the two-hand rotation fix, one-hand drag gain, distance-scaled A/B nudge,
  steadiness levels, the tablet's Files/Modes/Perf tabs, grip-anywhere grab
  and its hover highlight.

## Repo and secrets

Private repo: `github.com/DIDSA-UK/DIDSA-VR` (backend stays in the separate
`DIDSA-CAD` repo). `secrets.cfg` (gitignored) holds the real `backend_url`
and `api_key` for a given dev machine, loaded at runtime by `main.gd`;
`secrets.cfg.example` shows the format. These were previously hardcoded as
script defaults, which would have leaked the real API key into git history —
if you ever see a real credential as a literal default value in a script
again, that's a bug, pull it out the same way. `models/*` is also
git-ignored (models are often proprietary; only `models/.gitkeep` is
tracked).

`scenes/main.tscn` currently has uncommitted, accidental-looking editor
changes (the status label, camera and light shifted by the same offset and
rotation). Don't commit it without asking John.

## How this has been worked on

Early on this was a conversational AI session with remote access to John's
machine (a device-bridge shell, no Godot console visible), testing by
putting the headset on and reporting back. That loop is good for feel and
interaction bugs and slow for anything needing console output or multi-file
refactors. Since `dd0db4e` a local Claude Code CLI session in this repo
(`gh` authenticated) does the sustained coding, and it can run Godot itself:

- Godot: `C:\Users\johnn\Downloads\Godot_v4.7.2-stable_win64.exe\
  Godot_v4.7.2-stable_win64_console.exe` (not on PATH).
- Parse check: `"$G" --headless --path . --check-only --script
  res://scripts/x.gd` (reports `SCRIPT ERROR: Parse Error`; the OpenXR "no
  HMD" notice is harmless).
- Smoke tests: an `extends SceneTree` script that builds nodes in
  `_initialize()`, `await process_frame`s, prints `SMOKE …`, and `quit()`s;
  run with `--headless --script`. The tablet was tested by aiming the right
  controller at button positions and emitting `button_pressed`/`released`.
- GPU timing: run non-headless with the scene in a big SubViewport and
  `viewport_get_measured_render_time_gpu`.
- **Never run `main.tscn` without pointing `main.secrets_file_path` at a
  nonexistent file** — it would POST to the real dev backend.
- Headless tests can't fake a real grip press or a headset; anything relying
  on those is exercised by calling the routine directly and is flagged as
  unverified in-headset.

## Vision brief drift

`docs/vision-brief.md` is an export and its milestone table still says, for
milestone 1, that whole-model two-hand rotate/scale and scale views are open.
Both are built. The live Claude Docs artifact should be updated to something
like: "Native import, individual part manipulation, user movement, whole-model
one/two-hand movement, scale views, the wrist tablet (modes, scale, local
glb files, perf) and local glb import are built. Still open: STEP/OBJ/STL
import and on-Quest measurements."
