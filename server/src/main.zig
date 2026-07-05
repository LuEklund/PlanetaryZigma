const std = @import("std");
const builtin = @import("builtin");
const system = @import("system");
const shared = @import("shared");
const tracy = @import("ztracy");
const World = system.World;
const nz = shared.numz;

pub fn main(init: std.process.Init) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = gpa_impl.allocator();
    const io = init.io;

    var steam_server: shared.SteamNet.Server = try .init(gpa, io);
    defer steam_server.deinit();
    steam_server.handle_packets_future = try io.concurrent(shared.SteamNet.Server.handlePackets, .{&steam_server});

    var watcher: shared.Watcher = try .init("system_server", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var world: World = try .init(gpa);
    defer world.deinit();

    var system_context: system.Context = undefined;
    var system_table: system.ffi.Table = try .load(&watcher.dynlib.?);

    system_table.systemContextInit(&system_context, &system.Context.Data{
        .io = io,
        .world = &world,
        .gpa = gpa,
        .steam_server = &steam_server,
    });

    defer system_table.systemContextDeinit(&system_context);

    var loop_time_tracker: f32 = 0;
    var elapsed_time: f32 = 0;
    var tick: u32 = 0;
    const time_step: f32 = shared.tick_seconds;
    while (true) {
        if (system_context.request_exit) break;
        loop_time_tracker += getDeltaTime(io);
        if (loop_time_tracker < time_step) continue;
        tick += 1;
        elapsed_time += time_step;
        loop_time_tracker -= time_step;

        system_table.systemContextUpdate(&system_context, &.{
            .tick = tick,
            .delta_time = time_step,
            .elapsed_time = elapsed_time,
            .world = &world,
        });

        if (try watcher.reload(io)) {
            system_table.systemContextReload(&system_context, true);
            std.log.debug("system table updated", .{});
            system_table = try .load(&watcher.dynlib.?);
            system_table.systemContextReload(&system_context, false);
        }
    }
    steam_server.handle_packets_future.cancel(io) catch |err| {
        switch (err) {
            error.Canceled => std.log.err("valid error: {s}", .{@errorName(err)}),
            else => {
                std.log.err("err: {s}", .{@errorName(err)});
                return err;
            },
        }
    };
}

pub fn getDeltaTime(io: std.Io) f32 {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const static = struct {
        var previous: ?std.Io.Timestamp = null;
    };

    const now: std.Io.Timestamp = .now(io, .real);
    const prev = static.previous orelse {
        static.previous = now;
        return getDeltaTime(io);
    };

    const dt_ns = prev.durationTo(now);
    static.previous = now;

    return @as(f32, @floatFromInt(dt_ns.nanoseconds)) / 1_000_000_000.0;
}
