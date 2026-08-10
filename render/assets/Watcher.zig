//! One directory, the files in it worth watching, and which of them changed since you last
//! asked.
//!
//! It calls nobody and knows nothing about what a file holds. One per kind, so the caller's
//! loop has one thing to do with every row it gets back and this needs no tag to sort them.

const Watcher = @This();

const std = @import("std");
const dir = @import("dir.zig");

const Entry = struct {
    path: []const u8,
    mtime: std.Io.Timestamp,
};

gpa: std.mem.Allocator,
/// The one directory these files live in, held open so a poll is a stat and not a path walk.
handle: std.Io.Dir,
entries: std.ArrayList(Entry),
/// Refilled by every `poll`, so the caller needs no buffer and no idea how many there are.
changed: std.ArrayList(u32),

pub fn init(gpa: std.mem.Allocator, io: std.Io, sub_path: []const u8) !Watcher {
    const root = try dir.open(io);
    defer root.close(io);
    return .{
        .gpa = gpa,
        .handle = try root.openDir(io, sub_path, .{}),
        .entries = .empty,
        .changed = .empty,
    };
}

pub fn deinit(self: *Watcher, io: std.Io) void {
    self.handle.close(io);
    self.entries.deinit(self.gpa);
    self.changed.deinit(self.gpa);
}

/// The row number is the caller's to keep: it is what comes back from `poll`, and what
/// `path` takes.
pub fn add(self: *Watcher, file: []const u8) !void {
    try self.entries.append(self.gpa, .{ .path = file, .mtime = .zero });
}

pub fn path(self: *const Watcher, row: u32) []const u8 {
    return self.entries.items[row].path;
}

/// Every row whose file is newer than the last poll. A file that cannot be stat'd is skipped
/// rather than reported: an editor mid-write shows up on the next poll instead.
///
/// Valid until the next poll. The first one reports everything, which is what makes loading
/// and reloading the same code path.
pub fn poll(self: *Watcher, io: std.Io) []const u32 {
    self.changed.clearRetainingCapacity();
    for (self.entries.items, 0..) |*entry, row| {
        const stat = self.handle.statFile(io, entry.path, .{}) catch continue;
        if (stat.mtime.nanoseconds <= entry.mtime.nanoseconds) continue;
        entry.mtime = stat.mtime;
        self.changed.append(self.gpa, @intCast(row)) catch return self.changed.items;
    }
    return self.changed.items;
}
