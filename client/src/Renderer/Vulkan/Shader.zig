const Shader = @This();

const std = @import("std");
const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const ext = @import("procs.zig").device.ProcTable;
const check = @import("utils.zig").check;
const DescriptorLayout = @import("DesrciptorLayout.zig");

handle: c.VkShaderEXT,
device: Device,

pub const Topology = enum { quad, ribbon };

pub const ParticleInfo = struct {
    particle_count: u32,
    strands: u32,
    duration: ?f32,
    topology: Topology,
};

pub const Kind = enum {
    static,
    skinned,
    mesh,
    shadow_static,
    shadow_skinned,
    sky,
    ui,
    debug,
    explosion,
    lightning,
    item_effect,
    pub const count: usize = @typeInfo(Kind).@"enum".fields.len;
};

pub const Spec = struct {
    path: []const u8,
    vert: ?[:0]const u8,
    frag: ?[:0]const u8,
    descriptors: []const DescriptorLayout.Kind,
    push_constant_size: u32,
    particle: ?ParticleInfo,
};

const specs: std.EnumArray(Kind, Spec) = .init(.{
    .static = .{ .path = "mesh.spv", .vert = "static_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant), .particle = null },
    .skinned = .{ .path = "mesh.spv", .vert = "skinned_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant), .particle = null },
    .mesh = .{ .path = "mesh.spv", .vert = null, .frag = "mesh_frag", .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant), .particle = null },
    .shadow_static = .{ .path = "shadow.spv", .vert = "shadow_static_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant), .particle = null },
    .shadow_skinned = .{ .path = "shadow.spv", .vert = "shadow_skinned_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant), .particle = null },
    .sky = .{ .path = "sky.spv", .vert = "vertex", .frag = "fragment", .descriptors = &.{ .scene, .material }, .push_constant_size = 0, .particle = null },
    .ui = .{ .path = "ui.spv", .vert = "vertex", .frag = "fragment", .descriptors = &.{.textures}, .push_constant_size = @sizeOf(UiPushConstant), .particle = null },
    .debug = .{ .path = "debug.spv", .vert = "vertex", .frag = "fragment", .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant), .particle = null },
    .explosion = .{
        .path = "particle/explosion.spv",
        .vert = "vertex",
        .frag = "fragment",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(ParticlePushConstant),
        .particle = .{
            .particle_count = 40,
            .strands = 1,
            .duration = 0.8,
            .topology = .quad,
        },
    },
    .lightning = .{
        .path = "particle/lightning.spv",
        .vert = "vertex",
        .frag = "fragment",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(ParticlePushConstant),
        .particle = .{
            .particle_count = 64,
            .strands = 1,
            .duration = 0.3,
            .topology = .ribbon,
        },
    },
    .item_effect = .{
        .path = "particle/item_effect.spv",
        .vert = "vertex",
        .frag = "fragment",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(ParticlePushConstant),
        .particle = .{
            .particle_count = 154,
            .strands = 7,
            .duration = null,
            .topology = .ribbon,
        },
    },
});

pub fn get(kind: Kind) Spec {
    return specs.get(kind);
}

pub fn particleInfo(kind: Kind) ParticleInfo {
    return get(kind).particle orelse std.debug.panic("shader {t} is not a particle effect", .{kind});
}

pub fn instancesPerEmitter(kind: Kind) u32 {
    const particle_info = particleInfo(kind);
    return switch (particle_info.topology) {
        .quad => particle_info.particle_count,
        .ribbon => particle_info.particle_count - particle_info.strands,
    };
}

pub const WorldPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
    joint_matrices_address: c.VkDeviceAddress,
    texture_index: u32,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: c.VkDeviceAddress,
    screnn_size: [2]f32,
};
pub const ParticlePushConstant = extern struct {
    emitter_buffer_address: c.VkDeviceAddress,
    elapsed_time: f32,
    particle_count: u32,
    emitter_count: u32,
    duration: f32,
};

pub fn init(device: Device, kind: Kind, entry_point: [:0]const u8, stage: c.VkShaderStageFlagBits, next_stage: c.VkShaderStageFlags, descriptor_set_layouts: []const c.VkDescriptorSetLayout, data: []align(4) const u8) !Shader {
    const push_constant_size: u32 = get(kind).push_constant_size;
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

pub fn deinit(self: *Shader) void {
    ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
}
