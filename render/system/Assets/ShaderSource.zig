//! Reads shader bytes on THIS side of the boundary and hands them to the backend as data.
//!
//! The vtable is not the bug — a loader living inside render.so is. This one is compiled
//! into the consumer, so the pointers AssetServer holds stay valid across a render swap,
//! which is what `vulkan/root.zig`'s renderReload comment is about.

const ShaderSource = @This();

const std = @import("std");
const Shader = @import("shared").Shader;
const AssetServer = @import("assets").AssetServer;
const DrawList = @import("render").DrawList;

const Loader = AssetServer.Loader;

gpa: std.mem.Allocator,
/// One owned buffer per kind, kept so a reload can free the previous bytes.
spirv: [Shader.Kind.count]?[]align(4) u8,
/// The frame's upload queue, owned by Assets. Sources append; nobody keeps a private one.
pending: *std.ArrayList(DrawList.AssetUpload),
interface: Loader,

pub fn init(
    self: *ShaderSource,
    gpa: std.mem.Allocator,
    asset_server: *AssetServer,
    pending: *std.ArrayList(DrawList.AssetUpload),
) !void {
    const files = try gpa.alloc([]const u8, Shader.Kind.count);
    for (std.enums.values(Shader.Kind), files) |kind, *file| file.* = Shader.get(kind).path;

    self.* = .{
        .gpa = gpa,
        .spirv = @splat(null),
        .pending = pending,
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

    // A reload before the backend drained the queue would leave the freed bytes in an
    // undrained row, so rewrite that row rather than appending a second one for this kind.
    const kind: Shader.Kind = @enumFromInt(index);
    for (self.pending.items) |*upload| {
        if (upload.* != .shader or upload.shader.kind != kind) continue;
        upload.shader.spirv = bytes;
        return;
    }
    try self.pending.append(self.gpa, .{ .shader = .{ .kind = kind, .spirv = bytes } });
}

fn unload(loader: *Loader, index: usize) void {
    const self: *ShaderSource = @fieldParentPtr("interface", loader);
    _ = index;
    _ = self;
    // Nothing to drop here: the bytes stay owned until the next load replaces them, and
    // the GPU objects are the backend's to destroy when it applies the next upload.
}
