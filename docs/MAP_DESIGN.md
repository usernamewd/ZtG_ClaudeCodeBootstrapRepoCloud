# Map Design — Tactical Strike

Two original competitive bomb-defusal maps. **Both layouts are original work for
this project.** Nothing here is traced from, measured against, or derived from
any commercial game's map. What is borrowed is only the *genre grammar* — three
lanes, two sites, a contested middle — which is a design pattern, not
copyrightable expression.

## Design rules both maps obey

These are the constraints that make a defusal map actually play well. Treat them
as acceptance criteria, not suggestions.

1. **Three lanes.** Attackers leave spawn with three meaningful choices
   (left lane, middle, right lane). Every lane must reach a site.
2. **Two sites, two entrances each, minimum.** A site with one entrance is a
   turkey shoot; a site with four is undefendable. Each site gets a main
   entrance off its lane and a connector entrance off middle.
3. **Defender rotation is shorter than attacker rotation.** Defenders hold a
   short interior path behind the sites; attackers rotating between sites must
   go back through middle or spawn. This is what makes the attackers' choice of
   lane a real commitment.
4. **Timing.** Defenders must reach either site before attackers can (roughly
   6–9 s for defenders, 11–16 s for attackers at a 5.2 m/s run). Measure this by
   path length and state it, don't eyeball it.
5. **Sightline variety.** Each map needs at least one long angle (25 m+) that
   rewards a sniper, several mid-range duels (10–18 m), and close corners where
   a shotgun/SMG wins. No lane may be a single uninterrupted corridor.
6. **Cover cadence.** Along any traversal, cover no more than ~8 m apart, mixing
   full-height (breaks line of sight) and half-height (crouch-safe, shootable
   over). Half-height cover must be genuinely usable: 1.1 m tall.
7. **Plant zones are defensible from multiple posts,** with at least two
   distinct post-plant positions per site for attackers and two retake angles
   for defenders. The bomb must be plantable behind cover, not only in the open.
8. **No unwinnable spawn peeks.** No sightline may exist from either spawn into
   the other spawn or into a site.
9. **Verticality, but bounded.** One raised platform or catwalk per site,
   reachable by ramp or stairs (never a jump-only route — this is a touch-screen
   game). Nothing above 3 m of drop.
10. **Readability.** Each zone gets its own material/colour identity so a player
    knows where they are from any screenshot. Callout names are painted or
    implied by props.

Both maps are laid out on the environment kit's **4 m grid**, wall height 3.2 m
(interior) / 6 m (exterior boundary), doorways 1.1 x 2.2 m.

---

## Map 1 — "Saltline"

A coastal salt works and shipping dock at dusk. Warm, sun-bleached concrete,
rusted containers, salt heaps, steel walkways. Uses the warm skybox.

Footprint about **72 m x 68 m**. World origin at map centre; +X east, +Z south.
Havoc (attackers) spawn south, Aegis (defenders) spawn north.

### Zones

| Zone | Approx. bounds (x, z) | Character |
|---|---|---|
| **Havoc Spawn** | x −12..12, z 22..32 | Open yard, three exits |
| **West Yard** | x −32..−14, z 6..24 | Outdoor, container cover, feeds B Lane |
| **B Lane** | x −32..−16, z −10..6 | Covered walkway, one mid-length angle |
| **Site B (Salt Shed)** | x −34..−12, z −28..−10 | Indoor, salt heaps, raised platform + ramp |
| **Mid Courtyard** | x −8..8, z 2..22 | Open, central silo blocks the straight sightline |
| **Silo** | x −4..4, z 8..16 | Round structure, cover core of mid |
| **Mid Window** | x −2..2, z 0..2 | Elevated defender angle into mid, half-height |
| **Catwalk** | x −10..10, z −4..2 | Raised steel walkway linking both connectors |
| **A Connector** | x 8..18, z −6..4 | Mid → Site A, one doorway each end |
| **B Connector** | x −18..−8, z −6..4 | Mid → Site B |
| **East Dock** | x 14..32, z 8..24 | Outdoor, feeds A Long |
| **A Long** | x 16..32, z −8..8 | **The long angle** — 28 m sightline, sniper lane |
| **Site A (Loading Dock)** | x 12..34, z −28..−8 | Containers, raised dock platform + ramp |
| **Aegis Spawn** | x −8..8, z −34..−28 | North centre |
| **Aegis Rotate** | x −14..14, z −30..−26 | Short interior corridor linking both sites |

### Connectivity graph

```
Havoc Spawn ──┬── West Yard ──── B Lane ──────── Site B (main entrance, west)
              ├── Mid Courtyard ─┬─ B Connector ─ Site B (connector, south-east)
              │                  ├─ Catwalk ───── (links both connectors)
              │                  └─ A Connector ─ Site A (connector, south-west)
              └── East Dock ──── A Long ───────── Site A (main entrance, east)

Aegis Spawn ──── Aegis Rotate ──┬── Site B (rear)
                                ├── Mid Window  (overlooks Mid Courtyard)
                                └── Site A (rear)
```

### Timings (at 5.2 m/s run)

| Path | Distance | Time |
|---|---|---|
| Aegis Spawn → Site A rear | ~34 m | ~6.5 s |
| Aegis Spawn → Site B rear | ~34 m | ~6.5 s |
| Aegis Spawn → Mid Window | ~30 m | ~5.8 s |
| Havoc Spawn → Site A (via A Long) | ~72 m | ~14 s |
| Havoc Spawn → Site B (via B Lane) | ~70 m | ~13.5 s |
| Havoc Spawn → Mid Courtyard | ~24 m | ~4.6 s |
| Havoc rotate A→B (through mid) | ~52 m | ~10 s |
| Aegis rotate A→B (rear corridor) | ~28 m | ~5.4 s |

Defenders reach either site roughly 7 s before attackers can, and rotate at
about half the attacker cost — the intended asymmetry.

### Key fights

- **A Long** — the 28 m sniper angle. Must have two pieces of cover partway so
  it isn't a pure one-shot corridor, and an off-angle from the dock platform.
- **Mid doors into Mid Courtyard** — the silo means an attacker crossing mid is
  exposed to Mid Window but can break line of sight behind the silo.
- **B Lane double doorway** — close-quarters, favours shotguns/SMGs.
- **Site A dock ramp** — post-plant fight; the raised platform gives attackers a
  post but is exposed to the rear entrance.

---

## Map 2 — "Transit"

A decommissioned metro depot. Enclosed, cooler, fluorescent-lit concrete,
tiled walls, rail cars, maintenance pits. Uses the dusk/cool skybox and a
tighter, more indoor feel than Saltline — shorter average engagement range.

Footprint about **64 m x 64 m**, on two heights (street level and platform
level, 3 m apart).

### Zones

| Zone | Approx. bounds (x, z) | Character |
|---|---|---|
| **Havoc Spawn (Street)** | x −10..10, z 24..30 | Street level, above the depot |
| **West Stair** | x −24..−14, z 14..26 | Street → platform level, descends 3 m |
| **East Stair** | x 14..24, z 14..26 | Mirror descent |
| **Ticket Hall** | x −10..10, z 8..24 | **Mid** — open, columns, two levels of railing |
| **Turnstiles** | x −8..8, z 6..8 | Chokepoint into lower mid, half-height cover |
| **Lower Mid** | x −8..8, z −6..6 | Column cover, links both connectors |
| **West Passage** | x −26..−12, z 0..14 | Long-ish angle (22 m), feeds Site B |
| **East Passage** | x 12..26, z 0..14 | Mirror, feeds Site A |
| **Site A (Platform)** | x 10..30, z −26..−4 | Rail platform, a stationary rail car as cover, plant behind it or in the open |
| **Site B (Maintenance Bay)** | x −30..−10, z −26..−4 | Service pits, machinery, gantry above |
| **A Connector** | x 6..12, z −14..−6 | Lower Mid → Site A |
| **B Connector** | x −12..−6, z −14..−6 | Lower Mid → Site B |
| **Aegis Spawn** | x −6..6, z −32..−26 | Track level, centre |
| **Service Corridor** | x −16..16, z −30..−26 | Defender rear rotate |

### Connectivity graph

```
Havoc Spawn ──┬── West Stair ── West Passage ──── Site B (main, west)
              ├── Ticket Hall ── Turnstiles ── Lower Mid ─┬─ B Connector ── Site B (connector)
              │                                           └─ A Connector ── Site A (connector)
              └── East Stair ── East Passage ──── Site A (main, east)

Aegis Spawn ── Service Corridor ──┬── Site A (rear)
                                  ├── Site B (rear)
                                  └── Lower Mid (centre, contested)
```

Note the deliberate difference from Saltline: on Transit the defenders can also
contest **Lower Mid** directly from spawn, making mid control the pivotal
decision, whereas on Saltline mid is watched from a single elevated window.
Transit's engagement ranges are shorter and its vertical stack (street →
ticket hall → platform) gives it a different rhythm, so the two maps do not
play the same.

### Timings (at 5.2 m/s run)

| Path | Distance | Time |
|---|---|---|
| Aegis Spawn → Site A rear | ~30 m | ~5.8 s |
| Aegis Spawn → Site B rear | ~30 m | ~5.8 s |
| Aegis Spawn → Lower Mid | ~26 m | ~5.0 s |
| Havoc Spawn → Site A (via East) | ~64 m | ~12.3 s |
| Havoc Spawn → Site B (via West) | ~64 m | ~12.3 s |
| Havoc Spawn → Turnstiles | ~26 m | ~5.0 s |
| Aegis rotate A→B | ~34 m | ~6.5 s |

### Key fights

- **Turnstiles** — the hard chokepoint; grenades matter here.
- **Ticket Hall railing** — attackers on the upper level can hold angles down
  into mid; defenders can contest from Lower Mid.
- **East/West Passage** — 22 m mid-long angles.
- **Site A rail car** — splits the platform into two approaches, gives the
  post-plant fight two distinct shapes depending on plant side.

---

## Required per-map data (both maps)

Every map root runs `src/game/map_info.gd` and must provide:

- `ATKSpawns` / `DEFSpawns` — at least 5 `Marker3D` each, spread so players don't
  stack, all facing into the map.
- `BombSites/A`, `BombSites/B` — `Area3D` covering the plantable region.
- `BuyZones/ATK`, `BuyZones/DEF` — `Area3D` over each spawn, generous enough that
  a player can't accidentally step out mid-purchase.
- `NavRegion` — `NavigationRegion3D` whose baked mesh covers every walkable
  surface including ramps and platforms, with the boundary walls excluded.
- `radar_origin` / `radar_scale` set so `world_to_radar()` maps the playable
  area into a 256 px radar texture.
- Bot navigation hints: named `Marker3D`s under `BotPoints/` tagged by metadata
  (`hold`, `peek`, `plant`, `retake`, `rotate`) so the bot AI has authored
  positions to use instead of wandering.

## Verification for both maps

- Top-down orthographic render at 1024², reviewed against the connectivity graph
  above — every listed connection must be visibly present and every lane must be
  traversable.
- Eye-level screenshots from: each spawn, each site, mid, and the long angle.
- A navmesh overlay render proving connectivity (no islands, ramps included).
- A path-length report confirming the timing table within ±15%.
