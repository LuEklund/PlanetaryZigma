---
name: planetary-zigma-conventions
description: PlanetaryZigma code conventions — C-mindset architecture rules, wire/netcode invariants, spec-table content pattern, hot-reload and determinism gotchas. Use when writing or reviewing any code in this repo.
---

# PlanetaryZigma conventions

Distilled from the shipped code and `implementation_ideas/` (local design docs).
When a rule here and the code disagree, the code is newer — check git, then fix this file.

## 1. C-mindset (non-negotiable, applies to every proposal)

- Dependencies are function PARAMETERS. The signature is the honest dependency list.
- No stored sibling pointers between systems. Ever. (Physics is the one resource
  passed around — as a param, never stored.)
- Too many things to touch at once? Don't touch them — leave a request in a queue,
  drained in ONE place.
- Data structs + free-function systems. Systems talk only through World data.
- One exit door per decision (`giveItem`, `World.flush`, `enterScene`,
  `request_exit` in the driver loop).
- Return values over out-params for reporting (`WireStatus`, `Hud.Request`).

## 2. World as mailbox

- World = replicated game state + its own lifecycle. Nothing else lives on it
  (UI state → Hud, settings → Options, scene → Context).
- Server: systems append intents/facts (`new_spawns`, `pending_despawns`,
  `client_updates`); `World.flush(physics)` is the ONE drain. `spawn()` returns a
  live pointer immediately — mutate freely; bodies/packets follow at flush.
- Client: NetworkManager is dumb transport — wire → World inboxes (`pending_*`,
  `attack_events`, `render_outbox`) only. It decides nothing and touches no
  renderer state.
- NetworkManager is the ONLY system that knows the wire, on both sides.
- **Drain beats poll: "no update means no change."** But once event-driven,
  ordering is load-bearing — a request drained before its consumer exists is lost
  forever. Respect Context.update order; don't reorder casually.

## 3. Wire / netcode invariants

- The wire carries REALIZED OUTPUT, never intent. Client runs zero gameplay;
  derive what motion already tells you (walk/idle from velocity), send only what
  it can't (attack = event).
- Any change in `shared/src/net.zig` ⇒ rebuild AND restart BOTH binaries.
  A stale peer misparses silently (hangs/garbage, not errors). Verify freshness
  by whether the client's own logs print — `rm -rf zig-out/lib` ≠ restarting.
- New entity-touching packet types must either go through pending-phase deferral
  (like spawns/stats) or be order-independent. Spawn packets carry motion seed
  (velocity + tick) for this reason.
- Slice payloads need a sibling `<field>_len` integer field — `unmarshal` asserts
  it BY NAME.
- `protocol_version` is a comptime FNV over types REACHABLE from the packet
  unions. A `[]const u8` payload keeps its enum out of the fingerprint (dev
  commands exploit this); an enum on the wire bumps the version per arm.
- Server send-model and client evaluate-model must MATCH (both straight-line
  today). Never change one side's motion model without the other — mismatch
  makes corrections bigger, not smaller.
- Never send vertex/node indices over the wire: mesh index order depends on
  worker count. Replicate radius/seed, regenerate deterministically on each side.

## 4. Content = spec tables (UNDER RECONSIDERATION 2026-07-22 — user may redesign; confirm before leaning on this section)

- One authoritative row per kind: `entity.spec(kind)` (collider + model + stats +
  currency + durations), `Item.spec`, `Shader.spec`. Adding content costs one
  enum arm + one row (+ one `.frag` file for particle effects) — never a parallel
  enum, pool, or manager.
- Spec = kind data; wire = instance data. Don't derive instance state client-side
  from spec.
- `all_kinds` comptime expansion exists so loops cover union payloads; keep it in
  sync when adding Kind variants.
- Name lookups fail LOUD and helpful: a wrong clip/node name errors listing every
  name the file actually contains.
- One resource pool per type with one registration door (`registerImage`,
  `registerModel`); hot reload overrides the same slot, never grows the pool.

## 5. State & scenes

- State is OWNED, not derived: `scene: Scene` is stored; transitions happen once,
  in one door (`enterScene`), which always clears. Never re-derive a predicate
  that duplicates stored state (two predicates WILL disagree).
- Modal UI state = one union, not N bools (`Overlay = union { none, pause,
  options }`) so contradictory states cannot exist.
- Prefer query-at-decision-time over stored state (grounded = raycast now, not a
  `falling` flag).
- Deliberately POLLED where polling self-heals; event-driven only where the
  drain rule (§2) is respected.
- Porting between event-driven and polled APIs: reclassify EVERY consumer as
  edge- or level-triggered first. Events give edges for free, polling gives
  levels for free; toggles and once-per-transition effects (cursor lock) need an
  explicit was/now comparison, and `isUp()` means "not held", not "just
  released".

## 6. Hot reload

- Context/World LAYOUT change ⇒ restart both binaries. Reload swaps code only;
  old bytes reinterpreted against a new layout are garbage.
- Flat `Context.init` struct literal, no `undefined` dance — possible only
  because zero sibling pointers exist. Keep it that way.
- Policy lives in the dynlib (hot-reloadable), not in main.zig's driver loop.
- Push rules: must compile, run, hot-reload.
- Dev tools are NOT gated on `builtin.mode` — they must be testable in the
  shipped binary. Opt-in is a launch flag / in-game toggle.
- Handles created through hot-reloadable code embed pointers into that .so's
  image; `dlclose` must be the LAST teardown step, never an incidental defer.
- A struct compiled into MULTIPLE .so files (ffi handle, Table types) is a
  boundary: editing it requires rebuilding EVERY library that compiles it, not
  just the one you touched. Build-and-verify cannot see the mismatch — each
  library compiles clean alone and corrupts at load time.

## 7. Planet / determinism

- One `sdf()` is the whole shape, identical on both sides; meshes (collision AND
  render) are derived caches of the density field, never sources of truth and
  never derived from each other.
- `chunkClassify` is the ONE place allowed to say "skip this chunk" — cave-aware
  widening happens there, callers never change.
- Chunks are planet-internal data (mesh IDs client-side, body IDs server-side),
  never entities, never on the wire.
- Amplitude/margin consts are load-bearing: every consumer (classify margin,
  chunk range, surfacePoint window) must read the same named const or chunks
  silently go missing.

## 8. Working style (how changes land here)

- Brainstorm first: options + recommendation + REJECTED-with-reasons, wait for
  the pick. Design docs live in `implementation_ideas/` (gitignored) with
  STATUS / AS BUILT / Landmines sections — update status when landing.
- Explain, don't edit, for learning questions; snippet + `file:line`.
- No explanatory comments; full variable names; no default struct field values;
  init/deinit pairs; inline single-use helpers; `const Name = @This();` line 1.
- Debugging: discriminating test FIRST; never declare solved from a proxy metric
  the user can't see; check operational cause (stale build, wrong flags) before
  code-digging. Measure (StageTimings, one timer) before optimizing.
- Risky mechanical moves (folder renames, path strings) land as their OWN commit
  before the feature, so breakage is unambiguous.
- Merge conflict between a refactor and a feature: take the refactored side
  wholesale, then REPLAY the feature onto it as a fresh port. Never splice hunks.
- Comment audits: prose comments get DELETE / RESHAPE / KEEP; commented-out code
  is a separate bucket — always DELETE, and grep its references against current
  declarations (a rotted field name is unarguable evidence). Verify any comment
  claiming an ordering/invariant against the call graph first — wrong claim >
  redundant prose.
- Structural review of a package: step 1 is mechanical — dump every `@import`
  line plus per-file `wc -l` BEFORE reading any file. The graph generates the
  findings (cross-boundary imports, one-file dirs, unimported files).
- Every refactor recommendation carries a grep-MEASURED edit cost, sorted by
  value/cost. Renames preserving a module name cost zero import edits.

## Settled 2026-07-22

- **Decoupling is the direction (user priority):** renderer consuming data
  (FramePacket, render-frame-packet.md) is the target end-state, and the user
  wants MORE decoupling throughout the project. Do not add new
  system/→Renderer/Vulkan imports; existing ones are legacy to unwind, not
  precedent.
- **Switches:** exhaustive by default; an `else` arm only where zero-edit
  extension is the stated goal (say so at the switch).
