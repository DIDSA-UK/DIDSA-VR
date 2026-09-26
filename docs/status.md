# Project status

Continuity notes for picking this project back up — what's built, what's
open, and how it's been worked on so far. See also `README.md` (setup/usage)
and `docs/backend-api-notes.md` (backend endpoints this client depends on).
The fuller product vision — milestones, interaction model spec, open
decisions, parked ideas — is `docs/vision-brief.md`, a point-in-time export
of a live Claude Docs artifact; ask John for the live link if it's gone
stale (it isn't kept in sync automatically).

## Milestone 0 — glTF endpoint and engine choice: done

Backend built the node-instanced `assembly-mesh.glb` endpoint (PR #250,
merged). A hands-on Godot 4 OpenXR spike then proved the whole pipeline on a
real headset (PCVR via Virtual Desktop, not a sideloaded APK — see
"Untested paths" below): import a real assembly → fetch the glb → render at
correct real-world scale → grab a part → walk around. Godot won; no formal
Unity comparison was run since nothing surfaced that Godot couldn't do.

## Milestone 1 — Import and viewport: in progress

**Built and tested on-device:**
- Native (`.didsa`/`.DIDSAprt`) file import → `assembly-mesh.glb` fetch →
  render, at correct mm→m scale.
- Individual part manipulation (`scripts/controller.gd`):
  - Proximity grab (grip): grabs whichever part is physically closest to
    the hand, always — deliberately independent of laser-selection.
  - Laser-select (trigger): point and pull the trigger to select a part at
    a distance (trigger again, or aim at nothing, to deselect). While
    selected, the thumbstick rotates it relative to the current view
    (world-up for left/right spin, the camera's flattened right axis for
    up/down tip) rather than the part's own drifting local axes — an
    earlier version rotated around the part's local axes and it felt wrong
    once the part had turned a bit; this was the fix. A/X and B/Y nudge it
    nearer/farther along the aim direction.
- User movement (`scripts/locomotion.gd`): left thumbstick walks/strafes
  relative to view direction; right thumbstick's X axis snap-turns, Y axis
  aims/blinks a teleport. Either stick backs off automatically while that
  hand has a part selected (`controller.gd`'s `is_manipulating()`), so
  rotating a part never also spins or teleports the player.

**Still open, not built yet:**
- Whole-model two-hand rotate/scale (vision brief's "Model movement" mode —
  currently only single-part manipulation exists, no two-hand gesture at
  all).
- Scale views (jump to real-life size, or a preset list, with a lock).
- STEP/glTF/OBJ/STL import in the *client* — the backend already has the
  pieces (see `docs/backend-api-notes.md`'s import-features section), this
  client only ever imports the native format so far.

## Known bug: teleport-preview marker not visible

`locomotion.gd`'s teleport marker (a flat cyan disc meant to show the
landing spot while aiming) doesn't render in-headset, even though the
teleport itself works (the blink happens on stick release). First
hypothesis was z-fighting with the Ground plane's visual mesh (both sit at
y=0) — raised the marker 2cm off the floor to test that. Didn't fix it, so
that wasn't the (whole) cause. Not chased further yet because this was all
being debugged blind, patching files over a remote device bridge with no
access to Godot's own console/output panel or breakpoints — a local session
with a real Godot editor open should be able to add a `print()` or two and
find this quickly.

## Untested paths

- **Standalone Quest APK.** Every test so far has been Godot editor F6 +
  Virtual Desktop PCVR streaming to a headset from a desktop. No APK has
  been exported or sideloaded onto a Quest yet — the README's cleartext-HTTP
  workaround note is still theoretical, not verified.
- **STEP/OBJ/STL import** (see above) — backend support exists and is
  documented, but nothing in this client calls it yet.

## Repo and secrets

Private repo: `github.com/DIDSA-UK/DIDSA-VR` (backend stays in the separate
`DIDSA-CAD` repo). `secrets.cfg` (gitignored) holds the real `backend_url`
and `api_key` for a given dev machine, loaded at runtime by `main.gd`;
`secrets.cfg.example` shows the format. These were previously hardcoded as
script defaults, which would have leaked the real API key into git history —
if you ever see a real credential as a literal default value in a script
again, that's a bug, pull it out the same way.

## How this has been worked on so far

Most of this was built through a conversational AI session with remote
access to John's Windows machine (file edits via a device-bridge shell, no
local terminal or Godot editor console visible to the AI), testing by
literally putting the headset on and reporting back what happened each
round. That loop works for feel/interaction bugs (several were only found
this way — a scale bug that put the player inside the model, inverted
locomotion, this doc's teleport-marker bug) but is slow for anything needing
real console output, breakpoints, or multi-file refactors. A local Claude
Code CLI session in this repo (with `gh` already authenticated, matching
whatever pushed DIDSA-CAD's PRs) is the better tool for sustained coding —
the conversational route is still useful for quick in-headset bug rounds and
for keeping the vision brief current.
