const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const system = @import("../System.zig");
const World = @import("../World.zig");
const director = @import("director.zig");
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

pub fn loadPlace(
    world: *World,
    gpa: std.mem.Allocator,
    physics: *Physics,
    place: World.Place,
) !void {
    world.place = place;
    for (world.entities.values()) |entry| {
        if (entry.kind != .player) world.queueDespawn(entry.id);
    }
    try world.flush(physics);
    world.teleporter_id = .none;
    if (place == .planet) world.stage += 1;

    const radius = planetRadius(world, place);
    world.client_updates.appendAssumeCapacity(.{ .event = .{ .new_stage = world.stage } });
    world.client_updates.appendAssumeCapacity(.{ .spawn_planet = radius });
    std.log.info("loadPlace {s} planet_radius={d}", .{ @tagName(place), radius });
    try world.planet.sync(gpa, radius);
    try world.flush(physics);

    switch (place) {
        .ship => try buildShip(world, physics),
        .planet => try buildPlanet(world),
    }
    try placePlayers(world, physics);
}

fn planetRadius(world: *World, place: World.Place) u32 {
    if (place == .ship) return World.ship_planet_radius;
    const base = if (world.dev_mode) shared.Planet.dev_radius_min else shared.Planet.radius_min + (world.stage - 1) * 9;
    const pools = shared.PlanetType.stage_pools;
    const pool = pools[(world.stage - 1) % pools.len];
    const wanted = pool[world.prng.random().uintLessThan(usize, pool.len)];
    return shared.PlanetType.radiusFor(wanted, base);
}

fn buildShip(world: *World, physics: *Physics) !void {
    const floor_position = shipRoomPosition(world);
    _ = try world.spawn(.{ .kind = .platform, .transform = .{ .position = floor_position } });
    const slab = shared.entity.Kind.collider(.platform).?.shape.box;
    const wall_center = floor_position + nz.Vec3(f32){ 0, slab.x, 0 };
    const wall_distance = slab.x + slab.y;
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

    const dummy = shared.entity.Kind.collider(.target_dummy).?.shape.capsule;
    const dummy_height = slab.y + dummy.half_height + dummy.radius;
    _ = try world.spawn(.{
        .kind = .target_dummy,
        .transform = .{
            .position = floor_position + nz.Vec3(f32){ slab.x * 0.5, dummy_height, 0 },
        },
    });

    const portal = try world.spawn(.{
        .kind = .teleporter,
        .transform = .{ .position = floor_position + nz.Vec3(f32){ 0, slab.y, 0 } },
    });
    portal.teleporter.state = .completed;
    portal.teleporter.charged = portal.teleporter.max_charge;
    world.teleporter_id = portal.id;
    try world.flush(physics);
}

fn buildPlanet(world: *World) !void {
    const random = world.prng.random();
    const teleporter_direction = if (world.dev_mode)
        nz.Vec3(f32){ 0, 1, 0 }
    else
        nz.vec.randomUnitVector(nz.Vec3(f32), random);
    const teleporter_position = world.planet.surfacePoint(teleporter_direction);
    const teleporter = try world.spawn(.{
        .kind = .teleporter,
        .transform = .{
            .position = teleporter_position,
            .rotation = shared.math.rotationFromUp(shared.Planet.surfaceUp(teleporter_position)),
        },
    });
    world.teleporter_id = teleporter.id;
    try director.startStage(world);
}

fn placePlayers(world: *World, physics: *Physics) !void {
    const spawn_position = playerSpawnPosition(world);
    for (world.entities.values()) |*player| {
        if (player.kind != .player) continue;
        player.transform.position = spawn_position;
        player.replicated_velocity = .{ 0, 0, 0 };
        if (!player.flags.is_dead) {
            world.act(.{ .id = player.id, .verb = .{ .teleport = spawn_position } });
            world.act(.{ .id = player.id, .verb = .{ .set_velocity = .{ 0, 0, 0 } } });
            continue;
        }
        player.flags.is_dead = false;
        player.health = player.max_health;
        try physics.createBody(player);
        world.client_updates.appendAssumeCapacity(.{ .health = .{
            .id = player.id,
            .source = .none,
            .amount = .{ .set_current = @floatCast(player.max_health) },
        } });
    }
}
