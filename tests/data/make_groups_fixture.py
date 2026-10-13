#!/usr/bin/env python3
"""Builds tests/data/groups_two_subs.didsa from tests/data/rooms_sub_assembly.didsa for tests/e2e_groups.gd: the root places the sub-assembly TWICE
(300 mm and 900 mm along x), so the four leaves in the mesh carry identical tags in pairs and only the walk order tells the two sub-assemblies apart.
Usage (from the project root):  python3 tests/data/make_groups_fixture.py
"""
import copy
import json

SECOND_OCCURRENCE_ID = "8b2c3d4e-5f60-4b7c-9d8e-0f1a2b3c4d5e"

with open("tests/data/rooms_sub_assembly.didsa", encoding="utf-8") as f:
    source = json.load(f)
doc = source["document"]
root = next(p for p in doc["parts"] if p["id"] == doc["root_part_id"])
second = copy.deepcopy(root["occurrences"][0])
second["id"] = SECOND_OCCURRENCE_ID
second["name_override"] = "Sub 2"
second["transform"]["translation"] = [900.0, 0.0, 0.0]
root["occurrences"].append(second)
with open("tests/data/groups_two_subs.didsa", "w", encoding="utf-8") as f:
    json.dump(source, f, indent=1)
print("wrote tests/data/groups_two_subs.didsa")
