const FontLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const Loader = @import("../../AssetServer.zig").Loader;
const Font = @import("../../asset/Font.zig");
const Image = @import("../Vulkan/Image.zig");
const TextureTable = @import("TextureTable.zig");
const check = @import("../Vulkan/utils.zig").check;

const font_files: []const []const u8 = &.{"Roboto-Regular.ttf"};

table: *TextureTable,
items: []Font,
samplers: []c.VkSampler,
interface: Loader,

pub fn init(gpa: std.mem.Allocator, io: std.Io, table: *TextureTable) !FontLoader {
    const items = try gpa.alloc(Font, font_files.len);
    @memset(items, .empty);
    const samplers = try gpa.alloc(c.VkSampler, font_files.len);
    @memset(samplers, null);

    return .{
        .table = table,
        .items = items,
        .samplers = samplers,
        .interface = .{
            .gpa = gpa,
            .io = io,
            .root_path = "fonts",
            .files = font_files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
}

pub fn deinit(self: *FontLoader) void {
    const gpa = self.interface.gpa;
    for (0..self.items.len) |index| unload(&self.interface, index);
    gpa.free(self.items);
    gpa.free(self.samplers);
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *FontLoader = @fieldParentPtr("interface", loader);
    const gpa = loader.gpa;
    const table = self.table;
    const file = try err_file;
    unload(&self.interface, index);

    const font = &self.items[index];
    const coverage = try font.bake(gpa, loader.io, file);
    defer gpa.free(coverage);

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

    const atlas_handle = try table.allocSlot(gpa, atlas_image, self.samplers[index], null);
    font.atlas_texture_index = @intCast(atlas_handle.index());
}

fn unload(loader: *Loader, index: usize) void {
    const self: *FontLoader = @fieldParentPtr("interface", loader);
    if (self.samplers[index] == null) return;
    self.table.freeSlot(loader.gpa, @enumFromInt(self.items[index].atlas_texture_index));
    check(c.vkDeviceWaitIdle(self.table.device.handle)) catch {};
    c.vkDestroySampler(self.table.device.handle, self.samplers[index], null);
    self.samplers[index] = null;
    self.items[index] = .empty;
}
