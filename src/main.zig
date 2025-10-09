const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const nz = @import("numz");
const Render = @import("render.zig");

pub const db = struct {
    pub const Connection = opaque {
        pub fn connect() !*@This() {
            return c.connect_to_db_ffi() orelse error.Connect;
        }
        pub fn disconnect(self: *@This()) void {
            c.free_db_connection(self);
        }
    };

    pub const c = struct {
        pub extern fn connect_to_db_ffi() callconv(.c) ?*Connection;
        pub extern fn free_db_connection(connection: ?*Connection) callconv(.c) void;
    };
};

pub fn main() !void {
    const connection: *db.Connection = try .connect();
    defer connection.disconnect();

    // const window = Render.init();
    // defer Render.deinit(window);

    // const pipeline = Render.initPipeline();
    // defer Render.deinitPipeline(pipeline);

    // var time: f32 = 0;
    // while (!window.shouldClose()) {
    //     const delta_time = try getDeltaTime();
    //     time += delta_time;
    //     Render.update(window, delta_time);
    //     Render.draw(pipeline, window);
    // }
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
