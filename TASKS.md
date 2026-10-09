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
- [ ] G0 — Audit only: compare what exists (items, skills, teleporter, lootbox, currency, stages, enemies) against the RoR2 core loop: difficulty timer, director spawn credits, teleporter boss event + charge zone, item rarity tiers, chest cost scaling, stage-to-stage carry-over, respawn between stages, survivors. Write the gap list ranked by fun/cost in `docs/ror2-gaps.md`, then build the top items one per commit.

### Phase 3 — content and features
Each one: write a short proposal in `docs/decisions/` first (what, how it fits the data layout, cost), then build it. New monsters/items/classes use placeholder primitives + an entry under "Needs asset from Lucas". Web search for design references (RoR2 wiki, GDC talks) is encouraged.
- [ ] C1 — Biomes: per-planet/per-stage terrain params, palette and enemy pool as data rows. Terrain is code-generated, so this is fair game.
- [ ] C2 — Monster ideas: 5+ enemy designs with distinct behaviors (ranged, charger, flyer, swarm, elite modifiers), each as a spec row + behavior function.
- [ ] C3 — Items: 20+ RoR2-style items across rarity tiers (common/uncommon/legendary/lunar/equipment), on-hit/on-kill/passive procs as data-driven effects.
- [ ] C4 — Player classes (survivors): 3 classes with 4 abilities each (primary/secondary/utility/special). Abilities are data rows + one resolve function per ability kind, server-authoritative.
- [ ] C5 — Lobby: nicer Steam lobby (class pick, ready-up, player list, host settings). The lobby arc already shipped once — read the existing code before redesigning.
- [ ] C6 — Day/night cycle. Prior ruling: stylized color ramps, not physical scattering (no Preetham/Hosek/Bruneton). Procedural gradient sky: `up = normalize(cameraPos)`, `day = smoothstep(-0.10, 0.25, dot(sunDir, up))`, zenith/horizon colors for day and night, sun disc via `dot(V, sunDir)`; rotate `sunDir` over time for a cycle. Sun direction must also drive the directional light so they can't desync. Optional cheap planet rim: inverted sphere, `pow(1 - dot(N, V), k)`, additive.
- [ ] C7 — Particles: the system is already GPU-analytic (`pos = f(emitter, index, age)` in the vertex shader, no compute). Keep that. Known gaps: alpha never fades with age (`color.a * life`, one line), one blend equation for every effect (add additive for sparks/lightning), lightning is beads not a capsule SDF. Research better effects online, propose, then build.

### Bugs (from the 2026-08-14 review — verify each still exists; fold into Phase 1 when it touches the same code)
- [ ] R182 — Wayland registry binds globals at their XML max version; compositors other than Hyprland kill the connection. Fix: bind `@min(global.version, ceiling)`.
- [ ] R181 — Wayland key-repeat armed inside the chat-text guard but only disarmed inside it → closing chat with a key held overflows the 1024 B writer, permanent hang.
- [ ] R194 — `net.Input.keys` is a level bitfield rebuilt from edges; dropped/unmapped events stick bits forever. Write keys from per-frame `isDown()`, keep edges only for toggles. Should also close R186/R187.
- [ ] R39/R53 — holding R re-syncs the whole world every tick. Make it edge-triggered.
- [ ] R74 — one player joining full-resyncs every client. Sync only the joiner.
- [ ] R73 — failed reliable sends are dropped, never retried.
- [ ] R102 — failed submit after `vkResetFences` poisons that frame slot forever.
- [ ] R103 — `OUT_OF_DATE` with no size change never recreates the swapchain → permanent black window.
- [ ] R143 — the 5th player crashes a Debug server (`anchor_buffer[4]`). Add a lobby cap at the join door.
- [ ] R52 — freezer re-arms every tick: enemies within 10 u of a player never think.
- [ ] R9 — ally-graze / owner-gone bullets `continue` before teardown → immortal projectiles.
- [ ] R12 — UI 2048-quad cap uses `appendAssumeCapacity`; ~2100 quads in a fight panics ReleaseSafe.

## Needs asset from Lucas

## Questions for Lucas
- A0/plan step 10: the render HotLib is owned by the client `.so` (nested hot lib). Options: (a) leave it, (b) host exe owns both hot libs and passes the render Api into `systemUpdate`. Picked (a) for now — (b) changes reload ownership and needs a local reload test.
- A0: `Scene.particle_lab` is unreachable since its F4 entry was commented out (now deleted). Keep the scene (dev tool) or delete it? Kept.
