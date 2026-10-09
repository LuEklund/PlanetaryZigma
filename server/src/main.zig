const std = @import("std");
const builtin = @import("builtin");
const System = @import("system");
const shared = @import("shared");
const tracy = @import("ztracy");
const build_options = @import("build_options");
const Window = System.Window;

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
        host_steam_id = std.fmt.parseInt(u64, arg, 10) catch {
            std.log.warn("ignoring unrecognised argument: {s}", .{arg});
            continue;
        };
        break;
    }

    var system_lib: shared.HotLib(System.Api, *anyopaque) = try .init("system_server", gpa, io);
    defer system_lib.deinit(io);

    var window: Window = undefined;
    if (build_options.viewer) {
        try window.open(gpa, init.minimal, .{
            .app_id = "planetary_zigma_server",
            .title = "PlanetaryZigma — server view",
            .size = .{ .width = 854, .height = 480 },
        });
    }
    defer if (build_options.viewer) {
        window.close();
    };

    system_lib.handle = system_lib.api.systemInit(&System.Data{
        .io = io,
        .gpa = gpa,
        .mode = server_mode,
        .host_steam_id = host_steam_id,
        .dev_mode = dev_mode,
        .log_connection_status = init.environ_map.contains("NET"),
        .window = if (build_options.viewer) &window else {},
    }) orelse return error.SystemInit;
    defer system_lib.api.systemDeinit(system_lib.handle);

    while (true) {
        system_lib.trySwap(io);
        if (system_lib.api.systemUpdate(system_lib.handle)) break;
    }
}
