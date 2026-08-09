//! Reads shader bytes on THIS side of the boundary and hands them to the backend as data.
//!
//! The vtable is not the bug — a loader living inside render.so is. This one is compiled
//! into the consumer, so the pointers AssetServer holds stay valid across a render swap,
//! which is what `vulkan/root.zig`'s renderReload comment is about.

const ShaderSource = @This();

const std = @import("std");
const Shader = @import("contract").Shader;
const AssetServer = @import("assets").AssetServer;
const render = @import("contract");

const Loader = AssetServer.Loader;

gpa: std.mem.Allocator,
/// One owned buffer per kind, kept so a reload can free the previous bytes.
spirv: [Shader.Kind.count]?[]align(4) u8,
/// Read only inside `load`, which the owner runs after the renderer exists.
renderer: *const render.Renderer,
interface: Loader,

pub fn init(
    self: *ShaderSource,
    gpa: std.mem.Allocator,
    asset_server: *AssetServer,
    renderer: *const render.Renderer,
) !void {
    const files = try gpa.alloc([]const u8, Shader.Kind.count);
    for (std.enums.values(Shader.Kind), files) |kind, *file| file.* = Shader.get(kind).path;

    self.* = .{
        .gpa = gpa,
        .spirv = @splat(null),
        .renderer = renderer,
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

pub fn deinit(self: *ShaderSource) void {
    for (&self.spirv) |*slot| if (slot.*) |bytes| self.gpa.free(bytes);
    self.gpa.free(self.interface.files);
}

fn load(loader: *Loader, err_file: std.Io.File.OpenError!std.Io.File, index: usize) !void {
    const self: *ShaderSource = @fieldParentPtr("interface", loader);
    const file = err_file catch |err| std.debug.panic(
        "shader missing: assets/shaders/{s} ({t})",
        .{ loader.files[index], err },
    );

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(loader.io, &buffer);
    const len: usize = @intCast((try file.stat(loader.io)).size);
    const bytes = try self.gpa.alignedAlloc(u8, .@"4", len);
    errdefer self.gpa.free(bytes);
    try reader.interface.readSliceAll(bytes);

    if (self.spirv[index]) |old| self.gpa.free(old);
    self.spirv[index] = bytes;

    self.renderer.vtable.uploadShader(self.renderer.userdata, @intCast(index), bytes.ptr, bytes.len);
}

fn unload(loader: *Loader, index: usize) void {
    const self: *ShaderSource = @fieldParentPtr("interface", loader);
    _ = index;
    _ = self;
    // Nothing to drop here: the bytes stay owned until the next load replaces them, and
    // the GPU objects are the backend's to destroy when it applies the next upload.
}
