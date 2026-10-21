// Usage: node simplify_glb.mjs in.glb out.glb ratio [error]
// Welds vertices and decimates every mesh with meshoptimizer (keeps `ratio` of the triangles, within `error` of the model's size), writes plain uncompressed glb.
// Run it on a normalised model (normalise_glb.mjs) to bring a heavy model near the triangle budget (docs/landing-scope.md).
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { weld, simplify, prune, dedup } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';
const [,, src, dst, ratioArg, errorArg] = process.argv;
await MeshoptSimplifier.ready;
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const doc = await io.read(src);
const count = () => { let t = 0; for (const m of doc.getRoot().listMeshes()) for (const p of m.listPrimitives()) { const i = p.getIndices(); t += (i ? i.getCount() : p.getAttribute('POSITION').getCount()) / 3; } return Math.round(t); };
const before = count();
await doc.transform(weld(), simplify({ simplifier: MeshoptSimplifier, ratio: parseFloat(ratioArg), error: parseFloat(errorArg ?? '0.001') }), prune(), dedup());
await io.write(dst, doc);
console.log(dst.split('/').pop(), before, '->', count(), 'triangles');
