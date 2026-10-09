# 0004 — Monster behaviors and elites as data

## What
- `entity.Spec` gains `behavior: Behavior` (a tagged union with tuning numbers)
  and `pack_size`. `server/src/gameplay/enemies.zig` switches on the behavior,
  not the enemy kind: one function per behavior (`chase`, `leap`, `plant`,
  `heal`, `kite`, `orbit`, `charge`, `fuse`). The nine copy-pasted chase blocks
  became one `chase(context, locomotion)`.
- New rows in `shared/src/entity/enemies.zig`:

| Kind | Behavior | Role | Model |
|---|---|---|---|
| `grass_tank` | `charge` — windup 0.7 s, straight dash ×5 speed, one contact hit | charger | existing `grasstank.glb` (it had no behavior and no primary skill, so dev-spawning it panicked on `.?`) |
| `spitter` | `kite` — backs off under 10 u, closes over 20 u, shoots | ranged | placeholder cube |
| `wisp` | `orbit` — hovers at 6 u circling the player at 12 u, shoots | flyer | placeholder cube |
| `mite` | `chase`, `pack_size = 5` | swarm | placeholder cube |
| `bomber` | `fuse` — 0.8 s fuse in melee range, 5 u blast with falloff, dies | exploder | placeholder cube |

- Per-entity AI state is data on the server entity (`Entity.ai`: phase,
  phase end time, locked direction, struck flag).
- Elites: `shared/src/Elite.zig` rows (`blazing`, `glacial`, `overloading`) =
  health / damage / cost multipliers + granted items (energy drinks, icicles,
  lightning) so procs reuse the item stat machinery. The director rolls an elite
  (25 % once the coefficient ≥ 1.3) and pays `cost × 6`. `SpawnEntity.elite`
  replicates the affix; the client scales the model 1.25× and shows the affix
  name over the health bar in the elite tint.
- Glacial's stun on players now slows them (30 % move speed while stunned);
  before, a stun did nothing to players server-side.

## Cost
Wire: `Skill.charge`, `Skill.explode`, `SpawnEntity.elite` (protocol bump).
Layout: server `Entity` (+`ai`, `elite`), client `Entity` (+`elite`).

## Alternatives
- One behavior function per enemy kind: duplicates chase logic nine times
  (what existed).
- Elite effects as bespoke code paths: more to maintain than granting items.
