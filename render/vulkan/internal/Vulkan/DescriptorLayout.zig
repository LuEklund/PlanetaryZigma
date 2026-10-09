const DescriptorLayout = @This();

const vk = @import("vulkan");
const Device = @import("device.zig").Logical;

handle: vk.DescriptorSetLayout,

pub fn init(device: Device, bindings: []const vk.DescriptorSetLayoutBinding, flags: vk.DescriptorSetLayoutCreateFlags, binding_flags: ?[]const vk.DescriptorBindingFlags) !DescriptorLayout {
    const binding_flags_info: vk.DescriptorSetLayoutBindingFlagsCreateInfo = .{
        .binding_count = if (binding_flags) |all| @intCast(all.len) else 0,
        .p_binding_flags = if (binding_flags) |all| all.ptr else null,
    };
    const handle = try device.proxy.createDescriptorSetLayout(&.{
        .p_next = if (binding_flags != null) &binding_flags_info else null,
        .flags = flags,
        .binding_count = @intCast(bindings.len),
        .p_bindings = bindings.ptr,
    }, null);
    return .{ .handle = handle };
}

pub fn deinit(self: DescriptorLayout, device: Device) void {
    device.proxy.destroyDescriptorSetLayout(self.handle, null);
}
