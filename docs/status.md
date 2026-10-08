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

## Milestone 4 — assembly environment (mates, colours, sections, measurements): all four tools built

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
  create/list/delete for this pass), and edge picking. Colours and Sections
  are now built too (see below); measurements is still open — it reuses
  this same picking foundation against `POST /parts/{id}/measure`.
- **Not yet headset-verified** — this whole tool, like the rest of milestone
  4 so far, has only run headless and against a real backend from a cloud
  sandbox, never with a real hand pulling a real trigger.

### Colours tool: built (headless-verified, real backend confirmed)

The wrist tablet's new **Colours** tab, per the vision brief's Assembly
tools list. Simpler than Mates: no picking tool of its own — it acts on
whichever part is already laser-selected (`main.gd`'s now-public
`current_selected_part()`, the same lookup the Tools tab's "Isolate
selected" already used). A fixed swatch palette plus a **Custom hex…**
button (popup keyboard) and **Clear colour**.

- Built as a plain client to DIDSA-CAD's existing, already-shipped
  `PATCH /parts/{owner_part_id}/occurrences/{occurrence_id}` endpoint
  (`OccurrenceTransformUpdate.color` — the same field the flat app's own
  colour-disc row sets), so no backend changes were needed at all for this
  one, unlike mates. `scripts/colour_tool.gd` sends the hex string straight
  through (`""` clears the override, matching that field's own
  None-omitted/`""`-clears convention) and, once the backend confirms it,
  applies the colour locally via `material_override` so it's visible
  immediately without a full assembly reload.
- **A deliberate limitation, not an oversight**: "Clear colour" shows a
  plain neutral grey rather than reconstructing whatever the part's true
  pre-colour material was — that material identity isn't threaded through
  `assembly-mesh.glb` at all (only per-triangle face/body ids are, for
  mates/measurements), so a full reload is the only way to see the backend's
  own real post-clear rendering. Not undoable via `command_stack`, same
  precedent as Mates' create/delete: a backend-committed action, not a
  purely local instant transform.
- Tests: `tests/colour_tool.gd` (pure logic, no network — hex conversion
  matches the backend's own straight scaling exactly, root content is
  rejected before ever touching the network, `_apply_local_color` sets a
  real material) and `tests/e2e_colour.gd` (real backend, same "run
  manually" exception as the other `e2e_*.gd` tests).
- **Confirmed for real, end to end**: stood up a throwaway backend, let
  `main.tscn` load `assembly.didsa` for real, PATCHed a real occurrence's
  colour, confirmed it actually persisted server-side via a fresh
  `GET .../occurrences` fetch (not just trusting the optimistic local
  apply), confirmed the Godot node's own material changed to match, then
  cleared it again. Passed on the first real run.
- **Colouring hierarchy (round 2): `set_group_color()`, "Apply to whole
  group" on the tablet.** Loops the same PATCH over every Occurrence sharing
  the picked one's immediate `owner_part_id`, fetched via the real, confirmed
  `GET /parts/{id}/occurrences`. Tests: `tests/colour_tool.gd` (pure logic —
  the clearer root-content message, `_apply_local_color_to_group()`'s own
  filtering) and `tests/e2e_colour_group.gd` (real backend, same "run
  manually" exception): stood up a throwaway backend, group-coloured
  `assembly.didsa`'s real 2 sibling occurrences in one call, confirmed via a
  fresh `GET .../occurrences` that *both* persisted server-side (not just
  the one originally picked), confirmed the local preview reached every
  loaded sibling node too, then cleared the whole group again. Passed on the
  first real run.
- **Not yet headset-verified**, same caveat as Mates above.

### Sections tool: built (headless-verified, real-backend-confirmed, and the shader's own clip behaviour confirmed with a real software render)

The wrist tablet's new **Sections** tab, per the vision brief's Assembly
tools list. The vision brief itself doesn't specify a workflow for this one
(unlike Mates) — the interaction (a single grabbable clip-plane gizmo,
toggled from the tablet) was this session's own design call, not a spec
being implemented.

- **Confirmed client-side-only against the real backend source, not just
  `docs/backend-api-notes.md`'s own summary of it, before writing any
  client code.** Read `backend/app/document/section.py` directly:
  `compute_section_mesh` does a real OCCT `BRepAlgoAPI_Common` boolean per
  Body per plane (`_trim_solid_by_planes`), then a full re-tessellation of
  the result — recomputed from scratch on every single `POST
  /parts/{id}/section-preview` call, no caching, no persisted Feature. Far
  too slow to call every frame for a plane a real hand is dragging at 90 Hz,
  confirming the plan already flagged. This tool makes **no backend calls
  at all** — a world-space clip plane, applied by a small custom shader
  (`shaders/section_clip.gdshader`) shared by every loaded part via a single
  **global** shader uniform (one `RenderingServer.
  global_shader_parameter_set()` call per frame while active, not one per
  part).
- **Scope for this pass: ONE clip plane.** The backend's own endpoint
  supports several (AND-combined, for a quarter-cutaway), but the vision
  brief's Assembly tools list doesn't call for that and one plane already
  covers the common "see inside the assembly" case — the same kind of
  narrowing Mates made for face-only picking in its own first pass.
- **Interaction**: toggle **Section tool** on the tablet's new Sections tab
  to spawn a translucent disc gizmo (plus a small arrow showing which side
  stays) a short distance in front of wherever you're looking. **Grip**
  drags/tilts it 1:1, exactly like grabbing a part. **Flip** reverses which
  side is kept without moving the gizmo. This is its own mechanism
  (`scripts/section_tool.gd`), not a member of the `grabbable_parts` group
  that ordinary parts join: that group also feeds `two_hand_model.gd`'s
  model-bounds/Fit-to-view math and `main.gd`'s Tools-tab whole-assembly
  hide/isolate ops, and the gizmo must never be swept into either (it isn't
  part of the assembly, shouldn't move with a Scale-view change, and
  shouldn't be hidden by "Hide all"). `controller.gd` gained three small
  hooks (a check in `_try_grab()`/`_try_release()`, a per-frame call in
  `_physics_process()`) that hand GRIP to `section_tool.gd` first — mirroring
  exactly how `mates_tool_active`/`hide_tool_active` already redirect the
  TRIGGER for other tools, just applied to GRIP instead, and checked
  synchronously before any part-grab search runs so a hand can never grab
  both at once.
- **The real design problem this tool had to work around**: `colour_tool.gd`
  already owns `material_override` on parts (its optimistic local colour
  preview), and Godot's clip-plane discard has to run in whichever material
  is actually drawn — there's no way to layer a second, independent
  discard-only pass on top (`material_overlay`/`next_pass` both draw
  *after* the base pass has already written its fragments; neither can
  un-draw them). Rather than touch that shipped, real-backend-confirmed
  code, `section_tool.gd` **wraps** whatever's currently in
  `material_override` (null, or colour_tool's own flat-colour
  `StandardMaterial3D`) into a clip-aware `ShaderMaterial` only while
  active, re-deriving the wrap every frame from whatever's actually there
  right now — self-healing if colour_tool changes a part's colour while
  sectioning is on (briefly unclipped for that one part until the next
  frame's reconcile, not a crash) — and restores exactly what was there
  before on deactivate, including back to a genuinely absent override, not
  a placeholder. Zero changes were needed to `colour_tool.gd`.
- **The clip shader's own appearance**: `mesh_export.py`'s
  `AssemblyGlbInstance`/`encode_assembly_glb` only ever sets
  `pbrMetallicRoughness.baseColorFactor` — never a `metallicFactor`/
  `roughnessFactor` override, and never a texture — so a colour override
  (or its absence) means the glTF spec's own defaults (`metallic=1.0`,
  `roughness=1.0`) apply either way. `shaders/section_clip.gdshader`
  hardcodes exactly those two values and takes only `albedo_color` as a
  parameter, so it never has to reimplement texture sampling.
- **Godot gotchas caught while building this** (new ones, beyond the
  BoxMesh-winding/`GLTFState.get_scene_node()` pair from earlier in this
  milestone):
  - **A bare `Node3D`'s `global_position`/`global_transform` requires
    `is_inside_tree()`, and `get_root().add_child(x)` inside a
    `SceneTree`-extending `--script`'s own `_initialize()` does NOT make
    that true until the next `await process_frame`** — unlike `add_child()`
    during normal gameplay, which takes effect synchronously. `tests/
    README.md`'s existing "await process_frame after add_child(main)"
    safety note already covered `main.tscn` specifically; this generalizes
    it — found while writing `tests/section_tool.gd`'s own plain-`Node3D`
    hand stand-ins, confirmed with a minimal repro.
  - **`RenderingServer.global_shader_parameter_add()` is process-wide, not
    per-instance** — re-adding an already-registered name is a real engine
    ERROR (`Condition "global_shader_variables.has(p_name)" is true`), not a
    no-op. Guarded with a `static var` (shared by every `SectionTool`
    instance in the process), not a plain instance `var` — the instance-var
    version only breaks once more than one instance exists in the same
    process, i.e. this project's own tests, never the real app.
  - **`Basis` has no `affine_inverse()`** (that's a `Transform3D` method;
    `Basis` only has `inverse()`) — caught at parse-check time, before it
    ever ran, and turned out to be unnecessary anyway: the arrow's own local
    offset is always exactly local ±Z (Flip just picks the sign), a
    constant, needing no inverse-transform at all.
  - **`command_stack.gd extends RefCounted`, and calling `.free()` on a
    `RefCounted` is a real script error** (it frees itself when
    unreferenced) — caught because that error, thrown during test cleanup
    *after* every assertion had already printed, was silently swallowing
    the test's own `quit()` call, which looked exactly like a hang
    (`run_all.sh`'s 300s timeout, not a crash) until traced back to it.
  - **Adding an 8th wrist-tablet tab (`plain HBoxContainer`, `SIZE_EXPAND_
    FILL` buttons) overflowed the tablet's fixed 640px-wide viewport** —
    HBoxContainer doesn't wrap, and `SIZE_EXPAND_FILL` can't shrink a button
    below its own text-driven minimum width, so the tab row's total minimum
    width silently exceeded the panel once "Sections" (the longest label)
    was added, pushing every control below it (including the *unrelated*
    Modes tab's own Steadiness row) far enough off to break `tests/
    tablet_scene.gd`'s existing click-position math for a button that
    hadn't itself changed at all. Fixed by switching the tab row to
    `HFlowContainer` (already this file's own precedent for the Scale tab's
    presets and the Colours tab's swatch grid) so it wraps to a second row
    instead of overflowing — dropped `SIZE_EXPAND_FILL` from the tab
    buttons too, matching how those other two rows never set it either.
    Caught because a *pre-existing, already-passing* headless test broke on
    a change to an apparently unrelated tab — a real lesson for the next
    tool added here: always re-run the full suite, not just new tests.
- Tests: `tests/section_tool.gd` (pure logic — grab/drag/release/undo math,
  and the wrap/unwrap material bookkeeping including the colour_tool-changed-
  it-while-active case, against `MeshInstance3D`/`BoxMesh` stand-ins, no
  network, no rendering), `tests/section_tab.gd` (full-scene: `main.tscn`
  with no backend, drives the real Sections tab and simulates a real grip
  press via `button_pressed`/`button_released` signal emission — same
  precedent `tools_tab.gd`/`tablet_scene.gd` already use for "a real grip
  can't be faked headless"), and `tests/section_render.gd` (**needs a real
  render, not `--headless`** — same class of exception as `gpu_timing.gd`,
  but this cloud sandbox has no GPU/display at all, so Xvfb + Mesa's
  llvmpipe software rendering stood in for both, confirmed working this
  session specifically for this: `xvfb-run -a "$GODOT" --path . --script
  res://tests/section_render.gd`). The real-render test is the one thing
  the pure-logic test structurally can't check — that the shader actually
  **discards** fragments on the excluded side rather than fading them, and
  that Flip genuinely swaps which side survives — confirmed true on the
  first working version (after fixing the lighting: the shader's own
  `metallic=1.0`/`roughness=1.0` renders visibly dark under flat ambient
  light alone with no directional light, which isn't a bug, just a mismatch
  between the spike's original unshaded throwaway test material and the
  real shader's PBR one).
- **Confirmed for real, end to end, against a real backend**
  (`tests/e2e_section.gd`, same "run manually" exception as the other
  `e2e_*.gd` tests): stood up a throwaway backend (micromamba `didsacad`
  env, throwaway `CAD_API_KEY`), let `main.tscn` import and load this
  repo's own tracked `assembly.didsa` for real (3 parts), then drove
  `section_tool.gd`'s real wrap/grab/unwrap pipeline against those real
  glTF-imported parts and their real backend-baked materials — not the
  synthetic `BoxMesh` stand-ins the other tests use. Every real part's own
  real albedo survived being wrapped and unwrapped exactly; a real grip
  grab/drag against the real scene worked; turning the tool off restored
  every part's material_override to exactly what it was before (genuinely
  absent, not a placeholder). This is the same "don't just trust synthetic
  geometry" precedent the BoxMesh-winding gotcha established earlier in this
  milestone, applied to materials/rendering instead of collision geometry.
- **Not yet headset-verified** — like the rest of milestone 4, only run
  headless, against a real backend, and (for the shader specifically)
  against a real software-rendered image from a cloud sandbox; never with a
  real hand pulling a real trigger or grip, and never seen through a real
  headset's own eyes. In particular: whether grabbing a thin translucent
  disc feels natural at all with a real hand (versus a part, which has real
  volume to reach into); whether the default spawn position/size reads
  clearly on first toggle; and whether the clip itself, correct in a flat
  render, looks right in stereo/at real depth.

### Measurements: the last milestone-4 tool - a thin client to DIDSA-CAD's real, stateless Measure endpoint

Closes milestone 4. Read `backend/app/document/measure.py`/`schemas.py`
directly (in the `DIDSA-CAD` repo) first: `POST /parts/{part_id}/measure`
already existed (the same endpoint the flat app's own
`measurement_panel.dart` uses) and needed no backend changes at all - every
piece the VR client needed (a `MeasureEntityRefSchema{occurrence_id,
subshape_ref}` per pick, root content allowed via `occurrence_id: ""`) was
already there, and this client's own `mesh_identity.gd` already produces
exactly that shape from a raycast hit (built for Mates, reused verbatim
here).

**`scripts/measure_tool.gd`** (new): laser-pick 1-2 entities, live result -
no create/persist step at all (`measure.py`'s own docstring: "never a
Feature, never mutates Part, no undo/redo entry"), so picking the first
entity queries and shows a single-entity result immediately, picking a
second re-queries for the two-entity relationship. Deliberately **looser**
validation than Mates: a Measure entity can be the currently-open Part's
own root content, and both picks can land on the same Occurrence or root
content - measuring across two features of one part (a hole's spacing, a
wall's thickness) is the common case, not Mates' "two different parts"
requirement. A third pick starts a fresh measurement rather than being
ignored once full (Mates' own cap-at-2 behaviour) - Measure is for picking
through several things in a row.

**A real overlapping-request race, found by an e2e run against a real
backend, not by reasoning about the code**: the first design gated
`try_pick()` on `is_busy()`, so a real second pick thrown quickly - before
the first pick's own network round trip had returned - was silently
dropped waiting on a request that hadn't finished yet. `tests/e2e_measure.gd`
caught this directly: the two-entity case never even fired, `status_text()`
still asked for "a second entity" after both picks. Fixed with a monotonic
`_measure_token` instead of a hard gate: every pick always fires its own
`_run_measure()` call immediately (never dropped), and a request that
comes back after a *newer* pick has already superseded it (token mismatch)
discards its own now-stale result instead of clobbering the current one -
`clear_picks()` also bumps the token, so an old in-flight request can't
land after an explicit Clear either. Re-ran the same e2e test afterward:
real distance (83.34 mm), real delta, and real per-body volumes came back
for a genuine two-pick sequence.

**Wrist tablet**: new "Measure" tab (`wrist_tablet.gd`) - a tool toggle,
status/picked-entities labels, a live result list, and Clear. Result row
order/labels/formatting deliberately match the flat app's own
`MeasurementPanel._resultRows` exactly (Length, Diameter, Radius, Area,
Point, Axis distance, Normal distance, Distance, Delta, then per-body
Volume/Mass) so a user moving between VR and flat sees the same numbers
laid out the same way, not a VR-specific reinterpretation.

**Tests**: `tests/measure_tool.gd` (new, added to `run_all.sh`) - pure
pick-validation logic against manually-tagged stand-ins, 14/14 boolean
lines `true`, including the looser-than-Mates cases (root content and
same-occurrence picks both accepted) and confirming a failed/no-backend
measure attempt still leaves `is_busy()` correctly `false` rather than
stuck. `tests/e2e_measure.gd` (new, needs a real backend, not run by
`run_all.sh`, same class of exception as `e2e_mates.gd`) - real single- and
two-entity measurements against `assembly.didsa`'s own two placed
occurrences, **SMOKE PASSED** after the race-condition fix above. Full
headless suite (`run_all.sh`) re-run clean after the fix: **ALL RAN WITHOUT
SCRIPT ERRORS**, no regressions.

**Not yet headset-verified** - like the rest of milestone 4, only run
headless and against a real backend: whether the result list reads clearly
at wrist-tablet size with several rows populated at once, and whether
picking two faces in quick succession (the exact race the token fix
handles server-side) feels right from a real hand, not just correct over
the wire.

## Real-headset testing round: three bugs found and fixed

The first real hand pulling a real trigger at any of this project's UI
(the wrist tablet, popup keyboard) or at a part with the left hand,
on a build predating this session. Three issues came back; all three are
fixed and covered by a new headless test each (none needed a real headset
to verify the fix, since each has a specific, reproducible mechanism —
see each test's own docstring for exactly what it simulates and why).

- **Tablet/keyboard buttons: hover worked, activating never did.** Root
  cause, found by reproducing the exact mechanism headless rather than
  guessing: `wrist_tablet.gd`/`popup_keyboard.gd`'s own `_update_pointer()`
  kept tracking the live laser aim every frame, including *while a trigger
  press was being held* — a real trigger squeeze takes real time (order of
  100–300 ms), during which even a "steady" real hand drifts enough to push
  at least one `MouseMotion` event outside the pressed button's own rect.
  Godot's own `BaseButton` cancels a press the instant that happens
  (`pressing_inside`, tracked continuously, checked again only at release)
  — regardless of what position the eventual mouse-up event itself carries,
  which is why an earlier, incomplete fix (freezing only the up-event's own
  position) still failed. The real fix: freeze the pointer entirely (no new
  motion events at all) for the whole duration of a held press, only
  resuming live tracking once released. Invisible to every existing
  headless test because a synthetic `button_pressed.emit()`/
  `button_released.emit()` pair fires both ends in the same, unmoving
  simulated position — `tests/tablet_scene.gd`/`tests/popup_keyboard.gd` each
  gained a new drift-mid-press check that moves the simulated controller
  between press and release specifically to reproduce this.
- **The laser now shortens to whatever it's actually hitting.** Previously
  fixed-length regardless of what was in the way (`controller.gd`'s
  `laser_length`, "doesn't retarget to hit point" — the very first version
  of that comment turned out to describe exactly the bug John hit: aiming at
  the wrist tablet, the laser visibly passed straight through it instead of
  stopping there). Fixed with a `CylinderMesh` whose height/position now
  update every physics frame (`_update_laser_visual()`): a UI panel (wrist
  tablet/popup keyboard, reported via a new `ui_hit_distance` meta —
  same convention `ui_hover` already used) takes priority over a plain part
  hit, which takes priority over the default full length. Also gave the
  tablet/keyboard's own cursor dot a soft multi-ring glow (was a flat 8px
  circle) so the termination point actually reads as one at arm's length.
  `tests/laser_and_left_hand.gd` confirms full length with nothing hit,
  shortening to a real part and to the tablet, and returning to full length
  once clear of either.
- **Left-hand laser-select blocked left-hand walking.** `locomotion.gd`
  backs off a hand's own thumbstick while that controller reports
  `is_manipulating()` (i.e. has a `selected_node`) — so laser-selecting a
  part with the left hand silently disabled the left thumbstick's own
  walk/strafe for as long as it stayed selected, with no visual indication
  why. Per John's own call: left grip-grab is untouched (it "feels right"
  two-handed) and stays available on both hands; only left-hand laser-select
  (and the A/B/X/Y nudge + thumbstick rotate that ride on `selected_node`,
  which now simply never gets set there) is gone, via a new
  `laser_select_enabled` flag on `controller.gd` (hand-agnostic script,
  default `true`, set `false` for the left controller only in `main.gd`) —
  freeing the left trigger for a later tool (context menu, multi-select —
  not decided yet). The right hand is completely unaffected.
  `tests/laser_and_left_hand.gd` also confirms: left trigger no longer
  selects; left grip still grabs exactly as before; `is_manipulating()`
  stays false on the left hand; the right hand still selects normally.

Also removed per the same real-headset feedback: the floating `Label3D`
status text that used to hover in front of the user ("Loaded 3 part
mesh(es)...") — distracting, not requested by the vision brief. `main.gd`'s
own status reporting is now console-print-only (`status_text`, a plain
`String` property `tests/e2e_*.gd` still poll to know when a load finished,
no 3D node needed for that).

## Real-headset testing round 2: four bugs found; three fixed, one (mates) deferred as a real data/architecture gap

A second real-hand round, after round 1's tablet/keyboard/laser fixes above.
Four issues came back. Three are concrete, root-caused client bugs, now
fixed and covered by new headless tests. The fourth (mates) is not fixable
client-side at all — a genuine data-model/architecture gap, deferred to the
roadmap per John's own call rather than worked around.

### Colours: error message flashed and vanished; root cause was a genuine data-model gap, not a material clash

The error text was visible for at most ~0.25s: `wrist_tablet.gd`'s
`_process()` refreshed `_colour_status_label.text` unconditionally on its
periodic 0.25s tick, clobbering whatever `_apply_colour()` had just written.
Fixed with a hold window (`_colour_message_hold_until_ms`,
`_show_colour_message()`) — an error (or any status message) now survives at
least `_show_colour_message()`'s own default 3s before the periodic refresh
is allowed to overwrite it again. Confirmed headless:
`tests/tablet_scene.gd`'s new block clicks "Clear colour" with nothing
selected, confirms the message survives one refresh tick, then confirms it
reverts once the hold expires (using a directly-injected message to avoid a
coincidental identical-text false pass — see that test's own comment).

The failure itself, confirmed directly by John: he was trying to colour a
single mesh body — the only thing his raycast pick could resolve to in that
test data. `colour_tool.gd::set_color()` correctly rejects any pick with no
owning Occurrence ("root content" in the backend's own terms) with a real,
working guard, not a bug — traced the suspected material-override clash
with `section_tool.gd`'s wrap/unwrap pipeline and confirmed it already
preserves colour correctly through both directions (already covered by
`tests/section_tool.gd`'s own passing assertions), ruling that out as the
cause.

**Colouring hierarchy, designed and partially built this round** (grounded
in the real backend model — read `backend/app/document/router.py`/
`models.py` directly, not assumed): there's no distinct "Assembly" entity in
the backend at all — an assembly *is* a Part with Occurrences, and a
"sub-assembly" is just an Occurrence whose own Part has further Occurrences.
**Colour lives only on `Occurrence.color`** — one field, one endpoint
(`PATCH /parts/{owner_part_id}/occurrences/{occurrence_id}`) — so
assy/sub-assy/part-level colouring all reduce to the exact same mechanism,
just a different *scope* of occurrences to apply it to:

- **One Occurrence** (Part level) — already worked, unchanged.
- **Every Occurrence sharing an immediate owner** (sub-assembly/pattern
  level) — new this round: `colour_tool.gd::set_group_color()` fetches the
  real, confirmed `GET /parts/{id}/occurrences` (`router.py`'s
  `list_occurrences`) and loops the same PATCH over every sibling — same
  "loop the per-occurrence endpoint, there's no bulk one" shape
  `mates_tool.gd::enforce_all()` already uses. Exposed on the wrist tablet
  as a new "Apply to whole group" toggle on the Colours tab, read by every
  swatch/custom-hex/clear action.
- **Mesh body** — genuinely has no backend field at all; colour was never
  wired below Occurrence. Not client-fixable without new backend
  schema/endpoint work — flagged, not built.
- **Face** — the backend's `SubShapeType` enum has it for mates/measure, but
  it was never wired to colour either. Noted, not built.
- The bigger interaction John sketched (a floating tree window listing
  assy/sub-assy/part with breadcrumbs, an alternate "give me context, not
  just the raycast hit" pick gesture) is explicitly deferred to a future
  "flat windows" milestone, per his own call — no tree UI this round.

Root content (no Occurrence at all — the pick this bug report actually hit)
now gets a clearer message naming the real limit
(`colour_tool.gd`'s `_ROOT_CONTENT_ERROR`: "nothing here has a colour
override in the backend's data model") instead of the old, bug-report-
sounding generic rejection. **Important honesty note, unchanged from the
plan**: if a loaded file genuinely has zero real Occurrences anywhere (a
single multi-body Part with no placed structure at all — plausibly exactly
John's test file), no client-side control can find a colourable target in
it; that's the same root data gap as the mates issue below, not something
this round's "Apply to whole group" toggle can paper over.

Tests: `tests/colour_tool.gd` gained coverage for the clearer root-content
message and `set_group_color()`'s filtering logic
(`_apply_local_color_to_group()`, pure/no-network) against manually-tagged
stand-ins, same convention the file already used.

The one-off "couldn't get off the colour tool" didn't recur and matches the
class of intermittent click failure round 1 already fixed (drift-mid-press)
— no separate mechanism found, no action taken.

### Tablet dynamic highlight: toggle buttons never had a pressed/hover style

Every toggle button in the tablet (Modes' three, Sections' own
Section-tool/Flip, Mates' Flip/Relax, the tab row, steadiness/scale choice
rows) was relying entirely on Godot's built-in default theme fallback for
any pressed/unpressed visual difference — `_build_ui()`'s own `Theme.new()`
only ever set `default_font_size`; no stylebox was defined for any button
state anywhere in this file (the Colours tab's per-swatch `"normal"`
override is unrelated — that's each swatch's own fixed colour, not a
pressed-state indicator). That fallback wasn't reading clearly at arm's
length on an unshaded SubViewport quad. Fixed with one theme-wide
`pressed`/`hover_pressed` `StyleBoxFlat` override in `_build_ui()` — lights
up every toggle button in the tablet at once, no per-button changes needed.
Confirmed headless: `tests/tablet_scene.gd`'s new check reads a just-toggled
Modes button's own `pressed` stylebox via the theme and confirms it's a
real, distinct `StyleBoxFlat` (not null, not identical to `normal`).

### Section tool: gripping the gizmo also dragged the whole world; visual redesign

Root cause, confirmed by reading both files: `two_hand_model.gd::
_hand_free()` only ever checked `controller.gd`'s own `held_node` (a
*part*) to decide whether a hand was free to drag the whole model — it had
no idea `section_tool.gd` existed. The gizmo deliberately never sets
`held_node` (it isn't a `grabbable_parts` member — see that script's own
docstring), so grabbing it left `_hand_free()` believing the hand was still
free, and the same grip press dragged the whole model underneath it at the
same time. Fixed with the same meta-based convention already established
for `ui_hover`/`ui_hit_distance`: `section_tool.gd`'s `try_grab()`/
`release()` set/clear a new `section_gizmo_held` meta on the grabbing hand;
`two_hand_model.gd::_hand_free()` checks it before falling through to the
`held_node` check. Also fixed a related bug caught while re-reading the new
code, not from testing: deactivating the Sections tool *while still
gripping the gizmo* (never calling `release()`) used to leave that hand's
meta stuck `true` forever, permanently locking it out of whole-model
dragging — `set_active()`'s deactivate branch now clears the meta explicitly
if a grab is in progress.

Confirmed headless: `tests/section_tool.gd` gained direct assertions that
grab/release set and clear the meta, and that deactivating mid-grab also
clears it. **The live `two_hand_model.gd` interaction itself
(`_hand_free()`'s real behaviour while gated on
`hand.is_button_pressed(grab_action)`) can't be verified headless at all** —
Godot's `is_button_pressed()` reads real XR runtime state with no way to
inject a fake press (confirmed by trying: a script override of a native
`XRController3D` method is a hard parse error in this project's
strict-warnings build, not a silent no-op), so this specific interaction —
like the rest of this project's real-device-input logic — needs John's own
confirmation over PCVR. The meta set/clear correctness above is the closest
thing to verifiable proxy coverage.

Visual redesign, per John's own spec: disc → `BoxMesh` rectangle (was
`CylinderMesh`); arrow → a 4-`radial_segments` `CylinderMesh` cone (a
square-based pyramid) with `top_radius=0`; added a thin `CylinderMesh`
"tail" spanning from the plane's own surface out to the arrowhead's base so
the indicator reads as one continuous pin rather than a floating shape.
`_update_global_plane()`'s existing Flip-driven arrow repositioning got a
matching tail length/position update. Confirmed headless that nothing about
`tests/section_render.gd`'s real-render clip-shader checks regressed (Xvfb +
Mesa llvmpipe) — the geometry change doesn't touch the shader, but this
re-confirms rendering still works end to end with the new meshes. **Not
confirmed on a real headset** — the shape itself, like every other visual
change in this project, needs John's own look.

### Mates: blocked on a multi-body test file and no in-VR "open a different file" path — DEFERRED to the roadmap

Not a client bug, confirmed by reading both the backend model and this
client's own picking code:

1. **The test assembly's two visually-distinct chunks are two Bodies of one
   Part's own root content, not two placed Occurrences.** A Mate references
   two *Occurrences* — both in the backend's data model and in
   `mates_tool.gd`'s own validation (`_validate_pick()` rejects root
   content, and rejects the same occurrence picked twice). If a file's
   "parts" are really just multiple Bodies inside one Part with no
   Occurrence structure, there is nothing to mate — by the backend's own
   Mate semantics, not a gap in this client's picking.
2. **There's no in-VR way to open a different native file at runtime**, and
   no way to add parts to the currently-loaded assembly. `main.gd`'s native
   import runs once at `_ready()` against a hardcoded path; the Files tab
   only ever loads bare `.glb`/`.gltf` or goes through `import-features` for
   STEP/STL/OBJ, never a native assembly through `/import/native`. That
   endpoint is also a full-replace import (see
   `docs/backend-api-notes.md`), not additive — "add parts to the current
   assembly" needs real backend multi-file composition work, which the
   vision brief already flags as an unbuilt roadmap item ("Multi-file
   assembly composition: Port to Python").

**Per John's own call: deferred entirely, no code this round.** Blocking
mates testing until a real multi-Occurrence test assembly (or the
open/add-parts pathway) exists — tracked here so it's picked up as scoped
work after Milestone 4's measurements land, not re-diagnosed from scratch.

## Open/add-parts pathway built: the mates blocker's second half closed

Picked up the deferred item directly above. Blocker #2 (no in-VR way to
open a different native file, or add parts to the loaded assembly) is now
closed; blocker #1 (the tracked test assembly having no real Occurrences)
is a direct *consequence* of #2 having been missing — with a real add path
in hand, building a genuine multi-Occurrence test assembly no longer needs
anything outside this client (see below), so both close together.

**Backend**: `POST /parts/{root_part_id}/add-component`
(`backend/app/document/add_component.py`+`router.py` in DIDSA-CAD) — a
direct port of the Flutter client's own `add_component.dart::
mergeComponentIntoDocument`, merging another native file's own
already-exported payload into the *live session's* Document as a new
Occurrence, without discarding the rest of the session the way
`/import/native` (full replace) does. Deliberately narrow: it never touches
a filesystem itself (the caller — this client — already read the file off
disk), so it does **not** implement the bigger, still-unscoped "shared
network storage + server-side composition" item in DIDSA-CAD's
`docs/roadmap.md`; see `docs/backend-api-notes.md`'s own new section for
the exact line between what this closes and what it doesn't. Backend tests:
`backend/tests/test_add_component.py`, 6 new cases (first Occurrence gets
`fixed=true`, a second one doesn't, dedup by persisted Part id, an
unrelated session Part survives untouched — the actual full-replace-vs-
merge distinction that matters here, self-reference/unknown-root-part/
empty-file rejections) — **6/6 passed** against a real pythonocc-core
sandbox.

**Client**: two new entry points on `main.gd`, both wired into the wrist
tablet's Files tab (`wrist_tablet.gd::_rebuild_files()`):
- **`open_native_file(path)`** — the first half: a full-replace open of an
  *arbitrary* native `.didsa`/`.DIDSAprt` file at runtime (not just the one
  `native_file_path` the scene started with), mirroring `_begin_import()`'s
  own startup flow. Every file the Files tab lists now includes `.didsa`/
  `.DIDSAprt` (`list_model_files()`'s extension list grew accordingly), and
  tapping one's row button routes here via `load_model_file()`'s dispatcher
  (same tap-to-load convention `.glb`/STEP/STL/OBJ rows already use).
- **`add_component_file(path)`** — the second half: reads a local native
  file the same way, then calls the new backend endpoint against whichever
  Part is currently loaded (`current_root_part_id()`), and re-fetches
  `assembly-mesh.glb` to render the result — never discards the loaded
  scene's undo history, selection, etc. the way a full reopen would (though
  in practice `_show_model()` still rebuilds the whole scene graph to draw
  the new Occurrence, so `command_stack`/picks are still cleared, same as
  any other reload). Shown as a second, small "Add" button next to a
  native file's row — only once something backend-hosted is already loaded
  (`current_root_part_id()` non-empty), since there's nothing to add an
  Occurrence *onto* otherwise. `_import_external_file()` (the existing
  STEP/STL/OBJ path) now also sets `_resolved_part_id` after creating its
  fresh Part, so a part brought in that way can be added onto too, not just
  a native-opened one.

**What this actually unblocks for Mates**: John (or anyone) can now, from
inside VR alone — no editor, no Flutter app, no manually-crafted fixture —
open any single-Part file and then **Add** a second file onto it (even the
same file twice) to get a real, backend-persisted Occurrence pair, exactly
the multi-Occurrence structure the Mates tab's own picking validation
requires (`mates_tool.gd::_validate_pick()` rejects root content — see
"Real-headset testing round 2" above). The tracked `assembly.didsa`'s own
history already proves the Mates *code path* itself works end-to-end
(`tests/e2e_mates.gd`'s docstring: "Requires assembly.didsa to have at
least 2 top-level occurrences — the tracked fixture did" at the time it
was written) — what was missing was ever getting back to that state from
inside VR once the real on-device test file turned out to be occurrence-
less. This closes that gap without needing the network-storage/server-
side-composition project at all.

**Verification**: `backend/tests/test_add_component.py` — 6/6 passed
(real pythonocc-core sandbox), full backend suite re-run clean, no
regressions: **2517 passed**. Client-side, this session downloaded its own
headless Godot 4.7.2 Linux build and stood up the backend locally with
micromamba (same recipe "How this has been worked on" below documents),
so this could actually be run rather than left as untested code:

- **`tests/e2e_add_component.gd`** (needs a real running backend, same
  class of exception as `e2e_mates.gd`/`e2e_step_import.gd` — not run by
  `run_all.sh`): creates two bare geometry-free Parts directly against the
  backend, opens one via `open_native_file()`, adds the other via
  `add_component_file()`, then confirms via a fresh `GET .../occurrences`
  that the Occurrence genuinely persisted server-side, resolved to the
  right Part, and is `fixed`. **SMOKE PASSED**, real backend, first run
  after one real bug fix (below).
- **A real bug this run caught, that pure code review missed**: `wrist_
  tablet.gd`'s new `_rebuild_files()` line (`var assembly_loaded := not
  _main.current_root_part_id().is_empty()`) failed static type inference —
  `--check-only` on the script reported "Cannot infer the type of
  'assembly_loaded' variable" — which made the *whole script* fail to
  compile, so `main.gd`'s `_tablet` stayed `null` and every `_process()`
  tick threw "Nonexistent function 'is_open' in base 'Nil'". Silent at
  a glance (no crash, no visible error in a screenshot), but it broke the
  wrist tablet entirely and would have hung/stalled on a real headset,
  not just in the test harness that happened to surface it (`tests/
  tablet_scene.gd`, run standalone, showed the exact same spam and a
  wrong file-listing result). Fixed with an explicit `: bool` annotation.
  This is exactly the class of bug `tests/README.md`'s own "what headless
  can't do" caveat doesn't cover — it's not a feel/interaction question,
  it's a plain compile error that only surfaces by actually invoking Godot
  against the changed files, which is why this session did that rather
  than stopping at code review.
- **`tests/run_all.sh` (the full headless suite, all 15 tests + the parse
  check), re-run clean after that fix: `ALL RAN WITHOUT SCRIPT ERRORS`**,
  every SMOKE line matching this doc's own documented expected values
  (`tablet_scene.gd`'s Files-tab lines included) — confirmed no other
  regression from this session's `main.gd`/`wrist_tablet.gd` changes.

Genuinely still unconfirmed on a real headset, same as everything else in
this project not explicitly marked otherwise: whether the new "Add" button
reads clearly at wrist-tablet size, and whether re-adding a component while
the tablet is mid-interaction feels right.

## Milestone 3 — floating windows: Assembly Tree, Calculator, Image Viewer, Browser (and PDF) built

The vision brief's milestone 3 named five things: calculator, browser, PDF
reader, image viewer, and DIDSA-CAD itself, all as flat panels floating in
the arena. Two rounds of exploration before building anything turned up a
real split in risk: three of the five are buildable now, on existing
patterns, with no new dependency. The other two need something this repo
(and, for DIDSA-CAD-as-a-window, the DIDSA-CAD repo) doesn't have at all —
forcing all five into one phase would have blocked the high-value, low-risk
item (the assembly tree) on unscoped native-dependency research. This phase
ships the three; the other two are called out below as separate, unstarted
spikes, not silently dropped.

**Framework (`scripts/diegetic_panel.gd`).** `popup_keyboard.gd` was
already a complete template for a free-floating (not wrist-mounted),
laser-interactive panel: a `SubViewport`+quad, hand-built plane-raycast hit
testing against the right hand's laser, synthetic mouse events, and the
frozen-press-position fix for the real-headset drift-during-a-squeeze bug
(see the "Real-headset testing round" section above). This extracts that
mechanism into a reusable base so a new window doesn't have to duplicate it
from scratch — deliberately **not** retrofitted onto `wrist_tablet.gd`/
`popup_keyboard.gd` themselves: both are proven, headset-tested files, and
this session had no Godot available to verify a refactor of them hadn't
changed behaviour, so they're left exactly as they were.

Multiple windows being open at once raised a real question `wrist_tablet.gd`/
`popup_keyboard.gd` never had to answer: which one does the trigger belong
to if two are both being aimed at? The first design ("claim the shared
`ui_hover` meta if you're nearer than whoever already claimed it this
frame") turned out to have a real bug, caught by `tests/windows_tab.gd`
trying to assert it: an earlier-processed panel that had already set its
own `_hovering = true` was never told it got outbid later in the same
frame by a nearer panel stealing the meta, so both could end up believing a
single trigger pull was theirs. Fixed by simplifying to first-claim-per-
frame (whoever's `_process()` runs first and is genuinely hit, wins, full
stop — not the true geometric nearest, but provably exactly one winner).
Correctness mattered more than optimality here, and normal use doesn't
overlap panels anyway (each window's own `open_distance`/
`open_lateral_offset` keeps them apart) — see `diegetic_panel.gd`'s own
docstring for the full story. A new, small, additive change to
`controller.gd` (a `_process()` resetting the shared meta to neutral at the
very start of every frame, before any panel gets a turn) is what makes this
work at all — `XROrigin3D` is always `main.gd`'s first child, so this
always runs first.

**Assembly Tree** (`scripts/assembly_tree_window.gd`) — the vision brief's
own "interactive tree" from its Assembly tools list, named there since the
very first version of the brief and never built until now. Lazily recurses
`GET /parts/{id}/occurrences` from the loaded assembly's root, expanding a
row's own children only when tapped — the same real endpoint
`colour_tool.gd`'s "whole group" colouring already proved (see
`docs/backend-api-notes.md`'s new "Listing an Occurrence's direct children"
section), chosen over an eager `GET .../assembly-mesh` JSON fetch
specifically so opening the tree doesn't tax every model load, only the
ones where it's actually used (that endpoint measured ~460 KB on DIDSA-CAD's
own test assembly, per the vision brief — not a cost to add to every
startup for a window that might not even be opened). Tapping a row selects
the matching part the same way laser-select does — `main.gd`'s new
`select_part_by_occurrence_id()` walks the loaded, `mesh_identity.gd`-tagged
parts for a matching `occurrence_id` and calls `controller.gd`'s new
`select_external()`, a thin public wrapper around the same private
`_set_selection()`/`_clear_selection()` laser-select already uses (same
`command_stack` bookkeeping, same toggle-to-deselect behaviour). An
intermediate row (a sub-assembly with its own children) has no rendered
geometry of its own to select at all — `assembly-mesh.glb` is one node per
placed *leaf* instance only, per `mesh_identity.gd`'s own docstring — so
tapping one shows a status message rather than silently doing nothing.
`main.gd::_show_model()` calls the tree's `mark_stale()` alongside its
existing `command_stack.clear()`/`_mates_tool.clear_picks()` reset, so the
tree rebuilds whenever a new file is opened or a component added.

**v1 scope, on purpose**: browse and tap-to-select only. "Pull a tree node
into world space" (the vision brief's own literal wording) is real further
scope — duplicating geometry, or breaking a mate server-side, either one a
design question worth its own pass — and isn't attempted here.

**Calculator** (`scripts/calculator_window.gd`) and **Image Viewer**
(`scripts/image_viewer_window.gd`) round out this phase's realistic scope.
Calculator was deliberately built first and simplest, specifically to prove
several `diegetic_panel.gd` windows can be open and independently
interactive at once before trusting the arbitration fix with the tree
window (the real deliverable). Image Viewer sources from the same
`models/`/`user://models` folders and git-ignored-local-asset convention
the Files tab already uses for `.glb` files, just filtered to image
extensions; v1 is deliberately just "load and look at it," no pan/zoom.

New wrist-tablet **Windows** tab, one toggle button per window (a plain
button, not `toggle_mode`, since a window can also be closed by its own
"X" — see `wrist_tablet.gd`'s own `_window_toggle_button()` docstring for
why keeping a separate toggle-button state in sync wasn't worth it).

**Explicitly not attempted this phase** (separate, unstarted spike):

- **DIDSA-CAD as a flat window** — blocked on DIDSA-CAD's own Flutter
  client gaining a web build target (`flutter create --platforms=web` —
  doesn't exist today, confirmed: no `web/` folder in that repo) and
  validating `flutter_gpu`'s web support, an open, unvalidated risk per
  that repo's own recon docs (`docs/vr-recon-2026-09-24.md`/
  `-2-2026-09-24.md`). This is a DIDSA-CAD-repo spike, not a DIDSA-VR task.
  (Browser and PDF reader, originally alongside this in the "not attempted"
  list, are now built — see "Browser window and browser-relay" below.)

**Update, same session: Godot 4.7.2 obtained and the full suite actually
run.** The initial claim above ("no Godot available, only inspected") held
for the first pass — `apt` only has `godot3-server`, incompatible with this
Godot-4 project, and the obvious release-download hosts
(`downloads.tuxfamily.org`, `godotengine.org`) are both blocked by this
sandbox's network policy. `github.com`'s own release-asset redirect
(`objects.githubusercontent.com`/`release-assets.githubusercontent.com`)
was not blocked, though, and `project.godot`'s `config/features` names the
exact version this project actually targets (`"4.7"`, not assumed) — Godot
4.7.2-stable downloaded from there and `tests/run_all.sh` genuinely run
against it caught two real bugs neither inspection nor Godot 4.2.2
(tried first, wrong minor version, masked one of them entirely) surfaced:

- **A real production bug in `controller.gd`.** The per-frame `ui_hover`/
  `ui_hit_distance` reset (added for the arbitration fix above) assumed
  being `main.gd`'s first child meant it always ran before every panel's
  own `_process()` — wrong: `wrist_tablet.gd` is three levels deep
  (parented under the LEFT controller, not a sibling of the right one),
  and in practice sometimes ran first instead, silently wiping out a hover
  it had just legitimately claimed. `tests/laser_and_left_hand.gd` (pre-
  existing, not written this session) caught it — its own "shortens to the
  tablet via ui_hit_distance" line came back `false`, a genuine regression
  confirmed by disabling the new reset and re-running (passed) before
  re-enabling it with the real fix: `process_priority = -1000` on
  `controller.gd`, Godot's own explicit ordering mechanism, not tree
  position.
- **A real bug in the Calculator itself.** Godot's `Expression` class does
  true integer division for two integer literals, exactly like GDScript's
  own `/` operator — `"10/4"` evaluated to `2`, not `2.5`. Not a cosmetic
  formatting issue: a user typing that on the in-VR calculator would get a
  silently wrong answer. Fixed with `_floatify()` in
  `calculator_window.gd`, appending `.0` to every bare integer literal
  before parsing.

Two more bugs turned out to be in this session's own *test* code, not the
shipped app: `tests/windows_tab.gd`'s first draft aimed at the wrist tablet
with `look_at()`, degenerate for a panel that lies flat (its quad faces
straight up) — fixed by porting `tests/section_tab.gd`'s own proven fixed-
orientation aim; and it opened the tablet directly via `open_tablet()`
without also waiting out `open_settle_seconds` (0.4s, real wall-clock time,
ignores an immediate press) the way every other full-scene test already
does, silently swallowing its very first click.

`tests/run_all.sh` now passes clean end to end (exit 0, every SMOKE line
matching this doc's and `tests/README.md`'s own documented expected
values). **Still open**: `tests/e2e_assembly_tree.gd` (needs a real running
backend — none in this sandbox) and, same as every other milestone in this
project, a real headset pass.

### Browser window and browser-relay: the deferred Browser/PDF reader built, differently than originally scoped

After the sections above shipped, John asked to progress this milestone
further and reframed the deferred Browser item: "if DIDSA-CAD can run in a
floating window, can any app? E.g. a lightweight browser?" — a real
question, since DIDSA-CAD-as-a-window (see above) is itself just "run
some other real app and show it in a Godot panel." Checked directly rather
than assumed: `gdcef` (the one Godot-CEF GDExtension found) publishes
Linux/Windows/macOS builds only, no Android — so native in-Godot CEF
embedding was ruled out for Quest specifically, for real, not on
suspicion. A `neko`-style WebRTC remote-desktop server was considered and
rejected too: real and Docker-deployable, but it needs "a full WebRTC
browser client" on the viewing end, reintroducing the same native-webview
dependency problem one level removed.

**What got built instead: a generalized "any web content as a floating
window" mechanism**, specifically the Chrome DevTools Protocol (CDP) over
a plain authenticated WebSocket, needing only Godot's own core APIs
(`WebSocketPeer`, `Image.load_jpg_from_buffer()`) — no GDExtension, no
native dependency, works identically on Android. Two new pieces:

- **`browser-relay/` (DIDSA-CAD repo, new)** — a small FastAPI service,
  deliberately a "dumb relay": it authenticates a WebSocket
  (`X-API-Key`/`BROWSER_RELAY_API_KEY`, its own separate key from the CAD
  backend's — see `browser-relay/app/auth.py`'s docstring for why), asks a
  single shared headless-Chromium process it manages for a fresh tab (up
  to `BROWSER_RELAY_MAX_SESSIONS`, default 2), and then copies raw
  WebSocket frames verbatim between the client and that tab's own CDP
  WebSocket until either side disconnects. It has no idea what
  `Page.navigate` or `Input.dispatchMouseEvent` even are — every CDP
  detail lives client-side, in `browser_window.gd`, on purpose (see that
  service's own README for the reasoning: it keeps this service's surface
  from growing every time the client starts using a new CDP domain).
  Deployed as its **own** Docker container (new root `docker-compose.yml`),
  separate from the existing OCCT `backend/` container, specifically so a
  misbehaving Chromium tab can't starve memory the geometry solver needs —
  both run on the same Raspberry Pi 5 (4GB), which is why this was worth
  being deliberate about (see `docker-compose.yml`'s own comments for the
  concrete limits: `mem_limit: 768m`, `cpus: 1.0`, `shm_size: 256mb`).
- **`scripts/browser_window.gd` (this repo, new)** — a `diegetic_panel.gd`
  window with a URL bar and back/forward/refresh, whose content area is a
  live JPEG screencast of the real Chrome tab (`Page.startScreencast`,
  decoded frame-by-frame), with clicks/drags on it forwarded as
  `Input.dispatchMouseEvent` at the scaled CDP device coordinates. All the
  CDP message building/parsing is pure static functions
  (`build_message()`, `scale_to_device()`, `parse_incoming()`, etc.) —
  deliberately split out so `tests/browser_window.gd` can test them
  directly, the same pattern `calculator_window.gd`'s
  `evaluate_expression()` already established.

**PDF reader needed no separate work at all.** Pointing the Browser window
at a PDF URL makes Chrome's own built-in PDF viewer render it inline —
confirmed for real (see below), not assumed from general Chrome
knowledge. John's instruction on this ("a browser might be able to handle
PDFs, if not keep researching") is fully settled: it can, so there's
nothing further to research.

**This is the first piece of work this session validated with a real,
live, multi-process end-to-end pass, not just headless unit tests against
fakes** — made possible because this sandbox turned out to have a working
Chromium binary after all (Playwright's own bundled build at
`/opt/pw-browsers/chromium`), even though Ubuntu's own `chromium-browser`
apt package does not (confirmed by actually installing it: it pulls in
`snapd` and refuses to run — "requires the chromium snap to be installed"
— because this sandbox has no working snapd, a dead end that would have
otherwise stood in the way of testing any of this for real). With that
binary:

1. **The relay service itself**, run directly (`uvicorn`, no Docker — no
   Docker daemon in this sandbox either) with
   `BROWSER_RELAY_CHROME_BINARY` pointed at that real Chromium: a plain
   Python WebSocket client drove a full `Page.enable` →
   `Page.navigate` → `Page.startScreencast` → real `Page.screencastFrame`
   → `Page.screencastFrameAck` → `Input.dispatchMouseEvent` sequence
   through it against a real Chrome tab, and a wrong-`X-API-Key`
   connection was confirmed rejected (HTTP 403 before the WebSocket
   handshake even completes).
2. **The PDF question**, settled the same way: navigating a real tab to a
   local PDF file (`file:///tmp/test.pdf`) loads Chrome's own built-in
   PDF-viewer extension into a child frame (`chrome-extension://…`),
   fires a normal `Page.loadEventFired` with `isDownload: false` (no
   download prompt), and the screencast keeps producing real frames of
   the rendered page — this is also exactly why `extract_frame_url()`
   only looks at the *top-level* frame's own navigation: the PDF viewer's
   internal frame would otherwise overwrite the URL bar with its own
   `chrome-extension://` URL.
3. **The actual Godot client code**, not a Python stand-in: a one-off
   script (not committed — the real coverage lives in
   `tests/browser_window.gd`'s pure-function tests plus this record) ran
   inside a real headless Godot 4.7.2 process, using `WebSocketPeer` with
   `handshake_headers` set to a real `X-API-Key`, against the real running
   relay from step 1. It confirmed: the custom-header WebSocket handshake
   actually works from Godot's own `WebSocketPeer` (this had only been
   confirmed to exist as a property before, via `ClassDB` reflection, not
   exercised); a real `Page.navigate` and a real `Page.screencastFrame`
   round-tripped through the relay; the JPEG payload decoded into a real
   800×600 `Image` via Godot's own `Image.load_jpg_from_buffer()`; and a
   real `Input.dispatchMouseEvent` (press + release) sent without error.

**Update, same session: John asked whether installing Docker would allow
more thorough testing — yes, and it did, up to a real network-policy
wall.** A Docker daemon wasn't available in this sandbox initially; asked
to install it, `dockerd` turned out to already be present and started
cleanly (containerd, buildkit, overlayfs all came up without issue). With
it:

- **The `browser-relay` image's non-Chromium layers built and ran for
  real**: the exact base image, a `pip install` of the exact
  `requirements.txt` (needing a documented workaround for this sandbox
  specifically — installing this sandbox's proxy CA bundle as a trusted CA
  in an early build layer, since a plain container doesn't trust it by
  default), and the app code copied in.
- **The actual containerized app was run as a real Docker container** (not
  just `python -m uvicorn` on the host) and its fail-fast startup
  behaviour was confirmed for real: pointing `BROWSER_RELAY_CHROME_BINARY`
  at a non-Chrome binary inside the running container made it refuse to
  start with a clear error, rather than come up silently broken.
- **What it still couldn't reach: the Dockerfile's one Chromium-installing
  line.** `deb.debian.org` returns `403 Forbidden` on both HTTP and HTTPS
  from this sandbox — confirmed directly with `curl`, not assumed, and
  not transient (retried once, same result) — which is this specific
  sandbox's own network egress policy, not a Dockerfile problem. As a
  substitute check of what that line is *for*, a real working Chromium
  binary (the same Playwright one from the check above) was bind-mounted
  into the built image and run directly: it failed with `error while
  loading shared libraries: libglib-2.0.so.0: cannot open shared object
  file` — exactly the runtime dependency `apt-get install chromium` exists
  to pull in, confirming what was missing without confirming apt itself
  can supply it here.

**What's still unverified, net of all of the above**: the Debian-apt
`chromium` package specifically actually resolving and installing its
full dependency set (blocked only by this sandbox's `deb.debian.org`
access, not by anything about the package or the Dockerfile) and the
arm64 Raspberry Pi target — both reasonable to expect to behave like any
other environment where that domain is reachable, but neither run for
real yet — and, as with every other window in this project, a real
headset. `browser-relay/README.md` carries this same detail on the
DIDSA-CAD side.

## Wrist tablet / windows / keyboard redesign: in progress (plan: `docs/wrist-tablet-redesign-plan.md`)

John's sketch + concept renders, redesigned as a new tablet built **beside** the
old one (old `wrist_tablet.gd` untouched until the new one is signed off), then
windows and the popup keyboard restyled to match. Decisions, phases and the
one-active-tool rules are in the plan; this section tracks state.

**Phase 1 — foundation: done (headless-verified; nothing here is visible in the headset yet).**
- `scripts/ui/didsa_ui_theme.gd` + `ui/didsa_ui_theme.tres`: one Resource holding the
  colour / radius / spacing / type / motion tokens, with `build_theme()` (Button,
  Label, PanelContainer, HSlider, scroll bars, and type variations `LabelDim`,
  `LabelSmall`, `LabelTitle`, `ButtonAccent`, `ButtonDanger`, `ButtonRail`,
  `PanelRaised`) and shared styleboxes (`panel_box()` is the chrome every tablet /
  window / keyboard will use). Edit the .tres in the Godot Inspector to tune the look.
- `scripts/ui/laser_surface.gd`: the tablet's real-headset-hardened laser → SubViewport
  logic (frozen press, edge slack, let-go-on-leave, settle window, claim protocol,
  slider drag, stick scroll) as one component with no layout. `claim_first = true`
  is the arbitration windows use. **Adoption**: the new tablet (Phase 2) uses it;
  `diegetic_panel.gd` and `popup_keyboard.gd` switch to it in Phase 3 together with
  their restyle (deliberately not touched in Phase 1; the old tablet keeps its own copy).
- `scripts/ui/tablet_registry.gd`: categories and tools as data (4 × 2 grid = 8
  categories; a second grid row only from the 5th), `kind` = `page` or `mode`, optional
  list provider for the side panel.
- **UI Lab**: `lab/ui_lab.tscn` — open in the Godot editor, F6; a desktop window showing a
  style sheet laid out like the new tablet, built from the theme resource.
  `tests/ui_lab_render.gd` renders it under Xvfb to a PNG.
- Tests: `tests/laser_surface.gd`, `tests/tablet_registry.gd` (both in `run_all.sh`),
  `tests/ui_lab_render.gd` (Xvfb). Godot 4.7 can be downloaded into the cloud sandbox
  (GitHub releases are reachable) and `tests/run_all.sh` runs there.
- Full `tests/run_all.sh` before and after: SMOKE output identical for every existing test.

**Phase 2 — the new tablet: built, headless- and software-render-verified; not yet seen in a headset.**
Flip `Main > Wrist tablet > use_new_tablet` (default off) to build it instead of the old one.
- `scripts/ui/wrist_tablet_v2.gd`: the 3D half. Same public API as `wrist_tablet.gd`. Floats over
  the left wrist at 0.40 x 0.26 m (same text size as before), closed by default, opened only by
  shooting the wrist icon, closed by the top-right X. Right-hand laser only (via `laser_surface.gd`,
  `claim_first = true`). A second quad, the **contextual side panel** (0.17 m wide), is hinged on
  the tablet's right edge and angled up toward you (`side_yaw_degrees` -10, `side_pitch_degrees`
  8: Inspector exports on the node, headset feel unknown, tune there).
- `scripts/ui/tablet_ui.gd`: the 2D shell from the sketch (category grid 4 cols x up to 2 rows,
  Undo / Redo / Settings / Close cluster, tool rail, tool header with on/off switch and ? help,
  controls pane, status bar). `scripts/ui/side_panel_ui.gd`: the list panel (row cards, two-tap
  confirm on destructive actions). Both are plain Controls and run in the UI Lab.
- `scripts/ui/tablet_pages.gd`: every page ported from `wrist_tablet.gd` with the same calls into
  `main.gd` and the tools, restyled via the theme. **Deliberate differences**: a mode tool's on/off
  switch is in the tool header, not on its page; status text is in the status bar; lists are in the
  side panel (Mates -> existing mates with a two-tap Delete, Measure -> results, Files -> models
  with Open / Add); Windows and Files are each one tool today; **Shoot to hide is its own rail
  entry** (View > Shoot hide), because under one-tool-at-a-time it is a mode tool, not a toggle on
  the Visibility page; Settings is the utility-cluster button, not a category.
- **One active tool**: `scripts/ui/tool_manager.gd` (Mates, Measure, Sections, Shoot hide).
  Switching category never switches a tool on; tapping a mode tool in the rail does, and turns
  any other off; tapping the active one again (or the header switch) turns it off; closing the
  tablet leaves it on. `scripts/ui/tool_badge.gd` puts a badge (icon + name) above the right
  hand's tracking ring while one is active, visible with the tablet closed. (The controller button
  discs were removed in the 29 Sep round, so the badge sits on the ring, not on a disc.)
- Undo history: `command_stack.gd` gained `history_labels()` / `redo_labels()`; a long press
  (0.6 s) on Undo opens History in the side panel and doesn't also undo.
- Icons (`scripts/ui/ui_icons.gd`) were pulled forward from Phase 4: 26 SVG-string icons on one
  48 grid, rasterised at runtime with `Image.load_svg_from_string()` (no editor import step,
  export-safe), tinted by theme. The old tablet keeps its pixel-stamped icons.
- Tests: `tests/tool_manager.gd`, `tests/tablet_v2.gd` (both in `run_all.sh`), `tests/tablet_v2_render.gd`
  (Xvfb). The old tablet's tests are untouched and still run against the old tablet.
- **Not yet verified, needs the headset**: how the angled side panel sits, text size at 0.40 m
  wide, whether the wrist icon and a 40 cm panel are comfortable, hand-badge size and position.

**Phase 3 — windows and keyboard: restyled and moved onto the shared pieces; headless- and software-render-verified, not yet seen in a headset.**
- `diegetic_panel.gd` (every floating window) and `popup_keyboard.gd` no longer carry private copies of
  the laser -> SubViewport code: both use `scripts/ui/laser_surface.gd` (windows `claim_first = true`;
  the keyboard `claim_first = false` so it still wins over a window it overlaps). The headset-learned
  behaviours (frozen press, let-go-on-leave, claim protocol, stick scroll) are unchanged. One
  difference: the 3 cm "edge slack while a click is held" the tablet always had now applies to windows too.
  The old tablet (`wrist_tablet.gd`) keeps its own copy until it's deleted.
- The grab handle is `scripts/ui/panel_handle.gd`, shared. **The popup keyboard now has the same
  bottom handle as the windows**: grip it with either hand to carry it (the full keyboard keeps its
  lean), release to drop. It **reopens where you left it**, one remembered spot per layout (numeric /
  full), unless you've moved more than `moved_pose_reach` (3 m) from it, when it comes back in front
  of you. `popup_keyboard.setup()` takes the left hand as an optional third argument (main.gd passes it).
- Look: both are built from `ui/didsa_ui_theme.tres` like the new tablet: the theme's rounded, outlined
  panel; a close button with the close icon (still growing with the window); title in the title style;
  the keyboard's typed text in an inset field; the confirming key (OK / Done / Enter-as-confirm) in the
  accent style; handle pill and resize brackets coloured from the theme. Subclass content (calculator,
  tree, viewer, browser) is restyled for free through the theme.
- **Bug found by the new test and fixed in both**: while a window or the keyboard was being carried by its
  handle its hover flag went stale, so a trigger pull could still click through it. Carrying now drops hover.
- Tests: `tests/keyboard_handle.gd` (in `run_all.sh`), `tests/windows_render.gd` (Xvfb), a carry check added to
  `tests/windows_tab.gd`; `tests/features_round.gd` now reads the resize bracket colours as `_corner_hot` /
  `_corner_idle` (they come from the theme now, no longer constants). All other existing tests unchanged and green.
- **Not yet verified, needs the headset**: that the restyled windows/keyboard read well at arm's length, the
  handle's size on the keyboard, and whether "reopens where you left it" feels right.

**Phase 4 — polish and hand-off: built, headless- and software-render-verified; the single PCVR test is the next step.**
- **The new tablet is now the DEFAULT** (`Main > Wrist tablet > use_new_tablet = true`). Untick it to get
  the old tablet back for comparison. The 10 tests that drive `wrist_tablet.gd`'s internals (`tablet_scene`,
  `tools_tab`, `section_tab`, `bug_round`, `features_round`, `laser_and_left_hand`, `windows_tab`,
  `full_keyboard`, `popup_keyboard`, `e2e_mates_motion`) pin `main.use_new_tablet = false`; when the old tablet
  is deleted they need porting to the new one or retiring.
- Animations (all via `Tween`, all instant under **Reduce motion**; durations are theme tokens):
  tablet scales in with a slight overshoot and fades in on open, shrinks and fades on stow; the controls pane
  fades in when the tool / category changes; the side panel unfolds from its hinge and its rows fade in
  staggered (25 ms apart, capped); the status bar pulses on a toast (brighter, tinted red for an error). The
  quad is only transparent while fading. Not done (no sensible 3D equivalent inside a SubViewport): the
  button "Z-depress", the sliding category pill.
- `scripts/ui/ui_feedback.gd` (static, no autoload): haptics (hover tick as the laser crosses an enabled button,
  press, grab, open, close, confirm, error) at Off / Low / Normal / High, plus a sound hook that plays a stream
  registered with `set_sound(event, stream)`. **Settings page > Comfort** has Reduce motion, **Sound on/off**,
  **Volume** (slider, plays a confirm blip as you drag) and Haptics; all persist in `user://settings.cfg`
  (`app_settings.gd`) and are applied at startup.
- **Idle render gating** in `wrist_tablet_v2.gd`: the tablet and side panel render every frame only while the laser is
  on them or something changed in the last second, otherwise 4 times a second. Worst case a live label is 250 ms
  stale; never frozen. (The old tablet re-renders every frame while open.)
- **Sounds (added after the first Phase 4 commit)**: `scripts/ui/ui_sounds.gd` synthesises seven short soft sounds
  in code (hover tick, press click, grab thunk, open / close sweeps, confirm, error) into 16-bit mono
  `AudioStreamWAV`s at startup, so there are no audio files, no licences and no import step. Played as spatial
  `AudioStreamPlayer3D`s at the node that caused them (`ui_feedback.gd`): same event can't retrigger within 35 ms,
  at most 8 voices. Wired to: laser press and hover tick (every panel), handle grab, tablet open/close, window
  open/close, confirm/error toasts. To change a sound edit its recipe in `_build()`; to use a recorded file for one
  event, `UiFeedback.set_sound("press", load(...))` after `register_all()`. **Not heard by me**: only the samples
  (peak, length, silent ends, determinism) and the playback rules are tested; judge the sounds by ear.
- **Bug found by the new Settings test and fixed**: the Settings page's live performance readout changed height,
  shifting every button below it while you were aiming at one. It now has a fixed height.
- Tests: `tests/ui_feedback.gd` (in `run_all.sh`); `tests/tablet_v2.gd` extended (stow timing, idle gating, toast cue,
  Reduce motion); `tests/side_panel_ui.gd` extended (staggered intro).
- **Themes and shader effects (added after the first Phase 4 commit).** Three themes, switched in
  **Settings > Appearance** (or the UI Lab's buttons): **Navy** (the original), **Simple** (flat slate grey,
  thin outlines, small radii, low glow), **Dark** (near-black neutral greys, softer text). They are presets,
  `ui/themes/{navy,simple,dark}.tres`, ordinary theme resources you can edit in the Inspector;
  `ui/didsa_ui_theme.tres` is now the LIVE shared instance the presets are copied into in place
  (`scripts/ui/ui_themes.gd`), so everything already holding it sees the change. Every UI (tablet, side
  panel, windows, keyboard, hand badge) watches `UiThemes.revision` and re-themes **in place the next frame**:
  nothing is rebuilt, so the selected tool, scroll position and toggles are kept. Contrast is tested per theme
  (WCAG ratios). The choice persists (`user://settings.cfg`, applied before anything is built).
  **Shader effects** (one switch, default ON): `shaders/ui_glass.gdshader` via `scripts/ui/fx_overlay.gd`, an
  additive overlay over each panel (inner edge glow + faint top sheen, **static** so the idle render gating
  still works), plus a soft glow on hovered / selected buttons (a stylebox shadow, no shader). Each theme sets
  its strength with `fx_*` tokens; OFF hides the overlays and removes the glows, so it costs nothing.
  Tests: `tests/ui_themes.gd`, theme/effects switching in `tests/tablet_v2.gd`, per-theme x effects renders in
  `tests/ui_lab_render.gd` (shows the shader draws in every theme). Not verified: how the glow looks on a
  Quest lens / at arm's length, and the Quest-standalone cost of the overlay (one extra fragment pass per render).
- **Passthrough fix (real-headset report: choosing the Passthrough environment did nothing).** Root cause found by
  reading Godot's own AR/passthrough docs against `environment_manager.gd`: it only ever called the **legacy**
  `OpenXRInterface.start_passthrough()` (kept "for backwards compatibility") and **never set the environment blend
  mode**, which is how Godot 4.3+ turns passthrough on (alpha blend "will also perform these extra steps"). So on any
  runtime that exposes passthrough through blend modes, nothing happened. Now: ask the runtime
  (`get_supported_environment_blend_modes()`); ALPHA_BLEND if offered (+ transparent viewport), else ADDITIVE (+ black
  background), else the legacy layer; OPAQUE again when you leave; retried on `session_focussed` if the session wasn't
  ready at startup (the saved scene is applied very early). **If it still fails, it now says why**: the Environment page's
  status line (and the console) report what was used or what the runtime actually offers. `tests/passthrough.gd` covers
  all of this against a fake runtime (alpha / additive / legacy / nothing / late session / desktop). **Not verified**: a
  real headset (this sandbox has none), so whether your PCVR runtime offers alpha-blend over the link is unknown until
  the next test. Standalone Quest builds additionally need the OpenXR Vendors plugin + the export's Passthrough option
  (the project deliberately has no addons yet), which is NOT done.
- **Distance grab of floating windows and the keyboard (so an awkwardly placed one can be fetched).** Point either
  hand's LASER at a floating window or the popup keyboard (up to 6 m): it **glows** (a soft cyan halo, `shaders/ui_halo.gdshader`)
  and the laser stops on it; **grip** carries it from where it is (brighter glow); it follows the hand's position
  (smoothed) but always **turns to face you, upright** (the full keyboard keeps its lean); **A/X pulls it towards you,
  B/Y pushes it away**, at a speed proportional to its distance (same constants as nudging a part), never closer than
  0.25 m to the hand nor beyond 12 m; release drops it. Priorities: a part your hand is touching, the section gizmo and a
  panel's own near handle all win over a distance grab; a part in front of the window blocks the hover; whole-model grab
  stays out via the existing `window_held` meta. Implemented in `controller.gd` (`_update_panel_hover`,
  `_try_grab_panel_at_distance`, `_nudge_carried_panel`) and `scripts/ui/panel_handle.gd` (halo, `start_laser_grab`,
  `nudge`, facing-follow). Applies to every `diegetic_panels` member (all floating windows + the popup keyboard); NOT the
  wrist tablet. The old near-handle grab is unchanged. Test: `tests/panel_distance_grab.gd` (+ halo renders in
  `tests/windows_render.gd`). **Not verified**: the feel in a headset (smoothing rate, push/pull speed, whether hovering a
  window you are clicking in should glow that strongly), and a real A/B press (only `nudge_carried_panel()` is tested).
- **Removed the hovered-part name label** (e.g. "MESH 2") that floated beside the laser's hit point: the part still
  highlights pale yellow; `controller.gd`'s `_aim_label` is gone, README wording updated, `tests/precise_picking.gd` now
  checks there is none.
- **Headset checklist for John's PCVR pass**: (1) the wrist icon still opens it, nothing else does; (2) text size and
  comfort of the 0.40 x 0.26 m panel on the wrist; (3) the angled side list: tune `side_yaw_degrees` /
  `side_pitch_degrees` on the WristTablet node; (4) the hand badge: size, position above the ring, readable;
  (5) one tool at a time + badge with the tablet closed; (6) Undo long-press -> History; (7) keyboard handle and
  "reopens where you left it"; (8) window / keyboard look at arm's length; (9) haptic strengths; (10) animations
  feel (or turn Reduce motion on); (11) laser clicks near the panel edges and on the angled side panel.

## Untested paths

- **Wrist tablet / window / keyboard redesign (Phases 1-4, see the section above and
  `docs/wrist-tablet-redesign-plan.md`)**: all headless- and software-render-verified, nothing seen in a
  headset. The checklist is at the end of "Phase 4" above.
- **Milestone 3 (Assembly Tree, Calculator, Image Viewer windows, and the
  `diegetic_panel.gd` framework they're built on) — now headless-confirmed
  (Godot 4.7.2, `tests/run_all.sh` clean), not yet real-backend- or
  headset-confirmed.** See "Milestone 3 — floating windows" above for the
  two real bugs actually running the suite caught and fixed (a
  `controller.gd` process-ordering bug and a real Calculator wrong-answer
  bug) — the headless bar is cleared, same as everything else in this
  list, but `tests/e2e_assembly_tree.gd` still needs a real backend (none
  in this sandbox) and nothing here has felt a real hand pulling a real
  trigger yet.
- **28 Sep 2026 session's two additions — Open/Add (Files tab) and the
  Measure tab — are both headless- and real-backend-confirmed only, same
  as everything else in this list.** See "Open/add-parts pathway built"
  and "Measurements: the last milestone-4 tool" above for the full detail;
  summarized here so this list stays the one place that names every
  still-open verification gap. Specifically open: whether the Files tab's
  new small "Add" button (next to a native file's row) reads clearly and
  is easy to hit at arm's length; whether opening/adding a file feels
  right as an interaction (versus just being correct over the wire);
  whether the Measure tab's result list reads clearly with several rows
  populated; and whether picking two entities in quick succession — the
  exact overlapping-request race `measure_tool.gd`'s own `_measure_token`
  fix handles server-side — feels right from a real hand, not just correct
  over the wire.
- **Every toggle button on the tablet (Modes, Sections, Mates, the tab row,
  steadiness/scale choice rows) now has a real pressed/hover stylebox**
  (round 2's tablet-highlight fix, see above) — confirmed headless that the
  stylebox itself is real and distinct from unpressed, but whether it reads
  clearly enough at arm's length on a real headset (the original complaint)
  is still open; this project's whole real-vs-simulated-input gap means the
  fix can only be confirmed by John looking at it.
- **The Mates tab is headless- and real-backend-confirmed; the wrist tablet
  UI itself has now had one real round of laser/trigger testing too** (see
  "Real-headset testing round" above — the click-activation bug it found
  affected every tab, not just this one, and is now fixed). **Still blocked
  on a real multi-Occurrence test assembly** — see "Real-headset testing
  round 2" above; deferred, not yet scoped. Still open otherwise: whether
  picking two faces in quick succession feels right, and whether the tab's
  layout fits legibly on the existing panel size alongside everything
  else — feel, not mechanics, is what's left here.
- **The Colours tab has the same residual gap** — `colour_tool.gd`'s logic is
  headless- and real-backend-confirmed, clicking now works for real (see
  above), but colour legibility against the panel background and whether the
  text-colour contrast pick actually reads well are still open. **New this
  round, also unconfirmed on a real headset**: the held error-message
  window (does 3s read as "just long enough" or too long/short in practice)
  and the "Apply to whole group" toggle (whether the colouring-hierarchy
  concept — one Occurrence vs. every sibling sharing an owner — is legible
  from the tablet alone, with no tree/breadcrumb UI yet).
- **The Sections tab has the same gap, plus more this round.** Clicking its
  tab/toggle/Flip buttons now works for real (see above). Beyond that: the
  clip plane's own real-render behaviour is confirmed correct in a flat,
  software-rendered image (`tests/section_render.gd`, Xvfb + Mesa llvmpipe),
  but never in stereo, at real depth, or lit by anything beyond one plain
  directional light — whether a real cutaway reads correctly with both eyes,
  and whether grabbing a thin translucent disc feels natural with a real
  hand (a part has real volume to reach into; this gizmo doesn't), are both
  open. The default gizmo size (`plane_radius`, a fixed 0.4 m) and spawn
  distance (0.6 m in front of the camera) were picked as reasonable
  human-scale guesses, never checked against a real arm's reach. **New this
  round, entirely unconfirmed on a real headset**: whether the grip-vs-
  whole-model-drag fix (`section_gizmo_held` meta) actually stops the world
  moving underneath the gizmo in practice — it can't be verified headless at
  all, since Godot's `is_button_pressed()` can't be faked without a real XR
  runtime (see the "Real-headset testing round 2" section above) — and
  whether the new rectangle disc/pyramid arrow/tail reads clearly at real
  depth.
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
tracked) — real test parts John provided are tracked instead under
`tests/fixtures/` (see that folder's own `README.md`), which is **not**
what the Files tab reads from; copy a fixture into `models/` (or push it to
`user://models` on-device) to actually load it in VR.

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
  files) instead downloads its own headless Godot 4.7.2 Linux build directly
  from its GitHub release (`https://github.com/godotengine/godot/releases/
  download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip`, unzipped and
  `chmod +x`'d — no package manager needed) and, for anything touching the
  backend, stands up DIDSA-CAD's FastAPI/pythonocc backend itself with
  micromamba (Docker wasn't available in that sandbox) and a throwaway
  `CAD_API_KEY` — never John's real key — pointed at by a local `secrets.cfg`
  it creates and never commits. Micromamba's own install script
  (`micro.mamba.pm`) was blocked by this session's egress proxy policy;
  its GitHub release worked instead (`https://github.com/mamba-org/
  micromamba-releases/releases/latest/download/micromamba-linux-64.tar.bz2`).
  Once extracted: `micromamba create -y -n didsacad -f backend/environment.yml
  -r <MAMBA_ROOT_PREFIX>`, then `micromamba run -n didsacad -r
  <MAMBA_ROOT_PREFIX> uvicorn app.main:app --host 127.0.0.1 --port 8000` from
  `backend/` with `CAD_API_KEY` exported first — give it ~10 s: uvicorn's own
  startup log line is buffered and doesn't appear immediately, so don't
  conclude it's stuck before that. **Check for a pre-existing env first** —
  the 27/28 Sep 2026 sessions' own sandbox already had one at
  `/opt/sdks/micromamba_root/envs/didsa-backend` (`.../bin/uvicorn` runs
  directly from it, no `micromamba run` wrapper even needed), so the whole
  from-scratch `create`/pythonocc-core install wasn't needed either time;
  look before spending the ~10+ minutes that takes. Godot itself still had
  to be downloaded fresh each time (no pre-existing binary) — same GitHub
  release URL as above.
- **Real (non-headless) rendering, without a GPU or a display.** `gpu_timing.gd`
  was already documented as needing "a GPU and a window" — this session found
  a way to get both in a display-less cloud sandbox: `Xvfb` (a virtual X
  server) plus Mesa's own `llvmpipe` software rasterizer (both already
  present in this sandbox's base image) let Godot actually render — real
  shader compilation, real fragment discard, real pixels read back via
  `Image.get_pixel()` — where the plain `dummy` rendering driver `--headless`
  forces would silently accept shader code without ever running it (found
  the hard way: `RenderingServer.global_shader_parameter_get()` returns
  `Nil` under `--headless`, even right after a successful `..._set()` call,
  because the dummy driver doesn't actually back that state). Run with
  `xvfb-run -a "$GODOT" --path . --script res://tests/whatever.gd` — no
  `--headless` flag at all, Godot picks OpenGL 3 automatically once it
  detects no Vulkan surface is available. Used to genuinely confirm
  `shaders/section_clip.gdshader`'s own discard behaviour (`tests/
  section_render.gd`) rather than just flagging it unverified — worth
  reaching for again any time a shader or other real-rendering behaviour
  needs checking from a sandbox like this one.
- **`tests/` holds the headless tests and `tests/run_all.sh` runs them all**
  (parse-checks every script, then the steadiness filter, sensitivity,
  two-hand rotation, grab/scale, precise-picking, undo/redo, popup-keyboard,
  Tools-tab, full-scene tablet, mesh-identity, mates-tool, measure-tool,
  colour-tool, section-tool, section-tab and laser/left-hand tests).
  `tests/README.md` lists the expected values. Needs no GPU, headset or
  backend. **CI:** `.github/workflows/headless-tests.yml` runs `tests/ci.sh`
  (that suite plus `tests/check_smoke.py`, which fails on any `SMOKE ...: false`
  not listed in `tests/expected_false.txt`) on every push/PR touching code,
  scenes, shaders or tests, and a warning-only `render` job runs the four
  assert-based render tests under Xvfb + Mesa (`tests/ci_render.sh`). See
  `tests/README.md` "CI" (and its "CI open items": make `headless` required,
  try the e2e `workflow_dispatch` once, watch the warning-only `render` job)
  for what runs where. Picture-only render tests and
  the `e2e_*` tests stay manual.
- **`tests/e2e_*.gd` are the exceptions** (`e2e_backend.gd`, `e2e_step_import.gd`,
  `e2e_mates.gd`, `e2e_colour.gd`, `e2e_colour_group.gd`, `e2e_section.gd`,
  `e2e_add_component.gd`, `e2e_measure.gd`): each deliberately points
  `main.secrets_file_path` at the real `secrets.cfg` and drives real network
  calls against a running backend, using the tracked `assembly.didsa` (or,
  for `e2e_add_component.gd`, two throwaway Parts it creates itself).
  Run them manually once your backend is up; none are part of `run_all.sh`.
  A subset (`tests/e2e_ci_list.txt`) also runs in CI: `.github/workflows/
  e2e-backend.yml` builds DIDSA-CAD's `backend/Dockerfile` (public repo, `cad_ref`
  input, default `main`), starts it with a throwaway `CAD_API_KEY`, writes
  `secrets.cfg` and runs `tests/ci_e2e.sh`; first run found one stale assertion
  in `e2e_design_table.gd` (fixed).
  `e2e_backend.gd` confirmed once from the cloud sandbox: 3 parts, import
  21 ms, download 83 ms (47 KB glb), parse 2–3 ms, ~130 ms wall clock from
  instantiating the scene to "Loaded" — the first time this path was
  exercised outside John's own machine. `e2e_mates.gd`/`e2e_colour.gd`/
  `e2e_section.gd` are milestone 4's own real-backend confirmations (see
  that section above) — `e2e_section.gd` doesn't confirm a new endpoint
  (Sections calls none) but confirms `section_tool.gd`'s wrap/grab/unwrap
  pipeline against real backend-sourced parts and materials, not just a
  synthetic stand-in. `e2e_add_component.gd`/`e2e_measure.gd` are the 28 Sep
  2026 session's own real-backend confirmations (see "Open/add-parts
  pathway built" and "Measurements" above) — the latter is also the one
  that caught the `_measure_token` overlapping-request race, a real bug an
  e2e run found that pure code review and the headless unit test both
  missed (neither exercises a genuine, non-instant network round trip).
- Parse check: `"$G" --headless --path . --check-only --script
  res://scripts/x.gd` (reports `SCRIPT ERROR: Parse Error`; the OpenXR "no
  HMD" notice is harmless).
- Writing new tests: an `extends SceneTree` script that builds nodes in
  `_initialize()`, `await process_frame`s, prints `SMOKE …`, and `quit()`s;
  run with `--headless --script`. The tablet was tested by aiming the right
  controller at button positions and emitting `button_pressed`/`released`.
  **Any bare `Node3D` the test builds itself (not part of a loaded scene)
  needs the exact same `await process_frame` after `add_child()` before its
  `global_position`/`global_transform` can be touched at all** — this isn't
  specific to `main.tscn`, it's `SceneTree._initialize()`'s own timing (see
  `tests/section_tool.gd`'s own top-of-file note).
- GPU timing: run non-headless with the scene in a big SubViewport and
  `viewport_get_measured_render_time_gpu`.
- **Never run `main.tscn` without pointing `main.secrets_file_path` at a
  nonexistent file** — it would POST to the real dev backend.
- Headless tests can't fake a real grip press or a headset; anything relying
  on those is exercised by calling the routine directly and is flagged as
  unverified in-headset.

## Vision brief drift

**As of 28 Sep 2026, this repo's own `docs/vision-brief.md` export is fully
caught up with everything below** — milestone 1's, milestone 3's and
milestone 4's table rows, the "Interactive tree" bullet under Assembly
tools, the Mates cross-compatibility note, and the Mates-testing-blocker
checkbox have all been hand-edited into the export directly. **What's still
open: none of this has been pushed back into the live Claude Docs
artifact** — no session so far (this one included) has had access to it,
only to this repo's own point-in-time export ("re-export after any
significant change" per its own header). So the live doc and this repo's
export have now diverged the other way: the export is current, the live
doc is stale, and only John (or a session with access to that artifact)
can bring the live doc back in sync. Kept here as the record of what
drifted and when, since it can drift again the same way in either
direction.

- **Milestone 1** (originally drifted stale: the live doc said whole-model
  two-hand rotate/scale and scale views were open, and predated STEP/OBJ/
  STL import entirely). Export's row now says: "Done except for measuring
  it on real Quest hardware. Native import, STEP/OBJ/STL import, individual
  part manipulation (proximity grab, and trigger-laser select with
  thumbstick rotate / A-B nudge), user movement (walk, snap-turn,
  teleport), whole-model one/two-hand movement (drag, turn, scale), scale
  views (presets, lock, Fit, Home), the wrist tablet (Modes, Scale, Tools,
  Files, Perf, Undo/Redo), the popup keyboard, and local glb import (no
  backend round-trip) are all built and running — the only thing left is
  measuring performance on a real Quest headset (everything so far has been
  PCVR via Virtual Desktop), not more building."
- **Mates cross-compatibility note.** The "Mates workflow" section's note
  (added 27 Sep 2026) that VR mates must be readable/editable in DIDSA-CAD's
  flat app and vice versa — John's own requirement, added ahead of the mates
  work itself so it wouldn't be missed when that phase started — is in the
  export.
- **Milestone 4.** Export's row now says: "**Done, 28 Sep 2026.** Parts move
  individually; mates, colours, sections and measurements all work —
  Measurements (the last of the four) is a thin client to DIDSA-CAD's
  existing `POST /parts/{id}/measure`, needing no backend changes at all.
  Headless- and real-backend-confirmed (`tests/measure_tool.gd`,
  `tests/e2e_measure.gd`); not yet confirmed on a real headset." Sections'
  interaction was a design call made along the way — the vision brief
  itself never specified one, unlike Mates' own spelled-out workflow (see
  the "Milestone 4" section above for the full reasoning) — worth flagging
  if the live doc is ever revised, since it's this repo's own addition, not
  something being faithfully carried over from an existing spec.
- **Mates testing blocker.** The "Open decisions and risks" list's entry
  for this is now marked `[x]` resolved in the export, with a note on what
  actually closed it (`POST /parts/{id}/add-component` — see "Open/add-parts
  pathway built" above) and that the separate storage/composition decision
  is narrower than it looked as a result.
- **Milestone 3 and the "Interactive tree" bullet.** Export's milestone-3
  row now says it's mostly done (Assembly Tree/Calculator/Image
  Viewer/Browser built, Browser doubling as the PDF reader; only
  DIDSA-CAD-as-a-window remains flagged as its own unstarted spike) rather
  than listing all five as equally unbuilt, and the Assembly tools list's
  "Interactive tree" bullet now notes the browse/tap-to-select half is
  built, with "pulled out into world space" called out as further scope.
  See "Milestone 3 — floating windows" above for the full detail.

## Visuals pass, 28 Sep 2026: infinite floor grid, mixed-reality Environment scenes, wrist tablet reorganised into categories

**Headless-confirmed this session** (Godot 4.3 fetched into the container
specifically to check this work, since none was preinstalled) — parse-
checked every script in `scripts/*.gd` and ran the full `tests/run_all.sh`
list end to end: `ALL RAN WITHOUT SCRIPT ERRORS`, and every SMOKE line the
new navigation touches reads correctly (matched line-for-line against a
`git stash`ed baseline run of the pre-this-session code, to tell a real
regression apart from an already-flaky line — see "A real layout bug this
caught" below). **Not confirmed on a real headset or against OpenXR
passthrough** — flagged per-item below where that gap is sharpest.

**A real layout bug this caught, worth keeping in mind for any future
tablet page.** The first version of the sub-tab redesign put "User
movement" (View > Navigate) and several other buttons far enough down the
panel that clicks silently landed outside the SubViewport and did nothing
— caught by diffing SMOKE output against the stashed baseline (`locomotion`
staying `true` after a click that should have flipped it), not by reading
the code. Root cause: `BoxContainer` (the `VBoxContainer`s every page and
sub-page use) distributes its own leftover space *equally among whichever
children are currently visible* when none of them carry the expand size
flag — with only one page/sub-page visible at a time, that one page (and,
recursively, its own children) ballooned to fill the holder's entire
`SIZE_EXPAND_FILL`ed height, pushing later content off the bottom. Fixed
two ways: every page/sub-page now gets `size_flags_vertical =
Control.SIZE_SHRINK_BEGIN` right where it's added to its holder (see
`_build_ui()`'s and `_build_subtabbed()`'s own comments), and the panel
itself grew (`panel_size` 0.24×0.18m → 0.24×0.225m, `viewport_size`
640×480 → 640×600) to give the now-two-level navigation the extra room
a single flat tab row didn't need. Confirmed: `tests/tablet_scene.gd`'s
"2:1" scale click, the Navigate/Visibility/Sections toggle clicks, and the
Settings > Steadiness "Strong" click (the last of which turned out to be
silently broken in the *original* flat-tab layout too — baseline's own
"steadiness after clicking Strong" stayed on "Medium"; the extra panel
room fixed that as a side effect, not something this session set out to
fix) all now read correctly against the stashed baseline.

**Floor.** The original spike's floor (`scenes/main.tscn`'s `Ground` node)
was a small (6×6 m) opaque `PlaneMesh` with no material — the "square plane"
that hid anything dropping below floor level, since an opaque surface
correctly (if unhelpfully) occludes geometry behind it along the camera
ray. Replaced with a much larger (300×300 m) plane driven by a new shader,
`shaders/infinite_grid.gdshader`: thin white lines on an otherwise fully
transparent surface (600×600mm cells, ~60% transparent lines, distance-fade
so the plane's own edge is never seen, `depth_draw_never` so it can never
occlude anything even through its own gaps). The `Ground` StaticBody3D's
collision box grew to match (still 0.1m thick, sitting at y=0) — locomotion
itself doesn't raycast this body (teleport uses a maths `Plane`, see
`locomotion.gd`), so this only matters for something standing/resting on
the floor's own physics body.

**Environment (View > Environment tab).** New `scripts/environment_manager.gd`
(a `WorldEnvironment` subclass, new `WorldEnvironment` node in `main.tscn`)
switches between three rendered presets — **Light**/**Dark**/**Mid**,
differing in background colour, ambient light and the scene's one
`DirectionalLight3D`'s energy/colour — and **Passthrough**, OpenXR mixed
reality via `OpenXRInterface.start_passthrough()`/`stop_passthrough()`
(added alongside `is_passthrough_supported()`), with the viewport's
`transparent_bg` and `RenderingServer.set_default_clear_color()` cleared
per Godot's own documented passthrough flow. **Unverified**: passthrough
specifically needs a real Quest (or another passthrough-capable OpenXR
runtime) to confirm at all — desktop/PCVR preview can only exercise the
"not supported, falls back to black" branch. The last-picked scene
persists across restarts via a new `scripts/app_settings.gd`
(`user://settings.cfg`), loaded in `main.gd`'s `_ready()`.

**Wrist tablet reorganised.** The old ten flat tabs (Modes, Scale, Tools,
Mates, Colours, Sections, Measure, Windows, Files, Perf) are now four
categories on a left-hand rail — **View** (Navigate/Scale/Visibility/
Environment sub-tabs), **Assembly** (Mates/Colours/Sections/Measure
sub-tabs), **Windows**, **Files** — plus a small **Settings** cogwheel
pinned to the panel's own top-right corner, out of the main rail, holding
what John asked to be "set and forget": Steadiness (moved out of Modes),
the old Perf tab's Display levers (Shadows/Resolution/MSAA) and readout,
and a new **project folder** setting (an arbitrary absolute path the Files
category also scans — `main.gd`'s `list_model_files()`/`project_folder()`/
`set_project_folder()` — persisted the same way as the last-picked scene).
`wrist_tablet.gd`'s `_build_subtabbed()` is the new generic
one-category's-own-sub-navigation helper (same radio-button-group
mechanism the top-level rail already used, just scoped one level down);
`_show_page()` still exists for the five top-level pages.

Buttons on the rail and the Environment/Settings pages now carry a small
icon next to their label — stamped into a Godot `Image` at UI-build time
(`_make_icon_texture()`/`_stamp_disc()`/`_stamp_ring()`/`_stamp_rect_*()`/
`_stamp_line()`) and handed to `Button.icon` as a real `ImageTexture`, in
the same single-stroke style DIDSA-CAD's own SVG icon set uses
(`client/assets/icons/` — `stroke="currentColor"`). Deliberately *not*
Godot's SVG import pipeline (no editor available in this environment to
generate `.import` files) and deliberately *not* a hand-drawn child
`Control` overlaid on the button (an earlier draft did this, and in doing
so also emptied `Button.text` — which broke every `tests/*.gd` lookup that
finds a button by its exact label; caught in review, not by running
anything, since nothing here runs). `Button.icon` + `Button.text` together
keeps Godot's own native icon+text layout and keeps every button's real
text intact.

**Test suite.** `tests/tablet_scene.gd`, `tests/tools_tab.gd` and
`tests/section_tab.gd` are updated for the new navigation (an extra
category click before a sub-tab click; `Modes`→`Navigate`, `Tools`→`View`
+`Visibility`, `Sections`→`Assembly`+`Sections`, `Colours`→`Assembly`+
`Colours`, `Strong`/the old Perf levers → `Settings`) and confirmed
running clean this session (see above). `tests/windows_tab.gd` needed no
change (Windows stayed a flat, top-level category) — its pre-existing
`false` SMOKE lines (Calculator/Browser computing something real through a
laser click) are unchanged from the stashed baseline, i.e. not something
this session touched or broke; consistent with "No browser relay
configured"/no-backend, both expected in a from-scratch headless run.
`tests/steadiness_filter.gd` doesn't touch the tablet UI at all. **No new
automated test covers the Environment tab, passthrough, or the
project-folder setting** — worth adding; the icon-stamping helpers
(`_stamp_disc()` etc.) are also unit-testable in isolation (pixel-check a
few known coordinates on the returned `Image`) but nothing does yet.

`README.md`'s wrist-tablet section (item 7) and items 10–16 are updated to
match; item 16 is new (floor grid + Environment).

## Follow-up visuals pass, same day: white laser/marker, controller button discs, tablet icon

Confirmed the same way as the pass above — parse-checked every touched
script and re-ran `tests/run_all.sh`'s full list against Godot 4.3
headless; `ALL RAN WITHOUT SCRIPT ERRORS`, no new `false` SMOKE line
anywhere the diff touches.

- **Origin marker and laser, both white.** `controller.gd`'s
  `_add_visible_marker()` (the small sphere at each hand the laser
  emanates from) shrank to a third of its original 0.02m radius; the laser
  itself (`_add_laser()`) narrowed slightly (0.003m → 0.002m radius). Both
  recoloured from the original cyan to white, matching this pass's own
  white-line language (floor grid, tablet icons).
- **Controller button discs.** New `controller.gd` `_add_button_discs()`:
  a thin ring plus small white discs at this controller's own approximate
  real button positions — thumbstick, the two face buttons (A/B on the
  right hand, X/Y on the left), and, **left hand only**, the Menu button —
  matching what this project's own `openxr_action_map.tres` actually binds
  (`menu_button` → `/user/hand/left/input/menu/click` only; the right
  controller's real hardware has no equivalent, its System/Oculus button
  being OS-reserved). The Menu disc additionally carries three tiny dark
  bars so it reads as a hamburger (≡) glyph rather than a plain dot. Each
  disc brightens to pure white on its real button's press
  (`_on_button_pressed()`/`_on_button_released()` now call a new
  `_flash_disc()`, independent of whatever the press actually does) and
  fades back on release — real visual confirmation you found the right
  button, the way many VR apps show a floating controller reference (Quest
  home environment included) rather than making you glance at your actual
  hardware. **Positions are a stylised approximation** (offsets in metres
  from the controller's own tracked origin, chosen by eye against the real
  Touch controller's general layout, not measured/traced) — worth a real-
  headset pass to nudge them once someone can actually look at their hand.
- **Wrist tablet icon.** `wrist_tablet.gd`'s `_build_target()` (the small
  icon that opens the tablet) is no longer a plain ring-and-dot bullseye —
  it's a thin ring around a thin landscape-rectangle outline (four short
  `BoxMesh` bars), evoking a tablet rather than a target. White at rest,
  brightening to pure white on hover (was cyan/yellow) — the hover
  affordance is now brightness-only, no hue change, for the same reason
  the button-disc flash above dropped the old yellow accent.

## Bug-fix round, same day: controller discs repositioned, real section-clip fix, Files "Add" feedback, tablet-icon hover, window grab handles

Real-headset feedback (John's own bug list) on the previous two passes, all
five items fixed and confirmed this session — three of them (button
positions, the section shader, the drag-handle timing) specifically
**because** a real Godot render was available to check against, not just
read code. `tests/run_all.sh`: ALL RAN WITHOUT SCRIPT ERRORS; no `false`
SMOKE line anywhere this diff touches beyond the same pre-existing three in
`windows_tab.gd` (no relay/backend configured — unchanged from before this
session, see the previous pass's own note).

**Controller discs and the tablet icon, moved back.** Both read as too far
forward. `controller.gd`'s `_add_button_discs()`: each disc nudged back
(+Z, toward the user) by its own diameter (0.014m for the thumbstick disc,
0.010m for the two face-button discs and the Menu disc), the ring by their
0.011m average so it stays centred over the moved cluster.
`wrist_tablet.gd`'s `target_position` (the icon floating above the wrist)
moved back by its own ring's 0.062m outer diameter, same fix, same
reasoning.

**Section tool: a real bug, not a limitation — parts genuinely vanished
instead of getting cut open.** Traced with an actual render, not just
code-reading: `tests/section_render.gd`'s own Xvfb+llvmpipe setup (no GPU
here either, same as that test's own docstring explains — Mesa's llvmpipe
under a virtual X server stands in) pointed a camera straight into an open
cut on a solid, sectioned test cube and got a fully black frame — 0 of 144
sampled points lit. Two compounding causes, both real, both fixed in
`shaders/section_clip.gdshader`:
1. **No cap, and the interior was culled away.** `cull_back` (Godot's
   default) means the discarded half's own interior surfaces — the only
   thing left where it used to be — are invisible from outside; looking
   into the cut showed pure background. Fixed with `render_mode
   cull_disabled` plus `NORMAL = FRONT_FACING ? NORMAL : -NORMAL` in the
   fragment shader — a real second render pass (a true stencil cap) isn't
   possible from one fragment shader, but for this app's actual parts
   (simple, near-solid mechanical shapes) rendering the now-flipped
   interior face reads as a real filled cross-section at zero extra draw
   calls. The interior face is also darkened (`albedo * 0.6`) so a cut
   reads as "inside", not just more outer surface.
2. **Even fixed, the interior rendered black anyway.** The shader's
   in-place METALLIC=1.0/ROUGHNESS=1.0 (matching the glTF spec's own
   unset-field defaults, which is what the docstring assumed
   `mesh_export.py` always produces) has near-zero diffuse response and
   needs a strong, well-aimed specular light to read as anything but black
   — fine under the render test's own compensating `light_energy = 3.0`,
   not fine under this app's actual directional light (0.55–1.15 across
   the Light/Dark/Mid presets). Confirmed empirically (re-ran the same
   Xvfb render at each candidate value): METALLIC=0.0/ROUGHNESS=0.6 makes
   the interior reliably visible under realistic lighting. A deliberate
   departure from matching the export's own literal PBR values — see the
   shader's own updated docstring.
   Both fixes verified with a throwaway Xvfb render script (not committed
   - the existing `tests/section_render.gd` already covers the shader's
   core clip/flip/restore behaviour and was re-run clean after each
   change) and cross-checked against a solid (non-paper-thin) cube at
   several clip fractions to confirm the basic clip itself was never
   actually broken (proportional, continuous — 28/14/7 lit-sample counts
   at 50%/25%/10% kept) — the "disappears" bug was specifically the
   hollow-interior-when-viewed-face-on case above, not a threshold glitch.

**Files tab "Add" gave no feedback at all.** `main.gd`'s own
`add_component_file()` (and every other load/add/import path) only ever
calls `_set_status()`, which — per that function's own one-line body — is
console-print-only; deliberately no floating 3D status text since an
earlier pass found that distracting. Clicking **Add** with no
`secrets.cfg` configured (the reported case: testing with the native
fixture files, no backend running) hits `add_component_file()`'s very
first guard clause and returns, and from inside a headset that reads as
"nothing happened" - there was nowhere else for that message to go. Fixed
with a new status label on the Files page itself
(`_files_status_label`, refreshed the same way the Colours tab's own
status label already is, in `_process()`'s 0.25s tick) — now shows
whatever `main.status_text` last said, success or failure, whichever tab
triggered it.

**Wrist tablet icon hover: swell + blue tint**, replacing last pass's
brightness-only hover (which itself replaced the original cyan/yellow) -
`_update_pointer()` now also sets `_target.scale = Vector3.ONE * 1.2` on
hover, and the tint is `Color(0.75, 0.85, 1.0)` rather than pure white.

**Floating windows had no way to move.** `_place_in_front_of_camera()`
only ever runs once, on `open()` - a window opened once always reopens
exactly where it first appeared, whatever else has moved. New
`diegetic_panel.gd` `_build_handle()`: a small white capsule at the centre
of the panel's own lower edge; `_on_grip_pressed()`/`_on_grip_released()`
(both hands, `grip_click`) grab it by proximity and drag the whole panel
1:1, self-contained rather than routed through controller.gd's own
part-grab search (this file's own top docstring already explains why that
class of fix stays out of proven files - same reasoning applies here: a
window handle floats well clear of the assembly in normal use, so it
doesn't need arbitration against an ordinary part-grab). Required adding
a `left` controller parameter to `setup()` and to all four subclasses'
`setup_xyz()` (`assembly_tree_window.gd`, `calculator_window.gd`,
`image_viewer_window.gd`, `browser_window.gd`) and their call sites in
`main.gd` - previously only `right` was ever passed, since laser/click
interaction is right-hand-only, but grabbing a physical handle isn't.
New `tests/windows_tab.gd` coverage (grip near the handle grabs it, drag
follows 1:1, release stops the follow) needed **three** `await
process_frame`s after moving the hand, not one, to see the moved
position - confirmed by direct instrumentation that this was purely a
test-timing gap (the panel's own `_process()` demonstrably runs and
computes the right transform; it just hadn't been called yet after a
single awaited frame in this harness), not a product bug, and matches the
extra-settle-time convention this same test file already uses elsewhere.

## Headset bug round, 29 Sep 2026: section tool (real cause this time), tree, add-part errors, tablet, discs, nudge

John's next real-headset list (ten items) on the builds above. All fixed and
covered by tests; **none of it re-checked on a headset yet** — see the
checklist at the end. Verified with Godot 4.7.2: full `tests/run_all.sh`
(no new `false` lines vs a baseline run; the tablet's Settings-tab resolution/
MSAA clicks that silently missed in the baseline layout now land), the real-
render tests under Xvfb, and the `e2e_*` tests against a throwaway real backend.

- **Section tool "disappears the model past its centre" — the real cause.**
  `shaders/section_clip.gdshader` computed `MODEL_MATRIX * VERTEX` in
  `fragment()`, but **`VERTEX` in a Godot 4 `fragment()` is VIEW-space**. With
  the assembly root scaled 0.001 and offset to `spawn_position`, every
  fragment landed at ~the model origin, so the clip became all-or-nothing and
  flipped when the plane crossed the model's origin. The previous round's
  fixes (`cull_disabled`, metallic 0) were real but never touched this;
  `tests/section_render.gd` couldn't see it (identity-transform mesh, plain
  camera — view ≈ world). Fixed: world position is a `varying` set in
  `vertex()`. New `tests/section_render_transformed.gd` (scaled+offset parent,
  moved camera, plane at 3 fractions): old shader 52/26/0 lit columns, fixed
  39/26/13. **Gotcha for any future world-space shader maths: `VERTEX` in
  `fragment()` is view-space — use a `varying` from `vertex()` or
  `INV_VIEW_MATRIX`.**
- **Add part → HTTP 422 / 500.** Reproduced against the real backend with the
  tracked fixtures: the 422 is `{"detail":"Cannot insert a Part into itself"}`
  — "Add" was offered on the file that *is* the loaded root (Open plate, then
  Add plate). Now hidden for that file (`main.gd`'s
  `native_file_root_part_id()`, cached per mtime) and every load error's text
  carries the backend's `detail` (`_http_error_text()`), visible in the Files
  status label. **The 500 did not reproduce** in any Open/Add ordering. Best
  hypothesis: overlapping requests — the backend holds one global in-memory
  Document, and Open/Add/STEP-import were un-serialised coroutines (a second
  tap, or a tap during the startup import, interleaved with an in-flight mesh
  fetch). Now one at a time (`_claim_load()`, also held across the startup
  import chain: a second tap shows "Busy…"), and the mesh GET retries once on
  5xx, logging the failing body. **If a 500 recurs, the status text now says
  why — send me it plus the backend console output.**
- **Tree never populated.** Confirmed by measurement: the row list's
  `ScrollContainer` was **0.0 px tall** — `diegetic_panel.gd` added window
  content with no expand flag, so an inner `SIZE_EXPAND_FILL` scroll area
  collapsed (same BoxContainer trap the tablet had). Content now expands.
  Also: the root Part is the tree's top row with its Occurrences as children,
  and rows are labelled with the Part's real name (cached
  `GET /parts/{id}`) rather than "Occurrence d3c102e0".
- **Files "+5 more".** Cap removed; the tablet now scrolls.
- **Right thumbstick left/right reversed.** `locomotion.gd` snap-turn sign was
  inverted (positive rotation about +Y is a left turn). Fixed; tested.
- **Grabbing a window also moved the world.** Same class as the section
  gizmo: `diegetic_panel.gd` now sets a `window_held` meta on the grabbing
  hand (cleared on release **and** on close-mid-grab), `two_hand_model.gd`'s
  `_hand_free()` honours it, and `controller.gd`'s `_try_grab()` defers to any
  panel whose handle is in reach (`handle_in_reach()`), so a grip aimed at a
  window never also grabs a part or the section gizmo.
- **Light scene grid.** Charcoal in Light, white elsewhere
  (`environment_manager.gd` sets the grid material's `line_color`).
- **Models invisible in Light/Dark.** Real backend glb parts import as a
  pure-white albedo, metallic 0, roughness 1 (checked; my first theory —
  glTF-default metallic=1 mirroring the background — was **wrong** for this
  data and I removed the hack for it). The cause was the per-scene light
  energies: Light blew a white part out to the pale background, Dark left
  faces away from the sun near-black. Light/Dark/Mid now share the Mid
  lighting rig and differ only in background and grid colour, so parts read the
  same grey everywhere with an ambient floor on unlit faces. **Caveat:** the
  project renders with `mobile`; the sandbox can only render through GL
  compatibility, so `tests/look_render.gd` asserts the shared rig and grid
  colour deterministically and its pixel checks are a smoke test only — judge
  the actual grey in the headset (a dim fill light is the next step if faces
  still read too dark).
- **Tablet.** 900×720 px / 0.3375×0.27 m (was 640×600 / 0.24×0.225 — 20%
  taller, wider so View/Assembly/Windows/Files/Settings/X share one row with
  unclipped labels; same px/m so text is the same size). All pages sit in a
  `ScrollContainer`; while the right laser is on the tablet the **right
  thumbstick Y scrolls it** (down = down), and `locomotion.gd`/`controller.gd`
  stand the stick down whenever the right hand's `ui_hover` is set, so it can't
  also teleport, snap-turn or spin a selected part.
- **A/X "towards me" felt inverted.** It moved the part by `-aim`, so tilting
  up moved it down. Now `_nudge_along_aim()` (see the follow-up below): the hand→part direction eases
  toward the aim (`nudge_steer_rate`) while the distance closes (stops at
  `nudge_min_distance` 0.15 m) — the same "bead on the laser" feel as B/Y,
  which is unchanged.
- **Controller discs.** Thumbstick / A-B / X-Y / Menu discs, the hamburger
  glyph and the press flash are gone; only the ring remains, moved back by one
  ring diameter (0.096 m). **Assumption:** "the controller discs … their own
  diameter" was read as the remaining ring; the wrist-tablet icon position was
  left alone.

Tests added: `tests/bug_round.gd` (in `run_all.sh`), `tests/section_render_transformed.gd`
and `tests/look_render.gd` (Xvfb, not in `run_all.sh`), new window-grab checks in
`tests/windows_tab.gd`; `tests/e2e_assembly_tree.gd` updated for the root row.
New fixture `tests/fixtures/real_assembly_mesh.glb` (a real backend glb).

**Headset checklist (not yet done):** section plane crossing the model centre
and beyond; snap-turn direction; A/X feel; grab a window (world must stay put);
tablet stick-scroll feel and bottom clipping; Files list with many files; the
Tree window with a real Open + Add; Light/Dark/Mid grey; the ring position.

### Follow-up, same day: A/B nudge speeds matched; tablet clicks hardened (cause not reproduced)

- **A/X vs B/Y.** John: A now goes the right way but tracks the laser too
  fast; B is too slow — they should feel the same, mid-point. B was a plain
  move-by-aim with no steering, A steered at 6/s. Both now share
  `controller.gd`'s `_nudge_along_aim()` at `nudge_steer_rate = 3.0`/s (the
  mid-point); the distance rate is unchanged (`nudge_speed_for()`, which
  he said is fine). Test: `tests/bug_round.gd` asserts A and B swing by the
  same angle (35.3° after 0.5 s at a 45° aim change).
- **"I can no longer select on the tablet; the laser briefly goes through it
  when I click."** **Not reproduced.** A realistic oblique-aim click with hand
  jitter during the press (throwaway probe, real `main.tscn`) toggles a button
  correctly on both this build and the pre-round baseline, `Files` builds
  correctly with a real backend-loaded assembly and no script errors, and the
  full suite is clean, so the click path itself works headless — whatever
  breaks it needs real controller input. Two changes aimed at the strongest
  candidate (my new stick-scroll acting on real thumb input during a click),
  both in `wrist_tablet.gd`:
  1. Scrolling now needs a deliberate push (`scroll_deadzone` 0.2 -> 0.5) and
     is locked out while a click is held and for 400 ms after
     (`scroll_click_lockout_ms`): a resting thumb drifting the stick while
     the index finger pulls the trigger would otherwise slide the page under
     the frozen press point, so the release lands on a different control and
     nothing activates.
  2. Hover has 3 cm of edge slack while a click is held: losing hover
     mid-press releases the click (`elif was_hovering and _pressed`) and the
     laser stops being shortened to the panel — the "laser goes through"
     look — so a trigger-squeeze tilt at the panel's edge no longer does it.
  **If this doesn't fix it**, the next thing needed is the Godot console output
  from a run where it fails (a script error inside the tablet's `_process`
  would produce exactly this), and which page/button you were aiming at.

## Features round, 29 Sep 2026: travel-speed slider, grabbable single-mesh files, resizable windows

John's report on the previous round: the tablet-selection problem "came and went
and then stayed OK" (left unchanged; the earlier hardening stays), and three new
asks. All headless-tested (`tests/features_round.gd`, in `run_all.sh`) and
rendered under Xvfb for a visual check; not yet in a headset.

- **Travel speed slider** (View > Navigate). `locomotion.gd`: `min_move_speed`
  1.5 m/s (the old fixed pace — the slider's bottom and the default),
  `max_move_speed` 30 m/s, exponential (`set_speed_fraction()`/
  `speed_fraction()`), applied to the left-stick walk only. **Teleport reach
  (5 m) is unchanged** — say if you want it to scale with the slider. Not
  persisted across restarts (the default is always walking pace). The tablet
  had no slider before, and its pointer is deliberately *frozen* during a press
  (to keep buttons from cancelling), which makes a drag impossible — so a press
  that *starts on a slider* now keeps tracking the laser and releases where the
  laser is (`_drag_slider`, `_slider_at()` in `wrist_tablet.gd`); every other
  press keeps the frozen behaviour. Big knob/track styling for arm's length.
- **OBJ/STL/glTF not grabbable — a real bug, reproduced.** A glTF whose only
  scene node is the mesh (what most single-object exports from other tools look
  like) is generated with that `MeshInstance3D` *as the scene root*, and
  `main.gd`'s `_show_model()` only walked the root's *descendants* — so it loaded
  as "0 part mesh(es)" with no `grabbable_parts` group and no collider: neither
  grip nor laser could touch it. Now the root is included. Also, local files
  (`load_glb_file()`) get a **double-sided** pick collider
  (`backface_collision`): third-party meshes often have flipped winding or open
  surfaces and a trimesh collider is one-sided, so the laser passed through them;
  backend-tessellated parts keep the proven one-sided behaviour. **Caveat:** an
  OBJ/STL/glTF that came through the backend wrapper (`_import_external_file()`)
  *did* already load as a grabbable part when I tried a generated cube, so if a
  specific real file still can't be gripped after this, the likeliest remaining
  cause is scale (grip needs your hand within 5 cm of the part's bounding box;
  STL/OBJ go through the backend as millimetres → ×0.001, a local glTF is read as
  metres) — tell me the file's units and what you see.
- **Resizable floating windows** (`diegetic_panel.gd`, so Tree, Calculator,
  Image Viewer and Browser all get it). Four L-shaped brackets sit just outside
  the corners; aiming the right laser at one (a zone reaching 5 cm outward,
  4 mm back inside the edge so it never steals a content control such as the
  close button) highlights it cyan and enlarges it, and the laser stops on it
  like on the panel. Hold the trigger and drag: the opposite corner stays fixed,
  size clamps to 0.16–1.6 × 0.16–1.3 m. It is a **true resize**: the SubViewport
  grows with the panel at the same pixels-per-metre (re-allocated only every
  ~4 px of change, exact on release), so a bigger window shows more content and
  text stays the same physical size. Not persisted.

## Mates round, 29 Sep 2026: enforced mates now move parts as the mates demand

John's repro: added a mate between the two test-assembly parts; they didn't align;
Enforce mates moved one part but not into alignment; parts still grabbed and moved
individually. Wanted: with mates present and enforced, parts move as their mates
demand, and a remaining degree of freedom must not "fly off into space".
Decisions taken with John: follow the mates **live while dragging**; a grounded
(fixed) mated part is **locked, with a Fix/Float toggle**; **all placed parts'** VR
moves are saved to the backend.

**Root cause (verified against a real backend, not assumed).** VR moves (grip-drag,
laser nudge/rotate) only ever moved the Godot node; the backend was never told, so
every mate solve ran against STALE poses: the moved peer looked misaligned, and the
solver's free directions snapped back to the backend's old position. The flat app's
flow is "PATCH the dragged pose, then solve" (the solve's initial guess is the stored
pose, so it lands on the nearest mate-satisfying placement and leaves free directions
alone) — the VR client had only the second half. Reproduced: with the grounded plate
lifted 25 mm in VR, the old build mated the peg to the plate's OLD plane (a 25 mm
gap); a solve is ~3.6 ms server-side, so doing it live is cheap. Also found: the
solve of a grounded occurrence 422s and the client swallowed it (create_mate with the
grounded part as 2nd pick, and Enforce all, silently skipped it); no solve error was
ever shown. **Not a solver bug** — my first probe looked like one but misread face
normals from triangle winding (unreliable on reversed faces); ruled out.

**Client (`scripts/mates_tool.gd` is now the assembly-constraints hub):**
- `persist_pose()` — latest-wins write queue per occurrence; called on grip release,
  laser deselect and undo/redo (`controller.gd`'s `_push_move_command`/`_sync_pose`),
  and by every solve. A grounded part's move is written by floating it in the same
  PATCH (`{transform, fixed:false}`) then re-grounding it.
- `constrain_drag()` / `desired_global()` / `end_drag()` — while mates are enforced,
  a mated, floating part is moved by a one-in-flight PATCH+solve loop; the displayed
  pose is the solver's latest answer (before the first, the pose the drag started
  from, so nothing jumps). Laser rotate/nudge apply their per-frame increments to the
  drag's accumulated wish, not the lagging displayed pose. On release the loop finishes
  its last solve, records the undo step, and re-saves if the last solve failed.
- `is_locked()` (grounded + mated + enforced) makes `controller.gd` refuse a grip /
  laser move with a haptic buzz and a tablet message; **Fix / Float selected part** on
  the Mates page (`toggle_fixed()`) chooses the anchor. Relax all frees everything.
  A grounded part with NO mates is still free to move (and is saved).
- `create_mate` drives whichever picked part isn't grounded (`_choose_driven()`);
  `solve_occurrence` saves the current pose first; `enforce_all` reports what it did or
  why it couldn't (`_friendly_error()` turns the backend's 422s into sentences).
- Scope: top-level occurrences of the loaded root only (same as before — the backend
  only mates those, and only those have an owner-relative pose the glb bakes 1:1).

**Backend (DIDSA-CAD `assembly_solver.py`, own commit in that repo):** a face-to-face
mate leaves rotation about the shared normal free, but the solve's warm-start seed was
built from the LOCAL normal alone and discarded the occurrence's current rotation, so
every solve reset any spin about the mate axis (confirmed: a 30°/90° spin came back as
0°). The seed is now the minimal rotation taking the driven normal's CURRENT world
direction onto the target, composed onto the current rotation. New tests (spin kept;
wrong-way-facing pose still flips back); all 157 mate/assembly/occurrence backend tests
pass. **VR needs that backend change deployed** for spin to survive live dragging; without
it everything else still works but a mated part can't be turned about its mating axis.

**Tests:** `tests/mates_motion.gd` (pure logic, in `run_all.sh`) and
`tests/e2e_mates_motion.gd` (real backend, measures the mate with the backend's own
`measure`, uses REAL controller grip paths): all SMOKE true. **Not yet headset-verified:**
how the live follow feels over your real network (the displayed pose lags one round trip
— ~10–20 ms on a LAN, more over Wi-Fi/WAN), and whether the grounded-part buzz + tablet
message reads clearly. Limits/notes: live following needs the backend reachable
(a failed solve keeps the last good pose and reports on the Mates page); Distance/Angle
mates work the same way but were only exercised through coincident faces here.

## Full keyboard, 29 Sep 2026: typing web addresses (and page text) in the Browser

John: "the floating keyboard only offers a numpad — I'll need a full keyboard to type
webpages into the browser." `popup_keyboard.gd` now has two layouts. The numeric keypad is
the unchanged default (scale multiple, mate value). `{"mode": "full"}` gives a wide QWERTY:
digits row, letters, **Shift** (one-shot) + **Caps**, a **?123** symbols layer, URL keys
(`/ : . -`, **.com**), Space, Clear, Cancel/OK (the OK key takes a `confirm_label`, e.g. "Go").
It opens low (42 cm below eye level, 0.5 m out) and tilted back 30° like a keyboard on your
lap, so it doesn't sit on top of the Browser window in front of you. Same laser/press
mechanism as before; same pixels-per-metre as the keypad so keys are the same physical size.
Two ways to use it: confirm mode (type, OK/Enter calls back once; the first keystroke — or
Backspace — replaces/clears the pre-filled text, like a URL bar with its text selected) and
**live mode** (`"live": true, "on_input": Callable`): every key is handed to the callback as
`("text", "a")` / `("key", "Backspace"|"Enter"|"Tab")` and the keyboard stays open until Done.

**Browser window:** the address bar is no longer a dead `LineEdit` (there is no physical
keyboard to type into it) — poking it, or **Go**, opens the full keyboard on the current
address; `BrowserWindow.normalize_url()` turns what you typed into a URL (a bare `host` /
`host/path` / `localhost:port` gets `https://`, a full URL is used as typed, anything else —
words, or anything with a space — becomes a DuckDuckGo search). A new **Aa** button types INTO
THE PAGE: click a text box on the page, press Aa, and each key goes straight to the browser as
CDP `Input.insertText` (any character) or `Input.dispatchKeyEvent` (Backspace/Enter/Tab; Enter
carries its `\r` so forms submit). Also: the Colours tab's custom hex entry (needs a–f) and the
Settings project-folder path (a path) were silently using the numpad and now open the full
keyboard; `main.open_keyboard_for()` gained an `options` argument.

**Tests:** `tests/full_keyboard.gd` (new, in `run_all.sh`, drives the keyboard with real laser
clicks) and the pure address/CDP-event checks added to `tests/browser_window.gd`; every SMOKE line
true, and the existing numeric-keypad test is unchanged. Rendered under Xvfb to check both
layers' layout. **Not yet in a headset**, and **not exercised against a live browser-relay in
this session**: the CDP `Input.insertText`/`dispatchKeyEvent` messages are unit-checked for shape
and are the standard CDP forms, but whether they land in a focused page text box (and whether a
given site accepts synthetic key events) needs a real relay + Chromium run. Known limits: no
arrow keys / Escape / key-repeat-on-hold; Enter on a page is a form-submit key, not a newline
in the address bar; the address bar shows a search for anything that isn't host-shaped.

## Round: smooth mated drag, Image Viewer flow, multiple windows, bigger window controls — 29 Sep 2026

**1. Jerky mated dragging — the client now learns "how the part may move" once and applies
it locally (yes, that works; more round trips would not).** The first mates cut asked the
backend for the part's pose every frame (PATCH + solve per round trip), so the part moved at
network speed. Now:
- **Backend (DIDSA-CAD, own commit):** `POST /parts/{id}/occurrences/{oid}/mate-motion`
  `{transform?}` solves the occurrence's mates from the wanted pose WITHOUT storing anything and
  returns the nearest mate-satisfying pose, the DOF count and `free_twists` — an orthonormal
  basis of the remaining free motion at that pose (`[dx,dy,dz,rx,ry,rz]`: a translation added to
  the occurrence's translation and a rotation vector composed on its rotation about its own
  origin — the nullspace of the same Jacobian the DOF count already used). One request, no
  PATCH. 5 new backend tests (3 free directions for a face-to-face mate; every returned twist
  really keeps the mate satisfied and lifting/tipping is provably outside the subspace; the
  wanted pose's free directions/spin are kept; nothing stored; no-mates = all six free; grounded
  = 422); all 117 related backend tests pass.
- **VR (`mates_tool.gd`):** during an enforced-mate drag the wanted pose (hand, or laser
  rotate/nudge) is projected onto those twists **every frame, locally** (`project_motion()`;
  motion the mates forbid is dropped, motion they allow is followed 1:1, no network in the
  loop). Exact for the common mates (sliding/spinning on a face, sliding/rotating along an axis);
  first-order for curved ones — a fresh `mate-motion` call every ~150 ms (`RESYNC_INTERVAL_MS`,
  one in flight) re-anchors the reference pose and twists, which corrects any curvature drift
  without a visible jump. On release it does one last call and saves the final pose once. A
  real 60-frame grip-drag against a real backend used **7 requests total** (it used 2 per round
  trip, continuously). A backend without `mate-motion` (404 "Not Found"/405) falls back to the old
  loop automatically — tested. **The backend change must be deployed** to get the smooth path.
  Limits: projection uses a 100 mm lever arm to trade rotation against translation
  (`CONSTRAINT_LENGTH_MM`); the displayed pose is a first-order approximation between re-anchors
  for curved mates (angle mates, rotating about a moving axis), so a very fast large move on one
  can show a small correction at each re-anchor.
- Tests: `tests/mates_motion.gd` (projection maths — slide followed, lift dropped, spin kept, tip
  dropped, fully constrained, mixed twist idempotent — and that `constrain_drag` advances every
  call with zero requests), `tests/e2e_mates_motion.gd` (real backend: request count, the fallback).

**2. Image Viewer:** picking an image now **fills the window** (aspect kept, file name as the
title); a **< Back** button in the header returns to the picker; the picker is a real
`ScrollContainer` and the **right thumbstick scrolls it** while the laser is on the window
(new for every window via `diegetic_panel.gd`'s `scroll_target`; the Assembly Tree's rows use it
too — same 0.5 deadzone / click lockout as the tablet). Reopening starts at the picker.

**3. Several Browser / Image windows:** the tablet's Windows-page buttons now call
`main.open_window(kind)`: first press opens the primary window, each further press spawns
another (`spawn_window()`: staggered sideways and back so they fan out, its own state, its own
keyboard hookup); extras delete themselves on close, the primary hides. **The browser relay caps
concurrent sessions** (`BROWSER_RELAY_MAX_SESSIONS`, sized for a Pi): past it an extra Browser's
status line shows it couldn't connect.

**4. Window controls scale:** the header close button (and the Image Viewer's Back) start at
64 px / 34 pt (was ~44 px) and grow with the window (`chrome_scale()` = width / opening width,
capped at 3x; title grows by its square root).

**5. Resize corners:** hit zone doubled to 0.10 m (was 0.05), brackets drawn twice the size (0.07 m
arms), inside-edge reach 8 mm. (Tested: 8 cm out from a corner hovers it now, 13 cm doesn't.)

Tests: `tests/windows_round.gd` (new, in `run_all.sh`); pure projection tests + real-backend
checks above. Rendered under Xvfb: picker and image views. **Not yet in a headset.**

## 2026-09-30 — Constrained-drag rollout: plan lives in DIDSA-CAD, VR session S5 is queued (docs only)

No code changed. `docs/constrained-drag-rollout.md` orients VR sessions: the smooth-drag round (Sep 29) is the baseline; a CAD-side investigation found the frozen-peer solve under-reports DOF and that the projector should use screw integration and a bounding-radius lever arm. VR's part is session S5 of `DIDSA-CAD/docs/constrained-drag-implementation-plan.md`, after CAD S3/S4 land.

## 2026-09-30 — Constrained drag S5: VR adopts the group contract, projector v2, one commit on release

Implements session S5 of DIDSA-CAD's `docs/constrained-drag-implementation-plan.md` against the merged CAD S3 (endpoint) and S4 (spec + golden vectors).

**Built.** `scripts/motion/` (pure GDScript, no scene tree, 64-bit floats — `Transform3D`/`Basis` are float32 and cannot meet 1e-9, so poses are `{t, r}` arrays of plain floats and only the edges convert): `se3.gd` (chart, `rotvec` via atan2, screw exponential with the correct skew matrix), `free_motion_projector.gd` (follower-weighted Gram–Schmidt, projection, screw/additive integrators), `motion_blender.gd` (τ = 2 frames), `dof_hysteresis.gd`, `reanchor_scheduler.gd` (pure decision + acceptance test + a stateful scheduler with an injected clock Callable). `scripts/mates_tool.gd`'s live drag now: grab → one `mate-motion` with `transform:null` and `lever_arm` from the grabbed mesh's AABB half-diagonal → every frame the wish is projected onto the basis and applied to **all members** (followers move on screen) → anchors every 150 ms / 75 ms near a rank change / on `max_step`, one in flight, through the acceptance test; a rejected, non-converged, or failed answer HOLDS the last shown pose; the chart's echoed `lever_arm` replaces `CONSTRAINT_LENGTH_MM`. Release: ONE `commit:true` request with the release-time wish; success → every member takes its stored pose under ONE undo entry; `converged:false` / error → every member restored to its pre-grab pose, tablet says nothing was changed, no undo entry (one retry on a transport error only). `/solve` (create-mate snap, Enforce all) now also moves followers server-side, so after it the tool re-reads the stored poses and adopts every differing node (`_adopt_backend_poses`, one undo entry). Instrumentation: `stat_requests` plus `stat_motion` (anchor/commit requests, accepted/rejected-by-reason, holds, per-frame projection µs).

**Deleted.** `_sync_with_solve`, `_motion_supported`, the 404/405 fallback, `project_motion`, `weighted_basis`, `CONSTRAINT_LENGTH_MM`, `RESYNC_INTERVAL_MS`, `live_min_interval_ms`; the v0 alias fields `transform` / `free_twists` of the `mate-motion` response are no longer read (S9 may delete them server-side).

**Tests.** `tests/motion_vectors.gd` (new, in `run_all.sh`): every golden-vector kind to 1e-9 (7007 checks after the screw-log fix, worst difference 5e-11) + a check that fails when the fixture copy differs from a reachable CAD checkout; `tests/mates_motion.gd` extended (projector, scheduler with a fake clock, group `constrain_drag`, hold/resume, acceptance rejections, lever arm, request bodies); `tests/e2e_mates_motion.gd` rewritten against a REAL backend built from this CAD branch (S3+S4 + the S6 vectors fix; backend untouched): group follow, one commit + one undo entry, commit atomicity and hold under a conflicting mate, no alias/fallback code left. **Ran:** Godot 4.7-stable headless, real OCCT + py-slvs backend on localhost: `e2e_mates_motion.gd` → `SMOKE PASSED` (all lines true), `e2e_mates.gd` → `SMOKE PASSED`, `tests/run_all.sh` → `ALL RAN WITHOUT SCRIPT ERRORS` (the two `false` lines in `tablet_scene` are their documented after-click/after-close values). **Request counts, 60-frame drag:** 6 requests in ~0.7 s (1 grab anchor + 4 re-anchors + 1 commit), 5/5 anchors accepted, projection 0.1 ms mean, 0.2 ms max per frame (Godot headless). **Not run:** a headset — feel, pop visibility at re-anchors, whether 150 ms is right for real hands; all still unverified there.

**Spec defect found and fixed (with the CAD S6 PR).** The S4 spec built the wish in the additive chart but integrated with the screw, so a wish already on the free manifold was not reproduced when it both slid across and turned about an axis: `tests/mates_motion.gd` measured 22.4 mm (150 mm + 0.3 rad, all six free), 2.1 mm (12 mm + 0.3 rad), 48.6 mm (100 mm + 1 rad), and 23 mm on an ordinary flat face. The wish is now `Se3.screw_log(ref, wanted)`, the exact inverse of `screw_exp` (spec §4/§5/§13.3; vectors 76 cases incl. a new `screw_log` kind, projector + hysteresis pick it up through `wish_vector`); the same assertions now read exact (< 1e-9). Re-ran after the change: `motion_vectors.gd` (7007 checks, worst 5e-11), `mates_motion.gd`, and `e2e_mates_motion.gd` against the real backend — all pass. Cost, measured: on wishes OFF the manifold the swing scene's frame step rose 0.33 → 0.52 weighted mm (nearest anchors; hand 0.34) and 0.37 → 0.47 blended with real backend anchors. Other CAD findings: (2) near π the spec's axis-from-`(R+I)/2` rule has O(π−θ) error inside the 1e-3 band (same in both ports; the vectors avoid it); (3) the committed vectors' `nearest_anchors` (ternary search) moved by up to 1e-7 rad under one floating-point op, so no independent port could meet 1e-9 — regenerated as stored data; the copy in `tests/fixtures/` is from the CAD S6 branch (see `tests/fixtures/README.md`).

## 2026-10-02 — Tablet ergonomics, hand rings / watch restyle, face-level hover for Mates and Measure

Built from John's PCVR feedback; headless + software-render verified, **not yet in a headset**.

* **Wrist watch** (the shoot-to-open icon) redrawn in the redesign's style: glass face, accent ring, four-bar glyph, additive glow (when shader effects are on), all coloured from the live theme and re-styled in place on a theme change; moved back by half its own diameter (`target_position.z` 0.122 -> 0.153).
* **Hand rings / origin marker** (`controller.gd`) restyled the same way (accent ring, faint glass face, soft glow with shader effects, accent marker); re-coloured when the theme revision changes.
* **Tablet tilted 30 degrees toward the user** (`mount_tilt_degrees`) so the wrist can stay neutral while reading; `mount_position` moved to the new tablet centre so its near edge stays where the flat tablet's was.
* **Side panel**: its left (hinge) edge is parallel to the tablet's right edge, and its right edge is turned 5 degrees toward the user (`side_yaw_degrees = -5`, pitch 0 so the edges stay parallel).
* **Face-level highlight** (`scripts/face_highlight.gd`, wired by `main.gd`/`controller.gd`): with Mates or Measure on, the laser lights only the face it is on, and picked faces stay lit (first cyan, second orange). Uses the backend glb's per-triangle `face_ids`; with no tool on, whole-part hover is unchanged. **Only faces are pickable client-side today**, so edge/vertex highlight needs edge/vertex picking first. The highlight is plain overlay geometry: it is not clipped by an active section plane.
* Tests: `tests/face_highlight.gd` (new, in `run_all.sh`); `tests/tablet_v2.gd` now aims along the tilted tablet's normal and checks tilt, watch position, side-panel edges and the ring/watch re-theme.

## 2026-10-02 — Old wrist tablet removed (John signed off the redesign after PCVR testing)

* Deleted `scripts/wrist_tablet.gd` (1842 lines) and `Main.use_new_tablet`; the redesigned tablet is renamed `scripts/ui/wrist_tablet.gd` (tests `tablet.gd`, `tablet_render.gd`). Audit first: the old tablet's external API (`setup`, `open_tablet`, `close_tablet`, `is_open`, `set_info`) is all on the new one.
* The 10 tests that were pinned to the old tablet were ported or unpinned, with a per-test table in `tests/README.md` ("Old-tablet removal"). Nothing the old tests guarded was dropped without a covering test.

## 2026-10-02 — Measure picks edges and vertices (cross-repo: DIDSA-CAD + VR)

Closes the plan's "edge and vertex picking" gap for Measure. Not yet felt in a headset.

* **DIDSA-CAD** (`backend/app/document/{mesh_data,mesh,mesh_export,router}.py`): the glb's per-primitive `extras` now also carry `topology` per Body: every real edge (polyline), every topology vertex and each face's boundary edge list, all keyed by the **raw `SubShapeRef.index`** (the `MapShapes` position the resolver uses). The flat app's dense edge ids skip degenerate edges, so they are NOT valid indices past a sphere pole or cone apex; `BodyTopology.edge_ref_indices` translates, with a test against the real resolver on a sphere. `?topology=false` opts out. Tests: `test_merged_body_mesh_data.py`, `test_assembly_mesh_glb.py`.
* **VR**: `mesh_identity.gd` converts the topology once at tag time; `topology_pick.gd` picks vertex > edge > face from the hit face's own boundary within an angular reach (capped by part size); `face_highlight.gd` draws a hover/picked edge as a thin tube and a vertex as a ball; `measure_tool.gd` sends EDGE/VERTEX SubShapeRefs; `controller.gd` ties them together. Mates stays face-only. Tests: `tests/topology_pick.gd` (real import path + real physics rays on a glb made by the CAD encoder, fixture `tests/fixtures/topology_box_cylinder.glb`), `tests/topology_render.gd`.
* **To tune in the headset**: the reach (`topology_pick.gd` `REACH_*`, `EDGE_REACH_FRACTION`) and the tube / ball size (`face_highlight.gd` `EDGE_RADIUS`, `VERTEX_RADIUS`). The glb grows by the topology JSON (the box+cylinder fixture is 15 KB); real-assembly size is unmeasured, and `?topology=false` is the lever if it is heavy.

## 2026-10-02 — Section planes clip the highlight; Mates picks edges and corners

* **Section clip.** The face / edge / vertex highlight now uses `shaders/highlight_clip.gdshader`, which reads the same global section-plane uniforms as `section_clip.gdshader`, so the highlight on the cut-away half of a part is cut away with it. `tests/highlight_clip_render.gd` (Xvfb) checks it; `face_highlight.gd` materials are `ShaderMaterial`s now.
* **Mates edges / corners.** The Mates tool picks what the solver can use: planar and cylindrical faces, straight and circular edges, corners (so Concentric between two hole rims works). DIDSA-CAD's topology extras gained edge `k` ("line" / "circle" / "other") and `face_kinds` ("plane" / "cylinder" / "other"); `topology_pick.gd` has a `mates_only` mode and `is_mateable`; `mates_tool.gd` sends EDGE / VERTEX refs and refuses an unusable surface with a reason; the backend's `unsupported_mate_geometry` now reads as "this mate type needs ...". **Verified against a real local backend** (`tests/e2e_edges.gd`): a CONCENTRIC mate between a circular edge on each of two parts is accepted; Measure of edges and vertices works; `e2e_measure`, `e2e_mates_motion`, `e2e_section`, `e2e_colour` still pass. Not yet in a headset.

## 2026-10-02 - Constrained drag F1b VR: headset benchmark result (NO-GO for wiring the GDScript solver)

Measured on a Quest 3 (flat 2D debug APK, headset worn 180 s): one local-retraction `frame()` costs p95 3.1 ms (k=1 and k=2), 7.8 ms (k=3, max 13 ms) against 0.56 ms p95 for the projector's frame; no thermal drift (+5 % over 3 minutes). Rule was p95 <= 1.5 ms: fails at every k; two iterations instead of three would save only ~25 %. Decision: VR keeps the projector; `scripts/motion/local_retraction.gd` stays as a tested, unwired port (golden vectors to 1e-9). Details and the table: `docs/local-retraction-benchmark.md`. Not measured: a real stereo VR session (this was a 2D app).

## 2026-10-02 - Constrained drag S9 (VR half): docs follow the CAD cleanup

DIDSA-CAD S9 (PR #276) removed the v0 `transform` / `free_twists` aliases from `mate-motion` and moved `quality.jump` / `max_step` into the screw chart; DIDSA-CAD F1b made the anchor the weighted-nearest pose. VR needed no code change (it never read the aliases; `tests/e2e_mates_motion.gd` already asserts that). Updated: `docs/backend-api-notes.md` (aliases gone, screw-chart `jump`/`max_step`, nearest-point anchors, the optional `constraint_model` / `reference` / `include_constraint_model` fields VR ignores, and why VR does not run the local retraction), `docs/constrained-drag-rollout.md` (S9 happened), and one comment in `scripts/mates_tool.gd`. **Ran:** `tests/run_all.sh` (Godot 4.7.2 headless, clean) and `tests/e2e_mates_motion.gd` against a throwaway local backend built from DIDSA-CAD `main` after S9 + F1b (PR #278 merge, b9f4290): every SMOKE line `true`, the 60-frame drag cost 6 requests, group follow, atomic commit and the `converged:false` hold all pass. **Not run:** a headset, a PCVR session.

## 2026-10-03 — Milestone 2: the design table (built; headless- and real-backend-confirmed, not yet on a headset)

Full write-up: [`docs/design-table.md`](design-table.md). The brief it started from is saved as `docs/design-table-brief.md`.

**What was built** (all in `scripts/design_table/` unless noted): a summonable console (slab, grab handle, deck, tree) reached from
Assembly → Table on the wrist tablet; putting a part on it by carrying it over the slab or from the tree, as a scaled **copy** (the
arena node stays put, hidden) that goes back to the arena at arena scale (see the follow-up below); plane picking on flat faces and the three reference planes; the
sketch sheet and Line / Rectangle / Circle / Arc / Polygon / Point; snapping with a toggle; the constraint tools; Dimension with values
typed on the existing numeric pad; Extrude (boss / cut / flip / depth), Fillet, Chamfer, with a fresh mesh put on the table copy and on
every placed instance of the part; Undo; stale-mates flags, badges and the **Enforce mates** button; Files → Save as new file. Shared
picking moved to `scripts/laser_pick.gd`; `FaceHighlight` gained `invalidate()` and a multi-edge set; `Main` gained `swap_part_mesh()`,
`save_native_snapshot()`.

**Things the code taught us that the brief didn't know** (each cost an hour if you hit it blind):
- A glb node's `owner_part_id` is the **assembly that holds the occurrence**, not the part it shows; the part is `resolved_part_id` on
  the owner's occurrences. The table looks it up (and refuses an assembly of parts).
- The backend names a mate's faces by **index**, and an edit **renumbers** them: a boss on a plate's top turned the mated "top" and
  "bottom" into the two side faces, and Enforce mates then "succeeded" while the stack stayed apart. The client now records what each
  mate's face looked like before the first edit, compares after every change (so Undo clears it), and Enforce **suppresses** a mate whose
  face changed instead of solving it. `mate_health.gd`; verified against the real solver in `tests/e2e_design_table_mates.gd`.
- **Godot reads every JSON number as a float.** Re-serialising a native file writes `rotation_quarter_turns: 0.0`, which the backend
  accepts and then crashes on when it renders. `open_native_file` and `add_component_file` did this (a latent bug for any file with
  sketches); they now send the file's own text, and saving writes the backend's own text with the flat app's extra keys appended.
- A mated part with enforced mates is steered by a live solve while carried, so it can't be carried to the table; relax mates, or use the
  tree's Table button. A part with stale mates is deliberately not steered.
- The backend's sketch `solve-and-refresh` points are the truth: the first real length dimension rescales the whole sketch about its first
  point, so nothing drawn stays where it was tapped.

**Tests added:** `design_table_logic`, `design_table_scene`, `sketch_session` (with `tests/helpers/fake_cad.gd`), `design_table_editing`,
`design_table_tree`, `design_table_mates`, `design_table_save`, `mate_health` (all in `run_all.sh`); local-only `e2e_design_table` and
`e2e_design_table_mates` (real backend, real solver); `design_table_render` (Xvfb PNGs) and `design_table_perf` (script timing).
The full headless suite and the existing real-backend e2e tests (`e2e_add_component`, `_mates`, `_measure`, `_assembly_tree`, `_colour`,
`_section`, `_backend`, `_edges`) pass.

**Quest 2:** still nothing measured anywhere. What exists is `tests/design_table_perf.gd`: the table costs about 0.06 ms of script per
frame with the laser on a part and 0.13-0.17 ms with it on a 150-entity sketch on a desktop (x3.7 for a Quest 3 = 0.2-0.6 ms of the 1.5 ms
rule), and redrawing that big a sketch takes ~5.5 ms (only when it changes). Rendering cost is unmeasured.

**Untested paths (add to the list above):** everything on a real headset (laser on the sheet, snap radius, label hit radius, console size
and tilt, the carry-over-and-let-go gesture, the lift, the Enforce button's placement); Quest 2 at all; a sketch of more than a few dozen
entities on a headset (redraw hitch); a mated assembly more than one level deep (only the top-level mates are checked and enforced); Save
on a Quest (the write location, `user://models`, is assumed to be writable and visible to the Files tab).

### 2026-10-03 (later) — Milestone 2, follow-up: handling the part on the table

John asked how a part is manipulated "on the table" (answer: it couldn't be, beyond the console handle and the automatic turn to a
sketch plane) and asked for: **grab to move, independent of the world; two-hand grab to rotate and scale, also independent of the
world**; plus the stick, A / B push-pull and a reset button; and a way to know you are "in the design table". Decisions (his answers):
engagement is **automatic with a clear tell**, and leaving is **carry it off the slab and let go**.

**Built** (`scripts/design_table/table_manip.gd`, `table_pose.gd`; hooks in `design_table.gd`, `controller.gd`, `two_hand_model.gd`,
`table_ui.gd`):
- A grip on the part now moves the table's **copy** (`try_grab`, replacing the old "grip lifts the real part out"); two grips turn and
  scale it (shortest-arc swing, spread ratio, clamped 0.4x-3x); the right stick spins and tips it; A / B push and pull it along the line
  from the hand, kept over the slab. The scale lives on the copy's pivot (`user_scale`), so the sheet, plane squares and drawing follow;
  the editor's snap / pick / label radii use `effective_scale()`. Nothing touches the real part, `assembly_root` or the world scale.
- **Engaged** (no button): a hand gripping the part, or the right laser within 1.4 x its bounding sphere or on the sketch sheet (never
  while the laser is on the deck). The frame glows, a TABLE ACTIVE chip shows on the deck, the right hand ticks on entering and
  leaving, and there is a 0.15 s grace so it doesn't flicker. While engaged the right stick and A / B are the table's:
  `controller.is_manipulating()` (so locomotion keeps off), and the selected-part stick / nudge code skips.
- A hand gripping the part carries a `table_part_held` meta so `two_hand_model.gd` doesn't also drag the world.
- **Leaving:** let go over the slab keeps it; let go beyond it sends the real part back to the arena where you let go (arena scale,
  original orientation, one undoable move, saved; the frame turns amber while you carry it past the slab); a part held by enforced mates
  goes back where it came from instead. Deck buttons **Reset** (centre, fitted size, sketch plane flat) and **To arena** (back exactly
  where it came from, no move recorded).
- Tests: `design_table_logic` (the pose maths), `design_table_scene` (rewritten lift section: move, two hands, clamp, engaged tell, stick,
  A / B, Reset, send back, To arena, close mid-grip).

**Not confirmed:** all of it on a headset. In particular the engaged threshold, the 90 deg/s stick rate and the A / B speed are guesses,
and whether a second grip "anywhere over the table" is picked up the way a person expects.

### 2026-10-03 (later still) — Milestone 2: glass slab with rounded corners, a border and drag-to-resize corners

John asked for the table to be glass with radii on the corners, a border, and a variable size with drag corners as the windows have.
- The slab (was an opaque box with four frame bars) is now one flat pane drawn by `shaders/table_glass.gdshader`: rounded corners
  (`slab_radius` 4.5 cm), a rim (`slab_border` 6 mm) and a soft inner glow from a signed-distance rounded box in metres, a clear middle with a faint sheen.
  The rim is the engaged / amber tell from before (shader `glow` and `border_color`).
- `table_resize.gd`: four arc-and-arm brackets hugging the rounded corners, hover claims the laser, trigger-drag resizes with the opposite corner fixed
  (the console's origin follows, as a window's does), clamped 0.5 x 0.3 .. 1.4 x 1.0 m. `design_table.gd: set_slab_size()` moves the handle, deck and tree.
- Because the slab is see-through now, the handle's halo (`ui_halo.gdshader`) gained a `hollow` switch so it glows around the slab, not over it.
- Not done: the deck stays 0.6 m wide whatever the slab's size; the size is not remembered between sessions. Not seen on a headset (rendered once in software).

### 2026-10-03 (evening) — Milestone 2: New assembly and New part

John asked whether the table could create a part and whether the arena could clear and start a new assembly (it could do neither). Built
(plan agreed first, then implemented): `scripts/design_table/new_document.gd` (backend sequences), `Main.new_assembly()` / `add_blank_part()` /
blank handling in `swap_part_mesh`, `design_table.new_part()` and blank-aware seating, Files > **New assembly** (two-press confirm), the tree's
**+** and the Table page's **New part**; STEP / STL / OBJ import now starts from `POST /document/new`. Choices: auto-named "Part N"; a part already on
the table goes back first. Tests: `tests/new_document.gd` (fake backend, in `run_all.sh`), `tests/e2e_new_part.gd` (real backend, passes, incl. export /
re-import in the flat app's bundle shape and "importing twice leaves one part"). Details and the compatibility reasoning: `docs/design-table.md`,
"Starting from nothing".

**Not confirmed:** on a headset (the + is an icon-only button in the tree header; whether it is discoverable enough); opening a VR-saved file in
the flat app's own UI. **Not built:** renaming a part, a part inside a sub-assembly, drawing on the root's own content.

### 2026-10-03 (night) — Milestone 2: the table's tree is the part's Build tree

John pointed out the tree beside the table was the assembly tree again; it should be the part's build tree, like the flat app's part design lens. Built:
the docked window has **Build | Parts** tabs (Parts = the old assembly list, kept for choosing a part); **Build** lists the part on the table's features in
order (`GET .../features`), named per type and count, with select-and-light-up, **Edit** (PATCH of an extrude's depth / fillet radius / chamfer distance, taken
back by Undo), **Delete** with cascade (two presses, names what goes), **Hide / Show** and **Roll back / forward** that change only the table's copy. Code:
`build_tree.gd` (pure), `table_build.gd` (state and actions), `table_tree_window.gd` (the view), `Main.mesh_from_glb` / `hidden_feature_ids`, the editor's
second filtered fetch and `Table.show_filtered_view`. **DIDSA-CAD changed** (branch `ccr-a6221403-yu10pq`): `assembly-mesh.glb` takes
`hidden_feature_ids` and `rollback_excluded_feature_ids` for the requested part; the real backend must be updated for hide / rollback to work (the rest works on
today's). Tests: `design_table_build_tree` (fake backend, in `run_all.sh`), `e2e_build_tree` (real backend with the CAD change: tree, edit and undo, hide, save,
roll back, cascade), pytest in DIDSA-CAD. Fixed on the way: the editor kept a stale `part_id` after the part left the table.

**Not confirmed:** headset feel (row and button size, the action strip in a 0.30 m window). **Not built:** reopening an existing sketch to change it, the
flat app's Planes / Surfaces / Curves sections, undo of a cascade delete.


### 2026-10-03 (later night) — Milestone 2.5: the first headset session's feedback, and the gaps closed

John tried the design table in a headset once and sent seven comments, and asked for the known gaps to be written down and closed too. The gap list with
IDs, what was done and what is left is **`docs/design-table-gaps.md`**; the behaviour is in `docs/design-table.md`. In short:

* **Feedback:** edges and **view modes** (Shaded / + edges / Wireframe, edges from the backend's real topology, `edge_overlay.gd`, `view_modes.gd`,
  `edge_lines.gdshader`); the sketch **stands up 60 degrees from the slab** (animated; the reading of "60" is an assumption to check, `sketch_tilt_degrees`); a
  **0.8 x 0.4 m gridded sheet** (`sketch_grid.gdshader`); the sketch **origin** is a real, snappable point; a **Select tool** (on by default) with a menu of what
  applies to the selection (`sketch_selection.gd`, ported from the flat app's selection matrix, plus Fix / Construction / Delete), **pan and zoom** by the existing
  grips with the sketch rules (locked tilt, release holds the part, the whole sheet is the grab zone, 8x, Part: Locked / Free, Fit); a **point on each slab corner**.
* **Work loss:** a dirty flag and a "save first" warning; VR's **own `X-Document-Session`** (a behaviour change: VR and the flat app no longer share a backend's
  document, they exchange files); saves say where they went; Hide / Roll back switch off on an older backend; stale-mate flags are saved (`vr_stale_mates`).
* **Editing:** an existing sketch reopens from the Build tree (Edit) with a **Done** button that rebuilds the part; **Revolve, Shell and Mirror** and a **Slot** sketch tool; rename a part; a
  part with no solids goes blank; a turned-off mate can be **remade** on the equivalent face.
* **Table handling:** slab size remembered, deck width follows the slab, zoom limit and send-back orientation are settings, one-hand wrist turn (left stick modifier).
* **Tests:** new `view_modes`, `work_loss`, `table_handling` (in `run_all.sh`), and local-only `e2e_sketch_select`, `e2e_revolve`, `e2e_features`; `e2e_build_tree` and
  `e2e_design_table_mates` extended. The sketch tests found nothing wrong in the backend; one thing worth knowing: a sketch with redundant constraints (horizontal +
  vertical + perpendicular on the same lines) can make later solves report non-convergence, which the session answers by taking the new constraint back out.
* **Not done:** sub-assemblies (G14 / G16), carrying a mated part (G15), Pattern / Sweep / Loft / booleans / Ellipse, Spline, Text, Trim, Offset, a feature preview, redo, the Planes /
  Surfaces / Curves tree sections. **Not verified:** all of it in a headset; the open numbers are listed in `docs/design-table-gaps.md`.

### 2026-10-03 (later night, again) — Sketches look like engineering drawings

John pointed out that the yellow dimension text in a screenshot did not resemble a drawing dimension, and that construction lines (a polygon's, perhaps others') looked solid.
Both were true: dimensions were a bare billboard label on the geometry with no leaders, arrows or extension lines, and construction lines (flagged by the backend on a polygon's
centre-to-corner lines, a rectangle's diagonals, a slot's centre line) were only a dimmer colour. Now: object lines heavy and solid, construction lines thin and in a chain pattern,
a centre mark on every circle, and dimensions drawn with extension lines, a dimension line on the side with room (`dimension_layout.gd`, pure, unit-tested), arrowheads, and the value
lying along the line in the sketch plane; radius leaders, diameter lines and angle arcs; the candidate dimensions use the same graphics in yellow. A polygon's own corner angles and
a circle's own structural constraints (zero distances) are no longer drawn as dimensions. Checked in a software render (`tests/sketch_style_render.gd`), not in a headset: text size,
line weights and arrow size are in world metres and are the numbers to tune after one look (`LABEL_FONT`, `OBJECT_WIDTH`, `ARROW_LENGTH`, `DIM_OFFSET` in `sketch_view.gd`).

### 2026-10-04 — The sketch window is fixed; the part and its sketch pan and zoom under it

John asked for the canvas to pan and zoom within the canvas sub-window, and then pointed out that the model geometry has to move and zoom with it: sketches are dimensioned to and from
existing edges and vertices. A first attempt gave the sketch its own pan and zoom, independent of the part; that broke exactly that registration (the part's corners stopped being snap
targets) and was replaced the same day. Now the sketch stays a child of the part (sketch mm = part mm, always), and the **sketch window** is the thing that is fixed: a 0.8 x 0.4 m
rectangle in the sketch plane anchored in the console when the sketch opens (`window_anchor`), which the part slides and scales under. With Part: Locked one grip slides the part along the
plane (`pin_sketch_plane` takes any off-plane movement back out), two hands zoom it about their midpoint (1/50 to 200x while sketching), nothing turns. `sketch_view.gd` is told each frame which
sketch spot is at the window's middle and the part's scale (`set_frame`), re-sizes and re-grids the window, and clips the drawing to it with `sketch_lines.gdshader`; only a change of scale rebuilds the
drawing. Fit slides and zooms the part so the sketch fills the window. Not done: clipping the part's own mesh to the window (zoomed right in it fills the room), see `docs/design-table-gaps.md`.
Tests in `design_table_editing.gd` (the window stays put while the part slides / zooms, in-plane only, no turn, A / B cannot lift it off the plane, Fit, Free, Reset) and `design_table_logic.gd`; pictures
from `sketch_style_render.gd`. `e2e_new_part.gd` had been failing since the unsaved-changes warning (G1) and now clears the dirty flag before the second New assembly. Not verified in a headset: how the
grips feel.

### 2026-10-06 — The part's own corners and edges are references: dimension straight to them

John said dimensioning to part geometry felt clunky (convert, fix, set as construction, then dimension) and asked how SolidWorks makes it seamless and whether upstream
changes are followed as reliably. The design table now treats the part's vertices and straight edges, projected onto the sketch plane, as reference geometry
(`part_references.gd`: pure, grid-indexed, tested on the fixture; drawn quietly under the sketch with a dark underlay and shown over the part, because the sketch plane is often
inside it). Any tool snaps to a corner; Select, Dimension and the constraint tools pick a corner or a straight edge; the session makes the pinned point or construction line in the same
tap with the existing `convert-entities/vertex` route (idempotent; an edge is two such points and a construction line, reused if there), and a dimension between a pinned thing and one of the
sketch's own is offered as usual (nothing is offered between two pinned things). No backend change was needed. Checked with the fake backend (`design_table_references.gd`) and against the real one
(`e2e_references.gd`: a line from a top-face corner, a 12 mm distance to a picked edge, then the base made 30 mm wider: the pinned corner follows, the dimension holds, nothing flagged).
**Robustness finding (backend):** references are body id plus a raw OCCT vertex index; edits that keep the topology are followed, but a topology change renumbers the vertices and the reference
silently binds to a different corner (5 of 7 probes), unflagged. Recorded as R2 in `docs/design-table-gaps.md` with the fix (geometric signature, then OCCT history); not started. The earlier
canvas work was also reworked the same day: the sketch window is fixed in the world and the part and its sketch slide and zoom together under it (see the entry above).

### 2026-10-06 (Session B) — The part is clipped to the sketch window; holes, midpoints and driven dimensions; references for hidden / rolled-back parts and reopened sketches; lost and moved references shown

Session B of `docs/handover-references-overhaul.md`, after Session A's backend landed (DIDSA-CAD `ccr-c5e04801-z93yio`, merged). Worked in this repo only; the throwaway backend was DIDSA-CAD's current code (uvicorn from the existing `didsa-backend` env). Nothing here has been seen in a headset.

* **Clip to the sketch window.** `scripts/design_table/sketch_clip.gd` cuts the table's copy, its edge lines and its hover / selection overlays to a box (the window rectangle in the sketch plane, `DEPTH_M` 0.25 m either side, `MARGIN_M` 0) while a sketch is open. It is the section tool's mechanism, generalised: `shaders/clip_common.gdshaderinc` (included by `section_clip`, `edge_lines` and `highlight_clip`) holds the section plane and the window box as global uniforms plus a per-material `window_clip` switch, so the arena's parts are never clipped; `scripts/clip_globals.gd` registers the globals once (the section tool, view modes and highlights all call it; `RenderingServer.global_shader_parameter_get_list` is editor-only). The copy's materials are wrapped (a flat colour override, or the glTF surfaces' own albedo per surface) and put back on `end()`; view modes act on nodes (`layers`, the `EdgeLines` child), so wireframe and edges keep working; `view_modes.gd` picks the switched-on line material for a part with the `window_clip` meta and `face_highlight.gd` duplicates its material switched on. Found on the way: `has_meta` was used where the value was meant, so an overlay built before the clip began was never clipped (caught by the real-pipeline picture, now pinned in `tests/sketch_clip.gd`). Tests: `sketch_clip` (headless, in `run_all.sh`), `sketch_clip_render` (Xvfb: pixels inside the box lit, outside background, the arena part whole, the box moves, the edge lines, `end()`), `sketch_clip_picture` (real part zoomed 120x, before / after pictures). `view_modes.gd` test line updated (the shader code now includes the shared file).
* **More reference kinds.** `part_references.gd` finds circular edges in the sketch plane (a fit through three points of the polyline; whole circle or arc; `COPLANAR_MM` 0.001, the backend's own tolerance is 1e-4); `snap_resolver.gd` has snap kinds "centre", "edge_midpoint" and "edge_point"; `sketch_session.gd: ensure_reference` makes a pinned construction circle / arc with `convert-entities/edge` (the centre is the backend's live `circle_centre` reference since Session A, so **no backend change was needed**; the route is not idempotent, so the answer is remembered and read back from `GET .../external-references` when the sketch is reopened: `load_references`), and `_point_on_reference` makes the new point on a pinned line / circle with `at_midpoint` / `point_on_line` / `point_on_circle` (taken straight back out if the solver does not accept it). **Driven dimensions:** between pinned things the candidates are marked driven; keeping one is local to the editor (the backend has no driven constraint), drawn in brackets in a quiet colour. Tests: `design_table_references_more` (fake backend, in `run_all.sh`), `e2e_references_more` (real backend). **Backend finding (open item 2 in the gaps file):** `at_midpoint` is refused in a sketch that already holds a converted hole (the solver reports `result_code` 5 as soon as the converted circle is there, probably because it is Fixed *and* keeps its radius constraint, and `converged` is distrusted for any constraint outside its allowlist, which `at_midpoint` is); `point_on_line` is fine.
* **Hidden / rolled-back parts and reopened sketches.** `table_editor.gd: _load_references` uses the copy's own topology when the sketch is the last feature and nothing is hidden or rolled back, and otherwise fetches the part with `rollback_excluded_feature_ids` for everything after the sketch (and nothing hidden: the backend ignores hiding) and uses only that topology; the picture on the table is untouched. Tests in `design_table_references_more` and `e2e_references_history`.
* **Lost and moved references.** `BuildTree.reference_note` / `reference_counts` (sketches count point ids, other features reference paths) put a note on the Build row and `table_build.gd` says it once in the status line; `sketch_session.gd` has `reference_rows` (from `load_references`), `reference_status`, `flagged_references`, `reference_warning`, `reattach` and `confirm_reference`; the sketch view marks flagged points red / amber; with nothing picked Select's options row offers **Fix** (walks the flagged points, point at the replacement corner or hole centre, one `reattach` call) and **Keep moved ones** (`confirm`). `tests/e2e_references_lost.gd` moves a fillet to another edge against the real backend: away from the corner the reference follows, onto it the backend flags it lost (`consumed_by_<fillet>`), the table shows it and the re-pick mends it. (An arc made from the fillet's own rim is correctly flagged lost when the fillet moves; that is also what the first draft of that test found.)
* **Suite:** `tests/run_all.sh` now includes `sketch_clip` and `design_table_references_more`; it ran without script errors and with the same "false" lines as before (one line that looked for `section_enabled` in the edge shader was updated). Run by hand against the local backend: `e2e_references`, `e2e_references_more`, `e2e_references_lost`, `e2e_references_history`, plus `sketch_clip_render` and `sketch_clip_picture` under Xvfb.
* **Not verified:** all of it in a headset (the clip depth, the flagged colours, the reference weights, how the cut looks); a Quest's compatibility renderer (the software renders here used OpenGL 3 through Xvfb; the project's own renderer is Mobile, and global uniforms are used the same way as the section tool's).

### 2026-10-08 — Implementation plan (`docs/implementation-plan.md`): Step 0 baseline, Phase 1 (R-A, R-E)

Worked by one implementing session on `ccr-b3b16f97-0i1850` in both repos (DIDSA-VR and DIDSA-CAD), Godot 4.7.2, no headset. Everything below is headless, software-rendered (Xvfb + llvmpipe) or against a throwaway real backend; nothing is headset-verified and nothing says how it feels.

**Step 0: environment and baseline (before any change)**

| What | How | Result |
|---|---|---|
| Godot 4.7.2 | release zip from GitHub, `Godot_v4.7.2-stable_linux.x86_64` | installed outside the repo |
| VR headless suite | `tests/ci.sh` | exit 0, check_smoke 0 failures (1583 SMOKE lines) |
| VR render suite | `tests/ci_render.sh` | 18 SMOKE lines, 0 failures, 0 warnings |
| Backend env | micromamba (the conda-forge package, `micro.mamba.pm` is blocked) + `backend/environment.yml`: pythonocc-core 7.9.3, py-slvs 1.0.6 | works |
| Backend pytest baseline | `pytest -n 4 -m "not gears"` (the gear / bevel / planetary suites are slow and untouched by this work, so not run) | 2268 passed |
| Real-backend e2e | throwaway uvicorn on 127.0.0.1:8000 from the DIDSA-CAD working tree + gitignored `secrets.cfg` | runs |
| Flutter | SDK `master` channel (the repo's `pubspec.lock` needs Dart 3.13 / Flutter 3.44+; stable 3.27 cannot resolve the lock) cloned from GitHub | see the Phase 2 / 3 entries for whether the widget tests ran |
| "Before" images of the old options row | `tests/dock_panels_render.gd` with `DOCK_MODE=before` | Extrude, Fillet, Mirror saved |

One environment trap: the backend tests must run with `CAD_API_KEY` **unset** (the test conftest sets its own); with it set every route answers 401.

**Phase 1 (R-A, R-E), done**

* **At-midpoint next to a converted hole (R-A).** Reproduced first in `backend/tests/test_reference_convert_edge_robustness.py` (a plate with a hole; the rim and a straight edge converted as construction; an `at_midpoint` on the pinned line: `converged: false`, the new constraint blamed). Cause, found by dropping constraints one by one: py-slvs reports `result_code` 5 (redundancy) for a converted circle because (1) its radius `DistanceConstraint` and cardinal-point constraints only relate points that are all pinned, and (2) `add_fixed_constraint` listed the radius point twice (it is also the East cardinal point). The backend then trusted `converged` only through an allowlist that happened to apply because the circle's `EqualRadius` constraints were present, and `at_midpoint` is not on it. Fix (DIDSA-CAD `router.py`, `models.py`): `convert-entities/edge` drops those redundant constraints for a pinned Circle / Arc (`_drop_constraints_between_pinned_points`) and `add_fixed_constraint` fixes each point once. The sketch now solves with `result_code` 0.
* **Idempotent `convert-entities/edge` (R-E).** A second call for the same rim / arc / straight edge answers with the entity already made. pytest for the circle and the line.
* **VR.** `tests/e2e_references_more.gd` now expects the at-midpoint **held and solved** in the sketch that holds the converted hole (run against the real backend: passes). The take-back path in `sketch_session.gd: _point_on_reference` stays as a safety net for a real solver refusal. The remembered-answer workaround (`_ref_circles`) is gone from `sketch_session.gd`; `_ensure_circle` just asks the route again. `tests/helpers/fake_cad.gd` is idempotent per edge too and no longer makes the radius constraint the real route no longer makes.
* **Ran:** backend `test_reference_convert_edge_robustness.py` (3 new tests; the first two failed before the fix), the existing convert / circle-centre / reference-identity files, then the full non-gear backend suite (2271 passed); VR `e2e_references_more.gd` against the real backend (all true); VR headless suite (exit 0).

### 2026-10-08 — Phase 2 (R-C): silent, robust references

Backend (DIDSA-CAD `ccr-b3b16f97-0i1850`) and VR and flat app, one pass.

* **2.1 The flag.** `convert-entities/vertex` and `/edge` take `reference: true`. What they make (Points, Line / Circle / Arc) goes in `Sketch.reference_ids`, comes back as `is_reference` on the Point / Line / Circle / Arc responses and as `reference_ids` in the sketch export and the native file (additive; an old file has none, an old client ignores it). An ordinary convert (the flat app's Convert Entities) takes a helper over as real geometry; a reference convert of something already real does not make it a helper. Strict-equality backend tests that pinned the exact `PointResponse` shape were updated for the new field (`test_stage2_sketch.py`, two lines).
* **2.2 Faces.** `POST .../convert-entities/face` (`app/document/face_reference.py`): a flat face square to the sketch plane is a pinned construction line between its two extreme corners (live vertex references, idempotent); a cylinder / cone / torus whose axis is square to it is a live `circle_centre` reference of one of its own circular edges, so a **blind hole** (rim not in the plane) has a centre. Structured 422s: `face_not_perpendicular`, `face_axis_not_perpendicular`, `unsupported_face`, `face_has_no_circular_edge`, `degenerate_face`. Tests: `backend/tests/test_reference_helpers.py` (15, real OCCT), including the centre following a moved hole and a hole that is gone (flagged, or still on the axis, never elsewhere).
* **2.3 Clean-up.** `Sketch.prune_unused_reference_helpers` runs after a constraint or any entity is deleted (a FastAPI dependency on every sketch DELETE route, plus explicitly in the constraint route): a flagged shape no outside constraint reaches and no real shape stands on goes, then the flagged points nothing holds. A sketch with no helpers is untouched. Tests prove it keeps a helper while another constraint or a real line uses it and removes it with the last.
* **2.4 Flat app (Flutter master channel, ran).** DTOs carry `isReference`; `convertBodyVertex/Edge` take `reference`; `convertBodyFace` and `SketchController.ensureReferenceFace` are new; the controller keeps `_referenceIds`, `isReferenceHelper`, excludes helper lines / circles / arcs from hit-testing and a helper point from deletion; the 2D canvas draws helpers in the quiet reference colour with no handles and the 3D viewport (`part_screen.dart`) leaves them out, so the two renderings agree. Widget / controller tests (`sketch_controller_test.dart`, +5). **Not done in the flat app:** a picking UI for faces (the ghost-face geometry is not wired to `ensureReferenceFace`).
* **2.5 VR.** `sketch_session.gd`: `reference_ids` from the state / export, `is_reference()`, `ensure_reference` makes every reference with `reference: true` (a straight edge is now ONE `convert-entities/edge` call instead of two vertex converts plus a line, so a failure leaves nothing half made), new kinds `face_line` / `face_axis`, helpers are skipped by `nearest_entity`. `part_references.gd`: `faces` read from each face's boundary edges, `nearest_face_axis`, `nearest_face_line`, `pick` falls back to a face. `snap_resolver.gd`: a `face_axis` snap kind; session helpers are not snapped to as points (the part's own corner is). `sketch_view.gd`: helpers are drawn in `REF_USED_COLOUR`, thin, no dots. `table_editor.gd`: a part corner or hole centre beats a sketch line the laser is also on ("a point beats a line it is on", now that the helper point is hidden).
* **2.6 Robustness bars.** (1) follows or flags after an upstream edit: backend `test_reference_identity.py`, `test_circle_centre_reference.py`, `test_reference_helpers.py`, VR `e2e_references_lost.gd`, `e2e_references_face.gd` (the hole moved, the live centre followed). (2) no duplicates: idempotent routes (backend tests), `design_table_reference_robustness.gd`, `e2e_references_face.gd`. (3) save / reopen: backend native round trip (`reference_ids` survives; an old file loads), `e2e_references_face.gd` closes and reopens the sketch; the flat app opening a VR-saved file is **not run** (no flat-app UI session). (4) no orphans, Undo: backend prune tests, `design_table_reference_robustness.gd`, `e2e_references_face.gd`. (5) failed reference leaves nothing: `design_table_reference_robustness.gd` (refused face, vertex, rim, edge), backend 422 test. (6) hidden / rolled-back / reopened earlier sketches: the existing `e2e_references_history.gd` stays green.
* **GODOT GATE A.** Headless suite: 1607 SMOKE lines, 0 failures. `tests/ci_render.sh`: see the Gate A line below. `tests/references_render.gd` now makes a silent reference dimension (hole centre to the part's edge, both picked as the part's own geometry) and checks in a software render that the edge under the helper is the quiet blue with no sketch line drawn over it. The cut in that render test was going the wrong way (it never made the hole); fixed with Flip.
* **Verified how:** backend pytest (real OCCT); VR headless with the fake backend; VR against the throwaway real backend (`ci_e2e.sh`: 12 files, 178 SMOKE lines, all as expected after `e2e_references_more.gd` was adapted to helpers being unselectable); software render (Xvfb, llvmpipe); Flutter analyze + `sketch_controller_test.dart`. **Not verified:** a headset, Quest performance of `_build_faces` (it walks the faces' boundary edges once per sketch open; unmeasured on a large part), the flat app's UI on a device.

### 2026-10-08 — Phase 3 (R-B): persistent reference dimensions

* **3.1 Backend.** `Sketch.reference_dimensions` (`app/sketch/reference_dimensions.py`): `{id, kind (distance | horizontal | vertical | radius | diameter | angle), refs}`, the entities being Points, Lines, Circles or Arcs; the value is calculated on read (distance of two points, a point and a line, a line's length, two parallel lines; the x / y extent; radius / diameter; the angle between two lines), so it follows the part, and `None` where the geometry has no such value. Routes `POST / GET / PATCH / DELETE /sketch/sketches/{id}/reference-dimensions`, an identical dimension twice is one, nonsense is a 400 with a reason; the values come in the `solve-and-refresh` bundle (`reference_dimensions`), the sketch export and the native file (additive: an old file has none, an old client ignores it; **the solver is untouched**). A reference helper a dimension measures is kept by the clean-up and freed when the dimension is deleted. A dimension whose entity was deleted is dropped on read. Tests `backend/tests/test_reference_dimensions.py` (11, real OCCT where a part is involved): each kind, refusals, idempotence, edit / delete, the bundle, no effect on the solver (dof unchanged), save / open of the sketch and of the document, the value following an upstream edit, the helper kept and then freed, a blind hole's axis to an edge following the hole.
* **3.2 Flat app (Flutter, ran).** `ReferenceDimensionDto`, `listReferenceDimensions` / `createReferenceDimension` / `deleteReferenceDimension`, the values from every solve; `SketchController.referenceDimensions`, `referenceDimensionKinds` (what the current Dimension picks can make), `addReferenceDimension`, `deleteReferenceDimension`, `referenceDimensionLabels`; the 2D canvas draws a thin leader and the bracketed value, the 3D overlay a new `ReferenceDimensionItem` (not a tap target); the Dimension bar shows chips to add one for the current picks and to remove each existing one. Tests: `sketch_controller_test.dart` (+2 for dimensions, +5 earlier), `sketch_reference_dimension_overlay_test.dart` (3). The full Flutter suite was run once after phase 2 (2565 tests passed) and `sketch_controller_test.dart` plus the overlay test after this.
* **3.3 VR.** `sketch_session.gd`: `driven` (editor-only) is replaced by `ref_dims` (the backend's list, brought by every solve); `keep_driven` posts to the new route (async now) and Undo deletes; `driven_items()` draws from the backend's value in `dimension_layout.gd`'s existing specs (`dimension_layout.gd` itself is unchanged). The fake backend has the routes (and a coarse clean-up).
* **GODOT GATE B.** Headless suite and `tests/references_render.gd` (the sketch with the hole centre dimensioned to the edge, `(30)`), see the end-of-phase line below.
* **Not run:** the flat app's UI opening a VR-saved file (no device); only the controller / widget tests and the backend's native round trip stand for it. A reference dimension of a line's x / y extent can be made by the flat app / API but VR offers none (its candidates are the existing ghost keys).

### 2026-10-08 — Phase 4 (R-D): re-attach for every feature

* **4.1 Backend (DIDSA-CAD).** PATCH on the fillet / chamfer / shell / mirror / pattern feature routes accepts a new `edge_refs` / `faces_to_remove` / `mirror_plane` / `face_refs` / `edge_ref` and, on success, clears the feature's lost / moved flags (`test_reference_reattach_features.py`, 8 tests, real OCCT). New route `.../external-references/reattach-edge` re-picks both ends of a sketch edge reference in one call. Not tested: Pattern re-attach, and a feature flagged by a real upstream edit (the tests flag it by deleting the referenced geometry).
* **4.2 VR Fix for flagged non-sketch features.** `BuildTree.fix_target` / `fix_payload` say which slot of a feature a Fix pick fills (lost paths first); `TableEditor.begin_fix` rolls the part back to what the feature saw, a pick fills the slot, Apply PATCHes the feature with the kept and the new reference; a PATCH the backend refuses keeps fix mode and says why. Tests: `design_table_fix_references.gd` (fake backend, all true), `e2e_references_fix_feature.gd` (real backend, in `e2e_ci_list.txt`).
* **Not done:** VR does not yet call the new `reattach-edge` route (sketch re-attach is still one corner at a time there); the flat app has neither it nor a face picker for Fix.
* **Verified how:** headless suite 1626 SMOKE lines, 0 failures; backend `test_reference_reattach_features.py` 8 passed; e2e against the throwaway real backend: 16 files, 364 SMOKE lines, 0 failures. No headset.
