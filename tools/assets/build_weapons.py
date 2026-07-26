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


# Shared finish vocabulary; each weapon mixes these differently.
POLYMER_BLACK = hexc("23262b")
BLUED_STEEL = hexc("2b3340")
PARKERIZED = hexc("55585a")
STAINLESS = hexc("9aa0a6")
GUNMETAL = hexc("41464c")
WALNUT = hexc("6b4526")
DESERT_TAN = hexc("b09468")
FDE = hexc("7a6a4f")
OLIVE = hexc("4d5636")
OLIVE_DARK = hexc("343a24")
SCOPE_GLASS = hexc("2d4a6b")
RUBBER_BLACK = hexc("1b1d20")
BRASS = hexc("8a6a2c")
HAZARD = hexc("c8531f")
STEEL_LIGHT = hexc("7d8288")
LENS_WARM = hexc("d7e0c0")


# ===========================================================================
#  Weapon recipes
# ===========================================================================
# kind      "gun" | "melee" | "grenade" | "device"
# src       source file relative to /opt/assets_cc0 (None => fully procedural)
# space     source orientation family: "ug" (ultimategun), "ts" (toonshooter),
#           "proc" (authored directly in the working space)
# length    final size in metres along `axis`
# axis      "y" = along the barrel (guns/knife), "z" = height (grenades)
# accs      accessories / procedural add-ons joined in before atlasing
# colors    material name -> sRGB colour
# surfaces  material name -> palette surface treatment
WEAPONS: dict = {

# ------------------------------- PISTOLS ---------------------------------
"p9": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_2.fbx",
    length=0.22, axis="y",
    note="issue sidearm: polymer frame, parkerised slide, no accessories",
    accs=[],
    colors={"Black": POLYMER_BLACK, "DarkMetal": hexc("31353a"),
            "LightMetal": hexc("6e7378"), "Metal": PARKERIZED,
            "Wood": hexc("2c2f33")},
    surfaces={"Wood": "rubber", "Black": "rubber"},
),

"talon": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_4.fbx",
    length=0.235, axis="y",
    note="large-frame hand cannon: blued slide over desert tan polymer frame",
    accs=[],
    colors={"Black": DESERT_TAN, "LightMetal": hexc("8d949c"),
            "Metal": BLUED_STEEL},
    surfaces={"Black": "rubber"},
),

"snub": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_5.fbx",
    length=0.225, axis="y",
    note="compact burst machine pistol: two-tone stainless over black polymer "
         "with an underbarrel light module",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.66, drop=0.02, fit_width=0.78)],
    colors={"Black": POLYMER_BLACK, "LightMetal": STAINLESS,
            "Metal": hexc("6a7076"), "Glass": LENS_WARM},
    surfaces={"Black": "rubber", "Glass": "flat"},
),

# --------------------------------- SMGs ----------------------------------
"viper45": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SubmachineGun_4.fbx",
    length=0.60, axis="y",
    note="boxy .45 SMG with a vertical foregrip and a stubby suppressor",
    accs=[dict(src="ultimategun/FBX/Accessories/Silencer_Short.fbx",
               mount="muzzle", inset=0.02, fit_width=0.60)],
    colors={"Black": POLYMER_BLACK, "DarkMetal": hexc("2a2d31"),
            "Grey": hexc("4a4f55"), "Metal": GUNMETAL},
    surfaces={"Black": "rubber"},
),

"mk9": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SubmachineGun_5.fbx",
    length=0.62, axis="y",
    note="long thin SMG, wire folding stock, low-mount optic, olive/park finish",
    accs=[dict(src="ultimategun/FBX/Accessories/Scope_3.fbx",
               mount="rail", along=0.44, rise=0.0, fit_len=0.20)],
    colors={"Black": hexc("2f3a33"), "DarkMetal": hexc("39423a"),
            "Grey": hexc("6a7266"), "Metal": hexc("515a4e"),
            "Glass": SCOPE_GLASS},
    surfaces={"Black": "rubber", "Glass": "flat"},
),

# -------------------------------- RIFLES ---------------------------------
"ar77": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle2_4.fbx",
    length=0.90, axis="y",
    note="attacker carbine: AR pattern with carry handle, FDE furniture, "
         "underbarrel light",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.74, drop=0.02, fit_width=0.90)],
    colors={"Black": hexc("1e2024"), "DarkMetal": hexc("24262a"), "Main": FDE,
            "MainDark": hexc("4c4132"), "MainLight": hexc("94815f"),
            "Metal": hexc("36393d"), "Glass": LENS_WARM},
    surfaces={"Main": "rubber", "MainDark": "rubber", "MainLight": "rubber",
              "Glass": "flat"},
),

"br52": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle_2.fbx",
    length=0.92, axis="y",
    note="defender rifle: long-stroke pattern, walnut furniture, blued steel, "
         "side-rail optic",
    accs=[dict(src="ultimategun/FBX/Accessories/Scope_3.fbx",
               mount="rail", along=0.40, rise=0.0, fit_len=0.19)],
    colors={"Black": hexc("22242a"), "DarkMetal": BLUED_STEEL,
            "DarkWood": hexc("472c16"), "Metal": hexc("343d4a"),
            "Wood": WALNUT, "Glass": SCOPE_GLASS},
    surfaces={"Wood": "wood", "DarkWood": "wood", "Glass": "flat"},
),

"sr1": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SniperRifle_4.fbx",
    length=1.15, axis="y",
    note="bolt sniper: olive drab chassis, big glass, folding bipod",
    accs=[dict(src="ultimategun/FBX/Accessories/Bipod.fbx",
               mount="under_barrel", along=0.74, drop=0.02, fit_height=0.40)],
    colors={"Black": hexc("22251f"), "DarkMetal": hexc("2b3128"),
            "Glass": SCOPE_GLASS, "Grey": OLIVE, "Metal": hexc("4a5140")},
    surfaces={"Grey": "rubber", "Black": "rubber", "Glass": "flat"},
),

# -------------------------------- HEAVY ----------------------------------
"breacher12": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Shotgun_1.fbx",
    length=1.00, axis="y",
    note="tactical pump shotgun: black polymer, blued barrel, breaching light",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.58, drop=0.02, fit_width=0.95)],
    colors={"Black": POLYMER_BLACK, "DarkMetal": hexc("1e2228"),
            "LightMetal": hexc("737a82"), "Metal": BLUED_STEEL,
            "Glass": LENS_WARM},
    surfaces={"Black": "rubber", "Glass": "flat"},
),

"mule": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle_4.fbx",
    length=1.05, axis="y",
    note="belt-fed heavy: parkerised receiver, 100-round box magazine, "
         "vented heavy barrel, bipod",
    accs=[dict(src="ultimategun/FBX/Accessories/Bipod.fbx",
               mount="under_barrel", along=0.82, drop=0.02, fit_height=0.40),
          dict(kind="boxmag"),
          dict(kind="shroud")],
    colors={"Black": hexc("2a2c2e"), "DarkMetal": hexc("34383a"),
            "DarkWood": hexc("3a3f34"), "Metal": PARKERIZED,
            "Wood": hexc("4d5443"), "TS_Ammo": hexc("4b5240"),
            "TS_Accent": BRASS},
    surfaces={"Wood": "rubber", "DarkWood": "rubber", "TS_Ammo": "metal",
              "TS_Accent": "metal"},
),

# -------------------------------- MELEE ----------------------------------
"knife": dict(
    kind="melee", space="ts", src="toonshooter/Guns/glTF/Knife_2.gltf",
    length=0.30, axis="y",
    note="combat knife: satin blade, black ribbed rubber grip",
    accs=[],
    colors={"Black": RUBBER_BLACK, "DarkGrey": hexc("3a3f45"),
            "LightGrey": hexc("aeb4ba")},
    surfaces={"Black": "rubber", "LightGrey": "metal", "DarkGrey": "metal"},
),

# ------------------------------- GRENADES --------------------------------
"frag": dict(
    kind="grenade", space="ts", src="toonshooter/Guns/glTF/Grenade.gltf",
    length=0.115, axis="z",
    note="fragmentation grenade: olive drab body, steel fuse and spoon",
    accs=[],
    colors={"DarkGreen": OLIVE_DARK, "DarkGrey": hexc("42474d"),
            "Green": OLIVE},
    surfaces={"Green": "metal", "DarkGreen": "metal", "DarkGrey": "metal"},
),

"flash": dict(
    kind="grenade", space="proc", src=None, proc="flash",
    length=0.125, axis="z",
    note="stun grenade: tall bare-steel canister, three rings of emission "
         "ports, brass fuse (original procedural design)",
    accs=[],
    colors={"TS_Body": hexc("8e949a"), "TS_Band": hexc("1d1f22"),
            "TS_Port": hexc("15171a"), "TS_Fuse": hexc("55595b"),
            "TS_Accent": hexc("c9a227")},
    surfaces={"TS_Body": "metal", "TS_Band": "rubber", "TS_Port": "metal",
              "TS_Fuse": "metal", "TS_Accent": "metal"},
),

"smoke": dict(
    kind="grenade", space="proc", src=None, proc="smoke",
    length=0.118, axis="z",
    note="smoke canister: squat wide olive body, ribbed steel emitter cap, "
         "base vents (original procedural design)",
    accs=[],
    colors={"TS_Body": OLIVE, "TS_Band": hexc("2b3020"),
            "TS_Port": hexc("6d737a"), "TS_Fuse": hexc("4c5157"),
            "TS_Accent": hexc("b8bec4")},
    surfaces={"TS_Body": "metal", "TS_Band": "rubber", "TS_Port": "metal",
              "TS_Fuse": "metal", "TS_Accent": "metal"},
),

"incendiary": dict(
    kind="grenade", space="ts", src="toonshooter/Guns/glTF/FireGrenade.gltf",
    length=0.128, axis="z",
    note="incendiary canister: fire-red body, hazard banding, steel fuse",
    accs=[],
    colors={"Black": hexc("1d1f22"), "DarkRed": hexc("6d1a12"),
            "Grey": hexc("b9bec4"), "Red": hexc("a8301c")},
    surfaces={"Red": "metal", "DarkRed": "metal", "Grey": "metal",
              "Black": "rubber"},
),

# --------------------------- OBJECTIVE DEVICES ---------------------------
"bomb": dict(
    kind="device", space="proc", src=None, proc="bomb",
    length=0.34, axis="y",
    note="original demolition charge: ribbed case, keypad + LED strip, whip "
         "antenna, cargo straps, two shaped-charge blocks (procedural)",
    accs=[],
    colors={"TS_Case": hexc("2f3338"), "TS_Panel": hexc("15171a"),
            "TS_Key": hexc("5d646c"), "TS_Screen": hexc("2fbf5f"),
            "TS_Strap": hexc("30250f"), "TS_Accent": HAZARD,
            "TS_Charge": hexc("6d6250"), "TS_Wire": hexc("8f1f1f"),
            "TS_Metal": STEEL_LIGHT},
    surfaces={"TS_Case": "metal", "TS_Panel": "rubber", "TS_Key": "rubber",
              "TS_Screen": "flat", "TS_Strap": "fabric", "TS_Accent": "metal",
              "TS_Charge": "fabric", "TS_Wire": "rubber", "TS_Metal": "metal"},
),

"defusekit": dict(
    kind="device", space="proc", src=None, proc="defusekit",
    length=0.24, axis="x",
    note="original tool roll: canvas pouch, buckled flap, wire cutters and a "
         "driver standing in the tool loops (procedural)",
    accs=[],
    colors={"TS_Canvas": hexc("4a4632"), "TS_CanvasDark": hexc("332f21"),
            "TS_Strap": hexc("26210f"), "TS_Buckle": hexc("9aa0a6"),
            "TS_Tool": hexc("6f767d"), "TS_ToolGrip": hexc("9c2118"),
            "TS_Accent": hexc("c9a227")},
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
        cyl("rim_top", body_r * 1.05, 0.10, (0, 0, body_h * 0.5 - 0.05),
            mats["band"], segs=14),
        cyl("rim_bot", body_r * 1.05, 0.10, (0, 0, -body_h * 0.5 + 0.05),
            mats["band"], segs=14),
        cyl("waist", body_r * 1.03, 0.13, (0, 0, 0.02), mats["band"], segs=14),
    ]
    for k, z in enumerate((-0.42, 0.28, 0.60)):
        for i in range(6):
            a = 2 * math.pi * (i / 6.0) + (0.52 if k == 1 else 0.0)
            parts.append(cyl(f"port{k}_{i}", 0.085, 0.12,
                             (body_r * 0.96 * math.cos(a),
                              body_r * 0.96 * math.sin(a), z),
                             mats["port"], segs=6,
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
        cyl("rim_top", body_r * 1.05, 0.11, (0, 0, body_h * 0.5 - 0.055),
            mats["band"], segs=16),
        cyl("rim_bot", body_r * 1.05, 0.11, (0, 0, -body_h * 0.5 + 0.055),
            mats["band"], segs=16),
        box("label", (body_r * 1.30, 0.06, 0.30), (0, -body_r * 0.93, 0.02),
            mats["accent"]),
    ]
    cap_z = body_h * 0.5 + 0.10
    parts.append(cyl("cap", body_r * 0.86, 0.20, (0, 0, cap_z), mats["port"],
                     segs=16, r2=body_r * 0.70))
    for i in range(8):
        a = 2 * math.pi * i / 8.0
        parts.append(box(f"rib{i}", (0.055, body_r * 0.60, 0.09),
                         (0.42 * body_r * math.cos(a),
                          0.42 * body_r * math.sin(a), cap_z + 0.13),
                         mats["band"], rot=(0, 0, -a)))
    for i in range(6):
        a = 2 * math.pi * i / 6.0
        parts.append(cyl(f"vent{i}", 0.075, 0.10,
                         (body_r * 0.97 * math.cos(a),
                          body_r * 0.97 * math.sin(a), -body_h * 0.30),
                         mats["port"], segs=6, rot=(0, math.radians(90), -a)))
    parts += _fuse_assembly(mats, cap_z + 0.10, 0.92)
    return parts


def build_bomb(rec):
    """Original plantable demolition charge.

    A ribbed equipment case with a keypad and LED strip on a tilted top plate,
    a whip antenna, two cargo straps and two shaped-charge blocks wired into
    the case. Original silhouette; nothing is traced from any commercial game.
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
        parts.append(box(f"rib{i}", (W * 1.04, 0.055, H * 0.86),
                         (0, D * t, H * 0.48), m_panel))
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(box(f"bump{sx}{sy}", (0.075, 0.075, H * 1.03),
                             (sx * W * 0.5, sy * D * 0.5, H * 0.5), m_accent))
    pz = H + 0.035
    parts.append(box("panel", (W * 0.84, D * 0.60, 0.07), (0, -D * 0.16, pz),
                     m_panel, rot=(math.radians(-7), 0, 0)))
    parts.append(box("screen_bezel", (W * 0.70, D * 0.22, 0.03),
                     (0, -D * 0.36, pz + 0.045), m_metal,
                     rot=(math.radians(-7), 0, 0)))
    parts.append(box("screen", (W * 0.60, D * 0.16, 0.035),
                     (0, -D * 0.36, pz + 0.062), m_screen,
                     rot=(math.radians(-7), 0, 0)))
    for r in range(4):
        for c in range(3):
            parts.append(box(f"key{r}{c}", (0.055, 0.055, 0.032),
                             ((c - 1) * 0.15, -D * 0.14 + r * 0.115,
                              pz + 0.055 + r * 0.014), m_key,
                             rot=(math.radians(-7), 0, 0)))
    parts.append(cyl("lamp", 0.045, 0.05, (W * 0.31, -D * 0.45, pz + 0.06),
                     m_accent, segs=8))
    parts.append(cyl("ant_base", 0.055, 0.09, (W * 0.36, D * 0.40, H + 0.04),
                     m_metal, segs=8))
    parts.append(cyl("antenna", 0.024, 0.70, (W * 0.40, D * 0.44, H + 0.41),
                     m_panel, segs=6, rot=(math.radians(-9), 0, 0), r2=0.012))
    parts.append(sphere("ant_tip", 0.037, (W * 0.435, D * 0.49, H + 0.75),
                        m_accent, segs=8, rings=5))
    for sy in (-0.30, 0.30):
        parts.append(box(f"strap{sy}", (W * 1.07, 0.10, H * 1.07),
                         (0, D * sy, H * 0.5), m_strap))
        parts.append(box(f"buckle{sy}", (0.11, 0.14, 0.055),
                         (0, D * sy, H * 1.07), m_metal))
    for i, sx in enumerate((-1, 1)):
        parts.append(box(f"charge{i}", (0.20, 0.12, H * 0.62),
                         (sx * 0.19, -D * 0.55, H * 0.44), m_charge))
        parts.append(box(f"charge_band{i}", (0.215, 0.05, H * 0.20),
                         (sx * 0.19, -D * 0.55, H * 0.44), m_accent))
        parts.append(cyl(f"wire{i}", 0.018, 0.32,
                         (sx * 0.19, -D * 0.45, H * 0.80), m_wire, segs=6,
                         rot=(math.radians(58), 0, 0)))
    parts.append(box("handle_l", (0.05, 0.05, 0.14),
                     (-W * 0.30, D * 0.20, H + 0.07), m_metal))
    parts.append(box("handle_r", (0.05, 0.05, 0.14),
                     (W * 0.30, D * 0.20, H + 0.07), m_metal))
    parts.append(box("handle_bar", (W * 0.68, 0.05, 0.045),
                     (0, D * 0.20, H + 0.15), m_strap))
    return parts


def build_defusekit(rec):
    """Original defuse kit: a canvas tool roll with cutters and a driver."""
    m_canvas = _material("TS_Canvas", (0.22, 0.21, 0.14))
    m_dark = _material("TS_CanvasDark", (0.13, 0.12, 0.08))
    m_strap = _material("TS_Strap", (0.10, 0.08, 0.03))
    m_buckle = _material("TS_Buckle", (0.49, 0.51, 0.53))
    m_tool = _material("TS_Tool", (0.31, 0.34, 0.37))
    m_grip = _material("TS_ToolGrip", (0.42, 0.07, 0.05))
    m_accent = _material("TS_Accent", (0.78, 0.63, 0.15))

    W, D, H = 0.60, 0.34, 0.40
    parts = [
        box("pouch", (W, D, H), (0, 0, H * 0.5), m_canvas),
        box("pouch_front", (W * 0.92, 0.05, H * 0.62), (0, -D * 0.5, H * 0.42),
            m_dark),
        box("seam_l", (0.05, D * 1.03, H * 1.03), (-W * 0.5, 0, H * 0.5), m_dark),
        box("seam_r", (0.05, D * 1.03, H * 1.03), (W * 0.5, 0, H * 0.5), m_dark),
        box("flap", (W * 1.03, D * 0.74, 0.05), (0, D * 0.16, H + 0.03), m_dark,
            rot=(math.radians(-12), 0, 0)),
        box("flap_lip", (W * 1.03, 0.05, 0.10), (0, -D * 0.18, H + 0.015),
            m_canvas),
        box("strap", (0.13, D * 1.08, 0.035), (-W * 0.22, 0, H + 0.06), m_strap),
        box("buckle", (0.16, 0.10, 0.05), (-W * 0.22, -D * 0.44, H + 0.05),
            m_buckle),
    ]
    for i, sx in enumerate((-0.30, 0.02, 0.30)):
        parts.append(box(f"loop{i}", (0.10, 0.045, H * 0.34),
                         (W * sx, -D * 0.55, H * 0.55), m_strap))
    # Wire cutters standing in the right loop: jaws up, red grips down.
    cx = W * 0.30
    parts += [
        box("cut_jaw_l", (0.045, 0.05, 0.30), (cx - 0.035, -D * 0.53, H + 0.24),
            m_tool, rot=(0, math.radians(-9), 0)),
        box("cut_jaw_r", (0.045, 0.05, 0.30), (cx + 0.035, -D * 0.53, H + 0.24),
            m_tool, rot=(0, math.radians(9), 0)),
        cyl("cut_pivot", 0.055, 0.07, (cx, -D * 0.53, H + 0.09), m_buckle,
            segs=8, rot=(0, math.radians(90), 0)),
        box("cut_grip_l", (0.055, 0.06, 0.26), (cx - 0.055, -D * 0.53, H - 0.06),
            m_grip, rot=(0, math.radians(11), 0)),
        box("cut_grip_r", (0.055, 0.06, 0.26), (cx + 0.055, -D * 0.53, H - 0.06),
            m_grip, rot=(0, math.radians(-11), 0)),
    ]
    # Screwdriver in the left loop.
    dx = -W * 0.30
    parts += [
        cyl("drv_grip", 0.055, 0.24, (dx, -D * 0.53, H + 0.02), m_grip, segs=10),
        cyl("drv_shaft", 0.022, 0.30, (dx, -D * 0.53, H + 0.28), m_buckle,
            segs=6),
        box("drv_tip", (0.05, 0.02, 0.05), (dx, -D * 0.53, H + 0.44), m_tool),
        box("blade", (0.07, 0.03, 0.34), (W * 0.02, -D * 0.55, H + 0.17),
            m_accent, rot=(0, math.radians(4), 0)),
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

    The source packs are not in a shared scale -- the "flashlight" is a third
    as long as a pistol and as wide as a rifle receiver -- so accessory size is
    always expressed as a ratio of one of the gun's own extents:
      fit_len    accessory length  = f * gun length (along the barrel)
      fit_width  accessory width   = f * gun width  (lateral)
      fit_height accessory height  = f * gun height
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
    """Position an accessory on a source-space gun, from the gun's geometry."""
    xmin, xmax, span, axis_y, axis_z = _source_barrel_ref(gun)
    s = _fit_scale(gun, acc, spec)
    if abs(s - 1.0) > 1e-6:
        acc.scale = (s, s, s)
        _apply(acc, location=False, rotation=False, scale=True)
    mount = spec["mount"]
    alo, ahi = _bbox(acc)

    if mount == "muzzle":
        acc.location = (xmax - spec.get("inset", 0.02) * span - alo.x,
                        axis_y, axis_z)
    elif mount == "rail":
        x = xmin + spec["along"] * span
        top = _extreme_z_at(gun, x - 0.10 * span, x + 0.10 * span, True)
        acc.location = (x - (alo.x + ahi.x) * 0.5, axis_y,
                        top + spec.get("rise", 0.0) * span - alo.z)
    elif mount == "under_barrel":
        x = xmin + spec["along"] * span
        bot = _extreme_z_at(gun, x - 0.07 * span, x + 0.07 * span, False)
        acc.location = (x - (alo.x + ahi.x) * 0.5, axis_y,
                        bot + spec.get("drop", 0.05) * span - ahi.z)
    else:
        raise ValueError(f"unknown accessory mount: {mount}")
    _apply(acc)


def add_boxmag(gun):
    """A 100-round box magazine for the heavy. Source space, procedural."""
    xmin, _xmax, span, axis_y, _axis_z = _source_barrel_ref(gun)
    bot = _extreme_z_at(gun, xmin + 0.34 * span, xmin + 0.52 * span, False)
    m = _material("TS_Ammo", (0.22, 0.24, 0.17))
    m2 = _material("TS_Accent", (0.34, 0.26, 0.10))
    w = span * 0.075
    parts = [
        box("mag_body", (span * 0.20, w, span * 0.125),
            (xmin + 0.43 * span, axis_y, bot - span * 0.055), m),
        box("mag_lip", (span * 0.155, w * 0.86, span * 0.035),
            (xmin + 0.43 * span, axis_y, bot + span * 0.004), m),
        box("mag_latch", (span * 0.035, w * 1.04, span * 0.055),
            (xmin + 0.315 * span, axis_y, bot - span * 0.05), m2),
        box("belt", (span * 0.055, w * 0.55, span * 0.024),
            (xmin + 0.545 * span, axis_y, bot + span * 0.012), m2),
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
    c = _centroid(tip)
    axis_x, axis_z = c.x, c.z
    muzzle = Vector((axis_x, y_front, axis_z))

    if kind == "grenade" or kind == "device":
        # "Muzzle" on a thrown/planted object = the working end (fuse/antenna).
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

    # GripR: the hand. Rear-biased centroid of the low geometry behind the
    # trigger for guns (a magazine hangs low too but sits forward of the grip,
    # so the rear bias rejects it); the handle centroid for a knife. Heights
    # are measured *within the rear region* so a bipod hanging off the front
    # cannot drag the threshold down.
    if kind == "gun":
        rear = [v for v in vs if v.y >= y_front + 0.42 * L] or vs
        zr_bot = min(v.z for v in rear)
        hr = max(1e-6, max(v.z for v in rear) - zr_bot)
        low = [v for v in rear if v.z <= zr_bot + 0.38 * hr]
        if len(low) < 8:
            low = [v for v in rear if v.z <= zr_bot + 0.65 * hr] or rear
        y_cut = _pct([v.y for v in low], 0.55)
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
        zl = _pct([v.z for v in under], 0.45)
        zl = max(zl, axis_z - 0.55 * H)
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
            place_accessory(gun, acc, spec)
            joins.append(acc)
            sources.append(spec["src"])
        gun = bc.join_meshes(joins, wid)

    merge_duplicate_materials([gun])
    _apply(gun)

    orient(gun, resolve_space(rec))
    scale = bc.normalize_size(gun, rec["length"], rec["axis"])
    tris = fit_tris(gun, TRI_BUDGET)

    marks = _markers(gun, rec["kind"])

    # Origin: the right hand for held weapons, the base centre for things that
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

    slots = bc.build_atlas_for([gun], atlas_png, overrides=rec.get("colors"),
                               surfaces=rec.get("surfaces"))
    missing = [m for m in (rec.get("colors") or {}) if m not in slots]
    if missing:
        print(f"    WARNING colour overrides matched nothing: {missing}")
    unstyled = [m for m in slots if m not in (rec.get("colors") or {})]
    if unstyled:
        print(f"    WARNING materials with no colour override: {unstyled}")
    bc.atlas_remap([gun], slots, atlas_png, material_name=f"TS_{wid}")

    for name, loc in marks.items():
        bc.add_marker(name, loc, parent=gun)

    if debug_markers:
        dbg = _material("TS_DebugMark", (1.0, 0.0, 0.35))
        size = max(0.006, min(hi.y - lo.y, 0.5) * 0.022)
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
    print(f"[done] built {built} weapon(s), "
          f"{sum(manifest['weapons'][w]['tris'] for w in manifest['weapons'])} "
          f"tris total across the set")


main()
