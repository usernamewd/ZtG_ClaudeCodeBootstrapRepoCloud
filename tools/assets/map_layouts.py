#!/usr/bin/env python3
"""Authoritative layout data for the two competitive maps.

This module IS the map design, expressed as data so that both the Blender
geometry builder (tools/assets/build_maps.py) and the Godot scene builder
(tools/build_map_scene.gd) work from one source and can never disagree about
where a wall is.

Layouts implement docs/MAP_DESIGN.md. Read that first — it states the
competitive rules the geometry has to satisfy (three lanes, two entrances per
site, defender rotation shorter than attacker rotation, cover cadence, sightline
variety) and the timing table these coordinates are tuned to hit.

Conventions
-----------
* Metres. +X east, +Z south, +Y up. Origin at map centre.
* Attackers (Havoc) spawn on the +Z side, defenders (Aegis) on the −Z side.
* Wall height 3.2 m interior, 6.0 m boundary. Half-height cover 1.1 m.
* Doorways are produced by leaving gaps between wall segments, not by booleaning
  holes, so collision stays as cheap boxes.
* Every box is (centre_x, centre_z, size_x, size_z, height, material_family).
  Boxes sit on the floor: their vertical extent is 0..height.

Run directly to dump the JSON both builders consume:
    python3 tools/assets/map_layouts.py > /tmp/maps.json
"""
from __future__ import annotations

import json
from typing import Dict, List, Tuple

# Standard dimensions
WALL_H = 3.2
BOUNDARY_H = 6.0
COVER_H = 1.1
CRATE_H = 1.2
PLATFORM_H = 1.6
WALL_T = 0.4          # interior wall thickness
THIN_T = 0.16         # penetrable wall thickness (rifles punch through)
BOUNDARY_T = 1.0


def box(cx: float, cz: float, sx: float, sz: float, h: float,
        mat: str = "concrete", tag: str = "") -> dict:
    return {"cx": cx, "cz": cz, "sx": sx, "sz": sz, "h": h, "mat": mat, "tag": tag}


def wall_x(z: float, x0: float, x1: float, h: float = WALL_H,
           t: float = WALL_T, mat: str = "concrete", tag: str = "") -> dict:
    """Wall running along X (an east-west wall) at depth z."""
    return box((x0 + x1) * 0.5, z, abs(x1 - x0), t, h, mat, tag)


def wall_z(x: float, z0: float, z1: float, h: float = WALL_H,
           t: float = WALL_T, mat: str = "concrete", tag: str = "") -> dict:
    """Wall running along Z (a north-south wall) at position x."""
    return box(x, (z0 + z1) * 0.5, t, abs(z1 - z0), h, mat, tag)


def floor(cx: float, cz: float, sx: float, sz: float, y: float = 0.0,
          mat: str = "concrete", tag: str = "") -> dict:
    return {"cx": cx, "cz": cz, "sx": sx, "sz": sz, "y": y, "mat": mat, "tag": tag}


def marker(x: float, z: float, y: float = 0.0, yaw: float = 0.0,
           tag: str = "") -> dict:
    return {"x": x, "z": z, "y": y, "yaw": yaw, "tag": tag}


def boundary(x0: float, z0: float, x1: float, z1: float) -> List[dict]:
    """Closed boundary wall around the playable rectangle."""
    t = BOUNDARY_T
    return [
        wall_x(z0 - t * 0.5, x0 - t, x1 + t, BOUNDARY_H, t, "concrete", "boundary"),
        wall_x(z1 + t * 0.5, x0 - t, x1 + t, BOUNDARY_H, t, "concrete", "boundary"),
        wall_z(x0 - t * 0.5, z0 - t, z1 + t, BOUNDARY_H, t, "concrete", "boundary"),
        wall_z(x1 + t * 0.5, z0 - t, z1 + t, BOUNDARY_H, t, "concrete", "boundary"),
    ]


# ===========================================================================
# SALTLINE — coastal salt works. Warm, outdoor, one long dock angle.
# ===========================================================================

def saltline() -> dict:
    W, N, E, S = -36.0, -34.0, 36.0, 34.0     # playable bounds
    walls: List[dict] = boundary(W, N, E, S)
    floors: List[dict] = [floor(0.0, 0.0, (E - W), (S - N), 0.0, "concrete", "ground")]
    markers: List[dict] = []

    # ---- Site B, north-west: enclosed salt shed -----------------------------
    # South wall with a doorway to B Lane and a second to B Connector.
    walls += [
        wall_x(-10.0, -34.0, -26.0, WALL_H, WALL_T, "metal", "shed"),      # gap -26..-22 = B Lane door
        wall_x(-10.0, -22.0, -16.0, WALL_H, WALL_T, "metal", "shed"),      # gap -16..-12 = connector door
        wall_z(-12.0, -28.0, -18.0, WALL_H, WALL_T, "metal", "shed"),      # east wall, gap -18..-10
        wall_x(-28.0, -34.0, -12.0, WALL_H, WALL_T, "metal", "shed"),      # north wall (behind = Aegis rotate)
    ]
    # Raised platform + ramp: the site's verticality, reachable without jumping.
    floors += [floor(-30.0, -22.0, 8.0, 8.0, PLATFORM_H, "metal", "b_platform")]
    walls += [box(-30.0, -22.0, 8.0, 8.0, PLATFORM_H, "metal", "b_platform_solid")]
    floors += [floor(-24.0, -22.0, 4.0, 6.0, 0.0, "metal", "b_ramp")]
    markers += [marker(-24.0, -22.0, 0.0, 0.0, "ramp_b")]
    # Cover: salt heaps and crates, spaced so cover is never more than ~8 m away.
    walls += [
        box(-20.0, -14.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(-26.0, -16.0, 3.0, 2.0, COVER_H, "concrete", "cover"),
        box(-17.0, -22.0, 2.2, 3.4, CRATE_H, "wood", "cover"),
        box(-31.0, -13.0, 4.0, 2.0, COVER_H, "concrete", "cover"),
    ]

    # ---- Site A, north-east: open loading dock -----------------------------
    walls += [
        wall_x(-10.0, 12.0, 18.0, WALL_H, WALL_T, "metal", "dock"),        # gap 18..22 = connector door
        wall_x(-10.0, 22.0, 30.0, WALL_H, WALL_T, "metal", "dock"),        # gap 30..34 = A Long door
        wall_z(12.0, -26.0, -18.0, WALL_H, WALL_T, "metal", "dock"),
        wall_x(-28.0, 12.0, 34.0, WALL_H, WALL_T, "metal", "dock"),
    ]
    floors += [floor(29.0, -22.0, 10.0, 9.0, PLATFORM_H, "metal", "a_platform")]
    walls += [box(29.0, -22.0, 10.0, 9.0, PLATFORM_H, "metal", "a_platform_solid")]
    floors += [floor(22.0, -22.0, 4.0, 6.0, 0.0, "metal", "a_ramp")]
    markers += [marker(22.0, -22.0, 0.0, 0.0, "ramp_a")]
    # Shipping containers as the site's主 cover; one is thin-walled so rifles
    # can punch through it, which is the map's designed penetration moment.
    walls += [
        box(17.0, -15.0, 6.0, 2.5, 2.6, "metal", "container"),
        box(25.0, -13.0, 2.5, 6.0, 2.6, "metal", "container"),
        box(14.5, -24.0, 2.0, 3.0, CRATE_H, "wood", "cover"),
        box(20.0, -20.0, 0.16, 5.0, 2.4, "metal", "thin_wall"),
    ]

    # ---- Aegis (defender) spawn + rear rotate ------------------------------
    # The rotate corridor is short: this is the intended defender advantage.
    walls += [
        wall_x(-26.0, -12.0, -4.0, WALL_H, WALL_T, "concrete", "rotate"),
        wall_x(-26.0, 4.0, 12.0, WALL_H, WALL_T, "concrete", "rotate"),
    ]
    floors += [floor(0.0, -31.0, 20.0, 6.0, 0.0, "concrete", "aegis_spawn")]
    # Spawn markers must line up with the rotate-corridor gap (x −4..4) and face
    # into it; sitting them wider puts a player nose-first into a wall on spawn.
    for x in [-3.2, -1.6, 0.0, 1.6, 3.2]:
        markers.append(marker(x, -30.0 - abs(x) * 0.35, 0.0, 180.0, "def_spawn"))

    # ---- Mid: courtyard with a central silo -------------------------------
    # The silo is why crossing mid is survivable: it breaks the straight
    # sightline from Mid Window to Havoc spawn.
    walls += [
        box(0.0, 12.0, 8.0, 8.0, WALL_H, "metal", "silo"),
        wall_z(-8.0, 2.0, 22.0, WALL_H, WALL_T, "concrete", "mid_wall"),
        wall_z(8.0, 2.0, 22.0, WALL_H, WALL_T, "concrete", "mid_wall"),
    ]
    # Mid Window: the single elevated defender angle over the courtyard.
    walls += [
        wall_x(1.0, -8.0, -2.0, WALL_H, WALL_T, "concrete", "mid_face"),
        wall_x(1.0, 2.0, 8.0, WALL_H, WALL_T, "concrete", "mid_face"),
        box(0.0, 1.0, 4.0, WALL_T, COVER_H, "concrete", "mid_window_sill"),
    ]
    markers += [marker(0.0, -1.0, 0.0, 180.0, "mid_window")]
    # Catwalk linking the two connectors behind mid.
    floors += [floor(0.0, -2.0, 20.0, 3.0, PLATFORM_H, "metal", "catwalk")]
    walls += [
        box(-9.0, -2.0, 2.0, 3.0, PLATFORM_H, "metal", "catwalk_leg"),
        box(9.0, -2.0, 2.0, 3.0, PLATFORM_H, "metal", "catwalk_leg"),
    ]
    walls += [
        box(-4.0, 18.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(4.0, 18.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(0.0, 5.0, 5.0, 1.2, COVER_H, "concrete", "cover"),
    ]

    # ---- Connectors: mid -> each site --------------------------------------
    walls += [
        wall_x(-6.0, -18.0, -8.0, WALL_H, WALL_T, "concrete", "b_conn"),
        wall_x(4.0, -18.0, -8.0, WALL_H, WALL_T, "concrete", "b_conn"),
        wall_x(-6.0, 8.0, 18.0, WALL_H, WALL_T, "concrete", "a_conn"),
        wall_x(4.0, 8.0, 18.0, WALL_H, WALL_T, "concrete", "a_conn"),
    ]

    # ---- West lane: yard -> B Lane -----------------------------------------
    walls += [
        wall_z(-14.0, 6.0, 24.0, WALL_H, WALL_T, "concrete", "west"),
        wall_z(-16.0, -10.0, 6.0, WALL_H, WALL_T, "concrete", "b_lane"),
        box(-22.0, 2.0, 3.0, 2.0, COVER_H, "concrete", "cover"),
        box(-28.0, 10.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(-20.0, 18.0, 2.5, 6.0, 2.6, "metal", "container"),
    ]

    # ---- East lane: dock -> A Long (the long angle) ------------------------
    # A Long is ~28 m; two pieces of partial cover stop it being a pure
    # one-shot corridor.
    walls += [
        wall_z(14.0, 6.0, 24.0, WALL_H, WALL_T, "concrete", "east"),
        wall_z(16.0, -8.0, 6.0, WALL_H, WALL_T, "concrete", "a_long"),
        box(24.0, 2.0, 2.5, 2.5, CRATE_H, "wood", "cover"),
        box(30.0, -4.0, 3.0, 2.0, COVER_H, "concrete", "cover"),
        box(21.0, 12.0, 2.5, 6.0, 2.6, "metal", "container"),
        box(30.0, 16.0, 4.0, 2.0, COVER_H, "concrete", "cover"),
    ]

    # ---- Havoc (attacker) spawn -------------------------------------------
    floors += [floor(0.0, 28.0, 24.0, 8.0, 0.0, "concrete", "havoc_spawn")]
    for x in [-8.0, -4.0, 0.0, 4.0, 8.0]:
        markers.append(marker(x, 29.0 + abs(x) * 0.25, 0.0, 0.0, "atk_spawn"))

    # ---- Bot navigation hints ---------------------------------------------
    markers += [
        # Defender holds
        marker(-30.0, -20.0, PLATFORM_H, 135.0, "hold_B"),
        marker(-18.0, -20.0, 0.0, 100.0, "hold_B"),
        marker(29.0, -20.0, PLATFORM_H, -135.0, "hold_A"),
        marker(16.0, -20.0, 0.0, -100.0, "hold_A"),
        marker(0.0, -1.0, 0.0, 180.0, "hold_mid"),
        marker(30.0, -6.0, 0.0, 170.0, "hold_A"),        # the long angle
        # Attacker post-plant positions
        marker(-26.0, -16.0, 0.0, 45.0, "plant_B"),
        marker(-31.0, -24.0, PLATFORM_H, 45.0, "plant_B"),
        marker(17.0, -16.0, 0.0, -45.0, "plant_A"),
        marker(30.0, -24.0, PLATFORM_H, -45.0, "plant_A"),
        # Defender retake staging
        marker(-14.0, -27.0, 0.0, 200.0, "retake_B"),
        marker(-6.0, -20.0, 0.0, 250.0, "retake_B"),
        marker(14.0, -27.0, 0.0, 160.0, "retake_A"),
        marker(6.0, -20.0, 0.0, 110.0, "retake_A"),
        # Rotation waypoints
        marker(-20.0, 0.0, 0.0, 0.0, "rotate_B"),
        marker(20.0, 0.0, 0.0, 0.0, "rotate_A"),
        marker(0.0, 8.0, 0.0, 0.0, "rotate_mid"),
    ]

    return {
        "id": "saltline",
        "name": "Saltline",
        "bounds": {"x0": W, "z0": N, "x1": E, "z1": S},
        "sky": "day",
        "sun": {"pitch": -38.0, "yaw": -30.0, "color": [1.0, 0.86, 0.68],
                "energy": 1.25},
        "ambient": {"color": [0.38, 0.44, 0.55], "energy": 0.42},
        "fog": {"enabled": True, "color": [0.62, 0.58, 0.50], "density": 0.006},
        "walls": walls,
        "floors": floors,
        "markers": markers,
        "sites": {
            "A": {"cx": 23.0, "cz": -19.0, "sx": 22.0, "sz": 18.0},
            "B": {"cx": -23.0, "cz": -19.0, "sx": 22.0, "sz": 18.0},
        },
        "buy_zones": {
            "ATK": {"cx": 0.0, "cz": 28.0, "sx": 26.0, "sz": 10.0},
            "DEF": {"cx": 0.0, "cz": -30.0, "sx": 22.0, "sz": 8.0},
        },
        "radar": {"origin": [W, N], "span": max(E - W, S - N)},
    }


# ===========================================================================
# TRANSIT — metro depot. Enclosed, vertical, shorter engagements.
# ===========================================================================

def transit() -> dict:
    W, N, E, S = -32.0, -32.0, 32.0, 32.0
    LOWER = 0.0            # platform / track level
    UPPER = 3.0            # street / ticket hall level

    walls: List[dict] = boundary(W, N, E, S)
    floors: List[dict] = [floor(0.0, 0.0, (E - W), (S - N), LOWER, "concrete", "ground")]
    markers: List[dict] = []

    # ---- Upper level: Havoc street spawn and the ticket hall ---------------
    floors += [
        floor(0.0, 27.0, 24.0, 8.0, UPPER, "concrete", "street"),
        floor(0.0, 16.0, 22.0, 16.0, UPPER, "tile", "ticket_hall"),
    ]
    walls += [
        box(0.0, 27.0, 24.0, 8.0, UPPER, "concrete", "street_solid"),
        box(0.0, 16.0, 22.0, 16.0, UPPER, "concrete", "hall_solid"),
        # Railing overlooking lower mid — the upper hold angle.
        box(0.0, 8.2, 22.0, 0.3, COVER_H, "metal", "railing"),
    ]
    # Columns give the hall cover and break its sightlines.
    for cx in (-7.0, 0.0, 7.0):
        for cz in (12.0, 20.0):
            walls.append(box(cx, cz, 1.2, 1.2, WALL_H, "concrete", "column"))

    # Descending stairs, west and east. Ramps rather than steps: reliable
    # navmesh and no jump-only routes on a touch screen.
    floors += [
        floor(-19.0, 20.0, 8.0, 12.0, UPPER, "concrete", "west_stair_top"),
        floor(-19.0, 12.0, 8.0, 6.0, 0.0, "metal", "west_stair"),
        floor(19.0, 20.0, 8.0, 12.0, UPPER, "concrete", "east_stair_top"),
        floor(19.0, 12.0, 8.0, 6.0, 0.0, "metal", "east_stair"),
    ]
    walls += [
        box(-19.0, 20.0, 8.0, 12.0, UPPER, "concrete", "west_stair_solid"),
        box(19.0, 20.0, 8.0, 12.0, UPPER, "concrete", "east_stair_solid"),
    ]
    markers += [marker(-19.0, 12.0, 0.0, 0.0, "ramp_west"),
                marker(19.0, 12.0, 0.0, 0.0, "ramp_east")]

    for x in [-8.0, -4.0, 0.0, 4.0, 8.0]:
        markers.append(marker(x, 28.0, UPPER, 0.0, "atk_spawn"))

    # ---- Turnstiles: the hard chokepoint into lower mid --------------------
    walls += [
        wall_x(7.0, -8.0, -3.0, WALL_H, WALL_T, "metal", "turnstile"),
        wall_x(7.0, -1.0, 1.0, WALL_H, WALL_T, "metal", "turnstile"),
        wall_x(7.0, 3.0, 8.0, WALL_H, WALL_T, "metal", "turnstile"),
        box(-2.0, 5.0, 2.0, 0.8, COVER_H, "metal", "cover"),
        box(2.0, 5.0, 2.0, 0.8, COVER_H, "metal", "cover"),
    ]

    # ---- Lower mid --------------------------------------------------------
    walls += [
        wall_z(-8.0, -6.0, 6.0, WALL_H, WALL_T, "tile", "mid_wall"),
        wall_z(8.0, -6.0, 6.0, WALL_H, WALL_T, "tile", "mid_wall"),
        box(-3.5, 0.0, 1.2, 1.2, WALL_H, "concrete", "column"),
        box(3.5, 0.0, 1.2, 1.2, WALL_H, "concrete", "column"),
        box(0.0, -3.0, 4.0, 1.0, COVER_H, "concrete", "cover"),
    ]

    # ---- West/East passages: the 22 m mid-long angles ---------------------
    walls += [
        wall_x(0.0, -26.0, -12.0, WALL_H, WALL_T, "tile", "west_pass"),
        wall_x(14.0, -26.0, -12.0, WALL_H, WALL_T, "tile", "west_pass"),
        wall_x(0.0, 12.0, 26.0, WALL_H, WALL_T, "tile", "east_pass"),
        wall_x(14.0, 12.0, 26.0, WALL_H, WALL_T, "tile", "east_pass"),
        box(-16.0, 7.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(-22.0, 4.0, 2.0, 3.0, COVER_H, "concrete", "cover"),
        box(16.0, 7.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(22.0, 4.0, 2.0, 3.0, COVER_H, "concrete", "cover"),
    ]

    # ---- Site A, east: rail platform --------------------------------------
    walls += [
        wall_x(-4.0, 12.0, 18.0, WALL_H, WALL_T, "tile", "site_a"),
        wall_x(-4.0, 22.0, 30.0, WALL_H, WALL_T, "tile", "site_a"),
        wall_z(10.0, -24.0, -14.0, WALL_H, WALL_T, "tile", "site_a"),
        wall_x(-26.0, 10.0, 30.0, WALL_H, WALL_T, "tile", "site_a"),
    ]
    # The rail car splits the platform into two approaches, so the post-plant
    # fight has two distinct shapes depending on plant side.
    walls += [
        box(24.0, -16.0, 3.2, 12.0, 3.0, "metal", "rail_car"),
        box(14.0, -12.0, 2.2, 2.2, CRATE_H, "wood", "cover"),
        box(14.0, -22.0, 2.0, 3.0, COVER_H, "concrete", "cover"),
        box(29.0, -22.0, 3.0, 2.0, COVER_H, "concrete", "cover"),
    ]
    floors += [floor(20.0, -20.0, 20.0, 12.0, 0.0, "tile", "platform_a")]

    # ---- Site B, west: maintenance bay ------------------------------------
    walls += [
        wall_x(-4.0, -30.0, -22.0, WALL_H, WALL_T, "metal", "site_b"),
        wall_x(-4.0, -18.0, -12.0, WALL_H, WALL_T, "metal", "site_b"),
        wall_z(-10.0, -24.0, -14.0, WALL_H, WALL_T, "metal", "site_b"),
        wall_x(-26.0, -30.0, -10.0, WALL_H, WALL_T, "metal", "site_b"),
    ]
    # Machinery and a gantry: this site's verticality and its cover.
    walls += [
        box(-24.0, -12.0, 4.0, 3.0, 2.2, "metal", "machinery"),
        box(-16.0, -18.0, 2.4, 2.4, CRATE_H, "wood", "cover"),
        box(-28.0, -20.0, 3.0, 4.0, COVER_H, "metal", "cover"),
        box(-20.0, -23.0, 0.16, 4.0, 2.4, "metal", "thin_wall"),
    ]
    floors += [floor(-27.0, -17.0, 6.0, 6.0, PLATFORM_H, "metal", "gantry")]
    walls += [box(-27.0, -17.0, 6.0, 6.0, PLATFORM_H, "metal", "gantry_solid")]
    floors += [floor(-22.5, -17.0, 3.0, 4.0, 0.0, "metal", "gantry_ramp")]
    markers += [marker(-22.5, -17.0, 0.0, 0.0, "ramp_gantry")]

    # ---- Connectors and defender rear corridor ----------------------------
    walls += [
        wall_z(-6.0, -14.0, -6.0, WALL_H, WALL_T, "tile", "b_conn"),
        wall_z(-12.0, -14.0, -6.0, WALL_H, WALL_T, "tile", "b_conn"),
        wall_z(6.0, -14.0, -6.0, WALL_H, WALL_T, "tile", "a_conn"),
        wall_z(12.0, -14.0, -6.0, WALL_H, WALL_T, "tile", "a_conn"),
        wall_x(-26.0, -10.0, -4.0, WALL_H, WALL_T, "concrete", "service"),
        wall_x(-26.0, 4.0, 10.0, WALL_H, WALL_T, "concrete", "service"),
    ]
    floors += [floor(0.0, -29.0, 14.0, 6.0, 0.0, "concrete", "aegis_spawn")]
    # Aligned with the service-corridor gap (x −4..4), facing into the map.
    for x in [-3.0, -1.5, 0.0, 1.5, 3.0]:
        markers.append(marker(x, -28.5, 0.0, 180.0, "def_spawn"))

    markers += [
        marker(-27.0, -15.0, PLATFORM_H, 135.0, "hold_B"),
        marker(-14.0, -16.0, 0.0, 100.0, "hold_B"),
        marker(24.0, -22.0, 0.0, -150.0, "hold_A"),
        marker(13.0, -16.0, 0.0, -100.0, "hold_A"),
        marker(0.0, -2.0, 0.0, 180.0, "hold_mid"),
        marker(-22.0, 2.0, 0.0, 200.0, "hold_B"),
        marker(22.0, 2.0, 0.0, 160.0, "hold_A"),
        marker(-24.0, -20.0, 0.0, 45.0, "plant_B"),
        marker(-15.0, -12.0, 0.0, 20.0, "plant_B"),
        marker(21.0, -20.0, 0.0, -45.0, "plant_A"),
        marker(28.0, -12.0, 0.0, -20.0, "plant_A"),
        marker(-9.0, -27.0, 0.0, 220.0, "retake_B"),
        marker(-9.0, -10.0, 0.0, 250.0, "retake_B"),
        marker(9.0, -27.0, 0.0, 140.0, "retake_A"),
        marker(9.0, -10.0, 0.0, 110.0, "retake_A"),
        marker(-18.0, 6.0, 0.0, 0.0, "rotate_B"),
        marker(18.0, 6.0, 0.0, 0.0, "rotate_A"),
        marker(0.0, 2.0, 0.0, 0.0, "rotate_mid"),
    ]

    return {
        "id": "transit",
        "name": "Transit",
        "bounds": {"x0": W, "z0": N, "x1": E, "z1": S},
        "sky": "dusk",
        "sun": {"pitch": -62.0, "yaw": 20.0, "color": [0.72, 0.80, 0.95],
                "energy": 0.85},
        "ambient": {"color": [0.30, 0.36, 0.46], "energy": 0.50},
        "fog": {"enabled": True, "color": [0.30, 0.34, 0.40], "density": 0.012},
        "walls": walls,
        "floors": floors,
        "markers": markers,
        "sites": {
            "A": {"cx": 21.0, "cz": -17.0, "sx": 20.0, "sz": 18.0},
            "B": {"cx": -21.0, "cz": -17.0, "sx": 20.0, "sz": 18.0},
        },
        "buy_zones": {
            "ATK": {"cx": 0.0, "cz": 27.0, "sx": 26.0, "sz": 10.0},
            "DEF": {"cx": 0.0, "cz": -29.0, "sx": 16.0, "sz": 8.0},
        },
        "radar": {"origin": [W, N], "span": max(E - W, S - N)},
    }


ALL = {"saltline": saltline, "transit": transit}


def build_all() -> Dict[str, dict]:
    return {k: fn() for k, fn in ALL.items()}


def summarize(layout: dict) -> str:
    return "%-9s walls=%3d floors=%2d markers=%3d spawns=%d/%d" % (
        layout["id"], len(layout["walls"]), len(layout["floors"]),
        len(layout["markers"]),
        sum(1 for m in layout["markers"] if m["tag"] == "atk_spawn"),
        sum(1 for m in layout["markers"] if m["tag"] == "def_spawn"))


if __name__ == "__main__":
    import sys
    data = build_all()
    if sys.stdout.isatty():
        for layout in data.values():
            print(summarize(layout), file=sys.stderr)
    print(json.dumps(data, indent=1))
