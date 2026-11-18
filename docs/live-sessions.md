# Live sessions: Host Session and Join Session (P2a)

Phase P2 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md`; the protocol is DIDSA-CAD `docs/live-sessions-scope.md` (decisions LS-1 to LS-13), the hub is DIDSA-CAD
`session-hub/`. **Built and tested headless and against a real backend and a real hub; nothing here has been run on a headset or a phone.** What is verified and what is not is listed in the
plan's "P2 results" and at the foot of this page. This is **P2a (sessions working end to end)**; avatars, Go to presenter, Follow presenter and Gather everyone are **P2b, not built**.

## What it does

One person (the **presenter**, a Quest or the PCVR desktop preview) works exactly as before and presses **Host Session** on the landing's monolith. Up to six people (**observers**) press
**Join Session**, type or scan a six-character code, and see what the presenter shows: the model, every part as the presenter moves it, hidden parts, the cut, where the model stands and how
big it is, and a line saying what the presenter is doing. Observers cannot change anything.

```
presenter ── REST + CAD key ──> CAD backend <── glb + read-only view token ── observer
    └── wss + hub key ──> session hub <── wss, the code only ───────────────────┘
```

The model never goes through the hub: the observer fetches the presenter's `assembly-mesh.glb` from the presenter's own backend with a **view token** (it can read that glb and nothing else; it
ends with the session). A demo model shipped in the APK is shared by its path instead (every headset has the file). A bare `.glb` opened from a folder cannot be hosted (LS-9).

## Where it is in the code

| | |
|---|---|
| `scripts/session/session_protocol.gd` | codes, the `didsa-join:1?h=&c=` text, hub address rules, the 12-number transform (model space, millimetres), words for each hub error |
| `session_client.gd`, `session_transport.gd` | the WebSocket to the hub: host / join / resume, ping / pong, the welcome and its snapshot, the roster, errors, reconnecting with `resume` (1, 2, 4, 8, then every 10 s for 10 minutes), a send-rate guard |
| `session_manager.gd` | what the pages call: hostable model, hub discovery, minting and revoking the view token, host / join / end / leave, renewing the token before it expires and when the backend lost it |
| `session_publisher.gd` | the presenter: poses, visibility, section, place, status, `doc_changed`, `model` |
| `session_observer.gd` | an observer: fetches the glb with the token only, applies the snapshot and the stream, smooths poses, refetches on `doc_changed` |
| `qr_encoder.gd` | the join QR code (the headset had a reader and nothing that made one); `tools/qr_roundtrip/` checks it with an independent decoder |
| `document_revision.gd`, `session_http.gd` | the backend's `X-Document-Revision`; the few HTTP calls a session makes (fakeable) |
| `main.gd` (block "Live sessions") | the hooks: `session_doc_changed`, `session_model_changed`, `apply_session_role`, `session_show_*`, `session_apply_*`, `observer_blocked` |
| `landing/launcher_window.gd`, `landing_monolith.gd` | the Host, Join and Session pages, the rows, the scanner reading join codes, the Servers page's Hub form |

## Finding the hub

A presenter needs the hub's address and its own key (`SESSION_HUB_API_KEY`, not the CAD key). Whoever joins needs neither: the join code carries the address.

1. **Per saved server** (Servers > the server's **Hub** button): address (`wss://sessions.example.com`, or `ws://192.168.1.20:8300` on your own network) and key. Kept in `servers.cfg` with the server.
2. **A pairing code** from DIDSA-CAD's Connect a VR headset carries `h` and `hk` when the flat app has the hub set (its "Live sessions (optional)" section).
3. **`secrets.cfg`**: a `[session_hub]` section with `url` and `api_key` (for the PCVR preview).
4. If none is saved but the backend's `/health` says `session_hub` (DIDSA-CAD told `SESSION_HUB_URL`), that address is used with the saved key; the key still has to come from 1 to 3.

Plain `ws://` is accepted only for a local-network address; everything else must be `wss://` (the same rule as the browser relay). `localhost` is refused (the headset is not the hub) unless
`DIDSA_SESSION_ALLOW_LOOPBACK` is set (tests, and a desktop preview with the hub on the same PC).

## A finding: Godot loses the hub's last message (fixed on the hub's side)

Found by the end-to-end run against the real hub. **Godot's `WebSocketPeer` returns no packets once the close frame has been processed**, and the hub used to send its final message (`error ...`,
`end`) and close at once, so the app received only the close code (probed: a wrong join code gave states `[connecting, open, closed]`, close code 4000, **zero** packets). Two changes, neither a protocol
change: **the hub** (`session-hub/app/api.py`) now waits 150 ms between its last message and the close frame and puts the error code or end reason in the close frame's reason; re-probed against the
real hub, the error arrives and `get_close_reason()` says `bad_code`. **The client** (`session_client.gd` `_closed_by_hub`) still copes with a hub that has not been updated: it uses a message that
arrives, then the close reason, then the close code (**4003** removed, **4000** refused: for a join, "no such code, locked or full"; **1000 while live**: the session ended).

## What an observer cannot do

Role gating (`main.apply_session_role`): while watching, the hands do not grab, select or use tools; the whole-model move and scale is off (the presenter's place is shared, LS-6); the tool wheel is
off; the wrist tablet shows only Settings, Home, Calculator and Images; the design table closes; no backend is configured for any tool (the app's own server is not used and `has_backend()` is
false); Open, New, Save, Add, server projects and switching server are refused with a line saying why; the landing's file, server and model rows are off and the pill says whose session it is. Leaving
or the end of the session puts all of it back and puts the shared model away. Own-view tools (colour, hide, section, measure) are P4.

## Two-device steps (to check it by hand)

**You need:** the DIDSA-CAD backend and the hub running where **both devices can reach them**. The observer fetches the model from the address the presenter's *saved server* has, so that address must
work from the observer's device: a LAN address or a tunnel, not `localhost`.

```
# hub (once; one worker only)
cd DIDSA-CAD/session-hub && pip install -r requirements.txt
SESSION_HUB_API_KEY=<a key> python -m uvicorn app.main:app --host 0.0.0.0 --port 8300 --workers 1
```
Behind a Cloudflare tunnel give the hub its own hostname to `localhost:8300` and use `wss://`. (Not tried here.)

**On the presenter** (a Quest, or the PCVR desktop preview): Servers > your server > **Hub** > the hub's address (`ws://192.168.1.20:8300`) and key > Save hub.

1. Open a model: Continue or Open a server file, or Demo models > a rocket. Go back to the landing (wrist tablet **Home**, or the wheel's Home).
2. Monolith > **Host Session**. The page says what it will share and which hub. **Start session**.
3. The **Session** page shows a big code (for example `K7X Q4M`) and a QR code. Read the code to the other person.

**On the other device** (the second Quest, or the PCVR preview):

4. Landing > **Join Session**. Tap **Session code**, type the code. Tap **Hub address** and type the hub's address (it is filled in if this device already knows a hub). **Join**.
   *Or:* Join Session > **Scan a QR code** and look at the presenter's QR (Quest only: it uses the headset's marker tracking; the PC preview cannot scan). A card says **Join session K7X Q4M?**: press Join.
5. The model appears at the presenter's place and size. Check: the wrist tablet has only four tiles; grip and trigger do nothing; Continue, Open, New and Servers on the monolith say "Not while watching".

**Things to try on the presenter, and what the observer should show:**

| Presenter does | Observer sees |
|---|---|
| Grip a part and move it | the part moves, smoothly, about a tenth of a second behind |
| Preview a mate (the part glides) | the part glides |
| Hide a part (Tools, tree) | it disappears; it comes back when they show it |
| Sections tool: a cut plane | the same cut at the same place in the model |
| Two-hand move, turn or scale the whole model | the model moves, turns or scales with it |
| Open the design table | status line "Name is at the design table: Part" |
| Add a feature at the design table | after a moment that part's shape changes (a refetch) |
| Paint a body (a real paint) | the colour appears after a moment (a refetch) |
| Add or delete a part | the model refetches |
| Open another demo model | the observer's model changes to it |
| Open a file that is not on the server (a bare .glb) | the observer keeps the old model and the line says it cannot be shared |

**Also try:** Lock (Session page) then a third device joining is turned away; Remove; switch the presenter's Wi-Fi off for 20 seconds (the observer's line says "presenter reconnecting", the state stays,
it comes back and carries on); the observer's **Leave**; **End the session** (the observer's model goes with "The presenter ended the session.").

**What to write down if something is wrong:** which of the above; the line on the monolith; `adb logcat | grep "DIDSA VR"` on a Quest (or the console of the PC preview); the hub's log (it logs room
created and ended, joins, leaves and refusals by participant, never message contents).

## Not in P2a

Avatars, Go to presenter, Follow presenter, Gather everyone (P2b). Voice (P3). Observer tools and marks (P4). The phone build (P5). Sandbox paint, scene looks, Assembly Rooms and the sketch are not mirrored
(LS-4, LS-5): the observer sees the world assembly and a status line. A wrist-tablet page for the session (the code is on the monolith, which the presenter has to open) is not built.
