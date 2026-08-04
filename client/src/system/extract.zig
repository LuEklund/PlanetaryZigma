const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Ui = @import("render").Ui;
const Renderer = @import("render").Renderer;

const collider_color: [4]f32 = .{ 0, 1, 0, 1 };
const circle_segments = 16;

pub fn frame(world: *World, renderer: *Renderer, ui: *Ui, draw_sky: bool) !void {
    const planet_entity = world.getPtr(world.planet_id);

    renderer.beginFrame(.{
        .camera = .{
            .position = world.camera.transform.position,
            .rotation = world.camera.transform.rotation,
            .fov_rad = world.camera.fov_rad,
        },
        .elapsed_time = world.elapsed_time,
        .light_color = if (world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{ 1, 0.5, 0.5, 1 },
        .draw_sky = draw_sky,
        .planet = if (planet_entity) |planet| .{
            .id = planet.id,
            .transform = planet.transform.toMat4x4(),
            .radius = @intFromFloat(world.planet_radius),
            .anchor_position = if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position,
            .view_distance = @max(world.chunk_view_distance, 1),
        } else null,
        .surface_width = @intFromFloat(ui.screen_width),
        .surface_height = @intFromFloat(ui.screen_height),
    });

    try renderer.animator.begin(.{
        .delta_time = world.delta_time,
        .elapsed_time = world.elapsed_time,
        .local_entity = world.player_id,
        .camera_pitch = world.camera.pitch,
        .camera_yaw_rotation = world.camera.yaw_rotation,
    }, world.deaths.items, &renderer.models);
    world.deaths.clearRetainingCapacity();

    for (world.effects.items) |request| renderer.spawnEffect(request, world.elapsed_time);
    world.effects.clearRetainingCapacity();

    for (world.entities.values()) |*entity| {
        try renderer.animator.observe(.{
            .id = entity.id,
            .kind = entity.kind,
            .transform = entity.transform,
            .velocity = if (entity.motion.update) |update_motion| update_motion.velocity else @splat(0),
            .is_dying = entity.flags.is_dying,
            .stun_time = entity.stun_time,
            .state_override = entity.override_animation_state,
        }, &renderer.models);
    }
    renderer.advanceAnimation(world.trigger_events.items);
    world.trigger_events.clearRetainingCapacity();
    renderer.drawAnimated();

    if (world.controller.debug_draw_colliders) {
        for (world.entities.values()) |*entity| {
            const collider_shape = (shared.entity.collider(entity.kind) orelse continue).shape;
            var collider_transform = entity.transform;
            collider_transform.scale = @splat(1);
            switch (collider_shape) {
                .capsule => |capsule| appendCapsuleLines(renderer, collider_transform, capsule.half_height, capsule.radius),
                .box => |box| appendBoxLines(renderer, collider_transform, box),
            }
        }
    }

    renderer.drawUi(ui.quads.items, ui.screen_width, ui.screen_height);
    renderer.endFrame(world.elapsed_time);
}

fn appendLine(renderer: *Renderer, transform: nz.Transform3D(f32), from: nz.Vec3(f32), to: nz.Vec3(f32)) void {
    renderer.drawLine(
        transform.position + transform.rotation.rotateVec(from),
        transform.position + transform.rotation.rotateVec(to),
        collider_color,
    );
}

fn appendCapsuleLines(renderer: *Renderer, transform: nz.Transform3D(f32), half_height: f32, radius: f32) void {
    for (0..circle_segments) |segment| {
        const angle_start = std.math.tau * @as(f32, @floatFromInt(segment)) / circle_segments;
        const angle_end = std.math.tau * @as(f32, @floatFromInt(segment + 1)) / circle_segments;
        for ([2]f32{ -half_height, half_height }) |ring_y| {
            appendLine(
                renderer,
                transform,
                .{ radius * @cos(angle_start), ring_y, radius * @sin(angle_start) },
                .{ radius * @cos(angle_end), ring_y, radius * @sin(angle_end) },
            );
        }
    }
    for (0..4) |quarter| {
        const angle = std.math.tau * @as(f32, @floatFromInt(quarter)) / 4;
        appendLine(
            renderer,
            transform,
            .{ radius * @cos(angle), -half_height, radius * @sin(angle) },
            .{ radius * @cos(angle), half_height, radius * @sin(angle) },
        );
    }
    const arc_segments = circle_segments / 2;
    for (0..arc_segments) |segment| {
        const angle_start = std.math.pi * @as(f32, @floatFromInt(segment)) / arc_segments;
        const angle_end = std.math.pi * @as(f32, @floatFromInt(segment + 1)) / arc_segments;
        for ([2]f32{ 1, -1 }) |cap_direction| {
            const cap_y = cap_direction * half_height;
            appendLine(
                renderer,
                transform,
                .{ radius * @cos(angle_start), cap_y + cap_direction * radius * @sin(angle_start), 0 },
                .{ radius * @cos(angle_end), cap_y + cap_direction * radius * @sin(angle_end), 0 },
            );
            appendLine(
                renderer,
                transform,
                .{ 0, cap_y + cap_direction * radius * @sin(angle_start), radius * @cos(angle_start) },
                .{ 0, cap_y + cap_direction * radius * @sin(angle_end), radius * @cos(angle_end) },
            );
        }
    }
}

fn appendBoxLines(renderer: *Renderer, transform: nz.Transform3D(f32), box: shared.entity.ColliderShape.HalfBoxExtent) void {
    const bottom_corners = [4]nz.Vec3(f32){
        .{ -box.x, -box.y, -box.z },
        .{ box.x, -box.y, -box.z },
        .{ box.x, -box.y, box.z },
        .{ -box.x, -box.y, box.z },
    };
    var top_corners = bottom_corners;
    for (&top_corners) |*corner| corner[1] = box.y;

    for (0..4) |corner_index| {
        const next_corner_index = (corner_index + 1) % 4;
        appendLine(renderer, transform, bottom_corners[corner_index], bottom_corners[next_corner_index]);
        appendLine(renderer, transform, top_corners[corner_index], top_corners[next_corner_index]);
        appendLine(renderer, transform, bottom_corners[corner_index], top_corners[corner_index]);
    }
}
