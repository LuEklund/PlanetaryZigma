const Shader = @This();

const std = @import("std");
const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const ext = @import("procs.zig").device.ProcTable;
const check = @import("utils.zig").check;

handle: c.VkShaderEXT = null,
device: Device,
shader_create_info: c.VkShaderCreateInfoEXT,
descriptor_set_layouts: [5]c.VkDescriptorSetLayout,
descriptor_set_count: u32,
push_constant_size: u32,

pub const specs: std.EnumArray(Kind, Spec) = .init(.{
    .vert_skinned = .{ .path = "shaders/animation.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
    .vert_static = .{ .path = "shaders/static.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
    .vert_particle = .{ .path = "shaders/particle.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
    .vert_ui = .{ .path = "shaders/ui.vert.spv", .push_constant_size = @sizeOf(UiPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .ui },
    .frag_ui = .{ .path = "shaders/ui.frag.spv", .push_constant_size = @sizeOf(UiPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .ui },
    .vert_sky = .{ .path = "shaders/sky.vert.spv", .push_constant_size = 0, .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .sky },
    .frag_sky = .{ .path = "shaders/sky.frag.spv", .push_constant_size = 0, .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .sky },
    .frag_mesh = .{ .path = "shaders/fragment.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
    .frag_particle = .{ .path = "shaders/particle.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
    .vert_debug = .{ .path = "shaders/debug.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
    .frag_debug = .{ .path = "shaders/debug.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
    .vert_shadow_static = .{ .path = "shaders/shadow_static.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
    .vert_shadow_skinned = .{ .path = "shaders/shadow_skinned.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
});

pub const Spec = struct {
    path: []const u8,
    push_constant_size: u32,
    stage_bit: c.VkShaderStageFlagBits,
    layout: enum { scene_textures, sky, ui },
};

pub const Kind = enum(u16) {
    vert_skinned,
    vert_static,
    vert_particle,
    vert_ui,
    vert_sky,
    vert_debug,
    vert_shadow_static,
    vert_shadow_skinned,
    frag_ui,
    frag_sky,
    frag_mesh,
    frag_particle,
    frag_debug,
};

pub const WorldPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
    joint_matrices_address: c.VkDeviceAddress,
    texture_index: u32,
    _: u32 = 0,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: c.VkDeviceAddress,
    screnn_size: [2]f32,
};

pub fn init(device: Device, kind: Kind, descriptor_set_layouts: []const c.VkDescriptorSetLayout) Shader {
    const shader_spec = specs.get(kind);
    var self: Shader = .{
        .device = device,
        .shader_create_info = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            .stage = shader_spec.stage_bit,
            .nextStage = if (shader_spec.stage_bit == c.VK_SHADER_STAGE_VERTEX_BIT) c.VK_SHADER_STAGE_FRAGMENT_BIT else 0,
            .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
            .pName = "main",
        },
        .handle = null,
        .push_constant_size = shader_spec.push_constant_size,
        .descriptor_set_count = @intCast(descriptor_set_layouts.len),
        .descriptor_set_layouts = undefined,
    };
    std.debug.assert(descriptor_set_layouts.len <= self.descriptor_set_layouts.len);
    @memcpy(self.descriptor_set_layouts[0..self.descriptor_set_count], descriptor_set_layouts);
    return self;
}

pub fn deinit(self: *Shader) void {
    ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
}

pub fn load(self: *Shader, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File) !void {
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
