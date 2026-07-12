const std = @import("std");
const builtin = @import("builtin");
const DynLib = @import("DynLib.zig").DynLib;

const is_windows = builtin.os.tag == .windows;

dynlib: ?DynLib = null,
old_dynlib: ?DynLib = null,
dir_path: []const u8,
source_name: []const u8,
mtime: std.Io.Timestamp,
copy_id: u64,
// ring of the last 10 loaded libs, kept mapped (never closed mid-run) so old versions stay callable
versions: [25]?DynLib,
version_count: u64,

pub fn init(comptime library_name: []const u8, io: std.Io) !@This() {
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
        .mtime = .zero,
        .copy_id = 0,
        .versions = @splat(null),
        .version_count = 0,
    };
}

pub fn deinit(self: *@This(), io: std.Io) void {
    _ = io;
    for (&self.versions) |*slot| if (slot.*) |*dynlib| dynlib.close();
}

pub fn load(self: *@This(), io: std.Io) !void {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = try std.fmt.bufPrint(&source_buf, "{s}{s}", .{ self.dir_path, self.source_name });

    const stat = try std.Io.Dir.cwd().statFile(io, source_path, .{});

    self.copy_id += 1;
    var copy_buf: [std.fs.max_path_bytes]u8 = undefined;
    const copy_path = if (is_windows)
        try std.fmt.bufPrint(&copy_buf, "{s}{s}.{d}", .{ self.dir_path, self.source_name, self.copy_id })
    else
        try std.fmt.bufPrint(&copy_buf, "/tmp/{s}.{d}", .{ self.source_name, self.copy_id });

    try std.Io.Dir.cwd().copyFile(source_path, .cwd(), copy_path, io, .{});

    var dynlib = DynLib.open(copy_path) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
        return err;
    };

    if (dynlib.lookup(*const fn () void, "systemContextInit") == null) {
        dynlib.close();
        std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
        return error.SystemContextInitSymbolNotFound;
    }

    std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};

    self.dynlib = dynlib;
    self.mtime = stat.mtime;
    self.versions[self.version_count % self.versions.len] = dynlib;
    self.version_count += 1;
}

// the DynLib in ring slot n (0..9), or null if nothing loaded there yet
pub fn version(self: *@This(), n: usize) ?*DynLib {
    if (n >= self.versions.len) return null;
    if (self.versions[n]) |*lib| return lib;
    return null;
}

pub fn reload(self: *@This(), io: std.Io) !bool {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_path = std.fmt.bufPrint(&source_buf, "{s}{s}", .{ self.dir_path, self.source_name }) catch return false;

    const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch return false;
    if (stat.mtime.nanoseconds <= self.mtime.nanoseconds) return false;

    self.old_dynlib = self.dynlib;
    self.dynlib = null;
    self.load(io) catch {
        self.dynlib = self.old_dynlib;
        self.old_dynlib = null;
        return false;
    };
    self.old_dynlib = null; // ring retains the old lib; never close it mid-run

    std.log.debug("Reloaded dynamic lib: {s} (ring slot {d})", .{ self.source_name, (self.version_count - 1) % self.versions.len });
    return true;
}

pub inline fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) !T {
    const function_pointer = self.dynlib.?.lookup(T, name);
    if (function_pointer == null) return error.DynlibLookup;
    return function_pointer.?;
}
