# Server projects (S3)

Phase S3 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md` (Part 2, shared storage); the scope is DIDSA-CAD `docs/shared-storage-scope.md`
(sections 6, 7 "DIDSA-VR (S3): a mirror folder", 8 and 9; all eight section 8 decisions accepted). The store itself is DIDSA-CAD `project-store/`; the flat app's
side (S2) is `client/lib/storage/server/`, which this matches in rules and words. Built 2026-11-14. **Headless and against a real store only; nothing here has
been run on a headset** (see "Not verified").

## What it is

A project on the project store (a service beside the CAD backend that keeps projects as folders, gives every file a version and refuses a save made from a
stale copy) can be opened on the headset. Opening it copies what is needed into a **mirror folder**, an ordinary visible folder on the headset, so
`native_compose.gd`, `file_lookup.gd`, `file_index.gd` and `project_save.gd` work on it **unchanged**. A sync step keeps the mirror level with the store.

```
Documents/DIDSA-Cloud/<server host>/<project>/     the mirror: VISIBLE, a sibling of Documents/DIDSA (not inside it, not a dot-folder)
user://didsa-cloud-state/<key>/state.json          PRIVATE: what each file was at the last sync, the queue, the feed cursor, "mine" copies
user://didsa-cloud-state/<key>/mine/               PRIVATE: bytes kept after Take theirs
```

* **The mirror is the user's.** A file dropped or edited by hand is a **local change**; a file removed by hand is only "not downloaded" and is **never** a delete
  on the server (nothing in the code sends a delete). Dot-files and temp files (`.saving`, `.cloudtmp`) are not project files.
* **Why a sibling of `Documents/DIDSA`.** The moved-files index skips dot-folders, and the local Files list would show a nested folder. The root is **one
  setting** (`AppSettings.cloud_folder`, `""` = `Documents/DIDSA-Cloud`; `scripts/cloud/cloud_paths.gd`) so it can move if Launcher > Servers > Check storage shows
  Documents too slow or small. There is no settings screen for it yet: edit `[cloud] folder=` in `settings.cfg`.
* **All files access.** Documents needs it on the Quest (as the local project folder does). Without it, or when the folder cannot be made or written, the mirror falls
  back to `user://DIDSA-Cloud` and **Files > Server projects** and the Servers page say so, with the reason.
* **The state is private** so deleting the mirror cannot delete the queue. A queued save whose mirror file is gone is shown as a warning ("a save is waiting to be
  sent, but its file is gone"), not dropped and not sent as a delete.

## How a sync works (`scripts/cloud/cloud_project.gd`)

1. **Scan the mirror** (no network). Every file's SHA-256 is compared with the hash it had at the last sync: new = a queued create (base version null), different = a
   queued edit (base = the version it was based on), same = nothing ("a save whose bytes equal the version it was read at is not sent"). A file whose bytes equal
   the store's current version is recognised as that version (so a lost state does not turn the whole mirror into creates). Size and modified time are used only to
   skip re-hashing a file last changed before the previous scan; a file changed within the same second is always re-hashed.
2. **Ask the change feed** from the saved cursor (`GET .../changes?since=`). A queued save the feed shows is now stale becomes a clash; a file others changed is
   refreshed in the mirror **unless the open session holds it** (then the base stays and a save of it clashes: a re-read cannot move a base); a file the store
   removed disappears from a clean mirror (it stays in the store's history). A refused cursor (400 `bad_cursor`) falls back to the tree. No cursor yet = the tree.
3. **Stop at clashes.** With any clash nothing is sent; the user settles each (below).
4. **Send the queue.** One file: `PUT` with `If-Match: "<base>"` (a create: `If-None-Match: *`). Several: upload each, then **one** `POST .../commit`, all or
   nothing; a 409 lists every clash and writes nothing. A write is never sent without a precondition (428 would be a bug). The store's answer is what is recorded.

Runs when a server project is opened, every 20 s while one is open (`CloudManager`'s timer), after **Save** (main.gd syncs the active project), and on **Sync now**.

**Choices** (`resolve()`, per file, the flat app's words): *Keep mine* (re-based on their version, so mine is the next version over theirs), *Take theirs* (their file
is written into the mirror; mine is kept in private storage until the next sync after the one that finishes the resolution), *Save mine as a copy*
(`<name> (<device>, <date>).didsa`, a new document, Part and sketch id: `cloud_remint.gd`, the GDScript twin of `remint_identity.dart`; VR had no remint, since "Save as
new file" writes a whole-session snapshot). A deleted or moved file is a clash like any other ("Deleted by Phone", "Renamed to X by Desktop").

**Failures.** Unreachable = queued, never lost ("Working from the local copy"). 401 names the store key. 413 and 400 show the store's own message and keep the save
(the timer does not retry it until the queue changes; **Sync now** does; **Keep local only** stops trying and the file stays in the mirror). A file over 100 MB that
fails while the store still answers `/health` is explained as the Cloudflare tunnel's limit; no chunking (that is S4). A send problem leaves the whole queue queued
(a Save All is never half sent).

**Moved files against the store.** `prepare_open()` brings the root file and everything it places into the mirror: a reference found at its path (or under another
native extension / letter case) is fetched; one that is not is looked up with `GET .../parts/{part_id}` (the tree's own part ids when offline) instead of reading files,
and the file it names is fetched. `native_compose.gd` then runs on the mirror unchanged and relinks it by id.

## Where it is in the app

| | |
|---|---|
| Wrist tablet > Files > **Server projects** | The store's projects with a state symbol each (tick = synced, up arrow = to send, plain cloud = on the server only, slash = not connected, mark = clash) and the count in words; a project's files, its clashes (Keep mine / Take theirs / Save mine as a copy), refused saves (Keep local only), unsent saves with no file, kept copies (Put back as a file); Sync now, Refresh, New project. |
| Files > Models | One line pointing there, with what is waiting. |
| Landing | A row "Waiting to sync" / "Clash to settle" with the words, which opens Files > Server projects. Built from the saved state, no network. |
| Launcher > Servers | Project store address and key (in the add form and per saved server, **Store**); where server projects are copied (and why not Documents); this device's name. |
| Pairing | The QR code's `p=<store address>` and `pk=<store key>` (not `s` / `sk`: `s` is the document session). The card says "Project store: ...". An older headset ignores both; `pairing_payload.gd` ignored unknown keys already. |
| `secrets.cfg` | Optional `[project_store] url= api_key=` (developer override, like `[browser_relay]`). |

`scripts/cloud/`: `cloud_paths.gd` (where), `cloud_files.gd`, `cloud_state.gd` (private state), `cloud_store_client.gd` (the API, every status as a `kind`),
`cloud_http_transport.gd` (HTTPRequest), `cloud_project.gd` (scan, sync, choices, opening), `cloud_manager.gd` (what main.gd and the screens use; the timer),
`cloud_remint.gd`.

## Differences from the scope, and why

* **No `user://projects/<server>/<project>/` mirror and no `sync.json` beside it.** The owner's decision (13 Nov): the mirror is visible in Documents so files can be
  dragged in; the state is private in `user://`. (The scope's section 7 text predates it.)
* **The queue is found by scanning, not recorded at save time.** `project_save.gd` is not changed; whatever writes into the mirror (a save, the owner's hand, another
  app) is picked up the same way.
* **A file the store removed is removed from a clean mirror** (the flat app evicts its cache copy). The bytes are identical to the last version, which the store keeps.
* **`Sync now` is also "try again"** for a refused save, and a refused save does not stop the next timer ticks from checking the feed, only from re-sending it.
* **Rename in a server project is not offered** (the flat app does it online with a commit `move`); VR has no rename today.
* **No "Copy this project to the server".** Make a project on the store (Server projects > New project...), then save into it, or drop files into its mirror.
* **The conflict choices are buttons on the tablet's list,** not a dialog. Take theirs asks "Sure?" on a second press.
* **After Take theirs or Save as a copy the open session no longer matches the mirror.** The status line says to open the file again; there is no automatic reload.

## Not verified

* **Nothing on a headset**: the permission prompt and whether Documents/DIDSA-Cloud works with All files access on Horizon OS, how fast a sync of a real project feels,
  how the symbols, the rows and the three buttons read in the headset, the laser on the new buttons (they were pressed directly in tests).
* The Quest storage spike (Launcher > Servers > Check storage) has not been read off the headset: whether Documents is fast and large enough is still the owner's call.
* Not run against the owner's Pi, a Cloudflare tunnel (the 100 MB behaviour is the documented limit plus a simulated cut-off), or a synced Drive / NAS store root.
* A big project: the scan hashes every file on the first sync after a restart (the size / mtime shortcut is in memory only); the queue is read from disk file by file when
  sent. Not measured. The store's `parts` index is trusted as it answers.
* Two sessions open on one mirror, a store restored from a backup while a queue is waiting (the bad-cursor path is tested against the fake store and one real run), and
  killing the app mid-sync are covered by design (atomic state writes, the queue as the source of truth), not by a test that kills the process.
* The flat app's **Connect a VR headset** screen does not yet write `p` and `pk` (see below).

## What DIDSA-CAD needs (a small follow-up there, not done in this PR)

`client/lib/vr_pairing/` builds `didsa-vr:1?n=<name>&u=<url>&k=<key>` (plus optional `s`, `r`, `rk`). For S3 it must also write, when the flat app has a store set up
(`ApiConfig.storeUrl` / `storeApiKey`):

* `p=<the store's address>`: percent-encoded with `Uri.encodeQueryComponent` like the other values, `https://` (or `http://` on a local network), no trailing slash;
* `pk=<the store's key>`: likewise.

Both are optional and independent of `s`; leave them out when no store is configured. The headset refuses a code whose `p` fails its address rules (plain http to the
internet), takes `p` without `pk` (the card says there is no key), and ignores any other key. Add a test with the codes in `tests/cloud_paths.gd` as the reference.

## Tests

`cloud_paths`, `cloud_remint`, `cloud_sync`, `cloud_moved_files`, `cloud_manager`, `cloud_ui` (headless, a fake store: `tests/fake_project_store.gd`, `tests/cloud_rig.gd`) and
`e2e_cloud_store` (a real store; `tests/ci_e2e.sh` starts a throwaway one). See `tests/README.md`.
