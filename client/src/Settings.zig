const Settings = @This();

const std = @import("std");
const Options = @import("Options.zig");
const Controller = @import("system/Controller.zig");

pub const path = "settings.zon";

options: Options = .{},
bindings: Controller.Bindings = Controller.default_bindings,

pub fn load(io: std.Io, gpa: std.mem.Allocator) Settings {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024),
        .of(u8),
        0,
    ) catch return .{};
    defer gpa.free(source);
    return std.zon.parse.fromSlice(Settings, gpa, source, null, .{ .ignore_unknown_fields = true }) catch {
        std.log.warn("{s}: unreadable, using defaults", .{path});
        return .{};
    };
}

pub fn save(io: std.Io, settings: Settings) void {
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    std.zon.stringify.serialize(settings, .{}, &writer) catch return std.log.err("{s}: too big", .{path});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = writer.buffered() }) catch |err|
        std.log.err("{s}: {t}", .{ path, err });
}
