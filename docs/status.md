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

## Milestone 4 — assembly environment (mates, colours, sections, measurements): mates, colours and sections built; measurements not started

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
- **The Colours tab has the same gap** — `colour_tool.gd`'s logic is
  headless- and real-backend-confirmed, but the swatch grid itself (colour
  legibility against the panel background, whether the text-colour contrast
  pick actually reads well, tapping a swatch with a real laser) has never
  been rendered or clicked for real.
- **The Sections tab has the same gap, plus one more layer.** Beyond the
  usual "never clicked by a real laser" gap every tab in this milestone
  shares: the clip plane's own real-render behaviour is confirmed correct in
  a flat, software-rendered image (`tests/section_render.gd`, Xvfb + Mesa
  llvmpipe), but never in stereo, at real depth, or lit by anything beyond
  one plain directional light — whether a real cutaway reads correctly with
  both eyes, and whether grabbing a thin translucent disc feels natural with
  a real hand (a part has real volume to reach into; this gizmo doesn't),
  are both open. The default gizmo size (`plane_radius`, a fixed 0.4 m) and
  spawn distance (0.6 m in front of the camera) were picked as reasonable
  human-scale guesses, never checked against a real arm's reach.
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
  conclude it's stuck before that.
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
  Tools-tab, full-scene tablet, mesh-identity, mates-tool, colour-tool,
  section-tool and section-tab tests). `tests/README.md` lists the expected
  values. Needs no GPU, headset or backend.
- **`tests/e2e_*.gd` are the exceptions** (`e2e_backend.gd`, `e2e_step_import.gd`,
  `e2e_mates.gd`, `e2e_colour.gd`, `e2e_section.gd`): each deliberately points
  `main.secrets_file_path` at the real `secrets.cfg` and drives real network
  calls against a running backend, using the tracked `assembly.didsa`. Run
  them manually once your backend is up; none are part of `run_all.sh`.
  `e2e_backend.gd` confirmed once from the cloud sandbox: 3 parts, import
  21 ms, download 83 ms (47 KB glb), parse 2–3 ms, ~130 ms wall clock from
  instantiating the scene to "Loaded" — the first time this path was
  exercised outside John's own machine. `e2e_mates.gd`/`e2e_colour.gd`/
  `e2e_section.gd` are milestone 4's own real-backend confirmations (see
  that section above) — `e2e_section.gd` doesn't confirm a new endpoint
  (Sections calls none) but confirms `section_tool.gd`'s wrap/grab/unwrap
  pipeline against real backend-sourced parts and materials, not just a
  synthetic stand-in.
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

**Resolved this session, but only in the live Claude Docs artifact — this
repo's own `docs/vision-brief.md` export was only re-synced for the Mates
cross-compatibility note below, not the two Milestones-table rewordings.**
The export is a point-in-time snapshot by design ("re-export after any
significant change" per its own header), so its Milestones table still
reads exactly as it did before this session for milestone 1 and milestone
4's own "Done when" cells — re-export it (or hand-edit those two rows to
match) next time it's touched, so a future reader of the export alone
doesn't see stale milestone status. Kept here as the record of what
drifted and when, since it can drift again the same way.

- **Milestone 1.** The live doc's milestone table used to say whole-model
  two-hand rotate/scale and scale views were open. Both were built, and so
  was STEP/OBJ/STL import since. Live doc now says: "Done except for
  measuring it on real Quest hardware. Native import, STEP/OBJ/STL import,
  individual part manipulation (proximity grab, and trigger-laser select
  with thumbstick rotate / A-B nudge), user movement (walk, snap-turn,
  teleport), whole-model one/two-hand movement (drag, turn, scale), scale
  views (presets, lock, Fit, Home), the wrist tablet (Modes, Scale, Tools,
  Files, Perf, Undo/Redo), the popup keyboard, and local glb import (no
  backend round-trip) are all built and running — the only thing left is
  measuring performance on a real Quest headset (everything so far has been
  PCVR via Virtual Desktop), not more building."
- **Mates cross-compatibility note.** The "Mates workflow" section's note
  (added 27 Sep 2026) that VR mates must be readable/editable in DIDSA-CAD's
  flat app and vice versa — John's own requirement, added ahead of the mates
  work itself so it wouldn't be missed when that phase started — had only
  ever made it into this repo's own export, not the live doc. Now in both.
- **Milestone 4 progress.** The milestones table's row 4 ("Assembly
  environment... Parts move individually; mates, colours, sections and
  measurements work") now says: "In progress. Parts move individually
  (built since milestone 1). Mates (face-only picking, a real client to
  DIDSA-CAD's own Mate create/solve endpoints — a mate authored in VR is
  readable and editable in the flat app and vice versa), Colours (a real
  client to the existing occurrence-colour PATCH endpoint) and Sections
  (client-side only: a grabbable clip-plane gizmo; the backend's own
  section-preview endpoint re-tessellates a fresh OCCT boolean on every
  call, too slow for a plane dragged at 90 Hz) are built — confirmed
  headless and against a real backend, not yet on a real headset.
  Measurements hasn't been started." Sections' interaction was this
  session's own design call — the vision brief itself never specified one,
  unlike Mates' own spelled-out workflow (see the "Milestone 4" section
  above for the full reasoning).
