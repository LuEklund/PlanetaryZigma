const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");

const charge_per_second: f32 = 10;

pub fn updateTeleporter(world: *World) void {
    const entity = world.getPtr(world.teleporter_id) orelse return;
    const teleporter = &entity.teleporter;
    if (teleporter.charged == teleporter.max_charge) {
        world.director.spawning = false;
        teleporter.state = .completed;
        return;
    }
    const old_teleporter_charge = teleporter.charged;
    var living_players: f32 = 0;
    var players_in_zone: f32 = 0;
    for (world.players.items) |player_id| {
        const player = world.getPtr(player_id) orelse continue;
        living_players += 1;
        if (nz.vec.distance(
            player.transform.position,
            entity.transform.position,
        ) < shared.teleporter.charge_distance) players_in_zone += 1;
    }
    if (teleporter.state == .active and players_in_zone > 0) {
        teleporter.charged += world.delta_time * charge_per_second * players_in_zone / living_players;
        teleporter.charged = @min(teleporter.charged, teleporter.max_charge);
    }
    if (old_teleporter_charge != teleporter.charged) {
        world.client_updates.appendAssumeCapacity(
            .{ .event = .{ .teleporter_charge = @floatCast(teleporter.charged) } },
        );
    }
}
