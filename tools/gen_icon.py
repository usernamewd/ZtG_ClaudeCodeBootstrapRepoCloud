#!/usr/bin/env python3
"""Generate the original Tactical Strike app icon (and splash) procedurally.

Original design: dark slate roundel, orange chevron "strike" mark cutting
through a thin reticle ring. No third-party artwork involved.
"""
from PIL import Image, ImageDraw
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BG = (18, 22, 26, 255)
PANEL = (28, 34, 40, 255)
ORANGE = (255, 122, 26, 255)
STEEL = (154, 170, 184, 255)


def draw_icon(size: int) -> Image.Image:
    s = size / 512.0
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Rounded square background
    r = int(96 * s)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=BG)
    d.rounded_rectangle([int(14 * s)] * 2 + [size - int(14 * s)] * 2,
                        radius=int(84 * s), outline=PANEL, width=int(10 * s))
    cx = cy = size / 2
    # Reticle ring
    rr = int(176 * s)
    d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=STEEL, width=int(14 * s))
    # Reticle ticks
    tick = int(52 * s)
    w = int(14 * s)
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        x0 = cx + dx * rr - (w // 2 if dx == 0 else 0)
        y0 = cy + dy * rr - (w // 2 if dy == 0 else 0)
        if dx == 0:
            d.rectangle([cx - w / 2, y0 - (tick if dy < 0 else 0),
                         cx + w / 2, y0 + (tick if dy > 0 else 0)], fill=STEEL)
        else:
            d.rectangle([x0 - (tick if dx < 0 else 0), cy - w / 2,
                         x0 + (tick if dx > 0 else 0), cy + w / 2], fill=STEEL)
    # Chevron strike mark (two orange chevrons pointing up)
    for i, top in enumerate((150, 256)):
        t = top * s
        h = 96 * s
        wd = 150 * s
        thick = 54 * s
        pts = [(cx - wd, t + h), (cx, t), (cx + wd, t + h),
               (cx + wd, t + h + thick), (cx, t + thick), (cx - wd, t + h + thick)]
        d.polygon(pts, fill=ORANGE if i == 0 else (255, 152, 66, 255))
    return img


def main():
    icons = ROOT + "/assets/icons"
    os.makedirs(icons, exist_ok=True)
    draw_icon(512).save(icons + "/icon.png")
    draw_icon(432).save(icons + "/icon_adaptive_fg.png")
    bg = Image.new("RGBA", (432, 432), BG)
    bg.save(icons + "/icon_adaptive_bg.png")
    print("icons written to", icons)


if __name__ == "__main__":
    main()
