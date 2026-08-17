const Shaders = @This();

const std = @import("std");
const c = @import("vulkan");
const Device = @import("../Vulkan/device.zig").Logical;
const Shader = @import("renderer_contract").Shader;
const check = @import("../Vulkan/utils.zig").check;
const ext = @import("../Vulkan/procs.zig").device.ProcTable;

gpa: std.mem.Allocator,
device: Device,
layouts: std.EnumArray(Shader.Descriptor, c.VkDescriptorSetLayout),
shaders: []Stages,

pub const Object = struct {
    handle: c.VkShaderEXT,
    device: Device,

    pub fn init(device: Device, kind: Shader.Kind, entry_point: [:0]const u8, stage: c.VkShaderStageFlagBits, next_stage: c.VkShaderStageFlags, descriptor_set_layouts: []const c.VkDescriptorSetLayout, data: []align(4) const u8) !Object {
        const push_constant_size: u32 = Shader.get(kind).push_constant_size;
        const push_constant_range: c.VkPushConstantRange = .{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .offset = 0,
            .size = push_constant_size,
        };
        const shader_create_info: c.VkShaderCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            .stage = stage,
            .nextStage = next_stage,
            .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
            .pName = entry_point.ptr,
            .pSetLayouts = descriptor_set_layouts.ptr,
            .setLayoutCount = @intCast(descriptor_set_layouts.len),
            .pPushConstantRanges = &push_constant_range,
            .pushConstantRangeCount = if (push_constant_size != 0) 1 else 0,
            .codeSize = data.len,
            .pCode = data.ptr,
        };
        var handle: c.VkShaderEXT = null;
        try check(ext.vkCreateShadersEXT(device.handle, 1, &shader_create_info, null, &handle));
        return .{ .device = device, .handle = handle };
    }

    pub fn deinit(self: *Object) void {
        ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    }
};

pub const Stages = struct {
    vert: Object,
    frag: Object,
};

pub fn init(self: *Shaders, gpa: std.mem.Allocator, device: Device, layouts: std.EnumArray(Shader.Descriptor, c.VkDescriptorSetLayout)) !void {
    const shaders = try gpa.alloc(Stages, Shader.Kind.count);
    for (shaders) |*pair| {
        pair.vert.handle = null;
        pair.frag.handle = null;
    }

    self.* = .{
        .gpa = gpa,
        .device = device,
        .layouts = layouts,
        .shaders = shaders,
    };
}

pub fn deinit(self: *Shaders) void {
    for (self.shaders) |*pair| for ([_]*Object{ &pair.vert, &pair.frag }) |shader| {
        if (shader.handle != null) shader.deinit();
    };
    self.gpa.free(self.shaders);
}

pub fn vert(self: *Shaders, kind: Shader.Kind) *Object {
    return &self.shaders[@intFromEnum(kind)].vert;
}

pub fn frag(self: *Shaders, kind: Shader.Kind) *Object {
    return &self.shaders[@intFromEnum(kind)].frag;
}

/// Replace one kind's GPU objects from bytes the producer read. Called while draining
/// DrawList.shader_uploads, before any command buffer for this frame is recorded.
pub fn apply(self: *Shaders, kind: Shader.Kind, spirv: []align(4) const u8) !void {
    const spec = Shader.get(kind);
    const pair = &self.shaders[@intFromEnum(kind)];

    var waited: bool = false;
    for ([_]*Object{ &pair.vert, &pair.frag }) |shader| {
        if (shader.handle == null) continue;
        if (!waited) {
            check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
            waited = true;
        }
        shader.deinit();
        shader.handle = null;
    }

    var layout_handles: [4]c.VkDescriptorSetLayout = undefined;
    for (spec.descriptors, 0..) |descriptor_kind, i| layout_handles[i] = self.layouts.get(descriptor_kind);

    if (spec.vert) |entry_point| pair.vert = try .init(self.device, kind, entry_point, c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT, layout_handles[0..spec.descriptors.len], spirv);
    if (spec.frag) |entry_point| pair.frag = try .init(self.device, kind, entry_point, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, layout_handles[0..spec.descriptors.len], spirv);
}
