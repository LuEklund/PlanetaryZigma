const Clock = @This();

const std = @import("std");

previous: std.Io.Timestamp,
accumulated_seconds: f32,

pub const stall_seconds: f32 = 0.1;

pub fn init(io: std.Io) Clock {
    return .{ .previous = .now(io, .awake), .accumulated_seconds = 0 };
}

pub fn elapsedSinceLast(clock: *Clock, io: std.Io) f32 {
    const now: std.Io.Timestamp = .now(io, .awake);
    const delta_nanoseconds = clock.previous.durationTo(now).nanoseconds;
    clock.previous = now;
    return @as(f32, @floatFromInt(delta_nanoseconds)) / std.time.ns_per_s;
}

pub fn stepDue(clock: *Clock, io: std.Io, step_seconds: f32) bool {
    const delta_seconds = clock.elapsedSinceLast(io);
    if (delta_seconds > stall_seconds) std.log.warn("main loop stalled {d:.0}ms", .{delta_seconds * 1000});
    clock.accumulated_seconds += delta_seconds;
    if (clock.accumulated_seconds < step_seconds) {
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch |err| std.log.err("main loop sleep: {t}", .{err});
        return false;
    }
    clock.accumulated_seconds -= step_seconds;
    return true;
}
