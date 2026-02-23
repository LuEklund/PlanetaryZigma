const std = @import("std");

pub const nz = @import("numz");
pub const ecs = @import("ecs");
pub const Watcher = @import("watcher.zig");

pub const net = struct {
    pub const address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 6767 } };
};
