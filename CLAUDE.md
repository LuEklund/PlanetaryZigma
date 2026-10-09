# Project
PlanetaryZigma — co-op roguelike shooter. Zig 0.16 + C++, custom Vulkan renderer
(VK_EXT_shader_object, descriptor buffers, BDA). Server-authoritative UDP netcode.
Three Zig packages: shared/ (contract), server/ (authoritative sim), client/ (replicator + renderer).
Hot-reload split: thin exe loads system_{server,client}.so via 4-fn ffi Table.

# Build / run / test
No root build.zig — build from each package dir.
- Build: `cd client && zig build` (also compiles Slang→.spv, needs `slangc` on PATH); `cd server && zig build`.
  plain `zig build` is Debug — `--release` is forced to ReleaseSafe; `-Dtracy=true` for profiling; `zig build windows` (server) cross-compiles Windows artifacts.
- Run server: `cd server && zig build run -- [--dev] [--local-singleplayer] [<host_steam_id>]`
  (--dev = small planet; normally the CLIENT spawns the server itself and hands over via the `server_id` file).
- Run client: `cd client && zig build run` (Steam must be running; appid 4891340).
  Hot reload: `cd client && zig build lib` rebuilds only system_client.so; running exe picks it up.
- Tests: `cd shared && LD_LIBRARY_PATH=<zig-pkg steamworks lib dirs> zig build test -Dtarget=x86_64-linux-gnu.2.39`
  (native target hits GCC-16 crt1.o R_X86_64_PC64 linker error — same pin as box3d_spike; test exe needs
  libsdkencryptedappticket.so/libsteam_api.so from shared/zig-pkg/zig_steamworks*/steamworks/{public/steam/lib,redistributable_bin}/linux64).
  Physics smoke test: `cd server/box3d_spike && zig build run` → "SPIKE OK".
- Vendor note: box3d is a patched third-party port — block_allocator.c 8-byte
  rounding + sanitize_c=.off in build.zig. Don't regenerate/clobber this.

# Scope
Focus on today's problems, today's features — we can't guarantee tomorrow's will come.
- NEVER create or keep code that exists only for tests. Tests may only exercise
  production doors; if a function's only caller is a test, delete both.

# Lucas's rules (copied from his global config — the cloud session has no other copy)

## Talking to Lucas
State the fact, nothing more. 1-3 sentences is the ceiling. No background, no "the interesting part is". He asks follow-ups.

## Think C — always
- Dependencies are function parameters. The signature IS the honest dependency list.
- No stored sibling pointers between systems/managers/objects. Ever.
- Need to touch too many things at once? Leave a request in a queue, drained in ONE place.
- Data structs + free-function systems. Systems talk through data, not through each other.
- Hoist out of objects. Structs are data, they do not act. A field used by one system lives in that system.
- Who owns a decision matters more than where the code sits. One exit door per process.
- Return values over out-params for reporting.
- A needed comment is a design smell — fix the name or the shape instead.
Before proposing any structure: "what would this look like in C?" — fewer moving parts wins.

## Think Casey — every boundary (module, .so, API) judged on Muratori's five
- Granularity: granular layer first, convenience call on top — never only the convenience call.
- Redundancy: never make the caller restate what the component already knows.
- Coupling: no required base types, no "register with me first", no imposed lifetimes. Data in, data out.
- Retention: component holds nothing on the caller's behalf; caller owns any cache.
- Flow control: caller owns the loop. Step functions, no callbacks, no frameworks.
Caller-owned memory: allocator parameter fine, hidden malloc not. When C rules and these fight, say which you traded, one line.

## Handmade / data-oriented memory
- Arenas, not per-object allocation. Scratch reset wholesale, never freed item by item.
- Structs do not own memory: no `deinit` that only frees, no allocator field.
- Fixed capacity + assert on overflow over growable containers.
- Dynamic lifetimes = pool + freelist + generation; handles `{id, generation}`.
- OS/GPU resources owned by a system (init/shutdown); everything else holds a handle. No RAII doing work.
- Arrays of things over arrays of pointers; batch over arrays.
- Sort + scan over hash maps for grouping/dedup/pairing.
- GPU: few large allocations, bump-suballocated; one big vertex/index buffer.
- Simple version first, profile, then specialize — never a design that cannot be optimized later.

## Architecture target (Lucas, 2026-10-09)
Reference projects Marionette and gifer are NOT in this repo; their Window and HotLib already live here (`render/window/`, `shared/src/HotLib.zig`). What they do better is described below.
- Host exe is thin: window, permanent arena, `poll → trySwap → update`. All policy (tick timing, game loop decisions) lives in the .so.
- Hot reload is sacred. Every change must keep it working. Add Marionette's layout guard: a comptime FNV hash of the host-allocated struct layout, exported by the .so; host refuses a mismatched build and logs "restart needed". The cloud can't test reload — assume it works, Lucas verifies locally.
- Data-oriented: structs are plain data, behavior is free functions that take the data as parameters. `self:` methods are the exception, not the default. A function can still live in the namespace of the data it's about (`Enemy.update(enemies, world_view)`), but it reads like a C function, not an object method.
- Prefer functions over arrays (`updateEnemies(enemies: []Enemy, ...)`) to functions over one item.
- One concept per file; files grouped by what they're associated with (gameplay/, net/, render/, planet/...).
- Docs like Marionette: `docs/ARCHITECTURE.md` (module table + mermaid data flow, kept current) and `docs/decisions/NNNN-title.md` (what, why, alternatives, connections) for each structural change.

## Docs
- Zig 0.16: read std source (`zig env` → std_dir) instead of recalling APIs. APIs changed a lot (std.Io, no std.posix.recvfrom, etc).
- Vulkan: check `vk.xml` / the spec for every call. Never guess a signature.
- Before writing code, read `.claude/skills/planetary-zigma-conventions/SKILL.md`.

## Assets — HARD RULE
- NEVER create, download, or generate models, textures, sprites, sounds, or music. Lucas makes art and audio himself.
- Use only assets already in `assets/`. If a feature needs a model that doesn't exist, build a placeholder from primitive shapes (box/sphere/capsule) in code and list it in TASKS.md under "Needs asset from Lucas".
- Procedural-by-code is allowed: terrain, particles, shader effects, sky, UI geometry.

## Player-facing text — Lucas approves
- Any name, description or label a player can see that Claude wrote (survivors, abilities, items, monsters,
  elites, biomes, UI strings) gets a checkbox line in `docs/lucas-approval.md`. Lucas ticks or rewrites it.

## Git
- No Claude credit anywhere: no Co-Authored-By trailers, no "Claude"/"AI" in commit messages or PR bodies.
- Work only on the `ai` branch. One task = one commit, plain short message.
- NEVER release anything: no Steam uploads, no steamcmd, no builds sent anywhere, no tags, no merges into master, no PRs. Lucas ships manually.

# Cloud workflow (Claude Code on the web)
Lucas splits the work: the cloud session implements ideas while he's away; he builds, runs and playtests on his PC.
- Task queue: `TASKS.md`. Take the top unchecked task under "Queue", do it, tick it, append a 1-3 line result under it (what changed, what you could NOT verify).
- The cloud box has no Steam and no GPU: you can't run the game. `cd server && zig build` must pass; try `cd client && zig build` (needs `slangc` — if it's missing, say so and don't fake it). If Zig 0.16 isn't installed, install the official 0.16.0 tarball.
- Never mark a gameplay/render task "done" — mark it "built, needs playtest".
- Lucas is AWAY. Never end your turn to ask him something and never stop at uncertainty. Keep working the queue until it's empty or every remaining task is blocked.
- Uncertain? Write the question under "Questions for Lucas" in TASKS.md (task id, the options, which one you picked and why), then pick the most reversible option and keep going. If no option is safely reversible, skip to the next task.
- Commit after every finished step so nothing is lost if the session dies.
- Bug list items are from a 2026-08-14 review: verify the bug still exists in the tree before fixing. If it's already fixed, tick it with "already fixed".
