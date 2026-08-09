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
pending: std.ArrayList(DrawList.ShaderUpload),
interface: Loader,

pub fn init(self: *ShaderSource, gpa: std.mem.Allocator, asset_server: *AssetServer) !void {
    const files = try gpa.alloc([]const u8, Shader.Kind.count);
    for (std.enums.values(Shader.Kind), files) |kind, *file| file.* = Shader.get(kind).path;

    self.* = .{
        .gpa = gpa,
        .spirv = @splat(null),
        .pending = .empty,
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
    self.pending.deinit(self.gpa);
    self.gpa.free(self.interface.files);
}

/// Valid until the next `consumed()`; the backend reads these during renderUpdate.
pub fn uploads(self: *const ShaderSource) []const DrawList.ShaderUpload {
    return self.pending.items;
}

pub fn consumed(self: *ShaderSource) void {
    self.pending.clearRetainingCapacity();
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

    // A reload before the backend drained the previous bytes would leave a stale pointer
    // in `pending`, so replace that row rather than appending a second one.
    if (self.spirv[index]) |old| {
        for (self.pending.items) |*upload| {
            if (upload.spirv.ptr != old.ptr) continue;
            upload.spirv = bytes;
            break;
        }
        self.gpa.free(old);
    }
    self.spirv[index] = bytes;

    const kind: Shader.Kind = @enumFromInt(index);
    for (self.pending.items) |upload| if (upload.kind == kind) return;
    try self.pending.append(self.gpa, .{ .kind = kind, .spirv = bytes });
}

fn unload(loader: *Loader, index: usize) void {
    const self: *ShaderSource = @fieldParentPtr("interface", loader);
    _ = index;
    _ = self;
    // Nothing to drop here: the bytes stay owned until the next load replaces them, and
    // the GPU objects are the backend's to destroy when it applies the next upload.
}
