const Vertex = @import("shared").StaticVertex;

pub const vertices: []const Vertex = &.{
    .{ .position = .{ -1, -1, 1 }, .normal = .{ 0, 0, 1 }, .color = .{ 1, 0, 0, 1 }, .uv_x = 0, .uv_y = 1 },
    .{ .position = .{ 1, -1, 1 }, .normal = .{ 0, 0, 1 }, .color = .{ 1, 0, 0, 1 }, .uv_x = 1, .uv_y = 1 },
    .{ .position = .{ -1, 1, 1 }, .normal = .{ 0, 0, 1 }, .color = .{ 1, 0, 0, 1 }, .uv_x = 0, .uv_y = 0 },
    .{ .position = .{ 1, 1, 1 }, .normal = .{ 0, 0, 1 }, .color = .{ 1, 0, 0, 1 }, .uv_x = 1, .uv_y = 0 },
    .{ .position = .{ 1, -1, -1 }, .normal = .{ 0, 0, -1 }, .color = .{ 0, 1, 0, 1 }, .uv_x = 0, .uv_y = 1 },
    .{ .position = .{ -1, -1, -1 }, .normal = .{ 0, 0, -1 }, .color = .{ 0, 1, 0, 1 }, .uv_x = 1, .uv_y = 1 },
    .{ .position = .{ 1, 1, -1 }, .normal = .{ 0, 0, -1 }, .color = .{ 0, 1, 0, 1 }, .uv_x = 0, .uv_y = 0 },
    .{ .position = .{ -1, 1, -1 }, .normal = .{ 0, 0, -1 }, .color = .{ 0, 1, 0, 1 }, .uv_x = 1, .uv_y = 0 },
    .{ .position = .{ -1, -1, -1 }, .normal = .{ -1, 0, 0 }, .color = .{ 0, 1, 1, 1 }, .uv_x = 0, .uv_y = 1 },
    .{ .position = .{ -1, -1, 1 }, .normal = .{ -1, 0, 0 }, .color = .{ 0, 1, 1, 1 }, .uv_x = 1, .uv_y = 1 },
    .{ .position = .{ -1, 1, -1 }, .normal = .{ -1, 0, 0 }, .color = .{ 0, 1, 1, 1 }, .uv_x = 0, .uv_y = 0 },
    .{ .position = .{ -1, 1, 1 }, .normal = .{ -1, 0, 0 }, .color = .{ 0, 1, 1, 1 }, .uv_x = 1, .uv_y = 0 },
    .{ .position = .{ 1, -1, 1 }, .normal = .{ 1, 0, 0 }, .color = .{ 0, 0, 1, 1 }, .uv_x = 0, .uv_y = 1 },
    .{ .position = .{ 1, -1, -1 }, .normal = .{ 1, 0, 0 }, .color = .{ 0, 0, 1, 1 }, .uv_x = 1, .uv_y = 1 },
    .{ .position = .{ 1, 1, 1 }, .normal = .{ 1, 0, 0 }, .color = .{ 0, 0, 1, 1 }, .uv_x = 0, .uv_y = 0 },
    .{ .position = .{ 1, 1, -1 }, .normal = .{ 1, 0, 0 }, .color = .{ 0, 0, 1, 1 }, .uv_x = 1, .uv_y = 0 },
    .{ .position = .{ -1, 1, 1 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 }, .uv_x = 0, .uv_y = 1 },
    .{ .position = .{ 1, 1, 1 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 }, .uv_x = 1, .uv_y = 1 },
    .{ .position = .{ -1, 1, -1 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 }, .uv_x = 0, .uv_y = 0 },
    .{ .position = .{ 1, 1, -1 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1, 1 }, .uv_x = 1, .uv_y = 0 },
    .{ .position = .{ -1, -1, -1 }, .normal = .{ 0, -1, 0 }, .color = .{ 0, 0, 0, 1 }, .uv_x = 0, .uv_y = 1 },
    .{ .position = .{ 1, -1, -1 }, .normal = .{ 0, -1, 0 }, .color = .{ 0, 0, 0, 1 }, .uv_x = 1, .uv_y = 1 },
    .{ .position = .{ -1, -1, 1 }, .normal = .{ 0, -1, 0 }, .color = .{ 0, 0, 0, 1 }, .uv_x = 0, .uv_y = 0 },
    .{ .position = .{ 1, -1, 1 }, .normal = .{ 0, -1, 0 }, .color = .{ 0, 0, 0, 1 }, .uv_x = 1, .uv_y = 0 },
};

pub const indices: []const u32 = &.{
    0,  1,  2,  1,  3,  2,
    4,  5,  6,  5,  7,  6,
    8,  9,  10, 9,  11, 10,
    12, 13, 14, 13, 15, 14,
    16, 17, 18, 17, 19, 18,
    20, 21, 22, 21, 23, 22,
};
