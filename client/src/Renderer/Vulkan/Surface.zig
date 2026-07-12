const std = @import("std");
const Instance = @import("Instance.zig");
const device = @import("device.zig");
const c = @import("vulkan");
const check = @import("utils.zig").check;

handle: c.VkSurfaceKHR,

pub fn deinit(self: @This(), instance: Instance) void {
    c.vkDestroySurfaceKHR(instance.handle, self.handle, null);
}

pub fn getFormat(self: @This(), gpa: std.mem.Allocator, physical_device: device.Physical) !c.VkSurfaceFormatKHR {
    var format_count: u32 = 0;
    try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device.handle, self.handle, &format_count, null));

    const formats = try gpa.alloc(c.VkSurfaceFormatKHR, format_count);
    defer gpa.free(formats);
    try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device.handle, self.handle, &format_count, formats.ptr));

    var chosen_format: c.VkSurfaceFormatKHR = formats[0];
    for (0..format_count) |i| {
        if (formats[i].format == c.VK_FORMAT_R8G8B8A8_UNORM) {
            chosen_format = formats[i];
            break;
        }
    }
    return chosen_format;
}

pub fn getExtent(self: @This(), physical_device: device.Physical, width: u32, height: u32) !c.VkExtent2D {
    var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
    try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.handle, self.handle, &capabilities));

    const actual_extent: c.VkExtent2D = if (capabilities.currentExtent.width != std.math.maxInt(u32) and
        capabilities.currentExtent.height != std.math.maxInt(u32))
        capabilities.currentExtent
    else
        .{
            .width = @max(capabilities.minImageExtent.width, @min(capabilities.maxImageExtent.width, width)),
            .height = @max(capabilities.minImageExtent.height, @min(capabilities.maxImageExtent.height, height)),
        };

    return actual_extent;
}
