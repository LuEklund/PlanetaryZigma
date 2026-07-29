const ShaderLoader = @This();

const std = @import("std");
const c = @import("vulkan");
const Loader = @import("../../AssetServer.zig").Loader;
const Device = @import("../Vulkan/device.zig").Logical;
const Shader = @import("../Vulkan/Shader.zig");
const DescriptorLayout = @import("../Vulkan/DesrciptorLayout.zig");
const check = @import("../Vulkan/utils.zig").check;

device: Device,
layouts: LayoutHandles,
shaders: []StageSlots,
interface: Loader,

/// One row per file, one slot per stage. Files that lack a stage just leave
/// that slot null -- a few unused slots is cheaper than index arithmetic.
pub const StageSlots = [std.enums.values(Shader.Stage).len]Shader;

pub const LayoutHandles = struct {
    scene: c.VkDescriptorSetLayout,
    material: c.VkDescriptorSetLayout,
    textures: c.VkDescriptorSetLayout,
    shadow: c.VkDescriptorSetLayout,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, device: Device, layouts: LayoutHandles) !ShaderLoader {
    const files = try gpa.alloc([]const u8, std.enums.values(Shader.Kind).len);
    for (std.enums.values(Shader.Kind), files) |kind, *file| {
        file.* = Shader.get(kind).path["shaders/".len..];
    }

    const shaders = try gpa.alloc(StageSlots, std.enums.values(Shader.Kind).len);
    for (shaders) |*slots| for (slots) |*shader| {
        shader.handle = null;
    };

    return .{
        .device = device,
        .layouts = layouts,
        .shaders = shaders,
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
    for (self.shaders) |*slots| for (slots) |*shader| {
        if (shader.handle != null) shader.deinit();
    };
    gpa.free(self.shaders);
    gpa.free(self.interface.files);
}

pub fn shaderPtr(self: *ShaderLoader, kind: Shader.Kind, stage: Shader.Stage) *Shader {
    return &self.shaders[@intFromEnum(kind)][@intFromEnum(stage)];
}

pub fn verifyAllKindsLoaded(self: *const ShaderLoader) void {
    for (std.enums.values(Shader.Kind)) |kind| {
        for (Shader.get(kind).stages) |stage| {
            if (self.shaders[@intFromEnum(kind)][@intFromEnum(stage)].handle == null)
                std.debug.panic("shader missing or failed to load: {s} ({t}) -- run the build so the .spv is emitted", .{ Shader.get(kind).path, stage });
        }
    }
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

    // A slang file holds every stage, so one file change rebuilds all of them.
    for (spec.stages) |stage| {
        const shader = &self.shaders[@intFromEnum(kind)][@intFromEnum(stage)];
        if (shader.handle == null) {
            const layout_handles: []const c.VkDescriptorSetLayout = switch (spec.layout) {
                .scene_textures => &.{ self.layouts.scene, self.layouts.textures, self.layouts.shadow },
                .sky => &.{ self.layouts.scene, self.layouts.material },
                .ui => &.{self.layouts.textures},
            };
            shader.* = .init(self.device, kind, stage, layout_handles);
        }
        try shader.load(data);
    }
}

fn unload(loader: *Loader, index: usize) void {
    const self: *ShaderLoader = @fieldParentPtr("interface", loader);
    const kind: Shader.Kind = @enumFromInt(index);
    var waited: bool = false;
    for (Shader.get(kind).stages) |stage| {
        const shader = &self.shaders[@intFromEnum(kind)][@intFromEnum(stage)];
        if (shader.handle == null) continue;
        if (!waited) {
            check(c.vkDeviceWaitIdle(self.device.handle)) catch {};
            waited = true;
        }
        shader.deinit();
        shader.handle = null;
    }
}
