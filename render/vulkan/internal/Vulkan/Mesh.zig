const Mesh = @This();

const std = @import("std");
const shared = @import("shared");
const vk = @import("vulkan");
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const GpuMemory = @import("GpuMemory.zig");
const contract = @import("renderer_contract");

surfaces: []Surface,
opaque_count: u32,
index_buffer: Buffer,
vertex_buffer: Buffer,
name: []const u8,

pub const StaticVertex = shared.StaticVertex;
pub const SkinnedVertex = shared.SkinnedVertex;

pub const Surface = struct {
    index_start: u32,
    index_count: u32,
    texture: contract.TextureHandle,
};

pub fn init(
    gpa: std.mem.Allocator,
    heap: *GpuMemory,
    name: []const u8,
    device: Device,
    comptime VertexType: type,
    vertices: []const VertexType,
    indices: []const u32,
    surfaces: []Surface,
    opaque_count: u32,
) !Mesh {
    var vertex_buffer: Buffer = try .init(
        device,
        heap,
        VertexType,
        vertices.len,
        .{ .storage_buffer_bit = true, .shader_device_address_bit = true },
    );
    errdefer vertex_buffer.deinit(heap);
    vertex_buffer.copy(VertexType, vertices);

    var index_buffer: Buffer = try .init(
        device,
        heap,
        u32,
        indices.len,
        .{ .index_buffer_bit = true, .shader_device_address_bit = true },
    );
    errdefer index_buffer.deinit(heap);
    index_buffer.copy(u32, indices);

    return .{
        .index_buffer = index_buffer,
        .vertex_buffer = vertex_buffer,
        .surfaces = surfaces,
        .name = try gpa.dupe(u8, name),
        .opaque_count = opaque_count,
    };
}

pub fn deinit(self: *Mesh, gpa: std.mem.Allocator, heap: *GpuMemory) void {
    self.index_buffer.deinit(heap);
    self.vertex_buffer.deinit(heap);
    gpa.free(self.name);
    gpa.free(self.surfaces);
}
