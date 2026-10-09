# 0007 — Lobby in the ship

## What
The ship already is the pre-run room (teleporter in the middle, target dummy),
so the lobby lives there instead of a separate menu screen:

- `ClientPacket.lobby` (`LobbyCommand`: `survivor`, `ready`, host-only
  `difficulty`) and `ServerPacket.lobby_player` / `lobby_difficulty`.
- Server: `server/src/gameplay/lobby.zig` — the one door for lobby state
  (`setSurvivor`, `setReady`, `setDifficulty`, all ignored off the ship) and
  `updateLobby`, which starts the run (`start_round_requested`) once every
  player is ready and clears the ready flags. Interacting with the ship
  teleporter toggles your ready flag (before: anyone could start the run alone).
- Difficulty setting (Drizzle / Rainstorm / Monsoon) is World data feeding
  `difficulty.coefficient`; only the host connection may change it.
- Client: lobby panel (player name, survivor, ready) top-right while
  `stage == 0`; the pause menu in the ship gains Survivor / Ready / (host)
  Difficulty buttons. Full sync sends every player's lobby state and the
  difficulty to a joiner.

## Cost
Wire change (protocol bump); server `Entity.ready`, `World.difficulty_setting`;
client `Entity.ready`, `World.difficulty_setting`.

## Alternatives
- A separate lobby screen before the server spawns: duplicates the ship and
  needs a second connection phase.
- Steam lobby metadata for ready state: only useful before joining; in-game
  state already replicates through the server.
