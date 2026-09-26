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
- `backend/app/document/models.py` — `Part`, `Mate`, `ImportFeature`, and the
  `ImportSourceFormat` enum.
- `backend/app/document/native_format.py` — native JSON shape.
- `backend/app/document/mesh_export.py` / `mesh_data.py` — glTF encoding, unit
  handling (or lack of it).
- `backend/app/session_context.py` — session id resolution.
