const GpuMemory = @This();

const std = @import("std");
const vk = @import("vulkan");
const Device = @import("device.zig").Logical;

pub const max_free_ranges = 1024;

pub const Range = struct {
    offset: u64,
    size: u64,
};

pub const Heaps = struct {
    host: GpuMemory,
    device: GpuMemory,

    pub const host_size: u64 = 256 << 20;
    pub const device_size: u64 = 768 << 20;

    pub fn init(device: Device, memory_properties: vk.PhysicalDeviceMemoryProperties) !Heaps {
        var host: GpuMemory = try .init(
            device,
            memory_properties,
            host_size,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        errdefer host.deinit(device);
        const device_heap: GpuMemory = try .init(
            device,
            memory_properties,
            device_size,
            .{ .device_local_bit = true },
        );
        return .{ .host = host, .device = device_heap };
    }

    pub fn deinit(self: *Heaps, device: Device) void {
        self.host.deinit(device);
        self.device.deinit(device);
    }
};

memory: vk.DeviceMemory,
memory_type_index: u32,
mapped: ?[*]u8,
free_ranges: [max_free_ranges]Range,
free_count: u32,

pub fn init(
    device: Device,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    size: u64,
    required: vk.MemoryPropertyFlags,
) !GpuMemory {
    const memory_type_index: u32 = for (memory_properties.memory_types[0..memory_properties.memory_type_count], 0..) |memory_type, index| {
        if (memory_type.property_flags.contains(required)) break @intCast(index);
    } else return error.NoCompatibleMemoryType;

    const flags_info: vk.MemoryAllocateFlagsInfo = .{
        .flags = .{ .device_address_bit = true },
        .device_mask = 0,
    };
    const memory = try device.proxy.allocateMemory(&.{
        .p_next = &flags_info,
        .allocation_size = size,
        .memory_type_index = memory_type_index,
    }, null);
    errdefer device.proxy.freeMemory(memory, null);

    const mapped: ?[*]u8 = if (required.host_visible_bit)
        @ptrCast(try device.proxy.mapMemory(memory, 0, vk.WHOLE_SIZE, .{}))
    else
        null;

    var self: GpuMemory = .{
        .memory = memory,
        .memory_type_index = memory_type_index,
        .mapped = mapped,
        .free_ranges = undefined,
        .free_count = 1,
    };
    self.free_ranges[0] = .{ .offset = 0, .size = size };
    return self;
}

pub fn deinit(self: *GpuMemory, device: Device) void {
    device.proxy.freeMemory(self.memory, null);
}

pub fn alloc(self: *GpuMemory, requirements: vk.MemoryRequirements) !Range {
    std.debug.assert(
        requirements.memory_type_bits & (@as(u32, 1) << @intCast(self.memory_type_index)) != 0,
    );
    for (self.free_ranges[0..self.free_count], 0..) |*free_range, index| {
        const offset = std.mem.alignForward(u64, free_range.offset, requirements.alignment);
        const padding = offset - free_range.offset;
        if (free_range.size < padding + requirements.size) continue;
        const end = free_range.offset + free_range.size;
        if (padding != 0) {
            free_range.size = padding;
            if (offset + requirements.size < end) self.insert(
                index + 1,
                .{ .offset = offset + requirements.size, .size = end - offset - requirements.size },
            );
        } else if (free_range.size == requirements.size) {
            self.remove(index);
        } else {
            free_range.* = .{
                .offset = offset + requirements.size,
                .size = end - offset - requirements.size,
            };
        }
        return .{ .offset = offset, .size = requirements.size };
    }
    std.log.err(
        "gpu memory: out of space for {d} bytes (memory type {d}, {d} free ranges)",
        .{ requirements.size, self.memory_type_index, self.free_count },
    );
    return error.OutOfGpuMemory;
}

pub fn free(self: *GpuMemory, range: Range) void {
    var index: usize = 0;
    while (index < self.free_count and self.free_ranges[index].offset < range.offset) index += 1;
    self.insert(index, range);
    if (index + 1 < self.free_count and self.free_ranges[index].offset + self.free_ranges[index].size == self.free_ranges[index + 1].offset) {
        self.free_ranges[index].size += self.free_ranges[index + 1].size;
        self.remove(index + 1);
    }
    if (index > 0 and self.free_ranges[index - 1].offset + self.free_ranges[index - 1].size == self.free_ranges[index].offset) {
        self.free_ranges[index - 1].size += self.free_ranges[index].size;
        self.remove(index);
    }
}

pub fn bytes(self: *const GpuMemory, range: Range) [*]u8 {
    return self.mapped.? + range.offset;
}

fn insert(self: *GpuMemory, index: usize, range: Range) void {
    std.debug.assert(self.free_count < max_free_ranges);
    std.mem.copyBackwards(
        Range,
        self.free_ranges[index + 1 .. self.free_count + 1],
        self.free_ranges[index..self.free_count],
    );
    self.free_ranges[index] = range;
    self.free_count += 1;
}

fn remove(self: *GpuMemory, index: usize) void {
    std.mem.copyForwards(
        Range,
        self.free_ranges[index .. self.free_count - 1],
        self.free_ranges[index + 1 .. self.free_count],
    );
    self.free_count -= 1;
}

test "alloc and free coalesce back to one range" {
    var heap: GpuMemory = .{
        .memory = .null_handle,
        .memory_type_index = 0,
        .mapped = null,
        .free_ranges = undefined,
        .free_count = 1,
    };
    heap.free_ranges[0] = .{ .offset = 0, .size = 1024 };
    const a = try heap.alloc(.{ .size = 100, .alignment = 1, .memory_type_bits = 1 });
    const b = try heap.alloc(.{ .size = 100, .alignment = 256, .memory_type_bits = 1 });
    const d = try heap.alloc(.{ .size = 50, .alignment = 1, .memory_type_bits = 1 });
    try std.testing.expectEqual(@as(u64, 256), b.offset);
    try std.testing.expectEqual(@as(u64, 100), d.offset);
    heap.free(b);
    heap.free(a);
    heap.free(d);
    try std.testing.expectEqual(@as(u32, 1), heap.free_count);
    try std.testing.expectEqual(Range{ .offset = 0, .size = 1024 }, heap.free_ranges[0]);
}
