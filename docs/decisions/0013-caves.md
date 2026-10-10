# 0013 — Caves: gentle tunnels in a band under the surface

**What.** `sdf = max(terrain, -cave)` in `shared/src/planet/sdf.zig`, only within `cave_depth` (24 m) under the outer surface and only on planets with r ≥ 100. A tunnel follows a zero-isoline of a surface noise (its path). Its center depth is a second, slow surface noise, so floors slope at most about 29° (there's a test for this). Wherever the center depth goes above ground, the tunnel opens into a ramp, and that's an entrance. The cross-section is an ellipse about 6 m wide and 5 m tall.

**Rulings taken (Lucas said "let's go", vault `caves-terrain.md` recommendations):**
(a) `surfacePoint` = the outer terrain only (`sdf.terrain`), so spawns, props, water and nav snapping never land in a cave.
(b) Band-local, not deep: the buried-chunk skip stays, moved down by `cave_depth`.
(c) Physics already divides by |∇| at the ground check. The cave field is scaled to roughly meters, so the raw hover check stays sane.
(d) Enemies don't path into caves this rung. Nav snaps to the outer surface, so a player in a cave draws enemies to the ground above it.

**Why not 3D noodle noise.** Lucas: caves must go into the ground gently so players can get out and enemies don't get stuck. 3D noise makes vertical shafts.

**Also.** Shared tests were never run, because nothing referenced the nested test files. `shared/src/root.zig` now references planet + layout; one stale range test was fixed. Dev: `pz cmd "!cave"` flies the free camera into the nearest tunnel.

**Status 2026-10-10:** disabled (`caves_enabled = false`, comptime — zero cost). Flip it once caves have a gameplay use.
