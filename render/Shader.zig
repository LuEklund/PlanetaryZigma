const std = @import("std");

pub const Descriptor = enum {
    scene,
    material,
    textures,
    shadow,
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
    highlight_static,
    highlight_skinned,
    highlight_outline,

    particles,
    pub const count: usize = @typeInfo(Kind).@"enum".fields.len;
};

pub const Spec = struct {
    path: []const u8,
    vert: ?[:0]const u8,
    frag: ?[:0]const u8,
    descriptors: []const Descriptor,
    push_constant_size: u32,
};

const specs: std.EnumArray(Kind, Spec) = .init(.{
    .static = .{ .path = "mesh.spv", .vert = "static_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .skinned = .{ .path = "mesh.spv", .vert = "skinned_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .mesh = .{ .path = "mesh.spv", .vert = null, .frag = "mesh_frag", .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .shadow_static = .{ .path = "shadow.spv", .vert = "shadow_static_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .shadow_skinned = .{ .path = "shadow.spv", .vert = "shadow_skinned_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .sky = .{ .path = "sky.spv", .vert = "vertex", .frag = "fragment", .descriptors = &.{ .scene, .material }, .push_constant_size = 0 },
    .ui = .{ .path = "ui.spv", .vert = "vertex", .frag = "fragment", .descriptors = &.{.textures}, .push_constant_size = @sizeOf(UiPushConstant) },
    .debug = .{ .path = "debug.spv", .vert = "vertex", .frag = "fragment", .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .highlight_static = .{ .path = "highlight.spv", .vert = "highlight_static_vert", .frag = "highlight_frag", .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .highlight_skinned = .{ .path = "highlight.spv", .vert = "highlight_skinned_vert", .frag = null, .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(WorldPushConstant) },
    .highlight_outline = .{ .path = "highlight.spv", .vert = "highlight_outline_vert", .frag = "highlight_outline_frag", .descriptors = &.{ .scene, .textures }, .push_constant_size = @sizeOf(WorldPushConstant) },

    .particles = .{ .path = "particles.spv", .vert = "particles_vert", .frag = "particles_frag", .descriptors = &.{ .scene, .textures, .shadow }, .push_constant_size = @sizeOf(ParticlePushConstant) },
});

pub fn get(kind: Kind) Spec {
    return specs.get(kind);
}

pub const VkDeviceAddress = u64;

pub const WorldPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: VkDeviceAddress,
    joint_matrices_address: VkDeviceAddress,
    texture_index: u32,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: VkDeviceAddress,
    screen_size: [2]f32,
};
pub const ParticlePushConstant = extern struct {
    emitter_buffer_address: VkDeviceAddress,
    effect_params_address: VkDeviceAddress,
    elapsed_time: f32,
    emitter_count: u32,
};
