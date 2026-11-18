"""A scripted PRESENTER for tests/e2e_session_observer.gd (the headset is the observer). It builds a small assembly in the real backend, mints a view token, hosts on the real hub with
the hub key, then plays a script the Godot test steps through by creating files (<out>.step1, <out>.step2 ...): each step waits for its file, so nothing depends on timing:
    step 0  (as soon as an observer has joined)  place, the full pose table, visibility, a section, a status
    step 1  a part moved (a 30 Hz run of partial poses), the observer sees it arrive smoothed
    step 2  a part hidden (the full hidden list)
    step 3  a REAL document change (the bolt hidden in the backend) and a doc_changed with the revision the backend answered: the observer refetches with the token
    step 4  doc_changed for a newer revision the backend has nothing new for: the observer's refetch is a 304
    step 5  the presenter drops its socket and resumes (a new connection, the full state again)
    step 6  End: the token is revoked at the backend and the hub told
Writes <out> (JSON) at the start (the code, the root, the real paths) and at the end (what the backend answered). Usage:
    python session_presenter_stub.py --cad http://127.0.0.1:8001 --cad-key K --hub ws://127.0.0.1:8300 --hub-key H --out state.json"""

import argparse
import asyncio
import json
import sys
import time

from websockets.asyncio.client import connect

from session_common import build_assembly, cad_client, glb_instance_paths, until, wait_for_file, write_json

XF = lambda x, y, z: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, x, y, z]  # noqa: E731


async def main() -> int:
    parser = argparse.ArgumentParser()
    for name in ("--cad", "--cad-key", "--hub", "--hub-key", "--out"):
        parser.add_argument(name, required=True)
    args = parser.parse_args()
    cad = cad_client(args.cad, args.cad_key)
    root, bolt = build_assembly(cad)
    minted = cad.post("/document/view-tokens", json={"root_part_id": root}).json()
    token, rev = minted["token"], minted["rev"]
    glb = cad.get(f"/document/parts/{root}/assembly-mesh.glb", params={"quality": 0.5, "include_hidden": "false"})
    paths = glb_instance_paths(glb.content)
    bolt_path = next((p for p in paths if p == bolt), paths[-1])
    state = {"root": root, "bolt_path": bolt_path, "paths": paths, "rev": rev, "token": token, "code": "", "backend_url": args.cad}
    seq = 0

    async def send(ws, message: dict) -> None:
        nonlocal seq
        seq += 1
        await ws.send(json.dumps({**message, "seq": seq}))

    host_message = {"t": "host", "proto": 1, "name": "Python presenter", "device": "desktop", "client": "session_presenter_stub.py",
                    "model": {"kind": "backend", "root_part_id": root, "rev": rev, "quality": 0.5, "tier": "full", "title": "Mount"}, "backend_url": args.cad, "view_token": token}
    async with connect(f"{args.hub}/ws", additional_headers={"X-API-Key": args.hub_key}) as ws:
        await ws.send(json.dumps(host_message))
        welcome = await until(ws, "welcome")
        state["code"] = welcome["room"]["code"]
        state["resume"] = welcome["resume"]
        write_json(args.out, state)
        joined = await until(ws, "joined", timeout=90)
        state["observer"] = joined["participant"]["name"]
        place = [0.002, 0.0, 0.0, 0.0, 0.002, 0.0, 0.0, 0.0, 0.002, 1.0, 1.0, -2.0]

        async def publish_all() -> None:
            await send(ws, {"t": "place", "xf": place})
            await send(ws, {"t": "poses", "full": True, "items": [{"path": p, "xf": XF(15.0, 0.0, 10.0) if p == bolt_path else XF(0.0, 0.0, 0.0)} for p in paths]})
            await send(ws, {"t": "visibility", "hidden": []})
            await send(ws, {"t": "section", "on": True, "point": [10.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0]})
            await send(ws, {"t": "status", "activity": "design_table", "detail": "Mount"})

        await publish_all()
        # step 1: a part moves
        assert await wait_for_file(args.out + ".step1"), "step1 never came"
        for i in range(12):
            await send(ws, {"t": "poses", "items": [{"path": bolt_path, "xf": XF(15.0 + 2.0 * (i + 1), 0.0, 10.0)}]})
            await asyncio.sleep(1 / 30)
        state["moved_to"] = 15.0 + 2.0 * 12
        write_json(args.out, state)
        # step 2: hide
        assert await wait_for_file(args.out + ".step2"), "step2 never came"
        await send(ws, {"t": "visibility", "hidden": [bolt_path]})
        # step 3: a real change in the backend, then doc_changed with the revision it answered
        assert await wait_for_file(args.out + ".step3"), "step3 never came"
        changed = cad.patch(f"/document/parts/{root}/occurrences/{bolt}", json={"hidden": True})
        state["changed_status"] = changed.status_code
        new_rev = int(changed.headers["x-document-revision"])
        state["new_rev"] = new_rev
        await send(ws, {"t": "doc_changed", "rev": new_rev, "all": True})
        await send(ws, {"t": "poses", "full": True, "items": [{"path": p, "xf": XF(0.0, 0.0, 0.0)} for p in paths if p != bolt_path]})
        write_json(args.out, state)  # (the test reads new_rev from here)
        # step 4: a newer revision with nothing new behind it
        assert await wait_for_file(args.out + ".step4"), "step4 never came"
        await send(ws, {"t": "doc_changed", "rev": new_rev + 3, "all": True})
        state["spare_rev"] = new_rev + 3
        write_json(args.out, state)
        # step 5: drop and resume
        assert await wait_for_file(args.out + ".step5"), "step5 never came"
    await asyncio.sleep(0.5)
    async with connect(f"{args.hub}/ws", additional_headers={"X-API-Key": args.hub_key}) as ws:
        await ws.send(json.dumps({"t": "resume", "proto": 1, "resume": state["resume"]}))
        resumed = await until(ws, "welcome")
        state["resumed_as"] = resumed["you"]
        seq = 0
        await publish_all()
        # step 6: end
        assert await wait_for_file(args.out + ".step6"), "step6 never came"
        await ws.send(json.dumps({"t": "end"}))
        revoked = cad.delete(f"/document/view-tokens/{token}")
        state["revoke_status"] = revoked.status_code
        import httpx

        after = httpx.get(f"{args.cad}/document/parts/{root}/assembly-mesh.glb", headers={"X-View-Token": token}, timeout=30)
        state["after_end_glb_status"] = after.status_code
    state["finished_at"] = time.time()
    write_json(args.out, state)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
