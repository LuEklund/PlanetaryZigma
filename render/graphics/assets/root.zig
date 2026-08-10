//! Files on disk to data in memory: has it changed, get the bytes, turn them into something.
//!
//! Nothing in here knows what the data is FOR. No renderer type appears anywhere in it, and
//! it holds no state — the caller owns one entry per file and passes the parts of it these
//! need.

const std = @import("std");

pub const Bitmap = @import("types/Bitmap.zig");
pub const gltf = @import("types/gltf.zig");
pub const Model = @import("types/Model.zig");
pub const Node = @import("types/Node.zig");
pub const AnimationClip = @import("types/AnimationClip.zig");
pub const box = @import("types/box.zig");

/// Where the raw files are, relative to wherever the game was launched from. The only place
/// that names a path.
pub fn openDir(io: std.Io) !std.Io.Dir {
    const candidates: []const [:0]const u8 = &.{ "assets", "../assets", "../../../assets" };
    const found: [:0]const u8 = for (candidates) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        break path;
    } else return error.NoAssetDir;
    return std.Io.Dir.cwd().openDir(io, found, .{ .iterate = true });
}

/// True when the file is newer than `mtime`, which it then advances. A file that cannot be
/// stat'd reads as unchanged rather than as an error: an editor mid-write turns up on the
/// next call instead.
///
/// Start an entry at `.zero` and the first call reports it, which is what makes loading and
/// reloading one code path.
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
