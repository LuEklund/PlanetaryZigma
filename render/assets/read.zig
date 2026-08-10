//! Get the bytes. One function for every kind, because reading a file is reading a file —
//! what differs is what you do with them afterwards.

const std = @import("std");

/// 4-byte aligned because SPIR-V needs it and nothing else cares.
pub fn file(gpa: std.mem.Allocator, io: std.Io, folder: std.Io.Dir, path: []const u8) ![]align(4) u8 {
    const handle = try folder.openFile(io, path, .{});
    defer handle.close(io);

    var buffer: [4096]u8 = undefined;
    var reader = handle.reader(io, &buffer);
    const len: usize = @intCast((try handle.stat(io)).size);
    const bytes = try gpa.alignedAlloc(u8, .@"4", len);
    errdefer gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}
