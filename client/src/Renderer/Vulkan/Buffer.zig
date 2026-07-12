const std = @import("std");
const c = @import("vulkan");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const check = @import("utils.zig").check;

buffer: c.VkBuffer,
vma_allocation: Vma.Allocation,
device: Device,
info: Vma.AllocationInfo,
len: u32,

pub fn init(device: Device, vma: Vma, comptime T: type, amount: usize, vk_buffer_usage: c.VkBufferUsageFlags, vmaalloc_info: Vma.c.VmaAllocationCreateInfo) !@This() {
    var buffer_info: Vma.c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = amount * @sizeOf(T),
        .usage = vk_buffer_usage,
    };

    var new_buffer: c.VkBuffer = undefined;
    var allocation: Vma.Allocation = undefined;
    var info: Vma.AllocationInfo = undefined;

    try check(Vma.c.vmaCreateBuffer(
        vma.handle,
        &buffer_info,
        &vmaalloc_info,
        @ptrCast(&new_buffer),
        &allocation,
        &info,
    ));

    return .{
        .buffer = new_buffer,
        .vma_allocation = allocation,
        .info = info,
        .device = device,
        .len = @intCast(amount),
    };
}

pub fn deinit(self: *@This(), vma: Vma) void {
    Vma.c.vmaDestroyBuffer(vma.handle, @ptrCast(self.buffer), self.vma_allocation);
}

pub fn getGPUAddress(self: *const @This()) c.VkDeviceAddress {
    var device_adress_info: c.VkBufferDeviceAddressInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
        .buffer = self.buffer,
    };
    return c.vkGetBufferDeviceAddress(self.device.handle, &device_adress_info);
}

pub fn copy(self: *@This(), comptime T: type, data: []const T) void {
    const size = @sizeOf(T) * data.len;
    std.debug.assert(size <= self.info.size);
    var mapped: [*]u8 = @ptrCast(self.info.pMappedData);
    var byte_data: [*]const u8 = @ptrCast(data.ptr);
    @memcpy(
        mapped[0..size],
        byte_data[0..size],
    );
}
