# Tactical Strike — Asset Pipeline

All art is generated from CC0 source packs by scripts in `tools/assets/`, so the
repo stays small and every asset is reproducible. Nothing is hand-edited in a
binary editor. **Every source pack used is CC0 (public domain) — verified per
pack, recorded in CREDITS.md.**

## Tooling (installed in this environment)

| Tool | Path | Purpose |
|---|---|---|
| Blender | `/opt/blender/blender` (also `blender`) | 4.2.9 LTS, headless model/anim authoring |
| Blender Python | `/opt/blender/4.2/python/bin/python3.11` | has Pillow + numpy installed |
| Godot | `/opt/godot/godot` | 4.5 stable, import + preview render |
| Source packs | `/opt/assets_cc0/` | CC0 packs, see below |

## Source packs (all CC0, Quaternius)

| Dir | Contents | Used for |
|---|---|---|
| `toonshooter` | 3 rigged characters (43-bone humanoid, 17 anims), 16 guns, ~60 environment props | characters, animations, props |
| `ultimategun` | 34 detailed guns (AR/bullpup/pistol/revolver/shotgun/sniper) + accessories | weapon models |
| `animatedguns` | 6 guns rigged with Fire/Reload actions (slide, magazine, trigger bones) | viewmodel part animation reference |
| `modularstreets` | 25 street/bridge/sign pieces | map exteriors |
| `survival` | 53 survival props | map dressing |

The character rig (all three characters share it):
```
Root > Body > Hips > Abdomen > Torso > Neck > Head
                                     > Shoulder.L/R > UpperArm > LowerArm > {Thumb,Index,Middle,Pinky}{1..3}
              > UpperLeg.L/R > LowerLeg.L/R
Root > Foot.L/R, PoleTarget.L/R      (IK targets)
```
`Body` (2247 verts) and `Head` (700 verts) are **separate mesh objects**, and
Godot imports `Head` under a `BoneAttachment3D`. That is what makes full-body
first person cheap: hide `Head` for the local player.

Stock animations: `Idle, Idle_Shoot, Walk, Walk_Shoot, Run, Run_Gun, Run_Shoot,
Duck, Jump, Jump_Idle, Jump_Land, Death, HitReact, Punch, Wave, No, Yes`.
Missing (must be authored): strafe left/right, crouch-walk, reload, plant,
defuse, weapon draw, extra death variants.

## The palette atlas (`tools/assets/palette.py`)

Source models are flat-shaded, one material per colour, no UVs. Shipping that
directly means one draw call per colour and a flat plastic look. Instead:

1. `build_atlas(entries, out_png)` renders a 512x512, 8x8-slot atlas. Each slot
   gets its material's colour plus a procedural surface treatment picked by
   `classify()` from the material name — brushed **metal** with scratches,
   **wood** grain, woven **fabric**, **skin**, **rubber**, **concrete**.
2. `blender_common.atlas_remap(objs, slots, png)` gives every face UVs inside its
   colour's patch (projected from geometry, so grain varies across a surface),
   then collapses all material slots into ONE atlas-textured material.

Result per model: **1 material, 1 texture, 1 draw call**, with real surface
detail. Colours are converted linear→sRGB on write (Blender reports linear;
skipping this bakes everything near-black).

Cosmetics fall out of this for free: a weapon *finish* is the same geometry and
UVs with a recoloured atlas (`palette.recolor_atlas`). Team skins likewise.

Patch UVs are inset 18% so mip-mapping never bleeds between slots.

## `tools/assets/blender_common.py` API

```python
reset_scene(); import_any(path)                  # fbx / gltf / glb / obj
meshes(); armatures(); keep_only(names); delete_objects(objs)
collect_materials(objs) -> {name: {"color": rgb_linear}}
build_atlas_for(objs, out_png, overrides=None, surfaces=None) -> {name: slot}
atlas_remap(objs, slots, png, material_name, jitter=0.7)
join_meshes(objs, name)                          # one draw call
normalize_size(obj, target_length, axis="x")     # returns scale factor
apply_transforms(objs); add_marker(name, loc, parent, rot)
export_glb(path, with_animations=False)
tri_count()
```

## Conventions

- **Units: metres.** Rifles ~0.90 m long, pistols ~0.22 m, characters ~1.8 m tall.
- **Orientation:** every weapon exports with its barrel pointing **+Z** (Godot
  forward is −Z, so the mount rotates it; keeping the source consistent is what
  matters), grip down −Y. Normalize along the barrel axis.
- **Attachment markers** (Blender Empties, exported as Node3D):
  `Muzzle` (barrel tip, where flash/tracer spawn), `ShellPort` (ejection port),
  `GripR` / `GripL` (where the right/left hand bone attaches), `Sight` (ADS eye
  target, used to align the aim pose).
- **Naming:** `assets/weapons/<weapon_id>/tp.glb` (third person), `vm.glb`
  (viewmodel geometry), `<weapon_id>_atlas.png`. Characters:
  `assets/characters/<name>.glb` + `<name>_atlas.png`. Environment:
  `assets/env/<kit>/<piece>.glb`.
- **Budgets:** weapon TP ≤1500 tris, viewmodel ≤3000, character ≤3000,
  prop ≤600. Atlas textures 512² max (256² for props), imported with
  ETC2/ASTC VRAM compression.
- Every builder script is rerunnable from scratch and prints what it wrote.
  `tools/assets/build_all.py` runs the whole pipeline.

## Verifying a model in-engine (mandatory before calling an asset done)

```sh
/opt/godot/godot --headless --import
xvfb-run -a -s "-screen 0 1280x720x24" /opt/godot/godot --rendering-driver opengl3 \
  --resolution 1280x720 --path . --script tools/preview_model.gd -- \
  res://assets/weapons/ar77/tp.glb /tmp/ar77.png 35
```
`preview_model.gd` frames the subject from its AABB on a lit studio set and
prints the triangle count. It also takes `[anim_name] [anim_time]` to pose a
rigged model. **Look at the PNG.** The bar: it must read as a real firearm or a
real soldier — never an untextured box or capsule.

## First-person viewmodel plan

The local player renders **two** things:
1. **Full body** — the normal character model with `Head` hidden and the arm
   bones scaled to zero, so looking down shows animated legs and torso driven by
   the same locomotion state machine as everyone else.
2. **Viewmodel** — arms + weapon on a separate camera layer with a near clip
   plane, so it never intersects world geometry.

The viewmodel arms are extracted from the character `Body` mesh: 976 of its 2247
verts are dominated by arm bones (`Shoulder/UpperArm/LowerArm/{Thumb,Index,
Middle,Pinky}{1..3}` on both sides), which separates cleanly into a ~950-tri
arms mesh that matches the third-person art style exactly.

The **hold pose is taken from the stock `Idle_Shoot` action** rather than
authored blind — it is an artist-made two-handed weapon pose. Viewmodel
animations (draw, idle, fire, reload, inspect) are authored as keyframed offsets
from that pose.
