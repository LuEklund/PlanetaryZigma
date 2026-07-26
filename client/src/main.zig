const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const System = @import("system");
const World = System.World;
const yes = @import("yes");
const tracy = @import("ztracy");
const miniaudio = @import("miniaudio");

pub fn main(init: std.process.Init) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    tracy.setThreadName("main");
    const startup_zone = tracy.zoneNamed(@src(), "Startup");
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .stack_trace_frames = 16, .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = if (builtin.mode == .Debug) gpa_impl.allocator() else gpa_impl;
    const io = init.io;

    var eng: miniaudio.ma_engine = undefined;
    if (miniaudio.ma_engine_init(null, &eng) != miniaudio.MA_SUCCESS) return error.MiniaudioFailed;
    defer miniaudio.ma_engine_uninit(&eng);
    // _ = miniaudio.ma_engine_play_sound(&eng, "music.mp3", null);
    // _ = miniaudio.ma_engine_set_volume(&eng, 1);

    if (builtin.mode != .Debug) shared.redirectStderrToFile(io, "client.log");

    const steam_zone = tracy.zoneNamed(@src(), "SteamInit");
    shared.SteamNet.log_connection_status = init.environ_map.contains("NET");
    std.log.info("\n====\nNET = {s}\n====\n", .{if (shared.SteamNet.log_connection_status) "TRUE" else "FALSE"});
    var steam_client: shared.SteamNet.Client = try .init(gpa, io);
    steam_client.handle_packets_future = try io.concurrent(shared.SteamNet.Client.handlePackets, .{&steam_client});
    steam_zone.end();

    defer steam_client.deinit();

    var cross_desktop: yes.Desktop.Cross = try .init(gpa, io, init.minimal);
    defer cross_desktop.deinit();
    const desktop = cross_desktop.desktop();

    var cross_window: yes.Desktop.Cross.Window = .empty(desktop);
    const window = cross_window.interface(desktop);
    const window_size: yes.Window.Size = .{ .width = 854, .height = 480 };
    const window_zone = tracy.zoneNamed(@src(), "WindowOpen");
    try window.open(desktop, .{
        .title = "PlanetaryZigma",
        .size = window_size,
        .resize_policy = .{ .specified = .{
            .min_size = .{ .width = 300, .height = 200 },
        } },
        .surface_type = .vulkan,
    });
    window_zone.end();
    defer window.close(desktop);

    var asset_server = try System.AssetServer.init(gpa, init.io);
    defer asset_server.deinit();

    var world: World = try .init(gpa);
    defer world.deinit();

    var watcher: shared.Watcher = try .init("system_client", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var system_table: System.Table = try .load(&watcher.dynlib.?);

    const ctx_zone = tracy.zoneNamed(@src(), "SystemInit");
    const system: *anyopaque = system_table.systemInit(&System.Data{
        .gpa = gpa,
        .asset_server = &asset_server,
        .desktop = desktop,
        .window = window,
        .io = io,
        .world = &world,
        .steam_client = &steam_client,
    }) orelse return error.SystemInit;
    ctx_zone.end();
    defer system_table.systemDeinit(system);

    var elapsed_time: f32 = 0;
    var accumlated_time: f32 = 0;
    const time_step: f32 = shared.tick_seconds;
    startup_zone.end();
    main_loop: while (true) {
        tracy.frameMark();
        const delta_time = getDeltaTime(io);
        if (delta_time > 0.1) std.log.warn("main loop stalled {d:.0}ms", .{delta_time * 1000});
        accumlated_time += delta_time;
        if (accumlated_time < time_step) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            continue;
        }
        accumlated_time -= time_step;
        while (try window.poll(desktop)) |event| {
            if (system_table.systemUpdate(system, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, &event)) break :main_loop;
            switch (event) {
                .close => break :main_loop,
                .key => |key| {
                    if (key.state == .released) {
                        // numpad 0-9 toggles to that ring slot's lib version (contiguous enum values)
                        const np0 = @intFromEnum(yes.Window.Event.Key.Sym.numpad_0);
                        const sym = @intFromEnum(key.sym);
                        if (sym >= np0 and sym < np0 + 10) {
                            if (watcher.version(sym - np0)) |lib| {
                                system_table.systemReload(system, true);
                                system_table = try .load(lib);
                                system_table.systemReload(system, false);
                                std.log.err("switched to version slot {d}", .{sym - np0});
                            }
                        }
                    }
                },
                else => {},
            }
        }
        if (system_table.systemUpdate(system, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, null)) break :main_loop;

        if (try watcher.reload(io)) {
            std.log.err("system table updated", .{});
            system_table.systemReload(system, true);
            system_table = try .load(&watcher.dynlib.?);
            system_table.systemReload(system, false);
        }

        elapsed_time += time_step;
    }
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
