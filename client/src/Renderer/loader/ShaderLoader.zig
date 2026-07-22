const ShaderLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const AssetServer = @import("../../AssetServer.zig");
const Device = @import("../Vulkan/device.zig").Logical;
const Shader = @import("../Vulkan/Shader.zig");
const DescriptorLayout = @import("../Vulkan/DesrciptorLayout.zig");
const check = @import("../Vulkan/utils.zig").check;

device: Device,
layouts: LayoutHandles,
items: []Shader,
files: [][]const u8,
interface: AssetServer.Loader,

pub const LayoutHandles = struct {
    scene: c.VkDescriptorSetLayout,
    material: c.VkDescriptorSetLayout,
    textures: c.VkDescriptorSetLayout,
    shadow: c.VkDescriptorSetLayout,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, device: Device, layouts: LayoutHandles) !ShaderLoader {
    const files = try gpa.alloc([]const u8, Shader.all_kinds.len);
    for (Shader.all_kinds, files) |kind, *file| {
        file.* = Shader.spec(kind).path["shaders/".len..];
    }

    const items = try gpa.alloc(Shader, Shader.all_kinds.len);
    for (items) |*shader| shader.handle = null;

    return .{
        .device = device,
        .layouts = layouts,
        .items = items,
        .files = files,
        .interface = .{
            .gpa = gpa,
            .io = io,
            .root_path = "shaders",
            .files = files,
            .vtable = &.{ .load = load, .unload = unload },
        },
    };
}

pub fn deinit(self: *ShaderLoader) void {
    const gpa = self.interface.gpa;
    for (self.items) |*shader| {
        if (shader.handle != null) shader.deinit();
    }
    gpa.free(self.items);
    gpa.free(self.files);
}

pub fn shaderPtr(self: *ShaderLoader, kind: Shader.Kind) *Shader {
    return &self.items[Shader.index(kind)];
}

pub fn verifyAllKindsLoaded(self: *const ShaderLoader) void {
    for (Shader.all_kinds) |kind| {
        if (self.items[Shader.index(kind)].handle == null)
            std.debug.panic("shader missing or failed to load: {s} -- run the build so glslc emits it", .{Shader.spec(kind).path});
    }
}

fn load(loader: *AssetServer.Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *ShaderLoader = @fieldParentPtr("interface", loader);
    const kind = Shader.all_kinds[index];
    const file = err_file catch |err| std.debug.panic(
        "shader missing: assets/shaders/{s} ({t})",
        .{ self.files[index], err },
    );
    if (self.items[index].handle == null) {
        const layout_handles: []const c.VkDescriptorSetLayout = switch (Shader.spec(kind).layout) {
            .scene_textures => &.{ self.layouts.scene, self.layouts.textures, self.layouts.shadow },
            .sky => &.{ self.layouts.scene, self.layouts.material },
            .ui => &.{self.layouts.textures},
        };
        self.items[index] = .init(self.device, kind, layout_handles);
    }
    try self.items[index].load(loader.gpa, loader.io, file);
}

fn unload(loader: *AssetServer.Loader, index: usize) void {
    const self: *ShaderLoader = @fieldParentPtr("interface", loader);
    if (self.items[index].handle == null) return;
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
    self.items[index].deinit();
    self.items[index].handle = null;
}
