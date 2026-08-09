//! One table of files the game cares about: where each lives, when it last changed, what
//! kind it is, and which slot it belongs to on the other side.
//!
//! Register a file. Ask what moved. Do something with it. That is the whole interface — it
//! calls nobody, so nothing here holds a pointer into a hot-swappable library, and the first
//! poll reports everything, so loading and reloading are one code path.
//!
//! Nothing in this package knows what the data is FOR. No renderer type appears anywhere in
//! it, which is what stops it depending on the thing that consumes it.

const Assets = @This();

const std = @import("std");

pub const Bitmap = @import("types/Bitmap.zig");
pub const gltf = @import("types/gltf.zig");
pub const Model = @import("types/Model.zig");
pub const Node = @import("types/Node.zig");
pub const AnimationClip = @import("types/AnimationClip.zig");
pub const box = @import("types/box.zig");

/// How to turn one file of each kind into data. The reading, not the using.
pub const loader = @import("loader.zig");

pub const Kind = enum { shader, texture, font, model };

pub const Entry = struct {
    /// The directory it lives in — held open so a poll is one stat, not a path walk.
    dir: std.Io.Dir,
    path: []const u8,
    mtime: std.Io.Timestamp,
    kind: Kind,
    /// What this file is on the consumer's side: a shader ordinal, a texture slot, a font
    /// index, a model row. Meaningless here, which is the point.
    index: u32,
};

gpa: std.mem.Allocator,
entries: std.ArrayList(Entry),
/// One open handle per subdirectory, shared by every entry in it.
dirs: std.StringArrayHashMapUnmanaged(std.Io.Dir),

pub fn init(self: *Assets, gpa: std.mem.Allocator) void {
    self.* = .{ .gpa = gpa, .entries = .empty, .dirs = .empty };
}

pub fn deinit(self: *Assets, io: std.Io) void {
    for (self.dirs.values()) |dir| dir.close(io);
    self.dirs.deinit(self.gpa);
    self.entries.deinit(self.gpa);
}

/// `sub_path` is relative to the asset root, `path` relative to that. `index` is whatever
/// the caller needs handed back when this file changes.
pub fn add(
    self: *Assets,
    io: std.Io,
    root: std.Io.Dir,
    sub_path: []const u8,
    path: []const u8,
    kind: Kind,
    index: u32,
) !void {
    const dir = try self.openSub(io, root, sub_path);
    try self.entries.append(self.gpa, .{
        .dir = dir,
        .path = path,
        .mtime = .zero,
        .kind = kind,
        .index = index,
    });
}

fn openSub(self: *Assets, io: std.Io, root: std.Io.Dir, sub_path: []const u8) !std.Io.Dir {
    const slot = try self.dirs.getOrPut(self.gpa, sub_path);
    if (!slot.found_existing) slot.value_ptr.* = try root.openDir(io, sub_path, .{});
    return slot.value_ptr.*;
}

/// Entry indices whose file is newer than the last poll. A file that cannot be stat'd is
/// skipped rather than reported: an editor mid-write shows up on the next poll instead.
pub fn poll(self: *Assets, io: std.Io, out: []u32) []const u32 {
    var found: usize = 0;
    for (self.entries.items, 0..) |*entry, index| {
        if (found == out.len) break;
        const stat = entry.dir.statFile(io, entry.path, .{}) catch continue;
        if (stat.mtime.nanoseconds <= entry.mtime.nanoseconds) continue;
        entry.mtime = stat.mtime;
        out[found] = @intCast(index);
        found += 1;
    }
    return out[0..found];
}

/// Opening is separate from polling so a caller wanting the bytes another way — a memory
/// map, a different thread — is not forced through here.
pub fn open(self: *Assets, io: std.Io, entry: u32) std.Io.File.OpenError!std.Io.File {
    const row = self.entries.items[entry];
    return row.dir.openFile(io, row.path, .{});
}

/// Where the raw files are, relative to wherever the game was launched from. The only thing
/// in this package that names a path.
pub fn openDir(io: std.Io) !std.Io.Dir {
    const candidates: []const [:0]const u8 = &.{ "Assets", "../Assets", "../../../Assets" };
    const found: [:0]const u8 = for (candidates) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        break path;
    } else return error.NoAssetDir;
    return std.Io.Dir.cwd().openDir(io, found, .{ .iterate = true });
}
