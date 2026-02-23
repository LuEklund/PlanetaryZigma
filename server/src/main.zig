const std = @import("std");
const System = @import("System");
const shared = @import("shared");

pub fn main(init: std.process.Init) !void {
    std.debug.print("server\n", .{});

    var gpa: std.heap.DebugAllocator(.{ .verbose_log = false, .safety = true }) = .init;
    defer _ = gpa.deinit();
    var allocator = gpa.allocator();

    const io = init.io;
    var server = try shared.net.address.listen(io, .{ .reuse_address = true, .mode = .stream });
    defer server.deinit(io);

    var system_watcher: shared.Watcher = try .init("libsystem{s}", io);
    var systems: System = undefined;
    var systemsInit = try system_watcher.lookup(System.InitSystems, "initSystems");
    var systemsDeinit = try system_watcher.lookup(System.DeinitSystems, "deinit");
    var systemsUpdate = try system_watcher.lookup(System.UpdateSystems, "update");

    if (systemsInit(&systems, &allocator) != 0) return error.SystemsInit;
    defer systemsDeinit(&systems, &allocator);
    var count: usize = 0;

    while (true) {
        count += 1;

        systemsUpdate(&systems, 1.0);
        if (try system_watcher.listen()) {
            systemsDeinit(&systems, &allocator);
            try system_watcher.reload();
            systemsInit = try system_watcher.lookup(System.InitSystems, "initSystems");
            systemsDeinit = try system_watcher.lookup(System.DeinitSystems, "deinit");
            systemsUpdate = try system_watcher.lookup(System.UpdateSystems, "update");
            if (systemsInit(&systems, &allocator) != 0) return error.SystemsInit;
        }
        // const stream = try server.accept(io);
        //
        // _ = io.async(handleClient, .{ io, stream });
    }
}

pub fn handleClient(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);

    var stream_writer_buffer: [128]u8 = undefined;
    var stream_writer = stream.writer(io, &stream_writer_buffer);
    const writer = &stream_writer.interface;

    while (true) {
        try writer.print("Hello!", .{});
        try writer.flush();

        _ = try io.sleep(.fromMilliseconds(100), .real);
    }
}
