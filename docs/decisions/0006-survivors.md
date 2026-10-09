# 0006 — Survivors (player classes)

## What
`shared/src/Survivor.zig`: one row per survivor with base stats and an
ability per `Action` (primary / secondary / utility / special / equipment).
Abilities are `AssignedSkill` rows (skill kind + range + radius + damage
multiplier); `server/src/gameplay/skills.zig` `executeSkill` is the one resolve
function per skill kind.

| Survivor | Primary | Secondary | Utility | Special |
|---|---|---|---|---|
| Commando (the old loadout) | shoot | spread_shot | dash | grenade (rocket, 400 %) |
| Brawler (160 hp, 2 dmg) | melee_cone (3.5 u, 150 %) | ground_slam (6 u, 300 %) | blink 14 u | heal_pulse (allies in 12 u, +35 % max hp) |
| Marksman (80 hp) | railgun (piercing, 400 %) | grenade (300 %) | blink 20 u | artillery (7 u blast at aim point, 600 %) |

- New `Action.special` (`Stat.special_cooldown`), input bit `keys.special`,
  default key R. The dev "reload" (reset to origin + resync) moved to Backspace
  and is labelled "Reset Position".
- `entity.baseStats(kind, survivor)` / `entity.abilities(kind, survivor)` are
  the one place that says "players read their survivor row, everything else
  its kind row". Player stats were removed from `entity/plain.zig`.
- The client picks a survivor on the main menu (`Options.survivor`, cycling
  button with the description on hover); it rides in `Connect.survivor` and is
  replicated in `SpawnEntity.survivor` so the HUD computes cooldowns from the
  right row.
- Rockets/grenades now carry their damage in the projectile (`damageRocketImpact`
  takes the projectile's damage instead of re-reading the owner's stat).

## Cost
Wire + layout change (protocol bump). All survivors use `benbozo.glb` for now.

## Alternatives
- Survivors as separate entity kinds: would duplicate collider/model rows and
  break every `kind == .player` check.
- Class pick in a lobby: C5; the menu button is the smallest door for now.
