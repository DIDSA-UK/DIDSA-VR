# Demo content

Models and assemblies that ship inside the APK, so a headset with no server still has something to look at.
Credits and licences: [`CREDITS.md`](CREDITS.md). What the landing does with them: [`../docs/landing-scope.md`](../docs/landing-scope.md).

| Folder | What | Needs a server |
|---|---|---|
| `rockets/` | Six launch vehicles at full size (glTF, metres, Y up, base on the floor at the origin) | No |
| `spacecraft/` | Voyager, Hubble, Pioneer 10, Apollo-Soyuz at full size | No |
| `assemblies/table/` | The table: `Top_and_frame.didsa` (open this one) over `Frame.didsa`, `Frame_A/B.didsa`, `Table_Top.didsa` | Yes (native files are meshed by the backend) |
| `assemblies/plate_and_peg/` | `Plate_and_peg.didsa` over a plate and a peg | Yes |
| `tools/` | `normalise_glb.mjs`, the script that prepared the glb files (not exported; `.gdignore`) | n/a |

## Rules for these files

- **Full size.** Every glb is 1:1 in metres, checked against a published dimension (the table in
  [`../docs/landing-scope.md`](../docs/landing-scope.md#demo-models)). Load with `local_glb_scale` 1.0.
- **No Draco or meshopt compression.** Godot 4.7 cannot read `KHR_draco_mesh_compression`; such a file fails to load.
- **Exported as is.** Each glb has a `.import` file with `importer="keep"`, so Godot does not convert it to a scene and the raw file
  is packed (the app reads glb bytes with `GLTFDocument` at runtime, like any file from the Files tab).
- **Export filter.** `export_presets.cfg` is git-ignored, so set this in your local Android preset (Resources tab):
  *Filters to export non-resource files/folders* = `demo/*`, *Filters to exclude* = `demo/tools/*`. A test pack export with exactly
  these filters (20 Oct 2026) contained every glb and `.didsa` here and nothing from `docs/` or `secrets.cfg`.
- Never put `secrets.cfg` in an include filter: the APK would carry your API key to everyone you give it to.

## Adding a model

```
cd demo/tools && npm i @gltf-transform/core @gltf-transform/extensions @gltf-transform/functions draco3dgltf
node normalise_glb.mjs in.glb ../rockets/Name.glb <scale> [drop]
printf '[remap]\n\nimporter="keep"\n' > ../rockets/Name.glb.import
```

`<scale>` is published size / model size for one well-known dimension (height for a rocket, dish diameter for a probe). `drop`
removes a helper mesh whose only material is named `transparent`. Add the credit to `CREDITS.md` and the check to the scope's table.
Keep `demo/tools/node_modules` out of git.
