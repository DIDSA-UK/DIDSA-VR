// Usage: node normalise.mjs in.glb out.glb scale [dropHelperRoot]
// Decodes Draco, scales uniformly, stands the model on y=0 centred in x/z, drops invisible helper meshes, writes uncompressed.
import { NodeIO, getBounds } from '@gltf-transform/core';
import { ALL_EXTENSIONS, KHRDracoMeshCompression } from '@gltf-transform/extensions';
import { prune, dedup } from '@gltf-transform/functions';
import draco3d from 'draco3dgltf';
const [,, src, dst, scaleArg, dropArg] = process.argv;
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder': await draco3d.createDecoderModule(), 'draco3d.encoder': await draco3d.createEncoderModule()});
const doc = await io.read(src);
const root = doc.getRoot();
for (const ext of root.listExtensionsUsed()) if (ext.extensionName === 'KHR_draco_mesh_compression') ext.dispose();
if (dropArg === 'drop') for (const n of root.listNodes()) { // a helper mesh whose only material is the "transparent" placeholder
  const m = n.getMesh(); if (!m) continue;
  const prims = m.listPrimitives(); const helper = prims.filter(p => /^transparent$/i.test(p.getMaterial()?.getName() || ''));
  if (helper.length === prims.length && n.listChildren().length) { n.setMesh(null); console.log('dropped helper mesh on', n.getName()); }
}
const scene = root.getDefaultScene();
const s = parseFloat(scaleArg);
const wrap = doc.createNode('DemoRoot');
for (const c of scene.listChildren()) { scene.removeChild(c); wrap.addChild(c); }
scene.addChild(wrap);
wrap.setScale([s, s, s]);
let b = getBounds(scene);
wrap.setTranslation([-(b.min[0] + b.max[0]) / 2, -b.min[1], -(b.min[2] + b.max[2]) / 2]);
b = getBounds(scene);
await doc.transform(prune(), dedup());
await io.write(dst, doc);
console.log(dst.split('/').pop(), 'extent m', b.max.map((v, i) => (v - b.min[i]).toFixed(2)).join(' x '), 'min', b.min.map(v => v.toFixed(2)).join(' '));
