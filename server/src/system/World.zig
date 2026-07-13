const std = @import("std");
const shared = @import("shared");
const Physics = @import("Physics.zig");
const nz = shared.numz;

pub const max_entities: usize = 1024;

gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(u32, Entity),
players: std.ArrayList(u32),
teleport_bosses: std.ArrayList(u32),
fresh: std.ArrayList(u32),
despawn_queue: std.ArrayList(u32),
outbox: std.ArrayList(Fact),
next_stage_requested: bool,
teleporter_id: u32,
planet_radius: u32,
next_id: u32,
prng: std.Random.DefaultPrng,

pub const Fact = union(enum) {
    spawned: u32,
    despawned: u32,
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

pub const BulletData = struct {
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
    lifetime: f32 = 5,
};

pub const Entity = struct {
    id: u32 = 0,
    flags: Flags = .{},
    kind: shared.Entity.Kind = .unknown,
    owner_id: u32 = 0,

    transform: nz.Transform3D(f32) = .{},
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
    collider: Physics.Collider = .{
        .shape = .{ .primitive = .{ .box = .{ .x = 1, .y = 1, .z = 1 } } },
        .motion_type = .dynamic,
        .object_layer = .moving,
    },
    controller: Controller = .{},
    camera: Camera = .{},
    bullet: BulletData = .{},
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},

    last_attack: f32 = 0,

    pub const Flags = packed struct {
        invinsible: bool = false,
        is_teleporter_boss: bool = false,
    };

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        if (shared.Entity.hasCollider(self.kind)) {
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
    var entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty;
    try entities.ensureTotalCapacity(gpa, max_entities);

    return .{
        .gpa = gpa,
        .entities = entities,
        .players = try .initCapacity(gpa, 16),
        .teleport_bosses = try .initCapacity(gpa, max_entities),
        .fresh = try .initCapacity(gpa, max_entities),
        .despawn_queue = try .initCapacity(gpa, max_entities),
        .outbox = try .initCapacity(gpa, 8192),
        .next_stage_requested = false,
        .teleporter_id = 0,
        .planet_radius = 100,
        .next_id = 1,
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
    self.fresh.deinit(self.gpa);
    self.despawn_queue.deinit(self.gpa);
    self.outbox.deinit(self.gpa);
}

pub fn spawn(self: *@This(), entity_info: Entity) *Entity {
    std.debug.assert(self.entities.entries.len < max_entities);
    const id = self.next_id;
    self.next_id += 1;
    self.entities.putAssumeCapacity(id, entity_info);
    const entity = self.entities.getPtr(id).?;
    entity.id = id;
    if (entity.flags.is_teleporter_boss) self.teleport_bosses.appendAssumeCapacity(id);
    switch (entity.kind) {
        .enemy => |enemy_kind| switch (enemy_kind) {
            .tubloid => entity.stats.init(20, 3, 1, 1, 2),
            .tubloida => entity.stats.init(20, 3, 1, 0.2, 10),
            .wizard => entity.stats.init(100, 10, 1, 0.25, 40),
        },
        .player => entity.stats.init(100, 10, 10, 10, 10),
        else => {},
    }
    self.fresh.appendAssumeCapacity(id);
    return entity;
}

pub fn getPtr(self: *@This(), id: u32) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn queueDespawn(self: *@This(), id: u32) void {
    self.despawn_queue.appendAssumeCapacity(id);
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
    self.outbox.appendAssumeCapacity(.{ .stat = .{ .id = entity.id, .stat_kind = .health, .amount = .{ .set_current = @floatCast(current) } } });
    return true;
}

pub fn flush(self: *@This(), physics: *Physics) !void {
    for (self.fresh.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (shared.Entity.hasCollider(entity.kind)) {
            if (shared.Entity.colliderShape(entity.kind)) |primitive_shape| {
                entity.collider = .{
                    .shape = .{ .primitive = primitive_shape },
                    .motion_type = motionType(entity.kind),
                    .object_layer = objectLayer(entity.kind),
                };
            }
            try physics.createBody(entity);
        }
        self.outbox.appendAssumeCapacity(.{ .spawned = id });
    }
    self.fresh.clearRetainingCapacity();

    for (self.despawn_queue.items) |id| {
        const entity = self.getPtr(id) orelse continue;
        if (shared.Entity.hasCollider(entity.kind)) {
            if (entity.collider.body_id) |body_id| physics.destroyBody(body_id);
        }
        if (std.mem.indexOfScalar(u32, self.teleport_bosses.items, id)) |boss_index| {
            _ = self.teleport_bosses.swapRemove(boss_index);
        }
        entity.deinit(self.gpa);
        if (std.mem.indexOfScalar(u32, self.players.items, id)) |player_index| {
            _ = self.players.swapRemove(player_index);
        }
        _ = self.entities.swapRemove(id);
        self.outbox.appendAssumeCapacity(.{ .despawned = id });
    }
    self.despawn_queue.clearRetainingCapacity();
}

fn motionType(kind: shared.Entity.Kind) Physics.MotionType {
    return switch (kind) {
        .teleporter, .planet => .static,
        else => .dynamic,
    };
}

fn objectLayer(kind: shared.Entity.Kind) Physics.ObjectLayer {
    return switch (kind) {
        .teleporter, .planet => .non_moving,
        .item => .planet_only,
        else => .moving,
    };
}
