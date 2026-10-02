# Wrist tablet, window and keyboard redesign — plan

Status: agreed direction, not started. Supersedes `wrist-tablet-redesign-brief.md`
(an LLM-written brief written without access to this code) wherever they differ.
Sources: John's sketch, the concept renders (visual direction only — their
features are NOT in scope), and the existing code (`wrist_tablet.gd`,
`diegetic_panel.gd`, `popup_keyboard.gd`, `controller.gd`).

## Decisions made

| Topic | Decision |
|---|---|
| Input | Right-hand laser + trigger only (as today). Pointer layer kept swappable. No poke, no hand tracking. |
| Opening | Shoot the wrist icon, as today. Never opens by itself. No Peek state. |
| Scope | Restructure + reskin what exists. Concept-only features (angle measure, snap modes, saved measurements, DOF bar, Annotate…) are added later, tool by tool, as the client grows. |
| Approach | New tablet built beside the old one behind a switch; old one deleted once John signs off. |
| Categories | Keep View · Assembly · Windows · Files. Grid is 4 columns × 2 rows (8 slots); a second row only appears once a 5th category is registered. Settings, Undo, Redo, Close live in the utility cluster (top right). |
| Rail tools | Keep today's: View → Navigate / Scale / Visibility / Environment; Assembly → Mates / Colours / Sections / Measure. |
| Lists | Contextual side panel AND separate floating windows both stay (Assembly Tree remains a window; the side panel is added for Mates / Measure results / Files). |
| Numeric entry | Floating popup keyboard stays (right-stick click). No embedded numpad for now. |
| Active tool | One tool-mode tool active at a time. A small badge on the right hand's tracking ring shows which. |
| Keyboard | Restyled to match, and movable via a bottom handle, copying the floating-window handle. |
| Windows | Borders, header, handle and corner brackets restyled to match. |
| Look | Dark navy + cyan, rounded, from the concept renders. `StyleBoxFlat` + theme tokens first; no third-party icon/audio libraries yet. Icons: CAD's SVG set where it has one, otherwise drawn in the same 48 px / 1.5 px-stroke style. |
| Size | ~0.40 × 0.26 m, same physical text size as today (≈2667 px/m → ~1070 × 700 px). Refine on the wrist later. |
| Test | John tests once, on PCVR (Virtual Desktop, Quest 3). Quest-standalone performance remains unmeasured. |

## Rules for the new one-active-tool behaviour

* "Mode tools" = Mates, Measure, Sections, Shoot-to-hide. At most one is on.
* Selecting a mode tool in the rail turns it on and turns any other off.
  Pressing its on/off switch in the tool header turns it off.
* Looking at a non-tool page (Scale, Colours, Files…) does NOT change the active tool.
* Closing the tablet does NOT turn the tool off — you need to pick things in the
  world with the laser. That is exactly what the hand badge is for.
* The Navigate toggles (model movement / user movement / part manipulation) are
  modes of the hands, not tools, and stay independent.

## Phases

### Phase 1 — Foundation (almost no visible change) — DONE
* Extract the laser → SubViewport pointer plumbing from `wrist_tablet.gd` into one
  shared component (`scripts/ui/laser_surface.gd`). The new tablet uses it in
  Phase 2; `diegetic_panel.gd` and `popup_keyboard.gd` adopt it in Phase 3 with
  their restyle, so Phase 1 touches none of the working windows or keyboard.
  Move the headset-hardened logic verbatim: pointer frozen during a press, slider
  drag, stick scroll, click lockout after open, `ui_hover` / `ui_hit_distance`
  claim protocol.
* One `Theme` resource holding the colour / radius / spacing / font tokens, and
  one shared "panel chrome" style, used by tablet, windows and keyboard.
* Registry: `CategoryDef`, `ToolDef` (id, icon, label, page builder, kind =
  mode-tool or page, optional list provider). Adding a tool = a data edit.
* **UI Lab**: a plain desktop scene (`lab/ui_lab.tscn`) showing the new tablet UI,
  a window and the keyboard, mouse-driven, so layout and look can be iterated
  without a headset.
* Get Godot 4.7 headless working in the sandbox (GitHub release downloads
  look reachable), so the existing suite and new tests run here.
* Done when: existing `tests/run_all.sh` is clean, the old tablet still works.

### Phase 2 — The new tablet — DONE (headless/software-render verified; see docs/status.md)
* Shell per the sketch: category grid (4×2), utility cluster, tool rail
  (scrolls, label on hover), tool header (name, on/off switch, "?" help),
  controls pane, status/hint line.
* Wrap the existing page builders (Navigate, Scale, Visibility, Environment,
  Mates, Colours, Sections, Measure, Windows, Files, Settings) — same behaviour,
  new frame; no new features.
* Contextual side panel on the right edge, angled toward the user: Mates,
  Measure results, Files. Opens only when the active tool has a list.
* Undo/redo with disabled styling; long-press shows the existing command-stack
  labels as a short history.
* One-active-tool manager + the right-hand badge.
* Old/new tablet switch (single export on Main).
* Tests: new `tablet2_*` tests; old tablet tests untouched.

### Phase 3 — Windows and keyboard — DONE (headless/software-render verified; see docs/status.md)
* Restyle `DiegeticPanel` (border, header, handle, resize brackets) and
  `PopupKeyboard` (keys, display, border) from the same tokens.
* Keyboard handle: factor the handle grab/release/reach logic out of
  `DiegeticPanel` into a small shared piece; the keyboard joins the
  `diegetic_panels` group so `controller.gd`'s existing grip check finds it.
  The grab keeps the pose relative to the hand, so the 30° lean of the full
  keyboard is preserved. Default: it reopens where you left it, per layout
  (numeric / full), within the session.

### Phase 4 — Polish and handoff — BUILT (the PCVR pass and the old-tablet removal remain; see docs/status.md)
* Tween animations (open/stow, category switch, hover/press, list slide) with
  a Reduce-motion setting; haptic and sound hooks through one `UIFeedback`
  script (assets can be dropped in later).
* Vector icons replace the pixel-stamped ones.
* Perf: move the pointer cursor out of the SubViewport so the tablet only
  re-renders when something changes.
* Docs: `docs/status.md`, `README.md`, `tests/README.md`.
* John's single PCVR test. Fix list from that. Then delete the old tablet.

### After the redesign (optional) — look-dev
Concepts using shaders and library art, built in the UI Lab so John can try
them himself. See "Shaders and library art" below.

## Shaders and library art — what to expect

* **Shaders** are plain `.gdshader` text files. Dropping one in means giving a
  `ShaderMaterial` to a panel, an icon or the tablet quad; it is not a package
  to install. I'd write the few we need in-house (glass tint + edge glow,
  press glow, shimmer): short, no licence questions, tuned for the Mobile
  renderer. godotshaders.com shaders also work, but licences vary per shader
  and many assume the Forward+ renderer.
* **Limit worth knowing**: a UI inside a SubViewport can't see the 3D world
  behind it, so a true frosted-glass blur isn't possible. It is a fake
  (tint + gradient + edge highlight), which usually reads well. Making the panel
  actually translucent to the world is possible but costs transparency overdraw.
* **Library art**: SVG icons import natively; CC0 assets (e.g. Kenney sounds)
  drop straight into the project. Style is the catch — game-style UI kits
  clash with this look. Material Maker (free desktop tool, exports Godot
  materials) is something you can play with outside the project; check its
  licence on the repo before shipping anything made with it.
* **Playing with it yourself**: yes. After Phase 1 the look is controlled by one
  theme resource and a few shader parameters, and the UI Lab shows the result
  live in a normal window — change a value in the Inspector, see it.
* **Performance caveat**: you test on PCVR, which hides Quest 3 standalone
  cost. Anything translucent or shader-heavy should have a quality lever.

## Deviations from the plan while building (Phase 2)
* Shoot-to-hide became its own rail entry (View > Shoot hide) because it is a mode tool.
* Vector icons were pulled forward from Phase 4 into Phase 2 (needed for the rail, grid and badge).
* The hand badge sits on the right hand's tracking ring: the button discs no longer exist.
* The new tablet stays behind `Main > Wrist tablet > use_new_tablet` (default off) until Phase 4's PCVR pass.

## Themes and shader effects — BUILT (first look-dev slice)
Navy / Simple / Dark themes and a one-switch shader effects layer, in Settings > Appearance. See docs/status.md.

## Ergonomics round (2026-10-02)
Tablet tipped 30 degrees toward the user; side panel parallel to the tablet's right edge with its far edge turned 5 degrees toward the user; wrist watch and hand rings restyled and the watch moved back; Mates/Measure highlight the hovered and picked face only. See docs/status.md.

## Closure plan (2026-10-02) — John signed off the new tablet after PCVR testing

The new tablet beat the old one in the headset, so the old one goes. What is left falls into
three groups: remove the old tablet (mechanical, VR-only), close two known code gaps, and the
headset-only checks that only John can do.

### A. Remove the old tablet
Size: 1842-line `scripts/wrist_tablet.gd`, the `Main.use_new_tablet` switch, and 10 tests pinned to
the old one with `main.use_new_tablet = false`.

1. **Audit (first, small).** List the old tablet's public methods/properties that anything outside
   it calls (`main.gd`, `controller.gd`, `locomotion.gd`, the keyboard, the windows, tests) and
   confirm `wrist_tablet_v2.gd` has each. Anything missing is ported, not dropped.
2. **Triage the 10 pinned tests, line by line** (about 240 SMOKE lines). Each line is: *covered* by
   `tablet_v2` / a shared-component test (delete), *tablet-independent* (keep, point at the new
   tablet or at the underlying class), or *unique* (port to the new tablet).
   * Mostly page tests, expected to be mostly covered or portable: `tablet_scene`, `tools_tab`,
     `section_tab`, `windows_tab`.
   * Touch the tablet only incidentally (3-4 references each), expected to need only the pin and
     the aim helper changed: `popup_keyboard`, `full_keyboard`, `e2e_mates_motion`.
   * Mixed, need real care: `bug_round` (stick scrolling, Files list, press/hover state),
     `features_round` (speed slider), `laser_and_left_hand` (left-hand laser, close/open).
   Output of the triage is a short table in `tests/README.md` of what moved where, so nothing the
   old tests guarded quietly disappears.
3. **Delete** `wrist_tablet.gd`, the `use_new_tablet` export and the switch in
   `main.gd::_add_wrist_tablet()`, and any old-only helpers left in `main.gd`.
4. **Rename** `wrist_tablet_v2.gd` to `wrist_tablet.gd` (and `tablet_v2*` tests to `tablet*`) once
   nothing else is called "v2", so the codebase has one tablet and one name. Update the ~8
   comments that cite the old file (`controller.gd`, `diegetic_panel.gd`, `locomotion.gd`,
   `popup_keyboard.gd`, `laser_surface.gd`, `tablet_pages.gd`).
5. **Docs**: README, `tests/README.md`, `docs/status.md`, `docs/backend-api-notes.md`; mark this
   plan done.
6. **Gate**: full `tests/run_all.sh` against a fresh baseline (test count falls; every removed
   SMOKE line accounted for in the triage table), software render of the tablet, commit, push.

Order: 1, 2, 3 in one commit so the tree never has tests pointing at a deleted file; 4-6 follow.
Estimated as one session; the triage is most of the effort.

### B. Close the known code gaps
1. **Section planes don't clip the face highlight** (small). Give the highlight material a
   clip-aware unshaded shader reading the same global uniforms as `shaders/section_clip.gdshader`
   (`section_plane_*`, `section_enabled`). Test: render under Xvfb, highlight discards on the cut side.
2. **Edge and vertex picking and highlight** (the real gap; cross-repo, own milestone). Today the
   client can only resolve a laser hit to a face (`docs/backend-api-notes.md`), so Measure cannot
   take an edge/vertex and Mates cannot take a circular edge from the headset, and there is
   nothing to highlight. Needs:
   * **DIDSA-CAD**: export edge geometry and identity with the mesh (per-body edge polylines
     keyed by the same ids the measure/mate endpoints accept; vertices derive from edge ends).
     Backend tests alongside.
   * **VR**: pick the nearest edge or vertex within a small angular threshold of the hit point on
     the hit face (face wins otherwise); extend `mates_tool` / `measure_tool` picks with
     `shape_type`; extend `face_highlight.gd` to draw an edge as a lifted polyline and a vertex
     as a small marker, in hover and pick colours.
   * Decision for John: edge/vertex picking in Measure first (it is the tool that names them in
     its prompt), with Mates' circular-edge concentric picks as the second step.
3. Anything John's PCVR notes list (tablet size, panel angles, timings) is applied as a fix list
   to the new tablet before the old one is removed, so the rename in A4 happens once.

### C. Checks only John can do (headset)
* The ergonomic round (30 degree tilt, side-window angle, watch position, ring restyle, face
  highlight) is built but unverified in a headset.
* **Quest 3 standalone has never been measured**: every test so far is PCVR or headless. Before
  any Quest APK, run `tests/gpu_timing.gd` (or the in-headset equivalent) on the device with the
  tablet, side panel, a window and the keyboard open, shader effects on and off. The effects
  toggle is the quality lever if it is too heavy.

### Stays parked
Hand tracking / poke, Peek state, world-pinned tablet, handedness mirroring, embedded numpad,
composition-layer rendering, concept-only tools, third-party icon/audio pipeline, optional
look-dev stage.

## Not in this plan (parked)
Hand-tracking/poke · Peek palm-up state · pinned world-locked tablet ·
handedness mirroring (laser is hard-wired to the right hand in
`controller.gd`/`locomotion.gd`) · embedded numpad · composition-layer
rendering spike · concept-only tools · third-party icon/audio pipeline.

## Risks
* Nothing here is headset-verified until John's PCVR pass; the earlier tablet
  bugs (press cancelled by drift, laser passing through, first-claim
  arbitration) were all invisible headless.
* 11 tests reach into tablet internals; the new tablet gets its own tests so
  the old ones keep guarding the old tablet until it's removed.
* The keyboard and windows are touched in Phase 3, so their existing tests
  (`popup_keyboard`, `full_keyboard`, `windows_*`, `features_round`) must stay green.
