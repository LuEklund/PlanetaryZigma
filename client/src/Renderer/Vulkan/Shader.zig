const std = @import("std");
const c = @import("vulkan");
const AssetServer = @import("shared").AssetServer;
const Device = @import("device.zig").Logical;
const ext = @import("procs.zig").device.ProcTable;
pub const check = @import("utils.zig").check;

handle: c.VkShaderEXT = null,
device: Device,
shader_create_info: c.VkShaderCreateInfoEXT,
descriptor_set_layouts: [5]c.VkDescriptorSetLayout,
descriptor_set_count: u32,
shader_name: []const u8,
push_constant_size: u32,

pub const AnimationPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
    inverse_bind_matrices_addess: c.VkDeviceAddress,
};
pub const StaticPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: c.VkDeviceAddress,
    screnn_size: [2]f32,
};

pub fn init(
    gpa: std.mem.Allocator,
    device: Device,
    asset_server: *AssetServer,
    shader_create_info: c.VkShaderCreateInfoEXT,
    descriptor_set_layouts: []const c.VkDescriptorSetLayout,
    shader_name: []const u8,
    push_constant_type: type,
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .device = device,
        .shader_create_info = shader_create_info,
        .shader_name = shader_name,
        .handle = null,
        .push_constant_size = @sizeOf(push_constant_type),
        .descriptor_set_count = @intCast(descriptor_set_layouts.len),
        .descriptor_set_layouts = undefined,
    };
    std.debug.assert(descriptor_set_layouts.len <= self.descriptor_set_layouts.len);
    @memcpy(self.descriptor_set_layouts[0..self.descriptor_set_count], descriptor_set_layouts);
    self.shader_create_info.pSetLayouts = &self.descriptor_set_layouts;
    self.shader_create_info.setLayoutCount = self.descriptor_set_count;
    try asset_server.loadAsset(@This(), self, shader_name, loadShader);
    return self;
}
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    // self.* = undefined;
    gpa.destroy(self);
}

fn loadShader(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;
    const self: *@This() = @ptrCast(@alignCast(user_data));
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
    self.shader_create_info.codeSize = len;
    self.shader_create_info.pCode = data.ptr;
    if (self.handle != null) ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    try check(ext.vkCreateShadersEXT(self.device.handle, 1, &self.shader_create_info, null, &self.handle));
}
