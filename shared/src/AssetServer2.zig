const AssetServer = @This();

const builtin = @import("builtin");

const std = @import("std");
const tracy = @import("ztracy");

gpa: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
assets_path: []const u8,

loaders: std.ArrayList(*Loader) = .empty,
watchers: std.ArrayList(Watcher) = .empty,

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,

    root_path: [:0]const u8,
    files: []const []const u8,

    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (loader: *Loader, file: std.Io.File.OpenError!std.Io.File, index: usize) anyerror!void,
        unload: *const fn (loader: *Loader, index: usize) void,
    };
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
    self.* = undefined;
}

pub fn addLoader(self: *AssetServer, loader: *Loader) !void {
    try self.loaders.append(self.gpa, loader);
    const watcher = try self.watchers.addOne(self.gpa);

    const path = try std.Io.Dir.path.joinZ(self.gpa, &.{ self.assets_path, loader.root_path });
    defer self.gpa.free(path);
    watcher.* = try .initAllocator(self.gpa, path);
}

pub fn load(self: *AssetServer) !void {
    const io = self.io;
    for (self.loaders.items) |loader| {
        const loader_root = try self.dir.openDir(io, loader.root_path, .{});
        defer loader_root.close(io);

        for (loader.files, 0..) |file_path, i| {
            const file = loader_root.openFile(io, file_path, .{});
            defer if (file) |f| f.close(io) else |_| {};
            try loader.vtable.load(loader, file, i);
        }
    }
}

pub fn unload(self: *AssetServer) void {
    for (self.loaders.items) |loader| {
        for (0..loader.files.len) |i| {
            loader.vtable.unload(loader, i);
        }
    }
}

/// Checks for modified assets and reloads any that have changed.
pub fn reloadChangedAssets(self: *AssetServer) !void {
    const io = self.io;
    for (self.watchers.items, self.loaders.items) |*watcher, loader| {
        while (try watcher.next()) |event| {
            std.log.info("asset update: {t} {s}", .{ event.action, event.path });
            switch (event.action) {
                .created => {},
                .modified => for (loader.files, 0..) |file_path, i| {
                    if (std.mem.eql(u8, file_path, event.path)) {
                        const loader_root = try self.dir.openDir(io, loader.root_path, .{});
                        defer loader_root.close(io);
                        const file = loader_root.openFile(io, file_path, .{});
                        try loader.vtable.load(loader, file, i);
                        defer if (file) |f| f.close(io) else |_| {};
                        loader.vtable.unload(loader, i);
                        try loader.vtable.load(loader, file, i);
                    }
                },
                .deleted => for (loader.files, 0..) |file_path, i| {
                    if (std.mem.eql(u8, file_path, event.path)) loader.vtable.unload(loader, i);
                },
            }
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

    const InnerType = switch (builtin.os.tag) {
        .linux => Inotify,
        .windows => Windows,
        else => struct {
            pub const init = @compileError("unsupported platform");
            pub const deinit = @compileError("unsupported platform");
            pub const next = @compileError("unsupported platform");
        },
    };

    pub fn init(path: [:0]const u8) !Watcher {
        if (builtin.os.tag == .windows) @compileError("In Windows, use initAllocator instead.");
        return .{ .inner = try .init(path) };
    }

    pub fn initAllocator(gpa: std.mem.Allocator, path: [:0]const u8) !Watcher {
        return switch (builtin.os.tag) {
            .linux => .{ .inner = try .init(path) },
            .windows => .{ .inner = try .init(path, gpa) },
            else => @compileError("unsupported platform"),
        };
    }

    pub fn deinit(self: *Watcher) void {
        self.inner.deinit();
    }

    pub fn next(self: *Watcher) !?Event {
        return self.inner.next();
    }

    const Inotify = struct {
        fd: std.posix.fd_t,
        wd: usize,

        buffer: [4096]u8 = undefined,
        offset: usize = 0,
        length: usize = 0,

        const IN = struct {
            const NONBLOCK = 0x00000800;
            const CLOSE_WRITE = 0x00000008; // Normal file write/close
            const CREATE = 0x00000100; // New file
            const DELETE = 0x00000200; // File deletion
            const MOVED_TO = 0x00000080; // Swapping files / Renaming into place
        };

        pub fn init(path: [:0]const u8) !Inotify {
            const fd = std.posix.system.inotify_init1(IN.NONBLOCK);

            if (fd < 0) return error.InotifyInitFailed;

            const wd = std.posix.system.inotify_add_watch(
                @intCast(fd),
                path.ptr,
                IN.CLOSE_WRITE | IN.CREATE | IN.DELETE | IN.MOVED_TO,
            );

            if (wd < 0) {
                std.posix.close(@intCast(fd));
                return error.InotifyWatchFailed;
            }

            return .{ .fd = @intCast(fd), .wd = @intCast(wd) };
        }
        pub fn deinit(self: *Inotify) void {
            _ = std.posix.system.inotify_rm_watch(self.fd, @intCast(self.wd));
            _ = std.posix.system.close(self.fd);
        }

        pub fn next(self: *Inotify) !?Watcher.Event {
            while (true) {
                if (self.offset >= self.length) {
                    self.length = std.posix.read(
                        self.fd,
                        &self.buffer,
                    ) catch |err| switch (err) {
                        error.WouldBlock => return null,
                        else => return err,
                    };

                    self.offset = 0;
                    if (self.length == 0) return null;
                }

                if (self.offset + @sizeOf(std.posix.system.inotify_event) > self.length) {
                    self.offset = self.length;
                    continue;
                }

                const event: *const std.posix.system.inotify_event = @ptrCast(@alignCast(&self.buffer[self.offset]));

                const name_start = self.offset + @sizeOf(std.posix.system.inotify_event);
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

    // TODO: make it work or smth
    const Windows = struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        handle: std.os.windows.HANDLE,
        buffer: [4096]u8 = undefined,
        offset: usize = 0,
        length: usize = 0,

        pub fn init(root_path: []const u8, allocator: std.mem.Allocator) !Windows {
            const wide_path = try std.unicode.utf8ToUtf16LeAlloc(
                allocator,
                root_path,
            );
            defer allocator.free(wide_path);

            const handle = std.os.windows.kernel32.CreateFileW(
                wide_path.ptr,
                std.os.windows.GENERIC_READ,
                std.os.windows.FILE_SHARE_READ |
                    std.os.windows.FILE_SHARE_WRITE |
                    std.os.windows.FILE_SHARE_DELETE,
                null,
                std.os.windows.OPEN_EXISTING,
                std.os.windows.FILE_FLAG_BACKUP_SEMANTICS,
                null,
            );

            if (handle == std.os.windows.INVALID_HANDLE_VALUE)
                return error.OpenDirectoryFailed;

            return .{
                .allocator = allocator,
                .arena = .init(allocator),
                .handle = handle,
            };
        }

        pub fn deinit(self: *Windows) void {
            std.os.windows.kernel32.CloseHandle(self.handle);
        }

        pub fn next(self: *Windows) !?Watcher.Event {
            const arena = self.arena.allocator();
            while (true) {
                if (self.offset >= self.length) {
                    var bytes_written: u32 = 0;

                    const ok = std.os.windows.kernel32.ReadDirectoryChangesW(
                        self.handle,
                        &self.buffer,
                        self.buffer.len,
                        1, // watch subtree
                        .{
                            .FILE_NOTIFY_CHANGE_FILE_NAME = true,
                            .FILE_NOTIFY_CHANGE_LAST_WRITE = true,
                        },
                        &bytes_written,
                        null,
                        null,
                    );

                    if (ok == 0)
                        return error.ReadDirectoryChangesFailed;

                    self.length = bytes_written;
                    self.offset = 0;
                }

                const info: *std.os.windows.FILE_NOTIFY_INFORMATION =
                    @ptrCast(@alignCast(&self.buffer[self.offset]));

                self.offset += info.NextEntryOffset;

                const name_utf16 = info.FileName[0 .. info.FileNameLength / 2];

                const path = try std.unicode.utf16LeToUtf8Alloc(arena, name_utf16);

                const action: Watcher.Event.Action = switch (info.Action) {
                    1 => .created, // FILE_ACTION_ADDED
                    2 => .deleted, // FILE_ACTION_REMOVED
                    3 => .modified, // FILE_ACTION_MODIFIED
                    4 => .modified, // FILE_ACTION_RENAMED_OLD_NAME
                    5 => .created, // FILE_ACTION_RENAMED_NEW_NAME
                    else => .modified,
                };

                return .{
                    .path = path,
                    .action = action,
                };
            }
        }
    };
};

pub fn main(in2it: std.process.Init) !void {
    const gpa = in2it.gpa;
    const io = in2it.io;

    var asset_server: AssetServer = try .init(gpa, io);
    defer asset_server.deinit();

    var my_custom_loader: MyCustomLoader = .init(asset_server, "stuff", &.{
        "bob1.txt",
        "bob2.txt",
    });

    try asset_server.addLoader(&my_custom_loader.interface);

    try asset_server.load();
    defer asset_server.unload();

    std.log.warn("stuff: {d}", .{my_custom_loader.stuff});

    while (true) {
        try asset_server.reloadChangedAssets();
    }
}

pub const MyCustomLoader = struct {
    interface: Loader,
    stuff: u8 = 0,

    pub fn init(asset_server: AssetServer, root_path: [:0]const u8, files: []const []const u8) MyCustomLoader {
        return .{
            .interface = .{
                .gpa = asset_server.gpa,
                .io = asset_server.io,
                .root_path = root_path,
                .files = files,
                .vtable = &.{
                    .load = MyCustomLoader.load,
                    .unload = MyCustomLoader.unload,
                },
            },
        };
    }

    pub fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
        const self: *MyCustomLoader = @fieldParentPtr("interface", loader);

        const io = loader.io;
        const file_path = loader.files[index];
        const file = try err_file;

        var buffer: [1024]u8 = undefined;
        const len = try file.readPositionalAll(io, &buffer, 0);
        std.log.info("loaded: {s} {d}", .{ file_path, index });
        std.debug.print("{s}\n", .{buffer[0..len]});
        self.stuff += 1;
    }

    pub fn unload(loader: *Loader, index: usize) void {
        const file_name = loader.files[index];
        std.log.info("unloaded \"{s}\" {d}", .{ file_name, index });
    }
};
