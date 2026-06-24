const std = @import("std");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Mesh = @import("Mesh.zig");
const RenderResources = @import("RenderResources.zig");

pub const Surface = struct {
    mesh_id: []const u8,
    local_matrix: nz.Mat4x4(f32),
};

device: Device,
vma: Vma,
render_resources: *RenderResources,
surfaces: std.ArrayList(Surface) = .empty,
offset: nz.Transform3D(f32) = .{},

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    render_resources: *RenderResources,
    offset: nz.Transform3D(f32),
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .vma = vma,
        .device = device,
        .render_resources = render_resources,
        .offset = offset,
    };
    return self;
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.surfaces.deinit(gpa);
    self.* = undefined;
    gpa.destroy(self);
}

pub fn fromMesh(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    render_resources: *RenderResources,
    name: []const u8,
    vertices: []const Mesh.Vertex,
    indices: []const u32,
    offset: nz.Transform3D(f32),
) !*@This() {
    const mesh = try Mesh.init(
        gpa,
        vma,
        name,
        device,
        Mesh.Vertex,
        vertices,
        indices,
        &.{.{
            .index_start = 0,
            .index_count = @intCast(indices.len),
            .material_name = null,
        }},
    );
    try render_resources.createMesh(gpa, mesh);
    const self = try init(gpa, vma, device, render_resources, offset);
    try self.surfaces.append(gpa, .{ .mesh_id = mesh.name, .local_matrix = nz.Mat4x4(f32).identity });
    return self;
}
