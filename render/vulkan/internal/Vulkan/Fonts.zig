const Fonts = @This();

const std = @import("std");
const c = @import("vulkan");
const Font = @import("shared").Font;
const Image = @import("../Vulkan/Image.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

gpa: std.mem.Allocator,
table: *TextureTable,
items: []Font,
samplers: []c.VkSampler,
atlases: []?Image,

/// `fonts` is caller-owned: one owned here would be a pointer into render.so.
pub fn init(self: *Fonts, gpa: std.mem.Allocator, table: *TextureTable, fonts: []Font) !void {
    std.debug.assert(fonts.len == Font.files.len);
    const items = fonts;
    const samplers = try gpa.alloc(c.VkSampler, Font.files.len);
    @memset(samplers, null);
    const atlases = try gpa.alloc(?Image, Font.files.len);
    @memset(atlases, null);

    self.* = .{
        .gpa = gpa,
        .table = table,
        .items = items,
        .samplers = samplers,
        .atlases = atlases,
    };
}

pub fn deinit(self: *Fonts) void {
    for (0..self.items.len) |index| self.release(index);
    self.gpa.free(self.samplers);
    self.gpa.free(self.atlases);
}

fn release(self: *Fonts, index: usize) void {
    if (self.samplers[index] == null) return;
    self.table.free(self.gpa, self.items[index].atlas_texture_index);
    if (self.atlases[index]) |*atlas| atlas.deinit(self.table.vma, self.table.device);
    self.atlases[index] = null;
    c.vkDestroySampler(self.table.device.handle, self.samplers[index], null);
    self.samplers[index] = null;
}

/// Upload a baked atlas and hand its slot number back through the shared fonts array.
pub fn apply(self: *Fonts, index: usize, coverage: []const u8) !void {
    const table = self.table;
    check(c.vkDeviceWaitIdle(table.device.handle)) catch {};
    self.release(index);

    var atlas_image: Image = try .init(
        table.vma,
        table.device,
        c.VK_FORMAT_R8_UNORM,
        .{ .width = @intCast(Font.atlas_width), .height = @intCast(Font.atlas_height), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    errdefer atlas_image.deinit(table.vma, table.device);
    try atlas_image.uploadDataToImage(table.vma, table.device, coverage.ptr, 1, 0);

    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    try check(c.vkCreateSampler(table.device.handle, &sampler_info, null, &self.samplers[index]));

    const atlas_slot = table.alloc();
    table.write(atlas_slot, atlas_image.vk_imageview, self.samplers[index]);
    self.atlases[index] = atlas_image;
    self.items[index].atlas_texture_index = @intCast(atlas_slot);
}
