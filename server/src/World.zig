const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const Physics = @import("system/Physics.zig");
const nz = shared.numz;

gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity),
players: shared.CappedList(shared.entity.Id),
teleport_bosses: shared.CappedList(shared.entity.Id),
new_spawns: shared.CappedList(shared.entity.Id),
pending_despawns: shared.CappedList(PendingDespawn),
outbox: shared.CappedList(PendingUpdate),
next_stage_requested: bool,
teleporter_id: shared.entity.Id,
planet_radius: u32,
next_entity_id: u32,
next_stage: u32,
prng: std.Random.DefaultPrng,

pub const PendingDespawn = struct {
    id: shared.entity.Id,
    remove: bool,
};

pub const PendingUpdate = union(enum) {
    spawned: shared.entity.Id,
    despawned: shared.entity.Id,
    stat: shared.net.UpdateStat,
    inventory: shared.net.UpdateInventory,
    event: shared.net.Event,
};

pub const Camera = struct {
    pub const Mode = enum { follow, free };

    mode: Mode = .follow,
    yaw_rotation: nz.quat.Hamiltonian(f32) = .identity,
    pitch: f32 = 0,
    boom_offset: nz.Vec3(f32) = .{ 0, 0, 0 },
    transform: nz.Transform3D(f32) = .{},
};

pub const Controller = struct {
    input: shared.net.Input = .{},
};

pub const Entity = struct {
    id: shared.entity.Id = .none,
    flags: Flags = .{},
    kind: shared.entity.Kind = .unknown,
    owner_id: shared.entity.Id = .none,

    transform: nz.Transform3D(f32) = .{},
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
    collider: Physics.Collider = .{
        .shape = .{ .primitive = .{ .box = .{ .x = 1, .y = 1, .z = 1 } } },
        .motion_type = .dynamic,
        .object_layer = .moving,
    },
    controller: Controller = .{},
    camera: Camera = .{},
    lifetime: ?f32 = null,
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},

    last_attack: f32 = 0,

    pub const Flags = packed struct {
        invinsible: bool = false,
        is_teleporter_boss: bool = false,
        is_dead: bool = false,
    };

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (shared.entity.hasCollider(self.kind)) {
            switch (self.collider.shape) {
                .mesh => |*mesh| {
                    gpa.free(mesh.indices);
                    gpa.free(mesh.vertices);
                },
                .primitive => {},
            }
        }
    }
};

pub fn init(gpa: std.mem.Allocator) !@This() {
    var entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty;
    try entities.ensureTotalCapacity(gpa, shared.max_entities);

    return .{
        .gpa = gpa,
        .entities = entities,
        .players = try .initCapacity(gpa, 16),
        .teleport_bosses = try .initCapacity(gpa, shared.max_entities),
        .new_spawns = try .initCapacity(gpa, shared.max_entities),
        .pending_despawns = try .initCapacity(gpa, shared.max_entities),
        .outbox = try .initCapacity(gpa, 8192),
        .next_stage_requested = false,
        .teleporter_id = .none,
        .planet_radius = 100,
        .next_entity_id = 1,
        .next_stage = 0,
        .prng = .init(0xACE1),
    };
}

pub fn deinit(self: *@This()) void {
    for (self.entities.values()) |*entity| {
        entity.deinit(self.gpa);
    }
    self.entities.deinit(self.gpa);
    self.players.deinit(self.gpa);
    self.teleport_bosses.deinit(self.gpa);
    self.new_spawns.deinit(self.gpa);
    self.pending_despawns.deinit(self.gpa);
    self.outbox.deinit(self.gpa);
}

pub const SpawnError = error{ SpawnMaxSize, MaxEnemies, MaxPlayers };

pub fn spawn(self: *@This(), entity_info: Entity) SpawnError!*Entity {
    if (self.entities.entries.len >= shared.max_entities) {
        if (builtin.mode == .Debug) @panic("spawn: world full");
        return error.SpawnMaxSize;
    }
    if (entity_info.kind == .enemy and !entity_info.flags.is_teleporter_boss and self.enemyCount() >= shared.max_enemies) {
        return error.MaxEnemies;
    }
    if (builtin.mode != .Debug and entity_info.kind == .player and self.players.items.len >= shared.max_players) {
        return error.MaxPlayers;
    }
    const id: shared.entity.Id = @enumFromInt(self.next_entity_id);
    self.next_entity_id += 1;
    self.entities.putAssumeCapacity(id, entity_info);
    const entity = self.entities.getPtr(id).?;
    entity.id = id;
    if (entity.flags.is_teleporter_boss) self.teleport_bosses.append(id);
    switch (entity.kind) {
        .enemy => |enemy_kind| switch (enemy_kind) {
            .tubloid => entity.stats.init(20, 3, 1, 1, 2),
            .tubloida => entity.stats.init(20, 3, 1, 0.2, 10),
            .wizard => entity.stats.init(100 * @as(f32, @floatFromInt(self.next_stage)), 10, 1, 0.25, 40),
        },
        .player => entity.stats.init(100, 10, 10, 10, 10),
        else => {},
    }
    self.new_spawns.append(id);
    return entity;
}

pub fn enemyCount(self: *const @This()) usize {
    var count: usize = 0;
    for (self.entities.values()) |*entity| {
        if (entity.kind == .enemy) count += 1;
    }
    return count;
}

pub fn getPtr(self: *@This(), id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn queueDespawn(self: *@This(), id: shared.entity.Id) void {
    self.pending_despawns.append(.{ .id = id, .remove = false });
}

pub fn queueRemove(self: *@This(), id: shared.entity.Id) void {
    self.pending_despawns.append(.{ .id = id, .remove = true });
}

pub fn removeHealth(self: *@This(), entity: *Entity, amount: f32) bool {
    if (!entity.kind.hasHealth()) return false;
    if (entity.flags.invinsible) return false;
    return self.addHealth(entity, -amount);
}

pub fn addHealth(self: *@This(), entity: *Entity, amount: f32) bool {
    if (!entity.kind.hasHealth()) return false;
    const current = entity.stats.addCurrent(.health, amount);
    if (current <= 0) self.queueDespawn(entity.id);
    self.outbox.append(.{ .stat = .{ .id = entity.id, .stat_kind = .health, .amount = .{ .set_current = @floatCast(current) } } });
    return true;
}

pub fn flush(self: *@This(), physics: *Physics) !void {
    for (self.new_spawns.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (shared.entity.hasCollider(entity.kind)) {
            if (shared.entity.colliderShape(entity.kind)) |primitive_shape| {
                entity.collider = .{
                    .shape = .{ .primitive = primitive_shape },
                    .motion_type = motionType(entity.kind),
                    .object_layer = objectLayer(entity.kind),
                };
            }
            try physics.createBody(entity);
        }
        self.outbox.append(.{ .spawned = id });
    }
    self.new_spawns.clearRetainingCapacity();

    for (self.pending_despawns.items) |despawn| {
        const entity = self.getPtr(despawn.id) orelse continue;
        if (std.mem.indexOfScalar(shared.entity.Id, self.players.items, despawn.id)) |player_index| {
            _ = self.players.swapRemove(player_index);
        }
        if (entity.collider.body_id) |body_id| {
            physics.destroyBody(body_id);
            entity.collider.body_id = null;
        }
        if (entity.kind == .player and !despawn.remove) {
            entity.flags.is_dead = true;
            entity.velocity = .{ 0, 0, 0 };
        } else {
            if (std.mem.indexOfScalar(shared.entity.Id, self.teleport_bosses.items, despawn.id)) |boss_index| {
                _ = self.teleport_bosses.swapRemove(boss_index);
            }
            entity.deinit(self.gpa);
            _ = self.entities.swapRemove(despawn.id);
        }
        self.outbox.append(.{ .despawned = despawn.id });
    }
    self.pending_despawns.clearRetainingCapacity();
}

fn motionType(kind: shared.entity.Kind) Physics.MotionType {
    return switch (kind) {
        .teleporter, .planet => .static,
        else => .dynamic,
    };
}

fn objectLayer(kind: shared.entity.Kind) Physics.ObjectLayer {
    return switch (kind) {
        .teleporter, .planet => .non_moving,
        .item => .planet_only,
        else => .moving,
    };
}
