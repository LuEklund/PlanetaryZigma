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
    debug,
    highlight_static,
    highlight_skinned,
    highlight_outline,

    particles,
    dvui,
    post_fullscreen,
    bloom_prefilter,
    bloom_blur,
    composite,
    fxaa,
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
    .static = .{
        .path = "mesh.spv",
        .vert = "static_vert",
        .frag = null,
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .skinned = .{
        .path = "mesh.spv",
        .vert = "skinned_vert",
        .frag = null,
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .mesh = .{
        .path = "mesh.spv",
        .vert = null,
        .frag = "mesh_frag",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .shadow_static = .{
        .path = "shadow.spv",
        .vert = "shadow_static_vert",
        .frag = null,
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .shadow_skinned = .{
        .path = "shadow.spv",
        .vert = "shadow_skinned_vert",
        .frag = null,
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .sky = .{
        .path = "sky.spv",
        .vert = "vertex",
        .frag = "fragment",
        .descriptors = &.{ .scene, .material },
        .push_constant_size = 0,
    },
    .debug = .{
        .path = "debug.spv",
        .vert = "vertex",
        .frag = "fragment",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .highlight_static = .{
        .path = "highlight.spv",
        .vert = "highlight_static_vert",
        .frag = "highlight_frag",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .highlight_skinned = .{
        .path = "highlight.spv",
        .vert = "highlight_skinned_vert",
        .frag = null,
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .highlight_outline = .{
        .path = "highlight.spv",
        .vert = "highlight_outline_vert",
        .frag = "highlight_outline_frag",
        .descriptors = &.{ .scene, .textures },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },

    .dvui = .{
        .path = "dvui.spv",
        .vert = "vertex",
        .frag = "fragment",
        .descriptors = &.{.textures},
        .push_constant_size = @sizeOf(DvuiPushConstant),
    },
    .post_fullscreen = .{
        .path = "post.spv",
        .vert = "fullscreen_vert",
        .frag = null,
        .descriptors = &.{ .scene, .textures },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .bloom_prefilter = .{
        .path = "post.spv",
        .vert = null,
        .frag = "bloom_prefilter_frag",
        .descriptors = &.{ .scene, .textures },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .bloom_blur = .{
        .path = "post.spv",
        .vert = null,
        .frag = "bloom_blur_frag",
        .descriptors = &.{ .scene, .textures },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .composite = .{
        .path = "post.spv",
        .vert = null,
        .frag = "composite_frag",
        .descriptors = &.{ .scene, .textures },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .fxaa = .{
        .path = "post.spv",
        .vert = null,
        .frag = "fxaa_frag",
        .descriptors = &.{ .scene, .textures },
        .push_constant_size = @sizeOf(WorldPushConstant),
    },
    .particles = .{
        .path = "particles.spv",
        .vert = "particles_vert",
        .frag = "particles_frag",
        .descriptors = &.{ .scene, .textures, .shadow },
        .push_constant_size = @sizeOf(ParticlePushConstant),
    },
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
    /// std430 puts the float4 below at 96.
    padding: [3]u32 = @splat(0),
    /// rgb multiplies albedo (elite tint), a blends toward a white hit flash.
    tint: [4]f32 = .{ 1, 1, 1, 0 },
};
pub const DvuiPushConstant = extern struct {
    vertex_buffer_address: VkDeviceAddress,
    screen_size: [2]f32,
    texture_index: u32,
};
pub const ParticlePushConstant = extern struct {
    emitter_buffer_address: VkDeviceAddress,
    effect_params_address: VkDeviceAddress,
    elapsed_time: f32,
    emitter_count: u32,
};
