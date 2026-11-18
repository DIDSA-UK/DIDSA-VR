# Live sessions: Host Session and Join Session (P2a, P2b) and observer tools (P4)

Phases P2 and P4 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md`; the protocol is DIDSA-CAD `docs/live-sessions-scope.md` (decisions LS-1 to LS-13), the hub is DIDSA-CAD
`session-hub/`. **Built and tested headless and against a real backend and a real hub; nothing here has been run on a headset or a phone.** What is verified and what is not is listed in the
plan's "P2 results", "P4 results" and at the foot of this page. This is **P2a (sessions working end to end)**, **P2b (people: avatars, Go to presenter, Follow presenter, Gather everyone)** and
**P4 (observer tools: a drone cursor, own-view edits, Share / Ping / Look here / Raise hand, Reset my view)**.

## What it does

One person (the **presenter**, a Quest or the PCVR desktop preview) works exactly as before and presses **Host Session** on the landing's monolith. Up to six people (**observers**) press
**Join Session**, type or scan a six-character code, and see what the presenter shows: the model, every part as the presenter moves it, hidden parts, the cut, where the model stands and how
big it is, and a line saying what the presenter is doing. Observers cannot change the model: what they can do is look at it their own way and point things out (the section "Observer tools (P4)" below).

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
| `session_presence.gd`, `session_avatars.gd`, `session_navigation.gd`, `comfort_vignette.gd` | P2b: what this person sends (head, hands, laser, in model space, 15 Hz), the others drawn (head, two controllers, laser, name tag, one colour each, one interval behind), Go to / Follow / Gather and the comfort vignette |
| `qr_encoder.gd` | the join QR code (the headset had a reader and nothing that made one); `tools/qr_roundtrip/` checks it with an independent decoder |
| `document_revision.gd`, `session_http.gd` | the backend's `X-Document-Revision`; the few HTTP calls a session makes (fakeable) |
| `session_cursor.gd`, `session_own_view.gd`, `session_marks.gd` | P4: the drone cursor (what it touches or points at, the level, the pose in presence's `cursor`); an observer's own-view layer and Reset my view; Share, Ping, Look here, Raise hand and Clear marks |
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

Role gating (`main.apply_session_role`): while watching, the hands do not grab, select or use tools (`view_only`, with the one narrow exception for the own-view tools below: the controller's
`own_view_input`); the whole-model move and scale is off (the presenter's place is shared, LS-6); the tool wheel is off; the wrist tablet shows only View and Inspect (the own-view tools, without
Scale and Navigate), Settings, Home, Calculator and Images; the design table closes; no backend is configured for any tool (the app's own server is not used and `has_backend()` is false); Open, New,
Save, Add, server projects and switching server are refused with a line saying why; the landing's file, server and model rows are off and the pill says whose session it is. Leaving or the end of the
session puts all of it back and puts the shared model away.

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

## People (P2b)

**Avatars.** Everyone else is drawn: a head with a dark face band (so you can see which way they look), two controllers, the laser from the right hand to where it ends, a name tag that always faces you
(the presenter's has a star; someone riding the presenter's view says "(following)"), in the colour the hub gave them. They are sent in **model space** and drawn through your own view of the model, so
they stand where they stand relative to the model whatever scale or place the model has for you, and they stay a person's size (a model at 1:50 on a desk does not shrink them). A hand that is not tracked
is not drawn (a phone has none). Presence goes out at 15 Hz while you move (over 2 mm or 1 degree), once a second otherwise, and is shown one interval behind.

**Settings > Session** on the wrist tablet (an observer's tablet has Settings): *observer*: **Go to the presenter** (you are put 0.9 m to their right at their eye height facing the way they face, with a short
dark pulse), **Follow the presenter** (your view is eased towards that spot at no more than 3 m/s and 70 degrees a second; the **comfort vignette** darkens the edges while it moves and opens when it has caught
up; **push the left stick to stop**; with **Reduce motion** on it steps instead of gliding; a long way is a jump), **Leave**. *Presenter*: **Gather everyone** (everyone is moved into an arc in front of you, 1.4 m
out and 28 degrees apart, looking at you, with the same pulse; they cannot refuse) and **End**.

**More things to try by hand (two devices):**

| Do | Expect |
|---|---|
| Both look at each other | a head and two controllers with a name over it, in the other's colour |
| Presenter points the laser at a part | a thin line from their right controller to the spot |
| Presenter scales the model to 1:50 and puts it on a desk | their avatar is still person-sized; where it stands relative to the model is unchanged |
| Observer: Settings > Session > Go to the presenter | beside them, same height, same way round, a brief dark pulse |
| Observer: Follow, presenter walks about | the view follows smoothly, edges darken while it moves, the presenter sees "(following)" on the tag; left stick stops it |
| Observer with Reduce motion on: Follow | steps, not a glide |
| Presenter: Gather everyone (two or more observers) | each is placed in the arc in front of them, facing them |

**Whether it is comfortable** (the vignette's strength, 3 m/s, 70 degrees a second, the 0.9 m offset, the 1.4 m arc) is the owner's to judge: nothing here has been on a headset. Please write down what feels wrong and
at what speed. The vignette's shader renders correctly in a software render (`tests/session_vignette_render.gd`) but has not been seen in two eyes.

## Observer tools (P4)

What an observer can now do, and what nothing here ever does: **nothing in this section changes the presenter's state, the document, or any backend.** An observer's own view is its own; the only
things an observer sends the hub are presence (now with its cursor), marks (`mark` / `mark_clear`) and a raised hand (`hand`). No protocol change: the messages are the scope's (4.4, 4.5).

On the wrist tablet an observer's **View** hub has **Cursor**, **Share** and **My view** (new, observers only; a presenter never sees them) beside Visibility, Hide tool, Display, Appearance and
Environment; **Inspect** has Measure and Sections. Scale and Navigate are not offered (the model's place and size are the presenter's, LS-6).

**Drone cursor** (View > Cursor). A small marker in your colour with your name, flown along your right laser (`distance` metres out). The right stick, up and down, lets it out and in (that stick is the
cursor's while it is on, so there is no snap turn or teleport meanwhile); it passes through surfaces. It picks, in this order: a surface within 4 cm of it (touching), a part whose bounds hold it
(inside), the first surface beyond it along your aim (pointing). A **level** is chosen with the paint breadcrumb's levels: Face, Body, Part, then each sub-assembly the part sits in; **A** takes the pick one
level wider, **B** one narrower (or the Wider / Narrower buttons). Everyone sees your cursor with your name (it travels in presence's `cursor` field). What it has picked is what Share shows and what the
cursor page's buttons act on.

**Own view** (nothing is sent, nothing is saved; all of it is undone by Reset my view):

| Edit | How, and how it never reaches anyone |
|---|---|
| Colour, see-through | The cursor page's *Paint it with the Appearance brush* / *Make it see-through* / *Clear its paint* act on the picked level; or the Appearance tool (View > Appearance) with the laser: a click paints the body, a hold opens the breadcrumb. It is the Appearance tool in `local_only` mode: the sandbox's temporary layer for good (records by path, never sent), over a model built from the glb's own paths, and only parts the paint is on are restyled (the others keep the glb's materials). It survives a refetch of the presenter's model. |
| Hide, isolate | The cursor page's *Hide it*, *Isolate it*, *Show everything*; or the Visibility page; or the Hide tool (trigger). The presenter's hide list is applied to you as **changes** (a part you hid stays hidden until the presenter shows that very part, or Reset). |
| Cut | Inspect > Sections: your own plane, the grip moves it. While your own cut is on, the presenter's is held back (kept, not applied); Reset gives you theirs. |
| Measure | Inspect > Measure in `local_only` mode: pick two spots with the laser; the distance and the offset along each axis are worked out here in model mm. There is no backend, so no edge, circle or face measures. |
| Pull a part out | My view > *Pull a part out*: the grip takes the part the hand is in (nothing else; no laser grab, no sub-assembly choice) and it stays where you leave it, on your screen only. The presenter's pose for that part is **kept but not applied** until Reset / *Put pulled parts back*. It uses the Relax sandbox's hand grab with no backend behind it; it does not use the sandbox's own snapshot and glide home, because those would put back what the presenter moved meanwhile. |

**Share (D7)** (View > Share): *Share what the cursor picked* shows the pick to everyone as brackets with your name, in your hub colour, until *Stop sharing*, the presenter's *Clear marks*, or you leave (the hub keeps it
in the snapshot so a late joiner sees it); one live share each. *Ping* is a pulse at the cursor (or where the right laser ends), 3 s. *Look here* is an arrow with your name at that spot, 10 s, and says to the
presenter "Name asks you to look here." (Settings > Session > *Go to the spot someone asked you to look at* puts the presenter 1 m short of it, facing it). *Raise hand* puts "(hand up)" on your name tag
and tells the presenter in a line. All of these are `client.send` messages: no `seq`, never state, never written anywhere. A mark names a part by the glb's `instance_path`, the same key the poses use (a face or
body pick outlines the whole part). **Clear marks** is the presenter's (Settings > Session); an observer's `marks_clear` is dropped by the hub.

**Reset my view** (My view, and Settings > Session): colours and see-through, hidden and isolated parts, pulled parts, your own cut and your measurement go back to exactly what the presenter shows now.

### Two-device steps for P4 (to check it by hand)

You need the setup in "Two-device steps" above (a presenter on one device, an observer on the other; the model on show on both). Please write down what is awkward, not only what fails.

1. **Cursor.** Observer: wrist tablet > View > **Cursor**, switch **Drone cursor** on. A small marker in your colour with your name appears at the end of your right laser. Presenter: you should see it too, with the name.
   Push the right stick up and down: the marker goes out and in. Aim at a part (the marker rests on it): the cursor page says *Picked: Part · <name> (touching)*. Press **A**: *Sub-assembly...* or the part's
   body; **B** goes back. Fly it inside a part: *(inside)*. Switch the cursor off: the marker goes from both views and the right stick turns and teleports you again.
2. **Colour and see-through.** Pick a part with the cursor, press *Paint it with the Appearance brush* (set a colour first in View > Appearance), then *Make it see-through*. Only your view changes: ask the presenter
   to confirm their part is untouched. Press *Clear its paint*.
3. **Hide, isolate.** *Hide it*, then *Isolate it*, then *Show everything*. Then ask the presenter to hide another part: it goes for you too, and the part you hid stays hidden.
4. **Cut.** Inspect > Sections: grip the plane. The presenter's cut (if any) is held back. Reset my view: you see theirs.
5. **Measure.** Inspect > Measure: trigger on two spots. The tablet shows Distance and the three offsets; nothing is sent (the presenter sees no change).
6. **Pull a part out.** View > My view > **Pull a part out**, put a hand in a part and grip, move, let go: it stays. The presenter moves that part: yours does not follow. **Put pulled parts back**: just those go back.
7. **Share.** Pick a part, View > Share > **Share what the cursor picked**: the presenter (and a third device) see brackets round it with your name, in your colour. Share something else: it replaces the first.
   *Stop sharing* clears it. The presenter: Settings > Session > **Clear marks** clears every mark; an observer has no such button.
8. **Ping.** Share page > **Ping**: a pulse with your name at the cursor for 3 s, on every device, wherever the model is placed or scaled for them.
9. **Look here.** Share page > **Look here**: an arrow with your name for 10 s. The presenter's status line says "Name asks you to look here."; presenter Settings > Session > *Go to the spot someone asked you to look at*.
10. **Raise hand.** Share page > **Raise hand**: your name tag on the other devices says "(hand up)" and the presenter's line says "Name raised a hand."; switch it off: both go.
11. **Reset my view.** After a few of the above: My view > **Reset my view** (or Settings > Session). The page says "Your view is the presenter's." and the model looks as the presenter's does.
12. **Leave** and **join again**: a share the presenter or another observer still has up is shown at once.

**What to write down if something is wrong:** which step; what the cursor page said; `adb logcat | grep "DIDSA VR"`. **Not verified:** how any of this feels (the cursor's reach, the stick's speed `FLY_SPEED` 1.5 m/s, the 4 cm
touch radius, the A / B level keys, whether the right stick should be the cursor's), the marks' size and legibility, and that a Quest's right stick and A / B buttons reach the code the way the headless tests assume.

## Not built

Voice (P3). The phone build (P5). A face-level or body-level mark outlines the whole part, not the face. An observer's measure cannot measure an edge, a circle or a face's area (no backend).
A phone's controls for the cursor are P5. Sandbox paint, scene looks, Assembly Rooms and the sketch are not mirrored (LS-4, LS-5): the observer sees the world assembly and a status line.
A persistent in-world indicator for the presenter while hosting (the code is on the monolith, reached with Home) is not built. A phone's head orientation (gyro) is P5.
