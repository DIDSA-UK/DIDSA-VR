# Assembly Tree render check (manual)

A hand-run check of the Assembly Tree window against a live DIDSA-CAD backend, with pictures. It is not a test: it is in no CI list because it needs a backend and (for pictures) a renderer, and takes about 105 s headless (`ci_e2e.sh` stops a test at 120 s).

## Run

```
tools/setup_test_env.sh && tools/start_backend.sh        # Godot, Xvfb + Mesa, a throwaway backend, secrets.cfg
export DIDSA_NO_LANDING=1 DIDSA_SETTINGS_PATH=user://settings_test.cfg DIDSA_RECENT_PATH=user://recent_test.cfg DIDSA_SERVERS_PATH=user://servers_test.cfg
TREE_RENDER_DIR=/tmp/tree_shots xvfb-run -a -s "-screen 0 1280x720x24" "$GODOT" --path . --script res://tools/assembly_tree_render_check/assembly_tree_render_check.gd
```

`TREE_SCENARIOS=a,d` runs some scenarios only. Without `TREE_RENDER_DIR` or under `--headless` only the `SMOKE` lines on the rows are produced. The run **replaces the backend's document**; use the throwaway backend.

## What it shows

Fixtures are built through the backend's API (`/import/native` from `demo/assemblies/plate_and_peg`, mates, a PATCHed pose); nothing is written to the repo. Eleven scenarios (rows are read through `window.visible_lines()` / `row_count()`, since B6 draws only the visible rows), each asserted on the window's rows and saved as `<name>.png` (the panel's own pixels), `<name>_wide.png` (the view from eye height with the model) and `<name>.txt` (the rows as text):

a structure then status; b a collapsed parent's count bubble; c `Peg x4` folded, open, Fold off; d Fix and Float from the tree; e a world selection revealing a row through a folded group; f red tint over a rigid-set colour; g an older backend; h a 2,000-occurrence tree (row build time, `Model.filtered_rows` for `:parts` and a name, and a scroll sweep printed as `SMOKE TIMING`, not asserted); i the Mates folder line under the root (its count after the label); j Find (B7): `:errors`, a name with an unknown token, and cleared (`j1_find_errors`, `j2_find_name_unknown_token`, `j3_cleared`); p the design table's PARTS tab on the one tree component (C6): the bar for a placed part, then a sub-assembly's greyed Table and Bring (`p1_parts_part`, `p2_parts_subassembly`, the table tree's own panel; the `.txt` holds the bar line and the list's height).

## Limits

- A Mesa render on Xvfb (GL-compatibility, not the mobile renderer) is not the headset: it shows layout, text, colours and state, not legibility at arm's length, reach, feel or Quest frame rate. Timings are CPU software-render numbers.
- Scenario f's rigid-set ids are written into the live answer (synthetic); the over-constrained state is the backend's.
- Scenario g's older backend is a stand-in that answers the framework's 404.
- Scenario e calls the window's world-selection handler; it is not a laser pick.
