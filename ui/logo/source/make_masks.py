"""Splits didsa_logo_source.png into one black-on-white mask per logo part, 4x upscaled, for trace_logo.mjs.

Usage (from this folder): python3 make_masks.py masks/   (needs Pillow and numpy)
Regions are in source-image pixels; re-measure them if the artwork changes.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

UPSCALE = 4
REGIONS = {"emblem": (80, 330, 395, 660), "wordmark": (405, 405, 940, 550), "tagline": (405, 570, 940, 612)}
PORTHOLE = (310, 370, 360, 415)


def main(out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    image = Image.open(Path(__file__).with_name("didsa_logo_source.png")).convert("RGB")
    big = image.resize((image.width * UPSCALE, image.height * UPSCALE), Image.BICUBIC)
    rgb = np.asarray(big).astype(int)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luminance = 0.299 * r + 0.587 * g + 0.114 * b
    blue = (b - r > 50) & (b > 110)
    near_blue = np.asarray(Image.fromarray((blue * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9))) > 0
    ink = (luminance < 128) & ~near_blue
    meta = {"scale": UPSCALE, "regions": {}}

    def save(mask, name, box):
        x0, y0, x1, y1 = (v * UPSCALE for v in box)
        Image.fromarray(np.where(mask[y0:y1, x0:x1], 0, 255).astype(np.uint8)).save(out_dir / f"{name}.png")
        meta["regions"][name] = [x0, y0]

    for name, box in REGIONS.items():
        save(ink, name, box)
    save(blue, "porthole", PORTHOLE)
    (out_dir / "meta.json").write_text(json.dumps(meta))


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "masks"))
