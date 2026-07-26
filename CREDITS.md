# Credits and Asset Licences

Tactical Strike contains no assets from Counter-Strike or any other commercial
game. Nothing was downloaded, traced, ripped or reproduced from a commercial
title — no art, no screenshots, no HUD graphics, no logos, no map layouts, no
model designs. Genre mechanics (a buy economy, defusal rounds, a scoreboard, a
radar) are implemented from scratch as original work; the expression is ours.

Everything shipped falls into one of three buckets:

1. **Original code** — all game logic, UI design, map layouts, balance and
   branding are original work created for this project.
2. **Procedurally generated art** — every texture, all audio, the app icon, the
   skyboxes and the modular architecture set are synthesized by scripts in
   `tools/assets/` (Pillow, numpy and Blender's Python API). No external source.
3. **CC0 source geometry** — a small number of base meshes and rigs come from
   the public-domain packs listed below, then get retextured, rescaled, merged
   and re-animated by our pipeline.

## CC0 source packs

All packs below are released by **Quaternius** under
[Creative Commons Zero v1.0 Universal (CC0)](https://creativecommons.org/publicdomain/zero/1.0/)
— public domain dedication, no attribution required. We credit them anyway.

| Pack | Source | Licence | Used for |
|---|---|---|---|
| Toon Shooter Game Kit | https://quaternius.com/packs/toonshootergamekit.html | CC0 1.0 | Rigged 43-bone humanoid characters and their base animation set; environment props; grenade and knife meshes |
| Ultimate Gun Pack | https://quaternius.com/packs/ultimategun.html | CC0 1.0 | Firearm base meshes and weapon accessories (scopes, silencers, grips, stocks) |
| Animated Guns | https://quaternius.com/packs/animatedguns.html | CC0 1.0 | Reference rigs for weapon part motion (slide, magazine, trigger) |
| Modular Streets | https://quaternius.com/packs/modularstreets.html | CC0 1.0 | Street, kerb and street-furniture pieces for map exteriors |
| Survival Pack | https://quaternius.com/packs/survival.html | CC0 1.0 | Industrial and urban clutter props |

Licence verification: each pack's page was checked for its CC0 declaration
before use; the licence link above is the one published on the pack page.

CC0 imposes no conditions, so no attribution obligation is outstanding. No
CC-BY assets are used, and therefore no attribution-required entries exist.

## Procedurally generated (no external source)

| Asset | Generator |
|---|---|
| App icon and adaptive icon layers | `tools/gen_icon.py` |
| All palette-atlas textures (characters, weapons, environment) | `tools/assets/palette.py` |
| Modular architecture set (walls, floors, stairs, pillars, catwalks) | `tools/assets/build_env.py` |
| Skybox panoramas | `tools/assets/build_env.py` |
| Every sound effect | `tools/assets/build_audio.py` (numpy synthesis) |
| Weapon finishes / cosmetic skins | `tools/assets/palette.py` recolouring |
| First-person viewmodel animations | `tools/assets/build_viewmodel.py` |
| Additional character animations (strafe, crouch, reload, plant, defuse, deaths) | `tools/assets/build_animations.py` |

## Engine and tooling

| | |
|---|---|
| [Godot Engine 4.5](https://godotengine.org) | MIT License |
| [Blender 4.2 LTS](https://blender.org) (build-time only) | GPLv3 — used as a tool; does not affect output licensing |
| [Pillow](https://python-pillow.org), [NumPy](https://numpy.org) (build-time only) | MIT-CMU / BSD-3-Clause |

Godot's Android build template under `android/` is part of Godot Engine and is
covered by its MIT licence, together with the third-party licences Godot itself
ships.

## Fonts

The UI uses Godot's built-in default font (Open Sans, Apache License 2.0, bundled
with the engine). No additional fonts are shipped.
