const Shaders = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");
const assets = @import("assets/root.zig");

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

const Entry = struct {
    path: []const u8,
    mtime: std.Io.Timestamp,
};

dir: std.Io.Dir,
entries: std.ArrayList(Entry),

/// Added in enum order, so an entry IS the `Shader.Kind` — nothing comes back to name.
pub fn init(gpa: std.mem.Allocator, io: std.Io) !Shaders {
    const root = try assets.openDir(io);
    defer root.close(io);
    var self: Shaders = .{ .dir = try root.openDir(io, "shaders", .{}), .entries = .empty };
    errdefer self.deinit(gpa, io);

    for (std.enums.values(contract.Shader.Kind)) |kind| _ = try self.add(gpa, contract.Shader.get(kind).path);
    return self;
}

pub fn deinit(self: *Shaders, gpa: std.mem.Allocator, io: std.Io) void {
    self.dir.close(io);
    self.entries.deinit(gpa);
}

pub fn add(self: *Shaders, gpa: std.mem.Allocator, path: []const u8) !u32 {
    const kind: u32 = @intCast(self.entries.items.len);
    try self.entries.append(gpa, .{ .path = path, .mtime = .zero });
    return kind;
}

pub fn update(self: *Shaders, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    for (self.entries.items, 0..) |*entry, kind| {
        if (!assets.changed(io, self.dir, entry.path, &entry.mtime)) continue;
        const spirv = try assets.read(gpa, io, self.dir, entry.path);
        defer gpa.free(spirv);
        renderer.api.uploadShader(renderer.handle, @intCast(kind), spirv.ptr, spirv.len);
    }
}
