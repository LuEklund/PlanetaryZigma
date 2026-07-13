const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const system = @import("system");
const World = system.World;
const yes = @import("yes");
const tracy = @import("ztracy");

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

    const steam_zone = tracy.zoneNamed(@src(), "SteamInit");
    shared.SteamNet.log_connection_status = std.process.Environ.contains(.empty, gpa, "NET") catch false;
    var steam_client: shared.SteamNet.Client = try .init(gpa, io);
    steam_client.handle_packets_future = try io.concurrent(shared.SteamNet.Client.handlePackets, .{&steam_client});
    steam_zone.end();

    defer steam_client.deinit();

    var cross_platform: yes.Platform.Cross = try .init(gpa, io, init.minimal);
    defer cross_platform.deinit();
    const platform = cross_platform.platform();

    var cross_window: yes.Platform.Cross.Window = .empty(platform);
    const window = cross_window.interface(platform);
    const window_size: yes.Window.Size = .{ .width = 854, .height = 480 };
    const window_zone = tracy.zoneNamed(@src(), "WindowOpen");
    try window.open(platform, .{
        .title = "PlanetaryZigma",
        .size = window_size,
        .resize_policy = .{ .specified = .{
            .min_size = .{ .width = 300, .height = 200 },
        } },
        .surface_type = .vulkan,
    });
    window_zone.end();
    defer window.close(platform);

    var asset_server = try shared.AssetServer.init(gpa, init.io);
    defer asset_server.deinit();

    var world: World = try .init(gpa);
    defer world.deinit();

    var watcher: shared.Watcher = try .init("system_client", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var system_context: system.Context = undefined;
    var system_table: system.ffi.Table = try .load(&watcher.dynlib.?);

    const ctx_zone = tracy.zoneNamed(@src(), "SystemContextInit");
    system_table.systemContextInit(&system_context, &system.Context.Data{
        .gpa = gpa,
        .asset_server = &asset_server,
        .platform = platform,
        .window = window,
        .io = io,
        .world = &world,
        .steam_client = &steam_client,
    });
    ctx_zone.end();
    defer system_table.systemContextDeinit(&system_context);

    var elapsed_time: f32 = 0;
    var accumlated_time: f32 = 0;
    const time_step: f32 = shared.tick_seconds;
    startup_zone.end();
    main_loop: while (true) {
        tracy.frameMark();
        const delta_time = getDeltaTime(io);
        if (delta_time > 0.1) std.log.warn("main loop stalled {d:.0}ms", .{delta_time * 1000});
        accumlated_time += delta_time;
        if (accumlated_time < time_step) continue;
        accumlated_time -= time_step;
        while (try window.poll(platform)) |event| {
            const options_was_open = world.options_menu_open;
            system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, &event);
            switch (event) {
                .close => break :main_loop,
                .resize => {
                    try system_context.renderer.resize(gpa, window);
                },
                .key => |key| {
                    if (key.state == .released and key.sym == .escape and !system_context.isInGame() and !options_was_open) break :main_loop;
                    if (key.state == .released) {
                        // numpad 0-9 toggles to that ring slot's lib version (contiguous enum values)
                        const np0 = @intFromEnum(yes.Window.Event.Key.Sym.numpad_0);
                        const sym = @intFromEnum(key.sym);
                        if (sym >= np0 and sym < np0 + 10) {
                            if (watcher.version(sym - np0)) |lib| {
                                system_table.systemContextReload(&system_context, true);
                                system_table = try .load(lib);
                                system_table.systemContextReload(&system_context, false);
                                std.log.err("switched to version slot {d}", .{sym - np0});
                            }
                        }
                    }
                },
                else => {},
            }
            if (system_context.request_exit) break :main_loop;
        }
        system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, null);
        if (system_context.request_exit) break :main_loop;

        if (try watcher.reload(io)) {
            std.log.err("system table updated", .{});
            system_table.systemContextReload(&system_context, true);
            system_table = try .load(&watcher.dynlib.?);
            system_table.systemContextReload(&system_context, false);
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
