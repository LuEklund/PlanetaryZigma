# 0009 — Particle pass: blend per effect, life fade, capsule ribbons

## What (system stays GPU-analytic: `pos = f(emitter, index, age)`, no compute)
- `Effect.blend` (`alpha` | `additive`) is a CPU-side row field; the renderer
  sets `vkCmdSetColorBlendEquationEXT` per effect batch. Sparks, lightning and
  tracers are additive (glow stacks), puffs and the item swirl stay alpha.
  Additive leaves destination alpha untouched.
- Alpha × remaining life: `alpha = core² · color.a · (1 - age_fraction)`
  (replaces the last-25 % smoothstep). KeepAlive effects have age 0 → life 1.
- Path effects (lightning lines, item orbits) draw each segment as a capsule:
  the quad is extended by one radius past both ends and the fragment computes
  the distance to the segment in radius units, so joints get round caps instead
  of wedge gaps ("beads").

## Researched, not built
- Soft particles (depth fade against the opaque depth buffer): needs the depth
  attachment bound as a sampled image in the particle pass. Biggest remaining
  quality win for puffs touching terrain.
- Additive core + alpha halo per effect (two draws) as in Diablo III's VFX
  talk; a `glow` row field could drive it.
- Bolt flicker: re-seed the jitter a few times over the 0.3 s lifetime.

Sources: vfxdoc "Fading" (soft particles, additive fade), GDC 2013 "The VFX of
Diablo" notes, hexaquo Godot lightning shader (distance-field bolt).
