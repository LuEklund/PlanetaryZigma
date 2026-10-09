const DescriptorLayout = @This();

const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const check = @import("utils.zig").check;

handle: c.VkDescriptorSetLayout,
count: u32,

pub fn init(device: Device, bindings: []const c.VkDescriptorSetLayoutBinding, descriptor_flags: u32, binding_flags: ?[]const c.VkDescriptorBindingFlags) !DescriptorLayout {
    const binding_flags_info: c.VkDescriptorSetLayoutBindingFlagsCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        .bindingCount = if (binding_flags) |flags| @intCast(flags.len) else 0,
        .pBindingFlags = if (binding_flags) |flags| flags.ptr else null,
    };
    var info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = if (binding_flags != null) &binding_flags_info else null,
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

pub fn deinit(self: DescriptorLayout, device: Device) void {
    c.vkDestroyDescriptorSetLayout(device.handle, self.handle, null);
}
