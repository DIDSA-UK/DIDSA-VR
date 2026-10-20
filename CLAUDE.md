# DIDSA Design Tools VR: working notes

(The name is a placeholder. The repo and the docs still say DIDSA-VR / DIDSA VR in places.)

Godot 4.7 (Mobile renderer, OpenXR) VR client for DIDSA-CAD. GDScript only; no addons and no `godot-xr-tools` (deliberate). **One exception: the OpenXR Vendors plugin** (Meta passthrough and the Quest manifest) for the standalone Android build, fetched by `tools/install_vendors_plugin.sh`, never committed (`docs/android-build.md`).
The CAD backend and the flat Flutter app live in `DIDSA-UK/DIDSA-CAD`; this repo is a client of its REST API.

## Read first

1. `docs/status.md`: what is built, what is verified, what is open. Update it when that changes.
2. `docs/README.md`: index of every doc. The full old build log is `docs/status-history/status-log.md`.
3. `docs/backend-api-notes.md` before touching anything that calls the backend.
4. `tests/README.md` before adding or running tests.

## Layout

- `scripts/`: `main.gd` (scene root), `controller.gd` (all hand input), `two_hand_model.gd`, tools (`mates_tool`, `measure_tool`, `section_tool`, `colour_tool`), windows (`*_window.gd` on `diegetic_panel.gd`), `locomotion.gd`.
- `scripts/room/`: Assembly Rooms (clipped sub-assembly workspaces): manager, registry, clip, handles, console, edit, world preview.
- `scripts/design_table/`: the part-modelling console (sketch, constraints, features); `cad_api.gd` is its backend client.
- `scripts/ui/`: wrist tablet (`tablet_registry.gd`, `tablet_pages.gd`), theming (`didsa_ui_theme.gd`), shader FX.
- `scripts/landing/`: the first screen (a state of `main.gd`'s world): logo, rocket garden, launcher, tips (`landing.gd` is the entry; scope in `docs/landing-scope.md`). `DIDSA_NO_LANDING=1` turns it off for tests.
- `scripts/motion/`: constrained-drag projector and benchmarks. `shaders/`: clip, grid, glass-wall and effect shaders.
- `demo/`: models and assemblies shipped in the APK (1:1 glb, `importer="keep"`; credits in `demo/CREDITS.md`, rules in `demo/README.md`).
- `ui/logo/`: the DIDSA logo traced from the artwork (SVG, 3D glb; how to redo it in `ui/logo/source/`). `icon.svg` is its emblem.
- `tools/`: `install_vendors_plugin.sh` (the pinned OpenXR Vendors plugin) and `android/` (the Quest export preset example, the optional cleartext overlay). The Quest APK: `docs/android-build.md`.
- `ui/themes/`: theme presets. `lab/ui_lab.tscn`: UI sandbox (F6, no headset). `tests/`: headless, render and live-backend tests.

## Commands

```
GODOT=/path/to/godot tests/run_all.sh        # headless suite (script and parse errors)
GODOT=/path/to/godot tests/ci.sh             # what CI runs: also fails on any `false` SMOKE assertion
GODOT=/path/to/godot tests/ci_render.sh      # render tests (needs Xvfb + Mesa)
GODOT=/path/to/godot tests/ci_e2e.sh         # needs a running DIDSA-CAD backend; list in tests/e2e_ci_list.txt
```

CI pins Godot 4.7.2 (`.github/workflows`). The renderer is `mobile`; physics runs at 90 Hz.

## Rules that have bitten before

- Any test that instantiates `scenes/main.tscn` must first set `main.secrets_file_path` to a nonexistent file, or it reads the real `secrets.cfg` and POSTs to the configured backend. `await process_frame` after `add_child`.
- Never commit `secrets.cfg`, `export_presets.cfg` or anything under `models/` (git-ignored).
- Backend native units are millimetres; Godot reads glTF as metres (`spawn_scale` 0.001).
- The server does not stop cycles or unknown Part ids when adding occurrences; the client must.
- Say what you could not verify. Headless tests cannot judge feel, fake a real grip press, or render for real. Testing on the headset is ongoing and informal, so the repo does not record which features have been checked by hand: do not write "works on the headset" unless the owner says so.
- The app starts on the landing, not the start-up import of `assembly.didsa`. Tests (and any `e2e_*` run by hand) need `DIDSA_NO_LANDING=1`; the scripts in `tests/` set it.
- Adding a test file: add it to `tests/run_all.sh` and a row in `tests/README.md`; live-backend tests also go in `tests/e2e_ci_list.txt`.

## Naming

Older docs and commits use three label schemes. **Milestones 0-4** (Sep-Oct 2026: engine, import, design table, windows, assembly tools), **Phases 5-7** (design-table depth), and **R0-R4** (Assembly Rooms). The README does not use them; `CHANGELOG.md` maps them to dates.
`docs/status.md` section names quoted by other docs mean headings in `docs/status-history/status-log.md`.
