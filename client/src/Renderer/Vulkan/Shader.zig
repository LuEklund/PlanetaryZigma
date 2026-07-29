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
push_constant_stages: c.VkShaderStageFlags,

pub const Stage = enum { vert, frag, comp };
pub const Layout = enum { scene_textures, sky, ui };
pub const PushConstantKind = enum { world, ui, particle, none };
pub const Topology = enum { quad, ribbon };

/// glsl = one file per stage, entry point always "main".
/// slang = one file holding every stage, entry point named after the stage.
pub const Source = enum { glsl, slang };

/// Layer 1 of a particle effect: emitter config. Layer 2 (sim) and 4 (shading)
/// live in the .slang; layer 3 (geometry) is picked by `topology`.
pub const ParticleInfo = struct {
    particle_count: u32,
    duration: f32,
    topology: Topology,
    texture_name: []const u8,
    texture_edge_color: [3]f32,
    texture_center_color: [3]f32,
};

/// One arm per FILE. A slang file carries several stages, so this is no longer
/// one-arm-per-shader-object.
pub const Kind = enum {
    skinned_vert,
    static_vert,
    ui_vert,
    sky_vert,
    debug_vert,
    shadow_static_vert,
    shadow_skinned_vert,
    ui_frag,
    sky_frag,
    mesh_frag,
    debug_frag,
    explosion,
    lightning,
};

pub const Spec = struct {
    path: []const u8,
    source: Source,
    stages: []const Stage,
    layout: Layout,
    push_constant: PushConstantKind,
    particle: ?ParticleInfo,
};

const specs: std.EnumArray(Kind, Spec) = .init(.{
    .skinned_vert = .{ .path = "shaders/skinned.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .static_vert = .{ .path = "shaders/static.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .ui_vert = .{ .path = "shaders/ui.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .ui, .push_constant = .ui, .particle = null },
    .sky_vert = .{ .path = "shaders/sky.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .sky, .push_constant = .none, .particle = null },
    .debug_vert = .{ .path = "shaders/debug.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .shadow_static_vert = .{ .path = "shaders/shadow_static.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .shadow_skinned_vert = .{ .path = "shaders/shadow_skinned.vert.spv", .source = .glsl, .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .ui_frag = .{ .path = "shaders/ui.frag.spv", .source = .glsl, .stages = &.{.frag}, .layout = .ui, .push_constant = .ui, .particle = null },
    .sky_frag = .{ .path = "shaders/sky.frag.spv", .source = .glsl, .stages = &.{.frag}, .layout = .sky, .push_constant = .none, .particle = null },
    .mesh_frag = .{ .path = "shaders/mesh.frag.spv", .source = .glsl, .stages = &.{.frag}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .debug_frag = .{ .path = "shaders/debug.frag.spv", .source = .glsl, .stages = &.{.frag}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .explosion = .{
        .path = "shaders/particle/explosion.spv",
        .source = .slang,
        .stages = &.{ .vert, .frag },
        .layout = .scene_textures,
        .push_constant = .world,
        .particle = .{
            .particle_count = 40,
            .duration = 0.8,
            .topology = .quad,
            .texture_name = "explosion_particle",
            .texture_edge_color = .{ 255, 70, 12 },
            .texture_center_color = .{ 255, 235, 48 },
        },
    },
    .lightning = .{
        .path = "shaders/particle/lightning.spv",
        .source = .slang,
        .stages = &.{ .vert, .frag },
        .layout = .scene_textures,
        .push_constant = .world,
        .particle = .{
            .particle_count = 64,
            .duration = 0.3,
            .topology = .ribbon,
            .texture_name = "lightning_particle",
            .texture_edge_color = .{ 110, 160, 255 },
            .texture_center_color = .{ 255, 255, 255 },
        },
    },
});

pub fn get(kind: Kind) Spec {
    return specs.get(kind);
}

pub fn particleInfo(kind: Kind) ParticleInfo {
    return get(kind).particle orelse std.debug.panic("shader {t} is not a particle effect", .{kind});
}

pub fn entryPoint(source: Source, stage: Stage) [:0]const u8 {
    return switch (source) {
        .glsl => "main",
        .slang => switch (stage) {
            .vert => "vertMain",
            .frag => "fragMain",
            .comp => "computeMain",
        },
    };
}

pub const WorldPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
    joint_matrices_address: c.VkDeviceAddress,
    texture_index: u32,
    particle_count: u32 = 0,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: c.VkDeviceAddress,
    screnn_size: [2]f32,
};
pub const ParticlePushConstant = extern struct {
    particle_buffer_address: c.VkDeviceAddress,
    emitter_buffer_address: c.VkDeviceAddress,
    elapsed_time: f32,
    delta_time: f32,
    particles_per_effect: u32,
    emitter_count: u32,
};

fn pushConstantSize(kind: Kind) u32 {
    return switch (get(kind).push_constant) {
        .world => @sizeOf(WorldPushConstant),
        .ui => @sizeOf(UiPushConstant),
        .particle => @sizeOf(ParticlePushConstant),
        .none => 0,
    };
}

pub fn init(device: Device, kind: Kind, stage: Stage, descriptor_set_layouts: []const c.VkDescriptorSetLayout) Shader {
    const shader_spec = get(kind);
    var self: Shader = .{
        .device = device,
        .shader_create_info = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            .stage = switch (stage) {
                .vert => c.VK_SHADER_STAGE_VERTEX_BIT,
                .frag => c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .comp => c.VK_SHADER_STAGE_COMPUTE_BIT,
            },
            .nextStage = switch (stage) {
                .vert => c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .frag, .comp => 0,
            },
            .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
            .pName = entryPoint(shader_spec.source, stage).ptr,
        },
        .handle = null,
        .push_constant_size = pushConstantSize(kind),
        .push_constant_stages = switch (stage) {
            .vert, .frag => c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .comp => c.VK_SHADER_STAGE_COMPUTE_BIT,
        },
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

pub fn load(self: *Shader, data: []align(4) const u8) !void {
    const ranges: c.VkPushConstantRange = .{
        .stageFlags = self.push_constant_stages,
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
    self.shader_create_info.codeSize = data.len;
    self.shader_create_info.pCode = data.ptr;
    if (self.handle != null) ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    try check(ext.vkCreateShadersEXT(self.device.handle, 1, &self.shader_create_info, null, &self.handle));
}
