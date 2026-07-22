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

pub const Stage = enum { vert, frag };
pub const Layout = enum { scene_textures, sky, ui };
pub const PushConstantKind = enum { world, ui, none };

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
    explosion_vert,
    lightning_vert,
    explosion_frag,
    lightning_frag,
};

pub const Spec = struct {
    path: []const u8,
    stage: Stage,
    layout: Layout,
    push_constant: PushConstantKind,
};

const specs: std.EnumArray(Kind, Spec) = .init(.{
    .skinned_vert = .{ .path = "shaders/skinned.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .static_vert = .{ .path = "shaders/static.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .ui_vert = .{ .path = "shaders/ui.vert.spv", .stage = .vert, .layout = .ui, .push_constant = .ui },
    .sky_vert = .{ .path = "shaders/sky.vert.spv", .stage = .vert, .layout = .sky, .push_constant = .none },
    .debug_vert = .{ .path = "shaders/debug.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .shadow_static_vert = .{ .path = "shaders/shadow_static.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .shadow_skinned_vert = .{ .path = "shaders/shadow_skinned.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .ui_frag = .{ .path = "shaders/ui.frag.spv", .stage = .frag, .layout = .ui, .push_constant = .ui },
    .sky_frag = .{ .path = "shaders/sky.frag.spv", .stage = .frag, .layout = .sky, .push_constant = .none },
    .mesh_frag = .{ .path = "shaders/mesh.frag.spv", .stage = .frag, .layout = .scene_textures, .push_constant = .world },
    .debug_frag = .{ .path = "shaders/debug.frag.spv", .stage = .frag, .layout = .scene_textures, .push_constant = .world },
    .explosion_vert = .{ .path = "shaders/particle/explosion.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .lightning_vert = .{ .path = "shaders/particle/lightning.vert.spv", .stage = .vert, .layout = .scene_textures, .push_constant = .world },
    .explosion_frag = .{ .path = "shaders/particle/explosion.frag.spv", .stage = .frag, .layout = .scene_textures, .push_constant = .world },
    .lightning_frag = .{ .path = "shaders/particle/lightning.frag.spv", .stage = .frag, .layout = .scene_textures, .push_constant = .world },
});

pub fn get(kind: Kind) Spec {
    return specs.get(kind);
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

fn pushConstantSize(kind: Kind) u32 {
    return switch (get(kind).push_constant) {
        .world => @sizeOf(WorldPushConstant),
        .ui => @sizeOf(UiPushConstant),
        .none => 0,
    };
}

pub fn init(device: Device, kind: Kind, descriptor_set_layouts: []const c.VkDescriptorSetLayout) Shader {
    const shader_def = get(kind);
    var self: Shader = .{
        .device = device,
        .shader_create_info = .{
            .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
            .stage = switch (shader_def.stage) {
                .vert => c.VK_SHADER_STAGE_VERTEX_BIT,
                .frag => c.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
            .nextStage = switch (shader_def.stage) {
                .vert => c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .frag => 0,
            },
            .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
            .pName = "main",
        },
        .handle = null,
        .push_constant_size = pushConstantSize(kind),
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
