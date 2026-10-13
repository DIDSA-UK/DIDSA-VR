# Probe of the DIDSA-CAD backend routes that drop-to-add and delete-the-seed would use (docs/assembly-rooms-plan.md, "Drop-to-add and delete").
# Needs a local backend (CAD_API_KEY=testkey uvicorn app.main:app --port 8000) and httpx. Not a test: it prints what the backend answers.
import json, struct, httpx
H = {"X-API-Key": "testkey", "X-Document-Session": "probe"}
B = "http://127.0.0.1:8000/document"
c = httpx.Client(timeout=60)
fx = json.load(open("/home/user/work/didsa-vr/tests/data/rooms_sub_assembly.didsa"))
r = c.post(B + "/import/native", headers=H, json=fx); print("import", r.status_code)
root = fx["document"]["root_part_id"]
S = [p for p in fx["document"]["parts"] if p["id"] != root and p["occurrences"]][0]["id"]
leaf = [o["resolved_part_id"] for p in fx["document"]["parts"] if p["id"] == S for o in p["occurrences"]][0]
def nodes(part):
    g = c.get(f"{B}/parts/{part}/assembly-mesh.glb?quality=0.5", headers=H).content
    n = struct.unpack("<I", g[12:16])[0]
    j = json.loads(g[20:20+n]); return [(x["extras"]["owner_part_id"][:6], x["extras"]["occurrence_id"][:8]) for x in j["nodes"]]
print("S nodes before:", nodes(S))
occ = {"id": "occ_probe1", "resolved_part_id": leaf, "name_override": "Copy", "transform": {"translation": [50.0, 20.0, 0.0], "rotation_axis": [0,0,1], "rotation_angle_degrees": 0.0}}
r = c.post(f"{B}/parts/{S}/occurrences", headers=H, json=occ); print("POST occurrence on S:", r.status_code, {k: r.json().get(k) for k in ("id","resolved_part_id","fixed","hidden")})
print("S nodes after add:", nodes(S))
print("root nodes (world) after add:", nodes(root))
r = c.post(f"{B}/parts/{S}/occurrences", headers=H, json=occ); print("duplicate id:", r.status_code)
r = c.delete(f"{B}/parts/{S}/occurrences/occ_probe1", headers=H); print("DELETE:", r.status_code)
print("S nodes after delete:", nodes(S))
bad = dict(occ, id="occ_cycle", resolved_part_id=S)
r = c.post(f"{B}/parts/{S}/occurrences", headers=H, json=bad); print("add S into S (cycle):", r.status_code, "-> server does not stop it" if r.status_code == 201 else r.text[:120])
r2 = c.get(f"{B}/parts/{S}/assembly-mesh.glb?quality=0.5", headers=H); print("mesh after cycle:", r2.status_code)
c.delete(f"{B}/parts/{S}/occurrences/occ_cycle", headers=H)
unknown = dict(occ, id="occ_unknown", resolved_part_id="no-such-part")
r = c.post(f"{B}/parts/{S}/occurrences", headers=H, json=unknown); print("unknown Part id:", r.status_code, r.json().get("resolved_part_id"))
c.delete(f"{B}/parts/{S}/occurrences/occ_unknown", headers=H)
comp = json.load(open("/home/user/work/didsa-vr/assembly.didsa"))
r = c.post(f"{B}/parts/{S}/add-component", headers=H, json={"component": comp}); print("add-component on a sub-assembly Part:", r.status_code, r.text[:160])
print("S occurrences:", [(o["id"][:8], o["fixed"]) for o in c.get(f"{B}/parts/{S}/occurrences", headers=H).json()])
