const Watcher = @This();

const std = @import("std");
const builtin = @import("builtin");
const DynLib = @import("DynLib.zig").DynLib;

const is_windows = builtin.os.tag == .windows;

dynlib: ?DynLib = null,
old_dynlib: ?DynLib = null,
dir_path: []const u8,
source_name: []const u8,
probe_symbol: [:0]const u8,
mtime: std.Io.Timestamp,
process_id: u32,
copy_id: u64,
versions: [25]?DynLib,
version_count: u64,

pub fn init(comptime library_name: []const u8, comptime probe_symbol: [:0]const u8, io: std.Io) !Watcher {
    const source_name = if (is_windows) library_name ++ ".dll" else "lib" ++ library_name ++ ".so";
    const search_paths: []const [:0]const u8 = &.{
        "../lib/",
        "zig-out/lib/",
        "client/zig-out/lib/",
        "zig-out/bin/",
        "client/zig-out/bin/",
        "./",
    };
    const found_path: []const u8 = path: for (search_paths) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, source_name)) break :path path;
        }
    } else return error.NoLibraryPathFound;

    return .{
        .dir_path = found_path,
        .source_name = source_name,
        .probe_symbol = probe_symbol,
        .mtime = .zero,
        .process_id = if (is_windows) std.os.windows.GetCurrentProcessId() else 0,
        .copy_id = 0,
        .versions = @splat(null),
        .version_count = 0,
    };
}

pub fn deinit(self: *Watcher, io: std.Io) void {
    _ = io;
    for (&self.versions) |*slot| if (slot.*) |*dynlib| dynlib.close();
}

pub fn load(self: *Watcher, io: std.Io) !void {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_buf, "{s}{s}", .{ self.dir_path, self.source_name });

    const stat = try std.Io.Dir.cwd().statFile(io, source_path, .{});

    // Two processes on one machine (a client and a --render server, or two clients)
    // must not overwrite each other's /tmp copies mid-run.
    if (self.copy_id == 0) self.copy_id = @intCast(@mod(std.Io.Timestamp.zero.durationTo(.now(io, .real)).nanoseconds, 1_000_000_000));
    self.copy_id += 1;
    var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const copy_path = if (is_windows)
        try std.fmt.bufPrint(&copy_buf, "{s}{s}.{d}.{d}", .{ self.dir_path, self.source_name, self.process_id, self.copy_id })
    else
        try std.fmt.bufPrint(&copy_buf, "/tmp/{s}.{d}", .{ self.source_name, self.copy_id });

    try std.Io.Dir.cwd().copyFile(source_path, .cwd(), copy_path, io, .{});

    var dynlib = DynLib.open(copy_path) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
        return err;
    };

    if (dynlib.lookup(*const fn () void, self.probe_symbol) == null) {
        dynlib.close();
        std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
        std.log.err("{s}: probe symbol {s} missing", .{ self.source_name, self.probe_symbol });
        return error.ProbeSymbolNotFound;
    }

    // Debug keeps the copy on disk: an unlinked file has no DWARF for the panic
    // unwinder, which is why in-lib frames print as "??? in ???".
    if (builtin.mode != .Debug) std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};

    self.dynlib = dynlib;
    self.mtime = stat.mtime;
    self.versions[self.version_count % self.versions.len] = dynlib;
    self.version_count += 1;
}

/// Indexing the raw slot instead made generation 0 mean "25 builds ago" once the ring
/// wrapped, silently adopting live state into a stale library.
pub fn buildAt(self: *Watcher, generations_back: usize) ?*DynLib {
    if (generations_back >= self.versions.len or generations_back >= self.version_count) return null;
    const slot = (self.version_count - 1 - generations_back) % self.versions.len;
    if (self.versions[slot]) |*lib| return lib;
    return null;
}

pub fn changed(self: *Watcher, io: std.Io) bool {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = std.fmt.bufPrint(&source_buf, "{s}{s}", .{ self.dir_path, self.source_name }) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch return false;
    return stat.mtime.nanoseconds > self.mtime.nanoseconds;
}

pub fn reload(self: *Watcher, io: std.Io) !bool {
    if (!self.changed(io)) return false;

    self.old_dynlib = self.dynlib;
    self.dynlib = null;
    self.load(io) catch {
        self.dynlib = self.old_dynlib;
        self.old_dynlib = null;
        return false;
    };
    self.old_dynlib = null;

    std.log.info("reloaded {s} (build {d})", .{ self.source_name, self.version_count });
    return true;
}

pub inline fn lookup(self: *Watcher, comptime T: type, name: [:0]const u8) !T {
    const function_pointer = self.dynlib.?.lookup(T, name);
    if (function_pointer == null) return error.DynlibLookup;
    return function_pointer.?;
}
