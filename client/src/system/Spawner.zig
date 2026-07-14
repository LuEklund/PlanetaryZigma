const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.nz;

pub fn applyStat(entity: *system.Entity, command: shared.net.UpdateStat) void {
    switch (command.amount) {
        .set_current => |v| entity.stats.setCurrent(command.stat_kind, v),
        .set_max => |v| entity.stats.setMax(command.stat_kind, v),
    }
}

pub fn update(info: *const system.Info, system_context: *system.Context) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const world = info.world;
    const gpa = system_context.gpa;

    for (world.pending_spawn.items) |entity_info| {
        if (world.getPtr(entity_info.id) != null) continue;
        const entity = try world.spawn(entity_info.id);
        entity.* = .{
            .id = entity_info.id,
            .kind = entity_info.kind,
            .transform = .{
                .position = entity_info.position,
                .rotation = .fromVec(entity_info.rotation),
            },
            .update_motion = .{
                .id = entity_info.id,
                .position = entity_info.position,
                .velocity = entity_info.velocity,
                .rotation = entity_info.rotation,
                .tick = entity_info.tick,
            },
        };
        switch (entity_info.kind) {
            .player => {
                try system_context.renderer.inner.attachSkeleton(gpa, entity.id, entity_info.kind);
                if (entity_info.id == world.player_id) {
                    world.camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } };
                    world.controller.free_camera = false;
                }
            },
            .planet => {
                const radius: u32 = entity_info.data.planet_radius;
                world.planet_radius = @floatFromInt(radius);
                var planet: shared.Planet(.renderable) = try .init(gpa, radius);
                defer planet.deinit(gpa);
                try system_context.renderer.inner.resources.createStaticMesh(
                    gpa,
                    "planet",
                    planet.vertices,
                    planet.indices,
                    .planet,
                );
                std.log.debug("SPAWNED: Planet {d}", .{radius});
            },
            .bullet => {
                entity.transform.scale = @splat(0.3);
            },
            .teleporter => {
                world.teleporter_id = entity.id;
            },
            .enemy => {
                if (entity_info.data == .is_teleporter_boss) {
                    entity.transform.scale = @splat(5);
                    world.teleporter_bosses.append(entity.id);
                }
                try system_context.renderer.inner.attachSkeleton(gpa, entity.id, entity_info.kind);
            },
            .unknown, .item => {},
        }
    }
    world.pending_spawn.clearRetainingCapacity();

    for (world.pending_stats.items) |command| {
        if (world.getPtr(command.id)) |entity| applyStat(entity, command);
    }
    world.pending_stats.clearRetainingCapacity();

    for (world.pending_inventory.items) |command| {
        if (world.getPtr(command.id)) |entity| entity.inventory.set(command.item_kind, command.set);
    }
    world.pending_inventory.clearRetainingCapacity();

    for (world.pending_despawn.items) |id| {
        if (world.getPtr(id) == null) continue;
        system_context.renderer.inner.removeSkeleton(gpa, id);
        if (std.mem.indexOfScalar(shared.entity.Id, world.teleporter_bosses.items, id)) |index_of_boss| {
            _ = world.teleporter_bosses.swapRemove(index_of_boss);
        }
        if (id == world.player_id) world.controller.free_camera = true;
        _ = world.despawn(id);
    }
    world.pending_despawn.clearRetainingCapacity();
}
