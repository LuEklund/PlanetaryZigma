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
    kind: shared.Item,
    count: u32,
};

const dev_lootbox_min_distance: f32 = 5;
const dev_lootbox_max_distance: f32 = 10;

const spawn_chunk_reach: i32 = 1;

pub const enemy_max_spawn_distance: f32 = 50;
const enemy_min_spawn_distance: f32 = enemy_max_spawn_distance * 0.8;

pub fn update(self: *Director, info: *const system.Info, physics: *Physics) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (info.world.next_stage_requested) {
        info.world.next_stage_requested = false;
        try self.startStage(info.world, physics);
    }

    if (info.world.players.items.len != 0)
        try info.world.planet.stream(info.world.gpa, physics, info.world.entities.values());

    if (info.world.toggle_spawning_requested) {
        info.world.toggle_spawning_requested = false;
        self.spawning = !self.spawning;
        std.log.debug("dev: enemy spawning {s}", .{if (self.spawning) "on" else "off"});
    }

    if (self.spawning and info.world.players.items.len != 0) {
        if (info.elapsed_time - self.last_salary >= 1.0) {
            self.last_salary = info.elapsed_time;
            self.credits += self.salary_per_second * 15;
        }
        const rand = info.world.prng.random();
        if (self.credits >= self.enemy_cost) {
            const player_index = rand.uintLessThan(usize, info.world.players.items.len);
            if (info.world.getPtr(info.world.players.items[player_index])) |player| {
                const radius_float = info.world.planet.radius;
                const surface = shared.planet.surfacePointNear(player.transform.position, radius_float, enemy_min_spawn_distance, enemy_max_spawn_distance, rand);
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
    try world.flush(physics);
    world.planet.clear(world.gpa, physics);
    const random = world.prng.random();
    world.teleporter_id = .none;
    self.spawning = true;
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .new_stage = world.next_stage } });
    world.planet.radius = @floatFromInt(if (world.dev_mode)
        random.intRangeAtMost(u32, shared.planet.dev_radius_min, shared.planet.dev_radius_max)
    else
        random.intRangeAtMost(u32, 60, 80));
    std.log.debug("startStage planet_radius={d}", .{world.planet.radius});
    const player_spawn_surface = shared.planet.surfacePoint(.{ 0, 1, 0 }, world.planet.radius);
    const spawn_center = shared.planet.Chunk.fromPosition(player_spawn_surface);
    var x: i32 = -spawn_chunk_reach;
    while (x <= spawn_chunk_reach) : (x += 1) {
        var y: i32 = -spawn_chunk_reach;
        while (y <= spawn_chunk_reach) : (y += 1) {
            var z: i32 = -spawn_chunk_reach;
            while (z <= spawn_chunk_reach) : (z += 1) {
                try world.planet.ensureChunk(world.gpa, physics, spawn_center + nz.Vec3(i32){ x, y, z });
            }
        }
    }
    _ = try world.spawn(.{
        .kind = .planet,
        .transform = .{},
    });
    try world.flush(physics);

    const player_spawn_position = player_spawn_surface + nz.Vec3(f32){ 0, 2, 0 };
    for (world.entities.values()) |*player| {
        if (player.kind != .player) continue;
        player.transform.position = player_spawn_position;
        player.replicated_velocity = .{ 0, 0, 0 };
        if (player.flags.is_dead) {
            player.flags.is_dead = false;
            player.stats.current.set(.health, player.stats.max.get(.health));
            try physics.createBody(player);
            world.players.appendAssumeCapacity(player.id);
            world.client_updates.appendAssumeCapacity(.{ .spawned = player.id });
        } else if (player.collider.body_id) |body_id| {
            Physics.setPosition(body_id, player_spawn_position);
            Physics.setLinearVelocity(body_id, .{ 0, 0, 0 });
        }
    }

    const teleporter_direction = if (world.dev_mode)
        nz.Vec3(f32){ 0, 1, 0 }
    else
        nz.vec.randomUnitVector(nz.Vec3(f32), random);
    const teleporter_position = shared.planet.surfacePoint(teleporter_direction, world.planet.radius);
    for (0..25) |_| {
        const vector_direction = if (world.dev_mode)
            nz.vec.normalize(shared.planet.surfacePointNear(teleporter_position, world.planet.radius, dev_lootbox_min_distance, dev_lootbox_max_distance, random))
        else
            nz.vec.randomUnitVector(nz.Vec3(f32), random);
        const transform = shared.planet.surfaceTransform(vector_direction, world.planet.radius, system.World.spawn_hover);
        _ = try world.spawn(.{
            .kind = .lootbox,
            .transform = transform,
        });
    }

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
