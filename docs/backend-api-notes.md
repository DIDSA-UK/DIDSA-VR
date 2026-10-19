# Backend API notes (for the VR client)

Working notes from reading `DIDSA-CAD`'s backend source directly
(`github.com/DIDSA-UK/DIDSA-CAD`, `main` branch) while building this client.
Treat this as a starting map, not gospel — re-read the actual source
(paths given below) before relying on anything here for new work, especially
the parts marked unverified.

## Base URL and routing

All endpoints used so far live under the `/document` prefix:
`backend/app/document/router.py`:
```python
router = APIRouter(prefix="/document", tags=["document"], dependencies=[Depends(bind_session_id)])
```
So the real path is `{backend_url}/document/parts/...`, not `{backend_url}/parts/...`.

## Sessions

The backend is stateless per `X-Document-Session` header — an in-memory
`Document` store per session id (`backend/app/document/store.py`). With no
header sent, requests land in a fixed default session:
`backend/app/session_context.py`:
```python
DEFAULT_SESSION_ID = "default"
```
This client sends no `X-Document-Session` header on any call, so import and
mesh-fetch both land in `"default"` — consistent with each other, but a
*different* session than whatever the Flutter app is using if it's open at
the same time (it sets its own session id per launch).

## Native format (`.didsa` / `.DIDSAprt`)

One file = one `Part` (`id`, `name`, `features`, `occurrences`, `mates`,
`component_patterns`, ...). Export/import logic:
`backend/app/document/native_format.py` (`export_native()` /
`import_native()`). Exported JSON shape:
```json
{
  "schema_version": 1,
  "document": {
    "id": "...",
    "root_part_id": "...",
    "parts": [
      {"id": "...", "occurrences": [{"resolved_part_id": "...", "external_ref": null}], "...": "..."}
    ]
  },
  "sketches": [...]
}
```
`POST /document/import/native` does a full-replace import of this payload
into the current session's Document store. `document.root_part_id` is the
part id to then fetch a mesh for — no separate lookup needed.

**Units: millimetres.** Confirmed via `backend/app/document/models.py`'s
`Mate` docstring ("`value` is the distance (mm)"). No unit conversion
happens anywhere before glTF export (checked `mesh_export.py` / `mesh_data.py`
for conversion code — there is none). A raw glTF coordinate is 1 metre by
spec, so **the VR client must scale the loaded scene by 0.001** or everything
renders ~1000x too large. See `main.gd`'s `spawn_scale`.

**Up-axis: Y-up, matching glTF and Godot — no correction needed.**
`mesh_export.py` writes vertices straight through, `(x, y, z) -> (x, y, z)`,
with no axis remap of any kind — so whatever "up" means in the backend's own
native coordinate system is exactly what a client sees. Confirmed from
DIDSA-CAD's own history (`docs/status.md` there, 2026-07-08 entries): "this
app's camera and backend both already use Y-up, matching glTF's spec" — the
mirroring bug investigated that day turned out to be a specific *imported*
file (from Blender) that itself wasn't correctly Y-up internally, not a
backend/glTF mismatch. Practical effect for this client: any future "standard
views" (front/top/right) can just use Godot's own Y-up axes directly against
a loaded assembly-mesh.glb — no axis-swap step needed first.

## Add a component to the live session (without a full-replace import)

```
POST /document/parts/{root_part_id}/add-component
```
(`backend/app/document/router.py`'s `add_component`, logic in the new
`backend/app/document/add_component.py`)

Built this session to close the gap `docs/status.md`'s "Real-headset testing
round 2" flagged as blocking Mates testing: `POST /import/native` is a
**full replace** — there was no way, once a file was loaded, to open a
*different* file or add a second Part to the one already loaded, so there
was nothing with real placed Occurrences to mate against beyond whatever
single file happened to load at startup. This endpoint is the backend port
of the Flutter client's own `client/lib/assembly/add_component.dart::
mergeComponentIntoDocument` — same merge semantics, same "first Occurrence
gets `fixed=true`" grounding rule — so both clients behave identically, but
callable directly against the live session instead of requiring a client
that can run that Dart code.

Request body:
```json
{
  "component": { "schema_version": 1, "document": {"id": "...", "parts": [...]}, "sketches": [...] },
  "occurrence_id": null,
  "external_ref": null,
  "name_override": null
}
```
`component` is another native file's own already-`export_native`-shaped
payload (read a local file, same as any other native load — this backend
still has no filesystem access of its own, decision #6 in DIDSA-CAD's
`docs/assembly-scope.md` unchanged). `occurrence_id` is optional — leave it
out and the backend mints one (a plain `uuid4`), handed back in the
response so the caller can address the new Occurrence right away (e.g. to
give it a first Mate). Response:
```json
{"document_id": "...", "part_ids": ["...", "..."], "occurrence_id": "..."}
```
404s if `root_part_id` isn't a Part in the current session; 422s for a
schema-version mismatch, an empty/malformed component file, or inserting a
Part into itself.

**What this does and doesn't solve.** This only merges an already-fetched
payload into the *current session's* in-memory Document — it never touches
a filesystem or resolves a path itself. It does **not** implement the
still-unscoped "shared network storage + server-side assembly composition"
item in DIDSA-CAD's `docs/roadmap.md` ("Other open items") — that's a
bigger, separate architecture question (a mounted network share, which
supersedes `docs/assembly-scope.md` decisions #4/#6) this endpoint
deliberately sidesteps. What it *does* give this client: a real, in-VR way
to open a second file and place it as a component of whatever's already
loaded — this client's `main.gd::open_native_file()` (full-replace open of
an arbitrary native file at runtime, not just the one `native_file_path`
started with) and `main.gd::add_component_file()` (this endpoint) are the
two new entry points, both exposed from the wrist tablet's Files tab.

## Assembly mesh (the endpoint this client actually renders)

```
GET /document/parts/{part_id}/assembly-mesh.glb
```
(`backend/app/document/router.py` ~line 8958, encoder in
`backend/app/document/mesh_export.py::encode_assembly_glb`)

- Binary glTF (`.glb`), node-instanced: one mesh per unique `(part_id, resolved
  appearance)`, one node per placed instance with quaternion rotation (reuses
  `assembly_solver._quaternion_from_axis_angle`).
- **Appearance (DIDSA-CAD `docs/appearance-tool-scope.md` V1, branch
  `claude/appearance-and-scenes`):** each instance's material is its resolved
  appearance (`material_for_appearance`: base colour + opacity, metallic,
  roughness, emission with `KHR_materials_emissive_strength`; opacity < 1 is
  `alphaMode: BLEND`, which Godot imports as alpha with a depth pre-pass).
  Colours are written LINEAR (converted from the picked sRGB hex), so Godot's
  importer shows the hex as picked. `material.extras.appearance` lists only the
  fields that were set. A part whose bodies or faces look different is split
  into **one primitive per look**, each with an index accessor into the shared
  position / normal accessors and its own triangles' `face_ids` / `body_ids`
  (topology on the first primitive only): `mesh_identity.gd` joins them in
  surface order, which is `get_faces()` and the trimesh collider's order
  (`tests/appearance_glb.gd` checks it on a real backend glb).
- Every node's `extras` also carries `instance_path`: the full occurrence path
  from the requested Part (`outer/inner/leaf`, a pattern copy's
  `<source>#pattern:<pattern id>:<index>` segment included; `""` = the root's own
  content). `group_index.gd` places pattern copies with it.
- **The node list is flat**: one top-level node per placed instance, sub-assemblies
  included, each at its pose in the requested Part's frame (mm). A Part with no
  geometry of its own (a sub-assembly) is a mesh-less node, which Godot imports as
  a plain `Node3D`; `mesh_identity.gd` tags it with `instance_path` too, and
  `scenes_tool.gd` poses it (`tests/e2e_scenes.gd` checks the order and poses on
  a real backend glb).
- Hidden instances omitted by default; `?include_hidden=true` to include them.
- `?quality=0..1` and `?tier=coarse|full` control tessellation density.
- Accessors are unindexed — vertex welding is deliberately deferred
  server-side, so don't expect shared vertices across triangles.
- Built and merged in PR #250; real on-headset payload size for a genuine
  parametric assembly (not a pre-tessellated import) hasn't been measured yet
  — only estimated on the older JSON endpoint (see vision brief).

**Milestone 4 addition (DIDSA-CAD PR #257, merged): occurrence/face identity
as glTF `extras`.** Needed so a client-side raycast hit can be turned into a
real Mate/Measure reference — see `mesh_identity.gd` in this client and that
PR's own commit message for the full reasoning. Per node:
```json
"extras": {"owner_part_id": "...", "occurrence_id": "..."}
```
`occurrence_id: ""` means "this is `owner_part_id`'s own top-level content,
not a placed Occurrence" (root content, or a pattern-derived copy — matches
`MeasureEntityRefSchema.occurrence_id`'s own convention). Per mesh primitive,
parallel to its (unindexed) triangle list:
```json
"extras": {"face_ids": [0, 0, 1, 1, ...], "body_ids": ["<uuid>", "<uuid>", ...]}
```
`(body_ids[i], face_ids[i])` for triangle `i` is a real
`SubShapeRef{body_id, shape_type: "face", index}` (see "Mates" below) — note
glTF JSON round-trips every number as float, so cast `face_ids[i]` back to
`int` before sending it anywhere (`mesh_identity.gd` does this once, at tag
time). **This client's own ray hits correctly resolve to the right face for
geometry that came through `GLTFDocument`'s real import** (confirmed against
real OCCT tessellation) — but Godot's own `PrimitiveMesh` generators (e.g.
`BoxMesh`) use the *opposite* triangle winding, so don't use one as a
stand-in for testing per-triangle face identity; build a real (or
real-shaped) glb instead, as `tests/mesh_identity.gd` does.

**Edge / vertex topology (DIDSA-CAD, with the Measure edge/vertex pick).** The
same primitive's `extras` also carries `"topology"` (default on;
`?topology=false` leaves it out), keyed by `body_id`:
```json
"topology": {"<body_id>": {
  "edges":      [{"i": 3, "k": "circle", "s": [x1,y1,z1, x2,y2,z2, ...]}, ...],
  "vertices":   [{"i": 0, "p": [x, y, z]}, ...],
  "face_edges": [[3, 4, 7, 8], ...],
  "face_kinds": ["plane", "cylinder", "other", ...]
}}
```
`edges[].s` is the edge's polyline as consecutive start/end point pairs and
`vertices[].p` a point, both in the Part's own frame (the same frame as the
triangles, mm); `face_edges[face_id]` lists the edge `i`s on that face's
boundary. **`i` is the raw `SubShapeRef.index`** (the 0-based
`TopTools_IndexedMapOfShape` position `resolve_subshape_from_bodies` uses),
NOT the dense id the flat app's own mesh response draws with: they differ past
any degenerate edge (a sphere pole, a cone apex), so it can be sent straight
back as `{"body_id", "shape_type": "edge"|"vertex", "index": i}`.
`edges[].k` is `"line"` / `"circle"` / `"other"` and `face_kinds[face_id]` is
`"plane"` / `"cylinder"` / `"other"`: exactly what a mate can use
(`assembly_solver._resolve_local_geometry`: a plane's normal, a cylinder's axis,
a straight or circular edge's axis, a vertex's point), so the Mates tool only
offers those. `mesh_identity.gd` converts it once at tag time; `topology_pick.gd` picks from it.

## Mates — a real client to a real, pre-existing API

```
GET    /document/parts/{part_id}/mates
POST   /document/parts/{part_id}/mates
PATCH  /document/parts/{part_id}/mates/{mate_id}
DELETE /document/parts/{part_id}/mates/{mate_id}
POST   /document/parts/{part_id}/occurrences/{occurrence_id}/solve
POST   /document/parts/{part_id}/occurrences/{occurrence_id}/mate-motion
```
(`backend/app/document/router.py`, `create_mate`/`list_mates`/`update_mate`/
`delete_mate`/`solve_for_occurrence`/`mate_motion`; schemas in `schemas.py`:
`MateCreate`/`MateResponse`/`MateUpdate`.)

`part_id` here is the **owning** Part — whichever Part's own `.occurrences`
list contains both referenced Occurrences, not necessarily the loaded
assembly's root (a sub-assembly can own its own Mates). A Mate can only
reference a **top-level** Occurrence of that owning Part — this client
enforces that client-side too (`mates_tool.gd`'s pick validation), since a
solved Mate's local-to-parent transform is only directly usable as-is for a
top-level Occurrence (see below).

`POST .../mates` body (`MateCreate`):
```json
{
  "type": "coincident",
  "references": [
    {"occurrence_id": "...", "subshape_ref": {"body_id": "...", "shape_type": "face", "index": 0}},
    {"occurrence_id": "...", "subshape_ref": {"body_id": "...", "shape_type": "face", "index": 0}}
  ],
  "value": null,
  "flipped": false,
  "allow_rotation": true
}
```
`type` is one of `coincident`/`concentric`/`parallel`/`distance`/`angle`;
`value` is required (mm for distance, degrees for angle) for the last two,
omit otherwise. `shape_type` is one of `"face"`/`"edge"`/`"vertex"`/`"body"`
(`SubShapeType` in `models.py`) — the **Mates** and **Measure** tools send
`"edge"` and `"vertex"` as well as `"face"`: a ray only hits a face, so
`topology_pick.gd` takes the nearest of the HIT FACE's own boundary edges /
corners within a small angular reach of the hit point (see "Edge / vertex
topology" above). Mates only offers what the solver can use (planar /
cylindrical faces, straight / circular edges, corners); Measure takes any.
Verified against a real backend by `tests/e2e_edges.gd` (a CONCENTRIC mate
between two circular edges is accepted).

**Creating a Mate does not move anything by itself** — `solve_for_occurrence`
is a separate, explicit call. The flat app calls it immediately after
`create_mate` for the newly-driven Occurrence ("a freshly-authored Mate
visibly snaps its target into place immediately" — that endpoint's own
docstring); this client does the same by default. While mates are relaxed (the
sandbox, `mates_tool.gd`'s `set_relaxed`) a new or edited Mate is only
stored, and no part move is sent at all; when the sandbox ends the parts
go back to their remembered poses and only then are those Mates' driven
parts solved, so the solver never starts from a scattered layout. `solve_for_occurrence`'s response's `transform` is **local to the
Occurrence's own parent Part**, in the same raw-mm units the glb's own
per-instance translation uses (not pre-scaled) — for a top-level Occurrence
this equals the instance's whole world-relative-to-root transform (no
intermediate parenting in `assembly-mesh.glb` — see above), which is exactly
why this client restricts itself to top-level Occurrences for now; applying
it correctly to a nested Occurrence would need walking back up the chain,
not just writing the raw transform onto that instance's own flattened node.

No bulk-solve endpoint exists — "solve every Mate on this assembly" means
looping `solve_for_occurrence` over every distinct Occurrence any Mate
references (`mates_tool.gd`'s `enforce_all`).

**`/solve` now solves the whole mate-graph component (CAD constrained-drag S3).**
It is no longer "this occurrence against frozen peers": the occurrence AND every
occurrence mated to it (only as far as the mates *require* — a follower moves
just enough to keep its mates satisfied) are moved to the nearest satisfying
configuration and **all are stored**. The response is still only the driven
`OccurrenceResponse`; the followers' new poses are visible on the next
`GET .../occurrences`. This client therefore re-reads the occurrence list after
every `/solve` and moves every loaded node whose stored pose differs
(`mates_tool.gd`'s `_adopt_backend_poses`, one undo entry for all of them). A
non-converging component is still a 422 `mate_solve_did_not_converge`
(nothing stored) and a `fixed` occurrence a 422 `occurrence_is_fixed`.

### `mate-motion` — the live-drag contract (CAD constrained-drag S3, plan §3)

`occurrence_id` in the path is the **grabbed** occurrence. Request:
```json
{ "transform": { "translation": [..], "rotation_axis": [..], "rotation_angle_degrees": 0.0 },
  "lever_arm": 41.2,
  "commit": false }
```
`transform` = the wanted pose of the grabbed occurrence (`null` = its stored
pose; this client sends `null` for the grab-time anchor and the hand's wish for
every later one). `lever_arm` (mm, optional, > 0): this client sends half the
diagonal of the grabbed part's mesh AABB in the part's own frame; afterwards
it always uses the response's `chart.lever_arm`. `commit: true` also stores the
solved group atomically — this client sets it **only on release**, with the
release-time wish, exactly once. Response:
```json
{ "converged": true, "dof": 5, "grounded": true,
  "members": [ {"occurrence_id": "occ-B", "transform": {..}, "mobility": 3}, ... ],
  "basis": [ [ /* 6*k floats */ ], ... ],
  "chart": {"kind": "se3_owner_frame", "lever_arm": 41.2},
  "quality": {"residual_inf": 3e-10, "sigma_min": 0.31, "sigma_gap": 40.0, "max_step": 12.0, "jump": 0.7},
  "diagnostics": {"solve_ms": 3.4}, "committed": false }
```
* `dof` is the **group** dof (rank-based), `members[0]` is the grabbed occurrence,
  and the order of `members` is the column order of every `basis` row.
* `basis` rows are twists `[vx vy vz wx wy wz]` per member (`v` = displacement of
  the occurrence origin, `w` = rotation vector, rad) and are orthonormal in the
  *equal-weight* metric — the client re-orthonormalises them in the
  follower-weighted metric once per accepted answer (`FOLLOWER_WEIGHT` 1e-4 is a
  contract constant, not on the wire).
* **`quality.max_step`** (weighted mm) is how far the client's own screw
  prediction may travel before it leaves the mate manifold by more than a fixed
  tolerance; **`null` means "time cap only"** (flat mates and every screw orbit),
  never "unlimited". `sigma_min`/`sigma_gap` are `null` at rank 0. `quality.jump`
  is telemetry only — acceptance uses the client-measured jump.
* **`converged: false` carries no basis / dof / members / chart** — only
  `quality.residual_inf` and diagnostics. It is a normal 200, not an error. The
  client must **hold** the last pose and never read the missing basis as "all
  free". A `commit: true` with `converged: false` stores nothing (`committed`
  stays `false`); a `fixed` grabbed occurrence is a 422.
* The v0 aliases `transform` and `free_twists` are **gone** from the response
  (DIDSA-CAD S9, merged 2026-10-02, PR #276); this client never read them.
  (`/solve`'s own `transform` is the occurrence's stored pose and is unaffected.)
* **`quality.jump` and `max_step` are measured in the screw chart** (CAD S9 / F2):
  the prediction is the same screw integration this client does, so on a screw
  orbit `jump` is ~0 (swing scene, 15 mm slide + 90 deg: 1.83 -> 0.27). Still
  telemetry / a conservative guard; acceptance uses the client-measured jump.
* **The anchor is the weighted-nearest mate-satisfying pose** (CAD F1b: the backend
  refines the Gauss-Newton answer with the nearest-point retraction), so on a
  curved mate it no longer overshoots the linearised projection.
* **Optional additions this client does not use** (additive, safe to ignore):
  response `constraint_model` (the resolved mate geometry for a client-side local
  retraction; request flag `include_constraint_model`, default true) and request
  `reference` (the poses the client last accepted, a warm start; this client may
  send it, the flat client does by default). VR does NOT run the local retraction:
  the GDScript port cost p95 3.1 ms (k=1-2) / 7.8 ms (k=3) per frame on a Quest 3
  against 0.56 ms for the projector (`docs/local-retraction-benchmark.md`).

What the client does with it (DIDSA-CAD `docs/motion/projector-spec.md` is
normative; `scripts/motion/*.gd` implement it and `tests/motion_vectors.gd` pins
them to its golden vectors): project the hand's wish onto the basis every frame
with no network, integrate as a screw, blend across re-anchors, apply the result
to **every member** (followers move on screen), re-anchor with one request in
flight every 150 ms (75 ms near a rank change, or when travel reaches
`max_step`), accept an answer only if it converged, `residual_inf <= 1e-6` and its
client-measured jump is at most one lever arm, and hold on a miss. Measured on a
60-frame drag against a real backend: 1 grab anchor + 4 re-anchors + 1 commit =
**6 requests** in ~0.7 s.

## Measure — read-only, stateless, no create/persist step

```
POST /document/parts/{part_id}/measure
```
(`backend/app/document/router.py`'s `measure_entities`; domain logic in
`app.document.measure.measure`; schemas: `MeasureRequest`/
`MeasureEntityRefSchema`/`MeasurementResultSchema`. The same endpoint the
flat app's own `client/lib/viewport3d/measurement_panel.dart` uses.)

Body (`MeasureRequest`):
```json
{"refs": [{"occurrence_id": "...", "subshape_ref": {"body_id": "...", "shape_type": "face", "index": 0}}]}
```
1 or 2 refs (422 otherwise). Unlike Mates, `occurrence_id: ""` (root
content — the currently-open Part's own unplaced body) is a perfectly
valid ref, and **both refs can name the same Occurrence, or both be root
content** — `measure_tool.gd`'s own validation is deliberately looser than
`mates_tool.gd`'s for exactly this reason (measuring across two features of
one part is the common case, not a "two different parts" rule). Every
`occurrence_id` is resolved as a top-level Occurrence of the URL's own
`part_id` (`resolve_occurrence_target` — same restriction Mates has), so
both refs still need to belong to whichever Part is currently loaded.

Response (`MeasurementResultSchema`) is one flat, mostly-`null` object —
which fields are populated depends on what was sent, never a tagged union:
1 ref populates whichever of `point`/`length`/`area`/`radius`/`diameter`/
`center`/`axis`/`normal`/`point_on_face` applies to that entity's own
geometry type; 2 refs always populate `distance`/`point_a`/`point_b`/
`delta`, plus `axis_distance`/`axes_parallel` or `normal_distance`/
`faces_parallel` when that specific relationship is detected (e.g. two
circular edges' axes, two planar faces' normals). `body_volumes`/
`body_masses` (keyed by `body_id`) are **always** included for every
distinct Body among the refs, regardless of what was actually picked on
it — mass only for a Body with a material assigned. This client's own
wrist-tablet result rows (`wrist_tablet.gd`'s Measure tab) list these in
the exact same order the flat app's `MeasurementPanel._resultRows` does,
so the two apps read identically.

**No create/persist step at all** (`measure.py`'s own docstring: never a
`Feature`, never mutates `Part`, no undo/redo entry) — `measure_tool.gd`
re-queries on every pick rather than requiring an explicit "Measure"
action, and a real overlapping-request race is worth knowing about if
extending this further: a quick second pick fires its own request before
the first one's response has necessarily come back, so anything caching
or applying a response needs to guard against a stale one landing after a
newer pick has already superseded it (`measure_tool.gd`'s own
`_measure_token`, found necessary by a real e2e run against a live
backend, not anticipated up front).

## Appearance overrides (the Appearance tool)

```
GET /document/parts/{part_id}/appearance-overrides
PUT /document/parts/{part_id}/appearance-overrides
PATCH /document/parts/{part_id}          (appearance, body_appearances, face_appearances: the Part's own)
```
(DIDSA-CAD `backend/app/document/appearance_routes.py`, branch `claude/appearance-and-scenes`.) An override is
`{path, scope?, pattern_id?, part_id?, body_id?, face?, appearance}`: `path` is an occurrence path from the Part (`""` = the
Whole assembly, or with `body_id` one of its own bodies), `scope` is null, `"pattern"` (every copy of `pattern_id`, whose source
is the last segment) or `"same_part"` (every placement of `part_id`, empty path). PUT sets or replaces the override with that
target and returns the whole list; `appearance: null` clears it. GET lists them with `legacy: true` for an Occurrence's old
`color`, `unresolved` (why a target can't be found now; kept, ignored) and `face_current_index` (a face is re-found by its
signature after an edit). `GET /parts/{id}` now also returns the Part's own `appearance`, `body_appearances` and
`face_appearances` (each face with `current_index` / `unresolved`). Which look wins is the reference rule in DIDSA-CAD
`backend/app/document/appearance.py`; this client's copy is `scripts/appearance/appearance_rule.gd`, checked against the same
golden vectors (`tests/appearance_vectors.gd`). `appearance_tool.gd` paints in the scope's own Part (the world's root, or a
room's Part) and never edits a placed part's file.

## Scenes

```
GET    /document/parts/{part_id}/scenes
POST   /document/parts/{part_id}/scenes                 {name, overrides, section_planes?, viewpoint?}   (201)
GET    /document/parts/{part_id}/scenes/{scene_id}
PATCH  /document/parts/{part_id}/scenes/{scene_id}      each given field replaces that part whole
DELETE /document/parts/{part_id}/scenes/{scene_id}      (204)
```
(DIDSA-CAD `backend/app/document/scenes_routes.py`, branch `claude/appearance-and-scenes`.) A scene override is
`{path, body_id?, face?, transform?, hidden?, appearance?}`; a transform is the occurrence's local one at its own level (the
`{translation (mm), rotation_axis, rotation_angle_degrees}` shape), and a body / face or path `""` takes an appearance only
(422 otherwise). A viewpoint is `{eye, target, up}` in the Part's frame (mm). Every response carries `unresolved` (overrides
kept but not matching the assembly now). Composition (what a shown scene looks like) is the client's job; the reference is
DIDSA-CAD `backend/app/document/scene_compose.py` and this client's copy is `scripts/appearance/scene_compose.gd`
(`tests/scene_vectors.gd`). `scenes_tool.gd` never sends `section_planes` on Update, so a flat-app section plane survives.

## Occurrence colour (legacy alias)

Since the Appearance tool, `Occurrence.color` is an alias: the backend reads it as the override `{path: <occurrence>,
appearance: {colour}}` in the Part that places it, and mirrors a top-level occurrence's own override colour into it (so an
older client still shows it). This client no longer writes it directly (`colour_tool.gd` is gone); the notes below describe
the field as it was.

```
PATCH /document/parts/{part_id}/occurrences/{occurrence_id}
```
(`update_occurrence_transform` in `router.py`; `OccurrenceTransformUpdate`
in `schemas.py` — same endpoint the gizmo's own drag-persist and
hide/fixed/rename actions use, `color` is just one more optional field on
it.) Body `{"color": "#RRGGBB"}` sets it; **`{"color": ""}` (empty string,
not omitted) explicitly clears it back to no override** — omitting the
`color` key entirely leaves the current value untouched, the same
"omitted-means-unchanged, empty-string-means-clear" convention `hidden`/
`fixed`/`name_override` on this same schema use. The colour string itself is
opaque and unvalidated server-side (any string is accepted and echoed back
verbatim).

## Listing an Occurrence's direct children

```
GET /document/parts/{part_id}/occurrences
```
(`list_occurrences` in `router.py`; response is `list[OccurrenceResponse]`
— `id`, `external_ref`, `resolved_part_id`, `name_override`, `transform`,
`suppressed`, `hidden`, `fixed`, `color`.) One row per *direct* child
Occurrence of the given Part — not recursive. `colour_tool.gd`'s
`set_group_color()` (see "Occurrence colour" above) was this client's
first use of it, for "every sibling sharing an owner". Milestone 3's
Assembly Tree window (`scripts/assembly_tree_window.gd`) is the second and
more direct one: it recurses this call from the loaded assembly's
`root_part_id` down through each row's own `resolved_part_id`, lazily as a
row is expanded, to build a real (if shallow-fetched) tree view — there is
still no single nested-tree endpoint, so a client wanting the whole
hierarchy either recurses this call itself or, for the eager alternative,
reads `GET .../assembly-mesh` (the JSON, non-glb endpoint)'s own
`instances[].occurrence_path`, which already carries the full chain per
placed leaf instance in one round trip — not used here, since it costs a
second full-assembly fetch (~460 KB on DIDSA-CAD's own measured test
assembly, per the vision brief) on every model load whether or not the
tree is ever opened, versus this endpoint's pay-only-if-you-look-at-it
shape.

## Multi-format import (STEP/OBJ/STL) — backend exists, client doesn't use it yet

```
POST /document/parts/{part_id}/import-features
```
(`backend/app/document/router.py` ~line 8397)

Brings an external file's geometry in as a fixed, non-parametric
`ImportFeature` Body **on an existing Part** — this is not a "create a new
document from any file" endpoint. Body:
```json
{"data_base64": "...", "source_format": "STEP"}
```
`source_format` is an `ImportSourceFormat` enum; only `STEP` has been directly
confirmed while reading this (the vision brief's recon notes said the import
already accepts STEP/STL/OBJ/glTF too, but **re-check the actual enum in
`backend/app/document/models.py` before building against it** — this wasn't
independently re-verified for every format).

For a client wanting to load an arbitrary STEP/OBJ/STL file that *isn't*
already a DIDSA part, the likely flow (not yet built or tested here) is:
1. `POST /document/new` to create a bare Part (~line 3132, `NativeImportResponse`).
2. `POST /document/parts/{part_id}/import-features` with the file's bytes.
3. `GET /document/parts/{part_id}/assembly-mesh.glb` as usual.

A bare `.glb`/`.gltf` file needs none of this — Godot's `GLTFDocument` can
load it directly, client-side, with no backend round trip at all.

## Export endpoints (not used by this client, but available)

```
GET /document/parts/{part_id}/export/{step,stl,obj}
GET /document/parts/{part_id}/export/assembly-{step,stl,obj}
```
Single-part and whole-assembly export in classic CAD formats. No current
use case in the VR client, but useful if a future tool needs to hand
geometry back out.

## Files worth reading directly, if extending any of this

- `backend/app/document/router.py` — every endpoint above, with docstrings.
- `backend/app/document/models.py` — `Part`, `Mate`, `MateType`, `SubShapeType`,
  `Occurrence` (incl. `color`), `ImportFeature`, and the `ImportSourceFormat`
  enum.
- `backend/app/document/schemas.py` — `MateCreate`/`MateResponse`/`MateUpdate`,
  `OccurrenceTransformUpdate`, `MeasureEntityRefSchema` (measurements, not yet
  built client-side — the same picking foundation `mates_tool.gd` uses should
  carry straight over to `POST /parts/{id}/measure`).
- `backend/app/document/native_format.py` — native JSON shape.
- `backend/app/document/mesh_export.py` / `mesh_data.py` — glTF encoding, unit
  handling (or lack of it), the milestone-4 identity `extras`.
- `backend/app/document/assembly_solver.py` — what `solve_for_occurrence`
  actually does (`docs/assembly-scope.md` §3 Phase 6 in that repo).
- `backend/app/document/section.py` — the sectioning tool's own stateless
  `section-preview` endpoint. **Re-read directly this session (not just this
  summary) before building the VR client's own Sections tool, per the
  standing instruction here to check rather than trust it: confirmed still
  accurate.** `compute_section_mesh` does a real OCCT `BRepAlgoAPI_Common`
  boolean per Body per plane, then a full re-tessellation of the result,
  recomputed from scratch on every single request — no caching, no
  persisted Feature. This client's own Sections work went client-side-only
  (a world-space clip plane via a shared shader uniform — see
  `scripts/section_tool.gd`), makes no call to this endpoint at all, and is
  built (`docs/status.md`'s Milestone 4 section).
- `backend/app/session_context.py` — session id resolution.
