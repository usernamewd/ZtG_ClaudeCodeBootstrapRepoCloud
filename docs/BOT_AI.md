# Bot AI Design — Tactical Strike

Bots are the entire opposition (the game is offline), so they carry the whole
experience. They must feel like players executing a plan, not like turrets that
snap to your head or drones that walk into walls.

## Architecture

```
BotBrain (per bot, extends CharacterBase)
├── Perception      what this bot can currently see/hear   (updates at 10 Hz)
├── Blackboard      shared per-team knowledge               (team-scoped node)
├── RolePlan        what this bot is trying to do this round
├── Movement        NavigationAgent3D pathing + strafing    (physics tick)
└── Combat          aim, trigger discipline, recoil control (physics tick)
```

Only Movement and Combat run every physics tick. Perception runs on a staggered
10 Hz timer (bots offset by index so ten bots never all think on the same frame),
and planning runs on events plus a 2 Hz tick. This is the frame-budget rule: with
9 bots, per-frame work must stay under ~1.5 ms total on a mid-range phone.

## Perception — the fairness contract

A bot may only act on information a human player could have. This is
non-negotiable; violating it is what makes bots feel like cheaters.

- **Vision:** an enemy is visible only if inside the bot's FOV cone (100° while
  moving, 70° while holding an angle), within `max_sight` (60 m), with a clear
  raycast from the bot's eye to *any* of the target's head/chest/limb hitboxes,
  and not blocked by a smoke volume (smoke is tested by sampling the segment
  against active smoke spheres).
- **Reaction time:** on first acquiring a target, the bot cannot fire for
  `reaction_time` seconds. This is the single most important difficulty knob.
- **Memory:** a lost target is remembered as a *last known position* that decays
  over `memory_time`. Bots clear or re-check that position rather than
  omnisciently tracking.
- **Hearing:** gunfire, footsteps (only when the walker is running and within
  ~22 m), and reloads generate audio events with a position error that grows
  with distance. Bots turn toward them; they do not treat them as exact.

Difficulty scaling:

| | Easy | Normal | Hard |
|---|---|---|---|
| `reaction_time` | 0.45 s | 0.28 s | 0.16 s |
| Aim error at acquire | 6.0° | 3.0° | 1.4° |
| Aim settle rate | slow | medium | fast |
| Spray control | none | partial | near-full recoil compensation |
| Preferred target zone | chest | chest, head when close | head at all ranges |
| Uses utility (grenades) | rarely | sometimes | routinely |
| `memory_time` | 2 s | 4 s | 6 s |
| Peek discipline | walks into the open | uses cover | shoulder-peeks and re-holds |

## Aiming — how it must feel

Never snap. The bot holds a *desired* aim direction and moves its actual aim
toward it with a rate limit, plus a slowly-drifting error offset:

```
error = base_error * (1 - settle_progress) + wander(t)
desired = target_zone_position + error_offset(error)
aim = rotate_toward(aim, desired, max_turn_rate * dt)
```

`settle_progress` grows while the target stays visible, so a bot that has been
tracking you for a second is far more accurate than one that just spotted you —
the same way a human is. `wander(t)` is smooth low-frequency noise, so the
crosshair breathes instead of sitting perfectly still.

Trigger discipline:
- Bots respect the weapon's own recoil pattern. A bot spraying a rifle
  compensates by pulling against the pattern by `spray_control` (0..1), so Easy
  bots' shots climb off target exactly like a bad player's.
- Burst length is chosen by range: taps at long range, 3–5 round bursts at mid,
  full auto inside 10 m. Between bursts they pause for the pattern to recover.
- They will not fire while their spread exceeds what the range warrants, so they
  stop to shoot rather than spraying while sprinting.

## Roles and the round plan

At round start the team's blackboard assigns roles from the buy and the score
situation. Roles are *intentions*, re-evaluated on events (contact, bomb
planted, teammate died, site called).

**Attacking (Havoc)**
| Role | Behaviour |
|---|---|
| `entry` | First through the chokepoint, wide-swings, buys aggressive weapons |
| `support` | Follows entry by ~3 m, trades the duel, throws utility first |
| `lurk` | Takes the opposite lane alone, hunts rotators, times a flank |
| `carrier` | Holds the bomb, hangs back until the site is contested, then plants |
| `anchor` | Holds the attackers' flank so they can't be collapsed from behind |

The team commits to a site via a blackboard *call* (weighted by which site has
fewer known defenders, the previous round's outcome, and a randomness factor so
they are not predictable). After the plant, all living attackers move to
authored post-plant positions covering the bomb.

**Defending (Aegis)**
| Role | Behaviour |
|---|---|
| `site_anchor` | Stays on its site, holds an authored angle, never leaves before a real call |
| `flex` | Plays mid/connector, rotates to the first contact |
| `awp`/`angle` | Holds the map's long sightline if the bot bought a sniper |
| `rotator` | Deliberately positioned to rotate fast; leaves on the first contact call |

After a plant, defenders converge for a retake, staging at authored retake
positions and pushing together rather than trickling in one at a time.

Both sides use the map's authored `BotPoints/` markers (tagged `hold`, `peek`,
`plant`, `retake`, `rotate`) so behaviour is map-appropriate without hand-coding
coordinates in the AI.

## Movement

- `NavigationAgent3D` for pathing on the baked navmesh, with `path_desired_distance`
  tuned so bots corner smoothly instead of pivoting at every waypoint.
- Bots **walk** (slower, silent) when holding an angle or approaching a known
  contact, and **run** when rotating or crossing safe ground — the same
  audibility tradeoff a player makes.
- In combat they strafe: pick a lateral direction, hold it for 0.3–0.8 s, flip.
  They stop strafing to take an accurate shot (matching the spread rules above).
- They use cover: when taking damage from an unseen source, they break line of
  sight toward the nearest cover marker rather than standing in the open.
- Local avoidance is enabled so teammates don't body-block a doorway, with the
  avoidance radius kept small so they still funnel through chokes realistically.

## Economy

Bots run the same `Economy` rules as the player. Buy logic per bot:

1. If money ≥ full-buy threshold: primary appropriate to role + armour (+ helmet)
   + utility + (defuse kit if defending and affordable).
2. If in the force-buy band: armour + SMG/shotgun, or upgrade the pistol.
3. If below: **save** — buy nothing, or at most a cheap pistol upgrade — but only
   if enough teammates also save, decided on the team blackboard so the team
   saves or forces *together*. A team where three bots eco and two force is the
   classic AI tell.
4. Never buy what it cannot use: no defuse kit when attacking, no sniper for an
   `entry` bot.

## Bomb handling

- The `carrier` plants inside the site's `Area3D`, preferring an authored `plant`
  marker with cover, and only when the site is reasonably clear or time is short.
  Planting is interruptible and cancels on damage.
- Defenders defuse when the bomb is unguarded or after clearing, accounting for
  whether they hold a kit (5 s vs 10 s) and whether the remaining fuse allows it
  — a bot must not start a 10 s defuse with 6 s on the clock unless it is the
  last chance.
- Bots defending a plant will "fake defuse" to bait a shot when appropriate at
  Hard difficulty.

## What must never happen (test these)

- Bot fires through a wall, through smoke, or at an enemy it cannot actually see.
- Bot tracks a player perfectly through a smoke or after losing sight.
- Bot shoots the instant a player becomes visible (reaction time must apply).
- Bot walks into a wall, gets stuck on a doorway, or fails to path to a site.
- Whole team stacks one spot, or all five funnel single-file into the same angle.
- Bot defuses with no time left, or plants outside the site.
- Frame time on 9 bots exceeds the budget.
