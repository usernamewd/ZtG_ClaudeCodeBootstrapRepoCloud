# Performance

Target: **60 fps on a Snapdragon 7-class phone** with stable frame pacing, at
1080p with the Medium preset.

## How these numbers were obtained — and their limits

All figures below come from `tools/_diag/perf.tscn`, which loads
`scenes/game/match.tscn` (Saltline, 5v5, ten characters, full HUD), runs it for
18 seconds and reads `RenderingServer.get_rendering_info()` plus per-frame
deltas.

**The frame-time figures are not phone numbers and must not be read as such.**
This project was built in a headless Linux container with no GPU; rendering goes
through Mesa **llvmpipe**, a software rasteriser. Software rasterisation is
fill-rate bound in a way no mobile GPU is, so the measured frame time says almost
nothing about a real device.

What *is* device-independent, and what the budgets are actually about, is the
work submitted per frame: triangle count, draw calls, texture and buffer memory.
Those are measured honestly below.

Anyone with a device should re-run the probe on it:

```sh
adb install -r build/TacticalStrike.apk
adb logcat -c && adb logcat | grep -i godot     # the probe prints to logcat
```

## Measured — Saltline, 5v5, full HUD, Medium preset, 1280x720

| Metric | Budget | Measured | Status |
|---|---|---|---|
| Triangles in view | ≤150,000 | **42,096** | 28% of budget |
| Draw calls | ≤150 | **150** | at budget |
| Texture memory | — | 29.6 MB | |
| Buffer memory | — | 8.8 MB | |
| Video memory total | — | 38.4 MB | |
| CPU static memory | — | 48.0 MB | |
| Total memory in match | ≤512 MB | **~86 MB** | 17% of budget |
| Scene nodes | — | 625 | |
| Objects submitted | — | 705 | |

Triangles and memory have a wide margin. **Draw calls sit exactly on the
budget**, and that is the number to watch: it is dominated by the HUD, because
under the GL Compatibility renderer each `_draw()`-based Control costs its own
call. The 3D scene itself is cheap — the entire map shell is one mesh with one
material, and each character is two.

If draw calls need to come down further, in order of value:
1. Merge the static HUD readouts (health, armour, ammo) into a single custom
   `_draw()` Control instead of three.
2. Atlas the touch-control icons into one texture and draw them as a single
   multi-quad call rather than one Control per button.
3. `MultiMesh` the repeated map props once the environment kit lands.

## Optimisations applied

**Geometry and materials**
- Every map's architecture is merged into **one mesh with one material** by
  `tools/assets/build_maps.py` — a whole map shell is a single draw call
  (17.6k triangles for Saltline, 17.5k for Transit).
- The **palette-atlas pipeline** (`tools/assets/palette.py`) collapses every
  model's per-colour materials into one atlas-textured material. Source models
  ship 5–15 materials each; they render as one. This is the single largest
  draw-call saving in the project and it applies to characters, weapons, props
  and maps alike.
- Characters are decimated to budget at build time: 2,936 tris (Havoc) and
  2,976 (Aegis) against a 3,000 budget, from ~5,800-triangle sources.
- Weapons are 1,300–1,500 triangles each, normalised to real-world lengths.
- Collision uses the **designed box volumes**, not the shell's relief geometry —
  cheaper to test and it stops players snagging on decorative plinths.

**Lighting**
- Realtime directional shadows are **off on Low and Medium** and on only at High
  (`Settings.apply_shadow_preset`, maps register their sun in the `sun_light`
  group). Shadows were the largest single GPU cost measured.
- Ambient comes from the sky, so the scene is lit without additional lights.
  There are no point or spot lights in either map's static lighting.
- Fog provides depth cueing at effectively zero cost instead of extra geometry.

**Textures**
- Atlases are 512² and the project imports with **ETC2/ASTC VRAM compression**
  enabled (`textures/vram_compression/import_etc2_astc=true`), so textures stay
  compressed in VRAM on device.
- One texture per model, and cosmetic finishes reuse identical geometry and UVs
  with a recoloured atlas — a weapon skin costs one texture and zero draw calls.

**Render scaling** (`Settings.apply_graphics_preset`)

| Preset | 3D render scale | MSAA | Shadows |
|---|---|---|---|
| Low | 0.70 | off | off |
| Medium | 0.85 | 2x | off |
| High | 1.00 | 4x | on |

**Allocation discipline** — the rule is zero heap allocation per frame in
gameplay code:
- `Pools` preallocates every tracer, impact, grenade, smoke volume, fire area
  and blast effect at match start; nothing is instantiated during a round and
  nothing is `queue_free`d.
- The kill feed reuses a fixed set of five rows forever.
- `Weapon` preallocates its ray-query object; `BotBrain` preallocates its ray
  parameters and its enemy list and clears rather than rebuilds them.
- `BotBlackboard` preallocates its contact slots and recycles them through a
  free list.

**CPU scheduling**
- Bot perception runs at **10 Hz** and planning at **2 Hz**, not per frame, and
  each bot's phase is offset at spawn so ten bots never think on the same frame.
- Only aiming, combat and movement run per physics tick.
- Footsteps are derived from distance travelled rather than animation callbacks,
  so they cost nothing extra and stay correct across every animation blend.

**Culling**
- Occlusion culling is enabled project-wide
  (`occlusion_culling/use_occlusion_culling=true`); frustum culling is engine
  default.
- `max_fps` is pinned to 60 so the renderer never burns battery running ahead of
  the display.

## Known gaps

- **Draw calls are at budget, not under it.** The mitigations above are
  identified but not yet applied; the HUD is the place to spend that effort.
- **No LODs yet.** With 42k triangles in view the need is not yet real, but
  characters are the right first candidate once prop density increases.
- **No on-device measurement.** Everything here is from a software rasteriser.
  The APK builds and installs; the frame-rate claim in the target line is a
  design target, not a measured result, until someone runs it on hardware.
