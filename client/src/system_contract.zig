const std = @import("std");
const Window = @import("Window");

pub const World = @import("World.zig");

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    world: *World,
    log_connection_status: bool,
    discord_dir: ?[]const u8,
};

pub const Api = struct {
    systemInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    systemDeinit: *const fn (*anyopaque) callconv(.c) void,
    systemUpdate: *const fn (*anyopaque, world: *World) callconv(.c) bool,
    reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
};
