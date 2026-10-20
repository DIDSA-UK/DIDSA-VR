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

[server.phone]
name="Phone"
url="http://192.168.1.9:8000"
api_key="..."
```

`name`, `url` and `api_key` are what matter (`url` and `api_key` are required; an entry without both is ignored). `current` is the id of the
server used at start. `document_session`, `relay_url` and `relay_api_key` are optional (a fixed document session id; the Browser window's relay).
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

## Pre-loading a headset (no typing)

For a demo you set up yourself: write `servers.cfg` as above on your computer, then copy it into the app's data folder:

```
adb push servers.cfg <the folder shown at the bottom of the Servers page>/servers.cfg
```

The Servers page prints the exact folder (`OS.get_user_data_dir()`) at its foot. **Not verified:** which folder that is on a Quest, and whether `adb push`
can write to it without the app being a debug build (for a debug build, `adb shell run-as <package> ...` reaches the app's private files). Check it once
on the headset and correct this paragraph. The app reads the file at start, so restart it after pushing.

## Scanning a QR code

See the section below once L5 and L6 land; the code's format is DIDSA-CAD's `docs/vr-headset-pairing.md`.

## Tests

`tests/servers.gd` (the store, the address rules, switching and forgetting, the unload, secrets.cfg, a hand-written file, the Servers page) and
`tests/server_probe.gd` (the Test button against a stub `/health` server, `tests/helpers/stub_health_server.py`, needs `python3`). **Not run against a
real DIDSA-CAD backend** (none was available in the build session), and not on a headset.
