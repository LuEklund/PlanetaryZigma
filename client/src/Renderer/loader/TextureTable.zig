const TextureTable = @This();

const std = @import("std");
const c = @import("vulkan");
const ext = @import("../Vulkan/procs.zig").device.ProcTable;
const Vma = @import("../Vulkan/Vma.zig");
const Device = @import("../Vulkan/device.zig").Logical;
const Image = @import("../Vulkan/Image.zig");
const Buffer = @import("../Vulkan/Buffer.zig");
const check = @import("../Vulkan/utils.zig").check;

pub const max_textures = 256;
pub const crosshair_texture_key = "textures/crosshair.png";

vma: Vma,
device: Device,
descriptor_buffer: Buffer,
binding_offset: c.VkDeviceSize,
descriptor_size: usize,
images: std.ArrayList(Image),
free_slots: std.ArrayList(usize),
samplers: std.ArrayList(c.VkSampler),
keys: std.StringHashMapUnmanaged(Image.Handle),
skybox: ?Image,
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
        .images = .empty,
        .free_slots = .empty,
        .samplers = .empty,
        .keys = .empty,
        .skybox = null,
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

    var blank: Image = try .init(
        vma,
        device,
        c.VK_FORMAT_R8G8B8A8_UNORM,
        .{ .width = 1, .height = 1, .depth = 1 },
        .@"2d",
        c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    var white: [4]u8 = .{ 255, 255, 255, 255 };
    try blank.uploadDataToImage(vma, device, &white, 4, 0);

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
    try self.images.append(gpa, blank);
    for (0..max_textures) |slot| self.writeDescriptor(slot, blank.vk_imageview, default_sampler);

    return self;
}

pub fn deinit(self: *TextureTable, gpa: std.mem.Allocator) void {
    for (self.images.items, 0..) |*image, slot| {
        if (std.mem.indexOfScalar(usize, self.free_slots.items, slot) != null) continue;
        image.deinit(self.vma, self.device);
    }
    self.images.deinit(gpa);
    self.free_slots.deinit(gpa);
    for (self.samplers.items) |sampler| c.vkDestroySampler(self.device.handle, sampler, null);
    self.samplers.deinit(gpa);
    var key_iterator = self.keys.keyIterator();
    while (key_iterator.next()) |key| gpa.free(key.*);
    self.keys.deinit(gpa);
    if (self.skybox) |*skybox| skybox.deinit(self.vma, self.device);
    self.skybox_descriptor.deinit(self.vma);
    self.descriptor_buffer.deinit(self.vma);
}

pub fn allocSlot(self: *TextureTable, gpa: std.mem.Allocator, image: Image, sampler: c.VkSampler, key: ?[]const u8) !Image.Handle {
    const slot: usize = if (self.free_slots.pop()) |free_slot| reuse: {
        self.images.items[free_slot] = image;
        break :reuse free_slot;
    } else grow: {
        std.debug.assert(self.images.items.len < max_textures);
        try self.images.append(gpa, image);
        break :grow self.images.items.len - 1;
    };
    self.writeDescriptor(slot, image.vk_imageview, sampler);
    if (key) |new_key| try self.keys.put(gpa, try gpa.dupe(u8, new_key), @enumFromInt(slot));
    std.log.debug("texture slot {d}/{d}: {s}", .{ slot + 1, max_textures, key orelse "unnamed" });
    return @enumFromInt(slot);
}

pub fn freeSlot(self: *TextureTable, gpa: std.mem.Allocator, image_handle: Image.Handle) void {
    const slot = image_handle.index();
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
    self.images.items[slot].deinit(self.vma, self.device);
    self.images.items[slot] = self.images.items[0];
    self.writeDescriptor(slot, self.images.items[0].vk_imageview, self.samplers.items[0]);
    var key_iterator = self.keys.iterator();
    while (key_iterator.next()) |entry| {
        if (entry.value_ptr.* == image_handle) {
            const key = entry.key_ptr.*;
            _ = self.keys.remove(key);
            gpa.free(key);
            break;
        }
    }
    self.free_slots.append(gpa, slot) catch {};
}

pub fn handle(self: *const TextureTable, key: []const u8) Image.Handle {
    return self.keys.get(key).?;
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

pub fn setSlotSampler(self: *TextureTable, image_handle: Image.Handle, sampler: c.VkSampler) void {
    const slot = image_handle.index();
    self.writeDescriptor(slot, self.images.items[slot].vk_imageview, sampler);
}

pub fn setSkybox(self: *TextureTable, image: Image) void {
    if (self.skybox) |*old| {
        check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
        old.deinit(self.vma, self.device);
    }
    self.skybox = image;
    self.writeCombinedSamplerDescriptor(@ptrCast(self.skybox_descriptor.info.pMappedData), image.vk_imageview, self.samplers.items[0]);
}

fn writeDescriptor(self: *TextureTable, slot: usize, view: c.VkImageView, sampler: c.VkSampler) void {
    const descriptor_buffer_bytes: [*]u8 = @ptrCast(self.descriptor_buffer.info.pMappedData);
    self.writeCombinedSamplerDescriptor(descriptor_buffer_bytes + self.binding_offset + slot * self.descriptor_size, view, sampler);
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
