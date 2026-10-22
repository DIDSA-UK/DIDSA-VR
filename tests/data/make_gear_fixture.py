#!/usr/bin/env python3
"""Builds tests/data/gear_pair.didsa for tests/e2e_gear_mates.gd (and e2e_drive.gd) against a RUNNING DIDSA-CAD backend.

The document: a plate (fixed) with two holes 60 mm apart (centre distance m (z_A + z_B) / 2 = 2 (20 + 40) / 2 = 60 mm); gear A (module 2, 20 teeth,
bore 8) and gear B (module 2, 40 teeth, bore 8), each in its own part, each concentric to its hole and coincident (face to face) with the plate's top.
There is NO gear mate: the tests make it. Plus a rack part (module 2, 10 teeth) and a pinion... see ROOT below; the rack and screw cases use simple blocks
in the same file: a guide block (fixed) and a rack block on the plate for rack and pinion, and a screw / nut pair for the lead.
Done in Python (not in Godot) because Godot's JSON writer turns integers into floats, which the backend rejects for some fields.
Usage (from the project root, after tools/start_backend.sh):  python3 tests/data/make_gear_fixture.py
"""
import configparser
import json
import re
import urllib.request

cfg = open("secrets.cfg", encoding="utf-8").read()
URL = re.search(r'url\s*=\s*"([^"]+)"', cfg).group(1)
KEY = re.search(r'api_key\s*=\s*"([^"]+)"', cfg).group(1)
SESSION = "gear-fixture"


def call(method, path, body=None):
    request = urllib.request.Request(
        URL + path, method=method, data=None if body is None else json.dumps(body).encode(),
        headers={"X-API-Key": KEY, "X-Document-Session": SESSION, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def make_part(name):
    return call("POST", "/document/parts", {"name": name})


def sketch_on_xy(part_id):
    feature = call("POST", f"/document/parts/{part_id}/features/sketch", {"plane": "XY"})
    return feature["id"], feature["sketch_id"]


def point(sketch_id, x, y):
    return call("POST", f"/sketch/sketches/{sketch_id}/points", {"x": x, "y": y})["id"]


def box_part(name, width, depth, height, holes=()):
    """A width x depth x height block (corner at the origin) with round through holes [(x, y, radius)]."""
    part = make_part(name)
    feature_id, sketch_id = sketch_on_xy(part["id"])
    corners = [point(sketch_id, x, y) for x, y in [(0, 0), (width, 0), (width, depth), (0, depth)]]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        call("POST", f"/sketch/sketches/{sketch_id}/lines", {"start_point_id": a, "end_point_id": b})
    call("POST", f"/document/parts/{part['id']}/extrude-features",
         {"sketch_feature_id": feature_id, "extrude_type": "boss", "start_distance": 0.0, "end_distance": height, "target_body_ids": []})
    body_id = call("GET", f"/document/parts/{part['id']}/mesh")[0]["body_id"]
    if holes:
        feature_id, sketch_id = sketch_on_xy(part["id"])
        for x, y, r in holes:
            call("POST", f"/sketch/sketches/{sketch_id}/circles", {"center_point_id": point(sketch_id, x, y), "radius": r, "angle": 0.0})
        call("POST", f"/document/parts/{part['id']}/extrude-features",
             {"sketch_feature_id": feature_id, "extrude_type": "cut", "start_distance": 0.0, "end_distance": height, "target_body_ids": [body_id]})
    return {"id": part["id"], "body_id": call("GET", f"/document/parts/{part['id']}/mesh")[0]["body_id"]}


def cylinder_part(name, radius, height):
    part = make_part(name)
    feature_id, sketch_id = sketch_on_xy(part["id"])
    call("POST", f"/sketch/sketches/{sketch_id}/circles", {"center_point_id": point(sketch_id, 0.0, 0.0), "radius": radius, "angle": 0.0})
    call("POST", f"/document/parts/{part['id']}/extrude-features",
         {"sketch_feature_id": feature_id, "extrude_type": "boss", "start_distance": 0.0, "end_distance": height, "target_body_ids": []})
    return {"id": part["id"], "body_id": call("GET", f"/document/parts/{part['id']}/mesh")[0]["body_id"]}


def gear_part(name, teeth):
    part = make_part(name)
    call("POST", f"/document/parts/{part['id']}/gear-features",
         {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": teeth, "face_width": 10.0, "bore_diameter": 8.0})
    return {"id": part["id"], "body_id": call("GET", f"/document/parts/{part['id']}/mesh")[0]["body_id"]}


def measure_face(part, index):
    return call("POST", f"/document/parts/{part['id']}/measure", {"refs": [{"body_id": part["body_id"], "shape_type": "face", "index": index}]})


def faces(part, limit=800):
    for index in range(limit):
        try:
            yield index, measure_face(part, index)
        except Exception:
            return


def planar_face(part, normal):
    for index, m in faces(part):
        n = m.get("normal")
        if n is not None and all(abs(a - b) < 1e-6 for a, b in zip(n, normal)):
            return index
    raise SystemExit(f"no planar face with normal {normal} on {part['id']}")


def cylinder_face(part, near_xy=None):
    """A cylindrical face (gear: the bore); with `near_xy` the one whose axis passes there (a plate's hole)."""
    for index, m in faces(part):
        axis = m.get("axis")
        if axis is not None and m.get("radius") is not None:
            if near_xy is None or (abs(axis["origin"][0] - near_xy[0]) < 1e-3 and abs(axis["origin"][1] - near_xy[1]) < 1e-3):
                return index
    raise SystemExit(f"no cylindrical face on {part['id']} near {near_xy}")


def sub(part, index):
    return {"subshape_ref": {"body_id": part["body_id"], "shape_type": "face", "index": index}}


call("POST", "/document/new")
plate = box_part("Plate", 100.0, 60.0, 10.0, holes=[(20.0, 30.0, 6.0), (80.0, 30.0, 6.0)])
gear_a = gear_part("Gear A (20 teeth)", 20)
gear_b = gear_part("Gear B (40 teeth)", 40)
root = make_part("Gear pair")

IDENTITY = [0.0, 0.0, 1.0]
placements = [("plate", plate, (0.0, 0.0, 0.0), True), ("gear-a", gear_a, (20.0, 30.0, 10.0), False), ("gear-b", gear_b, (80.0, 30.0, 10.0), False)]
for occ_id, part, t, fixed in placements:
    call("POST", f"/document/parts/{root['id']}/occurrences", {
        "id": occ_id, "external_ref": f"parts/{part['id']}.didsa", "resolved_part_id": part["id"], "name_override": None,
        "transform": {"translation": list(t), "rotation_axis": IDENTITY, "rotation_angle_degrees": 0.0}, "fixed": fixed})

top = planar_face(plate, (0.0, 0.0, 1.0))
for occ_id, gear, hole_xy in (("gear-a", gear_a, (20.0, 30.0)), ("gear-b", gear_b, (80.0, 30.0))):
    ref = lambda occ, part, index: {"occurrence_id": occ, **sub(part, index)}
    call("POST", f"/document/parts/{root['id']}/mates", {"type": "concentric", "references": [ref(occ_id, gear, cylinder_face(gear)), ref("plate", plate, cylinder_face(plate, hole_xy))]})
    call("POST", f"/document/parts/{root['id']}/mates", {"type": "coincident", "references": [ref(occ_id, gear, planar_face(gear, (0.0, 0.0, -1.0))), ref("plate", plate, top)]})

document = call("GET", "/document/export/native")
document["document"]["root_part_id"] = root["id"]
with open("tests/data/gear_pair.didsa", "w", encoding="utf-8") as f:
    json.dump(document, f, indent=1)
print("wrote tests/data/gear_pair.didsa: root", root["id"], "plate fixed, gear A (20 teeth) and gear B (40 teeth) on their holes 60 mm apart, no gear mate")
