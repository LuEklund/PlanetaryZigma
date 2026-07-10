const std = @import("std");
const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const ext = @import("procs.zig").device.ProcTable;
pub const check = @import("utils.zig").check;

pub const AnimationPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
    joint_matrices_address: c.VkDeviceAddress,
};
pub const StaticPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: c.VkDeviceAddress,
    screnn_size: [2]f32,
};

pub const Kind = enum(u16) {
    vert_skinned,
    vert_static,
    vert_ui,
    vert_sky,
    vert_debug,
    frag_ui,
    frag_sky,
    frag_mesh,
    frag_debug,
};

pub const Spec = struct {
    path: []const u8,
    push_constant_size: u32,
    stage_bit: c.VkShaderStageFlagBits,
    layout: enum { scene_material, ui },
};

pub const specs: std.EnumArray(Kind, Spec) = .init(.{
    .vert_skinned = .{ .path = "shaders/animation.vert.spv", .push_constant_size = @sizeOf(AnimationPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_material },
    .vert_static = .{ .path = "shaders/static.vert.spv", .push_constant_size = @sizeOf(AnimationPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_material },
    .vert_ui = .{ .path = "shaders/ui.vert.spv", .push_constant_size = @sizeOf(UiPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .ui },
    .frag_ui = .{ .path = "shaders/ui.frag.spv", .push_constant_size = @sizeOf(UiPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .ui },
    .vert_sky = .{ .path = "shaders/sky.vert.spv", .push_constant_size = 0, .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_material },
    .frag_sky = .{ .path = "shaders/sky.frag.spv", .push_constant_size = 0, .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_material },
    .frag_mesh = .{ .path = "shaders/fragment.frag.spv", .push_constant_size = @sizeOf(AnimationPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_material },
    .vert_debug = .{ .path = "shaders/debug.vert.spv", .push_constant_size = @sizeOf(StaticPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_material },
    .frag_debug = .{ .path = "shaders/debug.frag.spv", .push_constant_size = @sizeOf(StaticPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_material },
});

handle: c.VkShaderEXT = null,
device: Device,
shader_create_info: c.VkShaderCreateInfoEXT,
descriptor_set_layouts: [5]c.VkDescriptorSetLayout,
descriptor_set_count: u32,
shader_name: []const u8,
push_constant_size: u32,

pub fn init(device: Device, kind: Kind, descriptor_set_layouts: []const c.VkDescriptorSetLayout) @This() {
    const shader_spec = specs.get(kind);
    var self: @This() = .{
        .device = device,
        .shader_create_info = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            .stage = shader_spec.stage_bit,
            .nextStage = if (shader_spec.stage_bit == c.VK_SHADER_STAGE_VERTEX_BIT) c.VK_SHADER_STAGE_FRAGMENT_BIT else 0,
            .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
            .pName = "main",
        },
        .shader_name = shader_spec.path,
        .handle = null,
        .push_constant_size = shader_spec.push_constant_size,
        .descriptor_set_count = @intCast(descriptor_set_layouts.len),
        .descriptor_set_layouts = undefined,
    };
    std.debug.assert(descriptor_set_layouts.len <= self.descriptor_set_layouts.len);
    @memcpy(self.descriptor_set_layouts[0..self.descriptor_set_count], descriptor_set_layouts);
    return self;
}

pub fn deinit(self: *@This()) void {
    ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
}

pub fn load(self: *@This(), gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !void {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len: usize = @intCast((try file.stat(io)).size);
    const data = try gpa.alignedAlloc(u8, .@"4", len);
    defer gpa.free(data);
    try reader.interface.readSliceAll(data);

    const ranges: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = self.push_constant_size,
    };
    if (self.push_constant_size != 0) {
        self.shader_create_info.pPushConstantRanges = &ranges;
        self.shader_create_info.pushConstantRangeCount = 1;
    } else {
        self.shader_create_info.pushConstantRangeCount = 0;
    }
    self.shader_create_info.pSetLayouts = &self.descriptor_set_layouts;
    self.shader_create_info.setLayoutCount = self.descriptor_set_count;
    self.shader_create_info.codeSize = len;
    self.shader_create_info.pCode = data.ptr;
    if (self.handle != null) ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    try check(ext.vkCreateShadersEXT(self.device.handle, 1, &self.shader_create_info, null, &self.handle));
}
