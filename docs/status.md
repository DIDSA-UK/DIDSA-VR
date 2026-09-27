# Project status

Continuity notes for picking this project back up — what's built, what's
open, and how it's been worked on so far. See also `README.md` (setup/usage,
including every control) and `docs/backend-api-notes.md` (backend endpoints
this client depends on). The fuller product vision — milestones, interaction
model spec, open decisions, parked ideas — is `docs/vision-brief.md`, a
point-in-time export of a live Claude Docs artifact; ask John for the live
link if it's gone stale (it isn't kept in sync automatically — see "Vision
brief drift" below).

Last updated for the "CAD foundations" phase (precise picking, undo/redo,
popup keyboard, Tools tab), built on top of commit `62e55ab`, plus three
follow-up fixes: held-part steadiness, two-hand drag gain, and closing out
the up-axis question (see below and `docs/backend-api-notes.md`) — and now
milestone 1's last open build item, STEP/OBJ/STL import.

**"Untested paths" (below) is the running list of what's built but not yet
confirmed in the headset — keep it current: add to it whenever headless work
lands, and move an item out once John reports it checked over PCVR.**

## Milestone 0 — glTF endpoint and engine choice: done

Backend built the node-instanced `assembly-mesh.glb` endpoint (PR #250,
merged). A hands-on Godot 4 OpenXR spike then proved the whole pipeline on a
real headset (PCVR via Virtual Desktop, not a sideloaded APK — see
"Untested paths" below): import a real assembly → fetch the glb → render at
correct real-world scale → grab a part → walk around. Godot won; no formal
Unity comparison was run since nothing surfaced that Godot couldn't do.

## Milestone 1 — Import and viewport: build done; on-Quest measurement outstanding

Two of the vision brief's four manipulation modes were already built; the
other two, plus the wrist tablet that switches between them, are now built
too. All of it is committed and pushed. Every "done when" item the vision
brief's milestone table lists for milestone 1 is now built — the one thing
left is measuring it on real Quest hardware (see "Untested paths" below),
which needs a physical headset, not more code.

### Built

- **Native import and render.** `.didsa`/`.DIDSAprt` file → backend import →
  `assembly-mesh.glb` fetch → render at correct mm→m scale (`main.gd`).
- **STEP/STL/OBJ import.** `main.gd`'s `load_model_file()` dispatches on
  extension: `.glb`/`.gltf` load locally (below); `.step`/`.stp`/`.stl`/
  `.obj` go through `_import_external_file()` — a new endpoint sequence not
  used anywhere else in this client: `POST /parts` (there's no existing part
  to import into, unlike the native-assembly flow) → `POST
  /parts/{id}/import-features` with the file's own bytes (base64) → the same
  `assembly-mesh.glb` fetch every other backend part uses. Uses its own
  `HTTPRequest` node (not the one the startup native-import flow occupies)
  and Godot 4's `await some_signal` to await each step in turn, rather than
  the connect/disconnect dance `_on_import_completed`/`_on_mesh_completed`
  use — a cleaner pattern worth using if those get touched again. Backend
  units are mm regardless of source format, so this uses `spawn_scale`, not
  `local_glb_scale`. Confirmed end to end for `.obj` and `.stl` against a
  real backend (`tests/e2e_step_import.gd`, generated fixtures, no
  proprietary geometry) — **STEP itself wasn't exercised** (no simple
  hand-written STEP fixture); same client code, different `source_format`
  string, so the risk is in the backend's own STEP parser, not this client.
  Files tab lists these alongside `.glb`/`.gltf` now.
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
  - **Precise picking (CAD foundations phase 1, done).** Laser-select is now
    a real physics ray test against each part's actual collision geometry
    (`create_trimesh_collision()`, added when a model loads) — nearest hit
    wins, replacing the old cone around each part's origin point, which
    mis-picked big or overlapping parts whenever the ray missed a part's
    geometry but still passed near its origin. A hover highlight (pale
    yellow) plus the hovered part's name (a floating `Label3D`) show what a
    trigger pull would select, before you commit to it. The thumbstick then
    rotates the selected part about the point the ray hit (or its centre),
    not its own origin.
- **User movement** (`locomotion.gd`): left thumbstick walks/strafes
  relative to view; right thumbstick X snap-turns, Y aims a teleport. The
  landing ring appears where the right laser meets the floor (within 5 m);
  releasing the stick moves your *head* onto the ring. Either stick backs off
  while that hand has a part selected (`is_manipulating()`).
- **Whole-model movement** (`two_hand_model.gd`): grip on empty space.
  One hand drags the model (translation only), amplified in proportion to
  model size (1:1 up to 0.6 m radius, capped at 15×). Two hands move, turn
  and scale it about the midpoint between them — **drag is now gain-
  amplified for two hands too** (same formula/cap as one-hand, measured once
  per gesture; turn and scale are deliberately left ungained, so a given
  wrist swing always turns the model the same angle regardless of size —
  previously only one-hand drag had this, so a big model needed constant
  re-grabbing with two hands). Each frame applies only the change since the
  last frame, so a second rotation builds on the current orientation
  (measuring against the pose at grab start made the second rotation feel
  anchored to the first — fixed). Spread/close scaling has a 3× gain
  (`scale_gain`).
- **Hand steadiness** (`one_euro.gd`): hand positions feed the model through
  an adaptive One Euro filter (Off/Light/Medium/Strong, default Medium).
  Simulated results: Medium removes ~80% of a 2 mm hand tremor for ~1 mm of
  lag on a slow 2 cm/s move and ~9 ms on a fast move. **Now also applies to a
  single held part** (`controller.gd`'s grip-grab) — its position (not
  rotation) goes through the same filter, with the same numbers, previously
  only whole-model moves did. Implementation note: the held part is no
  longer rigidly reparented onto the hand; `controller.gd` drives its
  transform explicitly every physics frame from a filtered hand position
  plus the grab-time offset, so it can filter position while still following
  the hand's rotation directly.
- **Scale views**: presets 1:10 … 10:1 about the model's centre (limits are
  multiples of real life, 0.1×–50×, so they work for mm backend models and
  metre local files), scale lock, Fit to view, Home.
- **Wrist tablet** (`wrist_tablet.gd`): a Control UI in a SubViewport on a
  quad on the left wrist. Closed by default; shoot the wrist bullseye with the
  right laser + trigger to open, X to close (an earlier version auto-appeared
  when you looked at your wrist and gave false positives). Tabs: **Modes**
  (switch model movement / user movement / part manipulation on and off,
  Steadiness), **Scale**, **Tools** (see the CAD foundations section below),
  **Files**, **Perf** (fps, worst frame, CPU/GPU/script/physics ms, part
  count, draw calls, load times; levers for Shadows, Resolution 100/80/65%,
  MSAA). It isn't rendered or measured while closed. While the laser is over
  the bullseye/tablet, the trigger belongs to them (`ui_hover` meta on the
  right controller, checked by `controller.gd`). **Undo**/**Redo** buttons
  sit above the tabs, visible whatever tab is open.

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

- **Measured on-headset numbers on Quest**, not just PCVR (see "Untested
  paths" below) — the one item left; needs a physical headset.
- STEP/OBJ/STL import, the popup keyboard and the tablet's Tools tab are all
  now built — STEP/OBJ/STL above, the other two in the "CAD foundations"
  section below.

## "CAD foundations" phase: done (headless-verified; not yet in the headset)

Built in dependency order, each step with its own headless test under
`tests/` (see `tests/README.md`):

1. **Precise picking** (`controller.gd`'s `_raycast_part()`). A real physics
   ray test against each part's actual collision geometry — nearest hit
   wins — replaces the old cone around each part's origin point. Parts get a
   collision shape when they load (`MeshInstance3D.create_trimesh_collision()`,
   called from `main.gd`'s `_show_model()`), so this needed no physics setup
   beyond that one call. A pale-yellow hover highlight plus the hovered
   part's name (a `Label3D` that follows the hit point) show what a trigger
   pull would select. The selected part's thumbstick rotation pivots on the
   ray's hit point (stored as a local-space offset, `_pivot_local`, so it
   tracks the part as it moves) rather than the part's own origin. Test:
   `tests/precise_picking.gd`.
2. **Undo/redo** (`scripts/command_stack.gd`). A generic history: a command
   is a label plus two Callables (`undo`, `redo`), pushed right after the
   action already happened. One shared instance, created by `main.gd`,
   handed to `controller.gd` (part moves via grip-drag and laser-select
   rotate/nudge — one command per grab/select session, not per frame),
   `two_hand_model.gd` (whole-model drags — one command per one/two-hand
   gesture, however it switches between them — plus the Scale tab's
   presets/Fit/Home), and `main.gd` (the Tools tab's hide/show/isolate,
   below). A no-net-change action (e.g. a drag that ends up back where it
   started) pushes nothing. The history is cleared whenever the model is
   replaced, since it would otherwise point at freed nodes. **Undo**/**Redo**
   buttons on the wrist tablet, visible on every tab. Test: `tests/undo_redo.gd`
   (including a synthetic hide/show command, proving the mechanism is
   generic enough for phase 4's tools before they existed).
3. **Popup keyboard** (`scripts/popup_keyboard.gd`). Opens on a click of the
   right thumbstick (`primary_click`, reserved since the wrist tablet was
   built) — a numeric keypad on a floating panel in front of the camera
   (yaw-only, so it stays upright regardless of headset pitch), hit-tested
   against the right hand's laser the same way as the wrist tablet (no
   physics). First real use: pre-filled with the model's current scale
   multiple; typing replaces the pre-filled value (not appends to it); OK
   applies it through `two_hand_model.gd`'s `set_preset()` (so it's undoable
   like any other scale change); Cancel, or clicking the thumbstick again,
   backs out. Test: `tests/popup_keyboard.gd`. **Not yet verified**: whether
   the panel's orientation logic (`Basis.looking_at()`, built and reasoned
   through headless, never rendered) actually faces you and reads right-way-round
   on a real headset — check this first over PCVR.
4. **Tools tab** (`wrist_tablet.gd`'s new tab, ops in `main.gd`). **Shoot to
   hide** toggles a per-hand flag (`controller.gd`'s `hide_tool_active`) that
   redirects the trigger from laser-select to hiding whatever it hits (same
   ray test, same hover). **Hide all**/**Show all**/**Reverse visibility**/
   **Isolate selected** operate on the whole assembly. All four push a
   single batched undo command (a dictionary of part → previous visibility).
   A hidden part is click-through for both the laser (`_raycast_part()` now
   loops past held/hidden colliders, capped at 8 attempts) and grip-grab
   (`_find_grab_target()` skips invisible parts) — it's out of the way, not
   just invisible. Test: `tests/tools_tab.gd`.

The one thing this phase touches that talks to a real backend —
`tests/e2e_backend.gd` — was re-run after `create_trimesh_collision()` was
added to the load path and still passes end-to-end (see "How this has been
worked on" below for the numbers).

Out of scope for this phase (unchanged): STEP/OBJ/STL import, the Quest
APK / cleartext HTTP, multiplayer, mates, sections, measurements.

## Milestone 4 — assembly environment (mates, colours, sections, measurements): foundation laid, tools not built yet

Started by reading the vision brief's Assembly tools/Mates workflow sections
and the 27 Sep cross-compatibility note (mates must be built as a client to
DIDSA-CAD's existing Mate endpoints, not a VR-only representation — see
below). Before any of the four tools themselves: a real architectural gap
had to be closed first, and a wrong assumption about Godot physics caught
before it could quietly break picking.

**The gap: `assembly-mesh.glb` carried no occurrence or face/edge identity at
all.** Read `backend/app/document/mesh_export.py`/`models.py` directly (in
the `DIDSA-CAD` repo) and confirmed the Mate/Measure APIs need a real
`occurrence_id` plus a `SubShapeRef{body_id, shape_type, index}` — but the
glb encoder emitted anonymous transforms over shared meshes, no node name,
no extras. Fixed in `DIDSA-CAD` (backend, not this repo):

- `mesh_export.py`'s `AssemblyGlbInstance`/`encode_assembly_glb` now carry
  `owner_part_id`/`occurrence_id` (glTF node `extras`, not `name` — Godot
  silently uniquifies duplicate node *names*, which would corrupt an id
  reused by two occurrences of the same part) and `face_ids`/`body_ids`
  (primitive `extras`, parallel to the triangle list) — plain JSON, not a
  vertex attribute, so this client needs no custom `GLTFDocumentExtension`.
- `router.py`'s `_walk_assembly_glb_instances` threads the real owning
  Part/Occurrence through the recursion (empty `occurrence_id` means "this
  is `owner_part_id`'s own top-level content", matching
  `MeasureEntityRefSchema`'s own existing convention; a pattern-derived
  instance also gets an empty `occurrence_id` — it has no `Occurrence` entry
  of its own to reference).
- Found and fixed a second, real bug while verifying against genuine
  `pythonocc-core`: `_merged_body_mesh_data` (used by `assembly-mesh.glb` to
  merge a multi-Body Part into one glTF mesh) dropped `face_ids` entirely
  and would have silently mis-numbered them across bodies if naively offset
  the way triangle vertex indices are — added `MeshData.body_ids` so
  `(body_ids[i], face_ids[i])` reconstructs a real `SubShapeRef` even for a
  Part with more than one Body.
- New backend tests (real OCCT, `DIDSA-CAD` repo):
  `test_merged_body_mesh_data.py`, plus additions to `test_mesh_export.py`
  and `test_assembly_mesh_glb.py`. Full `DIDSA-CAD` backend suite (2491+
  tests) re-run clean against genuine `pythonocc-core` (micromamba,
  `backend/environment.yml` — see "How this has been worked on" below).

**A wrong assumption caught before it shipped: Godot's own `PrimitiveMesh`
winding is NOT what a real glTF import produces.** `create_trimesh_collision()`
ray hits only register correctly (from outside, on the expected face) when
the ray direction matches the mesh's *actual* front-facing winding — and
`BoxMesh` (used by several existing synthetic tests, including
`precise_picking.gd`) turns out to use the opposite winding convention from
standard glTF/OpenGL CCW-front. Confirmed directly against real OCCT
(`tessellate_shape`'s own vertex order dotted against its own stored normal:
+1.000 on every face of a test box) that OCCT tessellation uses the
standard convention, and separately confirmed (headless, a hand-built glb in
the real backend's own byte shape, loaded through the exact
`GLTFDocument.append_from_buffer` → `generate_scene()` →
`create_trimesh_collision()` path `main.gd` uses) that a *real* glTF import
hits correctly from outside on every one of a box's 6 faces, with
`face_index` landing exactly on the expected triangle every time. Net
effect: real backend-tessellated parts pick correctly (this doesn't change
anything about the already-shipped precise-picking feature, which only ever
ran against real parts or `BoxMesh` stand-ins that happened not to expose
this), but a *new* synthetic test built from a raw hand-rolled `ArrayMesh`
or `BoxMesh` is not a reliable stand-in for real glTF-imported geometry
where per-triangle face identity matters — `tests/mesh_identity.gd` builds
its own test glb in the real backend's byte shape for exactly this reason.

**Also found while wiring this up: `GLTFState.get_scene_node(idx)` looked
like the obvious way to map a glTF json node index to its generated Node,
but empirically only returns a live object *during* `generate_scene()`
itself** — called afterwards, from ordinary script code, it returns an
already-freed instance every time (undocumented anywhere obvious; found by
just trying it headless). Worked around instead by relying on
`assembly-mesh.glb`'s own nodes always being flat (one per placed instance,
no parent/child nesting — `encode_assembly_glb` never emits a "children"
key) — confirmed `generate_scene()` preserves that flat order 1:1 in
`scene.get_children()`, so plain index correlation works with no
`GLTFDocumentExtension` anywhere. Documented as a hard constraint in
`mesh_identity.gd`'s own docstring: this does NOT generalize to a glTF file
with real hierarchy/skinning.

**Built so far:**

- `scripts/mesh_identity.gd`: `tag_scene()` (called from `main.gd`'s
  `_show_model()` right after `generate_scene()`) tags every loaded part's
  `MeshInstance3D` with `occurrence_id`/`owner_part_id` (node meta) and
  `face_ids`/`body_ids` (also node meta, re-cast to real ints once at tag
  time — glTF JSON round-trips every number as float, and a request built
  straight off the raw round-tripped value would send `"index": 3.0`
  instead of `3`). `subshape_ref_for_hit(part, face_index)` turns a
  `controller.gd`-style raycast hit's own `face_index` into a real
  `SubShapeRef`; `occurrence_ref_for(part)` gives `{owner_part_id,
  occurrence_id}` for a `POST .../mates` or `.../measure` call. Test:
  `tests/mesh_identity.gd` — no backend needed, hand-builds a glb in the
  real encoder's exact byte shape.
- **Confirmed for real, end to end, not just headless-against-synthetic-data**:
  stood up a real throwaway backend (micromamba `didsacad` env, throwaway
  `CAD_API_KEY`, never John's real one), imported this repo's own tracked
  `assembly.didsa` (3 parts, 2 occurrences), fetched its real
  `assembly-mesh.glb`, and loaded that real response through the exact
  client code path (`GLTFDocument` → `generate_scene()` →
  `MeshIdentity.tag_scene()` → `create_trimesh_collision()`). All 3 parts
  came through with correct identity (root content: `occurrence_id=""`;
  each placed occurrence: its own real UUID) and correct per-part
  `face_ids` (204/444/12 entries matching each part's own triangle count);
  a real ray hit on the real geometry resolved via `subshape_ref_for_hit()`
  to a genuine `SubShapeRef` with a real OCCT body UUID. This is the first
  time this specific path (real backend → real glb → real identity tags →
  real ray hit → real SubShapeRef) has been exercised at all, closing the
  one gap this section would otherwise still be flagging.

### Mates tool: built (face-only, headless-verified, real backend confirmed)

The wrist tablet's new **Mates** tab, per the vision brief's "Mates
workflow": toggle the tool, laser-target a face on two different parts, pick
a mate type, type a value on the popup keyboard, Create. Plus the "Assembly
tools" list's **Relax all mates**/**Enforce all mates**. Built as a plain
client to DIDSA-CAD's real Mate endpoints (`scripts/mates_tool.gd`) — never
a VR-only representation, per the 27 Sep compatibility note.

- **Scope for this pass: FACE-only.** A raycast against a filled triangle
  mesh naturally resolves to a face; picking an *edge* needs either separate
  wireframe-pickable geometry or a nearest-boundary-edge heuristic on top of
  the face hit — not built yet. This still covers real, common mate types
  (coincident/parallel/distance/angle between planar faces, concentric
  between cylindrical faces), just not an edge-to-edge concentric mate yet.
- **Also scoped to top-level Occurrences of the loaded root Part.** The
  backend only lets a Mate reference a top-level Occurrence of its own owning
  Part anyway (`MateEntityRef`'s own docstring in DIDSA-CAD) — `mates_tool.gd`
  rejects a pick on the root's own unplaced content, and rejects two picks
  from different assemblies, with its own status message either way. This
  also happens to be exactly the case where a solved Mate's local-to-parent
  transform IS the flattened, world-relative-to-root transform already baked
  into that instance's Godot node (`assembly-mesh.glb` has no intermediate
  parenting at all) — `_apply_solved_transform()` relies on this directly;
  it would need real work to generalize past top-level occurrences.
- **"Relax all"/"Enforce all"**: there's no bulk-solve endpoint server-side,
  and this client never auto-solves during a drag (out of scope per the
  vision brief's own "Drag latency" decision). So `relaxed` just suspends the
  one auto-solve this tool would otherwise do right after `create_mate` —
  mirroring the flat app's own create-then-solve pairing (see
  `solve_for_occurrence`'s own docstring: "a freshly-authored Mate visibly
  snaps its target into place immediately, matching real CAD mate-authoring
  UX") — letting a user place several mates before solving them all at once.
  "Enforce all" loops `solve_for_occurrence` over every occurrence any of
  this Part's own Mates reference.
- Tests: `tests/mates_tool.gd` (pure pick-validation/payload-building logic,
  no network — a manually-tagged `Node3D` stand-in, same convention
  `mesh_identity.gd`'s own test uses) and `tests/e2e_mates.gd` (real backend,
  same "run manually" exception as `e2e_backend.gd`). Two real bugs caught
  while getting the pure test to pass, both now fixed: `Node.name` is a
  `StringName`, not a `String` — comparing a pick's stored label against a
  plain string literal silently failed until cast with `str()`; and the pick
  validator conflated "no backend identity at all" (an untagged part, e.g. a
  bare local `.glb`) with "this part's real, tagged root content" into the
  same wrong error message — now two distinct messages.
- **Confirmed for real, end to end, against a real backend**: stood up a
  throwaway backend, let `main.tscn` run its own real import/load of
  `assembly.didsa`, then drove `mates_tool.gd`'s real network calls against
  its own two real occurrences — picked a face on each, `create_mate()` (a
  genuine `POST /parts/{id}/mates`), confirmed it round-tripped through
  `GET .../mates`, confirmed the driven part's Godot transform genuinely
  changed (`solve_for_occurrence` ran server-side and the result was
  correctly applied client-side), then `delete_mate()` to clean up. This is
  the concrete proof of the cross-compatibility mechanism — the Mate this
  created is indistinguishable from one the flat app would create with the
  same call — though not yet checked against a Mate authored *by* the flat
  app itself (no flat-created assembly-with-mates fixture exists anywhere in
  either repo, and the flat app's own Dart/Flutter client isn't available in
  this sandbox to author one directly — worth doing once a device/toolchain
  for it is available, rather than just trusting the shared-endpoint
  argument).
- **Not yet built**: editing an existing mate's value/flip (only
  create/list/delete for this pass), edge picking, and colours/sections/
  measurements — the other three of milestone 4's four tools. Colours mostly
  falls out of the already-wired `Occurrence.color` field; sections is
  planned client-side (a shader clip-plane uniform, since the backend's own
  `section.py` is a stateless, re-tessellate-on-every-request preview
  endpoint, too slow for a dragged plane at 90 Hz); measurements reuses this
  same picking foundation against `POST /parts/{id}/measure`.
- **Not yet headset-verified** — this whole tool, like the rest of milestone
  4 so far, has only run headless and against a real backend from a cloud
  sandbox, never with a real hand pulling a real trigger.

## Untested paths

- **The Mates tab is headless- and real-backend-confirmed, never handset-
  tested.** The wrist tablet UI itself (tab layout, the type/flip/allow-
  rotation choice rows, the popup keyboard reused for a value, the mates
  list's Delete buttons) has never been rendered or clicked by a real laser —
  only the underlying `mates_tool.gd` logic has been driven directly
  (headless pure-logic tests plus one real end-to-end run against a real
  backend). Whether picking two faces in quick succession feels right, and
  whether the tab's layout fits legibly on the existing panel size alongside
  everything else, are both open.
- **Standalone Quest APK.** Every test so far has been Godot editor +
  Virtual Desktop PCVR streaming to a headset from a desktop (John
  deliberately iterates on PCVR — faster). No APK has been exported or
  sideloaded; the README's cleartext-HTTP note is still theoretical. PCVR
  performance numbers say little about Quest's budget.
- **STEP/OBJ/STL import** — now built and confirmed end to end against a
  real backend for `.obj`/`.stl` (`tests/e2e_step_import.gd`); `.step` itself
  wasn't exercised (no simple hand-written STEP fixture — see the "Built"
  section above). None of the three tried in the headset, or with a real
  (non-generated) file.
- **Everything since `dd0db4e` has been verified headless, not yet in the
  headset, except where John reported results.** Reported in the headset:
  the teleport ring at the laser point was "better", and frame rate is
  "much better" after the vsync/physics change. Not yet headset-confirmed:
  the two-hand rotation fix, one-hand drag gain, distance-scaled A/B nudge,
  steadiness levels, the tablet's Files/Modes/Perf tabs, grip-anywhere grab
  and its hover highlight.
- **The whole CAD foundations phase is headless-only so far** (see above).
  In particular: whether the laser-select hover highlight/name and the
  pivot-on-hit-point rotation actually feel right when aimed by a real hand
  rather than a scripted transform; whether trimesh collision on real
  (possibly complex/concave) parts is fast enough at load time and doesn't
  cost anything per frame beyond the ray query itself; whether the popup
  keyboard's panel actually faces you and reads the right way round (its
  orientation math was reasoned through, never rendered — see phase 3
  above); and whether shoot-to-hide/hide-all/isolate feel right as an
  interaction, not just as a visibility toggle that happens to work.
- **Three follow-up fixes, also headless-only so far:**
  - **Held-part steadiness.** A grip-grabbed part's position now goes
    through the same One Euro filter as whole-model moves (previously only
    whole-model moves did). Confirmed headless that it matches the
    whole-model numbers exactly (`tests/steadiness_filter.gd`'s new "held-part
    shake" block: ~2.0 mm Off, ~0.4 mm Medium). Not yet felt in a real hand —
    rotation still isn't filtered (only translation), so a part held by an
    off-centre grab point may still show some residual shake from hand
    rotation tremor; worth a specific check.
  - **Two-hand drag gain.** Two-hand model drag is now amplified for big
    models by the same formula as one-hand drag (previously only one-hand
    was). Turn and scale are deliberately left ungained. Confirmed headless
    (`tests/sensitivity.gd`'s new blocks) that the gain matches one-hand's
    exactly and that turn/scale stay independent of model size. Not yet felt
    on a real big model two-handed.
  - **Up-axis question, closed (not a headless/headset gap — just
    resolved).** No fix was needed: the backend's native coordinate system
    already matches glTF/Godot's Y-up convention (see
    `docs/backend-api-notes.md`). Any future "standard views" work can use
    Godot's own axes directly.

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

`scenes/main.tscn` previously had uncommitted, accidental-looking editor
changes (the status label, camera and light shifted by the same offset and
rotation) on John's own machine. This session's clone (a fresh
`DIDSA-UK/DIDSA-VR` checkout in a cloud sandbox) shows it clean against
`origin` — don't stage or commit it without asking first if it ever shows as
modified again.

## How this has been worked on

Early on this was a conversational AI session with remote access to John's
machine (a device-bridge shell, no Godot console visible), testing by
putting the headset on and reporting back. That loop is good for feel and
interaction bugs and slow for anything needing console output or multi-file
refactors. Since `dd0db4e` a local Claude Code CLI session in this repo
(`gh` authenticated) does the sustained coding, and it can run Godot itself:

- Godot: `C:\Users\johnn\Downloads\Godot_v4.7.2-stable_win64.exe\
  Godot_v4.7.2-stable_win64_console.exe` (not on PATH) on John's own machine.
  A cloud-sandbox Claude Code session (no GPU/display, no access to John's
  files) instead downloads its own headless Godot 4.7.2 Linux build and, for
  anything touching the backend, stands up DIDSA-CAD's FastAPI/pythonocc
  backend itself with micromamba (Docker wasn't available in that sandbox)
  and a throwaway `CAD_API_KEY` — never John's real key — pointed at by a
  local `secrets.cfg` it creates and never commits.
- **`tests/` holds the headless tests and `tests/run_all.sh` runs them all**
  (parse-checks every script, then the steadiness filter, sensitivity,
  two-hand rotation, grab/scale, precise-picking, undo/redo, popup-keyboard,
  Tools-tab and full-scene tablet tests). `tests/README.md` lists the
  expected values. Needs no GPU, headset or backend.
- **`tests/e2e_backend.gd` is the one exception**: it deliberately points
  `main.secrets_file_path` at the real `secrets.cfg` and drives the actual
  import/native → assembly-mesh.glb → scene-load flow against a running
  backend, using the tracked `assembly.didsa`. Run it manually once your
  backend is up. Confirmed once from the cloud sandbox: 3 parts, import
  21 ms, download 83 ms (47 KB glb), parse 2–3 ms, ~130 ms wall clock from
  instantiating the scene to "Loaded". This is the first time this path has
  been exercised outside John's own machine.
- Parse check: `"$G" --headless --path . --check-only --script
  res://scripts/x.gd` (reports `SCRIPT ERROR: Parse Error`; the OpenXR "no
  HMD" notice is harmless).
- Writing new tests: an `extends SceneTree` script that builds nodes in
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
Both are built, and so is STEP/OBJ/STL import since. The live Claude Docs
artifact should be updated to something like: "Native import, STEP/OBJ/STL
import, individual part manipulation, user movement, whole-model one/two-hand
movement, scale views, the wrist tablet (modes, scale, tools, files, perf,
undo/redo), the popup keyboard, and local glb import are built. Milestone 1
is otherwise done — the only thing left is measuring it on real Quest
hardware, not more building."

**Also not yet in the live doc:** the "Mates workflow" section in this export
now has a note (added 27 Sep 2026, this repo's copy only) that VR mates must
be readable/editable in DIDSA-CAD's flat app and vice versa, so a user can
move between VR and flat with the same assembly file — John's own
requirement, added ahead of the mates work itself so it's not missed when
that phase starts. Carry that note into the live doc too.
