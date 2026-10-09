# RoR2 core loop — gap list (G0, 2026-10-09)

Formulas below are the commonly cited RoR2 ones, written from memory (the wiki
hosts were unreachable from the cloud box). Treat the constants as starting
points to tune by playtest, not as canon.

- `player_factor = 1 + 0.3 * (players - 1)`
- `time_factor = 0.0506 * difficulty_value * players^0.2` (Rainstorm `difficulty_value = 2`)
- `stage_factor = 1.15^stages_completed`
- `coefficient = (player_factor + minutes * time_factor) * stage_factor`
- `monster level = 1 + (coefficient - player_factor) / 0.33`; +30 % health, +20 % damage per level
- `chest cost = base * coefficient^1.25`
- director credits/s ≈ `0.75 * (1 + 0.4 * coefficient) * (players + 1) / 2`
- chest tier odds: common 79.2 %, uncommon 19.8 %, legendary 1 %

## What exists

| RoR2 element | PlanetaryZigma today | Where |
|---|---|---|
| Difficulty timer | none. Enemy health × stage number is the only scaling | `World.spawn` |
| Director spawn credits | flat 10 credits/s, fixed random weights, one spawn try per tick | `gameplay/director.zig` |
| Teleporter boss + charge zone | yes: interact → `bloorp_lord` boss + 10 %/s charge while any player within 12 u; leave after charge + boss dead | `gameplay/teleporter.zig`, `PlayerController.zig` |
| Item rarity tiers | none: chest rolls `random.enumValue(Item.Kind)` (lightning re-rolled to oxygen) | `PlayerController.zig` lootbox |
| Chest cost scaling | none: lootbox costs 10 forever | `entity/plain.zig` |
| Gold from kills | yes, enemy `currency` shared to all players, unscaled | `World.flush` |
| Stage carry-over | yes: players keep inventory and gold | `gameplay/stage.zig` |
| Respawn between stages | yes: dead players revived on `loadPlace` | `gameplay/stage.zig` |
| Survivors | one class (`player` spec) | `entity/plain.zig` |
| Equipment | one (`freezer`) | `Item.zig` |
| Elites | none | — |
| Run timer on HUD | none | — |

## Gaps ranked by fun / cost

| # | Gap | Fun | Cost | Plan |
|---|---|---|---|---|
| 1 | Difficulty coefficient (time + stage + players) driving enemy level (health/damage), shown on HUD | high: the core RoR2 pressure | low: one data struct on World, one function, one wire event | build now |
| 2 | Item rarity tiers + weighted chest roll | high: makes loot feel like loot | low: one field per item row + one roll function | build now |
| 3 | Chest cost scales with coefficient | medium: gold matters later in a run | trivial once #1 exists (cost written into the lootbox's `currency` at spawn, already replicated) | build now |
| 4 | Director credit rate scales with coefficient and player count; kill gold scales too | high | low | build now |
| 5 | Teleporter charge rate scales with the share of living players in the zone; boss gets the same level as ambient enemies | medium | low | build now |
| 6 | Elites (C2) | high | medium | C2 |
| 7 | More items incl. on-hit/on-kill procs (C3) | high | medium | C3 |
| 8 | Survivors with 4 abilities (C4) | high | high | C4 |
| 9 | Interactables variety (shrines, drones, equipment barrels) | medium | medium, needs models | later; needs assets |
| 10 | Difficulty selection in lobby (Drizzle / Rainstorm / Monsoon) | low | low once #1 exists | with C5 |
