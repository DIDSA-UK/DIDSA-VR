# Sketch as seed, and the Visibility tool: plan

Status: **plan, nothing built yet.** From the 9 Oct 2026 test round. The Visibility tool is the
prerequisite; "sketch as seed" (Extrude, Revolve, Sweep and Loft taking a *finished* sketch picked in
the viewport) builds on it.

## 1. Where we are now (checked in the code)

| Thing | Today |
|---|---|
| Bodies, faces, edges as seeds (Shell, Fillet, Chamfer, Pattern, Boolean, Merge, Split) | Picked in the viewport with the laser, lit up. Fine. |
| Loft sections, Sweep path, Pattern direction | Pick a **line** of an earlier sketch. Those sketches' lines are drawn **only while such a tool is active** (`sketch_picks.gd`, state `pick_curves`). |
| Extrude, Revolve, Sweep profile | Work on the **open** sketch only. With none open the tip says "Draw a closed shape on a plane first". To use an earlier sketch you reopen it from the Build tree (Edit). |
| Finished sketches in the viewport | Not shown at rest. The Build tree's "Lines: on/off" only narrows what Loft/Sweep can pick. |
| Reference planes (XY, XZ, YZ) and created planes | `plane_markers.gd`: shown only while choosing a plane to sketch on. |
| Hide / Show | Build tree strip, per **feature**. Stored as `hidden_feature_ids` in the file's native extras (the flat app reads it). Per the backend it is **purely cosmetic**: everything still resolves, bodies and surfaces just come back flagged `hidden`. |
| Arena parts | View > Tools (Hide all, Show all, Isolate...). Separate; stays as it is. |
| Centre of gravity | Does not exist. The backend reports body volume and mass, not a centroid. |

## 2. The visibility model

Two kinds of thing, handled differently.

**Items that are features (sketches, created planes, extrude/revolve bodies, surfaces, 3D curves).**
Hidden per item with the existing `hidden_feature_ids`. Cosmetic only, saved with the file, and the
flat app already reads and writes it, so these transit between apps with no new work.

**Things with no feature id (reference planes, origin and axes, centre of gravity, sketch dimension
and constraint glyphs, construction geometry, edge lines).** These are on/off switches for the whole
category, held in the client. VR keeps them in the file under a `vr_visibility` key (the way
`vr_stale_mates` is kept).

**Category buttons for features are batch edits, not a second layer.** Tapping "Sketches" when all are
visible hides every sketch (adds them all to `hidden_feature_ids`); tapping it when any are hidden
shows **all** of them, whatever their earlier individual settings (removes them all from
`hidden_feature_ids`). So off then on always ends with every sketch visible. A mixed state shows as a
half-filled eye and a count ("3 of 5"). Showing all also forgets any auto-hide records for those
sketches.

**Do the VR-only switches survive a trip through the flat app?** Checked, and not yet. The flat app
(`part_screen.dart`) writes only the keys it knows (`hidden_feature_ids`, `section_planes`) when it
saves, so any `vr_*` key in a file is **dropped** when that file is opened and saved in the flat app.
The same is true today of `vr_stale_mates`. Fix, on the DIDSA-CAD side: preserve unknown top-level
keys on open and save (or at least the `vr_` prefix). It is small, but it is a prerequisite for the
promise "the files still transit between apps"; it is listed on the roadmap.
If we would rather every client honour these switches, the alternative is to agree a shared
`hidden_categories` key. That is a decision for the CAD side.

Table scope only. The arena's View > Tools hide/show is untouched.

## 3. The Visibility tool

**Where:** the generic column (right of the dock), an eye button next to Snap. It is always available,
and toggles the drawer.

**The drawer:** a small panel that slides out beside the dock (same chrome as Properties, so it is
laser-clickable and has the same grab handle). One row per category:

```
 VISIBILITY                      [Show all] [Hide all]
 [eye]  Sketches            3 of 5
 [eye]  Bodies              2 of 2
 [eye]  Surfaces            0 of 0   (dimmed: none exist)
 [eye]  Created planes      1 of 1
 [eye]  Reference planes
 [eye]  Origin and axes
 [eye]  Centre of gravity
 [off]  Sketch dimensions
 [off]  Construction geometry
```

- A button shows eye (all visible), half eye (some), or eye-off and dimmed (none). The count shows how
  many items are visible ("3 of 5"). A category with nothing in it is greyed.
- Tapping: if everything in the category is visible it hides all; otherwise it shows **all**, whatever
  the earlier individual settings. Individual items stay adjustable from the tree.
- "Show all" / "Hide all" act on every category. Hide all is not destructive (nothing is deleted).
- The drawer sits **beside the dock** (decided).

**Categories**

| Category | Layer | Needs |
|---|---|---|
| Sketches | A | already there (feature ids) |
| Bodies | A | already there |
| Surfaces | A | already there |
| 3D curves | A | already there |
| Created planes | A | already there |
| Reference planes (XY, XZ, YZ) | B | `plane_markers.gd` gets an "always on" mode, not only while picking |
| Origin and axes | B | small new marker |
| Centre of gravity | B | **placeholder for now**: a greyed button marked "coming soon". Built later as a backend mass-properties feature so every client gets it (roadmap). |
| Sketch dimensions | B | glyph layer of the sketch view |
| Construction geometry | B | flag on sketch entities |
| Edge lines | B | already exists in `edge_overlay.gd`; just exposed |

More I'd consider later: bounding box, driven (reference) dimensions, hole centre marks, clip/section
planes, mates (assembly level, not the table), measurements.

## 4. Sketch lifecycle

1. A new sketch is **visible** and stays visible after Exit sketch.
2. When a feature that uses it as its **seed** is **confirmed** (Apply succeeded), the sketch
   **auto-hides** (its id goes into `hidden_feature_ids`).
3. The auto-hide is remembered separately (`vr_auto_hidden`: sketch id to the feature that caused it; a VR-only key, see section 2).
   Reasons: Undo of that feature brings the sketch back; a sketch the user hid by hand is never
   auto-shown; and the tree can say "seed of Extrude 1".
4. The user can show it again at any time (drawer or tree). It is not re-hidden until the next feature
   confirms with it.
5. Editing a feature (reopening it) shows its seed sketch while the edit is open, then restores.
6. A failed Apply changes nothing.
7. **Seeds** that auto-hide: the profile sketch of Extrude, Revolve, Loft (every section) and Sweep
   (profile and path). A Pattern's direction line does **not** hide its sketch (decided): it is a reference, not a consumed profile.
8. Rollback: rolled-back features do not count; a sketch hidden by a rolled-back feature is shown again
   while rolled back.

## 5. Hide/show from the tree

- A small **eye** at the left of each Build row (and each body, surface, plane) that hides or shows it
  in one tap, without selecting the row first. The existing Hide/Show on the selected-row strip stays.
- A hidden row is dimmed with an eye-off glyph; an auto-hidden sketch also shows "seed of Extrude 1".
- Group headings (Sketches, Bodies...) get the same eye and act on the whole group, so they mirror
  the drawer's category buttons.

## 6. Sketch as seed (the feature work)

Activating Extrude, Revolve, Sweep or Loft with **no sketch open** enters a pick-sketch state
instead of showing "Draw a closed shape first":

1. The **visible** sketches are drawn in the viewport, and their **closed profiles are shown as
   translucent filled regions** so a sketch looks pickable, not just a set of lines. Hover lights one.
2. Pull the trigger on a profile: that sketch is the seed. The Properties panel lists it under
   Selected ("Sketch 2: closed shape ready") and the usual controls (Boss/Cut, depth, Apply) appear.
   The preview starts as soon as the seed and values are valid.
3. If a sketch **is** open it is the default seed, as now, and nothing changes for that flow.
4. A hidden sketch cannot be picked. If none are visible the tip says so and offers the Sketches
   toggle ("No sketches are visible. Show them in Visibility.").
5. Per feature:
   - **Extrude**: one profile sketch.
   - **Revolve**: pick the profile sketch, then the axis line (a line of that sketch, or a reference axis).
   - **Sweep**: profile sketch, then the path curves (today's line picking).
   - **Loft**: two or more profile sketches, in pick order (today you pick a line of each; this makes it
     pick the profile).
6. Engineering notes: `extrude_request(...)` already takes a sketch feature id, so the request side
   needs only an `ed.seed_sketch_id()` instead of `ed.session.feature_id`; the "is it closed" answer
   comes from the sketch read `sketch_picks.gd` already does; `finishes_sketch()` applies only when the
   sketch was open. Filled-profile drawing and picking is the one genuinely new piece.

## 7. Build order

| Step | What | Tests |
|---|---|---|
| 1 | Visibility model: the VR-only category switches (`vr_visibility`, save/load), the batch show/hide rule in section 2 over the existing hidden set | pure logic + save round trip |
| 2 | Drawer and the eye button; categories on layers A and B that already exist (sketches, bodies, surfaces, created planes, reference planes) with counts | Rig scene test, render |
| 3 | Sketches drawn at rest when visible (reuses `sketch_picks.gd`); reference/created planes always-on mode | scene test, render |
| 4 | Tree eyes and group headings | tree test |
| 5 | Auto-hide lifecycle (section 4) with undo and rollback | scene test with the fake backend |
| 6 | Sketch as seed: Extrude first (filled profiles, pick, preview, apply), then Revolve, Sweep, Loft | scene tests + e2e against a real backend |
| 7 | Origin and axes, sketch dimensions, construction geometry (centre of gravity stays a placeholder, see roadmap) | per-item tests |

Each step ships on its own and leaves the table working.

## 8. Decisions and open questions

**Decided (John, 9 Oct 2026)**

1. A Pattern direction line does not auto-hide its sketch.
2. Auto-hide happens on **Apply** only.
3. The drawer sits **beside the dock**.
4. Category buttons show all when anything is hidden, regardless of earlier individual settings.
5. Centre of gravity is a **placeholder** now and a roadmap item (a backend feature, for every client).

**Still open**

1. **Consumed bodies** (inputs to Merge or Boolean): they stop being drawn because the result replaces
   them. Should the tree also list them, dimmed, as "consumed"?
2. **Overlapping sketches** on the same plane: when the laser is over regions of two sketches, cycle
   with repeat pulls, or pick the smallest region under the laser?
3. **Flat-app round trip:** is the CAD team happy to preserve unknown `vr_` keys on save (section 2)?
4. **Persistence** of the VR-only switches (reference planes, origin, dimensions...): saved per part
   in the file (as planned), or per session only?

## 9. Roadmap items this creates

- **Centre of gravity** (all clients): a backend mass-properties result (per body and whole part,
  volume centroid with density), then a marker and readout in VR and the flat app. VR shows a greyed
  placeholder in the Visibility drawer until then.
- **DIDSA-CAD: preserve unknown top-level keys** (at least `vr_*`) when a native file is opened and
  saved, so VR-only data is not lost in the flat app.
