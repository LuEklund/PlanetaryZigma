const Settings = @This();

const std = @import("std");
const Options = @import("Options.zig");
const Controller = @import("system/Controller.zig");

pub const path = "settings.zon";

options: Options = .{},
bindings: Controller.Bindings = Controller.default_bindings,

/// On disk bindings are keyed by action name, so adding or removing an action keeps the rest.
const File = struct {
    options: Options = .{},
    bindings: NamedBindings = .{},
};

const no_binding: ?Controller.Binding = null;
const NamedBindings = @Struct(
    .auto,
    null,
    std.meta.fieldNames(Controller.ActionKind),
    &@splat(?Controller.Binding),
    &@splat(.{ .default_value_ptr = &no_binding }),
);

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
    @setEvalBranchQuota(20_000);
    const file = std.zon.parse.fromSlice(File, gpa, source, null, .{ .ignore_unknown_fields = true }) catch {
        std.log.warn("{s}: unreadable, using defaults", .{path});
        return .{};
    };
    var settings: Settings = .{ .options = file.options };
    inline for (comptime std.meta.fieldNames(Controller.ActionKind)) |name| {
        if (@field(file.bindings, name)) |binding| settings.bindings.set(@field(Controller.ActionKind, name), binding);
    }
    return settings;
}

pub fn save(io: std.Io, settings: Settings) void {
    @setEvalBranchQuota(20_000);
    var buffer: [16 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    var file: File = .{ .options = settings.options };
    inline for (comptime std.meta.fieldNames(Controller.ActionKind)) |name| {
        @field(file.bindings, name) = settings.bindings.get(@field(Controller.ActionKind, name));
    }
    std.zon.stringify.serialize(file, .{}, &writer) catch return std.log.err("{s}: too big", .{path});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = writer.buffered() }) catch |err|
        std.log.err("{s}: {t}", .{ path, err });
}
