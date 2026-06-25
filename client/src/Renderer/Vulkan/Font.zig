const std = @import("std");
const c = @import("vulkan");
const Image = @import("Image.zig");
const Material = @import("Material.zig");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const stbTruetype = @import("stb_truetype");
const AssetServer = @import("shared").AssetServer;
const RenderResources = @import("RenderResources.zig");
const check = @import("utils.zig").check;

material: Material,
image: Image,
sampler: c.VkSampler,

device: Device,
vma: Vma,
render_resources: *RenderResources,
chars: [96]stbTruetype.stbtt_packedchar,
name: []const u8,
size: f32,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    path: []const u8,
    asset_server: *AssetServer,
    render_resources: *RenderResources,
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .device = device,
        .vma = vma,
        .render_resources = render_resources,
        .name = try gpa.dupe(u8, path),
        .image = undefined,
        .sampler = undefined,
        .chars = undefined,
        .material = undefined,
        .size = 32,
    };
    try asset_server.loadAsset(@This(), self, path, loadFont);
    return self;
}

fn loadFont(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;
    const self: *@This() = @ptrCast(@alignCast(user_data));
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);
    std.debug.print("size:  {d}\n", .{content.len});

    const atlas_w: c_int = 512;
    const atlas_h: c_int = 512;

    const coverage = try gpa.alloc(u8, @intCast(atlas_w * atlas_h));
    defer gpa.free(coverage);

    var pack: stbTruetype.stbtt_pack_context = undefined;
    _ = stbTruetype.stbtt_PackBegin(&pack, coverage.ptr, atlas_w, atlas_h, 0, 1, null);
    stbTruetype.stbtt_PackSetOversampling(&pack, 2, 2);
    _ = stbTruetype.stbtt_PackFontRange(&pack, content.ptr, 0, self.size, 32, 96, &self.chars);
    stbTruetype.stbtt_PackEnd(&pack);

    self.image = try .init(
        self.vma,
        self.device,
        c.VK_FORMAT_R8_UNORM,
        .{ .width = @intCast(atlas_w), .height = @intCast(atlas_h), .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    try self.image.uploadDataToImage(self.vma, self.device, coverage.ptr, 1, 0);

    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
    try check(c.vkCreateSampler(self.device.handle, &sampler_info, null, &self.sampler));

    self.material = try .init(
        gpa,
        self.name,
        self.device,
        self.vma,
        self.render_resources.set_size,
        self.render_resources.combined_image_sampler_descriptor_size,
        self.sampler,
        self.image.vk_imageview,
    );
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma, device: Device) void {
    self.image.deinit(vma, device);
    self.material.deinit(gpa, vma);
    c.vkDestroySampler(device.handle, self.sampler, null);
    gpa.free(self.name);
    gpa.destroy(self);
}
