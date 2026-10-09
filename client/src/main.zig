const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const System = @import("system");
const Window = @import("Window");
const tracy = @import("ztracy");

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

    if (builtin.mode != .Debug) shared.redirectStderrToFile(io, "client.log");

    var system_lib: shared.HotLib(System.Api, *anyopaque) = try .init("system_client", gpa, io);
    defer system_lib.deinit(io);

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

    const ctx_zone = tracy.zoneNamed(@src(), "SystemInit");
    system_lib.handle = system_lib.api.systemInit(&System.Data{
        .gpa = gpa,
        .window = &window,
        .io = io,
        .log_connection_status = init.environ_map.contains("NET"),
        .discord_dir = init.environ_map.get("XDG_RUNTIME_DIR"),
        .autostart = init.environ_map.get("PZ_AUTOSTART"),
    }) orelse return error.SystemInit;
    ctx_zone.end();
    defer system_lib.api.systemDeinit(system_lib.handle);

    startup_zone.end();
    while (!window.should_close) {
        system_lib.trySwap(io);
        if (system_lib.api.systemUpdate(system_lib.handle)) break;
    }
}
