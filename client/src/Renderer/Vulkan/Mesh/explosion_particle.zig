const Vertex = @import("../Mesh.zig").StaticVertex;

const yellow: [4]f32 = .{ 1.0, 0.82, 0.08, 1 };
const orange: [4]f32 = .{ 1.0, 0.32, 0.02, 1 };

fn v(position: [3]f32, normal: [3]f32, color: [4]f32) Vertex {
    return .{ .position = position, .normal = normal, .color = color };
}

pub const verticies: []const Vertex = &.{
    v(.{ 0, 0.45, 0 }, .{ 0, 0.7, 0.7 }, yellow),
    v(.{ -0.4, -0.25, 0.25 }, .{ 0, 0.7, 0.7 }, orange),
    v(.{ 0.4, -0.25, 0.25 }, .{ 0, 0.7, 0.7 }, orange),

    v(.{ 0, 0.45, 0 }, .{ 0.8, 0.4, -0.2 }, yellow),
    v(.{ 0.4, -0.25, 0.25 }, .{ 0.8, 0.4, -0.2 }, orange),
    v(.{ 0, -0.25, -0.45 }, .{ 0.8, 0.4, -0.2 }, orange),

    v(.{ 0, 0.45, 0 }, .{ -0.8, 0.4, -0.2 }, yellow),
    v(.{ 0, -0.25, -0.45 }, .{ -0.8, 0.4, -0.2 }, orange),
    v(.{ -0.4, -0.25, 0.25 }, .{ -0.8, 0.4, -0.2 }, orange),

    v(.{ -0.4, -0.25, 0.25 }, .{ 0, -1, 0 }, orange),
    v(.{ 0, -0.25, -0.45 }, .{ 0, -1, 0 }, orange),
    v(.{ 0.4, -0.25, 0.25 }, .{ 0, -1, 0 }, orange),
};

pub const indicies: []const u32 = &.{
    0, 1,  2,
    3, 4,  5,
    6, 7,  8,
    9, 10, 11,
};
