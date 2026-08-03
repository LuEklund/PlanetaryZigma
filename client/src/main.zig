const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const System = @import("system");
const World = System.World;
const Window = @import("Window");
const tracy = @import("ztracy");
const miniaudio = @import("miniaudio");

pub const std_options: std.Options = .{ .logFn = shared.logFn };

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
    shared.log_io = io;

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

    var watcher: shared.Watcher = try .init("system_client", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var window: Window = undefined;
    const window_zone = tracy.zoneNamed(@src(), "WindowOpen");
    try window.open(gpa, init.minimal, .{
        .app_id = "planetary_zigma",
        .title = "PlanetaryZigma",
        .size = .{ .width = 854, .height = 480 },
    });
    try window.setMinSize(.{ .width = 300, .height = 200 });
    window_zone.end();
    defer window.close();

    var asset_server = try System.AssetServer.init(gpa, init.io);
    defer asset_server.deinit();

    var world: World = try .init(gpa, io);
    defer world.deinit();

    var system_table: System.Table = try .load(&watcher.dynlib.?);

    const ctx_zone = tracy.zoneNamed(@src(), "SystemInit");
    const system: *anyopaque = system_table.systemInit(&System.Data{
        .gpa = gpa,
        .asset_server = &asset_server,
        .window = &window,
        .io = io,
        .world = &world,
        .steam_client = &steam_client,
    }) orelse return error.SystemInit;
    ctx_zone.end();
    defer system_table.systemDeinit(system);

    var accumlated_time: f32 = 0;
    var fps_window_seconds: f32 = 0;
    var fps_window_frames: u32 = 0;
    const time_step: f32 = shared.tick_seconds;
    startup_zone.end();
    while (!window.should_close) {
        tracy.frameMark();
        const delta_time = getDeltaTime(io);
        if (delta_time > 0.1) std.log.warn("main loop stalled {d:.0}ms", .{delta_time * 1000});
        accumlated_time += delta_time;
        fps_window_seconds += delta_time;
        if (accumlated_time < time_step) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            continue;
        }
        accumlated_time -= time_step;
        world.elapsed_time += time_step;
        world.delta_time = time_step;
        fps_window_frames += 1;
        if (fps_window_seconds >= 0.5) {
            world.fps = @as(f32, @floatFromInt(fps_window_frames)) / fps_window_seconds;
            fps_window_frames = 0;
            fps_window_seconds = 0;
        }

        if (system_table.systemUpdate(system, &world)) break;

        // numpad 0-9 toggles to that ring slot's lib version (contiguous enum values)
        const np0 = @intFromEnum(Window.Keyboard.Key.keypad_0);
        for (0..10) |n| {
            if (window.keyboard.get(@enumFromInt(np0 + n)) != .release) continue;
            if (watcher.version(n)) |lib| {
                system_table.systemReload(system, true);
                system_table = try .load(lib);
                system_table.systemReload(system, false);
                std.log.err("switched to version slot {d}", .{n});
            }
        }

        if (try watcher.reload(io)) {
            std.log.err("system table updated", .{});
            system_table.systemReload(system, true);
            system_table = try .load(&watcher.dynlib.?);
            system_table.systemReload(system, false);
        }
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
