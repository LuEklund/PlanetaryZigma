const std = @import("std");

pub const Bitmap = @import("types/Bitmap.zig");
pub const gltf = @import("types/gltf.zig");
pub const Model = @import("types/Model.zig");
pub const Node = @import("types/Node.zig");
pub const AnimationClip = @import("types/AnimationClip.zig");

pub fn findRoot(io: std.Io) ![:0]const u8 {
    const candidates: []const [:0]const u8 = &.{ "assets", "../assets", "../../../assets" };
    for (candidates) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |err| {
            std.log.info("assets: not at {s}: {t}", .{ path, err });
            continue;
        };
        dir.close(io);
        std.log.info("assets: using {s}", .{path});
        return path;
    }
    std.log.err("assets: no candidate dir found from cwd", .{});
    return error.NoAssetDir;
}

pub fn openDir(io: std.Io) !std.Io.Dir {
    return std.Io.Dir.cwd().openDir(io, try findRoot(io), .{ .iterate = true });
}

pub fn changed(io: std.Io, dir: std.Io.Dir, path: []const u8, mtime: *std.Io.Timestamp) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    if (stat.mtime.nanoseconds <= mtime.nanoseconds) return false;
    mtime.* = stat.mtime;
    return true;
}

/// 4-byte aligned because SPIR-V needs it and nothing else cares.
pub fn read(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]align(4) u8 {
    const handle = try dir.openFile(io, path, .{});
    defer handle.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = handle.reader(io, &buffer);
    const len: usize = @intCast((try handle.stat(io)).size);
    const bytes = try gpa.alignedAlloc(u8, .@"4", len);
    errdefer gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}
