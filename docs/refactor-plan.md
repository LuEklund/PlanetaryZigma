# Refactor plan (A0 audit, 2026-10-09)

Measured with grep on the tree at `760178c`. Counts are call sites outside the
defining file unless noted.

## 1. Stored sibling pointers

| File | Field | Uses | Fix |
|---|---|---|---|
| `server/src/World.zig:18` | `physics: *Physics` (set in `System.init`) | 5 in World (`rayCast`, `loadPlace`, `flush` ×2, revive) | Pass `*Physics` as a parameter: `flush(world, physics)`, `loadPlace(world, physics, place)`, `rayCast(world, physics, …)`; propagates to `executeSkill`, `updateEnemies`, `PlayerController.update`, `updateWipe` (~15 edits). |
| `server/src/System.zig:35` | `world: *World` | 3, all in `reload` | Server `.so` allocates one state block holding System + World (A2); reload reaches the world through the handle. |
| `server/src/system/NetworkManager.zig:24-27` | `Client.{gpa, io, steam_server: *Server}` | 1 (`sendCommand`) + `deinit` | `sendCommand(steam_server, gpa, client, …)`; deinit takes gpa/io. |
| `client/src/System.zig:40` | `window: *Window` | whole System | Keep for now: the window is host-owned and outlives the `.so`. Becomes an `update` parameter once the host loop is `poll → trySwap → update` (A2). |

## 2. Structs that own an allocator / act instead of being data

| File | Symbol | Note |
|---|---|---|
| `server/src/World.zig:10`, `client/src/World.zig:20` | `World.gpa` | Every list is fixed-capacity after init; `gpa` is only used by `deinit` and planet sync. Candidate for a host permanent arena (World never frees item by item). |
| `server/src/system/Physics.zig:23-24` | `Physics.{gpa, io}` | Never read — dead fields. |
| `server/src/system/NetworkManager.zig:10` | `NetworkManager.gpa` + per-client `Client.gpa` | Hash maps grow (`clients`, `last_motions`, `pending_motions.append`). Fixed-capacity arrays sized by `max_players` / `max_entities` would remove the allocator. |
| `client/src/system/NetworkManager.zig:9` | `NetworkManager.gpa` | Same pattern. |
| `server/src/World.zig` | 18 `self:` fns: `spawn`, `removeHealth`, `addHealth`, `giveItem`, `useAction`, `executeSkill`, `aimPoint`, `loadPlace`, `flush`, … | World "acts": skills, combat and stage generation live on the data struct. Move to `server/src/gameplay/{skills,combat,stage}.zig` as free functions taking `*World` (call sites keep `world.x()` only where the function stays in World's namespace). |
| `client/src/System.zig:179-213` | event fan-out | Audio, particles, teleporter state and stun all decided inline in `System.update`. Move to `system/events.zig`: `apply(world, particles, audio, packets)`. |

`self:` methods by file (top 12): `render/vulkan/internal/Vulkan.zig` 26,
`render/ui/root.zig` 20, `server/src/World.zig` 18, `render/window/root.zig` 17,
`render/window/internal/Wayland.zig` 16, `Xlib.zig` 15, `Vulkan/Resources.zig` 15,
`client/src/system/NetworkManager.zig` 15, `shared/src/planet/root.zig` 14,
`Cocoa.zig` 13, `render/graphics/Animator.zig` 13, `steamNet/Client.zig` 12.
Window/Vulkan/Steam ones are OS/GPU resource systems (init/shutdown owners) and
stay; the gameplay ones (World, NetworkManager) are the targets.

## 3. Policy in the host exe

| File | Policy | Target |
|---|---|---|
| `client/src/main.zig:55-82` | fixed-step accumulator, sleep, fps window, `world.elapsed_time/delta_time` writes, `getDeltaTime` with a function-static | `.so` (A2) |
| `server/src/main.zig:183-202` | same + `world.tick += 1`; host reads `system_instance.request_exit` (a field of a `.so`-defined struct) | `.so` (A2); exit reported as `update` return value |
| `server/src/main.zig:168` | host allocates `System` on its stack with the `.so`'s layout | `.so` allocates (A2) |

## 4. Files mixing unrelated concepts

| File | Concepts | Split |
|---|---|---|
| `server/src/World.zig` (689) | entity store, spawn/despawn queues, combat, skills + aiming, stage generation (`loadPlace`), teleporter reward | store stays; `gameplay/skills.zig`, `gameplay/combat.zig`, `gameplay/stage.zig` |
| `server/src/system/gameplay.zig` (401) | director, enemy AI, projectiles + lightning/rocket procs, items, teleporter, regen, wipe | `gameplay/director.zig`, `enemies.zig`, `projectiles.zig`, `teleporter.zig`, `players.zig` |
| `client/src/System.zig` (351) | lifecycle, scene machine, input routing, net event fan-out, options → window | `system/events.zig`, `system/input.zig` |
| `shared/src/root.zig` | constants, logging, `teleporter` namespace | `shared/src/teleporter.zig` |

## 5. Ranked steps (value / cost)

| # | Step | Value | Cost | Gameplay / wire change? |
|---|---|---|---|---|
| 1 | Physics as a parameter (drop `World.physics`) | high: removes the only cross-system pointer in gameplay | ~15 edits | no |
| 2 | Drop dead `Physics.{gpa, io}`, `Client.{gpa, io, steam_server}` → params | medium | ~10 edits | no |
| 3 | Delete commented-out code (`client/src/System.zig:282-285`, `gameplay.zig:42-43,98`, `PlayerController.zig:33`) | low | trivial | no |
| 4 | A1 layout guard | high (hot reload safety) | 1 file + 2 exports | no |
| 5 | A2 loop policy → `.so`, `.so` allocates server state, drop `System.world` | high | ~4 files | no |
| 6 | Split `server/src/World.zig` + `gameplay.zig` into `server/src/gameplay/` (mechanical move commit) | medium | ~10 files, 0 behavior | no |
| 7 | Client event fan-out → `system/events.zig` | medium | 1 file | no |
| 8 | World lists from host arena, drop `World.gpa` | medium | 2 Worlds | no |
| 9 | NetworkManager hash maps → fixed arrays | low-medium | 2 files | no |
| 10 | Render HotLib owned by the client host instead of the client `.so` | medium | build + 3 files | no — but changes who owns reload; asked in TASKS.md |

Status column is kept in TASKS.md (A3…).
