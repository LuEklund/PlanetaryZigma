const Director = @This();

const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const Physics = @import("Physics.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

credits: f32 = 0,
salary_per_second: f32 = 2,
last_salary: f32 = 0,
enemy_cost: f32 = 10,
spawning: bool = false,

const StageItemSpawn = struct {
    kind: shared.Item.Kind,
    count: u32,
};

const stage_item_spawns = [_]StageItemSpawn{
    .{ .kind = .attack_speed, .count = 5 },
    .{ .kind = .speed, .count = 5 },
    .{ .kind = .damage, .count = 5 },
    .{ .kind = .rocket, .count = 5 },
    .{ .kind = .health, .count = 5 },
};

const item_surface_offset: f32 = 1.2;

pub fn update(self: *Director, info: *const system.Info, physics: *Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (info.world.next_stage_requested) {
        info.world.next_stage_requested = false;
        try self.startStage(info.world, physics);
    }

    if (self.spawning and info.world.players.items.len != 0) {
        if (info.elapsed_time - self.last_salary >= 1.0) {
            self.last_salary = info.elapsed_time;
            self.credits += self.salary_per_second;
        }
        const rand = info.world.prng.random();
        if (self.credits >= self.enemy_cost) {
            const player_index = rand.uintLessThan(usize, info.world.players.items.len);
            if (info.world.getPtr(info.world.players.items[player_index])) |player| {
                const radius_float: f32 = @floatFromInt(info.world.planet_radius);
                const max_distance = radius_float * (std.math.pi / 2.0);
                const min_distance = @min(15.0, max_distance * 0.5);
                const surface = shared.planetSurfacePointNear(player.transform.position, radius_float, min_distance, max_distance, rand);
                const spawn_position = surface + nz.vec.scale(nz.vec.normalize(surface), 2);
                if (info.world.spawn(.{
                    .kind = .{ .enemy = .tubloida },
                    .transform = .{ .position = spawn_position },
                    .last_attack = info.elapsed_time,
                })) |_| {
                    self.credits -= self.enemy_cost;
                } else |_| {}
            }
        }
    }
}

pub fn startStage(self: *Director, world: *system.World, physics: *Physics) !void {
    world.next_stage += 1;
    for (world.entities.values()) |entry| {
        if (entry.kind != .player) world.queueDespawn(entry.id);
    }
    const random = world.prng.random();
    world.teleporter_id = .none;
    self.spawning = true;
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .new_stage = world.next_stage } });
    world.planet_radius = random.intRangeAtMost(u32, shared.planet_min_radius, 100);
    std.log.debug("startStage planet_radius={d}", .{world.planet_radius});
    const planet: shared.Planet(.logical) = try .init(world.gpa, world.planet_radius);
    _ = try world.spawn(.{
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
    try world.flush(physics);

    const player_spawn_surface = shared.planetSurfacePoint(.{ 0, 1, 0 }, @floatFromInt(world.planet_radius));
    const player_spawn_position = player_spawn_surface + nz.Vec3(f32){ 0, 2, 0 };
    for (world.entities.values()) |*player| {
        if (player.kind != .player) continue;
        player.transform.position = player_spawn_position;
        player.velocity = .{ 0, 0, 0 };
        if (player.flags.is_dead) {
            player.flags.is_dead = false;
            player.stats.setCurrent(.health, player.stats.get(.health).max);
            try physics.createBody(player);
            world.players.appendAssumeCapacity(player.id);
            world.client_updates.appendAssumeCapacity(.{ .spawned = player.id });
        } else if (player.collider.body_id) |body_id| {
            Physics.setPosition(body_id, player_spawn_position);
            Physics.setLinearVelocity(body_id, .{ 0, 0, 0 });
        }
    }

    //NOTE: TEST ITEMS
    for (stage_item_spawns) |spawn_spec| {
        const random_spawn_count = if (spawn_spec.count > 0) spawn_spec.count - 1 else 0;
        for (0..random_spawn_count) |_| {
            // const vector_direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
            try spawnItem(world, spawn_spec.kind, .{ 0, 1, 0 });
        }
    }
    for (0..25) |_| {
        const vector_direction = nz.vec.randomUnitVector(nz.Vec3(f32), random);
        const transform = surfaceTransform(world, vector_direction);
        _ = try world.spawn(.{
            .kind = .lootbox,
            .transform = transform,
        });
    }

    const teleporter_position = shared.planetSurfacePoint(.{ 0, 1, 0 }, @floatFromInt(world.planet_radius));
    const teleporter = try world.spawn(.{
        .kind = .teleporter,
        .transform = .{ .position = teleporter_position },
    });
    const teleport_planet_up = nz.vec.normalize(teleporter_position);
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

fn spawnItem(world: *system.World, kind: shared.Item.Kind, vector_direction: nz.Vec3(f32)) !void {
    const transform = surfaceTransform(world, vector_direction);
    const item = try world.spawn(.{
        .kind = .{ .item = kind },
        .transform = transform,
    });
    std.log.debug("spawn item {t} id={d}", .{ kind, item.id });
}

fn surfaceTransform(world: *system.World, vector_direction: nz.Vec3(f32)) nz.Transform3D(f32) {
    const random = world.prng.random();
    const surface = shared.planetSurfacePointNear(vector_direction, @floatFromInt(world.planet_radius), 5, 20, random);
    const planet_up = nz.vec.normalize(surface);
    return .{
        .position = surface + nz.vec.scale(planet_up, item_surface_offset),
        .rotation = alignUpToPlanet(planet_up),
    };
}

fn alignUpToPlanet(planet_up: nz.Vec3(f32)) nz.quat.Hamiltonian(f32) {
    const default_up: nz.Vec3(f32) = .{ 0, 1, 0 };
    const dot = std.math.clamp(nz.vec.dot(default_up, planet_up), -1.0, 1.0);
    if (dot >= 0.9999) return .identity;
    const axis = if (dot > -0.9999)
        nz.vec.normalize(nz.vec.cross(default_up, planet_up))
    else
        nz.Vec3(f32){ 1, 0, 0 };
    return nz.quat.Hamiltonian(f32).angleAxis(std.math.acos(dot), axis);
}
