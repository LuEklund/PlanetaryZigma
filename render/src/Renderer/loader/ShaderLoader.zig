const ShaderLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const AssetServer = @import("../../AssetServer.zig");
const Loader = AssetServer.Loader;
const Device = @import("../Vulkan/device.zig").Logical;
const Shader = @import("../Vulkan/Shader.zig");
const DescriptorLayout = @import("../Vulkan/DescriptorLayout.zig");
const check = @import("../Vulkan/utils.zig").check;
const ext = @import("../Vulkan/procs.zig").device.ProcTable;

device: Device,
layouts: std.EnumArray(Shader.Descriptor, c.VkDescriptorSetLayout),
shaders: []Stages,
interface: Loader,

pub const Object = struct {
    handle: c.VkShaderEXT,
    device: Device,

    pub fn init(device: Device, kind: Shader.Kind, entry_point: [:0]const u8, stage: c.VkShaderStageFlagBits, next_stage: c.VkShaderStageFlags, descriptor_set_layouts: []const c.VkDescriptorSetLayout, data: []align(4) const u8) !Object {
        const push_constant_size: u32 = Shader.get(kind).push_constant_size;
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

    pub fn deinit(self: *Object) void {
        ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    }
};

pub const Stages = struct {
    vert: Object,
    frag: Object,
};

pub fn init(self: *ShaderLoader, gpa: std.mem.Allocator, asset_server: *AssetServer, device: Device, layouts: std.EnumArray(Shader.Descriptor, c.VkDescriptorSetLayout)) !void {
    const files = try gpa.alloc([]const u8, Shader.Kind.count);
    for (std.enums.values(Shader.Kind), files) |kind, *file| {
        file.* = Shader.get(kind).path;
    }

    const shaders = try gpa.alloc(Stages, Shader.Kind.count);
    for (shaders) |*pair| {
        pair.vert.handle = null;
        pair.frag.handle = null;
    }

    self.* = .{
        .device = device,
        .layouts = layouts,
        .shaders = shaders,
        .interface = .{
            .gpa = gpa,
            .io = asset_server.io,
            .root_path = "shaders",
            .files = files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
    try asset_server.addLoader(&self.interface);
}

pub fn deinit(self: *ShaderLoader) void {
    const gpa = self.interface.gpa;
    for (self.shaders) |*pair| for ([_]*Object{ &pair.vert, &pair.frag }) |shader| {
        if (shader.handle != null) shader.deinit();
    };
    gpa.free(self.shaders);
    gpa.free(self.interface.files);
}

pub fn vert(self: *ShaderLoader, kind: Shader.Kind) *Object {
    return &self.shaders[@intFromEnum(kind)].vert;
}

pub fn frag(self: *ShaderLoader, kind: Shader.Kind) *Object {
    return &self.shaders[@intFromEnum(kind)].frag;
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *ShaderLoader = @fieldParentPtr("interface", loader);
    const kind: Shader.Kind = @enumFromInt(index);
    const spec = Shader.get(kind);
    const file = err_file catch |err| std.debug.panic(
        "shader missing: assets/shaders/{s} ({t})",
        .{ loader.files[index], err },
    );

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(loader.io, &buffer);
    const len: usize = @intCast((try file.stat(loader.io)).size);
    const data = try loader.gpa.alignedAlloc(u8, .@"4", len);
    defer loader.gpa.free(data);
    try reader.interface.readSliceAll(data);

    var layout_handles: [4]c.VkDescriptorSetLayout = undefined;
    for (spec.descriptors, 0..) |descriptor_kind, i| layout_handles[i] = self.layouts.get(descriptor_kind);

    const pair = &self.shaders[@intFromEnum(kind)];
    if (spec.vert) |entry_point| pair.vert = try .init(self.device, kind, entry_point, c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT, layout_handles[0..spec.descriptors.len], data);
    if (spec.frag) |entry_point| pair.frag = try .init(self.device, kind, entry_point, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, layout_handles[0..spec.descriptors.len], data);
}

fn unload(loader: *Loader, index: usize) void {
    const self: *ShaderLoader = @fieldParentPtr("interface", loader);
    const kind: Shader.Kind = @enumFromInt(index);
    var waited: bool = false;
    const pair = &self.shaders[@intFromEnum(kind)];
    for ([_]*Object{ &pair.vert, &pair.frag }) |shader| {
        if (shader.handle == null) continue;
        if (!waited) {
            check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
            waited = true;
        }
        shader.deinit();
        shader.handle = null;
    }
}
