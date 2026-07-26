#!/usr/bin/env python3
"""Build the two Tactical Strike team characters from the CC0 ToonShooter rig.

    python3 tools/assets/build_characters.py            # both teams
    python3 tools/assets/build_characters.py havoc      # one team

The script re-launches itself inside Blender once per team (each team comes
from a different source .blend, and a .blend has to be *opened*, not imported).

Pipeline per team
-----------------
1.  open the source .blend, drop the 15 prop weapons that ship parented to the
    hand bone, keep armature + body + head (+ shoulder pads),
2.  decimate to the <=3000 tri character budget and re-derive sharp edges,
3.  **zone split**: every polygon is re-assigned to a semantic material
    (``Fatigue`` / ``Rig`` / ``Boot`` / ``Skin`` / ``Accent`` ...) from its
    source material *plus its position on the body*, which is what turns a
    4-colour toon model into something that reads as webbing over fatigues
    over boots,
4.  bake a 512x512 palette atlas per team via ``palette``/``blender_common``
    (``build_atlas_for(overrides=...)`` for variant A, ``recolor_atlas`` for
    the bot variant B — identical slot order, so one set of UVs serves both),
5.  ``atlas_remap`` -> 1 material + 1 texture + 1 draw call per mesh,
6.  scale the rig to 1.80 m, add the ``WeaponMount`` attachment empty,
7.  export GLB with the skin and all 17 stock actions.

``Body`` and ``Head`` stay separate mesh objects on purpose: the local player
hides ``Head`` for full-body first person (see docs/ASSET_PIPELINE.md).

Source: Quaternius "Ultimate Toon Shooter" (CC0)
  havoc <- /opt/assets_cc0/toonshooter/Characters/Blends/Character_Enemy.blend
  aegis <- /opt/assets_cc0/toonshooter/Characters/Blends/Character_Soldier.blend
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT_DIR = os.path.join(REPO, "assets", "characters")
PACK = "/opt/assets_cc0/toonshooter/Characters/Blends"
BLENDER = "/opt/blender/blender"

TARGET_HEIGHT = 1.80          # metres, per docs/ASSET_PIPELINE.md
TRI_BUDGET = 3000


# --------------------------------------------------------------------------
# colour helpers (the palette module wants LINEAR rgb; art direction is easier
# to reason about in sRGB hex, so convert here)
# --------------------------------------------------------------------------

def _s2l(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hx(h: str):
    """'#RRGGBB' (sRGB) -> linear rgb tuple."""
    h = h.lstrip("#")
    return tuple(_s2l(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


ACCENT_ORANGE = "#FF7A1A"     # the game's accent colour
ACCENT_NAVY = "#2E5FA8"

# --------------------------------------------------------------------------
# Body-zone geometry constants (source units, rest T-pose, Z up, ground z=0)
# --------------------------------------------------------------------------
Z_BOOT = 0.26        # everything below this is footwear
Z_HEAD = 1.53        # neck line
X_HAND = 0.97        # wrist: |x| beyond this is the hand
X_ARM = 0.30         # shoulder joint: |x| beyond this is an arm, not the torso
BAND_LO, BAND_HI = 0.33, 0.47    # upper-arm ring -> team armband


def zone_aegis(src: str, x: float, y: float, z: float, role: str) -> str:
    ax = abs(x)
    if role == "head":                       # the helmet/goggles shell
        if src == "Character_Main":
            return "Helmet"
        if src == "Grey":
            return "Accent"                  # band around the helmet
        return "Visor"
    if role == "pad":
        return "Pauldron"
    if src == "Skin":
        return "Glove" if ax >= X_HAND else "Skin"
    if src == "Black":
        if z < Z_BOOT:
            return "Boot"
        if z > Z_HEAD:
            return "Balaclava"
        if ax >= X_ARM:
            return "Accent" if BAND_LO <= ax <= BAND_HI else "Sleeve"
        return "Rig"
    if src == "Character_Main":
        return "Fatigue"
    if src == "DarkGrey":
        return "BootSole" if z < Z_BOOT else "Pouch"
    if src == "Pants":
        return "Trouser"
    if src == "Grey":
        return "Pauldron"
    return "Fatigue"


def zone_havoc(src: str, x: float, y: float, z: float, role: str) -> str:
    ax = abs(x)
    if role == "head":
        if src == "Enemy_Red":
            return "Hood"
        if src == "Black":
            return "Balaclava"
        return "Skin"
    if src == "Skin":
        return "Glove" if ax >= X_HAND else "Skin"
    if src == "Black":
        if z < Z_BOOT:
            return "Boot"
        if ax >= X_ARM:
            return "Accent" if BAND_LO <= ax <= BAND_HI else "Sleeve"
        return "Rig"
    if src == "Enemy_Red":
        return "Fatigue"
    if src == "Grey":
        return "Trouser"
    if src == "DarkGrey":
        return "BootSole" if z < Z_BOOT else "Pouch"
    return "Fatigue"


SURFACE = {
    "Fatigue": "fabric", "Trouser": "fabric", "Sleeve": "fabric",
    "Rig": "fabric", "Hood": "fabric", "Accent": "fabric",
    "Balaclava": "fabric", "Pauldron": "fabric", "Pouch": "fabric",
    "Skin": "skin",
    "Boot": "rubber", "BootSole": "rubber", "Glove": "rubber",
    "Helmet": "metal", "Visor": "metal",
}

TEAMS = {
    # attackers / bomb carriers - hooded desert raider silhouette
    "havoc": {
        "blend": f"{PACK}/Character_Enemy.blend",
        "body": "Character_Enemy",
        "head": "Character_Enemy_Head",
        "pads": [],
        "zone": zone_havoc,
        "decimate": {"Body": 0.66, "Head": 0.62},
        "palette_a": {
            "Hood":      hx("#96522A"),   # rust shemagh hood
            "Balaclava": hx("#31261B"),
            "Fatigue":   hx("#8A7A4C"),   # khaki field jacket
            "Trouser":   hx("#AC9863"),   # lighter desert trousers
            "Sleeve":    hx("#4E4230"),   # dark olive sleeves
            "Rig":       hx("#5E3B1E"),   # brown leather webbing
            "Pouch":     hx("#402C17"),
            "Boot":      hx("#3C2C1D"),
            "BootSole":  hx("#1B1714"),
            "Glove":     hx("#4C3722"),
            "Skin":      hx("#C08B5C"),
            "Accent":    hx(ACCENT_ORANGE),
        },
        # bot variant: greener, weathered, darker skin
        "palette_b": {
            "Hood":      hx("#7C4632"),
            "Fatigue":   hx("#6F7546"),
            "Trouser":   hx("#8F8B5B"),
            "Sleeve":    hx("#40402C"),
            "Rig":       hx("#4E3620"),
            "Skin":      hx("#A5734A"),
        },
    },
    # defenders - helmeted, pauldroned, plate-carrier silhouette
    "aegis": {
        "blend": f"{PACK}/Character_Soldier.blend",
        "body": "Body",
        "head": "Head",
        "pads": ["ShoulderPad.L", "ShoulderPad.R"],
        "zone": zone_aegis,
        "decimate": {"Body": 0.52, "Head": 0.40},
        "palette_a": {
            "Helmet":    hx("#3F4A59"),
            "Visor":     hx("#15181D"),
            "Pauldron":  hx("#39434F"),
            "Fatigue":   hx("#4E5A6B"),   # slate blue-grey plate carrier
            "Trouser":   hx("#5C6878"),
            "Sleeve":    hx("#2C333D"),
            "Rig":       hx("#1B1F25"),   # black nylon webbing
            "Pouch":     hx("#262B33"),
            "Boot":      hx("#191A1D"),
            "BootSole":  hx("#0E0F11"),
            "Glove":     hx("#202329"),
            "Balaclava": hx("#1A1D22"),
            "Skin":      hx("#C79A6E"),
            "Accent":    hx(ACCENT_NAVY),
        },
        "palette_b": {
            "Helmet":    hx("#37424F"),
            "Fatigue":   hx("#41505F"),
            "Trouser":   hx("#4E5C6E"),
            "Sleeve":    hx("#242A33"),
            "Skin":      hx("#D8B48C"),
        },
    },
}


# ==========================================================================
# Everything below only runs inside Blender.
# ==========================================================================

def build(team: str) -> None:
    import bpy
    import bmesh
    from math import radians
    from mathutils import Matrix, Vector

    sys.path.insert(0, HERE)
    import blender_common as bc  # noqa: E402
    import palette              # noqa: E402

    cfg = TEAMS[team]
    written = []

    # ---- 1. open scene, strip the prop weapons ---------------------------
    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    arm = bc.armatures()[0]
    arm.name = "CharacterArmature"
    arm.data.pose_position = "REST"

    keep = ["CharacterArmature", cfg["body"], cfg["head"]] + cfg["pads"]
    bc.keep_only(keep)
    bpy.context.view_layer.objects.active = arm

    body = bpy.data.objects[cfg["body"]]
    head = bpy.data.objects[cfg["head"]]
    pads = [bpy.data.objects[n] for n in cfg["pads"]]
    src_tris = bc.tri_count()

    # rename before anything else: gameplay looks these node names up
    head.name = "Head"      # rename head first, "Body" may already be taken
    body.name = "Body"

    for o in bpy.data.objects:
        for m in list(o.modifiers):
            if m.type == "NODES":       # stock "Auto Smooth" geo-nodes modifier
                o.modifiers.remove(m)

    # neutral rest pose - Godot's AnimationPlayer drives everything else
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.rotation_euler = (0, 0, 0)
        pb.scale = (1, 1, 1)
    bpy.context.view_layer.update()

    # ---- 2. decimate to budget, then re-derive sharp edges ---------------
    for obj, ratio in ((body, cfg["decimate"]["Body"]), (head, cfg["decimate"]["Head"])):
        before = _tris(obj)
        d = obj.modifiers.new("Decimate", "DECIMATE")
        d.decimate_type = "COLLAPSE"
        d.ratio = ratio
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=d.name)
        _resharpen(bmesh, obj, radians(32.0))
        print(f"[decimate] {obj.name}: {before} -> {_tris(obj)} tris (ratio {ratio})")
    for p in pads:
        _resharpen(bmesh, p, radians(32.0))

    # ---- 3. zone split: source material + body position -> semantic zone --
    zone = cfg["zone"]
    counts = {}
    for obj, role in [(body, "body"), (head, "head")] + [(p, "pad") for p in pads]:
        _zone_split(bpy, obj, zone, role, counts)
    print("[zones] " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    # ---- 4. one skinned Body + one skinned Head --------------------------
    # The stock helmet / shoulder pads are *bone parented*; convert them to
    # real skinning so they can be joined without changing how they deform.
    if head.parent_type == "BONE":
        _bone_parent_to_skin(bpy, Matrix, head, arm, head.parent_bone)
    for p in pads:
        if p.parent_type == "BONE":
            _bone_parent_to_skin(bpy, Matrix, p, arm, p.parent_bone)

    # On the Soldier the actual head (face + balaclava) lives inside `Body`;
    # move it into `Head` so hiding `Head` in first person hides all of it.
    moved = _move_head_faces(bpy, bmesh, body, head, arm)
    if moved:
        print(f"[split] moved {moved} head-weighted faces from Body into Head")
    if pads:
        bc.join_meshes([body] + pads, "Body")
        body = bpy.data.objects["Body"]
        print(f"[join] shoulder pads merged into Body")

    for o in (body, head):
        if not any(m.type == "ARMATURE" for m in o.modifiers):
            m = o.modifiers.new("Armature", "ARMATURE")
            m.object = arm

    objs = [body, head]

    # ---- 5. palette atlases ---------------------------------------------
    entries = bc.collect_materials(objs)
    for name in entries:
        entries[name]["surface"] = SURFACE.get(name, "fabric")

    atlas_a = os.path.join(OUT_DIR, f"{team}_atlas.png")
    atlas_b = os.path.join(OUT_DIR, f"{team}_atlas_b.png")
    slots = bc.build_atlas_for(objs, atlas_a, overrides=cfg["palette_a"],
                               surfaces={k: SURFACE.get(k, "fabric") for k in entries})
    pal_b = dict(cfg["palette_a"])
    pal_b.update(cfg["palette_b"])
    slots_b = palette.recolor_atlas(entries, pal_b, atlas_b)
    assert slots == slots_b, "variant B must reuse variant A's slot layout"
    _flip_atlas_rows(atlas_a)
    _flip_atlas_rows(atlas_b)
    written += [atlas_a, atlas_b]
    print(f"[atlas] {len(slots)} slots: " +
          ", ".join(f"{k}#{v}" for k, v in sorted(slots.items(), key=lambda kv: kv[1])))

    # ---- 6. remap UVs into the atlas, collapse to one material -----------
    # Godot's glTF importer extracts embedded textures as
    # "<glb stem>_<gltf image name>.png", and Blender names the glTF image after
    # the source file. Feeding atlas_remap a copy called plain "atlas.png" makes
    # the extracted texture land exactly on <team>_atlas.png instead of adding a
    # duplicate <team>_<team>_atlas.png next to it.
    import shutil
    import tempfile
    tmp = os.path.join(tempfile.gettempdir(), f"ts_atlas_{team}")
    os.makedirs(tmp, exist_ok=True)
    tex = os.path.join(tmp, "atlas.png")
    shutil.copyfile(atlas_a, tex)
    bc.atlas_remap(objs, slots, tex, material_name=f"TS_{team}", jitter=0.55)
    for img in bpy.data.images:
        if img.filepath and os.path.basename(img.filepath) == "atlas.png":
            img.name = "atlas"

    # ---- 7. metric scale + weapon attachment -----------------------------
    bpy.context.view_layer.update()
    height = _world_height(objs)
    f = TARGET_HEIGHT / height
    _apply_metric_scale(bpy, Matrix, arm, objs, f)
    print(f"[scale] source height {height:.3f} -> {TARGET_HEIGHT:.2f} m (x{f:.4f})")

    _weapon_mount(bpy, Matrix, Vector, arm)

    # ---- 8. export -------------------------------------------------------
    arm.data.pose_position = "POSE"
    for a in bpy.data.actions:
        a.use_fake_user = True

    total = bc.tri_count()
    for o in objs:
        print(f"[tris] {o.name}: {_tris(o)}")
    print(f"[tris] TOTAL {total} (source {src_tris}, budget {TRI_BUDGET})")
    if total > TRI_BUDGET:
        print(f"[WARN] {team} is over the {TRI_BUDGET} tri budget!")

    glb = os.path.join(OUT_DIR, f"{team}.glb")
    bpy.context.view_layer.objects.active = arm
    bc.export_glb(glb, with_animations=True)
    written.append(glb)

    print(f"[anims] {len(bpy.data.actions)}: " +
          ", ".join(sorted(a.name for a in bpy.data.actions)))
    for p in written:
        print(f"WROTE {p}")


# --- Blender-side helpers ---------------------------------------------------

def _flip_atlas_rows(path: str) -> None:
    """Reconcile the two row conventions in the shipped palette pipeline.

    ``palette.build_atlas`` paints slot ``s`` with PIL, whose row 0 is the *top*
    of the PNG, while ``palette.patch_uv(s)`` returns v measured from the
    *bottom* (Blender/glTF UV space). Slot 0 therefore ends up painted at the
    top of the image but sampled from the bottom, and every model comes out
    reading the unused black slots. Flipping the finished atlas vertically maps
    PIL row gy onto UV row gy for every slot without touching palette.py.
    (Reported in the phase notes - the fix belongs in palette.patch_uv.)
    """
    from PIL import Image
    im = Image.open(path)
    im.transpose(Image.FLIP_TOP_BOTTOM).save(path)


def _tris(obj) -> int:
    return sum(max(0, len(p.vertices) - 2) for p in obj.data.polygons)


def _resharpen(bmesh, obj, angle: float) -> None:
    """Decimation destroys the source's smooth/sharp flags; rebuild them by
    dihedral angle so limbs stay smooth and plates stay faceted."""
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        e.smooth = not (len(e.link_faces) == 2 and e.calc_face_angle(0.0) > angle)
    bm.to_mesh(me)
    bm.free()


def _zone_split(bpy, obj, zone_fn, role: str, counts: dict) -> None:
    """Re-assign every polygon to a semantic zone material."""
    me = obj.data
    src = [m.name if m else "None" for m in me.materials]
    mw = obj.matrix_world
    zones = []
    for p in me.polygons:
        c = mw @ p.center
        s = src[p.material_index] if p.material_index < len(src) else "None"
        z = zone_fn(s, c.x, c.y, c.z, role)
        zones.append(z)
        counts[z] = counts.get(z, 0) + max(0, len(p.vertices) - 2)

    order = []
    for z in zones:
        if z not in order:
            order.append(z)
    me.materials.clear()
    for z in order:
        mat = bpy.data.materials.get(z)
        if mat is None:
            mat = bpy.data.materials.new(z)
            mat.use_nodes = False
            mat.diffuse_color = (0.5, 0.5, 0.5, 1.0)
        me.materials.append(mat)
    idx = {z: i for i, z in enumerate(order)}
    for p, z in zip(me.polygons, zones):
        p.material_index = idx[z]


def _bone_parent_to_skin(bpy, Matrix, obj, arm, bone_name: str) -> None:
    """Turn a bone-parented prop into a normally skinned mesh (all weight on
    the bone it was parented to) so it can be joined with a skinned mesh."""
    bpy.context.view_layer.update()
    world = obj.matrix_world.copy()
    obj.data.transform(arm.matrix_world.inverted() @ world)
    obj.parent = arm
    obj.parent_type = "OBJECT"
    obj.parent_bone = ""
    obj.matrix_parent_inverse = Matrix.Identity(4)
    obj.matrix_basis = Matrix.Identity(4)
    obj.vertex_groups.clear()
    vg = obj.vertex_groups.new(name=bone_name)
    vg.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")
    for m in list(obj.modifiers):
        if m.type == "ARMATURE":
            obj.modifiers.remove(m)
    m = obj.modifiers.new("Armature", "ARMATURE")
    m.object = arm
    bpy.context.view_layer.update()


def _move_head_faces(bpy, bmesh, body, head, arm) -> int:
    """Move the polygons of `body` that are dominated by the Head bone into
    `head`, so `Head` is the whole head (skull + gear) for first-person hiding."""
    me = body.data
    gname = {g.index: g.name for g in body.vertex_groups}
    if "Head" not in gname.values():
        return 0
    sel = []
    for p in me.polygons:
        w = {}
        for vi in p.vertices:
            for g in me.vertices[vi].groups:
                w[gname.get(g.group, "")] = w.get(gname.get(g.group, ""), 0.0) + g.weight
        if w and max(w, key=w.get) == "Head":
            sel.append(p.index)
    if not sel:
        return 0
    tris = sum(max(0, len(me.polygons[i].vertices) - 2) for i in sel)

    for p in me.polygons:
        p.select = False
    for i in sel:
        me.polygons[i].select = True
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.separate(type="SELECTED")
    bpy.ops.object.mode_set(mode="OBJECT")

    piece = [o for o in bpy.context.selected_objects if o not in (body,)]
    piece = [o for o in piece if o.name.startswith("Body")]
    if not piece:
        return 0
    part = piece[0]
    bpy.ops.object.select_all(action="DESELECT")
    part.select_set(True)
    head.select_set(True)
    bpy.context.view_layer.objects.active = head
    bpy.ops.object.join()
    return tris


def _apply_metric_scale(bpy, Matrix, arm, meshes, f: float) -> None:
    """Scale the whole character to metres *in the data*, leaving every object
    transform at identity.

    Putting the factor on the armature object instead looks right in Blender but
    exports wrong: the glTF exporter bakes the skin root's transform into the
    vertices AND writes it on the joint nodes, so the character comes out scaled
    twice. Scaling mesh data + bone rest positions + pose-bone *location* keys
    (rotations are scale-invariant) is exact and survives the round trip.
    """
    S = Matrix.Diagonal((f, f, f)).to_4x4()
    for o in meshes:
        o.data.transform(S)

    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for eb in arm.data.edit_bones:
        eb.use_connect = False
    for eb in arm.data.edit_bones:
        eb.head = eb.head * f
        eb.tail = eb.tail * f
    bpy.ops.object.mode_set(mode="OBJECT")

    n = 0
    for a in bpy.data.actions:
        for fc in a.fcurves:
            if not fc.data_path.endswith(".location"):
                continue
            n += 1
            for kp in fc.keyframe_points:
                kp.co.y *= f
                kp.handle_left.y *= f
                kp.handle_right.y *= f
    print(f"[scale] rescaled {n} location f-curves across {len(bpy.data.actions)} actions")
    bpy.context.view_layer.update()


def _weapon_mount(bpy, Matrix, Vector, arm) -> None:
    """`WeaponMount` sits in the right palm, oriented so a pipeline weapon
    (barrel +Z, grip -Y) parented to it with identity transform lands in the
    hand exactly where the source pack's own props sat."""
    bones = arm.data.bones
    wrist = arm.matrix_world @ bones["Index1.R"].head_local
    fingertip = arm.matrix_world @ bones["Middle1.R"].tail_local
    pos = wrist.lerp(fingertip, 0.55)
    # rest T-pose: the right arm points -X, so a held weapon's barrel is -X and
    # its grip hangs -Z.
    ax = Vector((0.0, -1.0, 0.0))
    ay = Vector((0.0, 0.0, 1.0))
    az = Vector((-1.0, 0.0, 0.0))
    rot = Matrix((ax, ay, az)).transposed().to_4x4()

    e = bpy.data.objects.new("WeaponMount", None)
    e.empty_display_type = "ARROWS"
    e.empty_display_size = 0.08
    bpy.context.scene.collection.objects.link(e)
    e.parent = arm
    e.parent_type = "BONE"
    e.parent_bone = "Index1.R"
    e.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.view_layer.update()
    e.matrix_world = Matrix.Translation(pos) @ rot
    bpy.context.view_layer.update()
    print(f"[mount] WeaponMount on bone Index1.R at {tuple(round(v, 3) for v in e.matrix_world.translation)}")


def _world_height(objs) -> float:
    lo, hi = 1e9, -1e9
    for o in objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            z = (mw @ v.co).z
            lo, hi = min(lo, z), max(hi, z)
    return hi - lo


# ==========================================================================
# entry point
# ==========================================================================

def _in_blender() -> bool:
    try:
        import bpy  # noqa: F401
        return True
    except ImportError:
        return False


def main() -> None:
    if _in_blender():
        argv = sys.argv[sys.argv.index("--") + 1:]
        build(argv[0])
        return

    import subprocess
    teams = sys.argv[1:] or list(TEAMS)
    os.makedirs(OUT_DIR, exist_ok=True)
    for t in teams:
        if t not in TEAMS:
            raise SystemExit(f"unknown team {t!r}; choose from {list(TEAMS)}")
        print(f"\n===== building {t} =====", flush=True)
        r = subprocess.run(
            [BLENDER, "-b", TEAMS[t]["blend"], "--python", os.path.abspath(__file__),
             "--", t],
            capture_output=True, text=True)
        keep = ("[", "WROTE", "Error", "Traceback", "error:")
        for line in (r.stdout + r.stderr).splitlines():
            if line.startswith(keep) or "Error" in line or "Traceback" in line:
                print(line)
        if r.returncode != 0:
            print(r.stdout[-4000:])
            print(r.stderr[-4000:])
            raise SystemExit(f"blender failed for {t}")


if __name__ == "__main__":
    main()
