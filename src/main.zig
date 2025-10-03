const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const nz = @import("numz");
const Render = @import("render.zig");

pub fn main() !void {
    const window = Render.init();
    defer Render.deinit(window);

    const pipeline = Render.initPipeline();
    defer Render.deinitPipeline(pipeline);

    var time: f32 = 0;
    while (!window.shouldClose()) {
        const delta_time = try getDeltaTime();
        time += delta_time;
        Render.update(window, delta_time);
        Render.draw(pipeline, window);
    }
}

pub fn getDeltaTime() !f32 {
    const Static = struct {
        var previous: ?std.time.Instant = null;
    };

    const now = try std.time.Instant.now();
    const prev = Static.previous orelse {
        Static.previous = now;
        return 0.0;
    };

    const dt_ns = now.since(prev);
    Static.previous = now;

    return @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
}
