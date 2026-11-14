# Server projects (S3, hardened in S4)

Phase S3 of DIDSA-CAD `docs/mates-storage-sessions-plan-2026-11-12.md` (Part 2, shared storage); the scope is DIDSA-CAD `docs/shared-storage-scope.md`
(sections 6, 7 "DIDSA-VR (S3): a mirror folder", 8 and 9; all eight section 8 decisions accepted). The store itself is DIDSA-CAD `project-store/`; the flat app's
side (S2) is `client/lib/storage/server/`, which this matches in rules and words. Built 2026-11-14. **Headless and against a real store only; nothing here has
been run on a headset** (see "Not verified"). S4 (14 Nov) hardened it: chunked upload, resume, the size of the local copy, a hash cache that survives a restart;
see "S4: hardening" below.

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
  Documents too slow or small. **Launcher > Servers** has it since S4 ("Local copy folder", typed with the keyboard; empty = the default). Changing it does not move
  files already copied: the new folder starts empty and fills as projects are opened (the sync state is private and stays).
* **All files access.** Documents needs it on the Quest (as the local project folder does). Without it, or when the folder cannot be made or written, the mirror falls
  back to `user://DIDSA-Cloud` and **Files > Server projects** and the Servers page say so, with the reason.
* **The state is private** so deleting the mirror cannot delete the queue. A queued save whose mirror file is gone is shown as a warning ("a save is waiting to be
  sent, but its file is gone"), not dropped and not sent as a delete.

## How a sync works (`scripts/cloud/cloud_project.gd`)

1. **Scan the mirror** (no network). Every file's SHA-256 is compared with the hash it had at the last sync: new = a queued create (base version null), different = a
   queued edit (base = the version it was based on), same = nothing ("a save whose bytes equal the version it was read at is not sent"). A file whose bytes equal
   the store's current version is recognised as that version (so a lost state does not turn the whole mirror into creates). Size and modified time are used only to
   skip re-hashing: **since S4 the record (`size`, `mtime`, hash, when it was taken) is kept in the private state, so a restart does not re-hash every file**. The same
   size and modified time are trusted only when the file had been still for more than a second when it was hashed (git's "racy timestamp" rule); a changed size, or
   a modification within a second of the hash, is always re-hashed. A change that keeps size AND mtime and is older than a second is missed (the store's own scan has the
   same limit); a save is still checked by the store's `If-Match`.
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
fails while the store still answers `/health` and **cannot take chunks** (no `uploads.chunked` in its features) is explained as the Cloudflare tunnel's limit; a store that
can gets the file in chunks (below). A send problem leaves the whole queue queued (a Save All is never half sent).

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
* **Rename in a server project is not offered** (the flat app does it online with a commit `move`); VR has no rename today. *(Still not built after S4: a feature, not hardening.)*
* **No "Copy this project to the server".** Make a project on the store (Server projects > New project...), then save into it, or drop files into its mirror. *(Still not built after S4.)*
* **The conflict choices are buttons on the tablet's list,** not a dialog. Take theirs asks "Sure?" on a second press.
* **After Take theirs or Save as a copy the open session no longer matches the mirror.** The status line says to open the file again; there is no automatic reload. *(Still so after S4.)*

## Not verified

* **Nothing on a headset**: the permission prompt and whether Documents/DIDSA-Cloud works with All files access on Horizon OS, how fast a sync of a real project feels,
  how the symbols, the rows and the three buttons read in the headset, the laser on the new buttons (they were pressed directly in tests).
* The Quest storage spike (Launcher > Servers > Check storage) has not been read off the headset: whether Documents is fast and large enough is still the owner's call.
* Not run against the owner's Pi, a **Cloudflare tunnel** (the 100 MB limit is Cloudflare's documentation, not measured; the fake imitates it with a non-JSON 413 and a body cap, the
  real store was only ever driven directly), or a synced Drive / NAS store root. The chunked path was exercised against a real store process that was killed and restarted
  (`e2e_cloud_outage`), but with 3 MB files and 1 MB chunks, not 100 MB+ ones: **no file near the real limits has been sent**, so speed, memory and the HTTPRequest's behaviour on a
  32 MB body on a Quest are unknown. A download is still one request held in memory (no resume of a cut download; a file of 200 MB would be read whole).
* The persisted hash cache is not measured on a big project (it removes the re-hash after a restart by design); a scan still lists the mirror and stats every file.
* The cache clean-up was tested for the rules (what may and may not go, the order, across projects), not for a real disk filling up, and "least recently used" is the last
  open or download here, not a record of every read by other apps.
* The Continue tile's picture is drawn for real only under Xvfb (software GL), never on a Quest; whether it looks right in the headset, and the hitch of drawing it after a load, are unknown.
* Two sessions open on one mirror, a store restored from a backup while a queue is waiting (the bad-cursor path is tested against the fake store and one real run), and
  killing the *app* mid-sync (the store was killed and restarted, and the app "closed and reopened" by building a new `CloudProject` over the same state, but the process itself was
  not killed mid-write) are covered by design (atomic state writes, the queue as the source of truth), not by a test that kills the app.
* The Servers page's new buttons (folder, room for local copies, free up space) were built and their logic tested; they were not pressed with a laser, and the folder keyboard was not used on a headset.

## What DIDSA-CAD does (done in S4)

`client/lib/vr_pairing/` now writes `p=<the store's address>` and `pk=<the store's key>` (percent-encoded, no trailing slash) when the flat app has a store set up
(`ApiConfig.storeUrl` / `storeApiKey`, both or neither), and the screen says that the code includes the key. A code without them still pairs. They are not `s` / `sk`.
Not tried: a real scan of a code with all of `r`, `rk`, `p`, `pk` by this headset's camera (the QR length grows; `pairing_payload.gd` parses it).

## S4: hardening (14 Nov)

**Chunked upload.** A file over 90 MB (`CHUNK_THRESHOLD`; the tunnel's limit is 100 MB), or one a tunnel refuses with a non-JSON 413, goes up in 32 MB chunks (`CHUNK_BYTES`, or
the store's own advice when smaller) through the store's chunk routes (DIDSA-CAD `project-store/README.md`): `POST .../uploads/sessions {size, sha256}`, `PUT .../uploads/{id}?offset=`,
`GET .../uploads/{id}` (how far it got), `POST .../uploads/{id}/complete` (the store checks the SHA-256 and size). The result is an upload id used in the **commit as usual**, so
even a single big file is a one-file commit with its base version (never a `PUT` of the whole body) and the stale-save check is unchanged. The file is read a chunk at a time
(`FileAccess`), not held whole, and hashed in a stream. A store without `uploads.chunked` gets the old message, reworded ("cannot take it in pieces").

**Interrupted uploads.** The session `{id, hash, size, time}` is saved in the private state before the first chunk (`state.uploads`). A cut connection, a store that was switched
off, or the app being closed all end the same way: the next sync asks `GET .../uploads/{id}` and sends only the rest, on the same session; no chunk is sent twice and one version
results. A chunk whose reply was lost is sent again and the store answers 409 `wrong_offset` with where it really is, which is adopted (a store that keeps naming the offset it
was just sent makes the sync give up after three tries instead of looping). A changed file (another hash) starts a new upload; an expired one (an hour without a chunk), or one
the store discarded for a hash mismatch, starts again once. The unfinished session of a file that was edited meanwhile is left to expire on the store.

**A server that comes back mid-save.** A commit or `PUT` that **landed with its reply lost** leaves the save queued; the next sync sees the change in the feed, and because the
queued bytes equal the store's current version (`_adopt_equal`) there is no clash and no second version. Tests switch the store off and on (`die_after`, `restart_store`,
`lose_reply_next` in the fake; a real process killed and restarted in `e2e_cloud_outage`).

**Two devices offline on one file.** The first back online wins; the second sees who changed it (the clash from the feed, before it uploads a big file for nothing) and the
three choices work; the same edit on both is no clash. No new rule was needed (the S3 rules covered it); it is now tested.

**The size of the local copy.** `AppSettings.cloud_cache_mb` (`[cloud] cache_mb=`, default 2048, 0 = no limit; **Launcher > Servers > Room for local copies** cycles 1 / 2 / 5 / 10 GB /
no limit and shows what is used). After each timer sync, and when the setting changes, `CloudManager.cleanup_cache()` removes the **least recently used clean** files across all
projects until the total fits. Only a file that is exactly the version it was synced as (re-hashed to be sure), has no save waiting, is not kept local-only, is not held by the open
session and is listed on the store may go; it becomes "on the server only" and opening it downloads it again. The limit is reported as exceeded, never met by deleting a save,
a clash, a dragged-in file or an open file. "Free up space now" removes every copy that is allowed to go. "Last used" is the time a file was last opened or downloaded here (kept in
the state), else its modified time. It counts the mirror's files, not the private state (`mine/` copies) or the hash records.

**Thumbnails.** The Rooms page already had a picture per open room (R-phase, `room_thumbnail.gd`; unchanged in what it shows). S4 adds the landing's **Continue** tile: after a model
loads, a few frames later `room_thumbnail.gd` draws it once off-screen (`render_model`, the same view as a room's) and `thumbnail_store.gd` keeps the picture in
`user://thumbnails/` keyed by the file's path (at most 64 pictures / 8 MB, oldest first, a damaged one removed); the Continue tile shows it in place of the symbol. Not for
the demo catalogue, the Files list or a server project's tile: they have no picture. Headless draws nothing, so there the tile keeps its symbol; the drawing is tested under Xvfb
(`thumbnail_render`).

## Tests

`cloud_paths`, `cloud_remint`, `cloud_sync`, `cloud_moved_files`, `cloud_manager`, `cloud_ui`, `cloud_hardening` (S4) and `thumbnail_store` (headless, a fake store:
`tests/fake_project_store.gd`, which can now be switched off and on, dropped after N requests, lose a reply after applying it, and serve/forget chunked uploads;
`tests/cloud_rig.gd`), `thumbnail_render` (Xvfb) and `e2e_cloud_store` + `e2e_cloud_outage` (a real store; `tests/ci_e2e.sh` starts one throwaway store, and the outage test starts,
kills and restarts its own). See `tests/README.md`.
