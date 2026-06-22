const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.nz;

pub const SpawnInfo = struct {
    kind: shared.Entity.Kind,
    server_id: u32,
    data: [4]u8 = @splat(0),
};

gpa: std.mem.Allocator,
world: *system.World,
pending_spawn: std.ArrayList(SpawnInfo) = .empty,
pending_despawn: std.ArrayList(u32) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
        .pending_spawn = try .initCapacity(gpa, system.World.max_entities),
        .pending_despawn = try .initCapacity(gpa, system.World.max_entities),
    };
}
pub fn deinit(self: *@This()) void {
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
}

pub fn spawn(self: *@This(), entity_info: SpawnInfo) void {
    self.pending_spawn.appendAssumeCapacity(entity_info);
}

pub fn depspawn(self: *@This(), entity_id: u32) !void {
    // std.log.debug("despawn ID: {d}", .{entity_id});
    self.pending_despawn.appendAssumeCapacity(entity_id);
}

pub fn update(self: *@This(), info: *const system.Info, system_context: *system.Context) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = info;

    for (self.pending_spawn.items) |entity_info| {
        if (self.world.getPtr(entity_info.server_id) == null) {
            const entity = try self.world.spawn();
            const client_id = entity.id;
            entity.* = .{ .id = client_id, .kind = entity_info.kind, .flags = .{ .transform = true } };
            switch (entity_info.kind) {
                .player => |kind| {
                    try system_context.renderer.inner.attachSkeleton(self.gpa, client_id, kind);
                },
                .planet => {
                    const size: u32 = @intCast(entity_info.data[0]);
                    var planet: shared.Planet(.renderable) = try .init(self.gpa, size);
                    defer planet.deinit(self.gpa);
                    try system_context.renderer.inner.createModelWithMesh(
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
                },
                else => {
                    if (entity.isEnemy() or entity.isItem()) {
                        try system_context.renderer.inner.attachSkeleton(self.gpa, client_id, entity.kind);
                    }
                },
            }
            try self.world.enitity_mapping.put(self.gpa, entity_info.server_id, client_id);
        }
    }
    self.pending_spawn.clearRetainingCapacity();

    for (self.pending_despawn.items) |entity_id| {
        if (self.world.getPtr(entity_id)) |entity| {
            _ = entity;
            system_context.renderer.inner.removeSkeleton(self.gpa, entity_id);
            _ = self.world.despawn(entity_id);
        }
    }
    self.pending_despawn.clearRetainingCapacity();
}
