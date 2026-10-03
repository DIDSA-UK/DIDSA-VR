# DIDSA VR: Design Table feature set

> Saved into the repo as written (a brainstorming export, not live-synced). What was decided from it, and what the code turned out to say, is in [`design-table.md`](design-table.md).

Brief for planning. This is a requirements summary, not an implementation plan. Please read the DIDSA-VR and DIDSA-CAD repos, then produce the plan.

## Context

- DIDSA VR Design Tools is the VR/XR companion to DIDSA-CAD, targeting Meta Quest (Quest 2/3/3S standalone, PCVR later).
- The VR app lives in its own repo (DIDSA-VR) and reuses the DIDSA-CAD backend and native part files.
- Earlier notes say Godot 4 with OpenXR was chosen as the engine and milestone 1 (import and viewport) is in progress. Please confirm against the repo rather than relying on this.
- The DIDSA-CAD backend is stateless and the client owns document state. Check how that applies to editing in VR.
- This feature is milestone 2 in the original roadmap: a design table that can be summoned into the assembly arena.

## What the design table is

A floating, tilted console that the user summons in front of them in the arena. A single part is edited on it. The wrist watch handles world and session controls (scale, view, hide, mates, environment) and spawns the table. The table handles authoring one part.

## Layout (from the user's concept sketch)

1. **Tree panel** at the table's left. Interactive assembly tree. Parts and sub-assemblies can be pulled out onto the table or into the world.
2. **Build area** in the middle. The part being edited sits here, and the geometry floats above the flat surface.
3. **Grab handle** on the build area's front edge. Moves and rotates the whole table without disturbing the part on it.
4. **Category row** below the build area: five category buttons.
5. **Tool row** below the category row: six tool buttons, showing the tools for the active category. The row changes when the category changes.

Category and tool names are not specified here. Take them from the repo (the existing DIDSA-CAD tool set). Any names in the concept art are placeholders.

## Decided behaviour

**Summoning and editing**
- The table is spawned from the wrist watch.
- The user picks up a part in the arena (or pulls one from the tree) and puts it on the table to edit its features and sketches.
- A part on the table scales to fit it. Lifting it off returns it to world scale.

**Leaving the table**
- Wherever the user puts the part down, an **Enforce mates** button appears.
- Mates are flagged dirty after an edit and need redoing.
- A part that is also open elsewhere is flagged dirty.

**Sketching**
- The user picks a sketch plane by lasering a face or plane in the table space, or in the tree. The chosen plane is highlighted on the part in the table space.
- On choosing a plane, the part orientates to the sketch plane and the sketcher opens.
- Laser points become corners, end points, centres and edges.
- Points snap to geometry. A button toggles snapping off.
- A dimension tool adds dimensions. Values are typed using the existing keyboard.

**Files**
- Native parts edited in VR must stay cross-compatible with the flat DIDSA-CAD app.

## Edit flow

1. Pick up a part in the arena, or pull it from the tree.
2. Put it on the build area. It scales to fit the table.
3. Laser a face or plane to choose a sketch plane. The part turns to face it and the sketcher opens.
4. Sketch with laser points and typed dimensions, then add features.
5. Lift the part off. It returns to world scale, its mates are flagged dirty, and Enforce mates appears where it is put down.

## Out of scope for now

- Multiplayer and one table per person (on the roadmap for later).
- Bluetooth pen on a real table.
- Other headsets (Pico, Galaxy, Apple) and PCVR-only heavy models.
- Environments (hangar, lab, clean room).
- Floating app windows (milestone 3).
- Network storage import.

## Related ideas from the original brainstorm

- A keyboard pops up on a right thumbstick click and can be called anywhere.
- AI-assisted modelling from voice, text or an easel drawing. Not part of this feature set unless the repo already has the hook.
- Laser-targeting faces and edges is shared with the mates tool, so the picking code should be common.

## Please confirm in the repos

1. How the existing mate and dirty-flag logic works in DIDSA-CAD, and whether the VR side can reuse it for the dirty-mates and dirty-part behaviour.
2. How the current keyboard handles typed numeric values for dimensions.
3. Whether native part files can be read and written by both apps as they stand, and what is missing if not.
4. How edit state is held on the client, given the stateless backend, and where a part's source of truth lives while it is on the table.
5. Quest 2 performance limits that affect the table (geometry budget for the part, tree, and sketch overlay).
6. The real category and tool names, and how a tool set maps to the six-slot tool row, including what happens if a category has more than six tools.

## Visual references

The design canvas has four boards: Concept art, Anatomy, Edit flow and Organised ideas. The Anatomy board labels the six parts and the Edit flow board shows the five steps above.
