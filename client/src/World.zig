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
pending_inventory: shared.CappedList(shared.net.UpdateInventory) = .empty,
attack_events: shared.CappedList(shared.entity.Id) = .empty,
particles: shared.CappedList(Particle) = .empty,
camera: Camera = .{},
controller: Controller = .{},
teleporter_id: shared.entity.Id = .none,
player_id: shared.entity.Id = .none,
planet_radius: f32 = 0,
stage: u32 = 0,
prng: std.Random.DefaultPrng,

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
        .pending_inventory = try .initCapacity(gpa, shared.max_entities),
        .attack_events = try .initCapacity(gpa, shared.max_entities),
        .particles = try .initCapacity(gpa, 512),
        .prng = .init(0x5EED_BA11),
    };
}

pub fn deinit(self: *@This()) void {
    self.entities.deinit(self.gpa);
    self.teleporter_bosses.deinit(self.gpa);
    self.pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
    self.pending_stats.deinit(self.gpa);
    self.pending_inventory.deinit(self.gpa);
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

fn appendParticle(self: *@This(), particle: Particle) void {
    if (self.particles.items.len >= self.particles.buffer.len and self.particles.items.len > 0) {
        _ = self.particles.swapRemove(0);
    }
    self.particles.append(particle);
}

fn particleSurfaceUp(position: nz.Vec3(f32)) nz.Vec3(f32) {
    const distance = nz.vec.length(position);
    return if (distance > 0.001) nz.vec.scale(position, 1.0 / distance) else .{ 0, 1, 0 };
}

fn surfaceBiasedDirection(random: std.Random, surface_up: nz.Vec3(f32)) nz.Vec3(f32) {
    var direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
    const outward = nz.vec.dot(direction, surface_up);
    if (outward < 0.2) {
        direction = nz.vec.normalize(direction + nz.vec.scale(surface_up, 0.35 - outward));
    }
    return direction;
}

pub fn spawnRocketExplosion(self: *@This(), position: nz.Vec3(f32)) void {
    const random = self.prng.random();
    const surface_up = particleSurfaceUp(position);
    const spawn_position = position + nz.vec.scale(surface_up, 1.15);
    const center_particles = [_]struct {
        offset: nz.Vec3(f32),
        velocity: nz.Vec3(f32),
        scale: f32,
        lifetime: f32,
    }{
        .{ .offset = .{ 0, 0, 0 }, .velocity = .{ 0, 0, 0 }, .scale = 2.2, .lifetime = 0.34 },
        .{ .offset = .{ -0.15, 0.2, 0.2 }, .velocity = .{ -0.5, 0.7, 0.6 }, .scale = 1.95, .lifetime = 0.38 },
        .{ .offset = .{ 0.2, -0.15, -0.25 }, .velocity = .{ 0.7, -0.4, -0.8 }, .scale = 1.75, .lifetime = 0.4 },
        .{ .offset = .{ 0.45, 0.1, 0 }, .velocity = .{ 1.8, 0.4, 0 }, .scale = 1.55, .lifetime = 0.42 },
        .{ .offset = .{ -0.35, -0.2, 0.1 }, .velocity = .{ -1.2, -0.7, 0.4 }, .scale = 1.35, .lifetime = 0.46 },
        .{ .offset = .{ 0.05, 0.35, -0.15 }, .velocity = .{ 0.2, 1.1, -0.5 }, .scale = 1.2, .lifetime = 0.5 },
        .{ .offset = .{ 0.3, -0.4, 0.2 }, .velocity = .{ 0.9, -1.1, 0.5 }, .scale = 1.1, .lifetime = 0.44 },
        .{ .offset = .{ -0.45, 0.25, -0.1 }, .velocity = .{ -1.0, 0.8, -0.3 }, .scale = 1.0, .lifetime = 0.48 },
    };

    for (center_particles) |particle| {
        const tangent_offset = particle.offset - nz.vec.scale(surface_up, nz.vec.dot(particle.offset, surface_up));
        self.appendParticle(.{
            .position = spawn_position + tangent_offset,
            .velocity = particle.velocity + nz.vec.scale(surface_up, 1.4),
            .lifetime = particle.lifetime,
            .max_lifetime = particle.lifetime,
            .scale = particle.scale,
        });
    }

    for (0..2) |burst_index| {
        const burst_f: f32 = @floatFromInt(burst_index);
        for (0..16) |spark_index| {
            const direction = surfaceBiasedDirection(random, surface_up);
            const spark_f: f32 = @floatFromInt(spark_index);
            const lifetime = 0.42 + random.float(f32) * 0.28 + burst_f * 0.06;
            const speed = 12.0 + random.float(f32) * 7.0 + burst_f * 4.0;
            const scale = (0.3 + random.float(f32) * 0.22) * (1.0 - burst_f * 0.15);
            self.appendParticle(.{
                .position = spawn_position + nz.vec.scale(direction, burst_f * 0.35 + spark_f * 0.01),
                .velocity = nz.vec.scale(direction, speed),
                .lifetime = lifetime,
                .max_lifetime = lifetime,
                .scale = scale,
            });
        }
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
