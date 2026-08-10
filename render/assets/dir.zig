//! Where the raw files are, relative to wherever the game was launched from. The only place
//! that names a path.

const std = @import("std");

pub fn open(io: std.Io) !std.Io.Dir {
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
