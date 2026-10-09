# 0005 — Item procs as data

## What
`Item` rows gain `procs: []const Proc`. A proc is `{ trigger, chance, effect }`:

- triggers: `on_hit` (owner dealt damage), `on_kill` (owner's hit killed),
  `on_hurt` (owner took damage from an entity);
- effects (`ProcEffect` union): `heal`, `leech`, `gold`, `blast`,
  `healthy_bonus`, `thorns`. Magnitudes scale linearly with stacks; `blast`
  also grows its radius per stack.

`server/src/gameplay/procs.zig` has one resolve function: `afterHit` runs the
attacker's on_hit/on_kill and the victim's on_hurt rows. It is called from one
place, `combat.dealDamage`, after health changed. Proc damage goes through
`dealDamage(…, can_proc = false)`, so procs never chain into procs.

Equipment: `Item.Effect` gains `heal_burst` and `blast_wave` (resolved in the
`use_equipment` skill). Picking up equipment replaces the held one (RoR2 rule).

Lunar tradeoff items use negative `percent`/`flat` stats; `Stat.value` now
floors the percent scale at 0.1 so stacking can't zero out a stat.

## Items (26 total, 15 new)

| Tier | Items |
|---|---|
| common | oxygen, energy_drink, gun, pickaxe, heart, **leech_seed**, **coin_pouch**, **crowbar**, **boots**, **bandage** |
| uncommon | rocket, scope, rabbitsfoot, icicle, **gasoline**, **thorn_vest**, **vampire_fang**, **ghor_tome**, **leech_fang** |
| legendary | **brilliant_hammer**, **berserker_core** |
| boss | lightning |
| lunar | **glass_heart**, **blood_pact** (2 % chest roll) |
| equipment | freezer, **heal_spray**, **blast_wave** |

The existing rocket/lightning procs keep their hand-written paths in
`projectiles.zig`; folding them into proc rows is a follow-up (they depend on
projectile kind and impact point).

## Cost
Wire: new `Item.Kind` arms (protocol bump). Layout: inventories grow.
New items have no model/icon yet: pickups draw as the fallback cube, icons as
the "missing" texture.

## Alternatives
- A callback per item: code per row, harder to balance and to hot-reload.
- Buff/status system first (timed speed boosts, burn DoT): needed for a big
  part of RoR2's list; not built yet — next step for items.
