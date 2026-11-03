#!/usr/bin/env python3
"""Builds tests/data/pattern_follow.didsa for tests/e2e_pattern_follow.gd with DIDSA-CAD's own test helpers (needs the CAD checkout next to this repo and its
conda environment): a root Part placing two boxes, A (id "src", at the origin) and B (id "mover"); a Linear pattern of A (3 copies, 300 mm apart along x); and a
coincident mate between B's -z face and the top (+z) face of A's first copy, solved, so the file is stored satisfied.
Usage (from the project root):  /opt/tools/cad-env/bin/python tests/data/make_pattern_follow_fixture.py
"""
import json
import os
import sys

CAD = os.environ.get("CAD_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "DIDSA-CAD"))
sys.path.insert(0, os.path.join(CAD, "backend"))

from tests import conftest  # noqa: E402,F401  (sets CAD_API_KEY before app.main is imported)
from tests.test_mate_pattern_copy import _payload, _scene, client  # noqa: E402

scene = _scene()
top_id = scene["top"]["id"]
payload = _payload(scene, "src#pattern:%s:1" % scene["pid"])
assert client.post(f"/document/parts/{top_id}/mates", json=payload).status_code == 201
assert client.post(f"/document/parts/{top_id}/occurrences/mover/solve", json={}).status_code == 200
exported = client.get("/document/export/native").json()
with open("tests/data/pattern_follow.didsa", "w", encoding="utf-8") as f:
    json.dump(exported, f, indent=1)
print("wrote tests/data/pattern_follow.didsa; root part", top_id)
