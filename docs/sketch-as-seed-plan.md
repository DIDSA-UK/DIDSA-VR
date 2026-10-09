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
and constraint glyphs, construction geometry, edge lines).** On/off switches for the whole category,
held in the client for the session. They are **not saved**: nothing visibility-related is written to the
file beyond the existing `hidden_feature_ids`, so there is nothing new for the flat app to round-trip
and no compatibility question. (A key the flat app doesn't know does not stop a file loading; it is
simply dropped on a re-save, which is why we are not relying on one.)

**Category buttons for features are batch edits, not a second layer.** Tapping "Sketches" when all are
visible hides every sketch (adds them all to `hidden_feature_ids`); tapping it when any are hidden
shows **all** of them, whatever their earlier individual settings (removes them all from
`hidden_feature_ids`). So off then on always ends with every sketch visible. A mixed state shows as a
half-filled eye and a count ("3 of 5").

### The load rule

Because visibility is not saved, **every load starts from a rule**:

| Thing | On load |
|---|---|
| Sketch not used as a seed by any applied (and not rolled-back) feature | **shown** |
| Sketch that is a seed of an applied feature | hidden |
| Bodies | the current bodies only (consumed bodies do not exist, see section 5); shown |
| Surfaces, 3D curves | shown (they are results, like bodies) |
| Created planes | hidden |
| Reference planes, origin and axes, dimension glyphs, construction geometry | hidden |
| Edge lines | follow the existing View > Display mode |
| Items the file lists in `hidden_feature_ids` (set in the flat app, or by VR in an earlier save) | **stay hidden**, except sketches, which follow the rule (see below) |

Why those choices:
- "Seed" is read from the feature rows the backend already returns: an Extrude or Revolve's sketch, a
  Loft's section sketches, a Sweep's profile and path sketches. Pattern directions do not count.
- **Rolling a feature back** makes its sketch unconsumed again, so it is shown while rolled back and
  hidden again when the rollback is released.
- Keeping `hidden_feature_ids` for bodies, surfaces, curves and planes respects a deliberate hide made in
  either app, and it already travels. Sketches are the exception because the rule is the more useful
  default after a load (it recreates the state "sketches I can still use are visible"), and an
  explicit hide of a sketch is one tap to redo.
- Auto-hide records (which feature hid which sketch, for Undo) are session-only for the same reason.

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
3. The auto-hide is remembered separately (a session-only record of sketch id to the feature that caused it; not saved, see the load rule).
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
- **Bodies list = the current bodies only.** Features apply in sequence and the list shows what they
  produce now. A body consumed by a later feature (a Merge or Boolean input, say) is not listed, unless
  that consuming feature is rolled back, when the bodies it consumed come back with the rollback. To
  check when this is built: the backend already omits consumed bodies from its mesh response; a
  scene test with the fake backend will pin that the tree follows it, including after rollback.

## 6. Sketch as seed (the feature work)

Activating Extrude, Revolve, Sweep or Loft with **no sketch open** enters a pick-sketch state
instead of showing "Draw a closed shape first":

1. The **visible** sketches are drawn in the viewport. Their closed profiles are tinted as translucent
   regions so a sketch reads as a usable shape, but that tint is **only a cue**.
2. **Picking prefers a sketch line** (decided): aim at any line, circle or arc of the sketch and pull
   the trigger, and that sketch is the seed. A filled region is picked only when no line is within
   reach, so two overlapping sketches rarely compete (the lines differ even when the regions overlap).
   A "Select Other"-style cycle, as in the flat app, is the later answer for any remaining ambiguity
   (roadmap). The Properties panel lists it under
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
| 1 | Visibility model: the VR-only category switches (session only), the load rule and the batch show/hide rule in section 2 over the existing hidden set | pure logic + load/save round trip |
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
6. Consumed bodies are not listed unless the feature that consumed them is rolled back.
7. Picking a sketch prefers its **line** over the closed area; "Select Other" later.
8. **Visibility is not saved.** A load rule sets it (section 2); the VR-only switches are session-only.

**Still open**

None blocking. Check at step 1 whether the load rule's treatment of `hidden_feature_ids` for bodies,
surfaces, curves and planes (kept hidden) is what you want, once you have seen a file load.

## 9. Roadmap items this creates

- **Centre of gravity** (all clients): a backend mass-properties result (per body and whole part,
  volume centroid with density), then a marker and readout in VR and the flat app. VR shows a greyed
  placeholder in the Visibility drawer until then.
- **"Select Other"** for sketch picking in VR, matching the flat app, for overlapping sketches.
- Independent of this plan, and unchanged: DIDSA-CAD drops unknown top-level keys (such as
  `vr_stale_mates`) when the flat app re-saves a file. It no longer matters for visibility.
