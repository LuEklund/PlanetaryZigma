# 0014 — Directors like Risk of Rain 2

**Source:** riskofrain2.wiki.gg/wiki/Directors and /wiki/Difficulty (fetched 2026-10-10). Our difficulty coefficient, enemy level and chest cost formulas already matched it exactly. This decision changes how enemies get spent.

**What (server/src/gameplay/director.zig):**
- Four combat directors as data rows (`World.directors`, one EnumArray):
  | director | credits/s multiplier | between spawns in a wave | between waves |
  |---|---|---|---|
  | fast | 0.75 | 0.1–1 s | 4.5–9 s |
  | slow | 0.75 | 0.1–1 s | 22.5–30 s |
  | teleporter (while charging) | 2.0 | 0.5 s | 2–4 s |
  | teleporter boss | instant: 600·√coeff | — | — |
  Income: `multiplier × (1 + 0.4·coeff) × (players + 1) / 2` per second.
- **Spawn loop (RoR2 step for step):**
  - A wave keeps the same card and elite tier for up to 5 spawns.
  - On a failed spawn, the wave ends and a new random card is picked.
  - A card is "too cheap" when credits > 6 × its cost and cheaper cards exist. That rerolls, so rich directors spend on big monsters instead of swarming.
  - The elite tier (×6 cost, Blazing/Glacial/Overloading) is taken whenever affordable.
  - 40 monsters on the map caps every director except the boss director.
- **Monster cards:**
  - `Spec.category`: basic / miniboss / champion. `Spec.currency` is the card cost at RoR2 scale (basic 8–15, miniboss 40–45, champion 600).
  - Kill gold = 2 × 0.2 × coeff × cost (RoR2 `rewardMultiplier` 0.2).
  - A card is picked by category weight (basic 4, miniboss 2, champion 1), then by the biome's per-enemy weights.
- **Teleporter boss director:**
  - Picks a champion and spawns as many as its credits buy (up to 6), elite when it can afford it.
  - If no champion is affordable, it picks from all monsters, which is RoR2's "Horde of Many".
- **Teleporter start:** fast and slow stop and hand 40% of their credits to the teleporter director.
- **Scene director at stage load:**
  - Interactable credits = 220 × (1 + 0.5 × (players − 1)), spent on chests (card cost 15).
  - Monster credits = 100 × coeff, spent on monsters spread over the planet away from players.

**Alternatives.** Keeping our single salary director: rejected, because it spawns a steady drip instead of RoR2's waves and "big monster late" curve, which players expect.

**Not yet (TODO):** family events (one family takes over a stage), per-stage monster pools (stage 1 vs 5), loop-only variants, shrines/other interactable cards, T2 elites after stage 6.
