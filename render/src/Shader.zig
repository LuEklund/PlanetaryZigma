const std = @import("std");

pub const Topology = enum { quad, ribbon };

pub const Descriptor = enum {
    scene,
    material,
    textures,
    shadow,
};

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
    descriptors: []const Descriptor,
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
    elapsed_time: f32,
    particle_count: u32,
    emitter_count: u32,
    duration: f32,
};
