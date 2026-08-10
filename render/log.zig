//! render.so's own logging wiring. Each image carries its own copy of these globals, so
//! this cannot be borrowed from the game — and borrowing it from `shared` is exactly the
//! dependency this package is shedding. Twin of `shared`'s; keep the format identical so
//! the two images' lines interleave readably in one log file.

const std = @import("std");

pub var io: ?std.Io = null;

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
    if (io) |clock_io| {
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
