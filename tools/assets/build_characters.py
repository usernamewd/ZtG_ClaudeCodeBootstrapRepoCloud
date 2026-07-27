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
Z_BOOT = 0.26        # sole / shoe geometry lives below this
Z_CUFF = 0.28        # ... and the trouser below this becomes the boot shaft
Z_HEAD = 1.53        # neck line
Z_KNEE_LO, Z_KNEE_HI = 0.50, 0.61
Z_HEM = 0.99         # bottom hem of the torso mesh -> belt line
X_HAND = 0.97        # wrist: |x| beyond this is the hand
X_ARM = 0.30         # shoulder joint: |x| beyond this is an arm, not the torso
X_ELBOW = 0.62       # |x| beyond this is forearm


def zone_aegis(src: str, x: float, y: float, z: float, role: str) -> str:
    ax = abs(x)
    # `Head` holds the helmet shell *and* the skull that was lifted out of Body
    if role == "head":
        if src == "Skin":
            return "Skin"                    # face
        if src == "Character_Main":
            return "Helmet"
        if src == "Grey":
            return "Accent"                  # band around the helmet
        return "Balaclava"                   # balaclava + goggle strap
    if role == "pad":
        return "Pauldron"
    if src == "Skin":
        return "Glove" if ax >= 0.88 else "Sleeve"
    if src == "Black":
        if z < Z_BOOT:
            return "Boot"
        if z > Z_HEAD:
            return "Balaclava"
        if ax >= X_ARM:
            # the pauldron covers the upper arm, so the team band goes on the
            # forearm where it is actually visible
            return "Accent" if 0.60 <= ax <= 0.73 else "Sleeve"
        return "Rig"
    if src == "Character_Main":
        return "Fatigue"
    if src == "DarkGrey":
        return "BootSole" if z < Z_BOOT else "Pouch"
    if src == "Pants":
        if z < Z_CUFF:
            return "Boot"
        if Z_KNEE_LO <= z <= Z_KNEE_HI and y < -0.05:
            return "KneePad"
        return "Trouser"
    if src == "Grey":
        return "Pauldron"
    return "Fatigue"


def zone_havoc(src: str, x: float, y: float, z: float, role: str) -> str:
    ax = abs(x)
    if role == "head":
        if src == "Enemy_Red":
            # dark hood over the crown, lighter shemagh wrapped round the face
            # and neck - two tones stop the head reading as one bald dome
            return "Hood" if z >= 1.78 else "Wrap"
        if src == "Black":
            return "Balaclava"
        return "Visor"                       # narrow eye slot
    if src == "Skin":
        return "Skin"                        # bare forearms and hands
    if src == "Black":
        if z < Z_BOOT:
            return "Boot"
        if z > Z_HEAD:
            return "Balaclava"               # collar under the hood
        if ax >= X_ARM:
            return "Accent" if 0.33 <= ax <= 0.52 else "Sleeve"
        return "Rig"                         # webbing straps on the torso
    if src == "Character_Main":
        if z <= Z_HEM:
            return "Rig"                     # leather belt at the jacket hem
        if y < -0.02 and 1.14 <= z <= 1.42:
            return "Vest"                    # chest rig band across the front
        return "Fatigue"
    if src == "DarkGrey":
        return "BootSole" if z < Z_BOOT else "Pouch"
    if src == "Pants":
        if z < Z_CUFF:
            return "Boot"
        if Z_KNEE_LO <= z <= Z_KNEE_HI and y < -0.05:
            return "KneePad"
        return "Trouser"
    return "Fatigue"


SURFACE = {
    "Fatigue": "fabric", "Trouser": "fabric", "Sleeve": "fabric",
    "Hood": "fabric", "Wrap": "fabric", "Accent": "fabric",
    "Balaclava": "fabric",
    "Rig": "wood",       # the "wood" treatment reads as grained leather webbing
    "Vest": "fabric", "Pouch": "fabric", "Pauldron": "concrete",
    "Skin": "skin",
    "Boot": "wood", "BootSole": "rubber", "Glove": "fabric",
    "KneePad": "rubber",
    "Helmet": "concrete", "Visor": "metal",
}

TEAMS = {
    # attackers / bomb carriers - hooded desert raider silhouette
    "havoc": {
        "blend": f"{PACK}/Character_Soldier.blend",
        "body": "Body",
        "head": "Head",                        # helmet, replaced by the hood
        "pads": [],                            # no pauldrons -> slimmer read
        "graft_head": (f"{PACK}/Character_Enemy.blend", "Character_Enemy_Head"),
        "zone": zone_havoc,
        "decimate": {"Body": 0.52, "Head": 0.80},
        "palette_a": {
            "Hood":      hx("#4A2C1B"),   # dark rust hood over the crown
            "Wrap":      hx("#7A6444"),   # tan shemagh round the face/neck
            "Balaclava": hx("#1D1710"),
            "Visor":     hx("#141110"),   # shadowed eye slot
            "Fatigue":   hx("#6E6139"),   # khaki field jacket
            "Vest":      hx("#2C1F12"),   # chest rig
            "Rig":       hx("#4E3018"),   # brown leather belt / webbing
            "Pouch":     hx("#2A1C0C"),
            "Trouser":   hx("#857449"),   # desert trousers
            "KneePad":   hx("#2A2015"),
            "Sleeve":    hx("#3E3426"),   # dark olive upper sleeve
            "Boot":      hx("#35271A"),
            "BootSole":  hx("#17130F"),
            "Skin":      hx("#A87550"),
            "Accent":    hx(ACCENT_ORANGE),
        },
        # bot variant: greener, more weathered, darker skin
        "palette_b": {
            "Hood":      hx("#3B2E20"),
            "Wrap":      hx("#6A6242"),
            "Fatigue":   hx("#57603A"),
            "Trouser":   hx("#6F6B42"),
            "Sleeve":    hx("#333323"),
            "Vest":      hx("#26210F"),
            "Skin":      hx("#8E6440"),
        },
    },
    # defenders - helmeted, pauldroned, plate-carrier silhouette
    "aegis": {
        "blend": f"{PACK}/Character_Soldier.blend",
        "body": "Body",
        "head": "Head",
        "pads": ["ShoulderPad.L", "ShoulderPad.R"],
        "zone": zone_aegis,
        "decimate": {"Body": 0.53, "Head": 0.48},
        "palette_a": {
            "Helmet":    hx("#414B59"),
            "Visor":     hx("#14171B"),
            "Pauldron":  hx("#525E6C"),
            "Fatigue":   hx("#313944"),   # dark plate carrier over the uniform
            "Pouch":     hx("#1F242B"),
            "Rig":       hx("#17191E"),   # black nylon webbing
            "Sleeve":    hx("#414B58"),   # slate uniform sleeve
            "Trouser":   hx("#5A6673"),   # lighter slate trousers
            "KneePad":   hx("#22262D"),
            "Boot":      hx("#16181C"),
            "BootSole":  hx("#0C0D0F"),
            "Glove":     hx("#1A1D22"),
            "Balaclava": hx("#191C21"),
            "Skin":      hx("#B78A62"),
            "Accent":    hx(ACCENT_NAVY),
        },
        "palette_b": {
            "Helmet":    hx("#39424E"),
            "Fatigue":   hx("#2A323D"),
            "Sleeve":    hx("#38414D"),
            "Trouser":   hx("#4E5966"),
            "Skin":      hx("#C9A279"),
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

    # ---- 2. one skinned Body + one skinned Head --------------------------
    # The stock helmet / shoulder pads are *bone parented*; convert them to
    # real skinning so they can be joined without changing how they deform.
    if head.parent_type == "BONE":
        _bone_parent_to_skin(bpy, Matrix, head, arm, head.parent_bone)
    for p in pads:
        if p.parent_type == "BONE":
            _bone_parent_to_skin(bpy, Matrix, p, arm, p.parent_bone)

    graft = cfg.get("graft_head")
    if graft:
        # Both teams use the Soldier body (it is the one with a plate carrier,
        # mag pouches and a belt as real geometry). Havoc swaps the helmet for
        # the Enemy character's hood, which rides the *same* 43-bone rig, so the
        # two teams read apart instantly at distance without a second body mesh.
        bpy.data.objects.remove(head, do_unlink=True)
        head = _graft_head(bpy, arm, graft[0], graft[1])
        print(f"[graft] head {graft[1]!r} appended from {os.path.basename(graft[0])}")

    # On the Soldier the actual head (face + balaclava) lives inside `Body`.
    # Aegis moves it into `Head` so hiding `Head` in first person hides all of
    # it; Havoc drops it, because the grafted hood is a closed head already.
    moved = _move_head_faces(bpy, bmesh, body, head, arm,
                             discard=bool(graft))
    if moved:
        verb = "discarded" if graft else "moved into Head"
        print(f"[split] {moved} head-weighted tris {verb}")
    if pads:
        bc.join_meshes([body] + pads, "Body")
        body = bpy.data.objects["Body"]
        print("[join] shoulder pads merged into Body")

    for o in (body, head):
        if not any(m.type == "ARMATURE" for m in o.modifiers):
            m = o.modifiers.new("Armature", "ARMATURE")
            m.object = arm

    # ---- 3. decimate to budget, then re-derive sharp edges ---------------
    for obj in (body, head):
        ratio = cfg["decimate"][obj.name]
        before = _tris(obj)
        d = obj.modifiers.new("Decimate", "DECIMATE")
        d.decimate_type = "COLLAPSE"
        d.ratio = ratio
        d.use_symmetry = True          # a lopsided face is instantly obvious
        d.symmetry_axis = "X"
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=d.name)
        _resharpen(bmesh, obj, radians(25.0))
        print(f"[decimate] {obj.name}: {before} -> {_tris(obj)} tris (ratio {ratio})")

    # ---- 4. zone split: source material + body position -> semantic zone --
    counts = {}
    _zone_split(bpy, body, cfg["zone"], "body", counts)
    _zone_split(bpy, head, cfg["zone"], "head", counts)
    print("[zones] " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    objs = [body, head]

    # ---- 5. palette atlases ---------------------------------------------
    entries = bc.collect_materials(objs)
    for name in entries:
        entries[name]["surface"] = SURFACE.get(name, "fabric")

    pal_a = cfg["palette_a"]
    surf = {k: SURFACE.get(k, "fabric") for k in entries}
    if os.environ.get("TS_ZONE_DEBUG"):
        # flat, maximally distinct hue per zone - for checking *where* each zone
        # landed on the body without art direction getting in the way.
        import colorsys
        pal_a = {}
        for i, n in enumerate(sorted(entries)):
            h = (i * 0.618034) % 1.0          # golden ratio: neighbours stay far apart
            s = 1.0 if i % 2 == 0 else 0.55
            v = 0.95 if i % 3 else 0.45
            pal_a[n] = colorsys.hsv_to_rgb(h, s, v)
            print(f"[debug] {n:10s} h={h:.2f} s={s} v={v} "
                  f"rgb={tuple(round(c, 2) for c in pal_a[n])}")
        surf = {k: "flat" for k in entries}
        print("[debug] zone-debug palette active")

    atlas_a = os.path.join(OUT_DIR, f"{team}_atlas.png")
    atlas_b = os.path.join(OUT_DIR, f"{team}_atlas_b.png")
    slots = bc.build_atlas_for(objs, atlas_a, overrides=pal_a, surfaces=surf)
    pal_b = dict(pal_a)
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


def _base_name(name: str) -> str:
    """'Black.001' -> 'Black' (appending from a second .blend suffixes names)."""
    head, _, tail = name.rpartition(".")
    return head if head and tail.isdigit() and len(tail) == 3 else name


def _graft_head(bpy, arm, blend_path: str, obj_name: str):
    """Append a head mesh from another character .blend and re-target it onto
    this scene's armature. Every ToonShooter character shares one 43-bone rig
    with identical rest positions, so the vertex groups line up by name."""
    actions_before = {a.name for a in bpy.data.actions}
    objs_before = {o.name for o in bpy.data.objects}
    directory = os.path.join(blend_path, "Object") + os.sep
    bpy.ops.wm.append(filepath=os.path.join(directory, obj_name),
                      directory=directory, filename=obj_name,
                      link=False, autoselect=False, active_collection=True)
    new = [o for o in bpy.data.objects if o.name not in objs_before]

    head = next(o for o in new if o.type == "MESH")
    head.parent = arm
    head.parent_type = "OBJECT"
    for m in list(head.modifiers):
        if m.type == "NODES":
            head.modifiers.remove(m)
        elif m.type == "ARMATURE":
            m.object = arm
    for o in new:                       # the appended duplicate armature
        if o.type == "ARMATURE":
            bpy.data.objects.remove(o, do_unlink=True)
    for a in list(bpy.data.actions):    # ... and its duplicate action set
        if a.name not in actions_before:
            bpy.data.actions.remove(a)
    head.name = "Head"
    return head


def _zone_split(bpy, obj, zone_fn, role: str, counts: dict) -> None:
    """Re-assign every polygon to a semantic zone material."""
    me = obj.data
    src = [_base_name(m.name) if m else "None" for m in me.materials]
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


def _move_head_faces(bpy, bmesh, body, head, arm, discard: bool = False) -> int:
    """Move the polygons of `body` that are dominated by the Head bone into
    `head`, so `Head` is the whole head (skull + gear) for first-person hiding.
    With ``discard=True`` they are deleted instead (the grafted hood already is
    a closed head, so the original skull would just be hidden geometry)."""
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

    piece = [o for o in bpy.context.selected_objects
             if o is not body and o.name.startswith("Body")]
    if not piece:
        return 0
    part = piece[0]
    if discard:
        bpy.data.objects.remove(part, do_unlink=True)
        return tris
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
