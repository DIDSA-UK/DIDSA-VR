"""Builds demo/assemblies/gear_train/Gear_train.didsa (the gear train demo, gears-and-motion plan M8) against a RUNNING DIDSA-CAD backend.

The document: a plate (fixed) carrying a 20-tooth pinion and a 40-tooth gear (module 2, bore 8, 60 mm apart, each concentric to a hole of the plate and
flat on it), a 10-tooth rack that can only slide along x (flat on the plate, back on a fixed guide block) under the pinion, and a crank handle (a bar with a
hole) over the pinion. Mates: gear (pinion to gear, Auto ratio 1 : 2), rack and pinion (Auto travel per turn), a travel limit on the rack (it slides 46 mm, so it stays on the plate and under the pinion), and a 1 : 1 gear mate (the sense reversed from
the default) that makes the crank turn with the pinion the same way round. Turn the crank (or use the Drive tool on it): the gear turns the other way at half the speed and the rack slides.
Done in Python (not in Godot) for the same reason as make_gear_fixture.py. Usage (from the project root, after tools/start_backend.sh):
    python3 tests/data/make_gear_train_demo.py
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




def edge_along(part, direction, min_length=20.0, limit=400):
    """A straight edge of `part` parallel to `direction` and at least `min_length` long."""
    for index in range(limit):
        try:
            m = call("POST", f"/document/parts/{part['id']}/measure", {"refs": [{"body_id": part["body_id"], "shape_type": "edge", "index": index}]})
        except Exception:
            break
        axis = m.get("axis")
        if axis is not None and m.get("length") and m["length"] >= min_length and all(abs(abs(a) - abs(b)) < 1e-6 for a, b in zip(axis["direction"], direction)):
            return index
    raise SystemExit(f"no straight edge along {direction} on {part['id']}")


def bevel_part(name, teeth):
    """A straight bevel gear (module 3, 45 degrees: a 90 degree pair with an equal partner), apex at the part's origin, widening along +z, bore 8."""
    part = make_part(name)
    call("POST", f"/document/parts/{part['id']}/bevel-gear-features",
         {"bevel_type": "boss", "module": 3.0, "tooth_count": teeth, "face_width": 12.0, "pitch_cone_angle_degrees": 45.0, "bore_diameter": 8.0})
    return {"id": part["id"], "body_id": call("GET", f"/document/parts/{part['id']}/mesh")[0]["body_id"]}


def rack_part(name, teeth):
    part = make_part(name)
    call("POST", f"/document/parts/{part['id']}/rack-features", {"rack_type": "boss", "module": 2.0, "tooth_count": teeth, "face_width": 10.0})
    return {"id": part["id"], "body_id": call("GET", f"/document/parts/{part['id']}/mesh")[0]["body_id"]}


def edge_ref(occ, part, index):
    return {"occurrence_id": occ, "subshape_ref": {"body_id": part["body_id"], "shape_type": "edge", "index": index}}


call("POST", "/document/new")
PINION_XY, GEAR_XY = (50.0, 55.0), (110.0, 55.0)
plate = box_part("Plate", 170.0, 100.0, 10.0, holes=[(PINION_XY[0], PINION_XY[1], 6.0), (GEAR_XY[0], GEAR_XY[1], 6.0)])
pinion = gear_part("Pinion (20 teeth)", 20)
gear = gear_part("Gear (40 teeth)", 40)
rack = rack_part("Rack (10 teeth)", 10)
guide = box_part("Rack guide", 65.0, 10.0, 10.0)
crank = box_part("Crank handle", 32.0, 8.0, 6.0, holes=[(24.0, 4.0, 4.0)])
bevel_a = bevel_part("Bevel gear A (20 teeth)", 20)
bevel_b = bevel_part("Bevel gear B (20 teeth)", 20)
bearing = box_part("Bearing block", 36.0, 36.0, 14.0, holes=[(18.0, 18.0, 4.0)])
root = make_part("Gear train")

IDENTITY = [0.0, 0.0, 1.0]
DISPLAY_NAMES = {"plate": "Plate", "pinion": "Pinion (20 teeth)", "gear": "Gear (40 teeth)", "guide": "Rack guide", "rack": "Rack", "crank": "Crank handle",
                 "bevel_a": "Bevel gear A", "bevel_b": "Bevel gear B", "bearing": "Bearing block"} # the assembly tree and the VR readout show these (without a name they read "Component 3")
rack_y = PINION_XY[1] - 20.0 # the rack's pitch line (its local y = 0) touches the pinion's pitch circle
placements = [
    ("plate", plate, (0.0, 0.0, 0.0), True),
    ("pinion", pinion, (PINION_XY[0], PINION_XY[1], 10.0), False),
    ("gear", gear, (GEAR_XY[0], GEAR_XY[1], 10.0), False),
    ("guide", guide, (10.0, rack_y - 6.5 - 10.0, 10.0), True),
    ("rack", rack, (42.0, rack_y, 10.0), False),
    ("crank", crank, (PINION_XY[0] - 24.0, PINION_XY[1] - 4.0, 20.0), False),
]
# A 90 degree bevel pair on the gear's shaft: bevel A sits on top of the 40-tooth gear, large end down (turned over about x), its cone narrowing upwards to an apex
# 31.7515 mm above the gear's top face (the large end plane's distance from the apex, as the solver places it: the mesh's highest vertex, 31.8398, is not on the plane); bevel B's axis is horizontal (along world x) through the SAME apex, its large end facing +x, and a bearing block (fixed,
# rotated so its hole runs along x) holds it. A turns with the gear (a 1 : 1 gear mate, like the crank), B turns with A (Auto ratio 1 : 1) about a crossed axis.
BEVEL_END = 31.7515339340878
APEX = (GEAR_XY[0], GEAR_XY[1], 20.0 + BEVEL_END)
BLOCK_X = APEX[0] + BEVEL_END # B's large end plane
placements += [
    ("bevel_a", bevel_a, APEX, False, ((1.0, 0.0, 0.0), 180.0)),
    ("bevel_b", bevel_b, APEX, False, ((0.0, 1.0, 0.0), 90.0)),
    ("bearing", bearing, (BLOCK_X, APEX[1] - 18.0, APEX[2] + 18.0), True, ((0.0, 1.0, 0.0), 90.0)),
]
for entry in placements:
    occ_id, part, t, fixed = entry[:4]
    axis, degrees = entry[4] if len(entry) > 4 else (IDENTITY, 0.0)
    call("POST", f"/document/parts/{root['id']}/occurrences", {
        "id": occ_id, "external_ref": f"parts/{part['id']}.didsa", "resolved_part_id": part["id"], "name_override": DISPLAY_NAMES[occ_id],
        "transform": {"translation": list(t), "rotation_axis": list(axis), "rotation_angle_degrees": degrees}, "fixed": fixed})


def ref(occ, part, index):
    return {"occurrence_id": occ, **sub(part, index)}


def mate(kind, a, b, **extra):
    return call("POST", f"/document/parts/{root['id']}/mates", {"type": kind, "references": [a, b], **extra})


top = planar_face(plate, (0.0, 0.0, 1.0))
for occ_id, g, hole_xy in (("pinion", pinion, PINION_XY), ("gear", gear, GEAR_XY)):
    mate("concentric", ref(occ_id, g, cylinder_face(g)), ref("plate", plate, cylinder_face(plate, hole_xy)))
    mate("coincident", ref(occ_id, g, planar_face(g, (0.0, 0.0, -1.0))), ref("plate", plate, top))
mate("coincident", ref("rack", rack, planar_face(rack, (0.0, 0.0, -1.0))), ref("plate", plate, top))
mate("coincident", ref("rack", rack, planar_face(rack, (0.0, -1.0, 0.0))), ref("guide", guide, planar_face(guide, (0.0, 1.0, 0.0))))
mate("concentric", ref("crank", crank, cylinder_face(crank)), ref("pinion", pinion, cylinder_face(pinion)))
mate("coincident", ref("crank", crank, planar_face(crank, (0.0, 0.0, -1.0))), ref("pinion", pinion, planar_face(pinion, (0.0, 0.0, 1.0))))

# the couplers (value left out: Auto from the teeth; the crank turns with the pinion: 1 : 1, same sense)
mate("gear", ref("pinion", pinion, cylinder_face(pinion)), ref("gear", gear, cylinder_face(gear)))
mate("rack_pinion", ref("pinion", pinion, cylinder_face(pinion)), edge_ref("rack", rack, edge_along(rack, (1.0, 0.0, 0.0))))
# (the backend's default sense for two gears is the OPPOSITE way round in the world, as meshing gears turn; a crank fixed to the pinion turns the SAME way, so take the other one)
crank_mate = mate("gear", ref("crank", crank, cylinder_face(crank)), ref("pinion", pinion, cylinder_face(pinion)), value=1.0)
call("PATCH", f"/document/parts/{root['id']}/mates/{crank_mate['id']}", {"secondary_flip": not crank_mate["secondary_flip"]})

# the bevel pair: A on the gear's shaft (concentric to its bore, large end on the gear's top face), turning with the gear; B in the bearing block (concentric to
# its hole, large end on the block's face), turning with A at 1 : 1 about the crossed axis (the backend's default sense for a crossed pair is k = -1)
mate("concentric", ref("bevel_a", bevel_a, cylinder_face(bevel_a)), ref("gear", gear, cylinder_face(gear)))
mate("coincident", ref("bevel_a", bevel_a, planar_face(bevel_a, (0.0, 0.0, 1.0))), ref("gear", gear, planar_face(gear, (0.0, 0.0, 1.0))), alignment="anti_aligned")
mate("concentric", ref("bevel_b", bevel_b, cylinder_face(bevel_b)), ref("bearing", bearing, cylinder_face(bearing, (18.0, 18.0))))
mate("coincident", ref("bevel_b", bevel_b, planar_face(bevel_b, (0.0, 0.0, 1.0))), ref("bearing", bearing, planar_face(bearing, (0.0, 0.0, -1.0))), alignment="anti_aligned")
rigid = mate("gear", ref("gear", gear, cylinder_face(gear)), ref("bevel_a", bevel_a, cylinder_face(bevel_a)), value=1.0)
call("PATCH", f"/document/parts/{root['id']}/mates/{rigid['id']}", {"secondary_flip": not rigid["secondary_flip"]}) # the same shaft: A turns the way the gear does
mate("gear", ref("bevel_a", bevel_a, cylinder_face(bevel_a)), ref("bevel_b", bevel_b, cylinder_face(bevel_b))) # Auto: 20 teeth to 20 teeth

# the rack's travel (limit mates, M9): its +x end against the plate's +x edge, the signed gap from the plate edge, limited to where the pinion still meets the
# rack - it slides 40 mm towards the plate's left edge and 6 mm back to the right of where it starts (the rack starts near the right end of its travel). Made with
# a wide range first to read where it sits now, then narrowed around that.
rack_end = mate("limit_distance", ref("rack", rack, planar_face(rack, (1.0, 0.0, 0.0))), ref("plate", plate, planar_face(plate, (1.0, 0.0, 0.0))), limit_min=-1000.0, limit_max=1000.0)
now = rack_end["limit_value"]
call("PATCH", f"/document/parts/{root['id']}/mates/{rack_end['id']}", {"limit_min": round(now - 40.0, 3), "limit_max": round(now + 6.0, 3)})

document = call("GET", "/document/export/native")
document["document"]["root_part_id"] = root["id"]
document["document"]["parts"].sort(key=lambda part: part["id"] != root["id"])  # the flat app opens a multi-part file on its FIRST part: the root assembly goes first
import os
os.makedirs("demo/assemblies/gear_train", exist_ok=True)
with open("demo/assemblies/gear_train/Gear_train.didsa", "w", encoding="utf-8") as f:
    json.dump(document, f, indent=1)
print("wrote demo/assemblies/gear_train/Gear_train.didsa: root", root["id"])
