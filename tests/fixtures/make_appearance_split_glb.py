"""Writes tests/fixtures/appearance_split.glb for DIDSA-VR: DIDSA-CAD's real assembly-mesh.glb of one Part with two box
bodies (10 mm at x 0..10, 10 mm at x 30..40), the second body painted #E63946 with opacity 0.5 (a Part body appearance), so the
mesh comes as two indexed primitives. Run from DIDSA-CAD/backend with the backend environment."""
import sys
sys.path.insert(0, ".")
import os
os.environ.setdefault("CAD_API_KEY", "gen")
from fastapi.testclient import TestClient
from app.main import app

c = TestClient(app)
c.headers.update({"X-API-Key": os.environ["CAD_API_KEY"]})
part = c.post("/document/parts", json={"name": "Split"}).json()
pid = part["id"]

def square(x0, size):
    sk = c.post(f"/document/parts/{pid}/features/sketch", json={"plane": "XY"}).json()
    pts = [c.post(f"/sketch/sketches/{sk['sketch_id']}/points", json={"x": x, "y": y}).json()["id"] for x, y in [(x0, 0), (x0 + size, 0), (x0 + size, size), (x0, size)]]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        c.post(f"/sketch/sketches/{sk['sketch_id']}/lines", json={"start_point_id": a, "end_point_id": b})
    r = c.post(f"/document/parts/{pid}/extrude-features", json={"sketch_feature_id": sk["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []})
    assert r.status_code == 201, r.text

square(0.0, 10.0)
square(30.0, 10.0)
bodies = [b["body_id"] for b in c.get(f"/document/parts/{pid}/mesh").json()]
assert len(bodies) == 2, bodies
r = c.patch(f"/document/parts/{pid}", json={"body_appearances": {bodies[1]: {"colour": "#E63946", "opacity": 0.5}}})
assert r.status_code == 200, r.text
glb = c.get(f"/document/parts/{pid}/assembly-mesh.glb").content
open(sys.argv[1], "wb").write(glb)
print("bodies", bodies, "bytes", len(glb))
