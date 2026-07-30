const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const FrameData = @import("FrameData.zig");

const collider_color: [4]f32 = .{ 0, 1, 0, 1 };
const circle_segments = 16;

pub fn appendLine(vertices: [*]FrameData.DebugVertex, vertex_count: *u32, from: nz.Vec3(f32), to: nz.Vec3(f32)) void {
    std.debug.assert(vertex_count.* + 2 <= FrameData.max_debug_vertices);
    vertices[vertex_count.*] = .{ .position = .{ from[0], from[1], from[2], 1 }, .color = collider_color };
    vertices[vertex_count.* + 1] = .{ .position = .{ to[0], to[1], to[2], 1 }, .color = collider_color };
    vertex_count.* += 2;
}

pub fn appendCapsuleLines(vertices: [*]FrameData.DebugVertex, vertex_count: *u32, half_heigth: f32, radius: f32) void {
    for (0..circle_segments) |segment| {
        const angle_start = std.math.tau * @as(f32, @floatFromInt(segment)) / circle_segments;
        const angle_end = std.math.tau * @as(f32, @floatFromInt(segment + 1)) / circle_segments;
        for ([2]f32{ -half_heigth, half_heigth }) |ring_y| {
            appendLine(
                vertices,
                vertex_count,
                .{ radius * @cos(angle_start), ring_y, radius * @sin(angle_start) },
                .{ radius * @cos(angle_end), ring_y, radius * @sin(angle_end) },
            );
        }
    }
    for (0..4) |quarter| {
        const angle = std.math.tau * @as(f32, @floatFromInt(quarter)) / 4;
        appendLine(
            vertices,
            vertex_count,
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
                vertices,
                vertex_count,
                .{ radius * @cos(angle_start), cap_y + cap_direction * radius * @sin(angle_start), 0 },
                .{ radius * @cos(angle_end), cap_y + cap_direction * radius * @sin(angle_end), 0 },
            );
            appendLine(
                vertices,
                vertex_count,
                .{ 0, cap_y + cap_direction * radius * @sin(angle_start), radius * @cos(angle_start) },
                .{ 0, cap_y + cap_direction * radius * @sin(angle_end), radius * @cos(angle_end) },
            );
        }
    }
}

pub fn appendBoxLines(vertices: [*]FrameData.DebugVertex, vertex_count: *u32, box: shared.entity.ColliderShape.HalfBoxExtent) void {
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
        appendLine(vertices, vertex_count, bottom_corners[corner_index], bottom_corners[next_corner_index]);
        appendLine(vertices, vertex_count, top_corners[corner_index], top_corners[next_corner_index]);
        appendLine(vertices, vertex_count, bottom_corners[corner_index], top_corners[corner_index]);
    }
}
