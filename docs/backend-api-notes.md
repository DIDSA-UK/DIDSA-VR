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

## Assembly mesh (the endpoint this client actually renders)

```
GET /document/parts/{part_id}/assembly-mesh.glb
```
(`backend/app/document/router.py` ~line 8958, encoder in
`backend/app/document/mesh_export.py::encode_assembly_glb`)

- Binary glTF (`.glb`), node-instanced: one mesh per unique `(part_id, colour)`,
  one node per placed instance with quaternion rotation (reuses
  `assembly_solver._quaternion_from_axis_angle`).
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

## Mates — a real client to a real, pre-existing API

```
GET    /document/parts/{part_id}/mates
POST   /document/parts/{part_id}/mates
PATCH  /document/parts/{part_id}/mates/{mate_id}
DELETE /document/parts/{part_id}/mates/{mate_id}
POST   /document/parts/{part_id}/occurrences/{occurrence_id}/solve
```
(`backend/app/document/router.py`, `create_mate`/`list_mates`/`update_mate`/
`delete_mate`/`solve_for_occurrence`; schemas in `schemas.py`:
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
(`SubShapeType` in `models.py`) — **this client only ever sends `"face"`
today**; edge/vertex picking isn't wired up client-side yet (a raycast
against a filled mesh naturally resolves to a face; an edge needs either
separate wireframe-pickable geometry or a nearest-boundary-edge heuristic).

**Creating a Mate does not move anything by itself** — `solve_for_occurrence`
is a separate, explicit call. The flat app calls it immediately after
`create_mate` for the newly-driven Occurrence ("a freshly-authored Mate
visibly snaps its target into place immediately" — that endpoint's own
docstring); this client does the same by default (`mates_tool.gd`'s
`relaxed` flag can suspend it to place several Mates before solving them
all). `solve_for_occurrence`'s response's `transform` is **local to the
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

## Occurrence colour

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
verbatim) — this client always sends a `"#RRGGBB"` hex string to match how
`mesh_export.py`'s `_color_to_base_color_factor` decodes it for rendering
(straight 0–255→0–1 channel scaling, no sRGB conversion) — `colour_tool.gd`'s
own local preview matches that exact scaling so its optimistic
`material_override` renders the same shade a real reload would.

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
  `section-preview` endpoint; re-tessellates on every call, likely too slow
  for a dragged plane at 90 Hz, so this client's own sections work is planned
  client-side (a shader clip-plane) rather than calling this — read it anyway
  before committing to that, in case something changed.
- `backend/app/session_context.py` — session id resolution.
