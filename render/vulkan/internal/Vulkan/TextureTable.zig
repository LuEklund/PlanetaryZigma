const TextureTable = @This();

const std = @import("std");
const c = @import("vulkan");
const Vma = @import("../Vulkan/Vma.zig");
const Device = @import("../Vulkan/device.zig").Logical;
const check = @import("../Vulkan/utils.zig").check;
const contract = @import("renderer_contract");

pub const max_textures = 256;

vma: Vma,
device: Device,
set: c.VkDescriptorSet,
skybox_set: c.VkDescriptorSet,
taken: [max_textures]bool,
samplers: std.ArrayList(c.VkSampler),
empty_view: c.VkImageView,
empty_sampler: c.VkSampler,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    pool: c.VkDescriptorPool,
    textures_layout: c.VkDescriptorSetLayout,
    material_layout: c.VkDescriptorSetLayout,
) !TextureTable {
    const layouts = [_]c.VkDescriptorSetLayout{ textures_layout, material_layout };
    var sets: [2]c.VkDescriptorSet = undefined;
    try check(c.vkAllocateDescriptorSets(device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool,
        .descriptorSetCount = layouts.len,
        .pSetLayouts = &layouts,
    }, &sets));

    var self: TextureTable = .{
        .vma = vma,
        .device = device,
        .set = sets[0],
        .skybox_set = sets[1],
        .taken = taken: {
            var named: [max_textures]bool = @splat(false);
            for (0..@typeInfo(contract.TextureHandle).@"enum".fields.len) |slot| named[slot] = true;
            break :taken named;
        },
        .samplers = .empty,
        .empty_view = null,
        .empty_sampler = null,
    };

    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .anisotropyEnable = c.VK_FALSE,
        .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = c.VK_FALSE,
        .compareEnable = c.VK_FALSE,
        .compareOp = c.VK_COMPARE_OP_ALWAYS,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR,
    };
    var default_sampler: c.VkSampler = undefined;
    try check(c.vkCreateSampler(device.handle, &sampler_info, null, &default_sampler));
    try self.samplers.append(gpa, default_sampler);

    return self;
}

pub fn deinit(self: *TextureTable, gpa: std.mem.Allocator) void {
    for (self.samplers.items) |sampler| c.vkDestroySampler(self.device.handle, sampler, null);
    self.samplers.deinit(gpa);
}

pub fn registerEmpty(self: *TextureTable, view: c.VkImageView, sampler: c.VkSampler) void {
    self.empty_view = view;
    self.empty_sampler = sampler;
    for (0..max_textures) |slot| self.write(@enumFromInt(slot), view, sampler);
}

pub fn alloc(self: *TextureTable) contract.TextureHandle {
    const slot = std.mem.indexOfScalar(bool, &self.taken, false).?;
    self.taken[slot] = true;
    return @enumFromInt(slot);
}

pub fn free(self: *TextureTable, texture: contract.TextureHandle) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
    self.write(texture, self.empty_view, self.empty_sampler);
    self.taken[@intFromEnum(texture)] = false;
}

pub fn addSampler(self: *TextureTable, gpa: std.mem.Allocator, mag_linear: bool, min_linear: bool) !c.VkSampler {
    const sampler_info: c.VkSamplerCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .maxLod = c.VK_LOD_CLAMP_NONE,
        .minLod = 0,
        .magFilter = if (mag_linear) c.VK_FILTER_LINEAR else c.VK_FILTER_NEAREST,
        .minFilter = if (min_linear) c.VK_FILTER_LINEAR else c.VK_FILTER_NEAREST,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
        .anisotropyEnable = c.VK_FALSE,
        .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = c.VK_FALSE,
        .compareEnable = c.VK_FALSE,
        .compareOp = c.VK_COMPARE_OP_ALWAYS,
    };
    var new_sampler: c.VkSampler = undefined;
    try check(c.vkCreateSampler(self.device.handle, &sampler_info, null, &new_sampler));
    try self.samplers.append(gpa, new_sampler);
    return new_sampler;
}

pub fn write(self: *TextureTable, texture: contract.TextureHandle, view: c.VkImageView, sampler: c.VkSampler) void {
    writeCombinedSampler(self.device, self.set, @intFromEnum(texture), view, sampler);
}

pub fn writeSkybox(self: *TextureTable, view: c.VkImageView, sampler: c.VkSampler) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
    writeCombinedSampler(self.device, self.skybox_set, 0, view, sampler);
}

pub fn writeCombinedSampler(device: Device, set: c.VkDescriptorSet, array_element: u32, view: c.VkImageView, sampler: c.VkSampler) void {
    const image_info: c.VkDescriptorImageInfo = .{
        .sampler = sampler,
        .imageView = view,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const descriptor_write: c.VkWriteDescriptorSet = .{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .dstBinding = 0,
        .dstArrayElement = array_element,
        .descriptorCount = 1,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image_info,
    };
    c.vkUpdateDescriptorSets(device.handle, 1, &descriptor_write, 0, null);
}
