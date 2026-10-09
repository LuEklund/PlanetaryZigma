# 0002 — Loop policy and persistent state live in the `.so`

## What
- Host exes (`client/src/main.zig`, `server/src/main.zig`) are: allocator,
  args, window, `HotLib`, and `while (...) { trySwap; if (systemUpdate(handle)) break; }`.
- `systemUpdate(handle) bool` decides itself whether a fixed step is due
  (`shared/src/Clock.zig`: accumulator, 1 ms sleep, stall warning), advances
  `elapsed_time` / `delta_time` (and `tick` on the server), counts fps on the
  client, and returns "exit requested".
- Each `.so` allocates one `System` (which now holds `World` by value) in
  `systemInit`. The host keeps an opaque `*anyopaque`.
- The server host imports only `server/src/system_contract.zig` (Data + Api),
  no longer the whole `System.zig`.

## Why
Tick timing is game policy and must hot-reload. The host reading
`system_instance.request_exit` or allocating `System`/`World` on its stack meant
the exe depended on `.so` layouts; now only the `.so` does, and the layout
guard covers it. Removes the stored `System.world` pointer (refactor plan #5).

## Alternatives
- Host owns World in a permanent arena and passes it each update (Marionette
  style). Keeps World across a full `.so` restart, but the host must then know
  World's layout. Not needed today: there is no "reinit the .so without
  restarting" path.
- Window poll in the host: the poll options (text writer only while chat is
  open) are client policy, so `poll` stays inside the client `.so` update.

## Connections
- `shared/src/Clock.zig`, `shared/src/HotLib.zig`
- `client/src/system_contract.zig`, `server/src/system_contract.zig`
- `docs/ARCHITECTURE.md` hot reload section
