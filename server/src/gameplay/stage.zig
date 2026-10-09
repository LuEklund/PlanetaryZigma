const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const Physics = @import("../system/Physics.zig");

pub fn shipRoomPosition(world: *const World) nz.Vec3(f32) {
    return nz.Vec3(f32){ 0, world.planet.radiusFloat() * World.ship_room_altitude_factor, 0 };
}

pub fn playerSpawnPosition(world: *const World) nz.Vec3(f32) {
    return switch (world.place) {
        .ship => shipRoomPosition(world) + nz.Vec3(f32){ 0, World.ship_room_stand_height, 0 },
        .planet => world.planet.surfacePoint(.{ 0, 1, 0 }) + nz.Vec3(f32){ 0, 2, 0 },
    };
}

pub fn loadPlace(world: *World, gpa: std.mem.Allocator, physics: *Physics, place: World.Place) !void {
    world.place = place;
    for (world.entities.values()) |entry| {
        if (entry.kind != .player) world.queueDespawn(entry.id);
    }
    try world.flush(physics);
    const random = world.prng.random();
    world.teleporter_id = .none;
    if (place == .planet) world.stage += 1;
    const spawn_planet_radius: u32 = switch (place) {
        .ship => World.ship_planet_radius,
        .planet => if (world.dev_mode)
            random.intRangeAtMost(u32, shared.Planet.dev_radius_min, shared.Planet.dev_radius_min + 1)
        else
            shared.Planet.radius_min + (world.stage - 1) * 9,
    };
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .new_stage = world.stage } });
    world.client_updates.appendAssumeCapacity(.{ .spawn_planet = spawn_planet_radius });
    std.log.info("loadPlace {s} planet_radius={d}", .{ @tagName(place), spawn_planet_radius });
    try world.planet.sync(gpa, spawn_planet_radius);
    try world.flush(physics);

    switch (place) {
        .ship => {
            const floor_position: nz.Vec3(f32) = shipRoomPosition(world);
            _ = try world.spawn(.{
                .kind = .platform,
                .transform = .{ .position = floor_position },
            });
            const slab: shared.entity.ColliderShape.HalfBoxExtent = shared.entity.Kind.collider(.platform).?.shape.box;
            const wall_center: nz.Vec3(f32) = floor_position + nz.Vec3(f32){ 0, slab.x, 0 };
            const wall_distance: f32 = slab.x + slab.y;
            const walls: [4]struct { offset: nz.Vec3(f32), axis: nz.Vec3(f32) } = .{
                .{ .offset = .{ wall_distance, 0, 0 }, .axis = .{ 0, 0, 1 } },
                .{ .offset = .{ -wall_distance, 0, 0 }, .axis = .{ 0, 0, 1 } },
                .{ .offset = .{ 0, 0, wall_distance }, .axis = .{ 1, 0, 0 } },
                .{ .offset = .{ 0, 0, -wall_distance }, .axis = .{ 1, 0, 0 } },
            };
            for (walls) |wall| {
                _ = try world.spawn(.{
                    .kind = .platform,
                    .transform = .{
                        .position = wall_center + wall.offset,
                        .rotation = nz.quat.Hamiltonian(f32).angleAxis(std.math.pi / 2.0, wall.axis),
                    },
                });
            }

            const dummy_capsule = shared.entity.Kind.collider(.target_dummy).?.shape.capsule;
            _ = try world.spawn(.{
                .kind = .target_dummy,
                .transform = .{ .position = floor_position + nz.Vec3(f32){
                    slab.x * 0.5,
                    slab.y + dummy_capsule.half_height + dummy_capsule.radius,
                    0,
                } },
            });

            const portal = try world.spawn(.{
                .kind = .teleporter,
                .transform = .{ .position = floor_position + nz.Vec3(f32){ 0, slab.y, 0 } },
            });
            portal.teleporter.state = .completed;
            portal.teleporter.charged = portal.teleporter.max_charge;
            world.teleporter_id = portal.id;
            try world.flush(physics);
        },
        .planet => {
            world.director.spawning = true;
            const teleporter_direction = if (world.dev_mode)
                nz.Vec3(f32){ 0, 1, 0 }
            else
                nz.vec.randomUnitVector(nz.Vec3(f32), random);
            const teleporter_position = world.planet.surfacePoint(teleporter_direction);
            for (0..25) |_| {
                const vector_direction = if (world.dev_mode)
                    nz.vec.normalize(world.planet.surfacePointNear(teleporter_position, 5, 10, random))
                else
                    nz.vec.randomUnitVector(nz.Vec3(f32), random);
                const transform = world.planet.surfaceTransform(vector_direction, 0.2);
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
        },
    }

    const player_spawn_position = playerSpawnPosition(world);
    for (world.entities.values()) |*player| {
        if (player.kind != .player) continue;
        player.transform.position = player_spawn_position;
        player.replicated_velocity = .{ 0, 0, 0 };
        if (player.flags.is_dead) {
            player.flags.is_dead = false;
            player.health = player.max_health;
            try physics.createBody(player);
            world.client_updates.appendAssumeCapacity(.{ .health = .{ .id = player.id, .source = .none, .amount = .{ .set_current = @floatCast(player.max_health) } } });
        } else {
            world.act(.{ .id = player.id, .verb = .{ .teleport = player_spawn_position } });
            world.act(.{ .id = player.id, .verb = .{ .set_velocity = .{ 0, 0, 0 } } });
        }
    }
}
