const PipelineLayout = @This();

const vk = @import("vulkan");
const Device = @import("device.zig").Logical;

pub const Kind = enum { world, particle, sky, dvui };
pub const push_stages: vk.ShaderStageFlags = .{ .vertex_bit = true, .fragment_bit = true };

handle: vk.PipelineLayout,

pub fn init(
    device: Device,
    push_constant_size: u32,
    descriptor_set_layouts: []const vk.DescriptorSetLayout,
) !PipelineLayout {
    const range = [_]vk.PushConstantRange{.{
        .stage_flags = push_stages,
        .offset = 0,
        .size = push_constant_size,
    }};
    const handle = try device.proxy.createPipelineLayout(&.{
        .set_layout_count = @intCast(descriptor_set_layouts.len),
        .p_set_layouts = descriptor_set_layouts.ptr,
        .push_constant_range_count = if (push_constant_size != 0) 1 else 0,
        .p_push_constant_ranges = &range,
    }, null);
    return .{ .handle = handle };
}

pub fn deinit(self: PipelineLayout, device: Device) void {
    device.proxy.destroyPipelineLayout(self.handle, null);
}
