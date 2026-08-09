const TextureLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const shared = @import("shared");
const entity = shared.entity;
const AssetServer = @import("../../AssetServer.zig");
const Loader = AssetServer.Loader;
const Image = @import("../Vulkan/Image.zig");
const Bitmap = @import("../../asset/Bitmap.zig");
const TextureTable = @import("TextureTable.zig");
const Texture = @import("shared").Texture;
const check = @import("../Vulkan/utils.zig").check;

table: *TextureTable,
blank: Image,
missing: Image,
skybox: ?Image,
images: [Texture.paths_capacity]?Image,
interface: Loader,

pub fn init(self: *TextureLoader, gpa: std.mem.Allocator, asset_server: *AssetServer, table: *TextureTable) !void {
    var path_buffer: [Texture.paths_capacity][]const u8 = undefined;
    const texture_paths = Texture.paths(&path_buffer);
    const files = try gpa.alloc([]const u8, texture_paths.len);
    @memcpy(files, texture_paths);

    var blank: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = 1, .height = 1, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    var white: [4]u8 = .{ 255, 255, 255, 255 };
    try blank.uploadDataToImage(table.vma, table.device, &white, 4, 0);

    var missing: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = 8, .height = 8, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    var checkerboard: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        const magenta: bool = (x + y) % 2 == 0;
        checkerboard[(y * 8 + x) * 4 + 0] = if (magenta) 255 else 0;
        checkerboard[(y * 8 + x) * 4 + 1] = 0;
        checkerboard[(y * 8 + x) * 4 + 2] = if (magenta) 255 else 0;
        checkerboard[(y * 8 + x) * 4 + 3] = 255;
    };
    try missing.uploadDataToImage(table.vma, table.device, &checkerboard, checkerboard.len, 0);

    table.registerEmpty(blank.vk_imageview, table.samplers.items[0]);
    table.write(Texture.slot(.missing), missing.vk_imageview, table.samplers.items[0]);

    self.* = .{
        .table = table,
        .blank = blank,
        .missing = missing,
        .skybox = null,
        .images = @splat(null),
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

pub fn deinit(self: *TextureLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.interface.files.len) |index| unload(&self.interface, index);
    if (self.skybox) |*skybox| skybox.deinit(self.table.vma, self.table.device);
    self.blank.deinit(self.table.vma, self.table.device);
    self.missing.deinit(self.table.vma, self.table.device);
    gpa.free(self.interface.files);
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
    const self: *TextureLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const table = self.table;

    const file = try err_file;
    unload(&self.interface, index);

    var decoded = try decodeFile(gpa, loader.io, file);
    defer decoded.deinit();

    if (Texture.reserved + index == Texture.slot(.skybox_cubemap)) return self.loadSkybox(gpa, decoded);

    var image: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = @intCast(decoded.width), .height = @intCast(decoded.height), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer image.deinit(table.vma, table.device);
    try image.uploadDataToImage(table.vma, table.device, decoded.pixels, 4, 0);

    self.images[index] = image;
    table.write(Texture.reserved + index, image.vk_imageview, table.samplers.items[0]);
    std.log.debug("texture slot {d}: textures/{s}", .{ Texture.reserved + index, loader.files[index] });
}

fn loadSkybox(self: *TextureLoader, gpa: std.mem.Allocator, decoded: Bitmap) !void {
    const table = self.table;
    const width: u32 = @intCast(decoded.width);
    const face_size: u32 = @divTrunc(width, 4);

    var cubemap: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = face_size, .height = face_size, .depth = 1 },
        .cube_map,
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer cubemap.deinit(table.vma, table.device);

    const channels: u32 = 4;
    const row_bytes = face_size * channels;
    const data = try gpa.alloc(u8, face_size * face_size * channels);
    defer gpa.free(data);
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

        for (0..face_size) |y| {
            const dst = y * row_bytes;
            const src = ((y_start + y) * width + x_start) * channels;
            @memcpy(data[dst..][0..row_bytes], decoded.pixels[src..][0..row_bytes]);
        }

        try cubemap.uploadDataToImage(table.vma, table.device, data.ptr, channels, @intCast(face));
    }

    if (self.skybox) |*old| {
        check(c.vkDeviceWaitIdle(table.device.handle)) catch {};
        old.deinit(table.vma, table.device);
    }
    self.skybox = cubemap;
    table.writeSkybox(cubemap.vk_imageview, table.samplers.items[0]);
}

fn unload(loader: *Loader, index: usize) void {
    const self: *TextureLoader = @fieldParentPtr("interface", loader);
    const table = self.table;
    var image = self.images[index] orelse return;
    check(c.vkDeviceWaitIdle(table.device.handle)) catch {};
    table.write(Texture.reserved + index, self.missing.vk_imageview, table.samplers.items[0]);
    image.deinit(table.vma, table.device);
    self.images[index] = null;
}
