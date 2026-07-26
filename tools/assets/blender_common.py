"""Shared Blender helpers for the Tactical Strike asset pipeline.

Run inside Blender (``blender -b --python <script>``). Importing this module
outside Blender fails by design.

The central operation is :func:`atlas_remap`: source models are flat-shaded
low-poly with one material per colour and no UVs, which would cost one draw
call per colour and look like untextured plastic. ``atlas_remap`` assigns every
face a UV inside its colour's patch in a generated palette atlas, then collapses
all materials into a single textured material.
"""
from __future__ import annotations

import os
import sys

import bpy
import bmesh
from mathutils import Vector

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import palette  # noqa: E402


# --- Scene management --------------------------------------------------------

def reset_scene() -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_any(path: str) -> None:
    """Import FBX / glTF / OBJ into the current scene."""
    ext = os.path.splitext(path)[1].lower()
    if ext == ".fbx":
        bpy.ops.import_scene.fbx(filepath=path)
    elif ext in (".gltf", ".glb"):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == ".obj":
        bpy.ops.wm.obj_import(filepath=path)
    elif ext == ".blend":
        raise ValueError("open .blend files with `blender -b file.blend`, not import_any")
    else:
        raise ValueError(f"unsupported asset type: {path}")


def meshes():
    return [o for o in bpy.data.objects if o.type == "MESH"]


def armatures():
    return [o for o in bpy.data.objects if o.type == "ARMATURE"]


def delete_objects(objs) -> None:
    for o in list(objs):
        bpy.data.objects.remove(o, do_unlink=True)


def keep_only(names) -> None:
    keep = set(names)
    delete_objects([o for o in bpy.data.objects if o.name not in keep])


# --- Material colour extraction ----------------------------------------------

def material_base_color(mat) -> tuple:
    """Best-effort base colour of a material, as linear RGB 0..1."""
    if mat is None:
        return (0.5, 0.5, 0.5)
    if mat.use_nodes and mat.node_tree:
        for node in mat.node_tree.nodes:
            if node.type in ("BSDF_PRINCIPLED", "BSDF_DIFFUSE", "EMISSION"):
                inp = node.inputs.get("Base Color") or node.inputs.get("Color")
                if inp is not None and not inp.is_linked:
                    return tuple(inp.default_value)[:3]
    return tuple(mat.diffuse_color)[:3]


def collect_materials(objs=None) -> dict:
    """material name -> {"color": rgb}, in a stable (sorted) order."""
    objs = objs if objs is not None else meshes()
    found = {}
    for o in objs:
        for slot in o.data.materials:
            if slot is not None and slot.name not in found:
                found[slot.name] = {"color": material_base_color(slot)}
    return {k: found[k] for k in sorted(found)}


# --- The atlas remap ---------------------------------------------------------

def atlas_remap(objs, slots: dict, atlas_image_path: str,
                material_name: str = "TS_Atlas", jitter: float = 0.7):
    """Give every face a UV inside its material's atlas patch, then merge all
    material slots into one atlas-textured material.

    ``jitter`` (0..1) spreads a face's UVs across its patch's safe area instead
    of pinning them to the centre, so the procedural grain in the atlas actually
    varies across a surface rather than repeating one texel.
    """
    mat = _make_atlas_material(material_name, atlas_image_path)

    for o in objs:
        me = o.data
        name_by_index = [m.name if m else None for m in me.materials]

        bm = bmesh.new()
        bm.from_mesh(me)
        uv_layer = bm.loops.layers.uv.get("UVAtlas") or bm.loops.layers.uv.new("UVAtlas")

        for face in bm.faces:
            src = name_by_index[face.material_index] if face.material_index < len(name_by_index) else None
            slot = slots.get(src, 0)
            u0, v0, u1, v1 = palette.patch_uv(slot)
            cu, cv = (u0 + u1) * 0.5, (v0 + v1) * 0.5
            hw, hh = (u1 - u0) * 0.5 * jitter, (v1 - v0) * 0.5 * jitter

            # Project the face's own geometry into the patch so adjacent faces
            # of the same colour sample different texels (real grain, not a
            # flat swatch). Scale is arbitrary but consistent: 1 world metre
            # maps to roughly one patch width.
            for loop in face.loops:
                co = loop.vert.co
                pu = (co.x * 1.7 + co.z * 0.31) % 1.0
                pv = (co.y * 1.7 + co.x * 0.17) % 1.0
                loop[uv_layer].uv = Vector((cu + (pu - 0.5) * 2.0 * hw,
                                            cv + (pv - 0.5) * 2.0 * hh))

        bm.to_mesh(me)
        bm.free()

        me.materials.clear()
        me.materials.append(mat)
        for poly in me.polygons:
            poly.material_index = 0

        # UVAtlas must be the active/first UV layer for the glTF exporter.
        for layer in list(me.uv_layers):
            if layer.name != "UVAtlas":
                me.uv_layers.remove(layer)
        me.uv_layers.active = me.uv_layers["UVAtlas"]

    return mat


def _make_atlas_material(name: str, image_path: str):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    tex = nt.nodes.new("ShaderNodeTexImage")

    img = bpy.data.images.load(image_path, check_existing=True)
    img.colorspace_settings.name = "sRGB"
    tex.image = img
    tex.interpolation = "Linear"

    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Roughness"].default_value = 0.72
    bsdf.inputs["Metallic"].default_value = 0.0
    return mat


def build_atlas_for(objs, out_png: str, overrides=None, surfaces=None) -> dict:
    """collect materials -> render atlas -> return slot map.

    ``overrides`` recolours specific materials (team tints, weapon finishes);
    ``surfaces`` forces a treatment for specific materials.
    """
    entries = collect_materials(objs)
    for mname, surf in (surfaces or {}).items():
        if mname in entries:
            entries[mname]["surface"] = surf
    if overrides:
        return palette.recolor_atlas(entries, overrides, out_png)
    return palette.build_atlas(entries, out_png)


# --- Transform helpers -------------------------------------------------------

def apply_transforms(objs) -> None:
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    if objs:
        bpy.context.view_layer.objects.active = objs[0]
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def join_meshes(objs, name: str):
    """Join meshes into one object (one draw call). Returns the survivor."""
    objs = [o for o in objs if o.type == "MESH"]
    if not objs:
        return None
    if len(objs) == 1:
        objs[0].name = name
        return objs[0]
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    survivor = bpy.context.view_layer.objects.active
    survivor.name = name
    return survivor


def normalize_size(obj, target_length: float, axis: str = "x") -> float:
    """Uniformly scale an object so its bounding box along `axis` equals
    target_length. Returns the scale factor applied."""
    dims = obj.dimensions
    cur = {"x": dims.x, "y": dims.y, "z": dims.z}[axis]
    if cur <= 1e-6:
        return 1.0
    f = target_length / cur
    obj.scale = (f, f, f)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return f


def add_marker(name: str, location, parent=None, rotation=(0, 0, 0)):
    """Empty used as an attachment point (muzzle, shell port, grip)."""
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = "ARROWS"
    e.empty_display_size = 0.05
    e.location = location
    e.rotation_euler = rotation
    bpy.context.scene.collection.objects.link(e)
    if parent is not None:
        e.parent = parent
    return e


# --- Export ------------------------------------------------------------------

def export_glb(path: str, with_animations: bool = False) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    kwargs = dict(
        filepath=path,
        export_format="GLB",
        export_yup=True,
        export_apply=False,
        export_materials="EXPORT",
        use_selection=False,
    )
    if with_animations:
        kwargs.update(export_animations=True, export_animation_mode="ACTIONS",
                      export_skins=True, export_force_sampling=True)
    else:
        kwargs.update(export_animations=False, export_skins=False)
    bpy.ops.export_scene.gltf(**kwargs)
    print(f"[export] {path} ({os.path.getsize(path)} bytes)")


def tri_count() -> int:
    total = 0
    for o in meshes():
        me = o.data
        total += sum(max(0, len(p.vertices) - 2) for p in me.polygons)
    return total
