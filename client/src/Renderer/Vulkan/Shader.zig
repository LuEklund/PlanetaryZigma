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

pub const ParticleInfo = struct {
    particle_count: u32,
    duration: f32,
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
};

pub const Spec = struct {
    path: []const u8,
    stages: []const Stage,
    layout: Layout,
    push_constant: PushConstantKind,
    particle: ?ParticleInfo,
};

const specs: std.EnumArray(Kind, Spec) = .init(.{
    .static = .{ .path = "shaders/mesh.spv", .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .skinned = .{ .path = "shaders/mesh.spv", .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .mesh = .{ .path = "shaders/mesh.spv", .stages = &.{.frag}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .shadow_static = .{ .path = "shaders/shadow.spv", .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .shadow_skinned = .{ .path = "shaders/shadow.spv", .stages = &.{.vert}, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .sky = .{ .path = "shaders/sky.spv", .stages = &.{ .vert, .frag }, .layout = .sky, .push_constant = .none, .particle = null },
    .ui = .{ .path = "shaders/ui.spv", .stages = &.{ .vert, .frag }, .layout = .ui, .push_constant = .ui, .particle = null },
    .debug = .{ .path = "shaders/debug.spv", .stages = &.{ .vert, .frag }, .layout = .scene_textures, .push_constant = .world, .particle = null },
    .explosion = .{
        .path = "shaders/particle/explosion.spv",
        .stages = &.{ .vert, .frag, .comp },
        .layout = .scene_textures,
        .push_constant = .particle,
        .particle = .{
            .particle_count = 40,
            .duration = 0.8,
            .topology = .quad,
        },
    },
    .lightning = .{
        .path = "shaders/particle/lightning.spv",
        .stages = &.{ .vert, .frag },
        .layout = .scene_textures,
        .push_constant = .particle,
        .particle = .{
            .particle_count = 64,
            .duration = 0.3,
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
        .ribbon => particle_info.particle_count - 1,
    };
}

pub fn hasStage(kind: Kind, stage: Stage) bool {
    return std.mem.indexOfScalar(Stage, get(kind).stages, stage) != null;
}

pub fn entryPoint(kind: Kind, stage: Stage) [:0]const u8 {
    return switch (kind) {
        inline else => |kind_tag| switch (stage) {
            inline else => |stage_tag| @tagName(kind_tag) ++ "_" ++ @tagName(stage_tag),
        },
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
    particle_buffer_address: c.VkDeviceAddress,
    emitter_buffer_address: c.VkDeviceAddress,
    elapsed_time: f32,
    delta_time: f32,
    particle_count: u32,
    particle_stride: u32,
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

pub fn pushConstantStages(push_constant: PushConstantKind) c.VkShaderStageFlags {
    return switch (push_constant) {
        .particle => c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT,
        .world, .ui, .none => c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
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
            .pName = entryPoint(kind, stage).ptr,
        },
        .handle = null,
        .push_constant_size = pushConstantSize(kind),
        .push_constant_stages = pushConstantStages(shader_spec.push_constant),
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
