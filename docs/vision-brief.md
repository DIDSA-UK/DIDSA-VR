# DIDSA VR Design Tools: Vision Brief

Sep 24, 2026 · @John

> Point-in-time export (as of 26 Sep 2026, rev 23) of a live Claude Docs
> artifact — this file does not update automatically when the live doc
> changes. Ask John for the current artifact link if this looks stale, and
> re-export after any significant change to keep the repo in sync.

## Vision

DIDSA VR Design Tools is a shared VR/XR workspace where engineers build assemblies, model parts and run flat-screen apps at real-life scale. It joins the DIDSA Design Tools family, reuses the DIDSA-CAD backend and opens the same native files. Meta Quest standalone is the primary target, with a PCVR option for models too heavy for the headset.

The author is a mechanical design engineer, not a software developer, so Claude acts as developer and advisor on this project.

## Platforms and constraints

The goal is device-agnostic, but Quest has the market, so Quest comes first and its limited onboard compute shapes everything else.

| Platform | Role | Note |
| --- | --- | --- |
| Quest 2, 3, 3S (standalone) | Primary target | Sideloaded APK; limited compute, so the headset only displays and interacts |
| PCVR | Heavy models | Same client and native files, or a sibling app on the same engine |
| Pico, Steam Frame, Galaxy | Later | Reachable if the client stays on OpenXR |
| Android phone + Cardboard viewer | Later, observer only | View-only client for design reviews; needs multiplayer first (see "Phone observer" below) |
| Apple | Later, separate effort | Different platform; do not design around it yet |

Models must be imported over a network from storage the user already has, so the network path matters as much as the headset.

## Proposed architecture

Proposal, not yet confirmed against the repo: a thin VR client that displays and manipulates meshes, with all geometry work on the DIDSA-CAD backend.

```mermaid
flowchart LR
  A[Quest client<br/>standalone] -->|meshes, edits| B[Backend<br/>FastAPI + OCCT]
  C[PCVR client<br/>same engine] -->|meshes, edits| B
  B --> D[Network storage<br/>native + STEP files]
  A --- E[Session server<br/>multiplayer, later]
  C --- E
```

The headset never runs OCCT; it receives tessellated geometry (glTF is the likely format) and sends back edits and mate commands. PCVR uses the same client with more headroom.

The Flutter client will not carry over because it cannot drive a VR view. The VR client needs an OpenXR-capable engine, with Unity and Godot as the realistic candidates. The engine is the first decision, since it fixes language, tooling and platform reach.

**Payload, measured.** On a test assembly of 186 instances of 4 unique parts, the current JSON assembly-mesh is 470 KB and the existing flattened glb is 1.33 MB. A node-instanced glTF is estimated at 90 to 100 KB. Decision: one glTF scene per call.

**Storage.** Assembly composition moves into the backend, which reads project files from a mounted network share, so clients need no file-system access. The backend already speaks plain HTTP on a LAN; the Quest app needs a scoped cleartext exception in its Android network config, or TLS.

## Reuse from DIDSA-CAD

The backend is the main reuse candidate; the client code is not. Two repo recons on 24 September 2026 confirmed this.

| Piece | Reuse | Finding |
| --- | --- | --- |
| Import, tessellate, export and solve endpoints | Yes, as-is | Plain JSON over HTTP with no Flutter coupling; import already accepts STEP, STL, OBJ and glTF |
| Assembly scene (assembly-mesh) | Yes, plus a glTF encoder | Already deduplicated per part with world transforms; the encoder needs no new geometry work |
| Solvers (py-slvs) | Yes | Mate solve is backend logic; v1 drives one occurrence against fixed peers |
| Single-file native format | Yes | One Part per file, owned by the backend |
| Multi-file assembly composition | Port to Python | Client-side Dart today; a simple graph walk that gets easier on the server |
| Local sketch solver (Dart/FFI) | No | Exists for drag speed; VR either reimplements it or solves on release |
| Mate picking | Ids yes, code no | face and edge ids are engine-agnostic; picking is a raycast in the VR client |
| Flutter rendering and UI | No | Cannot drive a VR view |

Sources: docs/vr-recon-2026-09-24.md and docs/vr-recon-2-2026-09-24.md in the DIDSA-CAD repo.

## Interaction model

Four manipulation modes, each usable on its own and switchable from the wrist tablet.

1. **Model movement.** One hand grabs to move the model around the user. Two hands grab to rotate and scale.
2. **User movement.** Physical walking; left thumbstick walks and strafes; right thumbstick rotates and teleports. Teleport blinks forward by the indicated distance on thumbstick release.
3. **Individual part manipulation.** Laser-target a part and select with the trigger. Grab translates it, thumbstick rotates it, A/B move it nearer or further.
4. **Scale views.** Jump to real-life size or pick from a list of scales for small and large objects, with an option to lock to the chosen scale.

A popup keyboard opens on a click of the right thumbstick, everywhere, for any text entry.

## Tools, wrist tablet and mates

A wrist-mounted tablet controls the environment: UI and UX settings, tool selection and menus.

**Assembly tools**

- Relax all mates and enforce all mates buttons.
- Shoot to hide: with the tool active, laser-target a part and fire to hide it.
- Reverse visible and hidden state of all parts.
- Interactive tree with sub-assemblies and parts that can be pulled out into world space or onto the design table. **Built (3 Oct 2026)**: browse and tap-to-select in the Assembly Tree window, and the design table's own copy of it with **Table** (put the part on the table) and **Bring** (move it in front of you) on each row. Dragging a row out is not built (`docs/design-table.md`).
- Colours, sections and measurements.
- Import parts from network storage into the assembly.

**Mates workflow**

1. Start the mates tool on the wrist tablet.
2. Laser-target faces and edges.
3. Pick the mate type from the wrist menu.
4. Type any values on the popup keyboard.

**Cross-app compatibility with DIDSA-CAD (flat), added 27 Sep 2026 — now
synced into the live doc too.** Mates created in VR must be readable and
editable in DIDSA-CAD's flat app, and vice versa, so a user can move
between VR and flat and take the same assembly file with them. Mates are
already backend/session state, not
client state (see "Reuse from DIDSA-CAD" above: "Mate picking: Ids yes, code
no — face and edge ids are engine-agnostic; picking is a raycast in the VR
client" and "Solvers (py-slvs): Yes — Mate solve is backend logic"), so this
should fall out for free as long as the VR client's mates tool is built as a
client to the *same* backend Mate create/solve endpoints the flat app uses,
rather than inventing a separate VR-only representation. Worth a compatibility
check against a real flat-created assembly once mates are built, not just
against VR-created ones.

## In-VR part modelling

The user stays in the assembly arena and a floating design table appears in front of them. Sketches are drawn on the flat table and the part geometry floats above it, with modelling tools in menus around the table.

- **AI-assisted modelling.** Describe the part by microphone or text, or draw it on an easel; the image is saved and pushed to the existing AI modelling tool from inside VR.
- **Physical pen (open question).** Whether a Bluetooth pen on a real table could drive sketching on the virtual drawing board, and whether that needs new hardware.

Part modelling already exists in DIDSA-CAD, so the VR version should call the same modelling backend rather than reimplement it.

## Multiplayer and environments

Several people share one environment. Each can walk or move around the model, set up their own part design table and crate, and add new parts to the common assembly.

Multi-user comes in two stages.

**Stage 1, shared files.** Clients share one Part per file on network storage, with the backend composing assemblies. Users editing different Parts never collide. Today two users saving the same file overwrite each other whole-file, so the first safeguard is a version check on write that rejects a stale save. Two people actively editing one assembly file still need a lock or check-out.

**Stage 2, live presence.** Seeing each other's edits live needs a backend with separate session and document, persistence, a push channel and per-user identity. That is a separate backend project, scoped on its own.

### Phone observer (idea, recorded 14 Oct 2026; not scoped or started)

An Android APK that lets someone with only a phone and a Google Cardboard-style viewer sit in on a design review while a person with a proper HMD stays in control. The phone user sees the shared environment, the assembly and the other participants' avatars, but does not edit.

**Prerequisite: multiplayer.** Nothing here can start until stage 2 (live presence) exists. As of this note the repo has no networking or session-sync code, so the observer is a consumer of that work, not a driver of it. The observer should shape the multiplayer design in two ways only: participants need a role (editor or observer), and the session should send state a view-only client can render without any editing code.

**Shape of the client**
- Same Godot project, a separate Android export with OpenXR switched off. Cardboard phones have no OpenXR runtime and no tracked controllers.
- Head orientation from the phone's gyroscope, side-by-side stereo with lens distortion. Godot has no built-in Cardboard support, so this is a small custom camera rig (two SubViewports plus a distortion shader) or a community add-on. No positional tracking, so the observer moves with the gamepad or stays put.
- Input from a Bluetooth gamepad, which Godot supports on Android natively. Limited interaction only: move, point a laser, and perhaps highlight, ping or toggle part visibility locally. No edits are sent, which avoids conflict resolution and keeps authority with the HMD user.
- Reuses the view layer (glb scene, environments, avatars). Does not need the grab, mates, design-table or other controller-driven code.

**Open questions**
- Mid-range phones must hold about 60 fps in stereo; whether real assemblies and the current shaders and MSAA allow that is unknown. May need LOD or simplified materials for this build.
- How much of `main.gd` mixes rendering with Quest input, and so how cleanly a shared view layer can be split out.
- Whether the observer can have a small local-only toolset (hide parts, section, measure) or stays purely a viewer.
- A WebXR export is an alternative delivery route (no APK, runs in a phone browser); worth comparing once multiplayer exists.

**Roadmap placement.** After stage 2 live presence, and after Quest hardening has settled which parts of the client are view-only. Treat it as a candidate milestone 6 once those two are done.

Environments wanted: aircraft hangar, warehouse, open paved area, laboratory, clean room. Whether open-source versions exist is an open research question.

## Milestones

The four original milestones stand, with a recon step and an engine spike added in front.

| # | Milestone | Done when |
| --- | --- | --- |
| 0 | glTF endpoint and engine choice | Done. Backend built and merged (PR #250): GET /parts/{id}/assembly-mesh.glb, node-instanced, hidden filtered server-side by default. Engine spike (Godot 4 OpenXR core, PCVR via Virtual Desktop) succeeded end-to-end: import → glb fetch → correct-scale render → grab → locomotion. Godot is the pick. |
| 1 | Import and viewport | **Done except for measuring it on real Quest hardware.** Native import, STEP/OBJ/STL import, individual part manipulation (proximity grab, and trigger-laser select with thumbstick rotate / A-B nudge), user movement (walk, snap-turn, teleport), whole-model one/two-hand movement (drag, turn, scale), scale views (presets, lock, Fit, Home), the wrist tablet (Modes, Scale, Tools, Files, Perf, Undo/Redo), the popup keyboard, and local glb import (no backend round-trip) are all built and running — the only thing left is measuring performance on a real Quest headset (everything so far has been PCVR via Virtual Desktop), not more building. |
| 2 | Design table | **Built, 3 Oct 2026** (headless- and real-backend-confirmed, not yet on a headset): a summonable console where sketches on a sheet drive geometry floating above it - see `docs/design-table.md` for what's in and what isn't. |
| 3 | Floating windows | **Mostly done, 28 Sep 2026.** Calculator, image viewer, the vision brief's own "interactive tree" (from the Assembly tools list), and a Browser window are all built as free-floating panels that can be open together. The Browser window is a real headless-Chromium tab proxied over a separate server-side relay (Chrome DevTools Protocol over an authenticated WebSocket, `browser-relay/` in the DIDSA-CAD repo), not a native Godot webview/CEF dependency — which turned out not to exist for Android/Quest at all. It also serves as the PDF reader for free (Chrome's own built-in PDF viewer). Only DIDSA-CAD-as-a-window remains unattempted, blocked on DIDSA-CAD's own Flutter client gaining a web build target — its own scoping spike, not this repo's task. See `docs/status.md`. |
| 4 | Assembly environment | **Done, 28 Sep 2026.** Parts move individually; mates, colours, sections and measurements all work — Measurements (the last of the four) is a thin client to DIDSA-CAD's existing `POST /parts/{id}/measure`, needing no backend changes at all. Headless- and real-backend-confirmed (`tests/measure_tool.gd`, `tests/e2e_measure.gd`); not yet confirmed on a real headset. |

Shared network storage (stage 1) follows milestone 4; live presence (stage 2) is a separate backend project.

## Open decisions and risks

- [x] Engine: Godot, decided by a hands-on Quest spike (PCVR via Virtual Desktop) that imported a real assembly, fetched the assembly-mesh.glb endpoint, rendered it at correct real-world scale (mm→m), and supported grip-grab plus thumbstick locomotion — all working end-to-end. Plain Godot 4 OpenXR core, no godot-xr-tools. Standalone Quest APK export/sideload not yet tested; a formal Unity comparison was not run since no compelling functionality gap turned up.
- [x] Repo: backend stays in DIDSA-CAD; the VR client is DIDSA-UK/DIDSA-VR (private), git-initialised with a first commit covering the milestone 0/1 work so far. Backend URL and API key load from a gitignored secrets.cfg rather than being hardcoded in a script or baked into a .tscn override.
- [x] Geometry transport: node-instanced glb endpoint built and merged (PR #250). Vertex welding deferred; real payload size not yet measured against this endpoint, only estimated on the JSON endpoint.
- [ ] Backend location for a standalone Quest: a LAN server, over plain HTTP with a scoped cleartext exception in the Quest app, or TLS.
- [ ] Storage: server-side composition over a mounted network share. Roadmap placeholder added; still needs its own scoping doc superseding decisions 4 and 6 in docs/assembly-scope.md. **Narrower than it looked**: the specific thing this was blocking (VR having no real multi-Occurrence assembly to test Mates against) is now solved without this — see the Mates testing blocker entry below. This decision is still open for what it's actually about: a shared network-mounted project store for multi-user/multi-file work, not a prerequisite for basic Mates testing.
- [ ] Drag latency: reimplement a local solve in the VR client, or solve on release (proposed for v1).
- [x] Window apps: how to run a browser (and PDFs, via Chrome's own viewer) as a floating panel on Quest — solved via a server-side CDP relay, see `docs/status.md`. DIDSA-CAD itself as a floating panel is still open, blocked on DIDSA-CAD's own Flutter web build target.
- [ ] Live presence: separate backend project, after shared-file storage.
- [x] Mates testing blocker, 27 Sep 2026: closed via a narrower fix, not the storage decision above. The backend gained `POST /parts/{id}/add-component` (`docs/status.md` there, and DIDSA-CAD's own `docs/status.md`/`docs/roadmap.md` same date) — a pure-payload-merge port of the Flutter client's `add_component.dart`, needing no filesystem/storage decision at all. The VR client's wrist tablet Files tab now has "Open" (a full-replace load of any native file at runtime, not just the one it started with) and "Add" (merges a second file's Part onto the loaded assembly as a real Occurrence) — so a genuine multi-Occurrence assembly for the Mates tool to test against can now be built entirely from inside VR. Headless- and real-backend-confirmed (`tests/e2e_add_component.gd`, SMOKE PASSED); not yet confirmed on a real headset.

**Main risk:** the size estimate (about 100 KB for 186 instances) was measured on imported meshes, not real parametric assemblies, and dragging over a network round trip may feel laggy. Test both early.

## Parked ideas

Not needed for milestone 1; revisit once the viewport works.

- Bluetooth pen for sketching on a real table (hardware question first).
- Easel drawing pushed into the AI modelling tool.
- Voice-described parts by microphone.
- Multiplayer with per-user design tables and crates.
- Android + Cardboard observer client for design reviews, with optional Bluetooth gamepad (needs multiplayer first; see "Phone observer").
- Environment library: hangar, warehouse, paved area, laboratory, clean room.
- Apple, Pico, Steam Frame and Galaxy builds.
