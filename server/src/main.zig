const std = @import("std");
const builtin = @import("builtin");
const System = @import("system");
const shared = @import("shared");
const tracy = @import("ztracy");
const World = System.World;
const build_options = @import("build_options");
const Window = System.Window;
const nz = shared.numz;

pub const std_options: std.Options = .{ .logFn = shared.logFn };

pub fn main(init: std.process.Init) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = if (builtin.mode == .Debug) gpa_impl.allocator() else gpa_impl;
    const io = init.io;
    shared.log_io = io;

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

    var system_lib: shared.HotLib(System.ffi.Table, *System, "systemInit", "systemReload") = try .init("system_server", io);
    defer system_lib.deinit(io);

    var world: World = try .init(gpa, dev_mode);
    defer world.deinit();

    var window: Window = undefined;
    var asset_server: System.AssetServer = undefined;
    if (build_options.render) {
        try window.open(gpa, init.minimal, .{
            .app_id = "planetary_zigma_server",
            .title = "PlanetaryZigma — server view",
            .size = .{ .width = 854, .height = 480 },
        });
        asset_server = try .init(gpa, io);
    }
    defer if (build_options.render) {
        asset_server.deinit();
        window.close();
    };

    var system_instance: System = undefined;

    if (!system_lib.symbols.systemInit(&system_instance, &System.Data{
        .io = io,
        .world = &world,
        .gpa = gpa,
        .steam_server = &steam_server,
        .window = if (build_options.render) &window else {},
        .asset_server = if (build_options.render) &asset_server else {},
    })) return error.SystemInit;

    defer system_lib.symbols.systemDeinit(&system_instance);

    var loop_time_tracker: f32 = 0;
    const time_step: f32 = shared.tick_seconds;
    while (true) {
        if (system_instance.request_exit) break;
        const delta_time = getDeltaTime(io);
        if (delta_time > 0.1) std.log.warn("main loop stalled {d:.0}ms", .{delta_time * 1000});
        loop_time_tracker += delta_time;
        if (loop_time_tracker < time_step) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            continue;
        }
        world.tick += 1;
        world.elapsed_time += time_step;
        world.delta_time = time_step;
        loop_time_tracker -= time_step;

        system_lib.symbols.systemUpdate(&system_instance, &world);

        if (system_lib.hasNewBuild(io)) {
            system_lib.swap(io, &system_instance) catch |err| std.log.err("system swap: {s}", .{@errorName(err)});
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
