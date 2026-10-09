# 0003 — Biomes as data rows

## What
`shared/src/Biome.zig`: one row per biome (`verdant`, `coral`, `frost`, `dust`)
holding
- terrain: an amplitude scale (0..1) per noise field in `planet/Field.zig` and a
  frequency scale,
- palette: low / high / steep vertex colors used by `planet/Mesh.zig`,
- enemy pool: a weight per `EnemyKind` used by the director.

`Biome.forRadius(planet_radius)` picks the row. The planet radius is already the
only planet state on the wire (`spawn_planet`), and the server derives it from
the stage, so client and server agree on the biome without a new packet and the
stage → biome mapping stays deterministic.

## How it fits the data layout
- `sdf()` keeps its signature `(position, planet_radius)`; it looks the row up
  itself. Amplitude scales are clamped to ≤ 1, so `Field.max_height` (the
  load-bearing bound read by chunk classification) stays valid.
- Director: `switch (random)` over hard-coded percentages becomes a weighted
  pick over `biome.enemy_weights`. Adding an enemy to a biome is one number.
- Adding a biome costs one row.

## Cost
~150 lines, no new packet, no layout change in World. Visual only on the client
(vertex colors) plus terrain shape and spawn mix on both sides.

## Alternatives
- Biome id on the wire: redundant with the radius, and one more thing to keep in
  sync across reconnect/full-sync.
- Per-chunk biomes (regions on one planet): nicer, but chunk classification
  would need per-region bounds. Later.
