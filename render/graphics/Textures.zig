const Textures = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("renderer_contract");
const assets = @import("assets/root.zig");
const Bitmap = @import("assets/types/Bitmap.zig");

const channels: u32 = 4;

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

const Entry = struct {
    path: []const u8,
    mtime: std.Io.Timestamp,
    handle: contract.TextureHandle,
};

dir: std.Io.Dir,
entries: std.ArrayList(Entry),
crosshair_entry: u32,
shoot_entry: u32,
spread_entry: u32,
icon_entries: std.EnumArray(shared.Item.Kind, u32),

pub fn init(gpa: std.mem.Allocator, io: std.Io) !Textures {
    const root = try assets.openDir(io);
    defer root.close(io);
    var self: Textures = .{
        .dir = try root.openDir(io, "textures", .{}),
        .entries = .empty,
        .crosshair_entry = 0,
        .shoot_entry = 0,
        .spread_entry = 0,
        .icon_entries = .initFill(0),
    };
    errdefer self.deinit(gpa, io);

    self.crosshair_entry = try self.add(gpa, "crosshair.png");
    self.shoot_entry = try self.add(gpa, "shoot.png");
    self.spread_entry = try self.add(gpa, "spread.png");
    for (std.enums.values(shared.Item.Kind)) |item| {
        self.icon_entries.set(item, try self.add(gpa, shared.Item.icon_paths[@intFromEnum(item)]["textures/".len..]));
    }
    return self;
}

pub fn deinit(self: *Textures, gpa: std.mem.Allocator, io: std.Io) void {
    self.dir.close(io);
    self.entries.deinit(gpa);
}

pub fn add(self: *Textures, gpa: std.mem.Allocator, path: []const u8) !u32 {
    const entry: u32 = @intCast(self.entries.items.len);
    try self.entries.append(gpa, .{ .path = path, .mtime = .zero, .handle = .missing });
    return entry;
}

pub fn get(self: *const Textures, item: shared.Item.Kind) contract.TextureHandle {
    return self.entries.items[self.icon_entries.get(item)].handle;
}

pub fn crosshair(self: *const Textures) contract.TextureHandle {
    return self.entries.items[self.crosshair_entry].handle;
}

pub fn shoot(self: *const Textures) contract.TextureHandle {
    return self.entries.items[self.shoot_entry].handle;
}

pub fn spread(self: *const Textures) contract.TextureHandle {
    return self.entries.items[self.spread_entry].handle;
}

pub fn update(self: *Textures, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    for (self.entries.items) |*entry| {
        if (!assets.changed(io, self.dir, entry.path, &entry.mtime)) continue;
        const bytes = try assets.read(gpa, io, self.dir, entry.path);
        defer gpa.free(bytes);

        var decoded = decode(gpa, bytes) catch |err| {
            std.log.warn("texture {s}: {t}", .{ entry.path, err });
            continue;
        };
        defer decoded.deinit(gpa);
        const uploaded = renderer.api.uploadImage(renderer.handle, &.{
            .width = decoded.width,
            .height = decoded.height,
            .pixels = decoded.pixels,
            .r8 = false,
            .mips = false,
            .mag_linear = true,
            .min_linear = true,
        });
        if (uploaded == .missing) {
            std.log.err("upload texture {s}: keeping the one already bound", .{entry.path});
            continue;
        }
        if (entry.handle != .missing) renderer.api.freeImage(renderer.handle, entry.handle);
        entry.handle = uploaded;
    }
}

const Decoded = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *Decoded, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    var decoded = try Bitmap.one(gpa, bytes);
    defer decoded.deinit();
    const width: u32 = @intCast(decoded.width);
    const height: u32 = @intCast(decoded.height);
    return .{
        .pixels = try gpa.dupe(u8, decoded.pixels[0 .. width * height * channels]),
        .width = width,
        .height = height,
    };
}
