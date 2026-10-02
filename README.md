# DIDSA VR spike (Godot)

Milestones 0 (glTF endpoint + engine choice), 1 (import and viewport) and 4
(assembly environment — mates, colours, sections, measurements) are all
done, in the "headless- and real-backend-confirmed, not yet on a real
headset" sense every section below spells out — see "What 'done' looks
like" for each. Milestone 3 (floating windows) is now mostly done: the
Assembly Tree, Calculator, Image Viewer and Browser windows are all built
(see item 15 below) — the Browser window also serves as the PDF reader
(Chrome's own built-in PDF viewer, confirmed working through the same
mechanism — see docs/status.md), so only "DIDSA-CAD as a flat window"
remains unattempted. Milestone 2 (design table / in-VR part modelling)
hasn't been started. Still plain Godot 4 core (no `godot-xr-tools`, no
addons) — the Browser window's one exception to that is documented in
item 15 below (a separate server-side relay, not a Godot dependency).

**Redesign in progress:** the wrist tablet, floating-window chrome and popup keyboard
are being redesigned — plan in [`docs/wrist-tablet-redesign-plan.md`](docs/wrist-tablet-redesign-plan.md).
Try the new look without a headset: open `lab/ui_lab.tscn` in the Godot editor and press F6;
tune it by editing a preset in `ui/themes/` (Navy / Simple / Dark; the Lab has buttons for them and for the effects). To see the new tablet in the headset, tick **Use New Tablet**
on the Main node's Inspector (group *Wrist tablet*); it is off by default while the old tablet below
is still the reference.

**Picking this up fresh (including a new Claude Code session)?** Read
[`docs/status.md`](docs/status.md) first — what's built, what's open,
untested paths. [`docs/backend-api-notes.md`](docs/backend-api-notes.md)
covers the DIDSA-CAD endpoints this client depends on.
[`docs/vision-brief.md`](docs/vision-brief.md) is the fuller product vision
(milestones, interaction model, open decisions) — a point-in-time export, not
live-synced.

## What it does

1. On start, tries to activate OpenXR. On a headset (or a PCVR runtime on
   desktop) you're in VR; otherwise it runs as a flat 3D preview so you can
   sanity-check the download/parse step without a headset attached.
2. Reads `assembly.didsa` (or whatever `native_file_path` points at) from
   this project folder and `POST`s it to `{backend_url}/document/import/native`
   — this is the same "load a project" step the Flutter app does, just done
   once at startup here so the backend actually has your assembly in memory.
   The part id to load is read straight out of that file's own
   `document.root_part_id` field — nothing to look up or type in by hand.
3. Downloads `GET {backend_url}/document/parts/{part_id}/assembly-mesh.glb`
   with your `X-API-Key`, parses it with Godot's built-in `GLTFDocument`, and
   drops the result about a metre in front of you.
4. Each mesh can be manipulated two ways ("Individual part manipulation" in
   the vision brief), and the two are independent of each other: **grip**
   (either hand) grabs the part your hand is touching — anywhere on it, not
   just near its middle (inside its bounding box or within 5 cm of it; a
   light cyan highlight shows what a grip would take). The part stays
   attached exactly where you took hold, so turning your hand turns it about
   that spot; its position (not its rotation) goes through the same
   Steadiness filter as whole-model moves, so a held hand's tremor doesn't
   reach it — it drops on release, regardless of what's selected. Separately,
   point at a part from a distance with the **right hand** — a real ray test
   against its actual geometry (not just a cone around its origin point, so
   big and overlapping parts pick correctly; nearest hit wins) highlights it
   pale yellow and shows its name — and pull the **right trigger** to select
   it (trigger again, or aim at nothing, to deselect) — while selected, the
   **right thumbstick** rotates it about the point the ray hit (or its
   centre), relative to how you're currently looking (left/right spins it,
   up/down tips it away/towards you, not around the part's own possibly-
   tilted axes), and **A/X**/**B/Y** pull it nearer or push it farther (both follow where
   you aim the controller — tilt it and the part swings with it) — at a
   speed proportional to how far the part is from your hand (0.18 m/s at
   30 cm, 0.6 m/s at 1 m, 3 m/s at 5 m), so far parts travel quickly and near
   ones can be placed finely. The **left** trigger/thumbstick don't do this —
   left-hand select used to block left-hand walking (see item 5) whenever a
   part was selected there, so laser-select is right-hand only for now,
   freeing the left trigger up for a later tool (not decided yet); left grip
   is unaffected and still grabs normally. A thin white laser shows where
   you're aiming (from a small white sphere marking each hand's own
   origin), shortening to stop exactly on whatever it's actually hitting (a
   part, or the wrist tablet/popup keyboard) rather than always drawing at
   a fixed length; selected parts get a yellow highlight. Every part move
   (grip-drag or laser rotate/nudge) is undoable — see the wrist tablet's
   Undo/Redo below. Each controller also carries a thin floating ring
   (a stylised tracking halo), set back towards you from the hand. (The
   thumbstick/button discs it used to carry were removed after headset
   testing.)
5. Walk with the **left thumbstick** (relative to where you're looking); the
   **right thumbstick**'s X axis snap-turns (push right = turn right), its Y axis aims and blinks a
   teleport (push forward and point the right hand's laser at the floor — a
   cyan ring marks where it lands, within 5 m — release to jump there). Either stick backs off automatically while that hand has a
   part selected, so rotating a part never also turns or teleports you; the
   right stick also backs off while its laser is on the wrist tablet or a
   floating window, where it scrolls that panel instead (tablet: push down =
   scroll down).
6. Grip on **empty space** (not near a part) to grab the whole model. With
   **one hand** it follows that hand (moves only, so a wrist twitch never
   spins it). The one-hand drag scales with the model: 1:1 for anything up
   to about 1.2 m across, then proportionally faster (a model 12 m across
   moves 10 cm for every 1 cm of hand, capped at 15x), so big models don't
   need endless re-grabbing. With **both hands** it moves with them (dragging
   is amplified by that same size-based gain, so a big model doesn't need
   endless re-grabbing two-handed either), turns as you swing the line
   between your hands, and scales (3x as sensitive as the raw hand spread,
   `scale_gain`) as you spread or close them — turning and scaling are
   deliberately left at their own raw sensitivity, not gain-amplified, so a
   given wrist swing always turns the model by the same angle regardless of
   its size. Pivots on the midpoint between your hands (or, once the drag
   gain has carried the model away from your hands on a big model, a virtual
   point that tracks it). Every turn builds on the model's current
   orientation, so you can rotate about one axis and then another naturally.
   Switching between one and two hands never makes the model jump.
7. **Wrist tablet.** **(The redesigned tablet is now the default — see "The redesigned
   tablet" below; untick `Main > Wrist tablet > Use New Tablet` for the old one described
   here.)** A small thin-white-line icon — a ring with a landscape
   rectangle inside it, like a tablet — floats above your left wrist (it
   swells slightly and tints pale blue on hover). Point the right hand's
   laser at it and pull the trigger to open the tablet; press the **X** on
   the tablet to close it. It never
   opens by itself, so looking at your wrist can't trigger it. While the
   laser is over the bullseye or the tablet, the trigger presses those
   instead of selecting a part — the laser itself shortens to stop exactly
   there, with a soft glow where it lands, rather than passing through.
   **Undo**/**Redo** buttons sit above the categories, visible whatever
   category is open — see item 9 below. Navigation is a left-hand category
   rail plus a small **Settings** cogwheel pinned to the top-right corner
   for set-and-forget stuff (day-to-day tools don't belong beside it):
   - **View** — how you move around and look at the model.
     - **Navigate** — switch model movement, user movement and part
       manipulation on or off independently; **Travel speed** slider —
       how fast the left thumbstick walks you, from your normal walking
       pace (1.5 m/s, the bottom of the slider and the default) up to 30 m/s
       for crossing a large open space such as a house's grounds or a small
       village (exponential, so the low end stays fine-grained). Press the
       trigger on the slider and sweep the laser to drag it.
     - **Scale** — jump to 1:10, 1:5, 1:2, 1:1 (real life), 2:1, 5:1 or 10:1
       about the model's centre; lock the scale (also stops the two-hand
       spread/close and Fit from resizing); **Fit to view** brings the whole
       model in front of you at a comfortable size; **Home** returns it to
       where it first loaded (not while the scale is locked). For an exact
       value, click the **right thumbstick** — see item 8.
     - **Visibility** — see item 10.
     - **Environment** — see item 16 below: Light/Dark/Mid rendered
       backdrops, plus Passthrough (OpenXR mixed reality).
   - **Assembly** — the vision brief's assembly tools: **Mates** (item 11),
     **Colours** (item 12), **Sections** (item 13), **Measure** (item 14).
   - **Windows** — see item 15.
   - **Files** — load a model from the `models/` folder next to
     `project.godot` (or `user://models`, which also works in an exported
     build), plus the Settings cogwheel's own project folder if one's been
     set (item 16). A `.glb`/`.gltf` loads straight from disk, no backend at
     all, read as metres (change `local_glb_scale` on Main if yours are in
     millimetres). A `.step`/`.stp`/`.stl`/`.obj` needs a configured backend
     (see `secrets.cfg.example`) — the client can't decode these itself, so
     it creates a new Part on the backend, uploads the file to
     `POST /parts/{id}/import-features`, then fetches and renders it the
     same way as any other backend part. The `models/` contents are
     git-ignored. A `.didsa`/`.DIDSAprt` file already backend-loaded also
     gets an **Add** button, merging its own Part into the *currently
     loaded* assembly instead of replacing it (`POST
     /parts/{id}/add-component`) — needs a configured backend, same as
     STEP/STL/OBJ; a status line under the file list (fed by the same
     text `main.gd`'s own load/add/import functions always set) says why
     nothing happened if it can't, rather than the button just silently
     doing nothing.
   - **Settings** (corner cogwheel) — **Steadiness** (Off / Light / Medium /
     Strong): an adaptive filter on your hands while you hold the model *or*
     grip a single part, so a held hand doesn't shake it but deliberate moves
     stay direct (measured: Medium removes ~80% of a simulated 2 mm hand
     tremor and adds about 1 mm of lag on a slow 2 cm/s move — same numbers
     either way, whole-model or a single held part). **Display**: fps,
     CPU/GPU render time, script and physics time, part count, draw calls,
     load times; plus the levers for speed: **Shadows**, **Resolution**
     (100/80/65% of the headset runtime's size) and **MSAA**. Read GPU vs
     CPU ms first: over about 11 ms GPU (at 90 Hz) means lower Resolution or
     MSAA; high CPU means scripts. **Project folder** — an arbitrary
     absolute path (e.g. a shared network mount) the Files category also
     scans, typed on the popup keyboard; persisted to `user://settings.cfg`
     so it survives a restart. The tablet only renders and measures while
     open.

   With no `secrets.cfg` the app now starts anyway, ready for a local file.
   **The redesigned tablet** (default; `scripts/ui/wrist_tablet_v2.gd`, plan in
   `docs/wrist-tablet-redesign-plan.md`). Same wrist icon, same "shoot it to open, never
   opens by itself", right-hand laser only. A 0.40 x 0.26 m panel laid out like the sketch:
   a **category grid** top-left (View, Assembly, Windows, Files; up to 8 in 4 x 2, a second
   row appears from the 5th), **Undo / Redo / Settings / Close** top-right, a **tool rail**
   down the left, the tool's controls in the middle under a header (name, **Tool: ON/off**
   switch for tools that change what the laser does, **?** help card) and a one-line
   **status bar** at the bottom. A **side panel** angled beside it lists what the tool has
   a list of: existing mates (Delete asks "Sure?" first), measurement results, model files
   (Open / Add) or, after a **long press on Undo**, the undo history. **One tool at a time**:
   Mates, Measure, Sections and Shoot hide (View > Shoot hide) are mode tools; tapping one
   turns it on and any other off; browsing never changes it; closing the tablet doesn't
   either — a **badge** above your right hand's ring shows which is active. Settings (the
   sliders button) has Steadiness, display, **Comfort** (Reduce motion, Haptics Off / Low /
   Normal / High), **Sound on/off and Volume** (the UI's sounds are synthesised in code) and the project folder. Look and sizes: the presets in `ui/themes/` (Navy,
   Simple, Dark); try them without a headset in `lab/ui_lab.tscn` (F6 in the editor).
   **Settings > Appearance** switches theme and turns the **shader effects** (a glass
   edge-glow and soft highlight over every panel, and a glow on hovered / selected buttons)
   on or off; every tablet, window and keyboard re-themes live.

8. **Popup keyboard.** Click the **right thumbstick**, anywhere, to open a
   numeric keypad floating in front of you, pre-filled with the model's
   current scale multiple — its first real use, per the vision brief's "for
   any text entry" (reserved since the wrist tablet was built). Type a new
   number (the first keystroke replaces the pre-filled value rather than
   appending to it) and press **OK** to apply it — this goes through the
   same scale-preset code as the Scale tab's buttons, so it's undoable the
   same way; **Cancel**, or clicking the right thumbstick again, backs out
   without applying anything. Aim and click its keys with the right hand's
   laser and trigger, same as the wrist tablet. **Anything that needs real
   text gets a FULL keyboard instead** — a wide QWERTY (digits, letters,
   **Shift** for one capital, **Caps**, a **?123** symbols layer, and URL
   keys: `/` `:` `.` `-` and a **.com** key) that opens low and leans back
   like one on your lap, so it doesn't cover the window in front of you.
   It's used for the Browser's web addresses and typing into pages (below),
   the Colours tab's custom hex colour, and the Settings project-folder path;
   the numeric keypad stays for numbers (scale, mate values). Like the floating
   windows, the keyboard has a **grab handle** at the centre of its lower edge:
   **grip** it with either hand to carry the keyboard somewhere more comfortable,
   release to drop it. It reopens where you left it (one spot for the keypad, one
   for the full keyboard) until you walk more than 3 m away.
9. **Undo/redo.** Every part move (grip-drag, or laser-select rotate/nudge),
   whole-model move (one/two-hand drag, and the Scale sub-tab's
   presets/Fit/Home), and Visibility hide/show action goes onto one shared
   history — **Undo**/**Redo** on the wrist tablet step back/forward through
   it. A drag that ends up back where it started doesn't push anything. The
   history is cleared whenever the model is replaced (loading a different
   file), since it can't point at parts that no longer exist.
10. **View > Visibility.** **Shoot to hide** — toggle it on, then point the
    right hand's laser at a part (same hover highlight as normal selection) and
    pull the trigger to hide it. **Hide all** / **Show all** toggle every
    part at once. **Reverse visibility** flips every part's hidden/shown
    state. **Isolate selected** hides everything except whichever part is
    currently laser-selected (select it first, then press Isolate). All
    four are undoable. A hidden part is click-through for both the laser
    and grip — it's out of the way, not just invisible.
11. **Assembly > Mates** (milestone 4). Toggle **Mates tool** on, then point the
    right hand's laser at a face and pull the trigger to pick it (while the
    tool is on, only the face under the laser lights up, and a picked face
    stays lit — first pick cyan, second orange) — pick a face on a second, different
    part to complete a pair; a status line explains why a pick didn't count
    (picking the assembly's own unplaced content, the same part twice, or a
    part from a different assembly all reject with their own message).
    Choose a **mate type** (Coincident/Concentric/Parallel/Distance/Angle),
    **Flip** and **Allow rotation** as needed, and for Distance/Angle tap
    **Set value** to type an exact number on the popup keyboard (mm for
    distance, degrees for angle). **Create mate** posts a real Mate to the
    backend (`POST /parts/{id}/mates` — the same endpoint DIDSA-CAD's flat
    app uses, so a mate created here is readable and editable there too) and
    solves it into place immediately, unless **Relax all** is on, letting
    you place several mates before solving them all at once with **Enforce
    all**. **While mates are enforced** (the default), parts move as their
    mates demand: a mated part you grab, or nudge/rotate with the laser,
    slides along whatever its mates allow instead of following your hand
    freely — smoothly: the backend tells the app once how the part may move
    (its free directions) and the app applies your hand's motion to those
    directions locally every frame, re-checking with the backend only a few
    times a second, and stays where you put
    it in every direction the mates leave free — nothing flies off. Every
    move of a placed part is saved to the backend, so mates always solve
    against what you see. A **grounded** (fixed) part that has mates can't be
    moved while they're enforced — gripping it buzzes and the Mates page says
    why; **Fix / Float selected part** on that page picks which part is the
    anchor, and **Relax all** frees everything. Solve problems (a grounded
    part, mates that conflict) are reported on the Mates page instead of
    failing silently. Existing mates are listed below with a **Delete** button each,
    refreshed whenever the tab opens or a mate changes. Face-only for now —
    edge picking isn't wired up yet (see `docs/status.md`).
12. **Assembly > Colours** (milestone 4). Laser-select a part as usual (no separate
    picking tool — it acts on whatever's already selected), then tap a
    swatch to colour it, or **Custom hex…** to type an exact `#RRGGBB` on
    the popup keyboard. **Clear colour** removes the override. Each tap
    `PATCH`es the real backend (`PATCH /parts/{id}/occurrences/{id}` — the
    same field the flat app's own colour-disc row sets) and applies the
    change locally right away; **Clear** shows a plain neutral grey rather
    than reconstructing the part's exact prior look, which needs a full
    reload to see for real. Not undoable — pick a different colour (or
    Clear) rather than Undo.
13. **Assembly > Sections** (milestone 4). Toggle **Section tool** to spawn a
    translucent clip-plane disc (with a small arrow showing which side
    stays) a little in front of wherever you're looking. **Grip** the disc
    to drag/tilt it, exactly like grabbing a part; **Flip** swaps which side
    is kept without moving it. Entirely client-side — no backend call at
    all, since DIDSA-CAD's own sectioning endpoint re-tessellates a fresh
    OCCT boolean on every request, much too slow for a plane you're
    dragging in real time. One plane for now. A cut part shows a real
    (if not perfectly stencil-capped) filled cross-section rather than a
    hollow shell — real-headset feedback found a solid part clipped past
    its own midpoint looked like it had simply vanished, not been cut open,
    tracked to three things: the discarded half's own interior surfaces
    were being culled away instead of shown, the fully metallic/fully rough
    material rendered close to black, and — the one that made the whole
    model vanish as the plane crossed its origin — the shader computed the
    fragment's world position from a view-space `VERTEX` (see
    `shaders/section_clip.gdshader`'s own docstring for all three fixes).
    Turning the tool off drops the gizmo and restores every part's real
    appearance. Undoable (one command per grab/drag), toggling the tool and
    Flip are not.
14. **Assembly > Measure** (milestone 4 — the last of the four assembly tools).
    Toggle **Measure tool** on, then point the right hand's laser at a
    vertex/edge/face and pull the trigger to pick it (hover and picks
    highlight the face itself, not the whole part; today only faces are
    pickable from the headset, so edges/vertices light up once they can be
    picked) — unlike Mates, the currently-open Part's own
    unplaced content is a valid pick here, and so is a second pick on the
    very same part (measuring across two features of one part is the
    common case, not a "two different parts" rule). One pick shows that
    entity's own length/area/radius/diameter/point immediately; a second
    pick re-queries for the distance/delta between them (plus axis/normal
    distance when detected) — no Create button, nothing is persisted
    (`POST /parts/{id}/measure` — the same read-only endpoint DIDSA-CAD's
    flat app uses). A third pick starts a fresh measurement rather than
    being capped at two. **Clear** resets it. Not undoable — there is
    nothing to undo, only a live read-only query.
15. **Windows** (milestone 3). Four free-floating panels, each with its
    own toggle button, that can be open at the same time as each other and
    the wrist tablet — not wrist-mounted; each spawns in front of wherever
    you're looking and closes with its own **X**. Each also has a small
    grab handle at the centre of its own lower edge — **grip** it with
    either hand to drag the whole panel somewhere else, release to drop it;
    windows otherwise stay exactly where they first opened. While the
    laser is on a window with a list in it (the Assembly Tree, the Image
    Viewer's picker), the **right thumbstick scrolls it** (push down = down).
    **Image Viewer and Browser can be open several at a time**: the tablet
    button opens one, and another with every further press (each has its own
    close; closing one leaves the rest). Every window's **close button (and
    the Image Viewer's Back button) grows with the window**, so a big window
    keeps big, easy targets. They're also
    **resizable**: four bracket-shaped corner targets (a generous ~10 cm
    each) sit just outside the corners — aim
    the right laser at one and it lights up cyan; hold the trigger and drag
    (the opposite corner stays put). It's a true resize, not a zoom: the
    window's content area grows at the same text size, so a bigger Browser
    shows more page and a bigger Tree more rows:
    - **Assembly Tree** — browses the loaded assembly's Occurrence
      hierarchy (a real client to `GET /parts/{id}/occurrences`, recursed
      lazily as you expand a row — the same endpoint the Colours tab's
      "whole group" already uses) and lets you tap a row to select that
      part, the same way laser-selecting it would, without first having to
      already be looking at it. A row for a sub-assembly (one with its own
      children) has no geometry of its own to select and says so rather
      than doing nothing. Pulling a tree row out into world space isn't
      built yet — see docs/status.md.
    - **Browser** — a live view of a real headless-Chromium tab (URL bar,
      back/forward/refresh, click-to-interact; **poke the address bar or Go**
      to type a web address on the full keyboard — a bare `example.com` gets
      `https://`, plain words become a web search — and **Aa** to type into the
      page: click a text box on the page, press Aa, and the keyboard stays open
      sending each key straight to the page until **Done**), run by a separate
      server-side "browser relay" service (`browser-relay/` in the
      DIDSA-CAD repo) over a plain authenticated WebSocket carrying the
      Chrome DevTools Protocol (CDP) — see `scripts/browser_window.gd`'s
      own docstring for the full design and docs/status.md for how this
      replaced the originally-scoped native CEF/webview approach (which
      turned out to have no Android/Quest build at all). This is also the
      PDF reader: point it at a PDF URL and Chrome's own built-in PDF
      viewer renders it inline — confirmed for real (see docs/status.md),
      not a separate feature. Needs `[browser_relay]` set in
      `secrets.cfg` (see `secrets.cfg.example`); shows "No browser relay
      configured" instead of failing if it isn't.
    - **Calculator** — a plain arithmetic keypad, no backend involved.
    - **Image Viewer** — picks an image (`.png`/`.jpg`/`.jpeg`/`.webp`/
      `.bmp`) from the same `models/`/`user://models` folder the Files tab
      already reads. Pick one and it **fills the window** (aspect kept, the
      file name as the title); the header's **< Back** returns to the
      scrollable picker. No pan/zoom — resize the window instead.

    All three are built on a shared free-floating-panel mechanism
    (`scripts/diegetic_panel.gd`) that any future window can reuse. Several
    can be open together: each frame, only the first one the laser actually
    hits claims the trigger, so at most one ever reacts to a given pull —
    see that script's own docstring if you're adding a fourth window.
16. **Floor and Environment.** The floor is an infinite-looking grid
    (`shaders/infinite_grid.gdshader`, a large plane that fades out well
    before its own edge) — thin white 600×600mm lines at ~60% transparency,
    replacing the original spike's opaque square plane, which used to hide
    anything that dropped below floor level. **View > Environment** switches
    the rendered backdrop between **Light**, **Dark** and **Mid** presets
    (`scripts/environment_manager.gd`, a `WorldEnvironment` node driving
    background colour, ambient light and the one `DirectionalLight3D`), plus
    **Passthrough** — real OpenXR mixed reality (the headset's own camera
    feed) on a Quest or another passthrough-capable runtime (via the OpenXR environment blend
    mode; the Environment page's status line says whether it's on and, if not, what the runtime
    offers — a standalone Quest build also needs the OpenXR Vendors plugin, not included); on desktop or
    an unsupported runtime it falls back to a plain black background and
    says so. The last-picked scene is remembered across restarts
    (`user://settings.cfg`, via the Settings cogwheel's own project-folder
    setting — see item 7).

## 1. Drop in a real assembly

Export or copy a saved assembly file — a `.DIDSAprt`/`.didsa` file whose
**root Part has occurrences on it** (an assembly, not a bare single part;
that's what makes the grab test meaningful) — into this project folder,
next to `project.godot`, named `assembly.didsa`. It's plain JSON regardless
of the extension on the original file, so a straight copy/rename works.

If you'd rather not rename your file, or want to keep several around, change
`native_file_path` on the Main node instead (see below).

## 2. Set up the backend connection

Copy `secrets.cfg.example` to `secrets.cfg` (same folder as `project.godot`)
and fill in the two real values — this file is gitignored, so it never gets
committed, unlike the old approach of typing them into the Inspector (which
saves them straight into the tracked `.tscn` scene file):

```ini
[backend]
url="http://your-backend-host"
api_key="your-CAD_API_KEY"
```

- `url` — your server's address. **Use your Cloudflare Tunnel HTTPS URL if
  you have one** (e.g. `https://cad-api.snail-shell.uk`) rather than a bare
  LAN IP — Android blocks plain HTTP to anything but `localhost` by default,
  and switching that off needs a custom Gradle build, which is more setup
  than this project needs. If you only want to test on the desktop preview
  (not on-headset), a LAN `http://` URL works fine since that restriction is
  Android-only.
- `api_key` — matches your backend's `CAD_API_KEY`.

If `secrets.cfg` is missing, the app prints that to the console (and to
`main.status_text`) instead of silently trying (and failing) to hit an empty
URL.

A few more knobs live on the **Main** node's Inspector, under **Backend**,
if you need to change them from their defaults:

- `native_file_path` — defaults to `res://assembly.didsa`; only change this
  if you named your file something else.
- `part_id_override` — leave blank. It's only there for the rare case you
  want to skip the import step entirely and point straight at a part id
  that's already loaded in the backend's session some other way.
- `quality` / `tier` / `include_hidden` — same meaning as the JSON endpoint;
  the defaults (`0.5`, full tier, hidden omitted) are fine to start.

Note: the import call and the mesh-fetch call both go out with no
`X-Document-Session` header, so both land in the backend's `"default"`
session — consistent with each other, but a *different* session than
whatever the Flutter app is using if it's open on your tablet at the same
time (it sets its own session id per launch). Close the Flutter app's
connection to this backend or don't rely on it having the same in-memory
state while you're testing the spike, if that matters for what you're
checking.

## 3. Desktop preview (no headset needed first)

Press **F6** (run current scene) in the editor. You should see the console
log the import, then the download and part count. This alone tells you
whether the endpoint, API key and glTF parse are all working, before you
touch export/sideload at all.

## 4. Export to Quest

1. In the editor: **Editor → Manage Export Templates** → download templates
   matching your Godot version, if you haven't already.
2. **Project → Export → Add… → Android.** Point it at your Android SDK if
   this is the first Android export on this machine (Godot prompts for the
   SDK path).
3. On the Android preset, under **Xr Features**, set:
   - `Xr Mode` → `OpenXR`
   - `Hand Tracking` → off (spike uses controllers only)
4. Export a debug APK.

## 5. Sideload and run

```
adb install -r path/to/exported.apk
```

Put the headset on, launch **DIDSA VR Spike** from Unknown Sources /
App Library → Quest Link's sideload list (however you normally launch
sideloaded apps). Reach a hand toward the loaded part and squeeze the grip
button.

## What "done" looks like for milestone 1

- The model loads and is recognisably your assembly, at real-world scale —
  `spawn_scale` defaults to `0.001` because the backend's native units are
  millimetres, but a raw glTF coordinate is read as one metre by Godot (and
  by the glTF spec generally). If a part still looks wrong-sized, that's
  the ratio to check first, not the model itself.
- You can see roughly where your hands are (a small glowing marker on each
  controller — bare `XRController3D` draws nothing on its own).
- All four of the vision brief's manipulation modes are built: individual
  part manipulation (grip to grab close, trigger-laser to select and then
  grip/thumbstick/A-B at a distance), user movement (thumbstick walk,
  snap-turn, teleport), whole-model movement (one/two-hand drag, turn and
  scale), and scale views (jump to real-life/preset scales, with a lock).
- Native `.didsa`/`.DIDSAprt` import, bare `.glb`/`.gltf` (no backend round
  trip), and STEP/STL/OBJ (via the backend's `import-features`) are all
  wired up — milestone 1's full "done when" list of formats. (Bare glTF
  import was never actually blocked on anything; it's Godot's own
  `GLTFDocument`, already used for local files.)
- You have a felt sense of load time and frame rate — but only over PCVR so
  far, never on real Quest hardware, which was the actual point of that
  bullet. The vision brief's payload estimates (~90–100 KB for a
  186-instance test assembly) still haven't been measured on-headset.

## What "done" looks like for milestone 4

All four of the vision brief's assembly tools are built, each as a thin
client to a real, pre-existing (or, for Mates/Measure's identity plumbing,
newly-added) DIDSA-CAD endpoint — never a VR-only representation, so
anything authored here is readable and editable in the flat app and vice
versa:

- **Mates** — face-only picking (top-level Occurrences of the loaded root
  Part only), a real client to `POST/GET/PATCH/DELETE .../mates` and
  `.../occurrences/{id}/solve`. Relax-all/Enforce-all supported.
- **Colours** — `PATCH .../occurrences/{id}`'s existing `color` field,
  including a "whole group" (every Occurrence sharing an owner) option.
- **Sections** — a single grabbable clip-plane gizmo, entirely client-side
  (the backend's own section-preview endpoint re-tessellates a fresh OCCT
  boolean per call, too slow for 90 Hz dragging).
- **Measure** — `POST .../measure`, 1–2 picks, live result (length, area,
  distance, delta, and more depending on what's picked) — no create step,
  nothing persisted. Looser picking than Mates: the open Part's own root
  content and a repeated pick on one Occurrence are both valid, since
  measuring across two features of one part is the common case.

Also built alongside these: opening a different native file at runtime and
adding a second file's Part onto the loaded assembly as a real Occurrence
(`open_native_file()`/`add_component_file()`, backend's new
`POST /parts/{id}/add-component`) — not one of the four named tools, but
what actually makes it possible to build a real multi-Occurrence assembly
to test Mates/Measure against from inside VR at all, without the bigger,
still-unscoped shared-network-storage project.

**Nothing in this milestone has been confirmed on a real headset** — every
tool above is headless-test-covered and confirmed against a real running
backend (real create/solve/PATCH/measure calls, real persisted results),
but never yet felt through a real hand pulling a real trigger. See
`docs/status.md`'s own per-tool "Not yet headset-verified" notes for what
specifically is still open (mostly: does picking read clearly, does the
result/list layout fit the tablet at arm's length, does a quick real
double-pick feel right now that it's no longer silently dropped).

## What "done" looks like for milestone 3

Four of the five things the vision brief named under "floating windows"
are built, on a shared free-floating-panel mechanism
(`scripts/diegetic_panel.gd`) new windows can build on:

- **Assembly Tree** — the vision brief's own "interactive tree" from its
  Assembly tools list, never built until now. Browse and tap-to-select;
  pulling a row out into world space is real further scope of its own
  (duplicating geometry, or breaking a mate server-side) and isn't
  attempted here.
- **Calculator** and **Image Viewer** — round out this phase's realistic
  scope; see item 15 above.
- **Browser** (and, for free, **PDF reader**) — the originally-scoped
  native CEF/webview approach turned out to have no Android/Quest build at
  all (confirmed by checking `gdcef`'s own supported-platforms list).
  What's built instead is a generalized one: a separate server-side
  "browser relay" service (`browser-relay/` in the DIDSA-CAD repo) that
  authenticates a WebSocket and proxies raw Chrome DevTools Protocol (CDP)
  frames to a real headless-Chromium tab it manages, with every CDP detail
  — navigate, screencast, mouse input — living in
  `scripts/browser_window.gd` on this end, using only Godot core APIs
  (`WebSocketPeer`, `Image.load_jpg_from_buffer()`). PDF needed no separate
  implementation: navigating to a PDF URL makes Chrome's own built-in PDF
  viewer render it inline, confirmed for real (see below), not assumed.

**"DIDSA-CAD as a flat window" is the one item explicitly not attempted
this phase** — it needs DIDSA-CAD's Flutter client to grow a web build
target it doesn't have today, a DIDSA-CAD-repo spike, not a DIDSA-VR task.
(Note this is now a narrower gap than it looked at the start of this
phase: once DIDSA-CAD has a web build, it's plausible the same
browser-relay mechanism above could serve it too, rather than needing its
own separate solution — not attempted or verified, just no longer as
clearly a dead end.)

**Headless-confirmed (Godot 4.7.2, `tests/run_all.sh` clean), not yet
confirmed on a real headset.** Actually running the suite — not just
inspecting the code — caught and fixed two real bugs: `controller.gd`'s
per-frame UI-claim reset assumed tree position guaranteed it ran before
every panel, which wrist_tablet.gd (three levels deep, not a direct
sibling) disproved in practice, and the Calculator did real integer
division for two integer literals ("10/4" → 2, not 2.5) — see
`docs/status.md`'s "Milestone 3" section for both. `tests/e2e_assembly_tree.gd`
still needs a real backend to run. The Browser window's CDP layer went
further than headless-only: a real headless-Chromium binary, a real
running instance of `browser-relay`, and a real Godot process (not a
mock) were connected end-to-end in this repo's own dev sandbox — real
`X-API-Key` WebSocket handshake, real `Page.navigate`, a real JPEG
screencast frame decoded by Godot's own `Image.load_jpg_from_buffer()`,
and a real `Input.dispatchMouseEvent` round trip, all through the actual
relay — see `docs/status.md` for exactly what was run. A Docker daemon was
later obtained in this same sandbox and confirmed the browser-relay
image's non-Chromium layers build and run for real (including the app's
own fail-fast startup check, confirmed by intentionally pointing it at a
non-Chrome binary), but its one `apt-get install chromium` line hit a
real wall: `deb.debian.org` is blocked by this sandbox's own network
policy (confirmed with `curl`, not assumed). What's still unverified as a
result: that specific apt install actually resolving Chromium's runtime
dependencies (a bind-mounted real Chromium binary confirmed exactly which
dependency is missing without confirming apt can supply it here), the
arm64 Raspberry Pi target, and — as with every other window — a real
headset.

## Known gaps this project doesn't solve yet

- **Cleartext HTTP on Quest** — see the `backend_url` note above. Worth
  solving for real once milestone 1 is further along, not now.
- **Drag latency** — grabbing (grip or the laser-select's nudge/rotate)
  moves things locally and instantly; it doesn't round-trip to the backend's
  mate solver at all. That's deliberately out of scope here (see the vision
  brief's "Drag latency" open decision).
- **No automatic multi-file assemblies** — the import step still sends
  exactly one file's own JSON (its own features/occurrences/mates); if your
  assembly's Occurrences point at *other* files via `external_ref` with no
  `resolved_part_id` already stamped in, those referenced parts still won't
  auto-resolve on open — that's the server-side composition work the vision
  brief flags as a separate, unbuilt roadmap item (a mounted network share,
  path resolution), not something this project attempts. **What *is* built
  now**: the wrist tablet's Files tab can open any native file at runtime
  (`open_native_file()`, not just the one this scene started with) and add
  a second file's Part onto the loaded assembly as a real Occurrence
  (`add_component_file()`, backend's new `POST /parts/{id}/add-component`)
  — manual, one file at a time, but enough to build (and therefore test
  Mates against) a real multi-Occurrence assembly entirely from inside VR.
- **No godot-xr-tools** — deliberate, so far, to keep measuring the bare
  engine. Worth revisiting once milestone 1's interaction model is proven
  out, rather than continuing to hand-roll everything.
