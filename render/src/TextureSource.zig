//! Decodes textures on THIS side of the boundary and hands pixels to the backend as data.
//! Twin of ShaderSource; see its header for why the vtable is safe here and not in render.so.
//!
//! The skybox cross-split lives here too — it is pixel arithmetic, not GPU work.

const TextureSource = @This();

const std = @import("std");
const Texture = @import("shared").Texture;
const AssetServer = @import("AssetServer.zig");
const Bitmap = @import("asset/Bitmap.zig");
const DrawList = @import("DrawList.zig");

const Loader = AssetServer.Loader;
const channels: u32 = 4;

const Owned = struct {
    /// One block; `faces` are windows into it.
    bytes: []u8,
    faces: [][]const u8,
};

gpa: std.mem.Allocator,
owned: [Texture.paths_capacity]?Owned,
pending: std.ArrayList(DrawList.TextureUpload),
interface: Loader,

pub fn init(self: *TextureSource, gpa: std.mem.Allocator, asset_server: *AssetServer) !void {
    var path_buffer: [Texture.paths_capacity][]const u8 = undefined;
    const texture_paths = Texture.paths(&path_buffer);
    const files = try gpa.alloc([]const u8, texture_paths.len);
    @memcpy(files, texture_paths);

    self.* = .{
        .gpa = gpa,
        .owned = @splat(null),
        .pending = .empty,
        .interface = .{
            .gpa = gpa,
            .io = asset_server.io,
            .root_path = "textures",
            .files = files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
    try asset_server.addLoader(&self.interface);
}

pub fn deinit(self: *TextureSource) void {
    for (&self.owned) |*slot| if (slot.*) |owned| self.free(owned);
    self.pending.deinit(self.gpa);
    self.gpa.free(self.interface.files);
}

pub fn uploads(self: *const TextureSource) []const DrawList.TextureUpload {
    return self.pending.items;
}

pub fn consumed(self: *TextureSource) void {
    self.pending.clearRetainingCapacity();
}

fn free(self: *const TextureSource, owned: Owned) void {
    self.gpa.free(owned.faces);
    self.gpa.free(owned.bytes);
}

fn decodeFile(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !Bitmap {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len: usize = @intCast((try file.stat(io)).size);
    const bytes = try gpa.alloc(u8, len);
    defer gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);

    var decoded: Bitmap = .{};
    var decode_tasks: [1]Bitmap.Task = .{.{ .result = &decoded, .bytes = bytes }};
    try Bitmap.decodeAll(gpa, &decode_tasks);
    if (decoded.err) |err| return err;
    try if (decoded.pixels == null) error.LoadingStbi;
    return decoded;
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *TextureSource = @fieldParentPtr("interface", loader);
    const gpa = self.gpa;
    const fallback_slot: u32 = @intCast(Texture.reserved + index);

    const file = err_file catch |err| {
        std.log.warn("texture textures/{s}: {t} - using fallback", .{ loader.files[index], err });
        return self.pushFallback(fallback_slot);
    };

    var decoded = decodeFile(gpa, loader.io, file) catch |err| {
        std.log.warn("texture textures/{s}: {t} - using fallback", .{ loader.files[index], err });
        return self.pushFallback(fallback_slot);
    };
    defer decoded.deinit();

    const slot: u32 = @intCast(Texture.reserved + index);
    const owned, const width, const height = if (slot == Texture.slot(.skybox_cubemap))
        try splitCross(gpa, decoded)
    else
        try wholeImage(gpa, decoded);

    if (self.owned[index]) |old| {
        // A second reload before the backend drained the first would leave a freed pointer
        // in `pending`, so retarget that row instead of appending another.
        for (self.pending.items) |*upload| {
            if (upload.faces.ptr != old.faces.ptr) continue;
            upload.faces = owned.faces;
            break;
        }
        self.free(old);
    }
    self.owned[index] = owned;

    for (self.pending.items) |*upload| {
        if (upload.slot != slot) continue;
        upload.* = .{ .slot = slot, .width = width, .height = height, .faces = owned.faces };
        return;
    }
    try self.pending.append(gpa, .{ .slot = slot, .width = width, .height = height, .faces = owned.faces });
    std.log.debug("texture slot {d}: textures/{s}", .{ slot, loader.files[index] });
}

/// An empty face list tells the backend to bind its checkerboard for this slot. The skybox
/// is exempt: a 2D fallback cannot stand in for a cube view.
fn pushFallback(self: *TextureSource, slot: u32) !void {
    if (slot == Texture.slot(.skybox_cubemap)) return;
    for (self.pending.items) |*upload| {
        if (upload.slot != slot) continue;
        upload.* = .{ .slot = slot, .width = 0, .height = 0, .faces = &.{} };
        return;
    }
    try self.pending.append(self.gpa, .{ .slot = slot, .width = 0, .height = 0, .faces = &.{} });
}

fn wholeImage(gpa: std.mem.Allocator, decoded: Bitmap) !struct { Owned, u32, u32 } {
    const width: u32 = @intCast(decoded.width);
    const height: u32 = @intCast(decoded.height);
    const bytes = try gpa.dupe(u8, decoded.pixels[0 .. width * height * channels]);
    errdefer gpa.free(bytes);
    const faces = try gpa.alloc([]const u8, 1);
    faces[0] = bytes;
    return .{ .{ .bytes = bytes, .faces = faces }, width, height };
}

/// 4x3 cross layout -> six square faces in Vulkan cubemap order.
fn splitCross(gpa: std.mem.Allocator, decoded: Bitmap) !struct { Owned, u32, u32 } {
    const width: u32 = @intCast(decoded.width);
    const face_size: u32 = @divTrunc(width, 4);
    const face_bytes = face_size * face_size * channels;
    const row_bytes = face_size * channels;

    const bytes = try gpa.alloc(u8, face_bytes * 6);
    errdefer gpa.free(bytes);
    const faces = try gpa.alloc([]const u8, 6);
    errdefer gpa.free(faces);

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
    return .{ .{ .bytes = bytes, .faces = faces }, face_size, face_size };
}

fn unload(loader: *Loader, index: usize) void {
    _ = loader;
    _ = index;
    // Bytes stay owned until the next load replaces them; destroying the GPU image is the
    // backend's job, driven by the next upload for that slot.
}
