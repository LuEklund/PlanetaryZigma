const Watcher = @This();

const std = @import("std");
const builtin = @import("builtin");
const DynLib = @import("DynLib.zig").DynLib;

const is_windows = builtin.os.tag == .windows;

extern "kernel32" fn CopyFileW(existing: [*:0]const u16, new: [*:0]const u16, fail_if_exists: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) std.os.windows.DWORD;

fn wtf16Path(buf: *[std.fs.max_path_bytes]u16, path: []const u8) ![:0]const u16 {
    const len = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], path);
    buf[len] = 0;
    return buf[0..len :0];
}

/// Dir.copyFile picks its copy strategy by matching error values from the io
/// vtable, which misfires across the exe/library boundary and panics — Windows
/// goes through the OS directly, like fileExists; POSIX hand-copies with pure
/// `try` propagation for the same reason.
fn copyFile(source_path: []const u8, copy_path: []const u8, io: std.Io) !void {
    if (is_windows) {
        var src_buf: [std.fs.max_path_bytes]u16 = undefined;
        var dst_buf: [std.fs.max_path_bytes]u16 = undefined;
        const src_w = try wtf16Path(&src_buf, source_path);
        const dst_w = try wtf16Path(&dst_buf, copy_path);
        if (CopyFileW(src_w.ptr, dst_w.ptr, .FALSE) == .FALSE) return error.CopyFailed;
    } else {
        const source = try std.Io.Dir.cwd().openFile(io, source_path, .{});
        defer source.close(io);
        const copy = try std.Io.Dir.cwd().createFile(io, copy_path, .{});
        defer copy.close(io);
        var offset: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const read_len = try source.readPositionalAll(io, &buffer, offset);
            if (read_len == 0) break;
            try copy.writePositionalAll(io, buffer[0..read_len], offset);
            offset += read_len;
            if (read_len < buffer.len) break;
        }
    }
}

/// Probes through the OS instead of `io`: error values are numbered per
/// compilation, so errors from the host exe's io vtable arrive scrambled
/// inside a hot-reloaded library and cannot be told apart.
fn fileExists(path: []const u8) bool {
    if (is_windows) {
        var buf: [std.fs.max_path_bytes]u16 = undefined;
        const path_w = wtf16Path(&buf, path) catch return false;
        return GetFileAttributesW(path_w.ptr) != std.os.windows.INVALID_FILE_ATTRIBUTES;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(buf[0..path.len :0], std.c.F_OK) == 0;
}

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

pub fn init(comptime library_name: []const u8, comptime probe_symbol: [:0]const u8) !Watcher {
    const source_name = if (is_windows) library_name ++ ".dll" else "lib" ++ library_name ++ ".so";
    const search_paths: []const [:0]const u8 = &.{
        "../lib/",
        "zig-out/lib/",
        "client/zig-out/lib/",
        "zig-out/bin/",
        "client/zig-out/bin/",
        "./",
    };
    const found_path: []const u8 = for (search_paths) |path| {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, source_name }) catch continue;
        if (fileExists(full_path)) break path;
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

    try copyFile(source_path, copy_path, io);

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
