#!/usr/bin/env python3
"""Build every third-person weapon world model for Tactical Strike.

    /opt/blender/blender -b --python tools/assets/build_weapons.py            # all
    /opt/blender/blender -b --python tools/assets/build_weapons.py -- ar77 sr1
    /opt/blender/blender -b --python tools/assets/build_weapons.py -- --debug-markers

Writes, per weapon id:
    assets/weapons/<id>/tp.glb          one mesh, one material, one draw call
    assets/weapons/<id>/<id>_atlas.png  512x512 palette atlas
and finally assets/weapons/manifest.json.

Everything comes from the CC0 packs in /opt/assets_cc0 or is generated here.
The ten guns are built from ten *different* source silhouettes and given ten
different finishes (blued steel, parkerised grey, polymer black, walnut
furniture, desert tan, olive drab) so they never read as recolours of one gun.

--------------------------------------------------------------------------
Conventions produced by this script (see docs/ASSET_PIPELINE.md)
--------------------------------------------------------------------------
Blender working space after `orient()`: barrel along -Y, up +Z, weapon-right +X.
`export_glb(export_yup=True)` maps Blender (x, y, z) -> glTF/Godot (x, z, -y),
so the exported model has its **barrel along +Z, up +Y, right +X** and the grip
hanging down -Y, exactly as the pipeline doc requires.

The mesh origin is the **GripR** point for anything held in a hand (guns,
knife) and the **base centre** for things that sit down (grenades, bomb, defuse
kit), so a mount node needs no magic offset.

Markers are Empties parented to the mesh and export as Node3D:
Muzzle / ShellPort / GripR / GripL / Sight. Every one is derived from the actual
vertex cloud (see `_markers`), never from a hardcoded guess.

`_reproject_uvs` and `_seal_atlas` extend the shared helpers; see their
docstrings for why.
"""
from __future__ import annotations

import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import blender_common as bc  # noqa: E402
import palette  # noqa: E402

REPO = os.path.dirname(os.path.dirname(_HERE))
OUT_ROOT = os.path.join(REPO, "assets", "weapons")
CC0 = "/opt/assets_cc0"

TRI_BUDGET = 1500          # docs/ASSET_PIPELINE.md: weapon TP <= 1500 tris


# ===========================================================================
#  Colour helpers -- recipes are written in sRGB, palette.py wants linear
# ===========================================================================

def _srgb_to_linear_ch(c: float) -> float:
    c = max(0.0, min(1.0, c))
    if c <= 0.04045:
        return c / 12.92
    return ((c + 0.055) / 1.055) ** 2.4


def hexc(s: str):
    """'#3b4048' -> linear RGB, so palette.py's linear->sRGB round-trips."""
    s = s.lstrip("#")
    return tuple(_srgb_to_linear_ch(int(s[i:i + 2], 16) / 255.0)
                 for i in (0, 2, 4))


# ===========================================================================
#  Weapon recipes
# ===========================================================================
# kind      "gun" | "melee" | "grenade" | "device"
# src       source file relative to /opt/assets_cc0 (None => fully procedural)
# space     source orientation family: "ug" (ultimategun), "ts" (toonshooter),
#           "proc" (authored directly in the working space)
# length    final size in metres along `axis`
# axis      "y" = along the barrel (guns/knife), "z" = height, "x" = width
# accs      accessories / procedural add-ons joined in before atlasing
# colors    material name -> sRGB hex finish
# surfaces  material name -> palette surface treatment
#
# The source packs name materials by the artist's palette slot, not by role:
# Grenade's "DarkGreen" is the *white* band, Knife_2's "DarkGrey" is 65% of the
# blade, and every ultimategun model shares one 5-colour ramp. So the finishes
# below are assigned to preserve each source material's **luminance rank** --
# that keeps the artist's value structure (and therefore the readability of the
# model) while the hue does the work of making the guns materially different.
WEAPONS: dict = {

# ------------------------------- PISTOLS ---------------------------------
"p9": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_2.fbx",
    length=0.22, axis="y",
    note="issue sidearm: dark polymer frame, parkerised slide, stippled grip",
    accs=[],
    colors={"Black": "232120", "Metal": "35322e", "Wood": "4a4640",
            "LightMetal": "8b8880"},
    surfaces={"Wood": "rubber", "Black": "rubber", "Metal": "rubber"},
),

"talon": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_4.fbx",
    length=0.235, axis="y",
    note="large-frame hand cannon: blued steel over a desert tan polymer frame",
    accs=[],
    # Deliberately breaks the luminance-rank rule: "Black" is the frame and
    # grip here, and putting the tan there is what makes the two-tone read.
    colors={"Black": "a5885a", "Metal": "3b4350", "LightMetal": "8d8a83"},
    surfaces={"Black": "rubber", "LightMetal": "metal"},
),

"snub": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_5.fbx",
    length=0.225, axis="y",
    note="compact burst machine pistol: two-tone stainless over black polymer, "
         "underbarrel light module",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.74, drop=0.14, fit_width=0.78)],
    colors={"Black": "2e2b28", "Metal": "54514b", "LightMetal": "9d9a93",
            "Acc_Black": "302d29", "Acc_Glass": "e8eecf"},
    surfaces={"Black": "rubber", "Acc_Glass": "flat", "Acc_Black": "rubber"},
),

# --------------------------------- SMGs ----------------------------------
"viper45": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SubmachineGun_4.fbx",
    length=0.60, axis="y",
    note="boxy .45 SMG: matte black polymer over gunmetal, stubby suppressor",
    accs=[dict(src="ultimategun/FBX/Accessories/Silencer_Short.fbx",
               mount="muzzle", inset=0.02, fit_width=0.60)],
    colors={"Black": "262420", "Grey": "38352f", "DarkMetal": "423f39",
            "Metal": "5d594f", "Acc_Black": "2c2a26"},
    surfaces={"Black": "rubber", "Grey": "rubber", "Acc_Black": "rubber"},
),

"mk9": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SubmachineGun_5.fbx",
    length=0.62, axis="y",
    note="long thin SMG: olive-green receiver, wire folding stock, rail optic",
    accs=[dict(src="ultimategun/FBX/Accessories/Scope_3.fbx",
               mount="rail", along=0.46, rise=0.10, fit_len=0.20)],
    colors={"Black": "2e332a", "Grey": "3f4536", "DarkMetal": "4a5240",
            "Metal": "6d7556", "Acc_Black": "2a2c26",
            "Acc_DarkMetal": "3a3f34", "Acc_Glass": "4d7ba8"},
    surfaces={"Black": "rubber", "Acc_Glass": "flat", "Acc_Black": "rubber"},
),

# -------------------------------- RIFLES ---------------------------------
"ar77": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle2_2.fbx",
    length=0.90, axis="y",
    note="attacker carbine: AR pattern, full-length rail, collapsible stock, "
         "flat dark earth furniture, underbarrel light",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.72, drop=0.16, fit_width=0.90)],
    colors={"MainDark": "34322c", "Main": "87734f", "MainLight": "aa946c",
            "Acc_Black": "2b2926", "Acc_Glass": "e8eecf"},
    surfaces={"Main": "rubber", "MainDark": "rubber", "MainLight": "rubber",
              "Acc_Glass": "flat", "Acc_Black": "rubber"},
),

"br52": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle_2.fbx",
    length=0.92, axis="y",
    note="defender rifle: long-stroke pattern, walnut furniture, blued steel, "
         "side-rail optic",
    accs=[dict(src="ultimategun/FBX/Accessories/Scope_3.fbx",
               mount="rail", along=0.40, rise=0.10, fit_len=0.28)],
    colors={"Black": "2a2926", "DarkMetal": "3d434c", "Metal": "4e535d",
            "DarkWood": "5f4224", "Wood": "855c33", "Acc_Black": "2b2926",
            "Acc_DarkMetal": "3b3f45", "Acc_Glass": "4d7ba8"},
    surfaces={"Wood": "wood", "DarkWood": "wood", "Acc_Glass": "flat",
              "Acc_Black": "rubber"},
),

"sr1": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SniperRifle_4.fbx",
    length=1.15, axis="y",
    note="bolt sniper: olive drab chassis, black action, big glass, "
         "folding bipod",
    accs=[dict(src="ultimategun/FBX/Accessories/Bipod.fbx",
               mount="under_barrel", along=0.70, drop=0.12, fit_height=0.50)],
    colors={"Glass": "33547a", "Black": "2d2f28", "Grey": "3b3e31",
            "DarkMetal": "464c37", "Metal": "68704e", "Acc_Black": "2b2926",
            "Acc_DarkMetal": "3d4139"},
    surfaces={"Grey": "rubber", "Black": "rubber", "Glass": "flat"},
),

# -------------------------------- HEAVY ----------------------------------
"breacher12": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Shotgun_1.fbx",
    length=1.00, axis="y",
    note="tactical pump shotgun: black polymer furniture, blued barrel and "
         "magazine tube, breaching light",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.70, drop=0.16, fit_width=0.95)],
    colors={"Black": "2b2825", "DarkMetal": "333f4f", "Metal": "495060",
            "LightMetal": "8a857b", "Acc_Black": "2b2926",
            "Acc_Glass": "e8eecf"},
    surfaces={"Black": "rubber", "Acc_Glass": "flat", "Acc_Black": "rubber"},
),

"mule": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle_4.fbx",
    length=1.05, axis="y",
    note="belt-fed heavy: parkerised receiver, olive furniture, 100-round box "
         "magazine, vented heavy barrel, bipod",
    accs=[dict(src="ultimategun/FBX/Accessories/Bipod.fbx",
               mount="under_barrel", along=0.82, drop=0.12, fit_height=0.44),
          dict(kind="boxmag"),
          dict(kind="shroud")],
    colors={"Black": "2f2d29", "DarkMetal": "46443d", "Metal": "62605a",
            "DarkWood": "585e44", "Wood": "686f50", "TS_Ammo": "525939",
            "TS_Accent": "6f5827", "Acc_Black": "2b2926",
            "Acc_DarkMetal": "40443a"},
    surfaces={"Wood": "rubber", "DarkWood": "rubber", "TS_Ammo": "metal",
              "TS_Accent": "metal"},
),

# -------------------------------- MELEE ----------------------------------
"knife": dict(
    kind="melee", space="ts", src="toonshooter/Guns/glTF/Knife_2.gltf",
    length=0.30, axis="y",
    note="combat knife: satin blade, blued guard, black ribbed rubber grip",
    accs=[],
    colors={"Black": "2b2925", "DarkGrey": "4d5049", "LightGrey": "b8b5ae"},
    surfaces={"Black": "rubber", "LightGrey": "metal", "DarkGrey": "metal"},
),

# ------------------------------- GRENADES --------------------------------
"frag": dict(
    kind="grenade", space="ts", src="toonshooter/Guns/glTF/Grenade.gltf",
    length=0.115, axis="z",
    note="fragmentation grenade: olive drab body, steel fuse and spoon, "
         "painted ID band",
    accs=[],
    colors={"DarkGrey": "585c58", "Green": "636d3c", "DarkGreen": "c2c4b2"},
    surfaces={"Green": "metal", "DarkGreen": "metal", "DarkGrey": "metal"},
),

"flash": dict(
    kind="grenade", space="proc", src=None, proc="flash",
    length=0.125, axis="z",
    note="stun grenade: tall bare-steel canister, three rings of emission "
         "ports, brass fuse (original procedural design)",
    accs=[],
    colors={"TS_Port": "1e2022", "TS_Band": "2f2d2a", "TS_Fuse": "6e706e",
            "TS_Body": "92948f", "TS_Accent": "9a8a3f"},
    surfaces={"TS_Body": "metal", "TS_Band": "rubber", "TS_Port": "metal",
              "TS_Fuse": "metal", "TS_Accent": "metal"},
),

"smoke": dict(
    kind="grenade", space="proc", src=None, proc="smoke",
    length=0.118, axis="z",
    note="smoke canister: squat wide olive body, ribbed steel emitter cap, "
         "base vents (original procedural design)",
    accs=[],
    colors={"TS_Band": "343925", "TS_Fuse": "5a5c58", "TS_Body": "636d3f",
            "TS_Port": "6e706c", "TS_Accent": "b3b5a4"},
    surfaces={"TS_Body": "metal", "TS_Band": "rubber", "TS_Port": "metal",
              "TS_Fuse": "metal", "TS_Accent": "metal"},
),

"incendiary": dict(
    kind="grenade", space="ts", src="toonshooter/Guns/glTF/FireGrenade.gltf",
    length=0.128, axis="z",
    note="incendiary canister: fire-red body, hazard banding, steel fuse",
    accs=[],
    colors={"Black": "2c2a29", "Red": "ac3c27", "Grey": "a9aaa6",
            "DarkRed": "ddd8cc"},
    surfaces={"Red": "metal", "DarkRed": "metal", "Grey": "metal",
              "Black": "rubber"},
),

# --------------------------- OBJECTIVE DEVICES ---------------------------
"bomb": dict(
    kind="device", space="proc", src=None, proc="bomb",
    length=0.34, axis="y",
    note="original demolition charge: ribbed case, keypad + LED strip, stub "
         "antenna, cargo straps, two shaped-charge blocks (procedural)",
    accs=[],
    colors={"TS_Panel": "262624", "TS_Case": "434644", "TS_Key": "63676a",
            "TS_Screen": "3fd07a", "TS_Strap": "4d3f1e", "TS_Accent": "b8511a",
            "TS_Charge": "82755c", "TS_Wire": "a52a24", "TS_Metal": "8c8a83"},
    surfaces={"TS_Case": "metal", "TS_Panel": "rubber", "TS_Key": "rubber",
              "TS_Screen": "flat", "TS_Strap": "fabric", "TS_Accent": "metal",
              "TS_Charge": "fabric", "TS_Wire": "rubber", "TS_Metal": "metal"},
),

"defusekit": dict(
    kind="device", space="proc", src=None, proc="defusekit",
    length=0.24, axis="x",
    note="original tool roll: canvas pouch with a buckled flap, wire cutters "
         "laid across the top, coiled lead and a circuit tester (procedural)",
    accs=[],
    colors={"TS_Strap": "3e3520", "TS_CanvasDark": "494430",
            "TS_Canvas": "645f40", "TS_Tool": "8e908d", "TS_Buckle": "928f87",
            "TS_ToolGrip": "9c2f22", "TS_Accent": "b8912f"},
    surfaces={"TS_Canvas": "fabric", "TS_CanvasDark": "fabric",
              "TS_Strap": "fabric", "TS_Buckle": "metal", "TS_Tool": "metal",
              "TS_ToolGrip": "rubber", "TS_Accent": "metal"},
),
}


# ===========================================================================
#  Small Blender utilities
# ===========================================================================

def _obj_tris(obj) -> int:
    return sum(max(0, len(p.vertices) - 2) for p in obj.data.polygons)


def _activate(obj) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def _apply(obj, location=True, rotation=True, scale=True) -> None:
    _activate(obj)
    bpy.ops.object.transform_apply(location=location, rotation=rotation,
                                   scale=scale)
    bpy.context.view_layer.update()


def _bbox(obj):
    """(lo, hi) world bounding box, straight off the vertices (no depsgraph)."""
    if obj.type == "MESH" and len(obj.data.vertices):
        pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
    else:
        pts = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    return (Vector((min(p.x for p in pts), min(p.y for p in pts),
                    min(p.z for p in pts))),
            Vector((max(p.x for p in pts), max(p.y for p in pts),
                    max(p.z for p in pts))))


def _material(name: str, color=(0.5, 0.5, 0.5)):
    """Get/create a material whose base colour palette.py can read."""
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.diffuse_color = (color[0], color[1], color[2], 1.0)
    for n in m.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            n.inputs["Base Color"].default_value = (color[0], color[1],
                                                    color[2], 1.0)
    return m


def merge_duplicate_materials(objs) -> None:
    """Collapse ``Black`` / ``Black.001`` / ``Black.002`` into one slot.

    Joining an accessory into a gun duplicates identically-named source
    materials. Without this the atlas burns a slot per copy and the per-weapon
    colour overrides silently miss every ``.00N`` variant -- which is exactly
    how you end up with one grey gun ten times.
    """
    canon: dict = {}
    for o in objs:
        for i, m in enumerate(o.data.materials):
            if m is None:
                continue
            base = m.name.split(".")[0]
            keep = canon.setdefault(base, m)
            if keep is not m:
                o.data.materials[i] = keep
    for m in list(bpy.data.materials):        # drop the now-orphaned copies
        if m.users == 0:
            bpy.data.materials.remove(m)
    for base, m in canon.items():
        if m.name != base and bpy.data.materials.get(base) is None:
            m.name = base


def prefix_materials(obj, prefix: str) -> None:
    """Namespace an accessory's materials so it can carry its own finish.

    Every ultimategun model and accessory shares one 5-colour material ramp, so
    without this an optic's body is forced to the same slot as the rifle's
    receiver and no scope can ever be a different colour from the gun it sits
    on. Prefixing keeps them separate; merge_duplicate_materials still folds
    two copies of the same accessory material together.
    """
    for m in obj.data.materials:
        if m is not None and not m.name.startswith(prefix):
            m.name = prefix + m.name.split(".")[0]


def prune_unused_materials(obj) -> None:
    """Drop material slots no polygon actually uses.

    The FBX importer gives every ultimategun model the pack's full 5-colour
    material list whether the mesh uses it or not, which would spend atlas
    slots on colours that are never sampled (and make the per-weapon override
    check report phantom materials).
    """
    me = obj.data
    used = sorted({p.material_index for p in me.polygons})
    if len(used) == len(me.materials):
        return
    keep = [me.materials[i] for i in used if i < len(me.materials)]
    remap = {old: new for new, old in enumerate(used)}
    me.materials.clear()
    for m in keep:
        me.materials.append(m)
    for p in me.polygons:
        p.material_index = remap.get(p.material_index, 0)


def import_source(path_rel: str, name: str):
    """Import one CC0 file, join its meshes, drop everything else."""
    before = set(bpy.data.objects)
    bc.import_any(os.path.join(CC0, path_rel))
    new = [o for o in bpy.data.objects if o not in before]
    obj = bc.join_meshes([o for o in new if o.type == "MESH"], name)
    bc.delete_objects([o for o in new if o.type != "MESH"])
    _apply(obj)
    return obj


def fit_tris(obj, budget: int) -> int:
    """Decimate until the mesh fits the triangle budget.

    Coplanar dissolve first (these source meshes are flat-shaded, so merging
    coplanar fans is visually free), collapse only if that is not enough.
    """
    n0 = _obj_tris(obj)
    if n0 <= budget:
        return n0
    _activate(obj)
    m = obj.modifiers.new("planar", "DECIMATE")
    m.decimate_type = "DISSOLVE"
    m.angle_limit = math.radians(1.0)
    bpy.ops.object.modifier_apply(modifier=m.name)
    n1 = _obj_tris(obj)
    if n1 > budget:
        m = obj.modifiers.new("collapse", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = max(0.05, (budget / float(n1)) * 0.985)
        bpy.ops.object.modifier_apply(modifier=m.name)
    n2 = _obj_tris(obj)
    print(f"    decimate: {n0} -> dissolve {n1} -> collapse {n2} "
          f"(budget {budget})")
    return n2


# ===========================================================================
#  Atlas UVs
# ===========================================================================

def _tri_wave(t: float) -> float:
    """Continuous 0..1 triangle wave -- a tiling ramp with no seam."""
    t = math.fmod(t, 2.0)
    if t < 0.0:
        t += 2.0
    return 1.0 - abs(t - 1.0)


def _reproject_uvs(obj, face_slots, jitter: float = 0.7) -> None:
    """Rewrite the atlas UVs with a *seamless* geometric projection.

    ``blender_common.atlas_remap`` wraps its projection with ``% 1.0``. Faces
    that straddle a wrap span their whole patch in UV across a couple of
    millimetres of surface, which spikes the screen-space UV derivative and
    drops those faces to a coarse mip of the atlas -- so a handful of faces
    on every model shade differently from their neighbours. A triangle wave
    tiles the same way with no discontinuity, so the grain still varies across
    a surface but the derivative stays tiny and every face samples mip 0.

    Row/column placement is left entirely to ``palette.patch_uv``; the atlas
    painter agrees with it (see palette._patch_cell), so nothing is mirrored
    here -- doing so would double-flip and land every face on an unpainted slot.
    """
    me = obj.data
    uvl = me.uv_layers.active.data
    verts = me.vertices
    loops = me.loops
    for poly, slot in zip(me.polygons, face_slots):
        u0, v0, u1, v1 = palette.patch_uv(slot)
        cu, cv = (u0 + u1) * 0.5, (v0 + v1) * 0.5
        hw, hh = (u1 - u0) * 0.5 * jitter, (v1 - v0) * 0.5 * jitter
        for li in poly.loop_indices:
            co = verts[loops[li].vertex_index].co
            pu = _tri_wave(co.x * 1.7 + co.z * 0.31)
            pv = _tri_wave(co.y * 1.7 + co.x * 0.17)
            uvl[li].uv = (cu + (pu - 0.5) * 2.0 * hw,
                          cv + (pv - 0.5) * 2.0 * hh)


def _patch_pixel_cell(slot: int):
    """Image-space (column, row) of a palette slot, row 0 at the top.

    Derived from the public ``patch_uv`` rather than palette's private helper,
    so this stays correct whichever way the atlas painter numbers its rows --
    the invariant is only that painting and patch_uv agree.
    """
    u0, v0, u1, v1 = palette.patch_uv(slot)
    gx = int(((u0 + u1) * 0.5) * palette.GRID)
    gy = int((1.0 - (v0 + v1) * 0.5) * palette.GRID)
    return (min(palette.GRID - 1, max(0, gx)), min(palette.GRID - 1, max(0, gy)))


def _seal_atlas(png_path: str, used: int) -> None:
    """Fill the unused palette slots with the mean of the used ones.

    The atlas ships mip-mapped and VRAM-compressed; leaving 55 of 64 slots pure
    black means the coarse mips of a distant weapon average in that black and
    the model darkens as it recedes. Painting the spare slots with the average
    used colour makes the mip chain degrade to a plausible tone instead.
    Slot geometry is untouched, so the layout stays canonical.
    """
    from PIL import Image
    img = Image.open(png_path).convert("RGBA")
    p = palette.PATCH_PX
    px = img.load()
    acc = [0, 0, 0]
    for s in range(used):
        gx, gy = _patch_pixel_cell(s)
        c = px[gx * p + p // 2, gy * p + p // 2]
        for i in range(3):
            acc[i] += c[i]
    mean = tuple(max(1, v // max(1, used)) for v in acc) + (255,)
    for s in range(used, palette.GRID * palette.GRID):
        gx, gy = _patch_pixel_cell(s)
        for y in range(gy * p, (gy + 1) * p):
            for x in range(gx * p, (gx + 1) * p):
                px[x, y] = mean
    img.save(png_path)


# ===========================================================================
#  Procedural primitives (authored directly in the working space)
# ===========================================================================

def _finish(name, me, mat, loc, rot):
    me.materials.append(mat)
    for p in me.polygons:
        p.material_index = 0
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = rot
    return ob


def box(name, size, loc=(0, 0, 0), mat=None, rot=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = _finish(name, me, mat, loc, rot)
    ob.scale = size
    return ob


def cyl(name, r, depth, loc=(0, 0, 0), mat=None, segs=12, rot=(0, 0, 0),
        r2=None):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segs,
                          radius1=r, radius2=(r if r2 is None else r2),
                          depth=depth)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return _finish(name, me, mat, loc, rot)


def sphere(name, r, loc=(0, 0, 0), mat=None, segs=8, rings=5):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return _finish(name, me, mat, loc, (0, 0, 0))


def torus(name, r, thick, loc=(0, 0, 0), mat=None, major=10, minor=4,
          rot=(0, 0, 0)):
    bm = bmesh.new()
    grid = []
    for i in range(major):
        a = 2 * math.pi * i / major
        col = []
        for j in range(minor):
            b = 2 * math.pi * j / minor
            rr = r + thick * math.cos(b)
            col.append(bm.verts.new((rr * math.cos(a), rr * math.sin(a),
                                     thick * math.sin(b))))
        grid.append(col)
    for i in range(major):
        for j in range(minor):
            bm.faces.new((grid[i][j], grid[i][(j + 1) % minor],
                          grid[(i + 1) % major][(j + 1) % minor],
                          grid[(i + 1) % major][j]))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    return _finish(name, me, mat, loc, rot)


# ===========================================================================
#  Procedural builds  (-Y forward, +Z up, +X weapon-right)
# ===========================================================================

def _fuse_assembly(mats, body_top_z: float, s: float):
    """Grenade fuse: plug, striker lever (spoon), safety pin and pull ring.

    Shared by the flash and smoke canisters so all four grenades read as one
    family next to the two CC0 bodies.
    """
    fuse, accent, band = mats["fuse"], mats["accent"], mats["band"]
    return [
        cyl("fuse_neck", 0.30 * s, 0.16 * s, (0, 0, body_top_z + 0.07 * s),
            fuse, segs=10),
        cyl("fuse_plug", 0.20 * s, 0.22 * s, (0, 0, body_top_z + 0.24 * s),
            fuse, segs=10),
        cyl("fuse_cap", 0.26 * s, 0.06 * s, (0, 0, body_top_z + 0.37 * s),
            accent, segs=10),
        # Striker lever: a flat strip over the cap folding down the side.
        box("spoon_top", (0.10 * s, 0.44 * s, 0.035 * s),
            (0, 0.16 * s, body_top_z + 0.385 * s), band),
        box("spoon_side", (0.09 * s, 0.05 * s, 0.62 * s),
            (0, 0.36 * s, body_top_z - 0.02 * s), band,
            rot=(math.radians(-5), 0, 0)),
        # Safety pin through the plug with the pull ring hanging off it.
        cyl("pin", 0.032 * s, 0.46 * s, (0, -0.02 * s, body_top_z + 0.30 * s),
            accent, segs=6, rot=(0, math.radians(90), 0)),
        torus("pull_ring", 0.17 * s, 0.035 * s,
              (-0.30 * s, -0.02 * s, body_top_z + 0.30 * s), accent,
              major=10, minor=4, rot=(0, math.radians(90), 0)),
    ]


def build_flash(rec):
    """Tall bare-steel stun canister with three rings of emission ports."""
    mats = {
        "body": _material("TS_Body", (0.55, 0.57, 0.60)),
        "band": _material("TS_Band", (0.11, 0.12, 0.13)),
        "port": _material("TS_Port", (0.08, 0.09, 0.10)),
        "fuse": _material("TS_Fuse", (0.33, 0.34, 0.35)),
        "accent": _material("TS_Accent", (0.78, 0.63, 0.15)),
    }
    body_h, body_r = 1.55, 0.46
    parts = [
        cyl("body", body_r, body_h, (0, 0, 0), mats["body"], segs=14),
        cyl("rim_top", body_r * 1.06, 0.11, (0, 0, body_h * 0.5 - 0.055),
            mats["band"], segs=14),
        cyl("rim_bot", body_r * 1.06, 0.11, (0, 0, -body_h * 0.5 + 0.055),
            mats["band"], segs=14),
        cyl("waist", body_r * 1.04, 0.14, (0, 0, 0.02), mats["band"], segs=14),
    ]
    # Ports read as holes, so they sit flush: a dark disc on the skin, not a stud.
    for k, z in enumerate((-0.42, 0.28, 0.60)):
        for i in range(6):
            a = 2 * math.pi * (i / 6.0) + (0.52 if k == 1 else 0.0)
            parts.append(cyl(f"port{k}_{i}", 0.095, 0.02,
                             (body_r * 0.985 * math.cos(a),
                              body_r * 0.985 * math.sin(a), z),
                             mats["port"], segs=8,
                             rot=(0, math.radians(90), -a)))
    parts += _fuse_assembly(mats, body_h * 0.5, 1.0)
    return parts


def build_smoke(rec):
    """Squat wide smoke canister with a ribbed emitter cap."""
    mats = {
        "body": _material("TS_Body", (0.30, 0.34, 0.21)),
        "band": _material("TS_Band", (0.17, 0.19, 0.12)),
        "port": _material("TS_Port", (0.43, 0.45, 0.48)),
        "fuse": _material("TS_Fuse", (0.30, 0.32, 0.34)),
        "accent": _material("TS_Accent", (0.72, 0.75, 0.77)),
    }
    body_h, body_r = 1.05, 0.62
    parts = [
        cyl("body", body_r, body_h, (0, 0, 0), mats["body"], segs=16),
        cyl("rim_top", body_r * 1.06, 0.12, (0, 0, body_h * 0.5 - 0.06),
            mats["band"], segs=16),
        cyl("rim_bot", body_r * 1.06, 0.12, (0, 0, -body_h * 0.5 + 0.06),
            mats["band"], segs=16),
        box("label", (body_r * 1.24, 0.05, 0.30), (0, -body_r * 0.99, 0.02),
            mats["accent"]),
    ]
    cap_z = body_h * 0.5 + 0.10
    parts.append(cyl("cap", body_r * 0.86, 0.20, (0, 0, cap_z), mats["port"],
                     segs=16, r2=body_r * 0.70))
    for i in range(8):
        a = 2 * math.pi * i / 8.0
        parts.append(box(f"rib{i}", (0.06, body_r * 0.66, 0.12),
                         (0.40 * body_r * math.cos(a),
                          0.40 * body_r * math.sin(a), cap_z + 0.16),
                         mats["band"], rot=(0, 0, -a)))
    for i in range(6):
        a = 2 * math.pi * i / 6.0
        parts.append(cyl(f"vent{i}", 0.085, 0.02,
                         (body_r * 0.985 * math.cos(a),
                          body_r * 0.985 * math.sin(a), -body_h * 0.30),
                         mats["port"], segs=8, rot=(0, math.radians(90), -a)))
    parts += _fuse_assembly(mats, cap_z + 0.10, 0.92)
    return parts


def build_bomb(rec):
    """Original plantable demolition charge.

    A ribbed equipment case with a keypad and LED strip on a tilted top plate,
    a stub antenna, two cargo straps and two shaped-charge blocks wired into
    the case. Original silhouette; nothing traced from any commercial game.
    Base sits on z = 0 -- it is a ground object.
    """
    m_case = _material("TS_Case", (0.18, 0.19, 0.21))
    m_panel = _material("TS_Panel", (0.08, 0.09, 0.10))
    m_key = _material("TS_Key", (0.36, 0.39, 0.42))
    m_screen = _material("TS_Screen", (0.18, 0.75, 0.37))
    m_strap = _material("TS_Strap", (0.19, 0.15, 0.06))
    m_accent = _material("TS_Accent", (0.78, 0.33, 0.12))
    m_charge = _material("TS_Charge", (0.43, 0.38, 0.31))
    m_wire = _material("TS_Wire", (0.56, 0.12, 0.12))
    m_metal = _material("TS_Metal", (0.49, 0.51, 0.53))

    W, D, H = 0.62, 1.00, 0.42
    parts = [box("case", (W, D, H), (0, 0, H * 0.5), m_case)]
    for i, t in enumerate((-0.34, -0.12, 0.12, 0.34)):
        parts.append(box(f"rib{i}", (W * 1.05, 0.06, H * 0.86),
                         (0, D * t, H * 0.48), m_panel))
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(box(f"bump{sx}{sy}", (0.055, 0.055, H * 1.05),
                             (sx * W * 0.5, sy * D * 0.5, H * 0.5), m_accent))
    pz = H + 0.035
    parts.append(box("panel", (W * 0.86, D * 0.52, 0.09), (0, -D * 0.12, pz),
                     m_panel, rot=(math.radians(-6), 0, 0)))
    parts.append(box("screen_bezel", (W * 0.70, D * 0.19, 0.04),
                     (0, -D * 0.29, pz + 0.05), m_metal,
                     rot=(math.radians(-6), 0, 0)))
    parts.append(box("screen", (W * 0.58, D * 0.13, 0.045),
                     (0, -D * 0.29, pz + 0.072), m_screen,
                     rot=(math.radians(-6), 0, 0)))
    for r in range(4):
        for c in range(3):
            parts.append(box(f"key{r}{c}", (0.055, 0.05, 0.035),
                             ((c - 1) * 0.15, -D * 0.10 + r * 0.095,
                              pz + 0.065 + r * 0.010), m_key,
                             rot=(math.radians(-6), 0, 0)))
    parts.append(cyl("lamp", 0.05, 0.06, (W * 0.31, -D * 0.38, pz + 0.07),
                     m_accent, segs=8))
    parts.append(cyl("ant_base", 0.06, 0.10, (W * 0.36, D * 0.40, H + 0.045),
                     m_metal, segs=8))
    parts.append(cyl("antenna", 0.026, 0.42, (W * 0.39, D * 0.42, H + 0.28),
                     m_panel, segs=6, rot=(math.radians(-9), 0, 0), r2=0.014))
    parts.append(sphere("ant_tip", 0.04, (W * 0.415, D * 0.455, H + 0.50),
                        m_accent, segs=8, rings=5))
    for sy in (-0.30, 0.30):
        parts.append(box(f"strap{sy}", (W * 1.08, 0.11, H * 1.08),
                         (0, D * sy, H * 0.5), m_strap))
        parts.append(box(f"buckle{sy}", (0.13, 0.15, 0.06),
                         (0, D * sy, H * 1.08), m_metal))
    for i, sx in enumerate((-1, 1)):
        parts.append(box(f"charge{i}", (0.21, 0.13, H * 0.62),
                         (sx * 0.19, -D * 0.55, H * 0.44), m_charge))
        parts.append(box(f"charge_band{i}", (0.225, 0.055, H * 0.22),
                         (sx * 0.19, -D * 0.55, H * 0.44), m_accent))
        parts.append(cyl(f"wire{i}", 0.02, 0.32,
                         (sx * 0.19, -D * 0.45, H * 0.80), m_wire, segs=6,
                         rot=(math.radians(58), 0, 0)))
    parts.append(box("handle_l", (0.055, 0.055, 0.15),
                     (-W * 0.30, D * 0.20, H + 0.075), m_metal))
    parts.append(box("handle_r", (0.055, 0.055, 0.15),
                     (W * 0.30, D * 0.20, H + 0.075), m_metal))
    parts.append(box("handle_bar", (W * 0.70, 0.055, 0.05),
                     (0, D * 0.20, H + 0.16), m_strap))
    return parts


def build_defusekit(rec):
    """Original defuse kit: a canvas tool roll with the cutters laid on top.

    Tools lie *across* the pouch rather than standing in loops -- a compact
    silhouette that still reads as "bag of tools" from any angle and at the
    size this thing is actually seen (dropped on the floor, or as an icon).
    """
    m_canvas = _material("TS_Canvas", (0.22, 0.21, 0.14))
    m_dark = _material("TS_CanvasDark", (0.13, 0.12, 0.08))
    m_strap = _material("TS_Strap", (0.10, 0.08, 0.03))
    m_buckle = _material("TS_Buckle", (0.49, 0.51, 0.53))
    m_tool = _material("TS_Tool", (0.31, 0.34, 0.37))
    m_grip = _material("TS_ToolGrip", (0.42, 0.07, 0.05))
    m_accent = _material("TS_Accent", (0.78, 0.63, 0.15))

    W, D, H = 0.62, 0.38, 0.30
    parts = [
        box("pouch", (W, D, H), (0, 0, H * 0.5), m_canvas),
        box("pocket", (W * 0.80, 0.055, H * 0.60), (0, -D * 0.50, H * 0.40),
            m_dark),
        box("pocket_lip", (W * 0.80, 0.065, 0.05), (0, -D * 0.50, H * 0.70),
            m_strap),
        box("seam_l", (0.055, D * 1.04, H * 1.04), (-W * 0.5, 0, H * 0.5),
            m_dark),
        box("seam_r", (0.055, D * 1.04, H * 1.04), (W * 0.5, 0, H * 0.5),
            m_dark),
        box("base_welt", (W * 1.04, D * 1.04, 0.05), (0, 0, 0.025), m_dark),
        # Flap folded over the top, hanging a little over the front edge.
        box("flap", (W * 1.05, D * 0.92, 0.055), (0, D * 0.02, H + 0.03),
            m_dark, rot=(math.radians(-5), 0, 0)),
        box("flap_lip", (W * 1.05, 0.06, 0.10), (0, -D * 0.44, H + 0.005),
            m_canvas),
    ]
    # Two straps over the flap with buckles on the front face.
    for sx in (-0.28, 0.28):
        parts.append(box(f"strap{sx}", (0.12, D * 1.10, 0.04),
                         (W * sx, 0, H + 0.065), m_strap))
        parts.append(box(f"buckle{sx}", (0.15, 0.09, 0.055),
                         (W * sx, -D * 0.47, H + 0.01), m_buckle))
    # Wire cutters lying across the flap: jaws left, red grips right.
    tz = H + 0.10
    parts += [
        box("cut_jaw_l", (0.30, 0.05, 0.045), (-0.17, 0.035, tz), m_tool,
            rot=(0, 0, math.radians(4))),
        box("cut_jaw_r", (0.30, 0.05, 0.045), (-0.17, -0.035, tz), m_tool,
            rot=(0, 0, math.radians(-4))),
        cyl("cut_pivot", 0.055, 0.075, (0.02, 0, tz), m_buckle, segs=8),
        box("cut_grip_l", (0.26, 0.06, 0.055), (0.19, 0.06, tz), m_grip,
            rot=(0, 0, math.radians(-9))),
        box("cut_grip_r", (0.26, 0.06, 0.055), (0.19, -0.06, tz), m_grip,
            rot=(0, 0, math.radians(9))),
    ]
    # Coiled lead hooked on the right side, and a small circuit tester.
    parts.append(torus("coil", 0.072, 0.020, (-W * 0.30, D * 0.24, H + 0.09),
                       m_grip, major=12, minor=4))
    parts += [
        box("tester", (0.13, 0.09, 0.05), (W * 0.06, D * 0.26, H + 0.09),
            m_tool),
        cyl("tester_lamp", 0.026, 0.035, (W * 0.06, D * 0.26, H + 0.13),
            m_accent, segs=8),
        box("driver", (0.05, 0.05, 0.28), (W * 0.34, -D * 0.55, H * 0.62),
            m_accent, rot=(math.radians(14), 0, 0)),
        # A grab loop on the top so the silhouette is never a plain box.
        box("loop_l", (0.05, 0.05, 0.12), (W * 0.30, D * 0.30, H + 0.10),
            m_strap),
        box("loop_r", (0.05, 0.05, 0.12), (W * 0.42, D * 0.30, H + 0.10),
            m_strap),
        box("loop_bar", (0.17, 0.05, 0.045), (W * 0.36, D * 0.30, H + 0.17),
            m_strap),
    ]
    return parts


PROC_BUILDERS = {"flash": build_flash, "smoke": build_smoke,
                 "bomb": build_bomb, "defusekit": build_defusekit}


# ===========================================================================
#  Accessory mounting (source space: +X forward, +Z up, +-Y lateral)
# ===========================================================================

def _source_barrel_ref(obj):
    """Barrel tip / bore axis of a source-space gun, from its own vertices."""
    vs = [v.co for v in obj.data.vertices]
    xmax, xmin = max(v.x for v in vs), min(v.x for v in vs)
    span = xmax - xmin
    cand = [v for v in vs if v.x >= xmax - 0.03 * span] or vs
    return (xmin, xmax, span,
            sum(v.y for v in cand) / len(cand),
            sum(v.z for v in cand) / len(cand))


def _extreme_z_at(obj, x_lo, x_hi, top: bool):
    vs = [v.co.z for v in obj.data.vertices if x_lo <= v.co.x <= x_hi]
    if not vs:
        return 0.0
    return max(vs) if top else min(vs)


def _fit_scale(gun, acc, spec) -> float:
    """Scale factor sizing an accessory against the gun it bolts onto.

    The source packs are not in a shared scale -- the "flashlight" is a third as
    long as a pistol yet as wide as a rifle receiver -- so accessory size is
    always expressed as a ratio of one of the gun's own extents:
      fit_len    accessory length = f * gun length (along the barrel)
      fit_width  accessory width  = f * gun width  (lateral)
      fit_height accessory height = f * gun height
    """
    glo, ghi = _bbox(gun)
    alo, ahi = _bbox(acc)
    for key, gi, ai in (("fit_len", ghi.x - glo.x, ahi.x - alo.x),
                        ("fit_width", ghi.y - glo.y, ahi.y - alo.y),
                        ("fit_height", ghi.z - glo.z, ahi.z - alo.z)):
        if key in spec and ai > 1e-9:
            return spec[key] * gi / ai
    return spec.get("scale", 1.0)


def place_accessory(gun, acc, spec) -> None:
    """Position an accessory on a source-space gun, from the gun's geometry.

    ``drop`` / ``rise`` are overlap fractions of the *accessory's* own height,
    so a scope always sinks the same visual amount into its rail and a light
    always clears the barrel it hangs under, whatever the source scales are.
    """
    xmin, xmax, span, axis_y, axis_z = _source_barrel_ref(gun)
    s = _fit_scale(gun, acc, spec)
    if abs(s - 1.0) > 1e-6:
        acc.scale = (s, s, s)
        _apply(acc, location=False, rotation=False, scale=True)
    alo, ahi = _bbox(acc)
    ah = max(1e-9, ahi.z - alo.z)
    mount = spec["mount"]

    if mount == "muzzle":
        acc.location = (xmax - spec.get("inset", 0.02) * span - alo.x,
                        axis_y, axis_z)
    elif mount == "rail":
        # Reference the top line over a *wide* window. A narrow one lands in
        # the dip between the rear sight and the gas tube on a long-stroke
        # rifle, and the optic then fills that notch instead of sitting proud
        # of the gun -- present in the mesh, invisible in silhouette.
        x = xmin + spec["along"] * span
        top = _extreme_z_at(gun, x - 0.22 * span, x + 0.22 * span, True)
        acc.location = (x - (alo.x + ahi.x) * 0.5, axis_y,
                        top - spec.get("rise", 0.10) * ah - alo.z)
    elif mount == "under_barrel":
        x = xmin + spec["along"] * span
        bot = _extreme_z_at(gun, x - 0.07 * span, x + 0.07 * span, False)
        acc.location = (x - (alo.x + ahi.x) * 0.5, axis_y,
                        bot + spec.get("drop", 0.12) * ah - ahi.z)
    else:
        raise ValueError(f"unknown accessory mount: {mount}")
    _apply(acc)
    lo, hi = _bbox(acc)
    print(f"    [acc] {os.path.basename(spec['src'])} scale={s:.3f} "
          f"{mount} x=[{lo.x:.2f},{hi.x:.2f}] z=[{lo.z:.2f},{hi.z:.2f}] "
          f"(gun x=[{xmin:.2f},{xmax:.2f}] bore_z={axis_z:.2f})")


def add_boxmag(gun):
    """A 100-round box magazine for the heavy. Source space, procedural."""
    xmin, _xmax, span, axis_y, _axis_z = _source_barrel_ref(gun)
    x0 = xmin + 0.545 * span
    bot = _extreme_z_at(gun, xmin + 0.50 * span, xmin + 0.60 * span, False)
    m = _material("TS_Ammo", (0.22, 0.24, 0.17))
    m2 = _material("TS_Accent", (0.34, 0.26, 0.10))
    w = span * 0.070
    parts = [
        box("mag_body", (span * 0.19, w, span * 0.09),
            (x0, axis_y, bot - span * 0.012), m),
        box("mag_lip", (span * 0.15, w * 0.86, span * 0.030),
            (x0, axis_y, bot + span * 0.028), m),
        box("mag_latch", (span * 0.028, w * 1.04, span * 0.04),
            (x0 - span * 0.11, axis_y, bot - span * 0.020), m2),
        box("belt", (span * 0.045, w * 0.5, span * 0.020),
            (x0 + span * 0.112, axis_y, bot + span * 0.030), m2),
    ]
    for p in parts:
        _apply(p)
    return parts


def add_shroud(gun):
    """Vented heavy-barrel shroud for the heavy. Source space, procedural."""
    xmin, _xmax, span, axis_y, axis_z = _source_barrel_ref(gun)
    m = _material("TS_Ammo", (0.22, 0.24, 0.17))
    x0 = xmin + 0.68 * span
    parts = [cyl("shroud", span * 0.028, span * 0.22,
                 (x0 + span * 0.11, axis_y, axis_z), m, segs=10,
                 rot=(0, math.radians(90), 0))]
    for i in range(5):
        parts.append(cyl(f"shroud_vent{i}", span * 0.034, span * 0.016,
                         (x0 + span * 0.025 + i * span * 0.043, axis_y, axis_z),
                         m, segs=10, rot=(0, math.radians(90), 0)))
    for p in parts:
        _apply(p)
    return parts


EXTRA_BUILDERS = {"boxmag": add_boxmag, "shroud": add_shroud}


# ===========================================================================
#  Orientation
# ===========================================================================

def orient(obj, space: str) -> None:
    """Rotate a source model into the working space (-Y forward, +Z up).

    ultimategun FBX          barrel +X, up +Z      -> -90 deg about Z
    toonshooter glTF guns    barrel -X, up +Z      -> +90 deg about Z
    toonshooter glTF blades  tip +Z, flat +-Y      -> +90 about X then +90 about Y
    ts_upright / proc        already in the working space
    """
    # The glTF importer leaves objects in QUATERNION rotation mode, where
    # assigning rotation_euler is silently ignored.
    obj.rotation_mode = "XYZ"
    if space == "ug":
        obj.rotation_euler = (0, 0, math.radians(-90))
    elif space == "ts_gun":
        obj.rotation_euler = (0, 0, math.radians(90))
    elif space == "ts_blade":
        obj.rotation_euler = (math.radians(90), math.radians(90), 0)
    elif space in ("proc", "ts_upright"):
        return
    else:
        raise ValueError(f"unknown source space: {space}")
    _apply(obj)


def resolve_space(rec) -> str:
    if rec["space"] == "proc":
        return "proc"
    if rec["space"] == "ts":
        if rec["kind"] == "melee":
            return "ts_blade"
        if rec["kind"] == "grenade":
            return "ts_upright"
        return "ts_gun"
    return "ug"


# ===========================================================================
#  Marker derivation -- all five points come out of the vertex cloud
# ===========================================================================

def _pct(values, q: float) -> float:
    vs = sorted(values)
    if not vs:
        return 0.0
    return vs[min(len(vs) - 1, max(0, int(round(q * (len(vs) - 1)))))]


def _centroid(vs) -> Vector:
    n = float(len(vs))
    return Vector((sum(v.x for v in vs) / n, sum(v.y for v in vs) / n,
                   sum(v.z for v in vs) / n))


def _markers(obj, kind: str) -> dict:
    """Derive Muzzle / ShellPort / GripR / GripL / Sight from the mesh.

    Working space: -Y forward, +Z up, +X weapon-right.
    """
    vs = [v.co.copy() for v in obj.data.vertices]
    y_front, y_back = min(v.y for v in vs), max(v.y for v in vs)
    z_bot, z_top = min(v.z for v in vs), max(v.z for v in vs)
    L = max(1e-6, y_back - y_front)
    H = max(1e-6, z_top - z_bot)

    def band(lo_f, hi_f):
        return [v for v in vs
                if y_front + lo_f * L <= v.y <= y_front + hi_f * L]

    # Muzzle: the forward-most 3% of the cloud is the crown of the barrel, so
    # its lateral/vertical centroid is the bore -- not a bbox corner.
    tip = [v for v in vs if v.y <= y_front + 0.03 * L] or vs
    # Median, not mean: on guns whose front sight post reaches as far forward
    # as the crown, a mean drags the "bore" up onto the sight. The crown is a
    # ring of a dozen-odd verts and the post only a handful, so the median
    # stays on the barrel.
    axis_x = _pct([v.x for v in tip], 0.5)
    axis_z = _pct([v.z for v in tip], 0.5)
    muzzle = Vector((axis_x, y_front, axis_z))

    if kind in ("grenade", "device"):
        # The "muzzle" of a thrown/planted object is its working end: the fuse
        # on a grenade, the antenna/panel end of the charge.
        top = [v for v in vs if v.z >= z_top - 0.06 * H] or vs
        tc = _centroid(top)
        muzzle = Vector((tc.x, tc.y, z_top))

    # Sight: highest geometry over the receiver/optic stretch, taken at its
    # rear-most point -- a rear iron sight, or a scope's eyepiece.
    if kind in ("gun", "melee"):
        reg = ([v for v in band(0.22, 0.82) if abs(v.x - axis_x) <= 0.45 * H]
               or band(0.22, 0.82) or vs)
        z_reg = max(v.z for v in reg)
        top = [v for v in reg if v.z >= z_reg - 0.03 * H]
        sight = Vector((axis_x, max(v.y for v in top), z_reg))
    else:
        sight = Vector((0.0, 0.0, z_top))

    # ShellPort: right-hand face of the receiver just behind the chamber.
    if kind == "gun":
        b = band(0.36, 0.54) or vs
        upper = [v for v in b if v.z >= _pct([v.z for v in b], 0.55)] or b
        shell = Vector((max(v.x for v in b), y_front + 0.45 * L,
                        _centroid(upper).z))
    else:
        shell = Vector((max(v.x for v in vs), y_front + 0.5 * L,
                        z_bot + 0.6 * H))

    # GripR: the firing hand. Rear-biased centroid of the low geometry behind
    # the trigger for guns (the magazine hangs low too but sits forward of the
    # grip, so the rear bias rejects it); the handle centroid for a knife.
    # Heights are measured *within the rear region* so a bipod hanging off the
    # front cannot drag the threshold down with it.
    if kind == "gun":
        # The firing hand sits just behind the trigger, which on every one of
        # these silhouettes (pistol, SMG, rifle, shotgun) falls in the 56-84%
        # stretch measured back from the muzzle. Bounding the search that way
        # -- rather than "everything behind the midpoint" -- keeps a magazine,
        # an ammo box or a stock from owning the answer. Heights are measured
        # inside the band so a bipod up front cannot drag the floor down.
        rear = band(0.56, 0.84) or [v for v in vs if v.y >= y_front + 0.5 * L] or vs
        zr_bot = min(v.z for v in rear)
        hr = max(1e-6, max(v.z for v in rear) - zr_bot)
        low = [v for v in rear if v.z <= zr_bot + 0.40 * hr]
        if len(low) < 8:
            low = [v for v in rear if v.z <= zr_bot + 0.70 * hr] or rear
        y_cut = _pct([v.y for v in low], 0.50)
        sel = [v for v in low if v.y >= y_cut] or low
        g = _centroid(sel)
        grip_r = Vector((axis_x, g.y, g.z))
    elif kind == "melee":
        handle = [v for v in vs if v.y >= y_front + 0.62 * L] or vs
        g = _centroid(handle)
        grip_r = Vector((axis_x, g.y, g.z))
    else:
        grip_r = Vector((0.0, 0.0, z_bot + 0.45 * H))

    # GripL: support hand on the handguard, below the bore. Percentile-based so
    # a bipod or light in the same band cannot own the answer.
    if kind == "gun" and L > 0.35:
        fore = band(0.16, 0.42) or vs
        under = [v for v in fore if v.z <= axis_z] or fore
        zl = max(_pct([v.z for v in under], 0.45), axis_z - 0.55 * H)
        grip_l = Vector((axis_x, _centroid(fore).y, zl))
    else:
        grip_l = grip_r.copy()

    return {"Muzzle": muzzle, "ShellPort": shell, "GripR": grip_r,
            "GripL": grip_l, "Sight": sight}


# ===========================================================================
#  Build one weapon
# ===========================================================================

def build_weapon(wid: str, rec: dict, debug_markers: bool = False) -> dict:
    print(f"[{wid}] {rec['note']}")
    bc.reset_scene()

    sources = []
    if rec.get("proc"):
        parts = PROC_BUILDERS[rec["proc"]](rec)
        for p in parts:
            _apply(p)
        gun = bc.join_meshes(parts, wid)
        sources.append(f"procedural (this script): {rec['proc']}")
    else:
        gun = import_source(rec["src"], wid)
        sources.append(rec["src"])
        joins = [gun]
        for spec in rec.get("accs", []):
            if "kind" in spec:
                joins += EXTRA_BUILDERS[spec["kind"]](gun)
                sources.append(f"procedural (this script): {spec['kind']}")
                continue
            acc = import_source(spec["src"], f"{wid}_acc")
            prune_unused_materials(acc)
            prefix_materials(acc, "Acc_")
            place_accessory(gun, acc, spec)
            joins.append(acc)
            sources.append(spec["src"])
        gun = bc.join_meshes(joins, wid)

    merge_duplicate_materials([gun])
    prune_unused_materials(gun)
    _apply(gun)

    orient(gun, resolve_space(rec))
    scale = bc.normalize_size(gun, rec["length"], rec["axis"])
    tris = fit_tris(gun, TRI_BUDGET)

    marks = _markers(gun, rec["kind"])

    # Origin: the firing hand for held weapons, the base centre for things that
    # sit on the ground or in a palm.
    if rec["kind"] in ("gun", "melee"):
        anchor = marks["GripR"].copy()
    else:
        lo, hi = _bbox(gun)
        anchor = Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, lo.z))
    for v in gun.data.vertices:
        v.co -= anchor
    marks = {k: (v - anchor) for k, v in marks.items()}

    lo, hi = _bbox(gun)
    out_dir = os.path.join(OUT_ROOT, wid)
    os.makedirs(out_dir, exist_ok=True)
    atlas_png = os.path.join(out_dir, f"{wid}_atlas.png")

    colors = {k: hexc(v) for k, v in (rec.get("colors") or {}).items()}
    slots = bc.build_atlas_for([gun], atlas_png, overrides=colors,
                               surfaces=rec.get("surfaces"))
    missing = [m for m in colors if m not in slots]
    if missing:
        print(f"    WARNING colour overrides matched nothing: {missing}")
    unstyled = [m for m in slots if m not in colors]
    if unstyled:
        print(f"    WARNING materials with no colour override: {unstyled}")

    # Capture face -> palette slot before atlas_remap collapses the material
    # slots, so the UVs can be rebuilt afterwards (see _reproject_uvs).
    names = [m.name if m else None for m in gun.data.materials]
    face_slots = [slots.get(names[p.material_index] if
                            p.material_index < len(names) else None, 0)
                  for p in gun.data.polygons]

    bc.atlas_remap([gun], slots, atlas_png, material_name=f"TS_{wid}")
    _reproject_uvs(gun, face_slots)
    _seal_atlas(atlas_png, len(slots))

    for name, loc in marks.items():
        bc.add_marker(name, loc, parent=gun)

    if debug_markers:
        dbg = _material("TS_DebugMark", (1.0, 0.0, 0.35))
        size = max(0.006, min(hi.y - lo.y, 0.5) * 0.03)
        for name, loc in marks.items():
            _apply(box(f"DBG_{name}", (size, size, size), tuple(loc), dbg))
        glb = os.path.join(OUT_ROOT, "_dbg", f"{wid}.glb")
    else:
        glb = os.path.join(out_dir, "tp.glb")

    bc.export_glb(glb)
    print(f"    tris={tris} atlas_slots={len(slots)} src_scale={scale:.4f} "
          f"size_xyz=({hi.x - lo.x:.3f}, {hi.y - lo.y:.3f}, "
          f"{hi.z - lo.z:.3f}) m")
    print(f"    wrote {os.path.relpath(glb, REPO)}")
    print(f"    wrote {os.path.relpath(atlas_png, REPO)}")

    def godot(v):     # Blender (x, y, z) -> glTF/Godot (x, z, -y)
        return [round(v.x, 5), round(v.z, 5), round(-v.y, 5)]

    return {
        "id": wid,
        "tp": f"res://assets/weapons/{wid}/tp.glb",
        "atlas": f"res://assets/weapons/{wid}/{wid}_atlas.png",
        "kind": rec["kind"],
        "length_m": round(rec["length"], 4),
        "tris": tris,
        "atlas_px": palette.ATLAS_PX,
        "atlas_slots": len(slots),
        "origin": "GripR" if rec["kind"] in ("gun", "melee") else "base_centre",
        "markers": {k: godot(v) for k, v in marks.items()},
        "muzzle": godot(marks["Muzzle"]),
        "aabb_size_m": [round(hi.x - lo.x, 4), round(hi.z - lo.z, 4),
                        round(hi.y - lo.y, 4)],
        "sources": sources,
        "note": rec["note"],
    }


# ===========================================================================
#  main
# ===========================================================================

def main() -> None:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    debug = "--debug-markers" in argv
    ids = [a for a in argv if not a.startswith("--")] or list(WEAPONS)

    manifest_path = os.path.join(OUT_ROOT, "manifest.json")
    manifest = {
        "generated_by": "tools/assets/build_weapons.py",
        "convention": {
            "space": "barrel +Z, up +Y, weapon-right +X (glTF/Godot space)",
            "units": "metres",
            "markers": ["Muzzle", "ShellPort", "GripR", "GripL", "Sight"],
            "material": "one atlas-textured material -> one draw call",
            "tri_budget": TRI_BUDGET,
            "aabb_size_m": "[width, height, length] in Godot axes",
        },
        "weapons": {},
    }
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path) as f:
                manifest["weapons"] = json.load(f).get("weapons", {})
        except Exception:
            pass

    built = 0
    for wid in ids:
        if wid not in WEAPONS:
            print(f"[skip] unknown weapon id: {wid}")
            continue
        manifest["weapons"][wid] = build_weapon(wid, WEAPONS[wid],
                                                debug_markers=debug)
        built += 1

    manifest["weapons"] = {k: manifest["weapons"][k]
                           for k in WEAPONS if k in manifest["weapons"]}
    if not debug:
        os.makedirs(OUT_ROOT, exist_ok=True)
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=1)
            f.write("\n")
        print(f"[manifest] {os.path.relpath(manifest_path, REPO)} "
              f"({len(manifest['weapons'])} weapons)")
    print(f"[done] built {built} weapon(s); set total "
          f"{sum(manifest['weapons'][w]['tris'] for w in manifest['weapons'])}"
          f" tris")


main()
