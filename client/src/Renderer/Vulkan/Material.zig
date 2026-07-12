const std = @import("std");
const c = @import("vulkan");
const ext = @import("procs.zig").device.ProcTable;
const Buffer = @import("Buffer.zig");
const Device = @import("device.zig").Logical;
const Vma = @import("Vma.zig");

buffer: Buffer,
name: []const u8,

pub fn init(
    gpa: std.mem.Allocator,
    name: []const u8,
    device: Device,
    vma: Vma,
    set_size: c.VkDeviceSize,
    combined_image_sampler_descriptor_size: c.VkDeviceSize,
    sampler: c.VkSampler,
    view_image: c.VkImageView,
) !@This() {
    const new_desc_buf = try Buffer.init(
        device,
        vma,
        u8,
        set_size,
        c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
            c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
        .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
    );

    const img_info: c.VkDescriptorImageInfo = .{
        .sampler = sampler,
        .imageView = view_image,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    const get_info: c.VkDescriptorGetInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
        .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .data = .{ .pCombinedImageSampler = &img_info },
    };
    const material_dst: [*]u8 = @ptrCast(new_desc_buf.info.pMappedData);
    ext.vkGetDescriptorEXT(device.handle, &get_info, combined_image_sampler_descriptor_size, material_dst);

    return .{
        .name = try gpa.dupe(u8, name),
        .buffer = new_desc_buf,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.buffer.deinit(vma);
    gpa.free(self.name);
}
