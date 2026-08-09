const TextureLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const Image = @import("../Vulkan/Image.zig");
const DrawList = @import("render").DrawList;
const TextureTable = @import("TextureTable.zig");
const Texture = @import("shared").Texture;
const check = @import("../Vulkan/utils.zig").check;

gpa: std.mem.Allocator,
table: *TextureTable,
blank: Image,
missing: Image,
skybox: ?Image,
images: [Texture.paths_capacity]?Image,

pub fn init(self: *TextureLoader, gpa: std.mem.Allocator, table: *TextureTable) !void {

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
        .gpa = gpa,
        .table = table,
        .blank = blank,
        .missing = missing,
        .skybox = null,
        .images = @splat(null),
    };
}

pub fn deinit(self: *TextureLoader) void {
    const table = self.table;
    for (&self.images) |*slot| if (slot.*) |*image| image.deinit(table.vma, table.device);
    if (self.skybox) |*skybox| skybox.deinit(table.vma, table.device);
    self.blank.deinit(table.vma, table.device);
    self.missing.deinit(table.vma, table.device);
}

/// Replace one slot's GPU image from pixels the producer decoded. Six faces means a
/// cubemap; the cross-split already happened above the boundary.
pub fn apply(self: *TextureLoader, upload: DrawList.TextureUpload) !void {
    if (upload.faces.len == 6) return self.applyCubemap(upload);

    const table = self.table;
    const index: usize = upload.slot - Texture.reserved;

    // No pixels: the producer could not read or decode the file. Drop whatever was bound
    // and show the checkerboard, so a broken asset is visible instead of stale or white.
    if (upload.faces.len == 0) {
        if (self.images[index]) |*old| {
            check(c.vkDeviceWaitIdle(table.device.handle)) catch {};
            old.deinit(table.vma, table.device);
            self.images[index] = null;
        }
        table.write(upload.slot, self.missing.vk_imageview, table.samplers.items[0]);
        return;
    }

    var image: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = upload.width, .height = upload.height, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer image.deinit(table.vma, table.device);
    try image.uploadDataToImage(table.vma, table.device, upload.faces[0].ptr, 4, 0);

    if (self.images[index]) |*old| {
        check(c.vkDeviceWaitIdle(table.device.handle)) catch {};
        old.deinit(table.vma, table.device);
    }
    self.images[index] = image;
    table.write(upload.slot, image.vk_imageview, table.samplers.items[0]);
}

fn applyCubemap(self: *TextureLoader, upload: DrawList.TextureUpload) !void {
    const table = self.table;

    var cubemap: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = upload.width, .height = upload.height, .depth = 1 },
        .cube_map,
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer cubemap.deinit(table.vma, table.device);

    for (upload.faces, 0..) |face, layer| {
        try cubemap.uploadDataToImage(table.vma, table.device, face.ptr, 4, @intCast(layer));
    }

    if (self.skybox) |*old| {
        check(c.vkDeviceWaitIdle(table.device.handle)) catch {};
        old.deinit(table.vma, table.device);
    }
    self.skybox = cubemap;
    table.writeSkybox(cubemap.vk_imageview, table.samplers.items[0]);
}
