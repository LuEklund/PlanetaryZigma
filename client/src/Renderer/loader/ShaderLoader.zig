const ShaderLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const AssetServer = @import("../../AssetServer.zig");
const Loader = AssetServer.Loader;
const Device = @import("../Vulkan/device.zig").Logical;
const Shader = @import("../Vulkan/Shader.zig");
const DescriptorLayout = @import("../Vulkan/DesrciptorLayout.zig");
const check = @import("../Vulkan/utils.zig").check;

device: Device,
layouts: std.EnumArray(DescriptorLayout.Kind, c.VkDescriptorSetLayout),
shaders: []Stages,
interface: Loader,

pub const Stages = struct {
    vert: Shader,
    frag: Shader,
};

pub fn init(self: *ShaderLoader, gpa: std.mem.Allocator, asset_server: *AssetServer, device: Device, layouts: std.EnumArray(DescriptorLayout.Kind, c.VkDescriptorSetLayout)) !void {
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
    for (self.shaders) |*pair| for ([_]*Shader{ &pair.vert, &pair.frag }) |shader| {
        if (shader.handle != null) shader.deinit();
    };
    gpa.free(self.shaders);
    gpa.free(self.interface.files);
}

pub fn vert(self: *ShaderLoader, kind: Shader.Kind) *Shader {
    return &self.shaders[@intFromEnum(kind)].vert;
}

pub fn frag(self: *ShaderLoader, kind: Shader.Kind) *Shader {
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
    for ([_]*Shader{ &pair.vert, &pair.frag }) |shader| {
        if (shader.handle == null) continue;
        if (!waited) {
            check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
            waited = true;
        }
        shader.deinit();
        shader.handle = null;
    }
}
