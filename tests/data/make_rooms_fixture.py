#!/usr/bin/env python3
"""Builds tests/data/rooms_sub_assembly.didsa from the repo's assembly.didsa for tests/e2e_rooms.gd.

assembly.didsa's own root (two leaf parts) becomes the SUB-ASSEMBLY "S"; a new root part holds one placed occurrence of it, 300 mm along x. That is the
smallest document with a sub-assembly, which is what an Assembly Room opens. Done in Python (not in the test) because Godot's JSON writer turns integers into
floats (`0` -> `0.0`), which the backend rejects for fields such as `rotation_quarter_turns`.
Usage (from the project root):  python3 tests/data/make_rooms_fixture.py
"""
import copy
import json

ROOT_ID = "5f0c7a52-3b4e-4d63-9a3c-0d1e2f3a4b5c"
SUB_OCCURRENCE_ID = "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

with open("assembly.didsa", encoding="utf-8") as f:
    source = json.load(f)
doc = source["document"]
sub_id = doc["root_part_id"]
sub_part = next(p for p in doc["parts"] if p["id"] == sub_id)
root = copy.deepcopy(sub_part)
root.update({"id": ROOT_ID, "name": "Rooms test root", "features": [], "mates": [], "component_patterns": []})
root["occurrences"] = [{
    "id": SUB_OCCURRENCE_ID, "external_ref": None, "resolved_part_id": sub_id, "name_override": "Sub",
    "transform": {"translation": [300.0, 0.0, 0.0], "rotation_axis": [0.0, 0.0, 1.0], "rotation_angle_degrees": 0.0},
    "suppressed": False, "hidden": False, "fixed": False, "color": None,
}]
doc["parts"].append(root)
doc["root_part_id"] = ROOT_ID
with open("tests/data/rooms_sub_assembly.didsa", "w", encoding="utf-8") as f:
    json.dump(source, f, indent=1)
print("wrote tests/data/rooms_sub_assembly.didsa (sub-assembly", sub_id, "under root", ROOT_ID + ")")
