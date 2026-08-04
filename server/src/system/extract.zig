const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Rendering = @import("render").Rendering;
const Camera = @import("Viewer.zig").Camera;
const Ui = @import("render").Ui;

pub fn frame(world: *World, rendering: *Rendering, camera: Camera, ui: *Ui) !void {
    // The wire carries the client's real camera; `Entity.camera` holds only the yaw
    // the sim needs for movement.
    const followed = if (camera.follow != .none) world.getPtr(camera.follow) else null;
    const camera_position: nz.Vec3(f32) = if (followed) |player| player.controller.input.camera_position else camera.position;
    const camera_rotation: nz.quat.Hamiltonian(f32) = if (followed) |player|
        .fromVec(player.controller.input.camera_rotation)
    else
        camera.rotation();

    rendering.beginFrame(.{
        .camera = .{
            .position = camera_position,
            .rotation = camera_rotation,
            .fov_rad = 1.5,
        },
        .elapsed_time = world.elapsed_time,
        .light_color = .{ 1, 1, 1, 1 },
        .draw_sky = true,
        .planet = if (world.place == .planet) .{
            .id = world.planet_id,
            .transform = .identity,
            .radius = @intFromFloat(world.planet_radius),
            .anchor_position = camera_position,
            .view_distance = 4,
        } else null,
        .surface_width = rendering.window.size.width,
        .surface_height = rendering.window.size.height,
    });

    try rendering.animator.begin(.{
        .delta_time = world.delta_time,
        .elapsed_time = world.elapsed_time,
        .local_entity = if (followed) |player| player.id else .none,
        .camera_pitch = if (followed) |player| pitch: {
            const planet_up = nz.vec.normalize(player.transform.position);
            break :pitch std.math.asin(std.math.clamp(nz.vec.dot(camera_rotation.rotateVec(.{ 0, 0, -1 }), planet_up), -1, 1));
        } else camera.pitch,
        .camera_yaw_rotation = if (followed) |player| player.camera.yaw_rotation else camera.yaw_rotation,
    }, &.{}, &rendering.models);

    for (world.entities.values()) |*entity| {
        try rendering.animator.observe(.{
            .id = entity.id,
            .kind = entity.kind,
            .transform = entity.transform,
            .velocity = entity.replicated_velocity,
            .is_dying = false,
            .stun_time = @max(0, entity.un_stun_at - world.elapsed_time),
            .state_override = null,
        }, &rendering.models);
    }
    rendering.advanceAnimation(&.{});
    rendering.drawAnimated();

    rendering.drawUi(ui.quads.items, ui.screen_width, ui.screen_height);
    rendering.endFrame(world.elapsed_time);
}
