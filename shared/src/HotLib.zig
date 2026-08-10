//! One hot-reloadable library: the function table, the state block it owns, and what it
//! takes to swap a fresh build in. One struct because that is one job — the caller holds
//! a single field and calls straight through it.
//!
//! The library is copied to a scratch path before opening, so a rebuild can overwrite the
//! original while this process still has the old one mapped.
//!
//! A swapped-out build is NEVER closed mid-run, only at deinit. Anything that stored a
//! pointer into it — a registered callback, a vtable — keeps pointing at code that still
//! exists. Closing on swap turns every one of those into a jump into unmapped memory.

const std = @import("std");
const builtin = @import("builtin");
const DynLib = @import("DynLib.zig").DynLib;

const is_windows = builtin.os.tag == .windows;

extern "kernel32" fn CopyFileW(existing: [*:0]const u16, new: [*:0]const u16, fail_if_exists: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) std.os.windows.DWORD;

/// `Api` is a struct of function pointers; its FIELD NAMES are the exported symbol names.
/// Resolving all of them IS the liveness check on a freshly copied library — a partially
/// written file fails a lookup. One field is required: `reload`, the only one HotLib calls
/// itself, either side of a swap, so the library can rebind its globals.
pub fn HotLib(comptime Api: type, comptime Handle: type) type {
    return struct {
        const Self = @This();

        /// By value, beside the handle it is called with: a swap rewrites both at once, so
        /// there is no window where one is fresh and the other stale.
        api: Api,
        /// The state block every call is made against. Left undefined by `init` and set by
        /// the caller straight after, because it comes out of `api`'s own init — which
        /// cannot run until `api` is resolved. Whether the caller allocates it or the
        /// library returns it is the caller's business.
        handle: Handle,

        dynlib: DynLib,
        /// Every build swapped out so far, kept mapped until deinit. See the header.
        retired: std.ArrayList(DynLib),
        gpa: std.mem.Allocator,
        mtime: std.Io.Timestamp,
        dir_path: []const u8,
        source_name: []const u8,
        copy_id: u64,
        process_id: u32,

        pub fn init(comptime library_name: []const u8, gpa: std.mem.Allocator, io: std.Io) !Self {
            const source_name = if (is_windows) library_name ++ ".dll" else "lib" ++ library_name ++ ".so";
            const search_paths: []const [:0]const u8 = &.{
                "../lib/",
                "zig-out/lib/",
                "zig-out/bin/",
                "./",
            };
            const found_path: []const u8 = for (search_paths) |path| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const full_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, source_name }) catch continue;
                if (fileExists(full_path)) break path;
            } else return error.NoLibraryPathFound;

            var self: Self = .{
                .api = undefined,
                .handle = undefined,
                .dynlib = undefined,
                .retired = .empty,
                .gpa = gpa,
                .mtime = .zero,
                .dir_path = found_path,
                .source_name = source_name,
                .copy_id = 0,
                .process_id = if (is_windows) std.os.windows.GetCurrentProcessId() else 0,
            };
            self.dynlib, self.api, self.mtime = try self.open(io);
            return self;
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            _ = io;
            for (self.retired.items) |*old| old.close();
            self.retired.deinit(self.gpa);
            self.dynlib.close();
        }

        pub fn changed(self: *const Self, io: std.Io) bool {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const source_path = std.fmt.bufPrint(&buf, "{s}{s}", .{ self.dir_path, self.source_name }) catch return false;
            const stat = std.Io.Dir.cwd().statFile(io, source_path, .{}) catch return false;
            return stat.mtime.nanoseconds > self.mtime.nanoseconds;
        }

        /// Runs the newest build if there is one. Resolves BEFORE the pre-reload hook, so a
        /// library missing an export leaves the running one untouched rather than
        /// half-applying a hook pair.
        pub fn trySwap(self: *Self, io: std.Io) void {
            if (!self.changed(io)) return;

            const next_dynlib, const next_api, const next_mtime = self.open(io) catch |err| {
                std.log.err("{s}: reload failed, keeping the running build: {t}", .{ self.source_name, err });
                return;
            };

            self.api.reload(self.handle, true);
            self.retired.append(self.gpa, self.dynlib) catch {};
            self.dynlib = next_dynlib;
            self.api = next_api;
            self.mtime = next_mtime;
            self.api.reload(self.handle, false);
            std.log.info("reloaded {s}", .{self.source_name});
        }

        fn open(self: *Self, io: std.Io) !struct { DynLib, Api, std.Io.Timestamp } {
            var source_buf: [std.fs.max_path_bytes]u8 = undefined;
            const source_path = try std.fmt.bufPrint(&source_buf, "{s}{s}", .{ self.dir_path, self.source_name });
            const stat = try std.Io.Dir.cwd().statFile(io, source_path, .{});

            // Two processes on one machine (a client and a --render server, or two clients)
            // must not overwrite each other's copies mid-run.
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
            errdefer dynlib.close();

            var api: Api = undefined;
            inline for (std.meta.fields(Api)) |field| {
                @field(api, field.name) = dynlib.lookup(field.type, field.name) orelse {
                    std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};
                    std.log.err("{s}: symbol {s} missing", .{ self.source_name, field.name });
                    return error.DynlibLookup;
                };
            }

            // Debug keeps the copy on disk: an unlinked file has no DWARF for the panic
            // unwinder, which is why in-lib frames print as "??? in ???".
            if (builtin.mode != .Debug) std.Io.Dir.cwd().deleteFile(io, copy_path) catch {};

            return .{ dynlib, api, stat.mtime };
        }
    };
}

fn wtf16Path(buf: *[std.fs.max_path_bytes]u16, path: []const u8) ![:0]const u16 {
    const len = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], path);
    buf[len] = 0;
    return buf[0..len :0];
}

/// Dir.copyFile picks its copy strategy by matching error values from the io vtable, which
/// misfires across the exe/library boundary and panics — Windows goes through the OS
/// directly, like fileExists; POSIX hand-copies with pure `try` propagation for the same
/// reason.
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

/// Probes through the OS instead of `io`: error values are numbered per compilation, so
/// errors from the host exe's io vtable arrive scrambled inside a hot-reloaded library and
/// cannot be told apart.
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
