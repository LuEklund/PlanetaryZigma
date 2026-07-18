const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;

const Particle = @This();

pub const Kind = enum { explosion, lightning };

kind: Kind,
position: nz.Vec3(f32),
velocity: nz.Vec3(f32),
lifetime: f32,
max_lifetime: f32,
scale: f32,

fn append(list: *std.ArrayList(Particle), particle: Particle) void {
    if (list.items.len >= list.capacity and list.items.len > 0) {
        _ = list.swapRemove(0);
    }
    list.appendAssumeCapacity(particle);
}

fn surfaceUp(position: nz.Vec3(f32)) nz.Vec3(f32) {
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

pub fn spawnRocketExplosion(list: *std.ArrayList(Particle), random: std.Random, position: nz.Vec3(f32)) void {
    const surface_up = surfaceUp(position);
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
        append(list, .{
            .kind = .explosion,
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
            append(list, .{
                .kind = .explosion,
                .position = spawn_position + nz.vec.scale(direction, burst_f * 0.35 + spark_f * 0.01),
                .velocity = nz.vec.scale(direction, speed),
                .lifetime = lifetime,
                .max_lifetime = lifetime,
                .scale = scale,
            });
        }
    }
}

pub fn spawnLightningArc(list: *std.ArrayList(Particle), random: std.Random, from: nz.Vec3(f32), to: nz.Vec3(f32)) void {
    const segment = to - from;
    const length = nz.vec.length(segment);
    if (length < 0.001) return;
    const direction = nz.vec.scale(segment, 1.0 / length);
    const lifetime = 0.22 + random.float(f32) * 0.08;

    const node_count: usize = @intFromFloat(@max(2, @ceil(length / 1.5)));
    var previous_node = from;
    for (1..node_count + 1) |node_index| {
        const t = @as(f32, @floatFromInt(node_index)) / @as(f32, @floatFromInt(node_count));
        var node = from + nz.vec.scale(segment, t);
        if (node_index < node_count) {
            const raw = nz.vec.randomUnitVector(nz.Vec3(f32), random);
            const perpendicular = raw - nz.vec.scale(direction, nz.vec.dot(raw, direction));
            node += nz.vec.scale(perpendicular, 0.6);
        }

        const piece = node - previous_node;
        const piece_length = nz.vec.length(piece);
        const step_count: usize = @intFromFloat(@max(1, @ceil(piece_length / 0.12)));
        for (0..step_count) |step_index| {
            const step_t = @as(f32, @floatFromInt(step_index)) / @as(f32, @floatFromInt(step_count));
            append(list, .{
                .kind = .lightning,
                .position = previous_node + nz.vec.scale(piece, step_t),
                .velocity = .{ 0, 0, 0 },
                .lifetime = lifetime,
                .max_lifetime = lifetime,
                .scale = 0.55 + random.float(f32) * 0.15,
            });
        }
        previous_node = node;
    }
}

pub fn update(list: *std.ArrayList(Particle), delta_time: f32) void {
    var index: usize = 0;
    while (index < list.items.len) {
        const particle = &list.items[index];
        particle.lifetime -= delta_time;
        if (particle.lifetime <= 0) {
            _ = list.swapRemove(index);
            continue;
        }

        particle.position += nz.vec.scale(particle.velocity, delta_time);
        particle.velocity = nz.vec.scale(particle.velocity, std.math.pow(f32, 0.08, delta_time));
        index += 1;
    }
}
