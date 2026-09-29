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

## Untested paths

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
  backend.
- **`tests/e2e_*.gd` are the exceptions** (`e2e_backend.gd`, `e2e_step_import.gd`,
  `e2e_mates.gd`, `e2e_colour.gd`, `e2e_colour_group.gd`, `e2e_section.gd`,
  `e2e_add_component.gd`, `e2e_measure.gd`): each deliberately points
  `main.secrets_file_path` at the real `secrets.cfg` and drives real network
  calls against a running backend, using the tracked `assembly.didsa` (or,
  for `e2e_add_component.gd`, two throwaway Parts it creates itself).
  Run them manually once your backend is up; none are part of `run_all.sh`.
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
  up moved it down. Now `_nudge_towards_hand()`: the hand→part direction eases
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
