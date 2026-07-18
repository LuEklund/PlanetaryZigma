const PipelineLayout = @This();

const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const check = @import("utils.zig").check;

handle: c.VkPipelineLayout,

pub fn init(device: Device, comptime PushConstant: type, descriptor_set_layouts: []const c.VkDescriptorSetLayout) !PipelineLayout {
    // TEMP-COMMENT: was VERTEX-only; fragment shaders now read texture_index from the
    // push constant, and vkCmdPushConstants stage flags must match the range.
    const ranges: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(PushConstant),
    };

    var layout_create_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pSetLayouts = descriptor_set_layouts.ptr,
        .setLayoutCount = @intCast(descriptor_set_layouts.len),
        .pPushConstantRanges = &ranges,
        .pushConstantRangeCount = 1,
    };

    var layout: c.VkPipelineLayout = undefined;
    try check(c.vkCreatePipelineLayout(device.handle, &layout_create_info, null, &layout));
    return .{
        .handle = layout,
    };
}

pub fn deinit(self: PipelineLayout, device: Device) void {
    c.vkDestroyPipelineLayout(device.handle, self.handle, null);
}
