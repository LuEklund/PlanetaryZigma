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
    const gpa = if (builtin.mode == .Debug) gpa_impl.allocator() else gpa_impl;
    const io = init.io;

    if (builtin.mode != .Debug) shared.redirectStderrToFile(io, "server.log");

    shared.SteamNet.log_connection_status = init.environ_map.contains("NET");
    std.log.info("\n====\nNET = {s}\n====\n", .{if (shared.SteamNet.log_connection_status) "TRUE" else "FALSE"});

    var args_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iterator.deinit();
    _ = args_iterator.next();
    var host_steam_id: u64 = 0;
    var dev_mode = false;
    var server_mode: shared.SteamNet.Server.Mode = .steam_p2p;
    while (args_iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "--local-singleplayer")) {
            server_mode = .local_singleplayer;
            host_steam_id = 0;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dev")) {
            dev_mode = true;
            continue;
        }
        host_steam_id = std.fmt.parseInt(u64, arg, 10) catch continue;
        break;
    }

    var steam_server: shared.SteamNet.Server = try .init(gpa, io, .{
        .mode = server_mode,
        .host_steam_id = host_steam_id,
    });
    defer steam_server.deinit();
    steam_server.handle_packets_future = try io.concurrent(shared.SteamNet.Server.handlePackets, .{&steam_server});

    var watcher: shared.Watcher = try .init("system_server", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var world: World = try .init(gpa, dev_mode);
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
        const delta_time = getDeltaTime(io);
        if (delta_time > 0.1) std.log.warn("main loop stalled {d:.0}ms", .{delta_time * 1000});
        loop_time_tracker += delta_time;
        if (loop_time_tracker < time_step) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            continue;
        }
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
        std.log.err("packet pump exit: {s}", .{@errorName(err)});
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
