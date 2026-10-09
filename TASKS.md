# Tasks

Lucas adds tasks from his PC; the cloud session works the Queue top-down. Rules: see CLAUDE.md "Cloud workflow" and "Architecture target".
Goal: a Risk of Rain 2-like co-op roguelike on a walkable planet that Lucas will release on Steam himself. Architecture first, then gameplay.

## Queue

### Phase 1 — architecture (one commit per step, every step must build)
- [x] A0 — Audit only, no code. Write `docs/ARCHITECTURE.md` (module table + mermaid data flow of client/server/shared/render as they are today) and `docs/refactor-plan.md`: every `self:`-method struct and every struct that acts instead of being data (grep-measured list: file, symbol, callers), stored sibling pointers, policy living in the host exe (e.g. tick accumulator in `client/src/main.zig`), files mixing unrelated concepts. Rank steps by value/cost. Then carry out the steps that don't change gameplay or wire format; list the rest under "Questions for Lucas".
  - Result: `docs/ARCHITECTURE.md` + `docs/refactor-plan.md` written. Done in A0: plan steps 1-3 (Physics passed as a parameter, no more `World.physics`; network `Client` holds no pointers/allocator; dead `Physics.{gpa,io}` and commented-out code removed). Steps 4-10 continue under A1/A2/A3. Server + client build; behavior unchanged, not playtested.
- [x] A1 — Layout guard (also closes R13): each System exports a comptime FNV hash of the host-allocated layout; HotLib rejects a mismatched build with a "restart needed" log. Decision note `docs/decisions/0001-layout-guard.md`.
  - Result: `shared/src/layout.zig` hashes size/align/field names/offsets (pointers followed 4 deep); `layoutHash` exported by system_client, system_server and render; `HotLib.trySwap` rejects a mismatch with "restart needed". Could NOT test a live reload here — Lucas: rebuild the lib after adding a World field and check the log line.
- [x] A2 — Move game-loop policy (fixed-step accumulator, fps counting) out of `client/src/main.zig` and `server/src/main.zig` into the .so. Host becomes `poll → trySwap → update`.
  - Result: hosts are `trySwap → systemUpdate`; `Clock` (fixed step, sleep, stall log, fps) and World allocation moved into each .so (`System.world` by value). Server exe imports a small `system_contract.zig`. Decision 0002. Window poll stays in the client .so (chat text writer is policy). Builds (server incl. -Dviewer=false and windows); needs a local run + reload test.
- [x] A3… — Execute `docs/refactor-plan.md` steps, one per commit (skip the ones you listed as questions). Mechanical moves (renames, file splits) land as their own commit before behavior changes.
  - Result: plan step 6 (server `World.zig` + `gameplay.zig` split into `server/src/gameplay/`, mechanical commit), step 7 (`client/src/system/events.zig`), step 8 (no `World.gpa` on either side; client entity map fixed-capacity with assert). Skipped step 9 (NetworkManager hash maps → arrays: low value, touches Steam client/server code I can't run) and step 10 (asked below). All builds pass; nothing playtested.

### Phase 2 — Risk of Rain 2 loop
- [x] G0 — Audit only: compare what exists (items, skills, teleporter, lootbox, currency, stages, enemies) against the RoR2 core loop: difficulty timer, director spawn credits, teleporter boss event + charge zone, item rarity tiers, chest cost scaling, stage-to-stage carry-over, respawn between stages, survivors. Write the gap list ranked by fun/cost in `docs/ror2-gaps.md`, then build the top items one per commit.
  - Result: `docs/ror2-gaps.md` (formulas from memory — wiki unreachable from the cloud box; tune by playtest). Built #1-#5: `shared/src/difficulty.zig` coefficient (time on planet + stage + players) → enemy level (+30 % hp / +20 % dmg per level, replaces hp × stage), kill gold × coefficient, chest cost × coefficient^1.25, director credits scale; teleporter charge rate = share of living players in zone (was additive per player); HUD shows `Stage N mm:ss Lv L`; item tiers + weighted chest roll. New wire event `difficulty` (protocol bump). Built, needs playtest — balance is a guess.

### Phase 3 — content and features
Each one: write a short proposal in `docs/decisions/` first (what, how it fits the data layout, cost), then build it. New monsters/items/classes use placeholder primitives + an entry under "Needs asset from Lucas". Web search for design references (RoR2 wiki, GDC talks) is encouraged.
- [x] C1 — Biomes: per-planet/per-stage terrain params, palette and enemy pool as data rows. Terrain is code-generated, so this is fair game.
  - Result: decision 0003; `shared/src/Biome.zig` rows (coral = old look/pool, verdant, frost, dust): per-field amplitude ≤ 1 + frequency scale in `sdf`, low/high/steep vertex colors in `planet/Mesh.zig`, enemy weights used by the director. Picked by `Biome.forRadius` (radius is already on the wire), name shown on the HUD. Built, needs playtest (colors/shape untested visually). Sky tint per biome left for C6.
- [x] C2 — Monster ideas: 5+ enemy designs with distinct behaviors (ranged, charger, flyer, swarm, elite modifiers), each as a spec row + behavior function.
  - Result: decision 0004. Behavior union on the spec row + one function per behavior; new charger (grass_tank), spitter (kite), wisp (orbit flyer), mite (pack of 5), bomber (fuse/explode); elites blazing/glacial/overloading as data rows granting items; biome pools updated. Built, needs playtest (tuning numbers are guesses).
- [x] C3 — Items: 20+ RoR2-style items across rarity tiers (common/uncommon/legendary/lunar/equipment), on-hit/on-kill/passive procs as data-driven effects.
  - Result: decision 0005. 26 items (15 new) across common/uncommon/legendary/boss/lunar/equipment; procs on_hit/on_kill/on_hurt as data rows resolved in `gameplay/procs.zig` from one door (`combat.dealDamage`, no proc chains); 2 new equipment; equipment swaps on pickup. Built, needs playtest. Not done: timed buffs / DoTs (no status system yet).
- [x] C4 — Player classes (survivors): 3 classes with 4 abilities each (primary/secondary/utility/special). Abilities are data rows + one resolve function per ability kind, server-authoritative.
  - Result: decision 0006. Commando / Brawler / Marksman rows with 4 abilities each + 7 new skill kinds resolved in `executeSkill`; `special` action on R (dev reset moved to Backspace); survivor picked on the main menu, sent in `Connect`, replicated in spawns. Built, needs playtest.
- [x] C5 — Lobby: nicer Steam lobby (class pick, ready-up, player list, host settings). The lobby arc already shipped once — read the existing code before redesigning.
  - Result: decision 0007. Lobby = the ship: player list with survivor + ready, ready-up via teleporter or pause menu, survivor change in the lobby, host picks Drizzle/Rainstorm/Monsoon; run starts when everyone is ready. Steam lobby browser untouched. Built, needs multi-client playtest.
- [x] C6 — Day/night cycle. Prior ruling: stylized color ramps, not physical scattering (no Preetham/Hosek/Bruneton). Procedural gradient sky: `up = normalize(cameraPos)`, `day = smoothstep(-0.10, 0.25, dot(sunDir, up))`, zenith/horizon colors for day and night, sun disc via `dot(V, sunDir)`; rotate `sunDir` over time for a cycle. Sun direction must also drive the directional light so they can't desync. Optional cheap planet rim: inverted sphere, `pow(1 - dot(N, V), k)`, additive.
  - Result: decision 0008. Sun from server time in `shared/src/daynight.zig` → DrawList → one vector for sky, mesh light and shadows; gradient sky per the ruling with per-biome day colors, night constants, sunset band, sun disc, cubemap as night backdrop; light color dims at night. Shaders compile with slangc 2025.18; visuals untested (no GPU). Planet rim not built.
- [x] C7 — Particles: the system is already GPU-analytic (`pos = f(emitter, index, age)` in the vertex shader, no compute). Keep that. Known gaps: alpha never fades with age (`color.a * life`, one line), one blend equation for every effect (add additive for sparks/lightning), lightning is beads not a capsule SDF. Research better effects online, propose, then build.
  - Result: decision 0009. Per-effect blend (additive sparks/lightning/tracer), alpha × remaining life, capsule-SDF segments for lightning/orbit paths. Shaders compile; visuals untested (no GPU) — check in the particle lab. Soft particles proposed, not built.

### Phase 4 — Lucas decisions (2026-10-09)
- [ ] V1 — Drop `VK_EXT_shader_object` and `VK_EXT_descriptor_buffer`. Target = Vulkan 1.3 core only, per `~/Obsidian/Projects/Zeta/zeta-design.md` "Feature set": BDA, dynamic rendering, synchronization2, extended dynamic state, descriptor indexing, one persistent descriptor set, pipeline cache. Zero optional extensions in the critical path. Remove the `VK_LAYER_KHRONOS_shader_object` emulation layer. Decision note first.
- [ ] D1 — R52 freezer: freeze ALL enemies for 3 s, 100 s cooldown.
- [ ] D2 — Delete `Scene.particle_lab` and everything only it uses.
- [ ] T0 — Local dev loop (run on Lucas's PC, not cloud): screenshot hotkey/CLI flag writing PNG from the swapchain + a state-snapshot dump (scene, UI tree rects, entity counts) to a file Claude can read; usable with hot reload to check UI.
- [ ] D3 — C4: Special stays on R; dev reset moves from Backspace to an F key.
- [ ] U1 — Replace own `render/ui` with dvui (game + debug UI). Reuse the dvui Vulkan backend from `~/Projects/gifer` / Marionette. Fixes current UI overlap as part of it. After V1.
- [ ] L1 — RoR2-style character select screen (not in the main menu): survivor list, ability panel with readable descriptions, difficulty pick (host), ready. Built on dvui.
- [ ] Z1 — Zoo scene: every enemy, elite, survivor, item and particle effect laid out to inspect quickly (replaces the deleted particle lab).
- [ ] P1 — Placeholders: reuse existing models, tint / scale / add a box "hat" per variant (new enemies, elites, survivors). Ability icons = plain quad with the ability name as text.
- [ ] I1 — Item icons rendered from the item's 3D model (offscreen render at load), instead of needing a PNG per item.
- [ ] S1 — Settings file: options (audio volumes master/music/sfx, mouse sensitivity, keybinds, display) saved to a file next to the exe and loaded at start.
- [ ] S2 — Audio options in the Options screen (sliders), driven by S1.
- [x] F1 — Terrain "toon" band: `mesh.slang` rim was a hard `facing > 0.3` step (+0.3 brightness). Now `0.3 * smoothstep(0, 1, facing)`. Needs a look.

### Bugs (from the 2026-08-14 review — verify each still exists; fold into Phase 1 when it touches the same code)
- [x] R182 — Wayland registry binds globals at their XML max version; compositors other than Hyprland kill the connection. Fix: bind `@min(global.version, ceiling)`.
  - Result: already fixed — `Wayland.zig:375` binds `@min(global.version, GlobalType.interface.version)`.
- [x] R181 — Wayland key-repeat armed inside the chat-text guard but only disarmed inside it → closing chat with a key held overflows the 1024 B writer, permanent hang.
  - Result: disarm-on-close was already in place (`poll` clears `repeat_key` when `text == null`). Remaining hole fixed: after a long stall the repeat count could exceed the 1024 B writer, `poll` errored every frame and never advanced `next_time_ms`. Now clamps to free space and always advances. Needs a Wayland check.
- [x] R194 — `net.Input.keys` is a level bitfield rebuilt from edges; dropped/unmapped events stick bits forever. Write keys from per-frame `isDown()`, keep edges only for toggles. Should also close R186/R187.
  - Result: already fixed — `Controller.update` writes `keys` every frame from `window.keyboard.get(key).isDown()` (held) / `== .press` (pressed). R186/R187 not re-checked (no description in tree).
- [x] R39/R53 — holding R re-syncs the whole world every tick. Make it edge-triggered.
  - Result: server-side edge: `Controller.reload_held` + `resync_requested`; NetworkManager full-syncs only the pressing client once. Built, needs playtest.
- [x] R74 — one player joining full-resyncs every client. Sync only the joiner.
  - Result: joining no longer sets `sync_all_clients`; others get the new player via `world.spawned` (spawn packet carries the name). A rename of an already-spawned player still resyncs all. Built, needs 2-player playtest.
- [x] R73 — failed reliable sends are dropped, never retried.
  - Result: `SteamNet.sendOutgoing` keeps reliable messages that hit `k_EResultLimitExceeded` (and every later reliable message to that connection, to keep order) for the next flush. Built, needs a congested-link test.
- [x] R102 — failed submit after `vkResetFences` poisons that frame slot forever.
  - Result: fence reset moved to right before `vkQueueSubmit2`; a failed submit issues an empty submit to re-signal the fence. Built, untested (no GPU here).
- [x] R103 — `OUT_OF_DATE` with no size change never recreates the swapchain → permanent black window.
  - Result: `Vulkan.swapchain_stale` set on acquire OUT_OF_DATE and present OUT_OF_DATE/SUBOPTIMAL; next update recreates even at the same size. Built, untested (no GPU).
- [x] R143 — the 5th player crashes a Debug server (`anchor_buffer[4]`). Add a lobby cap at the join door.
  - Result: cap enforced at the join door (`NetworkManager` connect handler closes the connection with "server full"); Debug-only exception in `World.spawn` removed. Built, needs a 5-client test.
- [x] R52 — freezer re-arms every tick: enemies within 10 u of a player never think.
  - Result: freeze (10 s) could be re-armed every 5 s cooldown by holding Q → near-permanent. Active freeze no longer re-arms; freezer row adds +20 s equipment cooldown (25 s total); description fixed to 10 s. Built, needs playtest.
- [x] R9 — ally-graze / owner-gone bullets `continue` before teardown → immortal projectiles.
  - Result: projectiles already expire by `lifetime`, so not immortal; fixed owner-gone hits to despawn the projectile. Ally graze still passes through (looks intentional). Built, needs playtest.
- [x] R12 — UI 2048-quad cap uses `appendAssumeCapacity`; ~2100 quads in a fight panics ReleaseSafe.
  - Result: cap raised to 8192 quads (u32 indices, ~1.3 MB per frame buffer) and overflow drops quads/nodes with a debug log instead of panicking. Built, needs a fight to check.

## Needs asset from Lucas
- C4: Brawler and Marksman models (rigged like benbozo: Idle/Run/Death + attack clips). Both use `benbozo.glb` today; `captainbozo.glb` has no skin/animations so it can't be used as a player yet.
- C4: action-bar icons for the new abilities (special slot is a plain purple square; utility is a plain yellow square as before).
- C3: model (`objects/<name>.glb`) + icon (`textures/<name>.png`) for leech_seed, coin_pouch, crowbar, boots, bandage, gasoline, thorn_vest, vampire_fang, ghor_tome, leech_fang, brilliant_hammer, berserker_core, glass_heart, blood_pact, heal_spray, blast_wave. Paths are derived from the item name; dropping the files in is enough.
- C2: `spitter` (ranged kiter), `wisp` (small orbiting flyer), `mite` (tiny swarm bug), `bomber` (walking bomb) — currently scaled placeholder cubes (`model.path = ""` in `shared/src/entity/enemies.zig`). Each wants idle/walk/death + attack clip.
- C2: elite look — optional emissive/tint variant per affix (blazing orange, glacial ice-blue, overloading blue); today elites are just 1.25× scale + a name label.

## Questions for Lucas
- G0: no legendary items exist yet, so the 1 % legendary chest roll falls back to common (C3 adds legendaries). Lightning is now `boss` tier: only the teleporter boss drops it (same as before, when chests re-rolled it to oxygen).
- G0: enemy health used to scale ×stage (5× on stage 5). Now it follows the RoR2 level curve — similar by stage 5 at ~20 min, gentler early. Director base salary kept at 10 credits/s at coefficient 1.

## Answered (2026-10-09)
- C5: everyone must ready up — keep.
- R9: bullets pass through allies — keep.
- R52: freeze all 3 s / 100 s cooldown → D1.
- A0 particle lab: delete → D2.
- C4: Special on R, reset on an F key → D3.
- A0 step 10: keep render HotLib nested in the client .so (faster reload) unless it causes problems.

## Cloud notes
- ziglang.org and gitlab.freedesktop.org are blocked from the cloud box. Zig 0.16.0 came from the PyPI `ziglang` wheel (official binary); git deps were fetched with `git` and fed to `zig fetch <dir>` (hashes match). `ztracy` (HTRMC fork, unreachable) is a local no-op stub and `wayland_protocols` comes from Ubuntu's package — both only in gitignored `zig-pkg/`, so `-Dtracy=true` was never built here. `slangc` 2025.18 from the shader-slang GitHub release.
