const std = @import("std");
const Window = @import("Window");

pub const Init = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *Window,
    log_connection_status: bool,
    discord_dir: ?[]const u8,
    autostart: ?[]const u8,
    console: ?[]const u8,
};

pub const Api = struct {
    systemInit: *const fn (init: *const Init) callconv(.c) ?*anyopaque,
    systemDeinit: *const fn (*anyopaque) callconv(.c) void,
    systemUpdate: *const fn (*anyopaque) callconv(.c) bool,
    reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
    layoutHash: *const fn () callconv(.c) u64,
};
