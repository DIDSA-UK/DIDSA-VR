"""Writes tests/fixtures/session_assembly.glb: a tiny glb shaped like DIDSA-CAD's assembly-mesh.glb (flat nodes, one per placed instance, each with
`extras` {owner_part_id, occurrence_id, instance_path, name}), for the live-session tests. Three 10 mm cubes in millimetres (the backend's units): the root's own
content (instance_path "") and two placed instances. Stdlib only: python3 tests/fixtures/make_session_assembly_glb.py (re-run to regenerate)."""
import json
import struct
import sys
from pathlib import Path

CORNERS = [(-5, -5, -5), (5, -5, -5), (5, 5, -5), (-5, 5, -5), (-5, -5, 5), (5, -5, 5), (5, 5, 5), (-5, 5, 5)]
INDICES = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 3, 0, 4, 3, 4, 7]


def build() -> bytes:
    positions = b"".join(struct.pack("<3f", *c) for c in CORNERS)
    indices = b"".join(struct.pack("<H", i) for i in INDICES) + b"\0\0"  # padded to 4 bytes
    blob = positions + indices
    nodes = [
        {"name": "Mount", "mesh": 0, "translation": [0, 0, 0], "extras": {"owner_part_id": "part-root", "occurrence_id": "", "instance_path": "", "name": "Mount"}},
        {"name": "Bolt", "mesh": 0, "translation": [30, 0, 0], "extras": {"owner_part_id": "part-bolt", "occurrence_id": "occ-bolt", "instance_path": "occ-bolt", "name": "Bolt"}},
        {"name": "Nut", "mesh": 0, "translation": [0, 30, 0], "extras": {"owner_part_id": "part-nut", "occurrence_id": "occ-nut", "instance_path": "occ-nut", "name": "Nut"}},
    ]
    document = {
        "asset": {"version": "2.0", "generator": "make_session_assembly_glb.py"},
        "scene": 0, "scenes": [{"nodes": [0, 1, 2]}], "nodes": nodes,
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "material": 0}]}],
        "materials": [{"pbrMetallicRoughness": {"baseColorFactor": [0.7, 0.7, 0.8, 1.0], "metallicFactor": 0.1, "roughnessFactor": 0.6}}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(positions), "target": 34962}, {"buffer": 0, "byteOffset": len(positions), "byteLength": len(INDICES) * 2, "target": 34963}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3", "min": [-5, -5, -5], "max": [5, 5, 5]},
            {"bufferView": 1, "componentType": 5123, "count": len(INDICES), "type": "SCALAR"},
        ],
    }
    text = json.dumps(document, separators=(",", ":")).encode()
    text += b" " * (-len(text) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    return b"glTF" + struct.pack("<II", 2, total) + struct.pack("<I4s", len(text), b"JSON") + text + struct.pack("<I4s", len(blob), b"BIN\0") + blob


if __name__ == "__main__":
    out = Path(__file__).with_name("session_assembly.glb")
    out.write_bytes(build())
    print(f"wrote {out} ({out.stat().st_size} bytes)")
    sys.exit(0)
