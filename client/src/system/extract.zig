const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const World = @import("../World.zig");
const Ui = @import("render").Ui;
const FramePacket = @import("render").FramePacket;
const Presentation = @import("render").Presentation;
const ModelTable = @import("render").ModelTable;

const collider_color: [4]f32 = .{ 0, 1, 0, 1 };
const circle_segments = 16;

pub fn present(world: *World, presentation: *Presentation, loader: *ModelTable, packet: *FramePacket) !void {
    try presentation.begin(.{
        .delta_time = world.delta_time,
        .elapsed_time = world.elapsed_time,
        .local_entity = world.player_id,
        .camera_pitch = world.camera.pitch,
        .camera_yaw_rotation = world.camera.yaw_rotation,
    }, world.deaths.items, loader);
    world.deaths.clearRetainingCapacity();
    for (world.effects.items) |request| presentation.spawnEffect(request);
    world.effects.clearRetainingCapacity();
    for (world.entities.values()) |*entity| {
        try presentation.observe(.{
            .id = entity.id,
            .kind = entity.kind,
            .transform = entity.transform,
            .velocity = if (entity.motion.update) |update_motion| update_motion.velocity else @splat(0),
            .is_dying = entity.flags.is_dying,
            .stun_time = entity.stun_time,
            .state_override = entity.override_animation_state,
        }, loader);
    }
    presentation.finish(world.trigger_events.items, loader, packet);
    world.trigger_events.clearRetainingCapacity();
}

pub fn extract(world: *World, ui: *Ui, packet: *FramePacket, draw_sky: bool) void {
    packet.clear();

    packet.camera = .{
        .position = world.camera.transform.position,
        .rotation = world.camera.transform.rotation,
        .fov_rad = world.camera.fov_rad,
    };
    packet.time = world.elapsed_time;
    packet.light_color = if (world.teleporter_bosses.items.len == 0) .{ 1, 1, 1, 1 } else .{ 1, 0.5, 0.5, 1 };
    packet.draw_sky = draw_sky;

    if (world.controller.debug_draw_colliders) {
        for (world.entities.values()) |*entity| {
            const collider_shape = (shared.entity.collider(entity.kind) orelse continue).shape;
            var collider_transform = entity.transform;
            collider_transform.scale = @splat(1);
            switch (collider_shape) {
                .capsule => |capsule| appendCapsuleLines(packet, collider_transform, capsule.half_heigth, capsule.radius),
                .box => |box| appendBoxLines(packet, collider_transform, box),
            }
        }
    }

    packet.ui.quads.appendSliceAssumeCapacity(ui.quads.items);
    packet.ui.screen_width = ui.screen_width;
    packet.ui.screen_height = ui.screen_heigth;
    packet.surface_width = @intFromFloat(ui.screen_width);
    packet.surface_height = @intFromFloat(ui.screen_heigth);

    const planet_entity: ?*World.Entity = for (world.entities.values()) |*entity| {
        if (entity.kind == .planet) break entity;
    } else null;
    if (planet_entity) |planet| {
        packet.planet = .{
            .transform = planet.transform.toMat4x4(),
            .radius = @intFromFloat(world.planet_radius),
            .anchor_position = if (world.getPtr(world.player_id)) |player| player.transform.position else world.camera.transform.position,
            .view_distance = @max(world.chunk_view_distance, 1),
            .present = true,
        };
    } else {
        packet.planet = .{
            .transform = .identity,
            .radius = 0,
            .anchor_position = @splat(0),
            .view_distance = 1,
            .present = false,
        };
    }
}

fn appendLine(packet: *FramePacket, transform: nz.Transform3D(f32), from: nz.Vec3(f32), to: nz.Vec3(f32)) void {
    packet.draw_lines.appendAssumeCapacity(.{
        .a = transform.position + transform.rotation.rotateVec(from),
        .b = transform.position + transform.rotation.rotateVec(to),
        .color = collider_color,
    });
}

fn appendCapsuleLines(packet: *FramePacket, transform: nz.Transform3D(f32), half_heigth: f32, radius: f32) void {
    for (0..circle_segments) |segment| {
        const angle_start = std.math.tau * @as(f32, @floatFromInt(segment)) / circle_segments;
        const angle_end = std.math.tau * @as(f32, @floatFromInt(segment + 1)) / circle_segments;
        for ([2]f32{ -half_heigth, half_heigth }) |ring_y| {
            appendLine(
                packet,
                transform,
                .{ radius * @cos(angle_start), ring_y, radius * @sin(angle_start) },
                .{ radius * @cos(angle_end), ring_y, radius * @sin(angle_end) },
            );
        }
    }
    for (0..4) |quarter| {
        const angle = std.math.tau * @as(f32, @floatFromInt(quarter)) / 4;
        appendLine(
            packet,
            transform,
            .{ radius * @cos(angle), -half_heigth, radius * @sin(angle) },
            .{ radius * @cos(angle), half_heigth, radius * @sin(angle) },
        );
    }
    const arc_segments = circle_segments / 2;
    for (0..arc_segments) |segment| {
        const angle_start = std.math.pi * @as(f32, @floatFromInt(segment)) / arc_segments;
        const angle_end = std.math.pi * @as(f32, @floatFromInt(segment + 1)) / arc_segments;
        for ([2]f32{ 1, -1 }) |cap_direction| {
            const cap_y = cap_direction * half_heigth;
            appendLine(
                packet,
                transform,
                .{ radius * @cos(angle_start), cap_y + cap_direction * radius * @sin(angle_start), 0 },
                .{ radius * @cos(angle_end), cap_y + cap_direction * radius * @sin(angle_end), 0 },
            );
            appendLine(
                packet,
                transform,
                .{ 0, cap_y + cap_direction * radius * @sin(angle_start), radius * @cos(angle_start) },
                .{ 0, cap_y + cap_direction * radius * @sin(angle_end), radius * @cos(angle_end) },
            );
        }
    }
}

fn appendBoxLines(packet: *FramePacket, transform: nz.Transform3D(f32), box: shared.entity.ColliderShape.HalfBoxExtent) void {
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
        appendLine(packet, transform, bottom_corners[corner_index], bottom_corners[next_corner_index]);
        appendLine(packet, transform, top_corners[corner_index], top_corners[next_corner_index]);
        appendLine(packet, transform, bottom_corners[corner_index], top_corners[corner_index]);
    }
}
