const std = @import("std");
const builtin = @import("builtin");

pub const numz = @import("numz");
pub const net = @import("net.zig");
pub const planet = @import("planet/root.zig");
pub const StaticVertex = @import("vertex.zig").StaticVertex;
pub const SkinnedVertex = @import("vertex.zig").SkinnedVertex;

pub const Watcher = @import("Watcher.zig");
pub const DynLib = @import("DynLib.zig").DynLib;
pub const SteamNet = @import("SteamNet.zig");

const inventory = @import("inventory.zig");
pub const Item = inventory.Item;
pub const Inventory = inventory.Inventory;

pub const entity = @import("entity.zig");

pub const version: []const u8 = "0.1.0";

pub const tick_seconds: f32 = 0.0167;
pub const max_entities: usize = 1024;
pub const max_enemies: usize = 100;
pub const max_players: usize = 4;
pub const max_player_name_len: usize = 32;
pub const default_player_name: []const u8 = "Player";
pub const max_chat_len: usize = 128;

pub var log_io: ?std.Io = null;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const debug_io = std.Options.debug_io;
    const previous_protection = debug_io.swapCancelProtection(.blocked);
    defer _ = debug_io.swapCancelProtection(previous_protection);
    var buffer: [64]u8 = undefined;
    const terminal = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    if (log_io) |clock_io| {
        const nanoseconds = std.Io.Timestamp.now(clock_io, .real).nanoseconds;
        const day_seconds: u64 = @intCast(@mod(@divFloor(nanoseconds, std.time.ns_per_s), std.time.s_per_day));
        const milliseconds: u64 = @intCast(@mod(@divFloor(nanoseconds, std.time.ns_per_ms), std.time.ms_per_s));
        terminal.writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} ", .{
            @divFloor(day_seconds, std.time.s_per_hour),
            @divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min),
            @mod(day_seconds, std.time.s_per_min),
            milliseconds,
        }) catch {};
    }
    std.log.defaultLogFileTerminal(level, scope, format, args, terminal) catch {};
}

pub fn redirectStderrToFile(io: std.Io, path: []const u8) void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    switch (builtin.os.tag) {
        .windows => std.os.windows.peb().ProcessParameters.hStdError = file.handle,
        .linux => _ = std.os.linux.dup2(file.handle, 2),
        else => {},
    }
}

pub const teleporter = struct {
    pub const intertact_distance: f32 = 6;
    pub const charge_distance: f32 = 12;

    pub const State = struct {
        state: enum(u32) {
            idle,
            active,
            completed,
        } = .idle,
        charged: f32 = 0,
        max_charge: f32 = 100,
    };
};

pub const Stats = @import("Stats.zig");
