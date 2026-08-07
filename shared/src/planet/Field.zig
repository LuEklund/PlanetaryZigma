const Field = @This();

const std = @import("std");

id: @EnumLiteral(),
frequency: f32,
points: []const [2]f32,

pub const fields: []const Field = &.{
    .{ .id = .hills, .frequency = 0.03, .points = &.{ .{ -1, -5 }, .{ 1, 5 } } },
    .{ .id = .mountain, .frequency = 0.008, .points = &.{ .{ -1, 0 }, .{ 0.5, 0 }, .{ 0.7, 10 }, .{ 1, 12 } } },
    .{ .id = .crater, .frequency = 0.03, .points = &.{ .{ -1, -2 }, .{ -0.9, -4 }, .{ -0.75, -4 }, .{ -0.6, 0 }, .{ 1, 0 } } },
};

pub const max_height: comptime_int = blk: {
    var total: f32 = 0;
    for (fields) |field| {
        var biggest: f32 = 0;
        for (field.points) |point| biggest = @max(biggest, @abs(point[1]));
        total += biggest;
    }
    break :blk @intFromFloat(@ceil(total));
};

pub fn evaluate(self: Field, x: f32) f32 {
    if (x <= self.points[0][0]) return self.points[0][1];
    if (x >= self.points[self.points.len - 1][0]) return self.points[self.points.len - 1][1];
    for (0..self.points.len - 1) |i| {
        if (x > self.points[i + 1][0]) continue;
        const t = (x - self.points[i][0]) / (self.points[i + 1][0] - self.points[i][0]);
        return std.math.lerp(self.points[i][1], self.points[i + 1][1], t);
    }
    unreachable;
}
