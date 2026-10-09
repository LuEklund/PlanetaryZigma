const std = @import("std");
const shared = @import("shared");
const build_options = @import("build_options");

pub const Window = if (build_options.viewer) @import("Window") else void;

pub const Data = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mode: shared.SteamNet.Server.Mode,
    host_steam_id: u64,
    dev_mode: bool,
    log_connection_status: bool,
    window: if (build_options.viewer) *Window else void,
};

pub const Api = struct {
    systemInit: *const fn (data: *const Data) callconv(.c) ?*anyopaque,
    systemDeinit: *const fn (*anyopaque) callconv(.c) void,
    systemUpdate: *const fn (*anyopaque) callconv(.c) bool,
    reload: *const fn (*anyopaque, pre_reload: bool) callconv(.c) void,
    layoutHash: *const fn () callconv(.c) u64,
};
