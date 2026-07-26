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
The ten guns are deliberately built from ten different source silhouettes and
given ten different finishes (blued steel, parkerised grey, polymer black,
walnut furniture, desert tan, olive drab) so they never read as recolours.

--------------------------------------------------------------------------
Conventions produced by this script (see docs/ASSET_PIPELINE.md)
--------------------------------------------------------------------------
Blender working space after `_orient`: barrel along -Y, up +Z, weapon-right +X.
`export_glb(export_yup=True)` maps Blender (x, y, z) -> glTF/Godot (x, z, -y),
so the exported model has its **barrel along +Z, up +Y, right +X** and the grip
hanging down -Y, exactly as the pipeline doc requires.

The mesh origin is the **GripR** point for anything held in a hand (guns,
knife) and the **base centre** for objects that sit on the ground or in a palm
(grenades, bomb, defuse kit), so a mount node needs no magic offset.

Markers are Empties parented to the mesh, exported as Node3D:
Muzzle / ShellPort / GripR / GripL / Sight. Every one of them is derived from
the actual vertex cloud (see `_markers`), never from a hardcoded guess.
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


def rgb(r: float, g: float, b: float):
    """sRGB 0..1 -> linear, so palette.py's linear->sRGB round-trips exactly."""
    return (_srgb_to_linear_ch(r), _srgb_to_linear_ch(g), _srgb_to_linear_ch(b))


def hexc(s: str):
    s = s.lstrip("#")
    return rgb(int(s[0:2], 16) / 255.0, int(s[2:4], 16) / 255.0, int(s[4:6], 16) / 255.0)


# Shared finish vocabulary. Each weapon picks a different mix of these.
POLYMER_BLACK = hexc("23262b")
POLYMER_GREY = hexc("3b4048")
BLUED_STEEL = hexc("2b3340")
PARKERIZED = hexc("55585a")
STAINLESS = hexc("9aa0a6")
GUNMETAL = hexc("41464c")
WALNUT = hexc("6b4526")
WALNUT_DARK = hexc("46291444"[:6])
DESERT_TAN = hexc("b09468")
FDE = hexc("7a6a4f")
OLIVE = hexc("4d5636")
OLIVE_DARK = hexc("343a24")
SCOPE_GLASS = hexc("2d4a6b")
RUBBER_BLACK = hexc("1b1d20")
BRASS = hexc("8a6a2c")
HAZARD = hexc("c8531f")
STEEL_LIGHT = hexc("7d8288")


# ===========================================================================
#  Weapon recipes
# ===========================================================================
# kind      : "gun" | "melee" | "grenade" | "device"
# src       : source file relative to /opt/assets_cc0 (None => fully procedural)
# space     : source orientation family, "ug" (ultimategun) or "ts" (toonshooter)
# length    : final size in metres, measured along the axis named by `axis`
# axis      : "y" = along the barrel (guns/knife), "z" = height (grenades)
# accs      : accessory recipes joined into the mesh before atlasing
# colors    : material name -> sRGB colour override
# surfaces  : material name -> palette surface treatment
WEAPONS: dict = {

# ------------------------------- PISTOLS ---------------------------------
"p9": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_2.fbx",
    length=0.22, axis="y",
    note="issue sidearm: polymer frame, parkerised slide",
    accs=[],
    colors={"Black": POLYMER_BLACK, "DarkMetal": hexc("31353a"),
            "LightMetal": hexc("6e7378"), "Metal": PARKERIZED,
            "Wood": hexc("2c2f33")},
    surfaces={"Wood": "rubber", "Black": "rubber"},
),

"talon": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_4.fbx",
    length=0.235, axis="y",
    note="large-frame hand cannon: blued slide, desert tan polymer frame",
    accs=[],
    colors={"Black": DESERT_TAN, "LightMetal": hexc("8d949c"),
            "Metal": BLUED_STEEL},
    surfaces={"Black": "rubber"},
),

"snub": dict(
    kind="gun", space="ug", src="ultimategun/FBX/Pistol_5.fbx",
    length=0.225, axis="y",
    note="compact burst machine pistol: two-tone stainless over black polymer, "
         "underbarrel light module",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.72, drop=0.55, scale=0.85)],
    colors={"Black": POLYMER_BLACK, "LightMetal": STAINLESS,
            "Metal": hexc("6a7076"), "Glass": hexc("cfd8b8")},
    surfaces={"Black": "rubber", "Glass": "flat"},
),

# --------------------------------- SMGs ----------------------------------
"viper45": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SubmachineGun_4.fbx",
    length=0.60, axis="y",
    note="boxy .45 SMG with vertical foregrip and a stubby suppressor",
    accs=[dict(src="ultimategun/FBX/Accessories/Silencer_Short.fbx",
               mount="muzzle", inset=0.10, scale=1.0)],
    colors={"Black": POLYMER_BLACK, "DarkMetal": hexc("2a2d31"),
            "Grey": hexc("4a4f55"), "Metal": GUNMETAL},
    surfaces={"Black": "rubber"},
),

"mk9": dict(
    kind="gun", space="ug", src="ultimategun/FBX/SubmachineGun_5.fbx",
    length=0.62, axis="y",
    note="long thin SMG, wire folding stock, top rail + optic",
    accs=[dict(src="ultimategun/FBX/Accessories/Scope_3.fbx",
               mount="rail", along=0.50, rise=0.02, scale=0.42)],
    colors={"Black": hexc("2f3a33"), "DarkMetal": hexc("39423a"),
            "Grey": hexc("6a7266"), "Metal": hexc("515a4e"),
            "Glass": SCOPE_GLASS},
    surfaces={"Black": "rubber", "Glass": "flat"},
),

# -------------------------------- RIFLES ---------------------------------
"ar77": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle2_4.fbx",
    length=0.90, axis="y",
    note="attacker carbine: AR pattern, carry handle, FDE furniture, "
         "underbarrel light",
    accs=[dict(src="ultimategun/FBX/Accessories/Flashlight.fbx",
               mount="under_barrel", along=0.78, drop=0.45, scale=1.05)],
    colors={"DarkMetal": hexc("24262a"), "Main": FDE,
            "MainDark": hexc("4c4132"), "MainLight": hexc("94815f"),
            "Metal": hexc("36393d"), "Glass": hexc("d7e0c0")},
    surfaces={"Main": "rubber", "MainDark": "rubber", "MainLight": "rubber",
              "Glass": "flat"},
),

"br52": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle_2.fbx",
    length=0.92, axis="y",
    note="defender rifle: long-stroke pattern, walnut furniture, blued steel, "
         "side-rail optic",
    accs=[dict(src="ultimategun/FBX/Accessories/Scope_3.fbx",
               mount="rail", along=0.46, rise=0.03, scale=0.55)],
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
               mount="under_barrel", along=0.80, drop=0.10, scale=0.55)],
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
               mount="under_barrel", along=0.62, drop=0.30, scale=1.0)],
    colors={"Black": POLYMER_BLACK, "DarkMetal": hexc("1e2228"),
            "LightMetal": hexc("737a82"), "Metal": BLUED_STEEL,
            "Glass": hexc("dfe8c8")},
    surfaces={"Black": "rubber", "Glass": "flat"},
),

"mule": dict(
    kind="gun", space="ug", src="ultimategun/FBX/AssaultRifle_4.fbx",
    length=1.05, axis="y",
    note="belt-fed heavy: parkerised receiver, 100-rd box magazine, bipod, "
         "heat-shrouded heavy barrel",
    accs=[dict(src="ultimategun/FBX/Accessories/Bipod.fbx",
               mount="under_barrel", along=0.86, drop=0.06, scale=0.70),
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
    note="stun grenade: tall steel canister with three rings of emission ports",
    accs=[],
    colors={"TS_Body": hexc("8e949a"), "TS_Band": hexc("1d1f22"),
            "TS_Port": hexc("15171a"), "TS_Fuse": hexc("55five"[:5] + "b"),
            "TS_Accent": hexc("c9a227")},
    surfaces={"TS_Body": "metal", "TS_Band": "rubber", "TS_Port": "metal",
              "TS_Fuse": "metal", "TS_Accent": "metal"},
),

"smoke": dict(
    kind="grenade", space="proc", src=None, proc="smoke",
    length=0.118, axis="z",
    note="smoke canister: squat wide body, ribbed emitter cap, olive over grey",
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
    note="original demolition charge: ribbed case, keypad + LED strip, "
         "whip antenna, cargo straps, two shaped-charge blocks",
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
    length=0.235, axis="y",
    note="original tool roll: canvas pouch, flap + buckle, wire cutters and "
         "driver standing in the tool loops",
    colors={"TS_Canvas": hexc("4a4632"), "TS_CanvasDark": hexc("332f21"),
            "TS_Strap": hexc("26210f"), "TS_Buckle": hexc("9aa0a6"),
            "TS_Tool": hexc("6f767d"), "TS_ToolGrip": hexc("9c2118"),
            "TS_Accent": hexc("c9a227")},
    accs=[],
    surfaces={"TS_Canvas": "fabric", "TS_CanvasDark": "fabric",
              "TS_Strap": "fabric", "TS_Buckle": "metal", "TS_Tool": "metal",
              "TS_ToolGrip": "rubber", "TS_Accent": "metal"},
),
}

# Fix the two placeholder-ish literals above in a readable way.
WEAPONS["flash"]["colors"]["TS_Fuse"] = hexc("55595b")
WALNUT_DARK = hexc("462914")


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


def _bbox(obj):
    """(lo, hi) of the object's world bounding box."""
    pts = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts),
                 min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts),
                 max(p.z for p in pts)))
    return lo, hi


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
    materials. Without this the atlas burns a slot per copy and per-weapon
    colour overrides silently miss the ``.00N`` variants.
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
    # Rename survivors to their base name so recipes can address them.
    for base, m in canon.items():
        if m.name != base and bpy.data.materials.get(base) in (None, m):
            m.name = base


def import_source(path_rel: str, name: str):
    """Import one CC0 file, join its meshes, drop everything else."""
    before = set(bpy.data.objects)
    bc.import_any(os.path.join(CC0, path_rel))
    new = [o for o in bpy.data.objects if o not in before]
    new_meshes = [o for o in new if o.type == "MESH"]
    obj = bc.join_meshes(new_meshes, name)
    bc.delete_objects([o for o in new if o.type != "MESH"])
    _apply(obj)
    return obj


def fit_tris(obj, budget: int) -> int:
    """Decimate until the mesh fits the triangle budget.

    Coplanar dissolve first (free: these source meshes are flat-shaded, so
    merging coplanar fans changes nothing visually), collapse only if needed.
    """
    n = _obj_tris(obj)
    if n <= budget:
        return n
    _activate(obj)
    m = obj.modifiers.new("planar", "DECIMATE")
    m.decimate_type = "DISSOLVE"
    m.angle_limit = math.radians(1.0)
    bpy.ops.object.modifier_apply(modifier=m.name)
    n2 = _obj_tris(obj)
    if n2 > budget:
        m = obj.modifiers.new("collapse", "DECIMATE")
        m.decimate_type = "COLLAPSE"
        m.ratio = max(0.05, (budget / float(n2)) * 0.98)
        bpy.ops.object.modifier_apply(modifier=m.name)
    n3 = _obj_tris(obj)
    print(f"    decimate {n} -> {n2} -> {n3} tris (budget {budget})")
    return n3


# ===========================================================================
#  Procedural primitives
# ===========================================================================

def _prim(name: str, mat, verts_fn) -> object:
    bm = bmesh.new()
    verts_fn(bm)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    for p in me.polygons:
        p.material_index = 0
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    return ob


def box(name, size, loc=(0, 0, 0), mat=None, rot=(0, 0, 0)):
    ob = _prim(name, mat, lambda bm: bmesh.ops.create_cube(bm, size=1.0))
    ob.scale = size
    ob.location = loc
    ob.rotation_euler = rot
    return ob


def cyl(name, r, depth, loc=(0, 0, 0), mat=None, segs=12, rot=(0, 0, 0), r2=None):
    if r2 is None:
        r2 = r
    ob = _prim(name, mat, lambda bm: bmesh.ops.create_cone(
        bm, cap_ends=True, cap_tris=False, segments=segs,
        radius1=r, radius2=r2, depth=depth))
    ob.location = loc
    ob.rotation_euler = rot
    return ob


def sphere(name, r, loc=(0, 0, 0), mat=None, segs=10, rings=6):
    ob = _prim(name, mat, lambda bm: bmesh.ops.create_uvsphere(
        bm, u_segments=segs, v_segments=rings, radius=r))
    ob.location = loc
    return ob


def ring(name, r, thick, loc=(0, 0, 0), mat=None, major=10, minor=4,
         rot=(0, 0, 0)):
    ob = _prim(name, mat, lambda bm: bmesh.ops.create_cone(bm, segments=1,
                                                           radius1=0, radius2=0,
                                                           depth=0))
    # create_cone with zero radius leaves nothing; build the torus properly.
    bm = bmesh.new()
    for i in range(major):
        a = 2 * math.pi * i / major
        for j in range(minor):
            b = 2 * math.pi * j / minor
            rr = r + thick * math.cos(b)
            bm.verts.new((rr * math.cos(a), rr * math.sin(a),
                          thick * math.sin(b)))
    bm.verts.ensure_lookup_table()
    for i in range(major):
        for j in range(minor):
            a0 = i * minor + j
            a1 = i * minor + (j + 1) % minor
            b0 = ((i + 1) % major) * minor + j
            b1 = ((i + 1) % major) * minor + (j + 1) % minor
            bm.faces.new((bm.verts[a0], bm.verts[a1], bm.verts[b1], bm.verts[b0]))
        # noqa
    me = ob.data
    bm.to_mesh(me)
    bm.free()
    ob.location = loc
    ob.rotation_euler = rot
    return ob


# ===========================================================================
#  Procedural builds
# ===========================================================================
# All procedural geometry is authored directly in the final working space:
#   -Y = forward (barrel / "front"),  +Z = up,  +X = weapon right.

def _fuse_assembly(mats, body_top_z: float, body_r: float, scale: float):
    """Grenade fuse: plug, striker lever (spoon), safety pin and pull ring.

    Shared by the flash and smoke canisters so the four grenades read as one
    family alongside the two CC0 bodies.
    """
    fuse, accent, band = mats["fuse"], mats["accent"], mats["band"]
    s = scale
    parts = [
        cyl("fuse_neck", 0.30 * s, 0.16 * s, (0, 0, body_top_z + 0.07 * s),
            fuse, segs=10),
        cyl("fuse_plug", 0.20 * s, 0.22 * s, (0, 0, body_top_z + 0.24 * s),
            fuse, segs=10),
        cyl("fuse_cap", 0.26 * s, 0.06 * s, (0, 0, body_top_z + 0.37 * s),
            accent, segs=10),
        # Striker lever: a flat strip over the cap that folds down the side.
        box("spoon_top", (0.10 * s, 0.44 * s, 0.035 * s),
            (0, 0.14 * s, body_top_z + 0.38 * s), band),
        box("spoon_side", (0.09 * s, 0.05 * s, 0.62 * s),
            (0, 0.34 * s, body_top_z - 0.16 * s), band,
            rot=(math.radians(-6), 0, 0)),
        # Safety pin through the plug, with the pull ring hanging off it.
        cyl("pin", 0.035 * s, 0.46 * s, (0, -0.02 * s, body_top_z + 0.30 * s),
            accent, segs=6, rot=(0, math.radians(90), 0)),
        ring("pull_ring", 0.17 * s, 0.035 * s,
             (-0.30 * s, -0.02 * s, body_top_z + 0.30 * s), accent,
             major=10, minor=4, rot=(0, math.radians(90), 0)),
    ]
    return parts


def build_flash(rec):
    """Tall steel stun canister with three rings of emission ports."""
    mats = {
        "body": _material("TS_Body", (0.55, 0.57, 0.60)),
        "band": _material("TS_Band", (0.11, 0.12, 0.13)),
        "port": _material("TS_Port", (0.08, 0.09, 0.10)),
        "fuse": _material("TS_Fuse", (0.33, 0.34, 0.35)),
        "accent": _material("TS_Accent", (0.78, 0.63, 0.15)),
    }
    parts = []
    body_h, body_r = 1.55, 0.46
    parts.append(cyl("body", body_r, body_h, (0, 0, 0), mats["body"], segs=14))
    parts.append(cyl("rim_top", body_r * 1.04, 0.10, (0, 0, body_h * 0.5 - 0.05),
                     mats["band"], segs=14))
    parts.append(cyl("rim_bot", body_r * 1.04, 0.10, (0, 0, -body_h * 0.5 + 0.05),
                     mats["band"], segs=14))
    parts.append(cyl("waist", body_r * 1.02, 0.13, (0, 0, 0.02),
                     mats["band"], segs=14))
    # Three rings of six recessed ports -- the flashbang read.
    for k, z in enumerate((-0.42, 0.30, 0.62)):
        for i in range(6):
            a = 2 * math.pi * (i / 6.0) + (0.5 if k == 1 else 0.0)
            parts.append(cyl(f"port{k}_{i}", 0.085, 0.10,
                             (body_r * 0.94 * math.cos(a),
                              body_r * 0.94 * math.sin(a), z),
                             mats["port"], segs=6,
                             rot=(0, math.radians(90), -a)))
    parts += _fuse_assembly(mats, body_h * 0.5, body_r, 1.0)
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
    parts = []
    body_h, body_r = 1.05, 0.62
    parts.append(cyl("body", body_r, body_h, (0, 0, 0), mats["body"], segs=16))
    parts.append(cyl("rim_top", body_r * 1.05, 0.11, (0, 0, body_h * 0.5 - 0.055),
                     mats["band"], segs=16))
    parts.append(cyl("rim_bot", body_r * 1.05, 0.11, (0, 0, -body_h * 0.5 + 0.055),
                     mats["band"], segs=16))
    parts.append(box("label", (body_r * 1.35, 0.06, 0.30), (0, -body_r * 0.92, 0.02),
                     mats["accent"]))
    # Emitter cap: a stepped disc with radial vent ribs.
    cap_z = body_h * 0.5 + 0.10
    parts.append(cyl("cap", body_r * 0.86, 0.20, (0, 0, cap_z), mats["port"],
                     segs=16, r2=body_r * 0.72))
    for i in range(8):
        a = 2 * math.pi * i / 8.0
        parts.append(box(f"rib{i}", (0.055, body_r * 0.62, 0.09),
                         (0.5 * body_r * math.cos(a), 0.5 * body_r * math.sin(a),
                          cap_z + 0.13),
                         mats["band"], rot=(0, 0, -a)))
    # Base vents so smoke has somewhere to go.
    for i in range(6):
        a = 2 * math.pi * i / 6.0
        parts.append(cyl(f"vent{i}", 0.075, 0.09,
                         (body_r * 0.95 * math.cos(a),
                          body_r * 0.95 * math.sin(a), -body_h * 0.30),
                         mats["port"], segs=6, rot=(0, math.radians(90), -a)))
    parts += _fuse_assembly(mats, cap_z + 0.10, body_r, 0.92)
    return parts


def build_bomb(rec):
    """Original plantable demolition charge.

    A ribbed equipment case with a keypad + LED strip on the sloped top face,
    a whip antenna, two cargo straps and two shaped-charge blocks wired into
    the case. Deliberately nothing like any commercial game's bomb prop.
    Authored so +Z is up and the base sits on z = 0: it is a ground object.
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

    W, D, H = 0.62, 1.00, 0.42      # local units; normalised later
    parts = []
    parts.append(box("case", (W, D, H), (0, 0, H * 0.5), m_case))
    # Ribbed shell: raised ribs across the case give it a moulded look.
    for i, t in enumerate((-0.34, -0.12, 0.12, 0.34)):
        parts.append(box(f"rib{i}", (W * 1.03, 0.055, H * 0.86),
                         (0, D * t, H * 0.48), m_panel))
    # Corner bumpers.
    for sx in (-1, 1):
        for sy in (-1, 1):
            parts.append(box(f"bump{sx}{sy}", (0.075, 0.075, H * 1.02),
                             (sx * W * 0.5, sy * D * 0.5, H * 0.5), m_accent))
    # Control panel: a raised plate on the top face, tilted toward the player.
    pz = H + 0.035
    parts.append(box("panel", (W * 0.82, D * 0.58, 0.07),
                     (0, -D * 0.16, pz), m_panel,
                     rot=(math.radians(-7), 0, 0)))
    # LED strip / display.
    parts.append(box("screen", (W * 0.60, D * 0.16, 0.035),
                     (0, -D * 0.35, pz + 0.055), m_screen,
                     rot=(math.radians(-7), 0, 0)))
    parts.append(box("screen_bezel", (W * 0.68, D * 0.21, 0.03),
                     (0, -D * 0.35, pz + 0.04), m_metal,
                     rot=(math.radians(-7), 0, 0)))
    # 4 x 3 keypad.
    for r in range(4):
        for c in range(3):
            parts.append(box(f"key{r}{c}", (0.055, 0.055, 0.03),
                             ((c - 1) * 0.145, -D * 0.13 + r * 0.115,
                              pz + 0.055 + r * 0.012), m_key,
                             rot=(math.radians(-7), 0, 0)))
    # Status lamp + whip antenna at the back right corner.
    parts.append(cyl("lamp", 0.045, 0.05, (W * 0.30, -D * 0.44, pz + 0.06),
                     m_accent, segs=8))
    parts.append(cyl("ant_base", 0.055, 0.09, (W * 0.36, D * 0.40, H + 0.04),
                     m_metal, segs=8))
    parts.append(cyl("antenna", 0.022, 0.68, (W * 0.40, D * 0.42, H + 0.40),
                     m_panel, segs=6, rot=(math.radians(-9), 0, 0), r2=0.012))
    parts.append(sphere("ant_tip", 0.035, (W * 0.435, D * 0.47, H + 0.73),
                        m_accent, segs=8, rings=5))
    # Two cargo straps around the case with buckles.
    for sy in (-0.30, 0.30):
        parts.append(box(f"strap{sy}", (W * 1.06, 0.10, H * 1.06),
                         (0, D * sy, H * 0.5), m_strap))
        parts.append(box(f"buckle{sy}", (0.11, 0.14, 0.055),
                         (0, D * sy, H * 1.06), m_metal))
    # Two shaped-charge blocks strapped to the front face, wired in.
    for i, sx in enumerate((-1, 1)):
        parts.append(box(f"charge{i}", (0.20, 0.11, H * 0.62),
                         (sx * 0.19, -D * 0.55, H * 0.44), m_charge))
        parts.append(box(f"charge_band{i}", (0.215, 0.045, H * 0.20),
                         (sx * 0.19, -D * 0.55, H * 0.44), m_accent))
        parts.append(cyl(f"wire{i}", 0.018, 0.30,
                         (sx * 0.19, -D * 0.44, H * 0.78), m_wire, segs=6,
                         rot=(math.radians(58), 0, 0)))
    # Carry handle.
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
    parts = []
    parts.append(box("pouch", (W, D, H), (0, 0, H * 0.5), m_canvas))
    parts.append(box("pouch_front", (W * 0.92, 0.05, H * 0.62),
                     (0, -D * 0.5, H * 0.42), m_dark))
    parts.append(box("seam_l", (0.05, D * 1.02, H * 1.02),
                     (-W * 0.5, 0, H * 0.5), m_dark))
    parts.append(box("seam_r", (0.05, D * 1.02, H * 1.02),
                     (W * 0.5, 0, H * 0.5), m_dark))
    # Flap folded back over the top, with a buckle strap.
    parts.append(box("flap", (W * 1.02, D * 0.72, 0.05),
                     (0, D * 0.16, H + 0.03), m_dark,
                     rot=(math.radians(-12), 0, 0)))
    parts.append(box("flap_lip", (W * 1.02, 0.05, 0.10),
                     (0, -D * 0.18, H + 0.02), m_canvas))
    parts.append(box("strap", (0.13, D * 1.06, 0.035),
                     (-W * 0.22, 0, H + 0.06), m_strap))
    parts.append(box("buckle", (0.16, 0.10, 0.05),
                     (-W * 0.22, -D * 0.42, H + 0.05), m_buckle))
    # Elastic tool loops on the front.
    for sx in (-0.28, 0.02, 0.30):
        parts.append(box(f"loop{sx}", (0.10, 0.045, H * 0.34),
                         (W * sx, -D * 0.54, H * 0.55), m_strap))
    # Wire cutters standing in the right-hand loops: jaws up, red grips down.
    cx = W * 0.16
    parts.append(box("cut_jaw_l", (0.045, 0.05, 0.30),
                     (cx - 0.035, -D * 0.52, H + 0.24), m_tool,
                     rot=(0, math.radians(-9), 0)))
    parts.append(box("cut_jaw_r", (0.045, 0.05, 0.30),
                     (cx + 0.035, -D * 0.52, H + 0.24), m_tool,
                     rot=(0, math.radians(9), 0)))
    parts.append(cyl("cut_pivot", 0.055, 0.07, (cx, -D * 0.52, H + 0.09),
                     m_buckle, segs=8, rot=(0, math.radians(90), 0)))
    parts.append(box("cut_grip_l", (0.055, 0.06, 0.26),
                     (cx - 0.055, -D * 0.52, H - 0.06), m_grip,
                     rot=(0, math.radians(11), 0)))
    parts.append(box("cut_grip_r", (0.055, 0.06, 0.26),
                     (cx + 0.055, -D * 0.52, H - 0.06), m_grip,
                     rot=(0, math.radians(-11), 0)))
    # Screwdriver in the left loop.
    dx = -W * 0.30
    parts.append(cyl("drv_grip", 0.055, 0.24, (dx, -D * 0.52, H + 0.02),
                     m_grip, segs=10))
    parts.append(cyl("drv_shaft", 0.022, 0.30, (dx, -D * 0.52, H + 0.28),
                     m_buckle, segs=6))
    parts.append(box("drv_tip", (0.05, 0.02, 0.05), (dx, -D * 0.52, H + 0.44),
                     m_tool))
    # Snips / spare blade tucked in the middle loop.
    parts.append(box("blade", (0.07, 0.03, 0.34), (W * 0.02, -D * 0.54, H + 0.16),
                     m_accent, rot=(0, math.radians(4), 0)))
    return parts


PROC_BUILDERS = {
    "flash": build_flash,
    "smoke": build_smoke,
    "bomb": build_bomb,
    "defusekit": build_defusekit,
}


# ===========================================================================
#  Accessory mounting (in source space: +X forward, +Z up, +-Y lateral)
# ===========================================================================

def _source_barrel_ref(obj):
    """Barrel tip / axis of a source-space gun: forward-most vertex cluster."""
    vs = [v.co for v in obj.data.vertices]
    xmax = max(v.x for v in vs)
    xmin = min(v.x for v in vs)
    span = xmax - xmin
    cand = [v for v in vs if v.x >= xmax - 0.03 * span]
    ay = sum(v.y for v in cand) / len(cand)
    az = sum(v.z for v in cand) / len(cand)
    return xmin, xmax, span, ay, az


def _source_top_at(obj, x_lo, x_hi):
    vs = [v.co for v in obj.data.vertices if x_lo <= v.x <= x_hi]
    return max(v.z for v in vs) if vs else 0.0


def _source_bottom_at(obj, x_lo, x_hi):
    vs = [v.co for v in obj.data.vertices if x_lo <= v.x <= x_hi]
    return min(v.z for v in vs) if vs else 0.0


def place_accessory(gun, acc, spec) -> None:
    """Position an accessory on a source-space gun from the gun's geometry."""
    xmin, xmax, span, axis_y, axis_z = _source_barrel_ref(gun)
    s = spec.get("scale", 1.0)
    acc.scale = (s, s, s)
    _apply(acc, location=False, rotation=False, scale=True)
    mount = spec["mount"]

    if mount == "muzzle":
        # Butt the suppressor up against the muzzle, slightly overlapping.
        alo, _ahi = _bbox(acc)
        inset = spec.get("inset", 0.08) * span
        acc.location = (xmax - inset - alo.x, axis_y, axis_z)
    elif mount == "rail":
        x = xmin + spec["along"] * span
        top = _source_top_at(gun, x - 0.10 * span, x + 0.10 * span)
        alo, ahi = _bbox(acc)
        acc.location = (x - (alo.x + ahi.x) * 0.5, axis_y,
                        top + spec.get("rise", 0.0) * span - alo.z)
    elif mount == "under_barrel":
        x = xmin + spec["along"] * span
        bot = _source_bottom_at(gun, x - 0.08 * span, x + 0.08 * span)
        alo, ahi = _bbox(acc)
        acc.location = (x - (alo.x + ahi.x) * 0.5, axis_y,
                        bot - spec.get("drop", 0.2) * (ahi.z - alo.z) - ahi.z)
    else:
        raise ValueError(f"unknown accessory mount: {mount}")
    _apply(acc)


def add_boxmag(gun):
    """A 100-round box magazine, procedural, for the heavy. Source space."""
    xmin, xmax, span, axis_y, axis_z = _source_barrel_ref(gun)
    bot = _source_bottom_at(gun, xmin + 0.34 * span, xmin + 0.52 * span)
    m = _material("TS_Ammo", (0.22, 0.24, 0.17))
    m2 = _material("TS_Accent", (0.34, 0.26, 0.10))
    w = span * 0.055
    parts = [
        box("mag_body", (span * 0.20, w * 2.9, span * 0.115),
            (xmin + 0.42 * span, axis_y, bot - span * 0.055), m),
        box("mag_lip", (span * 0.16, w * 2.4, span * 0.03),
            (xmin + 0.42 * span, axis_y, bot + span * 0.005), m),
        box("mag_latch", (span * 0.035, w * 3.0, span * 0.05),
            (xmin + 0.315 * span, axis_y, bot - span * 0.05), m2),
        # Belt stub feeding into the receiver.
        box("belt", (span * 0.05, w * 1.6, span * 0.022),
            (xmin + 0.535 * span, axis_y, bot + span * 0.012), m2),
    ]
    for p in parts:
        _apply(p)
    return parts


def add_shroud(gun):
    """Ventilated heavy-barrel shroud for the heavy. Source space."""
    xmin, xmax, span, axis_y, axis_z = _source_barrel_ref(gun)
    m = _material("TS_Ammo", (0.22, 0.24, 0.17))
    x0 = xmin + 0.70 * span
    parts = [cyl("shroud", span * 0.026, span * 0.24,
                 (x0 + span * 0.12, axis_y, axis_z), m, segs=10,
                 rot=(0, math.radians(90), 0))]
    for i in range(5):
        parts.append(cyl(f"shroud_vent{i}", span * 0.030, span * 0.014,
                         (x0 + span * 0.03 + i * span * 0.045, axis_y, axis_z),
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

    ultimategun FBX: barrel +X, up +Z          -> rotate -90 deg about Z
    toonshooter glTF guns: barrel -X, up +Z    -> rotate +90 deg about Z
    toonshooter glTF blades: tip +Z, flat +-Y  -> +90 about X, then +90 about Y
    proc: already authored in the working space
    """
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
            return "ts_upright"      # grenades already stand on +Z
        return "ts_gun"
    return "ug"


# ===========================================================================
#  Marker derivation -- everything below is computed from the vertex cloud
# ===========================================================================

def _pct(values, q: float) -> float:
    vs = sorted(values)
    if not vs:
        return 0.0
    i = min(len(vs) - 1, max(0, int(round(q * (len(vs) - 1)))))
    return vs[i]


def _markers(obj, kind: str) -> dict:
    """Derive the five attachment points from the mesh itself.

    Working space: -Y forward, +Z up, +X weapon-right.
    """
    vs = [v.co.copy() for v in obj.data.vertices]
    ys = [v.y for v in vs]
    zs = [v.z for v in vs]
    y_front, y_back = min(ys), max(ys)
    z_bot, z_top = min(zs), max(zs)
    L = max(1e-6, y_back - y_front)
    H = max(1e-6, z_top - z_bot)

    def band(lo_f, hi_f):
        return [v for v in vs if y_front + lo_f * L <= v.y <= y_front + hi_f * L]

    # --- Muzzle: centroid of the forward-most 3% of the vertex cloud, pinned
    #     to the exact forward extreme. For a gun that cluster *is* the crown
    #     of the barrel, so this lands on the bore, not on the bbox corner.
    tip = [v for v in vs if v.y <= y_front + 0.03 * L] or vs
    axis_x = sum(v.x for v in tip) / len(tip)
    axis_z = sum(v.z for v in tip) / len(tip)
    muzzle = Vector((axis_x, y_front, axis_z))

    # --- Sight: highest geometry over the receiver/optic stretch, taken at its
    #     rear-most point (rear iron sight, or a scope's eyepiece).
    if kind in ("gun", "melee"):
        reg = [v for v in band(0.22, 0.82)
               if abs(v.x - axis_x) <= 0.45 * H] or band(0.22, 0.82) or vs
        z_reg = max(v.z for v in reg)
        top = [v for v in reg if v.z >= z_reg - 0.03 * H]
        sight = Vector((axis_x, max(v.y for v in top), z_reg))
    else:
        sight = Vector((axis_x, y_front + 0.5 * L, z_top))

    # --- ShellPort: right-hand face of the receiver just behind the chamber.
    if kind == "gun":
        b = band(0.36, 0.54) or vs
        zs_b = [v.z for v in b]
        upper = [v for v in b if v.z >= _pct(zs_b, 0.55)]
        sp_z = sum(v.z for v in upper) / len(upper)
        shell = Vector((max(v.x for v in b), y_front + 0.45 * L, sp_z))
    else:
        shell = Vector((max(v.x for v in vs), y_front + 0.5 * L,
                        z_bot + 0.6 * H))

    # --- GripR: the pistol grip -- rear-biased centroid of the low geometry
    #     behind the trigger. (The magazine also hangs low but sits forward of
    #     the grip, so the rear bias rejects it.)
    if kind in ("gun", "melee"):
        rear = [v for v in vs if v.y >= y_front + (0.42 if kind == "gun" else 0.55) * L]
        low = [v for v in rear if v.z <= z_bot + 0.38 * H]
        if len(low) < 6:
            low = [v for v in rear if v.z <= z_bot + 0.65 * H] or rear
        y_cut = _pct([v.y for v in low], 0.55)
        sel = [v for v in low if v.y >= y_cut] or low
        grip_r = Vector((axis_x, sum(v.y for v in sel) / len(sel),
                         sum(v.z for v in sel) / len(sel)))
    else:
        grip_r = Vector((0.0, 0.0, z_bot + 0.45 * H))

    # --- GripL: support hand on the handguard, under the barrel.
    if kind == "gun" and L > 0.35:
        fore = band(0.16, 0.40) or vs
        zf = [v.z for v in fore]
        lowf = [v for v in fore if v.z <= _pct(zf, 0.35)]
        grip_l = Vector((axis_x, sum(v.y for v in lowf) / len(lowf),
                         sum(v.z for v in lowf) / len(lowf)))
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
        sources.append(f"procedural:{rec['proc']}")
    else:
        gun = import_source(rec["src"], wid)
        sources.append(rec["src"])
        joins = [gun]
        for spec in rec.get("accs", []):
            if "kind" in spec:
                joins += EXTRA_BUILDERS[spec["kind"]](gun)
                sources.append(f"procedural:{spec['kind']}")
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

    # Origin: the hand for held weapons, the base for objects that sit down.
    if rec["kind"] in ("gun", "melee"):
        anchor = marks["GripR"].copy()
    else:
        lo, hi = _bbox(gun)
        anchor = Vector(((lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5, lo.z))
    for v in gun.data.vertices:
        v.co -= anchor
    for k in marks:
        marks[k] = marks[k] - anchor

    lo, hi = _bbox(gun)
    out_dir = os.path.join(OUT_ROOT, wid)
    os.makedirs(out_dir, exist_ok=True)
    atlas_png = os.path.join(out_dir, f"{wid}_atlas.png")

    slots = bc.build_atlas_for([gun], atlas_png,
                               overrides=rec.get("colors"),
                               surfaces=rec.get("surfaces"))
    missing = [m for m in (rec.get("colors") or {}) if m not in slots]
    if missing:
        print(f"    WARNING unused colour overrides: {missing}")
    unstyled = [m for m in slots if m not in (rec.get("colors") or {})]
    if unstyled:
        print(f"    WARNING materials with no override: {unstyled}")
    bc.atlas_remap([gun], slots, atlas_png, material_name=f"TS_{wid}")

    for name, loc in marks.items():
        bc.add_marker(name, loc, parent=gun)
    if debug_markers:
        dbg = _material("TS_DebugMark", (1.0, 0.0, 0.4))
        for name, loc in marks.items():
            b = box(f"DBG_{name}", (0.012, 0.012, 0.012), tuple(loc), dbg)
            _apply(b)

    glb = os.path.join(out_dir, "tp.glb")
    bc.export_glb(glb)
    print(f"    tris={tris} atlas_slots={len(slots)} scale={scale:.4f} "
          f"size=({hi.x - lo.x:.3f}, {hi.y - lo.y:.3f}, {hi.z - lo.z:.3f}) m")
    print(f"    wrote {os.path.relpath(glb, REPO)}")
    print(f"    wrote {os.path.relpath(atlas_png, REPO)}")

    # glTF/Godot space is (x, z, -y) of Blender space.
    def godot(v):
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
    manifest = {"weapons": {}, "convention": {
        "space": "barrel +Z, up +Y, weapon-right +X (Godot/glTF space)",
        "units": "metres",
        "markers": ["Muzzle", "ShellPort", "GripR", "GripL", "Sight"],
        "material": "single atlas-textured material, 1 draw call",
        "tri_budget": TRI_BUDGET,
    }}
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path) as f:
                old = json.load(f)
            manifest["weapons"] = old.get("weapons", {})
        except Exception:
            pass

    total = 0
    for wid in ids:
        if wid not in WEAPONS:
            print(f"[skip] unknown weapon id: {wid}")
            continue
        entry = build_weapon(wid, WEAPONS[wid], debug_markers=debug)
        manifest["weapons"][wid] = entry
        total += entry["tris"]

    manifest["weapons"] = {k: manifest["weapons"][k]
                           for k in WEAPONS if k in manifest["weapons"]}
    os.makedirs(OUT_ROOT, exist_ok=True)
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1, sort_keys=False)
        f.write("\n")
    print(f"[manifest] {os.path.relpath(manifest_path, REPO)} "
          f"({len(manifest['weapons'])} weapons)")
    print(f"[total] {total} tris across {len(ids)} built this run")


main()
