const std = @import("std");
const tracy = @import("ztracy");

gpa: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
mtime: std.Io.Timestamp,
metadata: std.ArrayList(Metadata) = .empty,

pub const Metadata = struct {
    user_data: *anyopaque,
    file_path: []const u8,
    mtime: std.Io.Timestamp,
    callback: Callback,

    pub const Callback = *const fn (*anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) anyerror!void;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, user_data: *anyopaque, file_path: []const u8, callback: Callback) !@This() {
        return .{
            .user_data = user_data,
            .mtime = .now(io, .real),
            .file_path = try gpa.dupe(u8, file_path),
            .callback = callback,
        };
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) !void {
        gpa.free(self.file_path);
    }
};

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    const asset_paths: []const []const u8 = &.{
        "assets",
        "../assets",
        "../../assets",
    };

    const found_path: []const u8 = path: for (asset_paths) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        break :path path;
    } else return error.NoAssetDir;

    const dir = try std.Io.Dir.cwd().openDir(io, found_path, .{ .iterate = true });

    return .{
        .gpa = gpa,
        .io = io,
        .dir = dir,
        .mtime = .now(io, .real),
    };
}

pub fn deinit(self: *@This()) void {
    self.dir.close(self.io);
    for (self.metadata.items) |*meta| {
        try meta.deinit(self.gpa);
    }
    self.metadata.deinit(self.gpa);
    self.* = undefined;
}

pub fn update(self: *@This()) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    for (self.metadata.items) |*metadata| {
        const entry_stat = self.dir.statFile(self.io, metadata.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) continue;
            std.debug.print("error: {any}\nfile: {s}\n", .{ err, metadata.file_path });
            continue;
        };

        if (entry_stat.mtime.nanoseconds > metadata.mtime.nanoseconds + std.time.ns_per_s) {
            std.debug.print("reload asset {s}\n", .{metadata.file_path});
            const file = try self.dir.openFile(self.io, metadata.file_path, .{});

            defer file.close(self.io);
            metadata.callback(metadata.user_data, self.gpa, self.io, file, metadata.file_path) catch |err| {
                std.debug.print("reload failed {s}: {s}, retrying\n", .{ metadata.file_path, @errorName(err) });
                continue;
            };
            metadata.mtime = entry_stat.mtime;
        }
    }
}

pub fn watchAsset(self: *@This(), comptime UserData: type, user_data: *UserData, file_path: []const u8, callback: Metadata.Callback) !void {
    for (self.metadata.items) |metadata| {
        if (std.mem.eql(u8, metadata.file_path, file_path) == true) return;
    }
    try self.metadata.append(
        self.gpa,
        try .init(self.gpa, self.io, user_data, file_path, callback),
    );
}

pub fn loadAsset(self: *@This(), comptime UserData: type, user_data: *UserData, file_path: []const u8, callback: Metadata.Callback) !void {
    var metadata_index: ?usize = null;
    for (self.metadata.items, 0..) |metadata, i| {
        if (std.mem.eql(u8, metadata.file_path, file_path) == true) {
            metadata_index = i;
            break;
        }
    }
    if (metadata_index == null) {
        try self.metadata.append(
            self.gpa,
            try .init(self.gpa, self.io, user_data, file_path, callback),
        );
    }

    std.log.debug("path: {s}", .{file_path});
    const file = try self.dir.openFile(self.io, file_path, .{});
    defer file.close(self.io);
    try callback(user_data, self.gpa, self.io, file, file_path);
}
