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

Two layers, because some things are features and some are not.

**Layer A: per item (feature-scoped), the existing `hidden_feature_ids`.**
Covers anything that is a feature: sketches, created planes, extrude/revolve bodies, surfaces, 3D
curves. Cosmetic only, saved with the file, shared with the flat app. No new storage and no backend change.

**Layer B: per category (VR-only display layers).**
For things with no feature id: reference planes, origin and axes, centre of gravity, sketch
dimension and constraint glyphs, construction geometry, edge lines. Stored in a VR-only native extra
(`vr_visibility`, the same way `vr_stale_mates` is kept; the flat app ignores unknown keys).

**Rule:** an item is drawn if its category is on **and** (for a feature-scoped item) its feature is
not hidden. Category switches never change the per-item flags, so turning "Sketches" off and on again
brings back exactly what was visible before.

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

- A button is a toggle: eye = shown, eye-off + dimmed = hidden. The count shows how many items in
  the category are currently visible ("3 of 5"). A category with nothing in it is greyed.
- Tapping a category flips **all** its items. Individual items are then still adjustable from the tree.
- "Show all" / "Hide all" act on every category. Hide all is not destructive (nothing is deleted).

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
| Centre of gravity | B | **new**: centroid of each body's volume, computed client-side from the mesh (signed tetrahedra); a marker per body plus one for the whole part. Uniform density assumed, and the label says so. Backend centroid endpoint is the alternative if we ever want real materials. |
| Sketch dimensions | B | glyph layer of the sketch view |
| Construction geometry | B | flag on sketch entities |
| Edge lines | B | already exists in `edge_overlay.gd`; just exposed |

More I'd consider later: bounding box, driven (reference) dimensions, hole centre marks, clip/section
planes, mates (assembly level, not the table), measurements.

## 4. Sketch lifecycle

1. A new sketch is **visible** and stays visible after Exit sketch.
2. When a feature that uses it as its **seed** is **confirmed** (Apply succeeded), the sketch
   **auto-hides** (its id goes into `hidden_feature_ids`).
3. The auto-hide is remembered separately (`vr_auto_hidden`: sketch id to the feature that caused it).
   Reasons: Undo of that feature brings the sketch back; a sketch the user hid by hand is never
   auto-shown; and the tree can say "seed of Extrude 1".
4. The user can show it again at any time (drawer or tree). It is not re-hidden until the next feature
   confirms with it.
5. Editing a feature (reopening it) shows its seed sketch while the edit is open, then restores.
6. A failed Apply changes nothing.
7. **Seeds** that auto-hide: the profile sketch of Extrude, Revolve, Loft (every section) and Sweep
   (profile and path). Open question: Pattern's direction line (see section 8).
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
| 1 | Visibility model: category layer store (`vr_visibility`, save/load), the rule in section 2, Layer A wired to the existing hidden set | pure logic + save round trip |
| 2 | Drawer and the eye button; categories on layers A and B that already exist (sketches, bodies, surfaces, created planes, reference planes) with counts | Rig scene test, render |
| 3 | Sketches drawn at rest when visible (reuses `sketch_picks.gd`); reference/created planes always-on mode | scene test, render |
| 4 | Tree eyes and group headings | tree test |
| 5 | Auto-hide lifecycle (section 4) with undo and rollback | scene test with the fake backend |
| 6 | Sketch as seed: Extrude first (filled profiles, pick, preview, apply), then Revolve, Sweep, Loft | scene tests + e2e against a real backend |
| 7 | Origin and axes, centre of gravity, sketch dimensions, construction geometry | per-item tests |

Each step ships on its own and leaves the table working.

## 8. Open questions

1. **Pattern direction** (and any "reference only" use of a sketch line): should it auto-hide the sketch?
   I'd say no: a direction reference isn't consuming the sketch the way a profile does.
2. **Auto-hide trigger:** on Apply, or when the feature is first previewed? I'd say Apply only.
3. **Bodies consumed by Merge/Boolean:** they already stop being drawn because the result replaces
   them. Do you also want them listed in the tree as "consumed", dimmed?
4. **Drawer placement:** beside the dock (as drawn), above the generic column, or a tab inside the
   Properties panel?
5. **Persistence:** category switches saved per part (as planned) or per session?
6. **Centre of gravity:** per body plus whole part, volume centroid, OK for v1?
7. **Sketch picking when several sketches overlap in the same plane:** cycle with repeat pulls, or pick the smallest region under the laser?
