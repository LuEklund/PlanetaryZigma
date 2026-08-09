const TextureTable = @This();

const std = @import("std");
const c = @import("vulkan");
const ext = @import("../Vulkan/procs.zig").device.ProcTable;
const Vma = @import("../Vulkan/Vma.zig");
const Device = @import("../Vulkan/device.zig").Logical;
const Buffer = @import("../Vulkan/Buffer.zig");
const Texture = @import("shared").Texture;
const check = @import("../Vulkan/utils.zig").check;

pub const max_textures = 256;

vma: Vma,
device: Device,
descriptor_buffer: Buffer,
binding_offset: c.VkDeviceSize,
descriptor_size: usize,
next_slot: usize,
free_slots: std.ArrayList(usize),
samplers: std.ArrayList(c.VkSampler),
empty_view: c.VkImageView,
empty_sampler: c.VkSampler,
skybox_descriptor: Buffer,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    textures_layout: c.VkDescriptorSetLayout,
    material_layout: c.VkDescriptorSetLayout,
    descriptor_size: usize,
) !TextureTable {
    var table_set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, textures_layout, &table_set_size);
    var binding_offset: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutBindingOffsetEXT(device.handle, textures_layout, 0, &binding_offset);
    var material_set_size: c.VkDeviceSize = 0;
    ext.vkGetDescriptorSetLayoutSizeEXT(device.handle, material_layout, &material_set_size);

    var self: TextureTable = .{
        .vma = vma,
        .device = device,
        .descriptor_buffer = try .init(
            device,
            vma,
            u8,
            table_set_size,
            c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
        ),
        .binding_offset = binding_offset,
        .descriptor_size = descriptor_size,
        .next_slot = Texture.count(),
        .free_slots = .empty,
        .samplers = .empty,
        .empty_view = null,
        .empty_sampler = null,
        .skybox_descriptor = try .init(
            device,
            vma,
            u8,
            material_set_size,
            c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
            .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
        ),
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
    self.free_slots.deinit(gpa);
    for (self.samplers.items) |sampler| c.vkDestroySampler(self.device.handle, sampler, null);
    self.samplers.deinit(gpa);
    self.skybox_descriptor.deinit(self.vma);
    self.descriptor_buffer.deinit(self.vma);
}

// The empty texture fills unused slots and reclaimed slots. The loader that owns it
// registers it once at startup, before any other slot is written.
pub fn registerEmpty(self: *TextureTable, view: c.VkImageView, sampler: c.VkSampler) void {
    self.empty_view = view;
    self.empty_sampler = sampler;
    for (0..max_textures) |slot| self.write(slot, view, sampler);
}

pub fn alloc(self: *TextureTable) usize {
    if (self.free_slots.pop()) |free_slot| return free_slot;
    std.debug.assert(self.next_slot < max_textures);
    const slot = self.next_slot;
    self.next_slot += 1;
    return slot;
}

pub fn free(self: *TextureTable, gpa: std.mem.Allocator, slot: usize) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
    self.write(slot, self.empty_view, self.empty_sampler);
    self.free_slots.append(gpa, slot) catch {};
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

pub fn write(self: *TextureTable, slot: usize, view: c.VkImageView, sampler: c.VkSampler) void {
    const descriptor_buffer_bytes: [*]u8 = @ptrCast(self.descriptor_buffer.info.pMappedData);
    self.writeCombinedSamplerDescriptor(descriptor_buffer_bytes + self.binding_offset + slot * self.descriptor_size, view, sampler);
}

pub fn writeSkybox(self: *TextureTable, view: c.VkImageView, sampler: c.VkSampler) void {
    self.writeCombinedSamplerDescriptor(@ptrCast(self.skybox_descriptor.info.pMappedData), view, sampler);
}

fn writeCombinedSamplerDescriptor(self: *TextureTable, destination: [*]u8, view: c.VkImageView, sampler: c.VkSampler) void {
    const image_info: c.VkDescriptorImageInfo = .{
        .sampler = sampler,
        .imageView = view,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const descriptor_get_info: c.VkDescriptorGetInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
        .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .data = .{ .pCombinedImageSampler = &image_info },
    };
    ext.vkGetDescriptorEXT(
        self.device.handle,
        &descriptor_get_info,
        self.descriptor_size,
        destination,
    );
}
