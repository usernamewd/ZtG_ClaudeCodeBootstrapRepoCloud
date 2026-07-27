#!/usr/bin/env python3
"""Generates the architectural shell for each map as a GLB.

    blender -b --python tools/assets/build_maps.py

Reads the layouts in map_layouts.py and emits, per map:
    assets/maps/<id>_shell.glb        merged geometry, one material
    assets/maps/<id>_atlas.png        palette atlas for that map's materials

Why relief matters: extruding each wall as a single box is exactly the "floating
gray box" look the project forbids. Every wall here is built as a plinth + body +
cap, with pilaster strips at a 4 m cadence on long runs, so edges catch the light
and the modular grid reads. Cost is ~36-90 triangles per wall segment, which is
nothing against the 150k in-view budget.

All geometry is merged per map into a single atlas-textured mesh, so an entire
map shell is ONE draw call.
"""
from __future__ import annotations

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import bpy  # noqa: E402
import bmesh  # noqa: E402

import blender_common as bc  # noqa: E402
import map_layouts  # noqa: E402

REPO = os.path.dirname(os.path.dirname(_HERE))
OUT_DIR = os.path.join(REPO, "assets", "maps")

# Relief proportions
PLINTH_H = 0.35
PLINTH_OUT = 0.06        # how far the plinth oversails the wall body
CAP_H = 0.22
CAP_OUT = 0.08
PILASTER_STEP = 4.0      # the kit's module size
PILASTER_W = 0.32
PILASTER_OUT = 0.05

## Surface treatment per material family, passed to the palette generator.
MAT_SURFACE = {
    "concrete": "concrete",
    "metal": "metal",
    "wood": "wood",
    "tile": "concrete",
}
## Base colours, in LINEAR space (Blender's convention; palette.py converts).
MAT_COLOR = {
    "concrete": (0.235, 0.223, 0.200),
    "metal": (0.055, 0.068, 0.086),
    "wood": (0.145, 0.070, 0.026),
    "tile": (0.330, 0.345, 0.330),
}


## Faces are subdivided to about this size before UVs are assigned. Each
## resulting quad samples one point of its palette patch, so a large surface
## reads as many slightly-different tiles instead of one flat swatch — and
## crucially without the smearing you get from projecting a patch across a
## 70 m quad.
SUBDIV_M = 2.0


def _grid_steps(length: float) -> int:
    return max(1, int(round(abs(length) / SUBDIV_M)))


def _add_face_grid(bm, origin, u_vec, v_vec, nu, nv, mat_index):
    """Emit an nu x nv grid of quads spanning origin + u_vec + v_vec."""
    for i in range(nu):
        for j in range(nv):
            u0, u1 = i / nu, (i + 1) / nu
            v0, v1 = j / nv, (j + 1) / nv
            p00 = (origin[0] + u_vec[0] * u0 + v_vec[0] * v0,
                   origin[1] + u_vec[1] * u0 + v_vec[1] * v0,
                   origin[2] + u_vec[2] * u0 + v_vec[2] * v0)
            p10 = (origin[0] + u_vec[0] * u1 + v_vec[0] * v0,
                   origin[1] + u_vec[1] * u1 + v_vec[1] * v0,
                   origin[2] + u_vec[2] * u1 + v_vec[2] * v0)
            p11 = (origin[0] + u_vec[0] * u1 + v_vec[0] * v1,
                   origin[1] + u_vec[1] * u1 + v_vec[1] * v1,
                   origin[2] + u_vec[2] * u1 + v_vec[2] * v1)
            p01 = (origin[0] + u_vec[0] * u0 + v_vec[0] * v1,
                   origin[1] + u_vec[1] * u0 + v_vec[1] * v1,
                   origin[2] + u_vec[2] * u0 + v_vec[2] * v1)
            vs = [bm.verts.new(p) for p in (p00, p10, p11, p01)]
            face = bm.faces.new(vs)
            face.material_index = mat_index


def add_box(bm, cx, y_bottom, cz, sx, height, sz, mat_index, subdivide=True):
    """Append an axis-aligned box using LAYOUT coordinates (x east, z south,
    y up), converting to Blender's Z-up space.

    Blender is Z-up and the glTF exporter's yup conversion is
    glTF(x, y, z) = Blender(x, z, -y). So to land layout X/Z/height on Godot's
    X/Z/Y unmirrored, we emit Blender (x, -z, height). Getting this wrong lays
    the whole map on its side.
    """
    hx, hz = sx * 0.5, sz * 0.5
    z0, z1 = y_bottom, y_bottom + height          # Blender Z carries height
    # Blender Y = -layout Z, so the layout's -Z (north) is Blender +Y.
    by0, by1 = -(cz + hz), -(cz - hz)
    x0, x1 = cx - hx, cx + hx

    if not subdivide:
        verts = [
            bm.verts.new((x0, by0, z0)), bm.verts.new((x1, by0, z0)),
            bm.verts.new((x1, by1, z0)), bm.verts.new((x0, by1, z0)),
            bm.verts.new((x0, by0, z1)), bm.verts.new((x1, by0, z1)),
            bm.verts.new((x1, by1, z1)), bm.verts.new((x0, by1, z1)),
        ]
        for f in [(3, 2, 1, 0), (4, 5, 6, 7), (1, 5, 4, 0),
                  (2, 6, 5, 1), (3, 7, 6, 2), (0, 4, 7, 3)]:
            face = bm.faces.new([verts[i] for i in f])
            face.material_index = mat_index
        return

    dx, dy, dz = x1 - x0, by1 - by0, z1 - z0
    nx, ny, nz = _grid_steps(dx), _grid_steps(dy), _grid_steps(dz)
    # bottom, top
    _add_face_grid(bm, (x0, by0, z0), (dx, 0, 0), (0, dy, 0), nx, ny, mat_index)
    _add_face_grid(bm, (x0, by0, z1), (0, dy, 0), (dx, 0, 0), ny, nx, mat_index)
    # -Y, +Y
    _add_face_grid(bm, (x0, by0, z0), (0, 0, dz), (dx, 0, 0), nz, nx, mat_index)
    _add_face_grid(bm, (x0, by1, z0), (dx, 0, 0), (0, 0, dz), nx, nz, mat_index)
    # -X, +X
    _add_face_grid(bm, (x0, by0, z0), (0, dy, 0), (0, 0, dz), ny, nz, mat_index)
    _add_face_grid(bm, (x1, by0, z0), (0, 0, dz), (0, dy, 0), nz, ny, mat_index)


def build_wall(bm, w, mat_index):
    """A wall segment with plinth, body and cap, plus pilasters on long runs."""
    cx, cz = w["cx"], w["cz"]
    sx, sz, h = w["sx"], w["sz"], w["h"]
    tag = w.get("tag", "")

    # Cover, crates, containers and machinery are objects, not architecture:
    # a single clean box reads correctly and keeps the triangle count down.
    if tag in ("cover", "container", "crate", "machinery", "rail_car", "silo",
               "thin_wall", "railing", "column") or h <= 1.3:
        add_box(bm, cx, 0.0, cz, sx, h, sz, mat_index)
        return

    # Solid fill blocks under raised floors are never seen from outside.
    if tag.endswith("_solid") or tag.endswith("_platform_solid"):
        add_box(bm, cx, 0.0, cz, sx, h, sz, mat_index)
        return

    body_h = max(h - PLINTH_H - CAP_H, 0.2)
    add_box(bm, cx, PLINTH_H, cz, sx, body_h, sz, mat_index)
    add_box(bm, cx, 0.0, cz, sx + PLINTH_OUT * 2.0, PLINTH_H, sz + PLINTH_OUT * 2.0,
            mat_index)
    add_box(bm, cx, PLINTH_H + body_h, cz, sx + CAP_OUT * 2.0, CAP_H,
            sz + CAP_OUT * 2.0, mat_index)

    # Pilasters every module along the wall's long axis.
    along_x = sx >= sz
    length = sx if along_x else sz
    if length <= PILASTER_STEP * 1.2:
        return
    count = int(length // PILASTER_STEP)
    if count < 1:
        return
    start = -length * 0.5 + (length - count * PILASTER_STEP) * 0.5 + PILASTER_STEP * 0.5
    for i in range(count):
        off = start + i * PILASTER_STEP
        if along_x:
            add_box(bm, cx + off, PLINTH_H, cz, PILASTER_W, body_h,
                    sz + PILASTER_OUT * 2.0, mat_index)
        else:
            add_box(bm, cx, PLINTH_H, cz + off, sx + PILASTER_OUT * 2.0, body_h,
                    PILASTER_W, mat_index)


def build_floor(bm, fl, mat_index):
    """Floors get a thin slab rather than a zero-thickness plane, so they read
    as a surface with an edge from a low camera and never z-fight."""
    add_box(bm, fl["cx"], fl["y"] - 0.12, fl["cz"], fl["sx"], 0.12, fl["sz"],
            mat_index)


def _hash3(x: int, y: int, z: int) -> int:
    """Integer hash with proper avalanche. A naive xor-of-products correlates
    along diagonals, which shows up as a woven pattern across large floors."""
    h = (x * 0x27D4EB2D) ^ (y * 0x165667B1) ^ (z * 0x9E3779B1)
    h &= 0xFFFFFFFFFFFF
    h ^= h >> 15
    h = (h * 0x2545F4914F6CDD1D) & 0xFFFFFFFFFFFF
    h ^= h >> 13
    return h & 0xFFFFFFFFFFFF


def _assign_face_uvs(mesh, slot_of_index: dict) -> None:
    """Give every face a single constant UV inside its material's palette patch.

    Projecting a patch across a face (the generic atlas_remap path) smears the
    patch over large surfaces and produces heavy banding. Because faces here are
    already subdivided to ~2 m, one sample per face gives each tile a slightly
    different tone, which reads as a textured surface.
    """
    import palette

    uv_layer = mesh.uv_layers.get("UVAtlas") or mesh.uv_layers.new(name="UVAtlas")
    for poly in mesh.polygons:
        slot = slot_of_index.get(poly.material_index, 0)
        u0, v0, u1, v1 = palette.patch_uv(slot)
        # Hash the face's rounded centre so the choice is stable across rebuilds
        # and neighbouring tiles differ.
        c = poly.center
        h = _hash3(int(c[0] * 4.0), int(c[1] * 4.0), int(c[2] * 4.0))
        fu = ((h >> 8) & 0xFFFF) / 65535.0
        fv = ((h >> 24) & 0xFFFF) / 65535.0
        # A narrow spread: enough tonal variation to read as a surface, not
        # enough to look like confetti.
        u = u0 + (u1 - u0) * (0.42 + 0.16 * fu)
        v = v0 + (v1 - v0) * (0.42 + 0.16 * fv)
        for li in poly.loop_indices:
            uv_layer.data[li].uv = (u, v)
    mesh.uv_layers.active = mesh.uv_layers["UVAtlas"]


def _merge_to_single_material(mesh, obj, atlas_png: str, mat_name: str) -> None:
    """Collapse every material slot into one atlas-textured material, leaving the
    UVs assigned by _assign_face_uvs untouched."""
    mat = bpy.data.materials.new(mat_name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tex = nt.nodes.new("ShaderNodeTexImage")
    img = bpy.data.images.load(atlas_png, check_existing=True)
    img.colorspace_settings.name = "sRGB"
    tex.image = img
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Roughness"].default_value = 0.8
    bsdf.inputs["Metallic"].default_value = 0.0

    mesh.materials.clear()
    mesh.materials.append(mat)
    for poly in mesh.polygons:
        poly.material_index = 0
    for layer in list(mesh.uv_layers):
        if layer.name != "UVAtlas":
            mesh.uv_layers.remove(layer)


def build_map(layout: dict) -> None:
    map_id = layout["id"]
    bc.reset_scene()

    families = sorted({w.get("mat", "concrete") for w in layout["walls"]}
                      | {f.get("mat", "concrete") for f in layout["floors"]})
    mesh = bpy.data.meshes.new(f"{map_id}_shell")
    obj = bpy.data.objects.new(f"{map_id}_shell", mesh)
    bpy.context.scene.collection.objects.link(obj)

    # One placeholder material per family; atlas_remap collapses them into one.
    index_of = {}
    for i, fam in enumerate(families):
        mat = bpy.data.materials.new(fam)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            col = MAT_COLOR.get(fam, (0.3, 0.3, 0.3))
            bsdf.inputs["Base Color"].default_value = (col[0], col[1], col[2], 1.0)
        mesh.materials.append(mat)
        index_of[fam] = i

    bm = bmesh.new()
    for w in layout["walls"]:
        build_wall(bm, w, index_of[w.get("mat", "concrete")])
    for fl in layout["floors"]:
        build_floor(bm, fl, index_of[fl.get("mat", "concrete")])
    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()

    mesh.calc_loop_triangles()
    tris = sum(max(0, len(p.vertices) - 2) for p in mesh.polygons)

    atlas_png = os.path.join(OUT_DIR, f"{map_id}_atlas.png")
    entries = {fam: {"color": MAT_COLOR.get(fam, (0.3, 0.3, 0.3)),
                     "surface": MAT_SURFACE.get(fam, "flat")}
               for fam in families}
    import palette
    slots = palette.build_atlas(entries, atlas_png)
    slot_of_index = {i: slots[fam] for fam, i in index_of.items()}
    _assign_face_uvs(mesh, slot_of_index)
    _merge_to_single_material(mesh, obj, atlas_png, f"TS_{map_id}")

    out_glb = os.path.join(OUT_DIR, f"{map_id}_shell.glb")
    bc.export_glb(out_glb)
    print(f"[map] {map_id}: {tris} tris, families={families}, "
          f"atlas={os.path.basename(atlas_png)}")


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for layout in map_layouts.build_all().values():
        build_map(layout)
    print("[map] done")


if __name__ == "__main__":
    main()
