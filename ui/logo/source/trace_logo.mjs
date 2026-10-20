// Traces the DIDSA logo masks to SVG (potrace), then extrudes the paths into a glb.
// Usage: node trace_logo.mjs <masks dir> <out.svg> <out.glb>
import fs from 'fs';
import path from 'path';
import potrace from 'potrace';
import parseSvgPath from 'svg-path-parser';
import earcut from 'earcut';
import { Document, NodeIO } from '@gltf-transform/core';

const [,, maskDir, outSvg, outGlb] = process.argv;
const meta = JSON.parse(fs.readFileSync(path.join(maskDir, 'meta.json')));
const U = meta.scale;
const parts = [
  { name: 'Emblem', file: 'emblem', colour: 'ink', depth: 0.022 },
  { name: 'Porthole', file: 'porthole', colour: 'accent', depth: 0.034 },
  { name: 'Wordmark', file: 'wordmark', colour: 'ink', depth: 0.03 },
  { name: 'Tagline', file: 'tagline', colour: 'ink', depth: 0.012 },
];
const COLOURS = { ink: '#111111', accent: '#2E9FD6' };
const trace = (file) => new Promise((res, rej) => {
  const t = new potrace.Potrace({ threshold: 128, turdSize: 40, optTolerance: 0.25, alphaMax: 1.0 });
  t.loadImage(file, (err) => (err ? rej(err) : res(t.getPathTag().match(/ d="([^"]+)"/)[1])));
});

// Flatten an SVG path (absolute M/L/C/Z, as potrace writes) into closed rings, in source-image pixels.
function rings(d, ox, oy) {
  const out = []; let ring = null; let cur = [0, 0];
  const P = (x, y) => [(x + ox) / U, (y + oy) / U];
  for (const c of parseSvgPath(d)) {
    if (c.code === 'M') { if (ring && ring.length > 2) out.push(ring); ring = [P(c.x, c.y)]; cur = [c.x, c.y]; }
    else if (c.code === 'L') { ring.push(P(c.x, c.y)); cur = [c.x, c.y]; }
    else if (c.code === 'C') {
      // Points along the curve: about one per 2 source pixels of chord, at least 2.
      const chord = Math.hypot(c.x - cur[0], c.y - cur[1]) / U;
      const n = Math.max(2, Math.min(12, Math.ceil(chord / 2)));
      for (let i = 1; i <= n; i++) {
        const t = i / n, u = 1 - t;
        const x = u*u*u*cur[0] + 3*u*u*t*c.x1 + 3*u*t*t*c.x2 + t*t*t*c.x;
        const y = u*u*u*cur[1] + 3*u*u*t*c.y1 + 3*u*t*t*c.y2 + t*t*t*c.y;
        ring.push(P(x, y));
      }
      cur = [c.x, c.y];
    } else if (c.code === 'Z') { if (ring && ring.length > 2) out.push(ring); ring = null; }
    else throw new Error('unexpected path command ' + c.code);
  }
  if (ring && ring.length > 2) out.push(ring);
  return out.map((r) => { const a = r[0], b = r[r.length - 1]; return Math.hypot(a[0]-b[0], a[1]-b[1]) < 1e-6 ? r.slice(0, -1) : r; });
}
const area = (r) => r.reduce((s, p, i) => { const q = r[(i + 1) % r.length]; return s + p[0]*q[1] - q[0]*p[1]; }, 0) / 2;
function inside(pt, r) {
  let c = false;
  for (let i = 0, j = r.length - 1; i < r.length; j = i++) {
    if ((r[i][1] > pt[1]) !== (r[j][1] > pt[1]) && pt[0] < (r[j][0]-r[i][0]) * (pt[1]-r[i][1]) / (r[j][1]-r[i][1]) + r[i][0]) c = !c;
  }
  return c;
}
// Even-odd nesting: depth 0 = outer, 1 = hole, 2 = island inside a hole (a new outer), ...
function shapes(all) {
  const depth = all.map((r, i) => all.filter((o, j) => j !== i && Math.abs(area(o)) > Math.abs(area(r)) && inside(r[0], o)).length);
  const outers = all.map((r, i) => ({ r, i })).filter(({ i }) => depth[i] % 2 === 0);
  return outers.map(({ r, i }) => ({
    outer: r,
    holes: all.filter((h, j) => depth[j] === depth[i] + 1 && inside(h[0], r) &&
      !outers.some((o) => o.i !== i && depth[o.i] === depth[i] + 0 && false)),
  })).map((s) => ({ ...s, holes: s.holes.filter((h) => !outers.some((o) => o.r !== s.outer && Math.abs(area(o.r)) < Math.abs(area(s.outer)) && inside(h[0], o.r) && inside(o.r[0], s.outer))) }));
}

const svgPaths = []; const built = [];
for (const part of parts) {
  const [ox, oy] = meta.regions[part.file];
  const d = await trace(path.join(maskDir, part.file + '.png'));
  const rs = rings(d, ox, oy);
  svgPaths.push({ part, rs });
  built.push({ part, shapes: shapes(rs), count: rs.length });
}

// SVG at the source image's own pixel size, cropped to the logo.
const allPts = svgPaths.flatMap(({ rs }) => rs.flat());
const minX = Math.min(...allPts.map((p) => p[0])), maxX = Math.max(...allPts.map((p) => p[0]));
const minY = Math.min(...allPts.map((p) => p[1])), maxY = Math.max(...allPts.map((p) => p[1]));
const pad = 8, W = maxX - minX + 2*pad, H = maxY - minY + 2*pad;
const f = (v) => v.toFixed(2);
const svg = [`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${f(W)} ${f(H)}" width="${f(W)}" height="${f(H)}">`,
  `  <title>DIDSA - Didsbury Space Agency</title>`,
  ...svgPaths.map(({ part, rs }) => `  <path id="${part.name.toLowerCase()}" fill="${COLOURS[part.colour]}" fill-rule="evenodd" d="${rs.map((r) => 'M' + r.map((p) => f(p[0]-minX+pad) + ' ' + f(p[1]-minY+pad)).join(' L') + ' Z').join(' ')}"/>`),
  '</svg>', ''].join('\n');
fs.writeFileSync(outSvg, svg);

// glb: 1.2 m wide, centred, Y up, facing +Z. One node per part so the landing can animate them.
const S = 1.2 / (maxX - minX), cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
const doc = new Document(); const buffer = doc.createBuffer();
const mats = {
  ink: doc.createMaterial('Ink').setBaseColorFactor([0.93, 0.95, 0.98, 1]).setMetallicFactor(0.2).setRoughnessFactor(0.4),
  accent: doc.createMaterial('Accent').setBaseColorFactor([0.18, 0.62, 0.84, 1]).setEmissiveFactor([0.18, 0.62, 0.84]).setRoughnessFactor(0.3),
};
const scene = doc.createScene('DIDSA logo'); const root = doc.createNode('DidsaLogo'); scene.addChild(root);
let triTotal = 0;
for (const { part, shapes: sh, count } of built) {
  const pos = [], nor = [], idx = [];
  const V = (x, y, z, n) => { pos.push((x - cx) * S, -(y - cy) * S, z); nor.push(...n); return pos.length / 3 - 1; };
  const z0 = part.depth / 2;
  for (const { outer, holes } of sh) {
    const ringsHere = [outer, ...holes];
    const flat = []; const holeIdx = [];
    for (const r of ringsHere) { if (r !== outer) holeIdx.push(flat.length / 2); for (const p of r) flat.push(p[0], p[1]); }
    const tris = earcut(flat, holeIdx);
    const n = flat.length / 2;
    const front = [], back = [];
    for (let i = 0; i < n; i++) { front.push(V(flat[2*i], flat[2*i+1], z0, [0, 0, 1])); back.push(V(flat[2*i], flat[2*i+1], -z0, [0, 0, -1])); }
    // Image y runs down, so the y flip mirrors winding: pick each cap's order from its triangle's actual normal.
    for (let t = 0; t < tris.length; t += 3) {
      const [a, b, c] = [tris[t], tris[t+1], tris[t+2]];
      const cross = (flat[2*b]-flat[2*a]) * -(flat[2*c+1]-flat[2*a+1]) - -(flat[2*b+1]-flat[2*a+1]) * (flat[2*c]-flat[2*a]);
      if (cross > 0) { idx.push(front[a], front[b], front[c], back[a], back[c], back[b]); }
      else { idx.push(front[a], front[c], front[b], back[a], back[b], back[c]); }
    }
    for (const r of ringsHere) {
      const ccw = area(r.map((p) => [p[0], -p[1]])) > 0; // in the flipped (Y up) frame
      for (let i = 0; i < r.length; i++) {
        const p = r[i], q = r[(i + 1) % r.length];
        const dx = (q[0]-p[0]), dy = -(q[1]-p[1]); const len = Math.hypot(dx, dy) || 1;
        // Outward normal of a CCW ring edge is (dy, -dx); holes (CW in this frame when the outer is CCW) flip naturally.
        let nx = dy / len, ny = -dx / len; if (!ccw) { nx = -nx; ny = -ny; }
        const a = V(p[0], p[1], z0, [nx, ny, 0]), b = V(q[0], q[1], z0, [nx, ny, 0]);
        const c = V(q[0], q[1], -z0, [nx, ny, 0]), d2 = V(p[0], p[1], -z0, [nx, ny, 0]);
        if (ccw) idx.push(a, d2, c, a, c, b); else idx.push(a, c, d2, a, b, c);
      }
    }
  }
  const prim = doc.createPrimitive()
    .setAttribute('POSITION', doc.createAccessor().setType('VEC3').setArray(new Float32Array(pos)).setBuffer(buffer))
    .setAttribute('NORMAL', doc.createAccessor().setType('VEC3').setArray(new Float32Array(nor)).setBuffer(buffer))
    .setIndices(doc.createAccessor().setType('SCALAR').setArray(new Uint32Array(idx)).setBuffer(buffer))
    .setMaterial(mats[part.colour]);
  root.addChild(doc.createNode(part.name).setMesh(doc.createMesh(part.name).addPrimitive(prim)));
  triTotal += idx.length / 3;
  console.log(part.name, 'rings', count, 'shapes', sh.length, 'tris', idx.length / 3);
}
await new NodeIO().write(outGlb, doc);
console.log('logo', ((maxX-minX)*S).toFixed(3), 'x', ((maxY-minY)*S).toFixed(3), 'm, tris', triTotal, '| svg', f(W), 'x', f(H));
