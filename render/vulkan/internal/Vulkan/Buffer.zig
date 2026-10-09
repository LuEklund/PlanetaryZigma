const Buffer = @This();

const std = @import("std");
const vk = @import("vulkan");
const GpuMemory = @import("GpuMemory.zig");
const Device = @import("device.zig").Logical;

buffer: vk.Buffer,
range: GpuMemory.Range,
mapped: [*]u8,
size: u64,
device: Device,

pub fn init(device: Device, heap: *GpuMemory, comptime T: type, amount: usize, usage: vk.BufferUsageFlags) !Buffer {
    const size: u64 = @max(1, amount) * @sizeOf(T);
    const buffer = try device.proxy.createBuffer(&.{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.proxy.destroyBuffer(buffer, null);
    const range = try heap.alloc(device.proxy.getBufferMemoryRequirements(buffer));
    errdefer heap.free(range);
    try device.proxy.bindBufferMemory(buffer, heap.memory, range.offset);
    return .{
        .buffer = buffer,
        .range = range,
        .mapped = heap.bytes(range),
        .size = size,
        .device = device,
    };
}

pub fn deinit(self: *Buffer, heap: *GpuMemory) void {
    self.device.proxy.destroyBuffer(self.buffer, null);
    heap.free(self.range);
}

pub fn getGPUAddress(self: *const Buffer) vk.DeviceAddress {
    return self.device.proxy.getBufferDeviceAddress(&.{ .buffer = self.buffer });
}

pub fn copy(self: *Buffer, comptime T: type, data: []const T) void {
    const size = @sizeOf(T) * data.len;
    std.debug.assert(size <= self.size);
    const byte_data: [*]const u8 = @ptrCast(data.ptr);
    @memcpy(self.mapped[0..size], byte_data[0..size]);
}
