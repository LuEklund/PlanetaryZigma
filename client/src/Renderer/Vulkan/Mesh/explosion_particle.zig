const Vertex = @import("../Mesh.zig").StaticVertex;

fn v(position: [3]f32, normal: [3]f32, color: [4]f32) Vertex {
    return .{
        .position = position,
        .normal = normal,
        .color = color,
        .uv_x = position[0] + 0.5,
        .uv_y = 0.5 - position[1],
    };
}

pub const verticies: []const Vertex = &.{
    v(.{ -0.5, 0.5, 0 }, .{ 0, 0, -1 }, .{ 1, 1, 1, 1 }),
    v(.{ 0.5, 0.5, 0 }, .{ 0, 0, -1 }, .{ 1, 1, 1, 1 }),
    v(.{ -0.5, -0.5, 0 }, .{ 0, 0, -1 }, .{ 1, 1, 1, 1 }),
    v(.{ 0.5, -0.5, 0 }, .{ 0, 0, -1 }, .{ 1, 1, 1, 1 }),
};

pub const indicies: []const u32 = &.{
    0, 2, 1,
    1, 2, 3,
};
