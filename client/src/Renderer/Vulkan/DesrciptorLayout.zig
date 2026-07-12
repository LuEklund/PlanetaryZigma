const std = @import("std");
const c = @import("vulkan");
const Func = @import("utils.zig").Func;
const Device = @import("device.zig").Logical;
const check = @import("utils.zig").check;

handle: c.VkDescriptorSetLayout,
count: u32,

pub const Kind = enum {
    scene,
    material,
    ui,
};

pub fn init(device: Device, bindings: []const c.VkDescriptorSetLayoutBinding, descriptor_flags: u32) !@This() {
    var info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pBindings = &bindings[0],
        .bindingCount = @intCast(bindings.len),
        .flags = descriptor_flags,
    };

    var set: c.VkDescriptorSetLayout = undefined;
    try check(c.vkCreateDescriptorSetLayout(
        device.handle,
        &info,
        null,
        &set,
    ));
    return .{
        .handle = set,
        .count = @intCast(bindings.len),
    };
}

pub fn deinit(self: @This(), device: Device) void {
    c.vkDestroyDescriptorSetLayout(device.handle, self.handle, null);
}
