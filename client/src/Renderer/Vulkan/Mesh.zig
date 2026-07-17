const Mesh = @This();

const std = @import("std");
const shared = @import("shared");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const Vma = @import("Vma.zig");

pub const box = @import("Mesh/box.zig");
pub const explosion_particle = @import("Mesh/explosion_particle.zig");

surfaces: std.ArrayList(GeoSurface),
index_buffer: Buffer,
vertex_buffer: Buffer,
name: []const u8,

pub const StaticVertex = shared.StaticVertex;
pub const SkinnedVertex = shared.SkinnedVertex;

pub const GeoSurface = struct {
    index_start: u32,
    index_count: u32,
    material_index: ?usize,
};

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    name: []const u8,
    device: Device,
    comptime VertexType: type,
    vertices: []const VertexType,
    indices: []const u32,
    surfaces: []const GeoSurface,
) !Mesh {
    var vertex_buffer: Buffer = try .init(
        device,
        vma,
        VertexType,
        vertices.len,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT_KHR,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    vertex_buffer.copy(VertexType, vertices);

    var index_buffer: Buffer = try .init(
        device,
        vma,
        u32,
        indices.len,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT_KHR,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    index_buffer.copy(u32, indices);

    var allocated_surfaces: std.ArrayList(GeoSurface) = try .initCapacity(gpa, surfaces.len);
    allocated_surfaces.appendSliceAssumeCapacity(surfaces);

    return .{
        .index_buffer = index_buffer,
        .vertex_buffer = vertex_buffer,
        .surfaces = allocated_surfaces,
        .name = try gpa.dupe(u8, name),
    };
}

pub fn deinit(self: *Mesh, gpa: std.mem.Allocator, vma: Vma) void {
    self.index_buffer.deinit(vma);
    self.vertex_buffer.deinit(vma);
    gpa.free(self.name);
    self.surfaces.deinit(gpa);
}
