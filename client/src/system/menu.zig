const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");

const planet_id: shared.entity.Id = @enumFromInt(1);
const bozo_id: shared.entity.Id = @enumFromInt(2);

const camera_fov_rad: f32 = 1.25;

const planet_mesh_radius: u32 = 18;
const planet_position: nz.Vec3(f32) = .{ 4.6, -16.1, -60 };
const planet_scale: f32 = 0.75;
const planet_spin_speed: f32 = 0.22;

const bozo_surface_offset: f32 = 3.5;
const bozo_scale: f32 = 4.4;

pub fn populate(world: *World) !void {
    world.camera = .{ .transform = .{}, .fov_rad = camera_fov_rad };

    const planet = try world.spawn(planet_id);
    planet.* = .{
        .id = planet_id,
        .kind = .planet,
        .transform = .{ .position = planet_position, .scale = @splat(planet_scale) },
    };
    world.planet_radius = @floatFromInt(planet_mesh_radius);
    world.render_outbox.appendAssumeCapacity(.{ .planet_spawned = .{ .id = planet_id, .radius = planet_mesh_radius } });
    world.render_outbox.appendAssumeCapacity(.{ .entity_spawned = .{ .id = planet_id, .kind = .planet } });

    const stand_height = @as(f32, @floatFromInt(planet_mesh_radius)) * planet_scale + bozo_surface_offset;
    const bozo = try world.spawn(bozo_id);
    bozo.* = .{
        .id = bozo_id,
        .kind = .player,
        .transform = .{
            .position = planet_position + nz.Vec3(f32){ 0, stand_height, 0 },
            .rotation = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 }),
            .scale = @splat(bozo_scale),
        },
        .animation_state = .walk,
    };
    world.render_outbox.appendAssumeCapacity(.{ .entity_spawned = .{ .id = bozo_id, .kind = .player } });
}

pub fn update(world: *World, elapsed_time: f32) void {
    const planet = world.getPtr(planet_id) orelse return;
    planet.transform.rotation = nz.Quat(f32).angleAxis(elapsed_time * planet_spin_speed, .{ 1, 0, 0 });
}
