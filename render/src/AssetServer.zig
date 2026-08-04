const AssetServer = @This();

const builtin = @import("builtin");

const std = @import("std");
const tracy = @import("ztracy");

gpa: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
assets_path: []const u8,

loaders: std.ArrayList(*Loader) = .empty,
file_mtimes: std.ArrayList([]std.Io.Timestamp) = .empty,
retries: std.ArrayList(Retry) = .empty,

const Retry = struct {
    loader_index: usize,
    file_index: usize,
};

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
    for (self.file_mtimes.items) |mtimes| self.gpa.free(mtimes);
    self.file_mtimes.deinit(self.gpa);
    self.retries.deinit(self.gpa);
    self.* = undefined;
}

pub fn addLoader(self: *AssetServer, loader: *Loader) !void {
    try self.loaders.append(self.gpa, loader);
    const mtimes = try self.gpa.alloc(std.Io.Timestamp, loader.files.len);
    @memset(mtimes, .zero);
    try self.file_mtimes.append(self.gpa, mtimes);
}

pub fn load(self: *AssetServer) !void {
    for (self.loaders.items, 0..) |_, loader_index| {
        const loader = self.loaders.items[loader_index];
        for (0..loader.files.len) |file_index| {
            try self.loadFile(loader_index, file_index);
            self.file_mtimes.items[loader_index][file_index] = .now(self.io, .real);
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
    try loader.vtable.load(loader, file, file_index);
}

/// Checks for modified assets and reloads any that have changed.
pub fn reloadChangedAssets(self: *AssetServer) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();

    var retry_index: usize = 0;
    while (retry_index < self.retries.items.len) {
        const retry = self.retries.items[retry_index];
        if (self.loadFile(retry.loader_index, retry.file_index)) |_| {
            _ = self.retries.swapRemove(retry_index);
        } else |_| {
            retry_index += 1;
        }
    }
    try self.pollChangedAssets();
}

fn pollChangedAssets(self: *AssetServer) !void {
    const io = self.io;
    for (self.loaders.items, self.file_mtimes.items, 0..) |loader, mtimes, loader_index| {
        const loader_root = self.dir.openDir(io, loader.root_path, .{}) catch continue;
        defer loader_root.close(io);
        for (loader.files, mtimes, 0..) |file_path, *mtime, file_index| {
            const entry_stat = loader_root.statFile(io, file_path, .{}) catch continue;
            if (entry_stat.mtime.nanoseconds <= mtime.nanoseconds + std.time.ns_per_s) continue;
            std.log.debug("reload asset {s}/{s}", .{ loader.root_path, file_path });
            loader.vtable.unload(loader, file_index);
            self.loadFile(loader_index, file_index) catch |err| {
                std.log.warn("reload failed {s}: {t}, retrying", .{ file_path, err });
                continue;
            };
            mtime.* = entry_stat.mtime;
        }
    }
}
