# DIDSA logo: source and tracing

`didsa_logo_source.png` (1024 x 1024, from the project owner) is the artwork. `../didsa_logo.svg` and `../didsa_logo.glb` are traced
from it, and `../../../icon.svg` (the APK launcher icon) is the emblem part of the SVG on a dark square.

```
python3 make_masks.py masks/                   # one mask per part: emblem, porthole, wordmark, tagline
npm i potrace earcut svg-path-parser @gltf-transform/core
node trace_logo.mjs masks ../didsa_logo.svg ../didsa_logo.glb
```

The glb is 1.2 m wide, centred on its origin, facing +Z, with one node per part (`Emblem`, `Porthole`, `Wordmark`, `Tagline`) so the
landing can animate them; materials `Ink` (near white, for a dark room) and `Accent` (the logo's blue, emissive). About 27,000
triangles. The SVG keeps the artwork's colours (black and blue). This folder is not exported (`.gdignore`); keep `node_modules/`
and `masks/` out of git.
