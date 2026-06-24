const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.nz;

gpa: std.mem.Allocator,
world: *system.World,
pending_spawn: std.ArrayList(shared.net.SpawnEntity) = .empty,
pending_despawn: std.ArrayList(u32) = .empty,
pending_stats: std.ArrayList(shared.net.UpdateStat) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
        .pending_spawn = try .initCapacity(gpa, system.World.max_entities),
        .pending_despawn = try .initCapacity(gpa, system.World.max_entities),
        .pending_stats = try .initCapacity(gpa, system.World.max_entities),
    };
}
pub fn deinit(self: *@This()) void {
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_stats.deinit(self.gpa);
}

pub fn spawn(self: *@This(), entity_info: shared.net.SpawnEntity) void {
    self.pending_spawn.appendAssumeCapacity(entity_info);
}

pub fn applyStat(entity: *system.Entity, command: shared.net.UpdateStat) void {
    switch (command.amount) {
        .set_health => |v| entity.health.current = v,
        .set_max_health => |v| entity.health.max = v,
        .add_health => |v| entity.health.current += v,
    }
}

pub fn depspawn(self: *@This(), entity_id: u32) !void {
    // std.log.debug("despawn ID: {d}", .{entity_id});
    self.pending_despawn.appendAssumeCapacity(entity_id);
}

pub fn update(self: *@This(), info: *const system.Info, system_context: *system.Context) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    for (self.pending_spawn.items) |entity_info| {
        if (self.world.getPtr(entity_info.id) != null) continue;
        const entity = try self.world.spawn(entity_info.id);
        entity.* = .{ .id = entity_info.id, .kind = entity_info.kind, .flags = .{ .transform = true } };
        switch (entity_info.kind) {
            .player => {
                try system_context.renderer.inner.attachSkeleton(self.gpa, entity.id, entity_info.kind);
            },
            .planet => {
                const size: u32 = entity_info.data.planet_size;
                var planet: shared.Planet(.renderable) = try .init(self.gpa, size);
                defer planet.deinit(self.gpa);
                try system_context.renderer.inner.createStaticMesh(
                    self.gpa,
                    "planet",
                    planet.vertices,
                    planet.indices,
                    .planet,
                );
                std.log.debug("SPAWNED: Planet {d}", .{size});
            },
            .bullet => {
                entity.transform.scale = @splat(0.3);
                entity.transform.position = entity_info.position;
                entity.velocity = entity_info.data.bullet_velocity;
                entity.flags.bullet = true;
            },
            .teleporter => {
                info.world.teleportal_id = entity.id;
            },
            .skelly, .wizard => {
                if (entity_info.data == .is_teleporter_boss) {
                    entity.transform.scale = @splat(5);
                    info.world.teleporter_bosses.appendAssumeCapacity(entity.id);
                }
                try system_context.renderer.inner.attachSkeleton(self.gpa, entity.id, entity_info.kind);
            },
            .unknown, .health_item, .speed_item, .damage_item, .attack_speed_item => {},
        }
    }
    self.pending_spawn.clearRetainingCapacity();

    for (self.pending_stats.items) |command| {
        if (self.world.getPtr(command.id)) |entity| applyStat(entity, command);
    }
    self.pending_stats.clearRetainingCapacity();

    for (self.pending_despawn.items) |id| {
        if (self.world.getPtr(id) == null) continue;
        system_context.renderer.inner.removeSkeleton(self.gpa, id);
        if (std.mem.indexOfScalar(u32, info.world.teleporter_bosses.items, id)) |index_of_boss| {
            _ = info.world.teleporter_bosses.swapRemove(index_of_boss);
        }
        _ = self.world.despawn(id);
    }
    self.pending_despawn.clearRetainingCapacity();
    for (info.world.entities.values()) |*entity| {
        if (entity.isEnemy()) {
            // std.log.debug("is enemy", .{});
        }
    }
}
