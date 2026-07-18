const AssetServer = @This();

const builtin = @import("builtin");

const std = @import("std");
const tracy = @import("ztracy");

gpa: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
assets_path: []const u8,

loaders: std.ArrayList(*Loader) = .empty,
// TEMP-COMMENT: linux only — one inotify watcher per loader, rooted at the loader's
// subdirectory (assets/textures, assets/objects, ...). Files sit flat in those dirs, so a
// non-recursive watch per subdir covers everything AND the basename-only inotify event
// paths match loader.files entries directly.
watchers: std.ArrayList(Watcher) = .empty,
// TEMP-COMMENT: windows only — ReadDirectoryChangesW blocks the caller, so windows falls
// back to v1-style mtime polling over each loader's file list (proven approach from the
// old AssetServer). One timestamp slice per loader, parallel to loaders.
file_mtimes: std.ArrayList([]std.Io.Timestamp) = .empty,
// TEMP-COMMENT: linux reload that failed (file mid-write when the event fired) — retried
// every frame until it loads. Windows gets retries for free (mtime only advances on success).
retries: std.ArrayList(Retry) = .empty,

const is_windows = builtin.os.tag == .windows;

const Retry = struct {
    loader_index: usize,
    file_index: usize,
};

pub const Loader = struct {
    root_path: [:0]const u8,
    files: []const []const u8,
    // TEMP-COMMENT: no vtable, no unload — every consumer's unload was a no-op (GPU pools
    // replace in place, deleted files = keep-last-good), and a one-entry vtable is just a
    // function pointer. gpa/io are call parameters, not stored copies.
    load: *const fn (loader: *Loader, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File.OpenError!std.Io.File, index: usize) anyerror!void,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) !AssetServer {
    const asset_paths: []const [:0]const u8 = &.{
        "assets",
        "../assets",
        "../../assets",
    };

    const assets_path: [:0]const u8 = path: for (asset_paths) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        break :path path;
    } else return error.NoAssetDir;

    const dir = try std.Io.Dir.cwd().openDir(io, assets_path, .{ .iterate = true });

    return .{
        .gpa = gpa,
        .io = io,
        .dir = dir,
        .assets_path = assets_path,
    };
}

pub fn deinit(self: *AssetServer) void {
    self.dir.close(self.io);
    self.loaders.deinit(self.gpa);
    for (self.watchers.items) |*watcher| watcher.deinit();
    self.watchers.deinit(self.gpa);
    for (self.file_mtimes.items) |mtimes| self.gpa.free(mtimes);
    self.file_mtimes.deinit(self.gpa);
    self.retries.deinit(self.gpa);
    self.* = undefined;
}

pub fn addLoader(self: *AssetServer, loader: *Loader) !void {
    try self.loaders.append(self.gpa, loader);
    if (is_windows) {
        const mtimes = try self.gpa.alloc(std.Io.Timestamp, loader.files.len);
        @memset(mtimes, .zero);
        try self.file_mtimes.append(self.gpa, mtimes);
    } else {
        const path = try std.Io.Dir.path.joinZ(self.gpa, &.{ self.assets_path, loader.root_path });
        defer self.gpa.free(path);
        const watcher = try self.watchers.addOne(self.gpa);
        watcher.* = try .init(path);
    }
}

pub fn load(self: *AssetServer) !void {
    for (self.loaders.items, 0..) |_, loader_index| {
        const loader = self.loaders.items[loader_index];
        for (0..loader.files.len) |file_index| {
            try self.loadFile(loader_index, file_index);
            if (is_windows) self.file_mtimes.items[loader_index][file_index] = .now(self.io, .real);
        }
    }
}

fn loadFile(self: *AssetServer, loader_index: usize, file_index: usize) !void {
    const io = self.io;
    const loader = self.loaders.items[loader_index];
    const loader_root = try self.dir.openDir(io, loader.root_path, .{});
    defer loader_root.close(io);
    const file = loader_root.openFile(io, loader.files[file_index], .{});
    defer if (file) |open_file| open_file.close(io) else |_| {};
    try loader.load(loader, self.gpa, io, file, file_index);
}

/// Checks for modified assets and reloads any that have changed.
pub fn reloadChangedAssets(self: *AssetServer) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    if (is_windows) return self.pollChangedAssets();

    // TEMP-COMMENT: retry pass first — a reload that failed mid-write gets another shot
    // every frame until the file decodes.
    var retry_index: usize = 0;
    while (retry_index < self.retries.items.len) {
        const retry = self.retries.items[retry_index];
        if (self.loadFile(retry.loader_index, retry.file_index)) |_| {
            _ = self.retries.swapRemove(retry_index);
        } else |_| {
            retry_index += 1;
        }
    }

    for (self.watchers.items, self.loaders.items, 0..) |*watcher, loader, loader_index| {
        while (try watcher.next()) |event| {
            std.log.info("asset update: {t} {s}", .{ event.action, event.path });
            switch (event.action) {
                // TEMP-COMMENT: created/deleted are ignored — the file set is fixed at
                // comptime and deletion = keep-last-good (live GPU state survives).
                .created, .deleted => {},
                // TEMP-COMMENT: was load+load (double-load bug) — now load once; failed
                // loads go to the retry list.
                .modified => for (loader.files, 0..) |file_path, file_index| {
                    if (std.mem.eql(u8, file_path, event.path)) {
                        self.loadFile(loader_index, file_index) catch |err| {
                            std.log.warn("reload failed {s}: {t}, retrying", .{ file_path, err });
                            try self.retries.append(self.gpa, .{ .loader_index = loader_index, .file_index = file_index });
                        };
                    }
                },
            }
        }
    }
}

// TEMP-COMMENT: windows path — same semantics as the old AssetServer: stat every watched
// file, reload when mtime moved forward; mtime only advances on successful load, so
// failures retry automatically next frame.
fn pollChangedAssets(self: *AssetServer) !void {
    const io = self.io;
    for (self.loaders.items, self.file_mtimes.items, 0..) |loader, mtimes, loader_index| {
        const loader_root = self.dir.openDir(io, loader.root_path, .{}) catch continue;
        defer loader_root.close(io);
        for (loader.files, mtimes, 0..) |file_path, *mtime, file_index| {
            const entry_stat = loader_root.statFile(io, file_path, .{}) catch continue;
            if (entry_stat.mtime.nanoseconds <= mtime.nanoseconds + std.time.ns_per_s) continue;
            std.log.debug("reload asset {s}/{s}", .{ loader.root_path, file_path });
            self.loadFile(loader_index, file_index) catch |err| {
                std.log.warn("reload failed {s}: {t}, retrying", .{ file_path, err });
                continue;
            };
            mtime.* = entry_stat.mtime;
        }
    }
}

pub const Watcher = struct {
    inner: InnerType,

    pub const Event = struct {
        path: []const u8,
        action: Action,

        pub const Action = enum {
            modified,
            created,
            deleted,
        };
    };

    // TEMP-COMMENT: windows uses mtime polling (pollChangedAssets) instead of a watcher —
    // ReadDirectoryChangesW is blocking and would freeze the frame loop.
    const InnerType = switch (builtin.os.tag) {
        .linux => Inotify,
        else => struct {},
    };

    pub fn init(path: [:0]const u8) !Watcher {
        if (builtin.os.tag != .linux) @compileError("watcher is linux-only; other platforms poll");
        return .{ .inner = try .init(path) };
    }

    pub fn deinit(self: *Watcher) void {
        if (builtin.os.tag != .linux) return;
        self.inner.deinit();
    }

    pub fn next(self: *Watcher) !?Event {
        if (builtin.os.tag != .linux) return null;
        return self.inner.next();
    }

    const Inotify = struct {
        fd: i32,
        wd: i32,

        buffer: [4096]u8 = undefined,
        offset: usize = 0,
        length: usize = 0,

        const linux = std.os.linux;

        const IN = struct {
            const NONBLOCK = 0x00000800;
            const CLOSE_WRITE = 0x00000008; // Normal file write/close
            const CREATE = 0x00000100; // New file
            const DELETE = 0x00000200; // File deletion
            const MOVED_TO = 0x00000080; // Swapping files / Renaming into place
        };

        pub fn init(path: [:0]const u8) !Inotify {
            const fd_result = linux.inotify_init1(IN.NONBLOCK);
            if (linux.errno(fd_result) != .SUCCESS) return error.InotifyInitFailed;
            const fd: i32 = @intCast(fd_result);

            const wd_result = linux.inotify_add_watch(
                fd,
                path.ptr,
                IN.CLOSE_WRITE | IN.CREATE | IN.DELETE | IN.MOVED_TO,
            );
            if (linux.errno(wd_result) != .SUCCESS) {
                _ = linux.close(fd);
                return error.InotifyWatchFailed;
            }

            return .{ .fd = fd, .wd = @intCast(wd_result) };
        }
        pub fn deinit(self: *Inotify) void {
            _ = linux.inotify_rm_watch(self.fd, self.wd);
            _ = linux.close(self.fd);
        }

        pub fn next(self: *Inotify) !?Watcher.Event {
            while (true) {
                if (self.offset >= self.length) {
                    const read_result = linux.read(self.fd, &self.buffer, self.buffer.len);
                    switch (linux.errno(read_result)) {
                        .SUCCESS => {},
                        .AGAIN => return null,
                        else => return error.InotifyReadFailed,
                    }
                    self.length = read_result;

                    self.offset = 0;
                    if (self.length == 0) return null;
                }

                if (self.offset + @sizeOf(linux.inotify_event) > self.length) {
                    self.offset = self.length;
                    continue;
                }

                const event: *const linux.inotify_event = @ptrCast(@alignCast(&self.buffer[self.offset]));

                const name_start = self.offset + @sizeOf(linux.inotify_event);
                const name_end = name_start + event.len;

                self.offset = name_end;

                var name: []const u8 = &.{};
                if (event.len > 0 and name_start < self.length) {
                    const full_name_slice = self.buffer[name_start..@min(name_end, self.length)];
                    const null_index = std.mem.indexOfScalar(u8, full_name_slice, 0) orelse full_name_slice.len;
                    name = full_name_slice[0..null_index];
                }

                // If a file is swapped in (MOVED_TO) or saved (CLOSE_WRITE), notify as modified
                const action: Watcher.Event.Action = if (event.mask & (IN.CLOSE_WRITE | IN.MOVED_TO) != 0)
                    .modified
                else if (event.mask & IN.CREATE != 0)
                    .created
                else if (event.mask & IN.DELETE != 0)
                    .deleted
                else
                    continue;

                return Watcher.Event{
                    .path = name,
                    .action = action,
                };
            }
        }
    };
};
