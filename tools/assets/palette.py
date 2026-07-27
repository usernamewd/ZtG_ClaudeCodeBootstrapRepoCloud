#!/usr/bin/env python3
"""Procedural palette-atlas generator for Tactical Strike.

Source models are flat-shaded low-poly with one material per colour and no UVs.
Rather than ship a dozen single-colour materials per mesh (a dozen draw calls,
and a flat plastic look), we bake every colour into one small atlas texture with
real surface detail, then remap each face's UVs into its colour's patch. Result:
one material and one texture per model, with fabric/metal/wood grain that reads
as textured rather than untextured.

The same mechanism drives cosmetics: a weapon "finish" is just a different
palette atlas over identical geometry and UVs.

Atlas layout: GRID x GRID patches. Patch i occupies a square; UVs are placed
inside an inset safe area so bilinear filtering and mip-mapping never bleed
between patches.
"""
from __future__ import annotations

import hashlib
import math
import os
from typing import Dict, Iterable, Tuple

from PIL import Image, ImageDraw, ImageFilter

GRID = 8              # 8x8 = 64 palette slots
PATCH_PX = 64         # pixels per patch -> 512x512 atlas
ATLAS_PX = GRID * PATCH_PX
INSET = 0.18          # fraction of the patch kept clear at the edges

Color = Tuple[float, float, float]


# --- Deterministic value noise ------------------------------------------------

def _rng(seed: int):
    state = seed & 0xFFFFFFFF

    def nxt() -> float:
        nonlocal state
        state = (1664525 * state + 1013904223) & 0xFFFFFFFF
        return state / 0xFFFFFFFF

    return nxt


def _fill_noise(img: Image.Image, box, base: Color, amount: float, seed: int,
                grain: int = 1) -> None:
    """Per-pixel multiplicative noise, blocky at `grain` pixels."""
    x0, y0, x1, y1 = box
    rnd = _rng(seed)
    px = img.load()
    w, h = x1 - x0, y1 - y0
    cells = {}
    for j in range(h):
        for i in range(w):
            key = (i // grain, j // grain)
            if key not in cells:
                cells[key] = 1.0 + (rnd() - 0.5) * 2.0 * amount
            k = cells[key]
            px[x0 + i, y0 + j] = (
                max(0, min(255, int(base[0] * 255 * k))),
                max(0, min(255, int(base[1] * 255 * k))),
                max(0, min(255, int(base[2] * 255 * k))),
                255,
            )


def _shade(c: Color, f: float) -> Color:
    return (max(0.0, min(1.0, c[0] * f)),
            max(0.0, min(1.0, c[1] * f)),
            max(0.0, min(1.0, c[2] * f)))


def _linear_to_srgb_ch(c: float) -> float:
    """Blender reports material colours in linear space; PNG stores sRGB. Without
    this every asset bakes out near-black."""
    c = max(0.0, min(1.0, c))
    if c <= 0.0031308:
        return c * 12.92
    return 1.055 * (c ** (1.0 / 2.4)) - 0.055


def linear_to_srgb(c: Color) -> Color:
    return (_linear_to_srgb_ch(c[0]), _linear_to_srgb_ch(c[1]), _linear_to_srgb_ch(c[2]))


# --- Per-family surface treatments -------------------------------------------

def _draw_metal(img, box, base, seed):
    x0, y0, x1, y1 = box
    _fill_noise(img, box, base, 0.05, seed, grain=1)
    d = ImageDraw.Draw(img)
    rnd = _rng(seed + 7)
    # Brushed horizontal streaks.
    for _ in range(int((y1 - y0) * 0.7)):
        y = y0 + int(rnd() * (y1 - y0))
        f = 1.0 + (rnd() - 0.5) * 0.28
        d.line([(x0, y), (x1 - 1, y)], fill=_rgb(_shade(base, f)))
    # A couple of bright scratches.
    for _ in range(3):
        y = y0 + int(rnd() * (y1 - y0))
        xa = x0 + int(rnd() * (x1 - x0) * 0.6)
        d.line([(xa, y), (min(x1 - 1, xa + int(rnd() * (x1 - x0) * 0.5)), y)],
               fill=_rgb(_shade(base, 1.5)))


def _draw_wood(img, box, base, seed):
    x0, y0, x1, y1 = box
    _fill_noise(img, box, base, 0.04, seed, grain=1)
    d = ImageDraw.Draw(img)
    rnd = _rng(seed + 13)
    for i in range(y1 - y0):
        y = y0 + i
        g = 0.86 + 0.14 * abs(math.sin(i * 0.55 + rnd() * 0.4))
        d.line([(x0, y), (x1 - 1, y)], fill=_rgb(_shade(base, g)))


def _draw_fabric(img, box, base, seed):
    x0, y0, x1, y1 = box
    _fill_noise(img, box, base, 0.07, seed, grain=2)
    d = ImageDraw.Draw(img)
    # Woven cross-hatch.
    for i in range(x0, x1, 3):
        d.line([(i, y0), (i, y1 - 1)], fill=_rgb(_shade(base, 0.93)))
    for j in range(y0, y1, 3):
        d.line([(x0, j), (x1 - 1, j)], fill=_rgb(_shade(base, 1.06)))


def _draw_skin(img, box, base, seed):
    _fill_noise(img, box, base, 0.035, seed, grain=2)


def _draw_rubber(img, box, base, seed):
    x0, y0, x1, y1 = box
    _fill_noise(img, box, base, 0.05, seed, grain=1)
    d = ImageDraw.Draw(img)
    rnd = _rng(seed + 23)
    for _ in range(28):
        cx = x0 + rnd() * (x1 - x0)
        cy = y0 + rnd() * (y1 - y0)
        r = 1 + rnd() * 2
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=_rgb(_shade(base, 0.8)))


def _draw_concrete(img, box, base, seed):
    x0, y0, x1, y1 = box
    _fill_noise(img, box, base, 0.09, seed, grain=2)
    d = ImageDraw.Draw(img)
    rnd = _rng(seed + 31)
    for _ in range(16):
        cx = x0 + rnd() * (x1 - x0)
        cy = y0 + rnd() * (y1 - y0)
        r = 1 + rnd() * 3
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=_rgb(_shade(base, 0.82 + rnd() * 0.3)))


def _draw_flat(img, box, base, seed):
    _fill_noise(img, box, base, 0.03, seed, grain=2)


SURFACES = {
    "metal": _draw_metal,
    "wood": _draw_wood,
    "fabric": _draw_fabric,
    "skin": _draw_skin,
    "rubber": _draw_rubber,
    "concrete": _draw_concrete,
    "flat": _draw_flat,
}


def _rgb(c: Color):
    return (int(c[0] * 255), int(c[1] * 255), int(c[2] * 255), 255)


def classify(material_name: str) -> str:
    """Guess a surface treatment from a source material name."""
    n = material_name.lower()
    if any(k in n for k in ("wood", "stock", "grip")):
        return "wood"
    if any(k in n for k in ("skin", "face", "hand", "flesh")):
        return "skin"
    if any(k in n for k in ("cloth", "pant", "fabric", "vest", "shirt", "strap",
                            "main", "uniform", "camo")):
        return "fabric"
    if any(k in n for k in ("rubber", "tire", "boot", "sole")):
        return "rubber"
    if any(k in n for k in ("concrete", "stone", "wall", "floor", "brick",
                            "asphalt", "road")):
        return "concrete"
    if any(k in n for k in ("metal", "steel", "iron", "barrel", "grey", "gray",
                            "silver", "chrome", "gun", "black", "dark")):
        return "metal"
    return "flat"


# --- Atlas -------------------------------------------------------------------

def _patch_cell(slot: int) -> Tuple[int, int]:
    """Grid cell for a slot in PIL pixel space, where row 0 is the TOP of the
    image.

    UV space (Blender, and glTF after the exporter's flip) measures v from the
    bottom, so a slot painted at PIL row 0 is sampled from the bottom of the
    image unless one of the two is inverted. Inverting here, once, keeps
    build_atlas and patch_uv in agreement — without it every model samples the
    unpainted slots and comes out black.
    """
    return slot % GRID, GRID - 1 - (slot // GRID)


def patch_uv(slot: int) -> Tuple[float, float, float, float]:
    """Return the safe (u0, v0, u1, v1) rectangle for a slot, in 0..1 UV space."""
    gx = slot % GRID
    gy = slot // GRID
    step = 1.0 / GRID
    u0, v0 = gx * step, gy * step
    pad = step * INSET
    return (u0 + pad, v0 + pad, u0 + step - pad, v0 + step - pad)


def patch_center_uv(slot: int) -> Tuple[float, float]:
    u0, v0, u1, v1 = patch_uv(slot)
    return ((u0 + u1) * 0.5, (v0 + v1) * 0.5)


def build_atlas(entries: Dict[str, dict], out_path: str,
                colors_are_linear: bool = True) -> Dict[str, int]:
    """Render an atlas.

    entries: material name -> {"color": (r,g,b) 0..1, "surface": optional str}
    Returns material name -> slot index. Order is the dict's insertion order, so
    callers get stable slots as long as they build the dict deterministically.

    Colours coming from Blender are linear; set ``colors_are_linear=False`` when
    passing hand-picked sRGB values.
    """
    if len(entries) > GRID * GRID:
        raise ValueError(f"{len(entries)} materials exceeds {GRID * GRID} palette slots")

    img = Image.new("RGBA", (ATLAS_PX, ATLAS_PX), (0, 0, 0, 255))
    slots: Dict[str, int] = {}

    for slot, (name, spec) in enumerate(entries.items()):
        slots[name] = slot
        color = tuple(spec["color"])[:3]
        if colors_are_linear:
            color = linear_to_srgb(color)
        surface = spec.get("surface") or classify(name)
        gx, gy = _patch_cell(slot)
        box = (gx * PATCH_PX, gy * PATCH_PX, (gx + 1) * PATCH_PX, (gy + 1) * PATCH_PX)
        seed = int(hashlib.md5(name.encode()).hexdigest()[:8], 16)
        SURFACES.get(surface, _draw_flat)(img, box, color, seed)

    # Soften so mip level 1 doesn't alias the fine grain into noise.
    img = img.filter(ImageFilter.GaussianBlur(0.4))
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    img.save(out_path)
    return slots


def recolor_atlas(entries: Dict[str, dict], overrides: Dict[str, Color],
                  out_path: str, colors_are_linear: bool = True) -> Dict[str, int]:
    """Build a variant atlas with some materials recoloured (team skins, weapon
    finishes). Slot assignment is identical to build_atlas for the same entries,
    so the same mesh UVs work with any variant."""
    merged = {}
    for name, spec in entries.items():
        s = dict(spec)
        if name in overrides:
            s["color"] = overrides[name]
        merged[name] = s
    return build_atlas(merged, out_path, colors_are_linear)


if __name__ == "__main__":
    demo = {
        "Metal": {"color": (0.27, 0.29, 0.35)},
        "DarkMetal": {"color": (0.09, 0.10, 0.12)},
        "Wood": {"color": (0.38, 0.20, 0.06)},
        "Fabric": {"color": (0.13, 0.19, 0.05)},
        "Skin": {"color": (0.48, 0.29, 0.10)},
        "Concrete": {"color": (0.55, 0.54, 0.50)},
    }
    print(build_atlas(demo, "/tmp/palette_demo.png"))
