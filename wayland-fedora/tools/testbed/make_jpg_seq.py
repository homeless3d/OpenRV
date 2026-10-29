#!/usr/bin/env python3
"""Generate a small numbered colour test sequence data/jpg/f.0001.jpg ... (default 24 frames, 960x540)."""
import colorsys, os, sys
from PIL import Image, ImageDraw
out = sys.argv[1] if len(sys.argv) > 1 else "data/jpg"
n = int(sys.argv[2]) if len(sys.argv) > 2 else 24
os.makedirs(out, exist_ok=True)
for i in range(1, n + 1):
    r, g, b = [int(255 * c) for c in colorsys.hsv_to_rgb(i / n, 0.7, 0.9)]
    im = Image.new("RGB", (960, 540), (r, g, b))
    d = ImageDraw.Draw(im)
    d.rectangle((40 + i * 30, 200, 140 + i * 30, 340), fill=(255, 255, 255))
    d.text((20, 20), "frame %04d" % i, fill=(0, 0, 0))
    im.save(os.path.join(out, "f.%04d.jpg" % i), quality=90)
print("wrote", n, "frames to", out)
