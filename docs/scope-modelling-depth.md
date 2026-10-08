# Scope: modelling depth (design table)

Scoping pass, 2026-10-08. Covers gap G8 (more sketch tools and features, a preview before Apply, redo) and the Build-tree part of G11 in
`docs/design-table-gaps.md`, open item 7. Nothing here is built. The roadmap entry is in DIDSA-CAD `docs/roadmap.md`
("DIDSA-VR: next-work candidates").

**Correction to the gap list:** open item 7 names *Point* as a missing sketch tool. It is already registered (`SKETCH_TOOLS` in `table_tools.gd`), so
that line is stale and should be fixed when the list is next edited.

## What exists now, and what the backend already offers

Almost all of this is **VR client work**: the backend has the routes.

| Area | In VR now | Backend has | Gap |
|---|---|---|---|
| Sketch tools | Select, Line, Rectangle, Circle, Arc, Polygon, Point, Slot | Trim (line, circle, arc, ellipse, split-trim), Offset (line, arc, chain), Ellipse, Ellipse Arc, Spline, Text (+ preview), sketch-level Pattern / Mirror instances | All of these |
| Constraints | Dimension, Horizontal, Vertical, Parallel, Perpendicular, Coincident; the rest in Select's menu | Full set incl. Tangent, Equal, Collinear, Concentric, Fix, At-midpoint | None worth scoping |
| Features | Extrude, Revolve, Fillet, Chamfer, Shell, Mirror | Pattern (rect / circular, coarse-preview), Boolean (subtract / common), Merge, Split, Sweep, Loft (coarse-preview), Create Plane, Move / Delete Face, Move / Scale / Delete Body, surfacing family | All of these |
| Preview | None; Apply creates the feature | Coarse-preview only for Pattern and Loft; the flat app previews Extrude / Fillet / Chamfer by creating eagerly and PATCHing (`DIDSA-CAD docs/live-preview-pattern.md`) | Generic preview |
| Undo / redo | Undo of sketch steps and features, LIFO; no redo | n/a | Redo |
| Build tree | Edit covers extrude, fillet, chamfer, revolve, shell, sketch reopen | n/a | Edit for new features; Planes / Surfaces / Curves sections |

## Step 0: make adding a tool cheap

`table_editor.gd` is 1,426 lines and routes tools with `match` statements (`apply_feature`, option rows, hints, pick requirements). Adding ten features that way will
make it unmaintainable. Before the first new feature, extract a small per-feature interface (one script per feature):

- its options (name, kind, default) and the order they show,
- what it needs picked (edges, faces, bodies, a plane, a sketch line, an axis) and how that is validated,
- how to build the create payload and the PATCH payload,
- an optional preview call.

`table_tools.gd` and `PartFeatures` stay as they are. Existing tools can move over one at a time; none need to change behaviour. This is the single most
valuable item here because every later piece depends on it.

## Shared building blocks (needed by several features)

1. **Body picking.** Boolean, Merge, Split, Pattern and the direct-edit tools act on bodies. The Build tree can select a body (`select_body`) but the laser cannot pick one on the
   part. Extend `laser_pick.gd` / the highlight with a "pick a body" mode.
2. **Reference picks beyond edges and faces:** a sketch line from an *earlier* sketch (Sweep path, Loft guide, Pattern direction, Revolve-like axes), and fixed axes X / Y / Z as chips.
3. **A properties surface.** The options row holds six buttons plus More. Pattern (type, direction, count, spacing, reverse, second direction, axis, angle, merge) needs
   more. Options: a second options page, or a small docked panel like the tree window. Decision below.
4. **Preview before Apply.** See below.
5. **Mate and reference health.** Every new feature goes through `notify_edited`. Pattern and Boolean add or remove faces and bodies, so check `mate_health.gd` and
   `dirty_mates.gd` against them (a pattern adds bodies; a boolean consumes some).

## Preview before Apply and redo

**Preview.** Two approaches:
- *Eager create then PATCH* (what the flat app does for Extrude / Fillet / Chamfer): create the feature when its tool opens, PATCH on each change, delete on Cancel. Proven, works for
  every feature, shows the real result. Cost: a backend round trip per adjustment, and the document changes while the user is still deciding. VR already serialises requests (one in flight).
- *Coarse-preview endpoints*: nothing is created. Exists only for Pattern and Loft.

**Recommendation:** use coarse-preview where it exists (Pattern, Loft); use eager create + PATCH for the rest; render the result as a translucent body (the flat app's `isPreviewMesh` idea). Measure on a
Quest before trusting it for large parts.

**Redo.** Undo pops the last feature or sketch step. Redo for features is feasible (store the create payload, recreate on redo; the id changes, but LIFO order means nothing later
depends on it). Redo for *sketch steps* means replaying entity creation. Recommend features only at first, sketches later if it is wanted. Decision below.

## Features, in suggested order

### Tier 1: most-used, backend ready

| Feature | VR work | Notes |
|---|---|---|
| **Pattern** (rectangular, circular) | Source body (pick), direction (edge, sketch line or X / Y / Z chip), count, spacing, reverse; circular adds axis, count, total angle; merge mode; coarse-preview overlay; skipped instances later | Biggest gap for everyday parts. Needs body pick, axis chips, properties surface, preview |
| **Boolean** (Subtract, Common) and **Merge** | Pick target body (or bodies), then tool body (or bodies); consume-tool toggle | Needs body pick. Natural pair with Extrude's "New body" |
| **Create Plane** | Offset from plane / face first, others later (the backend has six construction methods) | Prerequisite for Loft and good for Sweep; also sketching on non-face planes |
| **Split** | Pick body and plane / face | Small once body pick exists |

### Tier 2: needs a multi-sketch workflow

| Feature | VR work | Notes |
|---|---|---|
| **Sweep** | Sketch the path (one sketch), sketch the profile (another), then pick path lines from the first sketch as `path_refs` | The session handles one open sketch; picking lines from a *finished* sketch is new |
| **Loft** | Two or more sections, each a profile on its own plane (Create Plane first); optional guide curves; coarse-preview exists | Sections are profiles of different sketches, so a sketch-profile picker is needed |

### Tier 3: direct edit (a new "Modify" category; the accent colour is already defined)

Move Face, Delete Face, Move Body, Scale Body, Delete Body. These are one-pick-and-a-value tools once face and body picks exist. Cheap, and they make the table useful for
edits to imported STEP parts that have no feature tree.

### Sketch tools, in suggested order

1. **Trim** (pick the segment under the laser; backend trims line, circle, arc, ellipse). Fits the existing laser picking; high use.
2. **Offset** (line, arc, whole chain). Pick the entity, then drag or type the distance.
3. **Ellipse / Ellipse Arc.** Also closes R-F in `scope-references-and-dimensioning.md`.
4. **Spline.** Control-point placement is easy; editing handles in VR needs thought; solver-backed in the backend.
5. **Text.** Needs the full keyboard (exists), a font choice and a size; the backend has a text preview. Check how the flat app turns glyph outlines into extrudable profiles before scoping it further.
6. Sketch-level Pattern / Mirror: lowest priority.

### Build tree (G11)

Edit for the new features (pattern count and spacing, boolean operation, loft / sweep targets) and the Planes / Surfaces / Curves sections. Do this together with each feature, not as a separate project.

## Order of work

| Phase | Content | Exit criterion |
|---|---|---|
| M0 | Per-feature interface (step 0), body pick, properties surface | Existing six features run through it, tests unchanged |
| M1 | Pattern, Boolean, Merge, preview (eager + coarse), Build-tree edit | Pattern and Boolean made and edited on the table against the real backend; mates flagged correctly |
| M2 | Create Plane, Trim, Offset, redo for features | Plane then sketch on it; trim a rectangle; undo then redo a feature |
| M3 | Modify category (direct edit), Split | Move a face on an imported STEP part |
| M4 | Sweep, Loft | A swept pipe and a two-section loft |
| M5 | Ellipse, Spline, Text | Each draws, dimensions and extrudes |

M1 is the first point where the table reaches parity for most everyday parts.

## Tests

- Headless against the fake backend for every tool's logic (pattern as a model: `design_table_editing.gd`, `design_table_build_tree.gd`).
- Real-backend e2e per feature (the `e2e_features.gd` / `e2e_revolve.gd` style), run locally.
- Render / picture tests where something new is drawn (a preview overlay, a body highlight).

## Risks

- **Quest performance.** A pattern of many instances or a loft makes a large glb; after every feature VR refetches the whole part (`refresh_geometry`). Nothing about Quest 2 / 3 is measured. Set a mesh
  budget and a per-feature timing check before M1.
- **Deck space.** The Feature row already pages (five plus More). With roughly twenty features, group them (Sketch-based / Modify / Pattern / Plane) rather than one long row.
- **Untested feel.** The deck, laser picking and numeric pad have had one headset session. More tools multiply the surface that is unverified.
- **Flat-app parity.** Features created in VR must be editable in the flat app. Every new feature should be opened there as part of its test (the design table's "flat app has not opened a VR-saved file" gap already applies).

## Decisions for John

1. Properties surface: second options page on the deck, or a docked panel?
2. Preview: eager create + PATCH for everything except Pattern and Loft (recommended), or only previews where a coarse-preview endpoint exists?
3. Redo: features only (recommended), or sketch steps too?
4. Is Tier 3 (direct edit) worth doing before Sweep and Loft? It is cheaper and matters for imported parts, but it is less central to building from scratch.
