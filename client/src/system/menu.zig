const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");

const bozo_id: shared.entity.Id = @enumFromInt(2);

const planet_radius: f32 = 18;
const camera_position: nz.Vec3(f32) = .{ -6.1, 21.5, 80 };

const bozo_surface_offset: f32 = 4.7;
const bozo_scale: f32 = 4.4;

pub fn populate(world: *World) !void {
    world.camera = .{ .transform = .{ .position = camera_position } };
    world.controller.free_camera = false;
    try world.planet.sync(world.gpa, planet_radius);

    try world.applySpawn(.{
        .id = bozo_id,
        .kind = .player,
        .position = .{ 0, planet_radius + bozo_surface_offset, 0 },
        .rotation = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 }).toVec(),
        .data = .none,
    });
}

pub fn update(world: *World) void {
    const bozo = world.getPtr(bozo_id) orelse return;
    bozo.motion.update = null;
    bozo.transform.scale = @splat(bozo_scale);
    bozo.override_animation_loop = .walk;
}
