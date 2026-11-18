# Servers

Which DIDSA-CAD server the headset talks to, how to add one, and how to load one without typing. Scope: [`landing-scope.md`](landing-scope.md)
("Adding a server", steps L4 to L6). Code: `scripts/landing/server_store.gd`, `server_address.gd`, `server_probe.gd`, and the Servers page of
`launcher_window.gd`; switching is `main.gd` (`switch_server`, `add_server`, `forget_server`).

## Where servers live

`user://servers.cfg` on the headset (the app's private storage; it survives installing a new build over the top). It is a plain text
[ConfigFile](https://docs.godotengine.org/en/stable/classes/class_configfile.html) with the API key in it:

```
[servers]
current="workshop"

[server.workshop]
name="Workshop PC"
url="https://cad.example.net"
api_key="the CAD_API_KEY"
document_session=""
relay_url=""
relay_api_key=""
store_url=""
store_key=""

[server.phone]
name="Phone"
url="http://192.168.1.9:8000"
api_key="..."
```

`name`, `url` and `api_key` are what matter (`url` and `api_key` are required; an entry without both is ignored). `current` is the id of the
server used at start. `store_url` and `store_key` are the **project store** (below). `document_session`, `relay_url` and `relay_api_key` are optional (a fixed document session id; the Browser window's relay, a
`ws://` or `wss://` address: see [Setting up the Browser](#setting-up-the-browser-the-browser-relay)).
At most 12 servers.

`res://secrets.cfg` (developer machines; never in an APK) is read first and wins at start: it is listed as **From secrets.cfg**, read-only, and is
never written into `servers.cfg`. Another server can be used meanwhile (and secrets.cfg switched back to) without a restart, but the next start is on
secrets.cfg again.

## Using the Servers page

Landing > **Servers** (or tap the connection pill at the top of the launcher):

- **Use** switches to that server at once, with no restart. Everything loaded from the old server (a native file, a new assembly) is unloaded first,
  because its part ids mean nothing to the new one; unsaved changes ask first, like any replace (do it again within a few seconds to discard). A bare
  glb stays. **Use no server** goes offline (the demo models still work).
- **Test** asks `GET <address>/health` with the key and says what the answer means (works, key refused, no answer, certificate, error number).
- **Forget** removes it from the list and the file. The one in use goes offline first.
- **Relay** opens that server's **Browser relay** form under its row: the relay's address (`ws://` or `wss://`) and its own key, then **Save relay**
  (the row then reads **Relay on**; **Remove relay** clears it). See [Setting up the Browser](#setting-up-the-browser-the-browser-relay).
- **Add a server by typing:** Name, Address, Key on the full keyboard, then **Test these** and **Save and use**. The address is checked first (below).
  The key is shown as dots.
- **Scan a QR code:** see [Scanning](#scanning-a-qr-code).

### Which addresses are accepted

The same rules as DIDSA-CAD's pairing checks (`client/lib/vr_pairing/headset_pairing.dart`; `server_address.gd` is a port, checked against 24 cases in
`tests/servers.gd`):

- **Refused:** not http(s); no host; `localhost` and other loopback (the headset is not the server); `10.0.2.2` (the emulator's alias); link-local
  (`169.254.x.x`); a user name or password in the address; plain `http://` to anything that is not on a local network.
- **Allowed with a warning:** `http://` on a local network (RFC 1918, Tailscale, a `.local` / `.lan` name, a bare machine name): the key travels
  unencrypted and the headset must be on the same Wi-Fi; a `.local` name (may not resolve); Tailscale (same tailnet); `https://` to a private address
  (the certificate must be one the headset trusts).
- **Plain `http://` to a LAN server on the Quest is untried.** Android's cleartext rule is enforced by its Java networking stack and Godot's
  `HTTPRequest` uses its own sockets, so it very likely works, but nobody has run it on a headset. If it is blocked, the Test button says so and
  [`landing-scope.md`](landing-scope.md#plain-http-on-the-quest) (step L0) has the fix.

## The project store (server projects)

Server projects (`docs/server-projects.md`) live on DIDSA-CAD's **project store** (`project-store/` there), a service with its own address (port 8200 by default)
and its own key (`PROJECT_STORE_API_KEY`), not the CAD key. Give the headset both in any of these ways:

- **Scan the QR code** DIDSA-CAD shows (Connect a VR headset) once it writes `p=<store address>` and `pk=<store key>`; the card then lists "Project store: ...". (`s` is
  the document session; the store does not use it.) A code without them still pairs. The flat app's screen does not write them yet (`docs/server-projects.md`, "What
  DIDSA-CAD needs").
- **Type them** under Servers: the two optional fields in the add form, or **Store** on a saved server (like **Relay**): the address goes through the same rules as a
  server's (plain `http://` only on a local network) and the store needs its key.
- **`secrets.cfg`** `[project_store] url= api_key=` (developer override).
- **Pre-load** `store_url` and `store_key` in `servers.cfg`.

The Servers page also shows where server projects are copied (`Documents/DIDSA-Cloud`, or the app's own storage without All files access) and what **this device is
called** to the store (a name you can change; default from the platform, e.g. the Quest's model): other devices see it as "changed by ...", and it is trusted for nothing else.

## The session hub (live sessions)

Only **hosting** a live session needs it (`docs/live-sessions.md`); joining needs nothing, the join code carries the hub. **Hub** on a saved server's row opens a form: the hub's address
(`wss://` anywhere, plain `ws://` only to a local-network address; `/ws` is added for you and a trailing one dropped) and its own key (`SESSION_HUB_API_KEY`, not the CAD key); **Save hub** (the
row then reads **Hub on**; **Remove hub** clears it). It is kept with the server in `servers.cfg` (`hub_url`, `hub_key`). The same two values come from a pairing code (`h`, `hk`, written by
DIDSA-CAD's Connect a VR headset when the flat app has the hub set) and from `secrets.cfg`'s `[session_hub]` (`url`, `api_key`). If none is saved the backend's `/health` may advertise an address
(`session_hub`); the key still has to be set. `DIDSA_SESSION_ALLOW_LOOPBACK=1` lets a desktop preview use a hub on the same PC.

## Setting up the Browser (the browser relay)

The Browser window (wrist tablet > Windows > Browser) does not talk to the CAD backend. It shows a real Chromium tab running in a second service,
**browser-relay** (DIDSA-CAD `browser-relay/`, its README has the design), which streams the page to the headset over a WebSocket. Without a relay the
window says *No browser relay set for this server*.

**1. Run the relay** on the same computer or Pi as the backend (Docker; from the DIDSA-CAD repo root):

```
cp docker-compose.example.yml docker-compose.yml      # once
export CAD_API_KEY=...                                 # the backend's key, as before
export BROWSER_RELAY_API_KEY=<a different long random string>
docker compose up -d --build browser-relay
curl http://<server-ip>:8100/health                    # {"status":"ok"}: it is up (this check needs no key)
```

Without Docker: `cd browser-relay && pip install -r requirements.txt`, then `BROWSER_RELAY_API_KEY=... BROWSER_RELAY_CHROME_BINARY=<chromium>
python -m uvicorn app.main:app --host 0.0.0.0 --port 8100` (note `--host 0.0.0.0`, or the headset cannot reach it). Debian's `chromium` works;
Ubuntu's `chromium-browser` is a snap wrapper that does not run in a container.

**2. Give the headset its address and key**, either way:

- **Pairing code:** in the flat app, File > **Connect a VR headset...** > **Browser relay (optional)**: the address (`ws://<server-ip>:8100`, or
  `wss://` behind an https tunnel) and the relay key, **Save relay and check again**, then scan the code. The headset's card lists *Browser relay*.
- **On the headset:** Landing > **Servers** > **Relay** on the server's row, type both, **Save relay**.

The address is the base only: the app adds `/ws`. An `http(s)://` address is taken as `ws(s)://`. The same rules as a server's address apply:
plain `ws://` only on your own network.

**3. Open the Browser.** It says *Connected. Tap the address bar to open a page.* and shows a blank white page (it starts on about:blank);
tap the address bar, type an address or search words, and Go. (Before 11 Nov 2026 the window stayed empty even when connected: see `status.md`.) *Could not connect to the browser relay at ...* means one of: the relay is not
running (step 1's `curl`), the address or port is wrong, the key is the CAD key instead of `BROWSER_RELAY_API_KEY` (the relay closes the connection
before it opens, so a wrong key looks the same as no answer), or the headset is on another network. The relay allows 2 tabs at once
(`BROWSER_RELAY_MAX_SESSIONS`); closing the window frees its tab.

**Not verified:** the relay on the Raspberry Pi (arm64 Chromium), plain `ws://` from a Quest (as for `http://`, Godot uses its own sockets, so it
is expected to work), and a `wss://` relay behind a tunnel.

## Pre-loading a headset (no typing)

For a demo you set up yourself: write `servers.cfg` as above on your computer, then copy it into the app's data folder:

```
adb push servers.cfg <the folder shown at the bottom of the Servers page>/servers.cfg
```

The Servers page prints the exact folder (`OS.get_user_data_dir()`) at its foot. **Not verified:** which folder that is on a Quest, and whether `adb push`
can write to it without the app being a debug build (for a debug build, `adb shell run-as <package> ...` reaches the app's private files). Check it once
on the headset and correct this paragraph. The app reads the file at start, so restart it after pushing.

## Scanning a QR code

DIDSA-CAD shows the code (File > **Connect a VR headset...**, or the connection screen's **Connect a VR headset**): `didsa-vr:1?n=<name>&u=<url>&k=<key>`
(plus `&r=<relay>&rk=<relay key>` when a Browser relay is set there),
format and checks in DIDSA-CAD's `docs/vr-headset-pairing.md`. The headset reads it with **OpenXR marker tracking, which is in Godot's core**: the
runtime finds and decodes the code and Godot hands over an `OpenXRMarkerTracker` whose marker data is the text. No camera access, no decoder, no addon.

**Step L5 is the headset spike, and it has not been run.** What is built is a Scan page that makes the first run explain itself, and the project settings
(`project.godot`, **Android only**, so desktop and PC-VR builds are unchanged): `xr/openxr/extensions/spatial_entity/enabled`, `.../enable_marker_tracking`
and `.../enable_builtin_marker_tracking`, each with the `.android` feature tag.

### After a code is read (L6)

A DIDSA pairing code raises **Connect to <name>?** on the Scan page: its address (and, for plain http, the unencrypted-key warning), nothing saved yet,
the key never shown. **Connect** asks the server (`GET /health` with the code's key); if it answers the server is saved to `servers.cfg`, switched to at once
(document session and browser relay come with it) and the Servers page opens. If it does not answer the card says why and offers **Save anyway** or Cancel.
**Cancel** (also while it is asking) saves nothing. Rescanning a saved server updates its key. Another QR code, a code the address rules refuse, or a newer
version are reported on the page and never raise a card. The rules a code must pass are the typed ones ([above](#which-addresses-are-accepted)), plus no
control characters and sane lengths (`pairing_payload.gd`).

Not built: the card appearing on top of the screen where the code was seen (it is on the launcher), and DIDSA-CAD's version 2 (a short-lived pairing token
exchanged once for a per-device key: backend work, so version 1 still carries the single `CAD_API_KEY`).

### Running the spike (needs a headset and an APK built with these settings)

1. Landing > **Servers** > **Scan a QR code**. The page lists each stage with the headset's answer: *OpenXR running*, *Marker tracking present*, *QR codes
   supported*, *Scene permission* (asked at the page's start on Android), *Listening*, trackers seen, QR codes read.
2. Show a code on a screen (DIDSA-CAD, **Connect a VR headset**) and look at it. You must be able to see the screen: **turn passthrough on** (the page has
   a button).
3. When a code is read the page says what it was ("a DIDSA pairing code for Workshop PC (cad.example.net)", "a QR code that is not ours", "refused: ...").
   It never prints the code, which carries the API key.

What step L5 has to answer (write the answers into this page and the scope):

- Does *QR codes supported* say yes on your Quest 3 and Horizon OS version? (A forum report says it works on a Quest 3 with Horizon OS v83 and Godot 4.6, not
  4.5.)
- Which Android permission is needed? The OpenXR Vendors plugin writes `com.oculus.permission.USE_SCENE` (and `USE_ANCHOR_API`) into the manifest by itself while
  `xr/openxr/extensions/spatial_entity/enabled` reads true in the editor at export time (its source says so; `project.godot` has it with `.editor_hint` for that since 21 Oct, see `android-build.md`, the Android-only setting trap), and the scanner asks for the scene permission at run time. **Whether marker tracking
  needs exactly that one is still unknown**; the Scan page says what the headset answered.
- Does the runtime create a marker tracker for a code on a monitor at all, and how large must it be on screen?
- Is the tracker delivered through the XRServer's `tracker_added` / `tracker_updated` (what the scanner listens to, plus a 0.5 s poll)?

**Passthrough** is needed to see the screen, and on a standalone Quest that needs the OpenXR Vendors plugin: step L0, now prepared (`docs/android-build.md`;
the plugin is fetched by `tools/install_vendors_plugin.sh`, and no APK has been built from it yet). Over a PC link (Virtual Desktop) the headset's own passthrough settings apply but marker tracking would need the
PC runtime to offer it, which is untested. If marker tracking works and passthrough does not, the options are L0, or the typed route above. If marker tracking
does not work, route B (the Passthrough Camera API with a QR decoder in a small Kotlin plugin) breaks the "no addons" rule and needs L0 too.

## Tests

`tests/servers.gd` (the store, the address rules, switching and forgetting, the unload, secrets.cfg, a hand-written file, the Servers page) and
`tests/qr_scanner.gd`, `tests/scan_page.gd` (the scanner and the Scan page, with codes fed in by hand), `tests/pairing_payload.gd` (the code's format) and `tests/pairing_flow.gd` (Connect, Save anyway, Cancel), and
`tests/server_probe.gd` (the Test button against a stub `/health` server, `tests/helpers/stub_health_server.py`, needs `python3`) and, against a **real DIDSA-CAD
backend** (branch `claude/vr-landing-feature-scope-kspao7`, 20 Oct 2026), `tests/e2e_servers.gd`: Test, adding and switching, the demo table and plate and peg,
Continue, offline unloading, New assembly and pairing by code with the right and a wrong key. Not on a headset.
