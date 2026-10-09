# 0001 — Layout guard for hot reload

## What
Each hot-reloaded library exports `layoutHash() u64`: a comptime FNV-1a hash of
the types whose bytes outlive a reload.

| Library | Hashed types |
|---|---|
| `system_client` | client `System`, client `World` |
| `system_server` | server `System`, server `World` |
| `render` | render `Context` (reaches `Vulkan` through its pointer) |

`shared/src/layout.zig` walks each type: size, alignment, every field name +
bit offset + field type, enum tag values, union arms, array/vector lengths, and
follows pointers up to 4 levels (bounded so recursive types terminate and
comptime memoizes on `(type, depth)`). Type *names* are not hashed, only shape.

`HotLib` reads the hash when it first opens a library. On `trySwap` it opens the
new build, compares hashes, and on mismatch logs
`persistent memory layout changed (...) restart needed; keeping the running build`,
closes the new copy and records its mtime so it is not retried every frame.
The check is enabled for any Api table with a `layoutHash` field.

## Why
Reload swaps code, not data. A rebuilt `.so` with a new field in `World`
reinterprets old bytes and corrupts silently. Closes R13.

## Alternatives
- Version number bumped by hand: forgotten exactly when it matters.
- Hash `@typeName` + `@sizeOf` only: misses reordered or retyped fields of equal size.
- Serialize state across reload: heavy, and contradicts "reload swaps code only".

## Connections
- `shared/src/HotLib.zig` (check), `shared/src/layout.zig` (hash).
- Exports: `client/src/System.zig`, `server/src/System.zig`, `render/vulkan/root.zig`.
- Contract tables: `client/src/system_contract.zig`, `server/src/System.zig` `ffi.Table`, `render/renderer_contract.zig`.
- Changing any Api table is itself a host rebuild + restart.
