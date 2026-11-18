"""A scripted OBSERVER for tests/e2e_session_presenter.gd (the headset is the presenter). It joins by the code, fetches the presenter's glb from the backend with the view token ONLY
(200, then 304 with If-None-Match), checks what a token may not do, records every message the hub relays for --seconds, refetches on each doc_changed, and, when the session ends, checks the
token no longer works. Everything it saw goes to --out as JSON for the Godot test to judge. Usage:
    python session_observer_stub.py --hub ws://127.0.0.1:8300 --code K7XQ4M --out result.json --seconds 40"""

import argparse
import asyncio
import json
import sys
import time

import httpx
from websockets.asyncio.client import connect

from session_common import glb_instance_paths, write_json


def trim(message: dict) -> dict:
    """The message without the bulk (a pose table is counted, not stored)."""
    out = {k: v for k, v in message.items() if k not in ("items",)}
    if "items" in message:
        out["item_paths"] = [item.get("path") for item in message["items"]]
        out["items"] = message["items"][:4]
    return out


async def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hub", required=True)
    parser.add_argument("--code", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--seconds", type=float, default=40.0)
    args = parser.parse_args()
    result: dict = {"joined": False, "messages": [], "refetches": [], "errors": []}
    try:
        async with connect(args.hub + "/ws") as ws:
            await ws.send(json.dumps({"t": "join", "proto": 1, "code": args.code, "name": "Python observer", "device": "phone", "client": "session_observer_stub.py"}))
            welcome = None
            while welcome is None:
                raw = await asyncio.wait_for(ws.recv(), timeout=15)
                if not isinstance(raw, bytes) and json.loads(raw)["t"] == "welcome":
                    welcome = json.loads(raw)
            result["joined"] = True
            result["you"] = welcome["you"]
            result["snapshot"] = {k: v for k, v in welcome["snapshot"].items() if k != "poses"}
            result["snapshot_pose_paths"] = [p["path"] for p in welcome["snapshot"].get("poses", [])]
            result["snapshot_poses"] = {p["path"]: p["xf"] for p in welcome["snapshot"].get("poses", [])}
            token, backend, root = welcome["view_token"], welcome["backend_url"], welcome["snapshot"]["model"]["root_part_id"]
            result["backend_url"] = backend
            glb_path = f"/document/parts/{root}/assembly-mesh.glb"
            view = httpx.Client(base_url=backend, headers={"X-View-Token": token}, timeout=60)
            first = view.get(glb_path, params={"quality": 0.5, "include_hidden": "false"})
            etag = first.headers.get("etag", "")
            result["glb_first"] = {"status": first.status_code, "magic": first.content[:4].decode("latin-1"), "etag": etag, "bytes": len(first.content), "paths": glb_instance_paths(first.content) if first.status_code == 200 else []}
            again = view.get(glb_path, params={"quality": 0.5, "include_hidden": "false"}, headers={"If-None-Match": etag})
            result["glb_again_status"] = again.status_code
            result["forbidden"] = {}
            for method, path in [("GET", f"/document/parts/{root}"), ("GET", "/document/export/native"), ("GET", f"/document/parts/{root}/occurrences"), ("PATCH", f"/document/parts/{root}/occurrences/occ-bolt")]:
                result["forbidden"][f"{method} {path.replace(root, '<root>')}"] = view.request(method, path, json={} if method != "GET" else None).status_code
            state = view.get("/document/view-state")
            result["view_state"] = {"status": state.status_code, "rev": state.json().get("rev") if state.status_code == 200 else None, "header_rev": state.headers.get("x-document-revision")}
            result["ready_at"] = time.time()
            deadline = time.time() + args.seconds
            ended = False
            while time.time() < deadline and not ended:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=0.5)
                except asyncio.TimeoutError:
                    continue
                except Exception as error:  # the hub closed the socket after `end`
                    result["errors"].append(repr(error))
                    break
                if isinstance(raw, bytes):
                    continue
                message = json.loads(raw)
                if message["t"] == "ping":
                    await ws.send(json.dumps({"t": "pong", "n": message.get("n")}))
                    continue
                result["messages"].append({"at": time.time(), **trim(message)})
                if message["t"] == "token":
                    token = message["view_token"]
                    view.headers["X-View-Token"] = token
                if message["t"] == "doc_changed":
                    got = view.get(glb_path, params={"quality": 0.5, "include_hidden": "false"}, headers={"If-None-Match": etag})
                    new_etag = got.headers.get("etag", etag)
                    result["refetches"].append({"rev": message["rev"], "status": got.status_code, "etag": new_etag, "differs": got.status_code == 200 and got.content != first.content, "paths": glb_instance_paths(got.content) if got.status_code == 200 else []})
                    etag = new_etag
                if message["t"] == "end":
                    ended = True
                    result["end_reason"] = message.get("reason")
            if ended:
                # the presenter tells the hub `end` first and then revokes the token at the backend: the 401 follows within moments
                started = time.time()
                while True:
                    status = view.get(glb_path, params={"quality": 0.5, "include_hidden": "false"}).status_code
                    result["after_end_glb_status"] = status
                    result["token_revoked_after_s"] = round(time.time() - started, 2)
                    if status == 401 or time.time() - started > 10:
                        break
                    await asyncio.sleep(0.2)
    except Exception as error:
        result["errors"].append(repr(error))
    write_json(args.out, result)
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
