#!/usr/bin/env python3
"""Build the Tactical Strike first-person viewmodel (arms + authored animations).

    python3 tools/assets/build_viewmodel.py                  # assets/viewmodel/*
    python3 tools/assets/build_viewmodel.py --mounted        # + a debug GLB with
                                                             #   assets/weapons/ar77/tp.glb
                                                             #   welded to the mount
    python3 tools/assets/build_viewmodel.py --pov            # + Cycles POV frames
                                                             #   (composition check)

The script re-launches itself inside Blender (`blender -b <blend> --python ...`)
because the character rig has to be *opened*, not imported.

Pipeline
--------
1.  Open the CC0 ToonShooter soldier .blend, drop the 15 prop weapons and the
    head, and split `Body` (2247 verts) into the polygons whose skin weight is
    >50 % owned by an arm bone -- 926 quads / 1856 tris of forearm, sleeve and
    hand in exactly the art style of the third-person characters. Cap the open
    shoulder rings.
2.  Trim the 43-bone rig to the 33 bones the arms need
    (`Root > Body > Hips > Abdomen > Torso > Shoulder.L/R > UpperArm > LowerArm
    > {Thumb,Index,Middle,Pinky}{1..3}`), drop the legs/neck/head/IK targets and
    renormalise the skin weights that referenced them.
3.  Zone-split the four source materials into semantic zones (sleeve, elbow pad,
    forearm accent band, webbing, glove, knuckle, cuff) using material + position
    on the arm, bake a 512x512 palette atlas per team, `atlas_remap` to one
    material / one texture / one draw call.
4.  Scale the rig to metres (1.80 m character) and move it so the *camera* sits
    at the origin, then solve the two-handed hold: the weapon is placed where it
    should sit on screen and each hand is IK'd onto the weapon's own `GripR` /
    `GripL` markers with a hand frame built from the rig's knuckle geometry.
    The solved pose is applied as the armature's **rest pose**, so arms.glb is
    already holding a rifle before any animation plays.
5.  Author `vm_idle / vm_draw / vm_fire / vm_fire_ads / vm_reload / vm_inspect /
    vm_melee` as Bezier-eased offsets from that rest pose and export with skin +
    animations.

Hold-pose note (differs from docs/ASSET_PIPELINE.md): the stock `Idle_Shoot`
action is **not** a two-handed hold -- its left arm hangs at the hip (the hands
are 0.84 rig-units apart). `Run_Shoot` frame 0 is the closest artist-made
two-handed pose (0.515 apart) and is used as the IK seed pose so the elbows
settle where the artist put them; the final grip is then solved onto the real
weapon markers. See the phase report.

Source: Quaternius "Ultimate Toon Shooter" (CC0)
  /opt/assets_cc0/toonshooter/Characters/Blends/Character_Soldier.blend
  (objects `Body` + `CharacterArmature`, action `Run_Shoot`)
Weapon used for the mount check: assets/weapons/ar77/tp.glb (built by the
weapons phase from ultimategun, CC0).
"""
from __future__ import annotations

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OUT_DIR = os.path.join(REPO, "assets", "viewmodel")
BLEND = "/opt/assets_cc0/toonshooter/Characters/Blends/Character_Soldier.blend"
BLENDER = "/opt/blender/blender"
REF_WEAPON = os.path.join(REPO, "assets", "weapons", "ar77", "tp.glb")
REF_MANIFEST = os.path.join(REPO, "assets", "weapons", "manifest.json")

TARGET_HEIGHT = 1.80          # metres, per docs/ASSET_PIPELINE.md
TRI_BUDGET = 3000             # viewmodel budget
FPS = 60

# --------------------------------------------------------------------------
# Placement tunables.  All in metres, Blender axes on the *scaled* rig:
#   +X = the soldier's left, -Y = forward (where the camera looks), +Z = up.
# The exported GLB is Y-up, so Blender -Y becomes glTF +Z: the viewmodel faces
# +Z exactly like every weapon and character in this project.
# --------------------------------------------------------------------------
EYE = (0.0, -0.10, 1.55)      # camera point in scaled character space
RIG_PUSH = 0.30               # shove the whole rig this far forward (-Y) so the
                              # support hand can actually reach the handguard;
                              # the shoulders end up behind/below the frustum.

# Where the weapon sits relative to the camera, and how it is angled.
HOLD_POS = (-0.070, -0.400, -0.285)   # weapon origin (= its GripR marker)
HOLD_YAW = 13.0               # + swings the muzzle toward the soldier's left
HOLD_PITCH = -2.0             # + points the muzzle down
HOLD_ROLL = 7.0               # + rolls the weapon clockwise seen from behind

# Hand frame corrections, degrees, about the axis the fist wraps.
GRIP_R_TWIST = -14.0          # trigger hand roll around the pistol grip
GRIP_L_TWIST = 44.0           # support hand roll around the handguard
GRIP_R_SHIFT = (0.010, -0.030, 0.005)   # weapon-local nudge of the palm centre
GRIP_L_SHIFT = (0.012, -0.045, -0.040)

# Reference weapon markers (glTF/Godot space: barrel +Z, up +Y) -- read from
# assets/weapons/manifest.json when it exists, these are the ar77 fallbacks.
GRIP_R_MARKER = (0.0, 0.0, 0.0)
GRIP_L_MARKER = (0.0, 0.12702, 0.34263)

BLADE = 6.0                   # torso rotation toward the support side, degrees
SHOULDER_L_FWD = 16.0         # support shoulder protraction, degrees
SHOULDER_R_BACK = 6.0

# --------------------------------------------------------------------------
# Art direction
# --------------------------------------------------------------------------

def _s2l(c: float) -> float:
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hx(h: str):
    """'#RRGGBB' (sRGB) -> linear rgb, the space palette.py expects."""
    h = h.lstrip("#")
    return tuple(_s2l(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


SURFACE = {
    "Sleeve": "fabric", "Cuff": "fabric", "Accent": "fabric", "Fatigue": "fabric",
    "ElbowPad": "rubber", "Rig": "wood", "Pouch": "fabric",
    "Glove": "fabric", "GloveKnuckle": "rubber", "GloveCuff": "wood",
}

# Defender (aegis) viewmodel: slate uniform, black nomex gloves, navy band.
PALETTE = {
    "Sleeve":       hx("#414B58"),
    "Cuff":         hx("#2A303A"),
    "ElbowPad":     hx("#22262D"),
    "Accent":       hx("#2E5FA8"),
    "Rig":          hx("#17191E"),
    "Pouch":        hx("#1F242B"),
    "Fatigue":      hx("#313944"),
    "Glove":        hx("#1B1F25"),
    "GloveKnuckle": hx("#2E353F"),
    "GloveCuff":    hx("#242A32"),
}
# Attacker (havoc) viewmodel: khaki field jacket, brown leather gloves, orange.
PALETTE_HAVOC = {
    "Sleeve":       hx("#3E3426"),
    "Cuff":         hx("#2A2418"),
    "ElbowPad":     hx("#2A2015"),
    "Accent":       hx("#FF7A1A"),
    "Rig":          hx("#4E3018"),
    "Pouch":        hx("#2A1C0C"),
    "Fatigue":      hx("#6E6139"),
    "Glove":        hx("#3A2A1A"),
    "GloveKnuckle": hx("#54402A"),
    "GloveCuff":    hx("#2B2113"),
}

# Zone thresholds, in *source* rig units (wrist at |x| = 0.979, elbow at 0.539,
# shoulder joint at 0.152).
X_KNUCKLE = 1.14
X_WRIST = 0.995
X_CUFF = 0.90
X_BAND_LO, X_BAND_HI = 0.62, 0.755
X_ELBOW_LO, X_ELBOW_HI = 0.46, 0.615
X_SHOULDER = 0.30
X_ARM_CUT = 0.29              # everything inboard of this is chest/deltoid scrap
                              # that the weight test drags along -- it sits
                              # behind the camera and only ever shows as
                              # floating chunks, so cut the arm off here.

ARM_BONES = set()
for _s in ("L", "R"):
    ARM_BONES |= {f"Shoulder.{_s}", f"UpperArm.{_s}", f"LowerArm.{_s}"}
    for _f in ("Thumb", "Index", "Middle", "Pinky"):
        for _i in (1, 2, 3):
            ARM_BONES.add(f"{_f}{_i}.{_s}")

KEEP_BONES = {"Root", "Body", "Hips", "Abdomen", "Torso"} | ARM_BONES


def zone(src: str, x: float, y: float, z: float) -> str:
    """Semantic zone for one polygon of the arm mesh."""
    ax = abs(x)
    if src == "Skin":                       # the source only puts Skin on hands
        if ax >= X_KNUCKLE:
            return "GloveKnuckle"
        if ax >= X_WRIST:
            return "Glove"
        return "GloveCuff"
    if src == "Black":                      # the sleeve, shoulder to wrist
        if ax >= X_CUFF:
            return "Cuff"
        if X_BAND_LO <= ax <= X_BAND_HI:
            return "Accent"                 # team band on the forearm
        if X_ELBOW_LO <= ax <= X_ELBOW_HI and y > 0.0:
            return "ElbowPad"               # elbow points +Y in the rest T-pose
        if ax < X_SHOULDER:
            return "Rig"                    # webbing over the deltoid
        return "Sleeve"
    if src == "DarkGrey":
        return "Pouch"
    return "Fatigue"


# ==========================================================================
# Animation score.  Everything below is authored in *armature* space:
#   world_right = -X, world_forward = -Y, world_up = +Z.
# `rot` entries are (axis, degrees) applied about the armature axes, `loc` is a
# metre offset in armature space; both are converted into the bone's local space
# at bake time so the numbers here stay readable.
# ==========================================================================

RIGHT = (-1.0, 0.0, 0.0)
FWD = (0.0, -1.0, 0.0)
UP = (0.0, 0.0, 1.0)


def _k(frame, **kw):
    return dict(f=frame, **kw)


def anim_idle():
    """4 s breathing loop. Sampled from sine curves so the last key == the
    first; the two arms run at slightly different phase so it never reads as a
    single rigid object bobbing."""
    keys = {"Body": [], "UpperArm.L": [], "UpperArm.R": [], "LowerArm.L": []}
    n = 240
    for i in range(0, n + 1, 8):
        t = i / n
        breathe = math.sin(t * 2.0 * math.tau)          # 2 breaths in 4 s
        sway = math.sin(t * math.tau)                   # 1 slow figure-8
        sway2 = math.sin(t * 2.0 * math.tau + 1.1)
        keys["Body"].append(_k(i,
            loc=(sway * 0.009, breathe * 0.004, breathe * 0.0065),
            rot=[(RIGHT, -breathe * 0.85), (UP, sway * 1.5), (FWD, sway2 * 0.7)]))
        lag = math.sin((t - 0.06) * 2.0 * math.tau)
        keys["UpperArm.L"].append(_k(i, rot=[(FWD, lag * 1.4), (UP, -lag * 1.0)]))
        keys["UpperArm.R"].append(_k(i, rot=[(FWD, breathe * 1.1), (UP, breathe * 0.8)]))
        keys["LowerArm.L"].append(_k(i, rot=[(RIGHT, lag * 1.8)]))
    return dict(name="vm_idle", frames=n, loop=True, keys=keys)


def anim_draw():
    """0.55 s: the weapon swings up from below-right into the hold, overshoots a
    little and settles. The support hand arrives ~3 frames after the rifle."""
    return dict(name="vm_draw", frames=33, loop=False, keys={
        "Body": [
            _k(0,  loc=(-0.035, 0.030, -0.230), rot=[(RIGHT, 34.0), (UP, -16.0), (FWD, -22.0)], ease="EASE_OUT"),
            _k(9,  loc=(-0.020, 0.010, -0.095), rot=[(RIGHT, 15.0), (UP, -7.0), (FWD, -10.0)]),
            _k(20, loc=(0.004, -0.008, 0.016), rot=[(RIGHT, -5.5), (UP, 2.0), (FWD, 2.5)]),
            _k(27, loc=(-0.001, 0.002, -0.005), rot=[(RIGHT, 1.8), (UP, -0.6), (FWD, -0.8)]),
            _k(33, loc=(0, 0, 0), rot=[]),
        ],
        "UpperArm.R": [
            _k(0,  rot=[(FWD, -26.0), (RIGHT, 16.0)], ease="EASE_OUT"),
            _k(12, rot=[(FWD, -9.0), (RIGHT, 5.0)]),
            _k(22, rot=[(FWD, 3.0), (RIGHT, -2.0)]),
            _k(33, rot=[]),
        ],
        "UpperArm.L": [
            _k(0,  rot=[(FWD, 30.0), (UP, -22.0), (RIGHT, 10.0)], ease="EASE_OUT"),
            _k(14, rot=[(FWD, 13.0), (UP, -9.0), (RIGHT, 4.0)]),
            _k(25, rot=[(FWD, -4.5), (UP, 3.0)]),
            _k(33, rot=[]),
        ],
        "LowerArm.L": [
            _k(0,  rot=[(RIGHT, 28.0)], ease="EASE_OUT"),
            _k(16, rot=[(RIGHT, 10.0)]),
            _k(26, rot=[(RIGHT, -3.5)]),
            _k(33, rot=[]),
        ],
        "LowerArm.R": [
            _k(0, rot=[(RIGHT, 12.0)], ease="EASE_OUT"),
            _k(18, rot=[(RIGHT, 3.0)]),
            _k(33, rot=[]),
        ],
    })


def _recoil(name, frames, kick, rise, shove, twist):
    """Shared shape for the two fire animations: 2-frame punch back+up, then an
    eased settle that dips just past the rest pose before returning."""
    f_pk = max(1, int(round(frames * 0.28)))
    f_ov = max(f_pk + 1, int(round(frames * 0.62)))
    return dict(name=name, frames=frames, loop=False, keys={
        "Body": [
            _k(0, loc=(0, 0, 0), rot=[], ease="EASE_OUT"),
            _k(f_pk, loc=(kick * 0.20, kick, rise),
               rot=[(RIGHT, -shove), (UP, twist), (FWD, -twist * 0.8)], ease="EASE_IN_OUT"),
            _k(f_ov, loc=(-kick * 0.08, -kick * 0.22, -rise * 0.30),
               rot=[(RIGHT, shove * 0.26), (UP, -twist * 0.3)], ease="EASE_IN_OUT"),
            _k(frames, loc=(0, 0, 0), rot=[]),
        ],
        "LowerArm.R": [
            _k(0, rot=[], ease="EASE_OUT"),
            _k(f_pk, rot=[(RIGHT, -shove * 0.7), (FWD, -twist)]),
            _k(f_ov, rot=[(RIGHT, shove * 0.2)]),
            _k(frames, rot=[]),
        ],
        "UpperArm.L": [
            _k(0, rot=[], ease="EASE_OUT"),
            _k(f_pk + 1, rot=[(FWD, twist * 1.4), (RIGHT, -shove * 0.35)]),
            _k(f_ov + 1 if f_ov + 1 < frames else frames, rot=[(FWD, -twist * 0.4)]),
            _k(frames, rot=[]),
        ],
        "Index2.R": [
            _k(0, curl=0.0), _k(f_pk, curl=26.0), _k(frames, curl=0.0),
        ],
    })


def anim_fire():
    return _recoil("vm_fire", 7, kick=0.032, rise=0.012, shove=8.5, twist=2.6)


def anim_fire_ads():
    return _recoil("vm_fire_ads", 6, kick=0.014, rise=0.005, shove=4.0, twist=1.0)


def anim_reload():
    """2.2 s magazine change. The rifle rolls its magazine well toward the
    camera, the support hand leaves the handguard, strips the old magazine
    (down + out), fetches a fresh one from the chest, drives it home with a
    slap, then hits the bolt release and returns to the handguard."""
    E = "EASE_IN_OUT"
    return dict(name="vm_reload", frames=132, loop=False, keys={
        # the rifle itself: tilt over, dip, kick on the mag slap and bolt, recover
        "Body": [
            _k(0,   loc=(0, 0, 0), rot=[], ease="EASE_OUT"),
            _k(16,  loc=(-0.020, 0.012, -0.055), rot=[(FWD, 26.0), (RIGHT, 9.0), (UP, -7.0)], ease=E),
            _k(46,  loc=(-0.026, 0.016, -0.068), rot=[(FWD, 31.0), (RIGHT, 11.0), (UP, -9.0)], ease=E),
            _k(60,  loc=(-0.024, 0.014, -0.060), rot=[(FWD, 29.0), (RIGHT, 10.0), (UP, -8.0)], ease=E),
            _k(88,  loc=(-0.022, 0.014, -0.058), rot=[(FWD, 30.0), (RIGHT, 10.0), (UP, -8.0)], ease=E),
            _k(93,  loc=(-0.022, 0.014, -0.074), rot=[(FWD, 30.0), (RIGHT, 15.0), (UP, -8.0)], ease="EASE_OUT"),  # mag slap
            _k(99,  loc=(-0.021, 0.013, -0.052), rot=[(FWD, 29.0), (RIGHT, 7.0), (UP, -8.0)], ease=E),
            _k(108, loc=(-0.016, 0.008, -0.056), rot=[(FWD, 22.0), (RIGHT, 10.0), (UP, -6.0)], ease=E),
            _k(112, loc=(-0.014, 0.010, -0.048), rot=[(FWD, 19.0), (RIGHT, 6.0), (UP, -5.0)], ease="EASE_OUT"),  # bolt release
            _k(124, loc=(0.004, -0.004, 0.012), rot=[(FWD, -4.0), (RIGHT, -2.5), (UP, 1.5)], ease=E),
            _k(132, loc=(0, 0, 0), rot=[]),
        ],
        # support arm: off the handguard, down to the magwell, out, fetch, in
        "UpperArm.L": [
            _k(0,   rot=[], ease="EASE_OUT"),
            _k(14,  rot=[(FWD, 16.0), (UP, -10.0), (RIGHT, -6.0)], ease=E),
            _k(30,  rot=[(FWD, 30.0), (UP, -20.0), (RIGHT, -10.0)], ease=E),   # hand at magwell
            _k(46,  rot=[(FWD, 40.0), (UP, -26.0), (RIGHT, -6.0)], ease=E),    # strip mag
            _k(62,  rot=[(FWD, 54.0), (UP, -34.0), (RIGHT, 4.0)], ease=E),     # down to the pouch
            _k(74,  rot=[(FWD, 50.0), (UP, -31.0), (RIGHT, 2.0)], ease=E),     # grab fresh mag
            _k(90,  rot=[(FWD, 28.0), (UP, -18.0), (RIGHT, -9.0)], ease="EASE_IN"),
            _k(94,  rot=[(FWD, 22.0), (UP, -14.0), (RIGHT, -12.0)], ease="EASE_OUT"),  # slap home
            _k(104, rot=[(FWD, 26.0), (UP, -17.0), (RIGHT, -8.0)], ease=E),
            _k(112, rot=[(FWD, 14.0), (UP, -9.0), (RIGHT, -14.0)], ease=E),    # bolt release
            _k(124, rot=[(FWD, -5.0), (UP, 3.0), (RIGHT, 2.0)], ease=E),
            _k(132, rot=[]),
        ],
        "LowerArm.L": [
            _k(0,   rot=[], ease="EASE_OUT"),
            _k(14,  rot=[(RIGHT, 20.0), (FWD, 8.0)], ease=E),
            _k(30,  rot=[(RIGHT, 40.0), (FWD, 14.0)], ease=E),
            _k(46,  rot=[(RIGHT, 50.0), (FWD, 16.0)], ease=E),
            _k(62,  rot=[(RIGHT, 66.0), (FWD, 20.0)], ease=E),
            _k(74,  rot=[(RIGHT, 60.0), (FWD, 18.0)], ease=E),
            _k(90,  rot=[(RIGHT, 34.0), (FWD, 10.0)], ease="EASE_IN"),
            _k(94,  rot=[(RIGHT, 24.0), (FWD, 6.0)], ease="EASE_OUT"),
            _k(104, rot=[(RIGHT, 32.0), (FWD, 9.0)], ease=E),
            _k(112, rot=[(RIGHT, 16.0), (FWD, 4.0)], ease=E),
            _k(124, rot=[(RIGHT, -6.0)], ease=E),
            _k(132, rot=[]),
        ],
        "Shoulder.L": [
            _k(0, rot=[], ease="EASE_OUT"),
            _k(34, rot=[(FWD, 7.0), (UP, -5.0)], ease=E),
            _k(66, rot=[(FWD, 12.0), (UP, -8.0)], ease=E),
            _k(96, rot=[(FWD, 5.0), (UP, -3.0)], ease=E),
            _k(132, rot=[]),
        ],
        # support hand opens to release, closes on the magazine, opens again
        "_fingers.L": [
            _k(0, curl=0.0, ease="EASE_OUT"),
            _k(20, curl=-34.0, ease=E),      # open, off the handguard
            _k(34, curl=16.0, ease=E),       # close on the magazine
            _k(62, curl=22.0, ease=E),
            _k(74, curl=20.0, ease=E),
            _k(94, curl=6.0, ease=E),
            _k(106, curl=-26.0, ease=E),     # open again
            _k(124, curl=4.0, ease=E),
            _k(132, curl=0.0),
        ],
    })


def anim_inspect():
    """3 s: bring the rifle up and turn it over to look at both sides."""
    E = "EASE_IN_OUT"
    return dict(name="vm_inspect", frames=180, loop=False, keys={
        "Body": [
            _k(0,   loc=(0, 0, 0), rot=[], ease="EASE_OUT"),
            _k(34,  loc=(0.028, -0.030, 0.060), rot=[(FWD, -46.0), (UP, 22.0), (RIGHT, 12.0)], ease=E),
            _k(58,  loc=(0.032, -0.034, 0.066), rot=[(FWD, -52.0), (UP, 25.0), (RIGHT, 15.0)], ease=E),
            _k(84,  loc=(0.030, -0.026, 0.058), rot=[(FWD, -20.0), (UP, 6.0), (RIGHT, 24.0)], ease=E),
            _k(116, loc=(0.020, -0.030, 0.050), rot=[(FWD, 62.0), (UP, -18.0), (RIGHT, 6.0)], ease=E),
            _k(140, loc=(0.016, -0.026, 0.042), rot=[(FWD, 66.0), (UP, -20.0), (RIGHT, -4.0)], ease=E),
            _k(166, loc=(-0.004, 0.006, -0.012), rot=[(FWD, -6.0), (UP, 3.0), (RIGHT, -3.0)], ease=E),
            _k(180, loc=(0, 0, 0), rot=[]),
        ],
        "UpperArm.R": [
            _k(0, rot=[], ease="EASE_OUT"),
            _k(40, rot=[(FWD, 9.0), (RIGHT, -7.0)], ease=E),
            _k(116, rot=[(FWD, -10.0), (RIGHT, -3.0)], ease=E),
            _k(168, rot=[(FWD, 2.0)], ease=E),
            _k(180, rot=[]),
        ],
        "UpperArm.L": [
            _k(0, rot=[], ease="EASE_OUT"),
            _k(30, rot=[(FWD, 14.0), (UP, -8.0)], ease=E),
            _k(58, rot=[(FWD, 18.0), (UP, -10.0)], ease=E),
            _k(96, rot=[(FWD, 10.0), (UP, -4.0)], ease=E),
            _k(124, rot=[(FWD, 24.0), (UP, -14.0)], ease=E),
            _k(170, rot=[(FWD, -3.0)], ease=E),
            _k(180, rot=[]),
        ],
        "LowerArm.L": [
            _k(0, rot=[], ease="EASE_OUT"),
            _k(34, rot=[(RIGHT, 22.0)], ease=E),
            _k(96, rot=[(RIGHT, 14.0)], ease=E),
            _k(128, rot=[(RIGHT, 30.0)], ease=E),
            _k(170, rot=[(RIGHT, -4.0)], ease=E),
            _k(180, rot=[]),
        ],
        "_fingers.L": [
            _k(0, curl=0.0), _k(40, curl=-12.0, ease=E), _k(110, curl=8.0, ease=E),
            _k(150, curl=-6.0, ease=E), _k(180, curl=0.0),
        ],
    })


def anim_melee():
    """0.5 s stock/blade slash: wind up right, slash across left, recover."""
    return dict(name="vm_melee", frames=30, loop=False, keys={
        "Body": [
            _k(0,  loc=(0, 0, 0), rot=[], ease="EASE_IN"),
            _k(7,  loc=(-0.070, 0.075, 0.055), rot=[(UP, -30.0), (RIGHT, -16.0), (FWD, -22.0)], ease="EASE_IN"),
            _k(15, loc=(0.105, -0.115, -0.055), rot=[(UP, 44.0), (RIGHT, 22.0), (FWD, 30.0)], ease="EASE_OUT"),
            _k(20, loc=(0.070, -0.070, -0.035), rot=[(UP, 30.0), (RIGHT, 14.0), (FWD, 20.0)], ease="EASE_IN_OUT"),
            _k(25, loc=(-0.016, 0.014, 0.010), rot=[(UP, -7.0), (RIGHT, -3.0), (FWD, -5.0)], ease="EASE_IN_OUT"),
            _k(30, loc=(0, 0, 0), rot=[]),
        ],
        "UpperArm.R": [
            _k(0, rot=[], ease="EASE_IN"),
            _k(6, rot=[(FWD, -20.0), (UP, -12.0)], ease="EASE_IN"),
            _k(15, rot=[(FWD, 26.0), (UP, 16.0)], ease="EASE_OUT"),
            _k(22, rot=[(FWD, 8.0)], ease="EASE_IN_OUT"),
            _k(30, rot=[]),
        ],
        "UpperArm.L": [
            _k(0, rot=[], ease="EASE_IN"),
            _k(8, rot=[(FWD, -14.0), (UP, -16.0)], ease="EASE_IN"),
            _k(16, rot=[(FWD, 22.0), (UP, 18.0)], ease="EASE_OUT"),
            _k(24, rot=[(FWD, 5.0)], ease="EASE_IN_OUT"),
            _k(30, rot=[]),
        ],
        "LowerArm.L": [
            _k(0, rot=[], ease="EASE_IN"),
            _k(8, rot=[(RIGHT, -10.0)], ease="EASE_IN"),
            _k(16, rot=[(RIGHT, 18.0)], ease="EASE_OUT"),
            _k(30, rot=[]),
        ],
    })


ANIMS = [anim_idle, anim_draw, anim_fire, anim_fire_ads, anim_reload,
         anim_inspect, anim_melee]

FINGERS_L = [f"{f}{i}.L" for f in ("Index", "Middle", "Pinky") for i in (1, 2, 3)] + \
            ["Thumb1.L", "Thumb2.L"]


# ==========================================================================
# Everything below only runs inside Blender.
# ==========================================================================

def build(make_mounted: bool, make_pov: bool) -> None:
    import bpy
    import bmesh
    from mathutils import Matrix, Quaternion, Vector

    sys.path.insert(0, HERE)
    import blender_common as bc   # noqa: E402
    import palette                # noqa: E402

    written = []
    scn = bpy.context.scene
    scn.render.fps = FPS

    if bpy.context.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")

    arm = bc.armatures()[0]
    arm.name = "CharacterArmature"
    body = bpy.data.objects["Body"]
    head = bpy.data.objects["Head"]

    # ---- 0. remember the hold seed pose and the character's full height -----
    seed = _sample_action(bpy, arm, "Run_Shoot", 0)

    arm.data.pose_position = "REST"
    bpy.context.view_layer.update()
    # measure in the rest pose: `Head` is bone-parented, so a posed skeleton
    # would report the wrong character height
    full_h = _height([body, head])
    scale = TARGET_HEIGHT / full_h
    print(f"[scale] source character {full_h:.3f} units -> {TARGET_HEIGHT} m (x{scale:.4f})")

    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.scale = (1, 1, 1)
    bpy.context.view_layer.update()

    bc.keep_only(["CharacterArmature", "Body"])
    for o in bpy.data.objects:
        for m in list(o.modifiers):
            if m.type == "NODES":                 # stock "Auto Smooth" geo nodes
                o.modifiers.remove(m)
    for a in list(bpy.data.actions):
        bpy.data.actions.remove(a)

    # ---- 1. split the arm-dominant geometry out of Body ---------------------
    # `Body` ships with a 0.586 object scale while the armature is at 1.0; bake
    # it into the mesh data first or the metric rescale below moves the skin and
    # the skeleton by different amounts.
    bc.apply_transforms([body])
    fparms = _separate_arms(bpy, bmesh, body, arm)
    print(f"[split] FPArms {len(fparms.data.vertices)} verts, {_tris(fparms)} tris")

    # ---- 2. trim the rig ---------------------------------------------------
    dropped = _trim_armature(bpy, arm)
    _purge_groups(fparms, KEEP_BONES)
    print(f"[rig] kept {len(arm.data.bones)} bones, dropped {len(dropped)}: "
          + ", ".join(sorted(dropped)))

    # ---- 3. zones + atlas + remap -----------------------------------------
    counts = _zone_split(bpy, fparms)
    print("[zones] " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    entries = bc.collect_materials([fparms])
    for n in entries:
        entries[n]["surface"] = SURFACE.get(n, "fabric")
    atlas = os.path.join(OUT_DIR, "arms_atlas.png")
    atlas_h = os.path.join(OUT_DIR, "arms_atlas_havoc.png")
    surf = {k: SURFACE.get(k, "fabric") for k in entries}
    slots = bc.build_atlas_for([fparms], atlas, overrides=PALETTE, surfaces=surf)
    slots_h = palette.recolor_atlas(entries, PALETTE_HAVOC, atlas_h)
    assert slots == slots_h, "the havoc variant must reuse the same slot layout"
    _flip_atlas_rows(atlas)
    _flip_atlas_rows(atlas_h)
    written += [atlas, atlas_h]
    print(f"[atlas] {len(slots)} slots @ {palette.ATLAS_PX}px: "
          + ", ".join(f"{k}#{v}" for k, v in sorted(slots.items(), key=lambda kv: kv[1])))

    import shutil
    import tempfile
    tmp = os.path.join(tempfile.gettempdir(), "ts_atlas_viewmodel")
    os.makedirs(tmp, exist_ok=True)
    tex = os.path.join(tmp, "atlas.png")
    shutil.copyfile(atlas, tex)
    bc.atlas_remap([fparms], slots, tex, material_name="TS_Viewmodel", jitter=0.5)
    for img in bpy.data.images:
        if img.filepath and os.path.basename(img.filepath) == "atlas.png":
            img.name = "atlas"

    # ---- 4. metres, and put the camera at the origin -----------------------
    offset = Vector((-EYE[0], -EYE[1] - RIG_PUSH, -EYE[2]))
    _rescale_rig(bpy, Matrix, arm, [fparms], scale, offset)
    print(f"[place] rig moved so the eye sits at the origin, pushed {RIG_PUSH:.2f} m forward")

    # ---- 5. solve the two-handed hold --------------------------------------
    markers = _weapon_markers()
    W = _weapon_matrix(Matrix, Quaternion, Vector)
    print(f"[hold] weapon origin {tuple(round(v, 3) for v in W.translation)} "
          f"yaw={HOLD_YAW} pitch={HOLD_PITCH} roll={HOLD_ROLL}")
    _seed_pose(bpy, arm, seed, scale)
    _solve_hold(bpy, Matrix, Vector, arm, W, markers)

    # ---- 6. bake the hold pose as the rest pose ----------------------------
    _apply_as_rest(bpy, arm, fparms)
    _CURL_AXES.update(_finger_axes(arm))
    print("[hold] solved pose applied as the armature rest pose")

    mount = _add_mount(bpy, Matrix, arm, W)
    for name, m in markers.items():
        p = W @ Vector(_gltf_to_blender(m))
        e = bc.add_marker(f"VM_{name}", (0, 0, 0))
        e.parent = mount
        e.matrix_parent_inverse = mount.matrix_world.inverted()
        e.matrix_world = Matrix.Translation(p) @ W.to_3x3().to_4x4()
    bpy.context.view_layer.update()

    # ---- 7. author the animations -----------------------------------------
    arm.animation_data_create()
    names = []
    for fn in ANIMS:
        spec = fn()
        _make_action(bpy, Matrix, Quaternion, Vector, arm, spec)
        names.append(f"{spec['name']}({spec['frames'] / FPS:.2f}s"
                     + (", loop)" if spec["loop"] else ")"))
    print("[anims] " + ", ".join(names))

    # ---- 8. export ---------------------------------------------------------
    arm.data.pose_position = "POSE"
    for a in bpy.data.actions:
        a.use_fake_user = True
    _rest_pose(arm)

    total = bc.tri_count()
    print(f"[tris] FPArms {total} (budget {TRI_BUDGET})")
    if total > TRI_BUDGET:
        print(f"[WARN] viewmodel is over the {TRI_BUDGET} tri budget!")

    glb = os.path.join(OUT_DIR, "arms.glb")
    bpy.context.view_layer.objects.active = arm
    bc.export_glb(glb, with_animations=True)
    written.append(glb)

    readme = _write_readme(W, markers, total, len(arm.data.bones), slots)
    written.append(readme)

    if make_mounted:
        p = _mounted(bpy, bc, Matrix, Vector, arm, mount)
        print(f"[debug] {p}")

    if make_pov:                 # after --mounted so the rifle is in frame
        _pov_render(bpy, Vector)

    for p in written:
        print(f"WROTE {p}")


# --- geometry -----------------------------------------------------------------

def _tris(obj) -> int:
    return sum(max(0, len(p.vertices) - 2) for p in obj.data.polygons)


def _height(objs) -> float:
    lo, hi = 1e9, -1e9
    for o in objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            z = (mw @ v.co).z
            lo, hi = min(lo, z), max(hi, z)
    return hi - lo


def _separate_arms(bpy, bmesh, body, arm):
    """Keep only the polygons whose skin weight is >50 % owned by arm bones, cap
    the open shoulder rings and rename the survivor `FPArms`.

    Done with bmesh rather than `mesh.separate`, which propagates the selection
    through shared vertices and drags a chunk of chest along with it.
    """
    me = body.data
    gname = {g.index: g.name for g in body.vertex_groups}
    dom = set()
    for v in me.vertices:
        tot = sum(g.weight for g in v.groups)
        a = sum(g.weight for g in v.groups if gname.get(g.group) in ARM_BONES)
        if tot > 0.0 and a / tot > 0.5:
            dom.add(v.index)
    mw = body.matrix_world
    drop = [p.index for p in me.polygons
            if not all(vi in dom for vi in p.vertices)
            or abs((mw @ p.center).x) < X_ARM_CUT]

    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in drop], context="FACES")
    loose = [v for v in bm.verts if not v.link_faces]
    if loose:
        bmesh.ops.delete(bm, geom=loose, context="VERTS")
    # cap the two shoulder rings so the arms are closed solids from any angle
    ring = [e for e in bm.edges if e.is_boundary]
    if ring:
        bmesh.ops.holes_fill(bm, edges=ring, sides=0)
    bm.to_mesh(me)
    bm.free()
    me.update()

    body.name = "FPArms"
    me.name = "FPArms"
    if not any(m.type == "ARMATURE" for m in body.modifiers):
        m = body.modifiers.new("Armature", "ARMATURE")
        m.object = arm
    return body


def _trim_armature(bpy, arm):
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    dropped = set()
    for eb in list(arm.data.edit_bones):
        if eb.name not in KEEP_BONES:
            dropped.add(eb.name)
            arm.data.edit_bones.remove(eb)
    bpy.ops.object.mode_set(mode="OBJECT")
    return dropped


def _purge_groups(obj, keep):
    """Delete vertex groups for bones that no longer exist, then renormalise the
    remaining weights so the skin still sums to 1."""
    for g in list(obj.vertex_groups):
        if g.name not in keep:
            obj.vertex_groups.remove(g)
    idx = {g.index for g in obj.vertex_groups}
    me = obj.data
    for v in me.vertices:
        tot = sum(g.weight for g in v.groups if g.group in idx)
        if tot <= 1e-6:
            continue
        for g in v.groups:
            if g.group in idx:
                g.weight = g.weight / tot


def _zone_split(bpy, obj):
    me = obj.data
    src = [m.name if m else "None" for m in me.materials]
    mw = obj.matrix_world
    zones, counts = [], {}
    for p in me.polygons:
        c = mw @ p.center
        s = src[p.material_index] if p.material_index < len(src) else "None"
        z = zone(s, c.x, c.y, c.z)
        zones.append(z)
        counts[z] = counts.get(z, 0) + max(0, len(p.vertices) - 2)
    order = []
    for z in zones:
        if z not in order:
            order.append(z)
    me.materials.clear()
    for z in order:
        mat = bpy.data.materials.get(z) or bpy.data.materials.new(z)
        mat.use_nodes = False
        me.materials.append(mat)
    at = {z: i for i, z in enumerate(order)}
    for p, z in zip(me.polygons, zones):
        p.material_index = at[z]
    return counts


def _flip_atlas_rows(path: str) -> None:
    """palette.build_atlas paints slot rows top-down (PIL) but palette.patch_uv
    measures v bottom-up (glTF); flipping the finished PNG reconciles the two.
    Same workaround as tools/assets/build_characters.py."""
    from PIL import Image
    im = Image.open(path)
    im.transpose(Image.FLIP_TOP_BOTTOM).save(path)


def _rescale_rig(bpy, Matrix, arm, meshes, f: float, offset):
    """Scale + translate the rig *in the data*, leaving every object transform at
    identity (the glTF exporter would otherwise bake a skin-root transform twice
    -- see build_characters._apply_metric_scale)."""
    S = Matrix.Translation(offset) @ Matrix.Diagonal((f, f, f)).to_4x4()
    for o in meshes:
        o.data.transform(S)
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for eb in arm.data.edit_bones:
        eb.use_connect = False
    for eb in arm.data.edit_bones:
        eb.head = S @ eb.head
        eb.tail = S @ eb.tail
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.context.view_layer.update()


# --- the hold pose ------------------------------------------------------------

def _sample_action(bpy, arm, action_name: str, frame: int) -> dict:
    """Read one frame of a stock action into {bone: (quat, loc)}."""
    act = bpy.data.actions.get(action_name)
    if act is None:
        return {}
    arm.animation_data_create()
    prev = arm.animation_data.action
    arm.animation_data.action = act
    arm.data.pose_position = "POSE"
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    out = {}
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        out[pb.name] = (tuple(pb.rotation_quaternion), tuple(pb.location))
    arm.animation_data.action = prev
    return out


def _seed_pose(bpy, arm, seed: dict, f: float) -> None:
    """Put the arms in the closest artist-made two-handed pose before solving, so
    the IK solver's elbows start where the animator put them."""
    from mathutils import Quaternion
    arm.data.pose_position = "POSE"
    for name, (q, loc) in seed.items():
        pb = arm.pose.bones.get(name)
        if pb is None:
            continue
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = Quaternion(q)
        pb.location = (loc[0] * f, loc[1] * f, loc[2] * f)
    # a bladed firing stance: support shoulder forward, firing shoulder back
    _add_local_rot(arm, "Torso", [((0, 0, 1), BLADE)])
    _add_local_rot(arm, "Shoulder.L", [((0, -1, 0), SHOULDER_L_FWD)])
    _add_local_rot(arm, "Shoulder.R", [((0, -1, 0), -SHOULDER_R_BACK)])
    bpy.context.view_layer.update()


def _add_local_rot(arm, bone: str, rots) -> None:
    from mathutils import Quaternion, Vector
    pb = arm.pose.bones.get(bone)
    if pb is None:
        return
    R = pb.bone.matrix_local.to_quaternion()
    for axis, deg in rots:
        world = Quaternion(Vector(axis), math.radians(deg))
        pb.rotation_quaternion = pb.rotation_quaternion @ (R.inverted() @ world @ R)


def _gltf_to_blender(v):
    """glTF (x, y up, z fwd) -> Blender (x, y, z up)."""
    return (v[0], -v[2], v[1])


def _weapon_markers() -> dict:
    m = {"GripR": GRIP_R_MARKER, "GripL": GRIP_L_MARKER}
    try:
        with open(REF_MANIFEST) as fh:
            w = json.load(fh)["weapons"]["ar77"]["markers"]
        for k in ("GripR", "GripL", "Sight", "Muzzle"):
            if k in w:
                m[k] = tuple(w[k])
    except Exception as exc:                      # noqa: BLE001
        print(f"[hold] manifest unavailable ({exc}); using built-in ar77 markers")
    return m


def _weapon_matrix(Matrix, Quaternion, Vector):
    """Desired weapon transform in viewmodel space.

    The identity basis is "weapon aimed straight down the camera": glTF +Z
    (barrel) is Blender -Y, glTF +Y (up) is Blender +Z. Because the GLB export
    applies exactly that axis conversion, an empty whose Blender basis is the
    identity publishes the weapon's own frame to Godot -- a weapon parented to
    it with an identity transform aims where the camera looks.
    """
    R = Quaternion(Vector((0, 0, 1)), math.radians(HOLD_YAW)).to_matrix().to_4x4()
    right = R.to_3x3() @ Vector((1, 0, 0))            # weapon +X
    R = Quaternion(right, math.radians(HOLD_PITCH)).to_matrix().to_4x4() @ R
    barrel = R.to_3x3() @ Vector((0, -1, 0))          # weapon +Z
    R = Quaternion(barrel, math.radians(HOLD_ROLL)).to_matrix().to_4x4() @ R
    return Matrix.Translation(Vector(HOLD_POS)) @ R


def _hand_frame(arm, side: str):
    """Orthonormal frame of the rest hand, in armature space:
    (metacarpal direction, index->pinky knuckle line, palm normal)."""
    from mathutils import Vector
    b = arm.data.bones
    wrist = b[f"Middle1.{side}"].head_local
    knuck = b[f"Middle1.{side}"].tail_local
    ix = b[f"Index1.{side}"].tail_local
    pk = b[f"Pinky1.{side}"].tail_local
    f = (knuck - wrist).normalized()
    k = (pk - ix).normalized()
    k = (k - f * k.dot(f)).normalized()
    n = f.cross(k)
    palm = wrist.lerp(knuck, 0.5)
    return f, k, n, palm


def _solve_hold(bpy, Matrix, Vector, arm, W, markers) -> None:
    """Place each hand on the weapon's own grip marker with an IK constraint,
    then bake the result into the pose."""
    from mathutils import Quaternion

    targets = {}
    palms = {}
    wants = {}
    for side, marker, twist, shift, axis_map in (
            ("R", "GripR", GRIP_R_TWIST, GRIP_R_SHIFT, "grip"),
            ("L", "GripL", GRIP_L_TWIST, GRIP_L_SHIFT, "handguard")):
        f, k, n, palm = _hand_frame(arm, side)
        H = Matrix((f, k, n)).transposed()          # hand frame, columns

        # Where the fist's tunnel points in *weapon* space, and which weapon
        # direction the metacarpals run along.
        # (weapon-local *Blender* axes: barrel -Y, up +Z, weapon-right +X)
        if axis_map == "grip":
            # pistol grip: fist wraps the vertical grip column, metacarpals
            # point down the barrel.
            w_meta = Vector((0.0, -1.0, 0.0))
            w_tunnel = Vector((0.0, 0.0, -1.0))
        else:
            # handguard: fist wraps the barrel, metacarpals run across it.
            w_meta = Vector((-1.0, 0.0, 0.35)).normalized()
            w_tunnel = Vector((0.0, 1.0, 0.0))
        w_meta = (w_meta - w_tunnel * w_meta.dot(w_tunnel)).normalized()
        tw = Quaternion(w_tunnel, math.radians(twist))
        w_meta = tw @ w_meta
        Wb = Matrix((w_meta, w_tunnel, w_meta.cross(w_tunnel))).transposed()

        Q = (W.to_3x3() @ Wb @ H.inverted())
        grip = W @ Vector(_gltf_to_blender(markers[marker]))
        grip = grip + W.to_3x3() @ Vector(_gltf_to_blender(shift))

        la = arm.data.bones[f"LowerArm.{side}"]
        head_t = grip - Q @ (palm - la.head_local)
        tail_t = head_t + Q @ (la.tail_local - la.head_local)
        rot = (Q @ la.matrix_local.to_3x3()).to_4x4()

        e = bpy.data.objects.new(f"_IK.{side}", None)
        bpy.context.scene.collection.objects.link(e)
        e.matrix_world = Matrix.Translation(tail_t) @ rot
        targets[side] = e
        palms[side] = palm
        wants[side] = grip

        pb = arm.pose.bones[f"LowerArm.{side}"]
        c = pb.constraints.new("IK")
        c.target = e
        c.chain_count = 3                            # Shoulder + UpperArm + LowerArm
        c.use_rotation = True
        c.use_tail = True
        c.influence = 1.0
        print(f"[hold] {marker}: target {tuple(round(v, 3) for v in grip)}, "
              f"shoulder reach {(grip - arm.data.bones[f'Shoulder.{side}'].head_local).length:.3f} m")

    # The rotation half of the IK goal fights the position half, so the solver
    # settles a few centimetres off. Newton-step the targets by the residual --
    # 4 passes takes both palms to sub-millimetre.
    for _ in range(6):
        bpy.context.view_layer.update()
        worst = 0.0
        for side, e in targets.items():
            got = _palm_now(arm, side, palms[side])
            err = wants[side] - got
            worst = max(worst, err.length)
            e.matrix_world = Matrix.Translation(err) @ e.matrix_world
        if worst < 1e-4:
            break

    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    for pb in arm.pose.bones:
        pb.bone.select = True
    bpy.ops.pose.visual_transform_apply()
    for pb in arm.pose.bones:
        for c in list(pb.constraints):
            pb.constraints.remove(c)
    bpy.ops.object.mode_set(mode="OBJECT")
    for e in targets.values():
        bpy.data.objects.remove(e, do_unlink=True)

    _curl_fingers(arm)
    bpy.context.view_layer.update()

    for side, marker in (("R", "GripR"), ("L", "GripL")):
        got = _palm_now(arm, side, palms[side])
        print(f"[hold] {marker} palm lands {(got - wants[side]).length * 1000:.1f} mm "
              f"from the marker")


def _palm_now(arm, side: str, palm_rest):
    """Current armature-space position of the palm centre."""
    pb = arm.pose.bones[f"LowerArm.{side}"]
    la = arm.data.bones[f"LowerArm.{side}"]
    return pb.matrix @ (la.matrix_local.inverted() @ palm_rest)


CURL = {
    # bone suffix -> (curl degrees for the R hand, for the L hand)
    "1": (58.0, 62.0),
    "2": (72.0, 76.0),
    "3": (58.0, 60.0),
}


def _curl_axis(pb, palm_local):
    """Bone-local axis that swings this bone's tip toward the palm.

    The finger bones' roll is not consistent across the rig, so the axis is
    derived rather than assumed: rotating a bone about (bone_dir x palm_normal)
    by a positive angle moves its tip toward the palm normal, and in bone-local
    space `bone_dir` is always +Y.
    """
    from mathutils import Vector
    ax = Vector((0.0, 1.0, 0.0)).cross(palm_local)
    return ax.normalized() if ax.length > 1e-6 else Vector((1.0, 0.0, 0.0))


def _curl_fingers(arm) -> None:
    """Close both fists around the weapon. The trigger finger stays hooked, not
    balled, so the right hand reads as being on a trigger."""
    import bpy
    from mathutils import Quaternion
    s = float(os.environ.get("TS_VM_CURL", "1"))
    for side in ("R", "L"):
        _, _, n_rest, _ = _hand_frame(arm, side)
        la = arm.data.bones[f"LowerArm.{side}"]
        # the palm normal in the *current* (solved) pose
        palm_w = (arm.pose.bones[f"LowerArm.{side}"].matrix.to_3x3()
                  @ (la.matrix_local.to_3x3().inverted() @ n_rest)).normalized()
        for finger in ("Index", "Middle", "Pinky", "Thumb"):
            for i in (1, 2, 3):
                pb = arm.pose.bones.get(f"{finger}{i}.{side}")
                if pb is None:
                    continue
                if finger == "Thumb":
                    deg = (30.0, 40.0, 0.0)[i - 1]
                else:
                    deg = CURL[str(i)][0 if side == "R" else 1]
                    if side == "R" and finger == "Index":
                        deg *= 0.45 if i == 1 else 0.75   # hooked on the trigger
                    if finger == "Pinky":
                        deg *= 1.05
                M = pb.matrix.to_3x3()
                axis = _curl_axis(pb, (M.inverted() @ palm_w).normalized())
                pb.rotation_quaternion = pb.rotation_quaternion @ Quaternion(
                    axis, math.radians(deg * s))
                bpy.context.view_layer.update()


_CURL_AXES: dict = {}


def _finger_axes(arm) -> dict:
    """Per-finger-bone local curl axis in the *baked* rest pose, so the animation
    score can just say `curl=-30` and mean "open the hand by 30 degrees"."""
    out = {}
    for side in ("R", "L"):
        _, _, n_rest, _ = _hand_frame(arm, side)
        for finger in ("Index", "Middle", "Pinky", "Thumb"):
            for i in (1, 2, 3):
                b = arm.data.bones.get(f"{finger}{i}.{side}")
                if b is None:
                    continue
                M = b.matrix_local.to_3x3()
                out[b.name] = _curl_axis(None, (M.inverted() @ n_rest).normalized())
    return out


def _apply_as_rest(bpy, arm, mesh) -> None:
    """Bake the current pose into the mesh and make it the armature rest pose."""
    bpy.ops.object.select_all(action="DESELECT")
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = mesh
    mod = next(m for m in mesh.modifiers if m.type == "ARMATURE")
    bpy.ops.object.modifier_copy(modifier=mod.name)
    bpy.ops.object.modifier_apply(modifier=mod.name)

    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    bpy.ops.pose.select_all(action="SELECT")
    bpy.ops.pose.armature_apply()
    bpy.ops.object.mode_set(mode="OBJECT")
    _rest_pose(arm)
    bpy.context.view_layer.update()


def _rest_pose(arm) -> None:
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.scale = (1, 1, 1)


def _add_mount(bpy, Matrix, arm, W):
    """`WeaponMount`: an Empty on the right forearm whose local frame is exactly
    the weapon's own space (barrel +Z, up +Y after the Y-up export)."""
    e = bpy.data.objects.new("WeaponMount", None)
    e.empty_display_type = "ARROWS"
    e.empty_display_size = 0.06
    bpy.context.scene.collection.objects.link(e)
    e.parent = arm
    e.parent_type = "BONE"
    e.parent_bone = "LowerArm.R"
    e.matrix_parent_inverse = Matrix.Identity(4)
    bpy.context.view_layer.update()
    e.matrix_world = W
    bpy.context.view_layer.update()
    print(f"[mount] WeaponMount on LowerArm.R at "
          f"{tuple(round(v, 4) for v in e.matrix_world.translation)}")
    return e


# --- animation ----------------------------------------------------------------

def _local_rot(arm, bone: str, rots):
    """Convert a list of (armature-space axis, degrees) into one bone-local
    quaternion."""
    from mathutils import Quaternion, Vector
    R = arm.data.bones[bone].matrix_local.to_quaternion()
    q = Quaternion((1, 0, 0, 0))
    for axis, deg in rots:
        if abs(deg) < 1e-9:
            continue
        q = q @ (R.inverted() @ Quaternion(Vector(axis), math.radians(deg)) @ R)
    return q


def _local_loc(arm, bone: str, vec):
    from mathutils import Vector
    return arm.data.bones[bone].matrix_local.to_3x3().inverted() @ Vector(vec)


def _make_action(bpy, Matrix, Quaternion, Vector, arm, spec) -> None:
    from mathutils import Quaternion as Q, Vector as V
    act = bpy.data.actions.new(spec["name"])
    arm.animation_data.action = act
    _rest_pose(arm)

    def insert(bone, frame, quat, loc, ease):
        pb = arm.pose.bones.get(bone)
        if pb is None:
            return
        pb.rotation_quaternion = quat
        pb.location = loc
        pb.keyframe_insert("rotation_quaternion", frame=frame, group=bone)
        if loc.length > 0.0 or True:
            pb.keyframe_insert("location", frame=frame, group=bone)
        for fc in act.fcurves:
            if not fc.data_path.startswith(f'pose.bones["{bone}"]'):
                continue
            for kp in fc.keyframe_points:
                if abs(kp.co.x - frame) < 1e-4:
                    kp.interpolation = "BEZIER"
                    kp.easing = ease if ease in ("EASE_IN", "EASE_OUT", "EASE_IN_OUT") else "AUTO"
                    kp.handle_left_type = "AUTO_CLAMPED"
                    kp.handle_right_type = "AUTO_CLAMPED"

    def curl_q(bone, deg):
        return Q(_CURL_AXES.get(bone, V((1, 0, 0))), math.radians(deg))

    for bone, keys in spec["keys"].items():
        if bone == "_fingers.L":
            for k in keys:
                for fb in FINGERS_L:
                    insert(fb, k["f"], curl_q(fb, k.get("curl", 0.0)),
                           V((0, 0, 0)), k.get("ease", "AUTO"))
            continue
        for k in keys:
            if "curl" in k:
                q = curl_q(bone, k["curl"])
            else:
                q = _local_rot(arm, bone, k.get("rot", []))
            loc = _local_loc(arm, bone, k.get("loc", (0, 0, 0)))
            insert(bone, k["f"], q, loc, k.get("ease", "AUTO"))

    act.frame_range  # noqa: B018  (force the range to refresh)
    act.use_frame_range = True
    act.frame_start = 0
    act.frame_end = spec["frames"]
    _rest_pose(arm)


# --- reporting / verification -------------------------------------------------

def _write_readme(W, markers, tris, bones, slots) -> str:
    from mathutils import Matrix  # noqa: F401
    m = W
    gl = "\n".join(
        f"| `{k}` | {tuple(round(v, 4) for v in m @ __import__('mathutils').Vector(_gltf_to_blender(p)))} |"
        for k, p in sorted(markers.items()))
    rows = "\n".join(f"| `{k}` | {v} |" for k, v in sorted(slots.items(), key=lambda kv: kv[1]))
    txt = README_TMPL.format(
        tris=tris, bones=bones, rows=rows,
        pos=", ".join(f"{v:.4f}" for v in _mount_gltf(W)[0]),
        rot=", ".join(f"{v:.4f}" for v in _mount_gltf(W)[1]),
        basis=_mount_basis_text(W),
        yaw=HOLD_YAW, pitch=HOLD_PITCH, roll=HOLD_ROLL,
        push=RIG_PUSH, marker_rows=gl)
    path = os.path.join(OUT_DIR, "README.md")
    with open(path, "w") as fh:
        fh.write(txt)
    return path


def _mount_gltf(W):
    """WeaponMount transform expressed in Godot/glTF axes (Y up, forward +Z)."""
    t = W.translation
    b = W.to_3x3()
    pos = (t.x, t.z, -t.y)
    cols = []
    for i in range(3):
        c = b.col[i]
        cols.append((c.x, c.z, -c.y))
    return pos, (cols[0] + cols[1] + cols[2])


def _mount_basis_text(W):
    pos, cols = _mount_gltf(W)
    x, y, z = cols[0:3], cols[3:6], cols[6:9]
    return (f"Basis(Vector3({x[0]:.4f}, {x[1]:.4f}, {x[2]:.4f}), "
            f"Vector3({y[0]:.4f}, {y[1]:.4f}, {y[2]:.4f}), "
            f"Vector3({z[0]:.4f}, {z[1]:.4f}, {z[2]:.4f}))")


def _pov_render(bpy, Vector) -> None:
    """Cycles render from the viewmodel camera (the origin, looking -Y) so the
    on-screen composition can be checked -- preview_model.gd frames from the
    AABB and cannot show it."""
    scn = bpy.context.scene
    cam_data = bpy.data.cameras.new("VMCam")
    cam_data.lens_unit = "FOV"
    cam_data.angle = math.radians(float(os.environ.get("TS_POV_FOV", "65")))
    cam_data.clip_start = 0.01
    cam = bpy.data.objects.new("VMCam", cam_data)
    scn.collection.objects.link(cam)
    cam.location = (0, 0, 0)
    # look along -Y (the way the player faces) with +Z up
    cam.rotation_euler = (math.radians(90), 0, math.radians(180))
    scn.camera = cam
    for loc, e in (((1.2, 1.6, 2.0), 900.0), ((-1.6, 1.2, 1.2), 400.0),
                   ((0.0, -2.0, 1.0), 250.0)):
        ld = bpy.data.lights.new("L", type="POINT")
        ld.energy = e
        lo = bpy.data.objects.new("L", ld)
        lo.location = loc
        scn.collection.objects.link(lo)
    scn.world = scn.world or bpy.data.worlds.new("W")
    scn.world.use_nodes = True
    scn.world.node_tree.nodes["Background"].inputs[1].default_value = 0.7
    scn.render.engine = "CYCLES"
    scn.cycles.samples = 24
    scn.cycles.use_denoising = False
    scn.render.resolution_x, scn.render.resolution_y = 640, 360
    scn.render.image_settings.file_format = "PNG"
    out = os.environ.get("TS_POV_DIR", "/tmp/vm_pov")
    os.makedirs(out, exist_ok=True)
    for name in ("vm_idle", "vm_reload", "vm_draw"):
        act = bpy.data.actions.get(name)
        if act is None:
            continue
        arm = [o for o in bpy.data.objects if o.type == "ARMATURE"][0]
        arm.animation_data.action = act
        for frac in (0.0, 0.35, 0.7):
            scn.frame_set(int(act.frame_end * frac))
            scn.render.filepath = os.path.join(out, f"pov_{name}_{int(frac * 100):02d}.png")
            bpy.ops.render.render(write_still=True)
            print(f"[pov] {scn.render.filepath}")


def _mounted(bpy, bc, Matrix, Vector, arm, mount) -> str:
    """Weld the reference rifle to WeaponMount and export a debug GLB, so the
    in-engine preview proves the hands land on the grips."""
    if not os.path.exists(REF_WEAPON):
        print(f"[debug] {REF_WEAPON} missing, skipping the mounted preview")
        return ""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=REF_WEAPON)
    new = [o for o in bpy.data.objects if o not in before]
    gun = [o for o in new if o.type == "MESH"]
    roots = [o for o in new if o.parent is None]
    for r in roots:
        r.parent = mount
        r.matrix_parent_inverse = Matrix.Identity(4)
        r.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()
    out = os.path.join(OUT_DIR, "_mounted_preview.glb")
    bc.export_glb(out, with_animations=True)
    print(f"[debug] mounted {len(gun)} weapon meshes on WeaponMount")
    return out


README_TMPL = '''# Viewmodel (first-person arms)

`arms.glb` is the local player's first-person arms: **{tris} triangles**,
**{bones} bones**, one material, one 512x512 atlas -> one draw call.
Generated by `tools/assets/build_viewmodel.py` from the CC0 Quaternius
ToonShooter soldier (`Body` + `CharacterArmature`), so it matches the
third-person characters exactly.

| file | what |
|---|---|
| `arms.glb` | skinned arms + the 7 `vm_*` animations |
| `arms_atlas.png` | defender (aegis) palette -- slate sleeve, black gloves, navy band |
| `arms_atlas_havoc.png` | attacker palette -- khaki sleeve, brown gloves, orange band |

Swap teams by assigning the other atlas to the mesh's material albedo; the UVs
are identical (same palette slot order).

## Space and orientation

The mesh is authored in **metres** at 1.80 m character scale, and the origin of
`arms.glb` is the **camera/eye point**. The arms face **+Z in Godot space**, the
same convention every weapon and character in this project uses (barrel +Z).

So the viewmodel holder under the FPS camera is:

```gdscript
var vm := preload("res://assets/viewmodel/arms.glb").instantiate()
vm.rotation.y = PI          # project convention: assets face +Z, Godot looks -Z
camera.add_child(vm)        # camera should be on its own viewmodel layer,
                            # near = 0.01
```

The rig is pushed {push} m forward of the anatomical eye so the support hand can
reach the handguard; the shoulders sit below and behind the frustum, so the
upper arms enter frame from the bottom edge exactly like a normal viewmodel.

## Mounting a weapon

Weapons attach to the bone **`LowerArm.R`** (this rig has no separate hand bone
-- the finger bones hang straight off the forearm, so `LowerArm.R` *is* the
hand). The finger bones are deliberately *not* used, so trigger-finger and
support-hand animation never drags the weapon around.

`arms.glb` already contains a `WeaponMount` node parented to that bone (Godot
imports it as a `BoneAttachment3D`). **Add the weapon as a child of
`WeaponMount` with an identity transform** -- pipeline weapons have their origin
on their own `GripR` marker with the barrel down +Z, which is exactly the frame
`WeaponMount` publishes.

```gdscript
var mount := vm.find_child("WeaponMount", true, false)
var gun := load("res://assets/weapons/ar77/tp.glb").instantiate()
mount.add_child(gun)
gun.transform = per_weapon_offset(weapon_id)   # see the table below
```

If you would rather not rely on the node, the same transform relative to
`LowerArm.R`'s rest pose, in Godot space, is:

```gdscript
transform.origin = Vector3({pos})
transform.basis  = {basis}
```

Hold geometry (weapon placed at yaw {yaw} deg / pitch {pitch} deg / roll {roll}
deg relative to straight ahead; the muzzle is angled slightly across the screen,
which is what stops the rifle covering the crosshair):

| weapon marker | position in viewmodel space (Blender axes, metres) |
|---|---|
{marker_rows}

### Per-weapon offsets

`WeaponMount` is calibrated on the **assault rifle** class (`ar77`, `br52`,
`sr1`, `breacher12`, `mule`) -- 0.9 m long with a foregrip roughly 0.34 m ahead
of the pistol grip, which is what the support hand is solved onto. Shorter
weapons need to come back and up, because their handguard is closer to the grip
than the support hand sits:

| class | weapons | `Transform3D` on the weapon child of `WeaponMount` |
|---|---|---|
| rifle / carbine / DMR | `ar77` `br52` `sr1` | identity |
| shotgun / LMG (longer) | `breacher12` `mule` | `origin = Vector3(0, -0.005, -0.02)` |
| SMG | `mk9` `viper45` | `origin = Vector3(0, 0.006, 0.055)`, `rotated(Vector3.RIGHT, deg_to_rad(-2))` |
| pistol | `p9` `talon` `snub` | `origin = Vector3(-0.012, 0.028, 0.115)`, `rotated(Vector3.RIGHT, deg_to_rad(-6))` -- and play the support hand *off* the weapon (see below) |
| knife / kit / grenade | `knife` `defusekit` `frag` ... | `origin = Vector3(0, 0.02, 0.09)` |

A one-handed weapon (pistol, knife, grenade) should additionally push the
support arm out of the way. The cheapest way is a permanent additive offset on
`UpperArm.L` / `LowerArm.L` of about `(FWD 34 deg, UP -22 deg)` and
`(RIGHT 46 deg)` respectively -- the same numbers `vm_reload` uses at frame 30,
where the support hand is at the magazine well.

## Animations

All seven ship inside `arms.glb` at 60 fps. Godot does not import loop flags, so
set them yourself:

| animation | length | loop | notes |
|---|---|---|---|
| `vm_idle` | 4.00 s | **yes** | breathing + slow figure-8 sway; the last key is identical to the first, so it is seamless. The two arms are 6 % out of phase. |
| `vm_draw` | 0.55 s | no | rifle swings up from below-right, overshoots, settles. Support hand lands ~3 frames after the rifle. |
| `vm_fire` | 0.12 s | no | recoil punch back + up over 2 frames, dips past rest, returns. Trigger finger keys too. |
| `vm_fire_ads` | 0.10 s | no | ~45 % of the `vm_fire` magnitude and almost no lateral twist -- for aimed fire. |
| `vm_reload` | 2.20 s | no | rifle rolls its magazine well toward camera, support hand strips the mag (f30-f46), fetches (f62-f74), slaps it home (f94), hits the bolt release (f112), returns (f132). |
| `vm_inspect` | 3.00 s | no | rifle comes up and turns over to show both sides, then returns. |
| `vm_melee` | 0.50 s | no | wind-up right, slash across left, overshoot, recover. |

Every animation returns exactly to the rest pose on its last frame, so they can
be cross-faded into `vm_idle` with a short blend without a pop.

The **rest pose of the skeleton is the hold pose** -- `arms.glb` is already
holding a rifle with no animation playing, which means a missing/failed
animation degrades to a correct static hold instead of a T-pose.

## Palette slots

| zone | atlas slot |
|---|---|
{rows}

## Credit

Quaternius, *Ultimate Toon Shooter* (CC0 / public domain) --
`toonshooter/Characters/Blends/Character_Soldier.blend`, objects `Body` and
`CharacterArmature`, action `Run_Shoot` (used as the IK seed pose). All textures
are generated procedurally by `tools/assets/palette.py`.
'''


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
        argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
        build("--mounted" in argv, "--pov" in argv)
        return

    import subprocess
    os.makedirs(OUT_DIR, exist_ok=True)
    args = [a for a in sys.argv[1:] if a.startswith("--")]
    r = subprocess.run(
        [BLENDER, "-b", BLEND, "--python", os.path.abspath(__file__), "--", *args],
        capture_output=True, text=True)
    keep = ("[", "WROTE", "Error", "Traceback", "error:")
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith(keep) or "Error" in line or "Traceback" in line:
            print(line)
    if r.returncode != 0:
        print(r.stdout[-6000:])
        print(r.stderr[-6000:])
        raise SystemExit("blender failed")


if __name__ == "__main__":
    main()
