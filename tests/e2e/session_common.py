"""Shared helpers for the live-session stand-ins (session_observer_stub.py, session_presenter_stub.py): the end-to-end tests run these as the OTHER end of a session while the
headset app is the one under test. Needs httpx and websockets (the DIDSA-CAD backend / session-hub environment has both). The assembly builder is DIDSA-CAD's own
session-hub/tools/scripted_session.py's, copied (it is a tool of that repo, not a library)."""

import asyncio
import json
import os
import struct
import time
from pathlib import Path

import httpx


async def until(ws, kind: str, timeout: float = 15.0) -> dict:
    """The next JSON message of one type from the hub (others are skipped)."""
    deadline = time.time() + timeout
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=max(0.1, deadline - time.time()))
        if isinstance(raw, bytes):
            continue
        message = json.loads(raw)
        if message["t"] == kind:
            return message


async def wait_for_file(path: str, timeout: float = 60.0) -> bool:
    """The test (Godot) creates a file to say 'go on to the next step'."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if Path(path).exists():
            return True
        await asyncio.sleep(0.1)
    return False


def glb_instance_paths(data: bytes) -> list[str]:
    """The `extras.instance_path` of every node of an assembly-mesh.glb, in order (what a pose is keyed by)."""
    length = struct.unpack("<I", data[12:16])[0]
    document = json.loads(data[20 : 20 + length])
    return [str(node.get("extras", {}).get("instance_path", "")) for node in document.get("nodes", [])]


def box(cad: httpx.Client, name: str, size: float) -> dict:
    part = cad.post("/document/parts", json={"name": name}).json()
    sketch = cad.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    pts = [cad.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}).json() for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        cad.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]})
    cad.post(f"/document/parts/{part['id']}/extrude-features", json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []})
    return part


def build_assembly(cad: httpx.Client) -> tuple[str, str]:
    """A 20 mm block with a 2 mm bolt placed on it (occurrence id occ-bolt). Returns (root part id, bolt occurrence id)."""
    root, child = box(cad, "Mount", 20.0), box(cad, "Bolt", 2.0)
    root_export = cad.get("/document/export/native", params={"part_id": root["id"]}).json()
    child_export = cad.get("/document/export/native", params={"part_id": child["id"]}).json()
    root_dict = root_export["document"]["parts"][0]
    root_dict["occurrences"] = [{"id": "occ-bolt", "external_ref": "parts/bolt.didsa", "resolved_part_id": child["id"], "name_override": None,
                                 "transform": {"translation": [15.0, 0.0, 10.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0},
                                 "suppressed": False, "hidden": False, "color": None}]
    root_dict["mates"] = []
    payload = {"schema_version": root_export["schema_version"],
               "document": {"id": "e2e-session", "root_part_id": root["id"], "parts": [root_dict, child_export["document"]["parts"][0]]},
               "sketches": [*root_export["sketches"], *child_export["sketches"]]}
    assert cad.post("/document/import/native", json=payload).status_code == 200
    return root["id"], "occ-bolt"


def write_json(path: str, data: dict) -> None:
    Path(path).write_text(json.dumps(data, indent=1, default=str))


def cad_client(url: str, key: str, session: str | None = None) -> httpx.Client:
    return httpx.Client(base_url=url, headers={"X-API-Key": key, "X-Document-Session": session or f"e2e-{os.getpid()}-{int(time.time())}"}, timeout=60)
