const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const Physics = @import("Physics.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

credits: f32 = 0,
salary_per_second: f32 = 1,
last_salary: f32 = 0,
enemy_cost: f32 = 10,
should_spawm: bool = false,

pub fn update(self: *@This(), info: *const system.Info, physics: *Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (info.world.next_stage_requested) {
        info.world.next_stage_requested = false;
        try self.startStage(info.world, physics);
    }

    self.should_spawm = false;

    if (self.should_spawm and info.world.players.items.len != 0) {
        if (info.elapsed_time - self.last_salary >= 1.0) {
            self.last_salary = info.elapsed_time;
            self.credits += self.salary_per_second * 10;
        }
        const rand = info.world.prng.random();
        const x = rand.float(f32) * 2 - 1;
        const y = rand.float(f32) * 2 - 1;
        const z = rand.float(f32) * 2 - 1;
        const vector_direction: nz.Vec3(f32) = .{ x, y, z };
        if (self.credits >= self.enemy_cost) {
            self.credits -= self.enemy_cost;
            _ = info.world.spawn(.{
                .kind = .{ .enemy = .tubloid },
                .transform = .{ .position = vector_direction },
                .last_attack = info.elapsed_time,
            });
        }
    }
}

pub fn startStage(self: *@This(), world: *system.World, physics: *Physics) !void {
    for (world.entities.values()) |entry| {
        if (entry.kind != .player) world.queueDespawn(entry.id);
    }
    const random = world.prng.random();
    world.teleporter_id = 0;
    self.should_spawm = true;
    world.outbox.appendAssumeCapacity(.{ .event = .new_stage });
    world.planet_radius = @intFromFloat(random.float(f32) * 99 + 1);
    std.log.debug("startStage planet_radius={d}", .{world.planet_radius});
    const planet: shared.Planet(.logical) = try .init(world.gpa, world.planet_radius);
    _ = world.spawn(.{
        .kind = .planet,
        .transform = .{},
        .collider = .{
            .shape = .{
                .mesh = .{
                    .indices = planet.indices,
                    .vertices = planet.vertices,
                },
            },
            .motion_type = .static,
            .object_layer = .non_moving,
        },
    });
    // the teleporter placement raycast below needs the planet body to exist
    try world.flush(physics);

    for (0..20) |i| {
        const item_kind: shared.Item.Kind = switch (i) {
            0...5 => .attack_speed,
            6...10 => .speed,
            11...15 => .damage,
            else => .health,
        };
        const vector_direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
        _ = world.spawn(.{
            .kind = .{ .item = item_kind },
            .transform = .{ .position = nz.vec.scale(vector_direction, @as(f32, @floatFromInt(world.planet_radius)) + 10) },
        });
    }

    var teleport_position: ?nz.Vec3(f32) = null;
    while (teleport_position == null) {
        teleport_position = physics.getSurfacePoint(world, .{ 0, 100, 0 });
    } else {
        const teleporter = world.spawn(.{
            .kind = .teleporter,
            .transform = .{ .position = teleport_position.? },
        });
        const teleport_planet_up = nz.vec.normalize(teleport_position.?);
        const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
        const dot = std.math.clamp(nz.vec.dot(default_up, teleport_planet_up), -1.0, 1.0);
        teleporter.transform.rotation = if (dot < 0.9999) blk: {
            const axis = if (dot > -0.9999)
                nz.vec.normalize(nz.vec.cross(default_up, teleport_planet_up))
            else
                nz.Vec3(f32){ 1, 0, 0 };
            break :blk nz.quat.Hamiltonian(f32).angleAxis(std.math.acos(dot), axis);
        } else .identity;
        world.teleporter_id = teleporter.id;
    }
}
