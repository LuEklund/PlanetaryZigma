//! The one cubemap: six faces off a 4x3 cross. The backend puts it on the sky rather than in
//! the texture table, so no handle comes back and nobody can name it.

const Skybox = @This();

const std = @import("std");
const shared = @import("shared");
const contract = @import("contract");
const assets = @import("assets/root.zig");
const Bitmap = @import("assets/types/Bitmap.zig");

const channels: u32 = 4;

const RenderLib = shared.HotLib(contract.Api, *anyopaque);

dir: std.Io.Dir,
path: []const u8,
mtime: std.Io.Timestamp,

pub fn init(io: std.Io) !Skybox {
    const root = try assets.openDir(io);
    defer root.close(io);
    return .{
        .dir = try root.openDir(io, "textures", .{}),
        .path = "skybox_cubemap.png",
        .mtime = .zero,
    };
}

pub fn deinit(self: *Skybox, io: std.Io) void {
    self.dir.close(io);
}

pub fn update(self: *Skybox, gpa: std.mem.Allocator, io: std.Io, renderer: *const RenderLib) !void {
    if (!assets.changed(io, self.dir, self.path, &self.mtime)) return;
    const bytes = try assets.read(gpa, io, self.dir, self.path);
    defer gpa.free(bytes);

    var faces = cross(gpa, bytes) catch |err| {
        std.log.warn("skybox {s}: {t} - the sky keeps what it had", .{ self.path, err });
        return;
    };
    defer faces.deinit(gpa);
    renderer.api.uploadSkybox(renderer.handle, &.{ .size = faces.size, .faces = faces.faces });
}

/// Six square faces in Vulkan order, all windows into one block — which is why freeing goes
/// through `deinit`: releasing a face would release part of a block, not the block.
const Cubemap = struct {
    block: []u8,
    faces: [6][]const u8,
    size: u32,

    pub fn deinit(self: *Cubemap, gpa: std.mem.Allocator) void {
        gpa.free(self.block);
        self.* = undefined;
    }
};

fn cross(gpa: std.mem.Allocator, file_bytes: []const u8) !Cubemap {
    var decoded = try Bitmap.one(gpa, file_bytes);
    defer decoded.deinit();

    const width: u32 = @intCast(decoded.width);
    const face_size: u32 = @divTrunc(width, 4);
    const face_bytes = face_size * face_size * channels;
    const row_bytes = face_size * channels;

    const bytes = try gpa.alloc(u8, face_bytes * 6);
    errdefer gpa.free(bytes);
    var faces: [6][]const u8 = undefined;

    for (0..6) |face| {
        var x_start: u32, var y_start: u32 = switch (face) {
            0 => .{ 2, 1 },
            1 => .{ 0, 1 },
            2 => .{ 1, 0 },
            3 => .{ 1, 2 },
            4 => .{ 1, 1 },
            5 => .{ 3, 1 },
            else => unreachable,
        };
        x_start *= face_size;
        y_start *= face_size;

        const target = bytes[face * face_bytes ..][0..face_bytes];
        for (0..face_size) |y| {
            const dst = y * row_bytes;
            const src = ((y_start + y) * width + x_start) * channels;
            @memcpy(target[dst..][0..row_bytes], decoded.pixels[src..][0..row_bytes]);
        }
        faces[face] = target;
    }
    return .{ .block = bytes, .faces = faces, .size = face_size };
}
