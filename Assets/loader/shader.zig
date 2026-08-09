const std = @import("std");
const Assets = @import("../Watcher.zig");

/// SPIR-V wants 4-byte alignment; that is the only thing this knows about the bytes.
pub fn read(gpa: std.mem.Allocator, watcher: *Assets, io: std.Io, entry: u32) ![]align(4) u8 {
    const file = try watcher.open(io, entry);
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len: usize = @intCast((try file.stat(io)).size);
    const bytes = try gpa.alignedAlloc(u8, .@"4", len);
    errdefer gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}
