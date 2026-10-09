# Architecture

Co-op roguelike shooter on a walkable SDF planet. Server-authoritative over Steam
networking; client is a replicator + renderer. Everything gameplay-side is
hot-reloadable code in a `.so`; the executables are thin hosts.

## Packages

| Package | Builds | Role |
|---|---|---|
| `shared/` | module `shared` | The contract both sides compile: wire format (`net.zig`), entity spec rows (`entity.zig`, `entity/`), items (`Item.zig`), planet SDF + chunking + nav graph (`planet/`), Steam transport (`SteamNet.zig`, `steamNet/`), hot reload (`HotLib.zig`, `DynLib.zig`), log fn, tick constants. |
| `server/` | `server` exe, `libsystem_server.so` | Authoritative simulation. Host exe owns `World` + `System` memory and the tick loop; the `.so` runs network → gameplay → physics → flush → replication. Optional `viewer/` (build option) draws the server world through the renderer. |
| `client/` | `client` exe, `libsystem_client.so` | Replicates server state, runs input/camera/HUD/audio/animation, extracts a `DrawList` for the renderer. Spawns the server process for hosting. |
| `render/` | `librender.so` + modules `renderer_contract`, `graphics`, `ui`, `Window` | Vulkan renderer (shader objects, descriptor buffers, BDA) behind a C-ABI `Api` table; asset loading (`graphics/`), immediate-mode UI (`ui/`), native windowing (`window/`: Wayland, Xlib, Win32, Cocoa). |

## Modules

| Module | File(s) | Owns | Talks through |
|---|---|---|---|
| Client host | `client/src/main.zig` | gpa, window, client `World`, `HotLib(system_client)`, fixed-step loop + fps | `system_contract.Api` (4 fns) |
| Client System | `client/src/System.zig` | render `HotLib`, audio, assets, animator, particles, NetworkManager, Hud, scene | World (mailbox), DrawList |
| Client World | `client/src/World.zig` | replicated entities, dying list, damage events, camera/controller/chat/options, planet | packets in, read by extract/hud |
| Client NetworkManager | `client/src/system/NetworkManager.zig` | Steam client, server process spawning, `packets` inbox, tick estimate | `packets` list consumed by World/System |
| Hud | `client/src/system/Hud.zig`, `hud/` | screen/overlay state, UI context, damage popups | returns `Hud.Request` |
| extract | `client/src/system/extract.zig` | — | World → DrawList |
| Renderer | `render/vulkan/` | Vulkan device, swapchain, frame data, resources | `renderer_contract.Api` (C ABI, hot-reloaded inside the client System) |
| Server host | `server/src/main.zig` | gpa, args, server `World`, `System` instance memory, viewer window, fixed-step loop | `System.ffi.Table` (4 fns) |
| Server System | `server/src/System.zig` | NetworkManager, Physics, Viewer | World |
| Server World | `server/src/World.zig` | entities, players, spawn/despawn queues, physics command + impact queues, client_updates outbox, director, planet, navmesh, stage | `flush()` is the one drain |
| Physics | `server/src/system/Physics.zig` | box3d world | `physics_commands` in, `impacts` out |
| gameplay | `server/src/system/gameplay.zig` | — | enemies, director, projectiles, items, teleporter, regen, wipe |
| PlayerController | `server/src/system/PlayerController.zig` | — | input → physics commands, interact, skills, dev keys |
| Navmesh | `server/src/system/Navmesh.zig` | flow field + worker thread | `direction()` queries |
| Server NetworkManager | `server/src/system/NetworkManager.zig` | Steam server, client table, motion dedup | `client_updates` + `spawned` → wire |

## Data flow

```mermaid
flowchart LR
  subgraph ClientExe[client exe]
    CH[main.zig loop] -->|systemUpdate| CS
  end
  subgraph ClientSo[libsystem_client.so]
    CS[System.update] --> WIN[Window.poll]
    CS --> HUD[Hud.update] -->|Request| CS
    CS --> CTRL[Controller → net.Input]
    CTRL --> CNM[NetworkManager.update]
    CNM -->|packets| CW[World.update]
    CW --> ANIM[animate] --> EXT[extract → DrawList]
    EXT --> RAPI
  end
  subgraph RenderSo[librender.so]
    RAPI[Api.update] --> VK[Vulkan]
  end
  subgraph ServerSo[libsystem_server.so]
    SNM[NetworkManager.update] -->|input on entities| PC[PlayerController]
    PC -->|physics_commands| PHY[Physics.update]
    GP[gameplay: director/enemies] -->|physics_commands, spawns| PHY
    PHY -->|impacts| GP2[gameplay: projectiles/items/teleporter]
    GP2 --> FL[World.flush]
    FL -->|client_updates, spawned| SNM2[NetworkManager next tick → wire]
  end
  subgraph ServerExe[server exe]
    SH[main.zig loop] -->|systemUpdate| SNM
  end
  CNM <-->|Steam P2P / loopback: ClientPacket, ServerPacket| SNM
```

## Hot reload

- `shared/src/HotLib.zig` copies the `.so`, `dlopen`s the copy, resolves every
  field of the Api table by name, and swaps on mtime change
  (`reload(handle, true)` → swap → `reload(handle, false)`).
- Three hot libs: `system_client` (host: client exe), `render` (host: client
  System), `system_server` (host: server exe).
- Persistent memory survives a swap and is reinterpreted by the new code:
  client `World` (host stack), client `System` (gpa, created by the `.so`),
  server `World` + `System` (host stack). A layout change there needs a restart.
