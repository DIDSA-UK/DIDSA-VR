# Demo content: credits and licences

These files ship inside the APK (export include filter `demo/*`, see [`README.md`](README.md)). The landing's **About** page must show
this list in the headset, because the SLS model's licence (CC BY 4.0) requires visible credit.

## Third-party models

| File | Credit | Licence | Changes made here |
|---|---|---|---|
| `rockets/SLS_Block_1.glb` | "SLS Rocket" (https://skfb.ly/pI6F9) by WISEMANmods | [Creative Commons Attribution 4.0](http://creativecommons.org/licenses/by/4.0/) | Scaled x19.66 to full size, stood on the floor, re-saved as plain glTF |
| `rockets/Saturn_V.glb` | NASA 3D Resources, "Saturn V" (https://github.com/nasa/NASA-3D-Resources) | NASA media: free to use, no copyright; no NASA endorsement implied ([guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media)) | Scaled x8.516, stood on the floor |
| `rockets/Jupiter-C_Explorer_1.glb` | NASA 3D Resources, "Explorer Jupiter-C Rocket" | NASA media (as above) | Draco compression removed (Godot cannot read it), scaled x1.2135, stood on the floor |
| `rockets/Delta_II.glb` | NASA 3D Resources, "Delta II" (supplied by the project owner) | NASA media (as above) | Invisible 1 m helper box removed, stood on the floor (scale already 1:1) |
| `rockets/Pegasus_XL.glb` | NASA 3D Resources, "Pegasus XL" (supplied by the project owner) | NASA media (as above) | Invisible helper box removed, scaled x0.96, stood on the floor |
| `spacecraft/Voyager.glb` | NASA 3D Resources, "Voyager Probe (A)" | NASA media (as above) | Draco removed, scaled x36.6 |
| `spacecraft/Hubble_Space_Telescope.glb` | NASA 3D Resources, "Hubble Space Telescope (A)" | NASA media (as above) | Draco removed, scaled x0.0254 (it was modelled in inches) |
| `spacecraft/Pioneer_10.glb` | NASA 3D Resources, "Pioneer 10" | NASA media (as above) | Draco removed (scale already 1:1) |
| `spacecraft/Apollo-Soyuz.glb` | NASA 3D Resources, "Apollo Soyuz" | NASA media (as above) | Stood on the floor (scale already 1:1) |

The NASA insignia and mission markings that appear on some textures may not be used to imply NASA endorsement.

## Project files

`assemblies/table/` (the owner's table top on a four-bar frame) and `assemblies/plate_and_peg/` (the plate and peg sample) are
DIDSA files made with DIDSA-CAD. They are copies of `DIDSA-CAD/backend/tests/data/table_top_frame/` and of this repo's
`assembly.didsa` and `tests/fixtures/`.
