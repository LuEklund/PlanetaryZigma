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

pub const Vert = enum { skinned, static, ui, sky, debug, shadow_static, shadow_skinned };
pub const FragNormal = enum { ui, sky, mesh, debug };
pub const ParticleEffect = enum { explosion, lightning };

pub const Kind = union(enum) {
    vert: Vert,
    frag_normal: FragNormal,
    vert_particle: ParticleEffect,
    frag_particle: ParticleEffect,
};

pub const all_kinds: []const Kind = blk: {
    var kinds: []const Kind = &.{};
    for (std.enums.values(Vert)) |sub| kinds = kinds ++ .{Kind{ .vert = sub }};
    for (std.enums.values(FragNormal)) |sub| kinds = kinds ++ .{Kind{ .frag_normal = sub }};
    for (std.enums.values(ParticleEffect)) |sub| kinds = kinds ++ .{Kind{ .vert_particle = sub }};
    for (std.enums.values(ParticleEffect)) |sub| kinds = kinds ++ .{Kind{ .frag_particle = sub }};
    break :blk kinds;
};

pub fn index(kind: Kind) usize {
    const vert_count = std.enums.values(Vert).len;
    const frag_normal_count = std.enums.values(FragNormal).len;
    const effect_count = std.enums.values(ParticleEffect).len;
    return switch (kind) {
        .vert => |sub| @intFromEnum(sub),
        .frag_normal => |sub| vert_count + @intFromEnum(sub),
        .vert_particle => |sub| vert_count + frag_normal_count + @intFromEnum(sub),
        .frag_particle => |sub| vert_count + frag_normal_count + effect_count + @intFromEnum(sub),
    };
}

pub const EffectSpec = struct {
    particle_count: u32,
    duration: f32,
};

pub fn effectSpec(effect: ParticleEffect) EffectSpec {
    return switch (effect) {
        .explosion => .{ .particle_count = 40, .duration = 0.8 },
        .lightning => .{ .particle_count = 64, .duration = 0.3 },
    };
}

pub const Spec = struct {
    path: []const u8,
    push_constant_size: u32,
    stage_bit: c.VkShaderStageFlagBits,
    layout: enum { scene_textures, sky, ui },
};

pub fn spec(kind: Kind) Spec {
    return switch (kind) {
        .vert => |vert_kind| switch (vert_kind) {
            .skinned => .{ .path = "shaders/skinned.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
            .static => .{ .path = "shaders/static.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
            .ui => .{ .path = "shaders/ui.vert.spv", .push_constant_size = @sizeOf(UiPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .ui },
            .sky => .{ .path = "shaders/sky.vert.spv", .push_constant_size = 0, .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .sky },
            .debug => .{ .path = "shaders/debug.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
            .shadow_static => .{ .path = "shaders/shadow_static.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
            .shadow_skinned => .{ .path = "shaders/shadow_skinned.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
        },
        .frag_normal => |frag_kind| switch (frag_kind) {
            .ui => .{ .path = "shaders/ui.frag.spv", .push_constant_size = @sizeOf(UiPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .ui },
            .sky => .{ .path = "shaders/sky.frag.spv", .push_constant_size = 0, .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .sky },
            .mesh => .{ .path = "shaders/mesh.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
            .debug => .{ .path = "shaders/debug.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
        },
        .vert_particle => |effect| switch (effect) {
            .explosion => .{ .path = "shaders/particle/explosion.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
            .lightning => .{ .path = "shaders/particle/lightning.vert.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_VERTEX_BIT, .layout = .scene_textures },
        },
        .frag_particle => |effect| switch (effect) {
            .explosion => .{ .path = "shaders/particle/explosion.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
            .lightning => .{ .path = "shaders/particle/lightning.frag.spv", .push_constant_size = @sizeOf(WorldPushConstant), .stage_bit = c.VK_SHADER_STAGE_FRAGMENT_BIT, .layout = .scene_textures },
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

pub fn init(device: Device, kind: Kind, descriptor_set_layouts: []const c.VkDescriptorSetLayout) Shader {
    const shader_spec = spec(kind);
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
