const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Camera = @import("system/Camera.zig");
const Controller = @import("system/Controller.zig");

mutex: std.Io.Mutex = .init,
gpa: std.mem.Allocator,
entities: std.AutoArrayHashMapUnmanaged(shared.entity.Id, Entity) = .empty,
teleporter_bosses: shared.CappedList(shared.entity.Id) = .empty,
pending_spawn: shared.CappedList(shared.net.SpawnEntity) = .empty,
pending_despawn: shared.CappedList(shared.entity.Id) = .empty,
pending_stats: shared.CappedList(shared.net.UpdateStat) = .empty,
attack_events: shared.CappedList(shared.entity.Id) = .empty,
particles: shared.CappedList(Particle) = .empty,
camera: Camera = .{},
controller: Controller = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
stage: u32 = 0,

pub const Entity = struct {
    id: shared.entity.Id = .none,
    kind: shared.entity.Kind,
    teleporter: shared.teleporter.State = .{},
    inventory: shared.Inventory = .{},
    stats: shared.Stats = .{},

    update_motion: ?shared.net.UpdateMotion = null,
    smoothed_moiton_tick: u32 = 0,
    position_error: nz.Vec3(f32) = @splat(0),

    transform: nz.Transform3D(f32) = .{},
};

pub const Particle = struct {
    position: nz.Vec3(f32),
    velocity: nz.Vec3(f32),
    lifetime: f32,
    max_lifetime: f32,
    scale: f32,
};

pub fn init(gpa: std.mem.Allocator) !@This() {
    return .{
        .gpa = gpa,
        .teleporter_bosses = try .initCapacity(gpa, shared.max_entities),
        .pending_spawn = try .initCapacity(gpa, shared.max_entities),
        .pending_despawn = try .initCapacity(gpa, shared.max_entities),
        .pending_stats = try .initCapacity(gpa, shared.max_entities),
        .attack_events = try .initCapacity(gpa, shared.max_entities),
        .particles = try .initCapacity(gpa, 512),
    };
}

pub fn deinit(self: *@This()) void {
    self.entities.deinit(self.gpa);
    self.teleporter_bosses.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_stats.deinit(self.gpa);
    self.attack_events.deinit(self.gpa);
    self.particles.deinit(self.gpa);
}

pub fn spawn(self: *@This(), id: shared.entity.Id) !*Entity {
    try self.entities.put(self.gpa, id, .{ .id = id, .kind = .unknown });
    return self.entities.getPtr(id).?;
}

pub fn getPtr(self: *@This(), id: shared.entity.Id) ?*Entity {
    return self.entities.getPtr(id);
}

pub fn despawn(self: *@This(), id: shared.entity.Id) bool {
    return self.entities.swapRemove(id);
}

pub fn spawnRocketExplosion(self: *@This(), position: nz.Vec3(f32)) void {
    const directions = [_]nz.Vec3(f32){
        .{ 1, 0, 0 },
        .{ -1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, -1, 0 },
        .{ 0, 0, 1 },
        .{ 0, 0, -1 },
        .{ 1, 1, 0 },
        .{ -1, 1, 0 },
        .{ 1, -1, 0 },
        .{ -1, -1, 0 },
        .{ 1, 0, 1 },
        .{ -1, 0, 1 },
        .{ 1, 0, -1 },
        .{ -1, 0, -1 },
        .{ 0, 1, 1 },
        .{ 0, -1, -1 },
    };

    for (directions, 0..) |direction, index| {
        if (self.particles.items.len >= self.particles.buffer.len and self.particles.items.len > 0) {
            _ = self.particles.swapRemove(0);
        }

        const normalized = nz.vec.normalize(direction);
        const index_f: f32 = @floatFromInt(index);
        const lifetime = 0.45 + @as(f32, @floatFromInt(index % 4)) * 0.08;
        self.particles.append(.{
            .position = position,
            .velocity = nz.vec.scale(normalized, 12 + index_f * 0.35),
            .lifetime = lifetime,
            .max_lifetime = lifetime,
            .scale = 0.35 + @as(f32, @floatFromInt(index % 3)) * 0.08,
        });
    }
}

pub fn updateParticles(self: *@This(), delta_time: f32) void {
    var index: usize = 0;
    while (index < self.particles.items.len) {
        const particle = &self.particles.items[index];
        particle.lifetime -= delta_time;
        if (particle.lifetime <= 0) {
            _ = self.particles.swapRemove(index);
            continue;
        }

        particle.position += nz.vec.scale(particle.velocity, delta_time);
        particle.velocity = nz.vec.scale(particle.velocity, std.math.pow(f32, 0.08, delta_time));
        index += 1;
    }
}
