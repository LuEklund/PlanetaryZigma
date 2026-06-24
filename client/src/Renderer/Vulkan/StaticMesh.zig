const std = @import("std");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Mesh = @import("Mesh.zig");
const Node = @import("Node.zig");
const RenderResources = @import("RenderResources.zig");
const AssetServer = @import("shared").AssetServer;
const gltf = @import("gltf.zig");

pub const Surface = struct {
    mesh_id: []const u8,
    local_matrix: nz.Mat4x4(f32),
};

device: Device,
vma: Vma,
render_resources: *RenderResources,
surfaces: std.ArrayList(Surface) = .empty,
offset: nz.Transform3D(f32) = .{},

fn init(
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

pub fn load(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    asset_server: *AssetServer,
    render_resources: *RenderResources,
    path: []const u8,
    offset: nz.Transform3D(f32),
) !*@This() {
    const self = try init(gpa, vma, device, render_resources, offset);
    try asset_server.loadAsset(@This(), self, path, loadAsset);
    return self;
}

fn loadAsset(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;

    const self: *@This() = @ptrCast(@alignCast(user_data));
    self.surfaces.clearRetainingCapacity();

    var glb = try gltf.readGlb(gpa, io, file);
    defer glb.deinit(gpa);
    const gltf_loaded = glb.gltf;
    const bin = glb.bin;

    var nodes: std.ArrayList(Node) = .empty;
    var top_nodes: std.ArrayList(usize) = .empty;
    defer {
        for (nodes.items) |*node| node.deinit(gpa);
        nodes.deinit(gpa);
        top_nodes.deinit(gpa);
    }

    try gltf.parseScene(Mesh.StaticVertex, gpa, self.vma, self.device, self.render_resources, gltf_loaded, bin, &nodes, &top_nodes);

    for (nodes.items) |node| {
        const mesh_id = node.mesh_id orelse continue;
        try self.surfaces.append(gpa, .{ .mesh_id = mesh_id, .local_matrix = node.world_matrix });
    }
}

pub fn fromMesh(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    render_resources: *RenderResources,
    name: []const u8,
    vertices: []const Mesh.StaticVertex,
    indices: []const u32,
    offset: nz.Transform3D(f32),
) !*@This() {
    const mesh = try Mesh.init(
        gpa,
        vma,
        name,
        device,
        Mesh.StaticVertex,
        vertices,
        indices,
        &.{.{
            .index_start = 0,
            .index_count = @intCast(indices.len),
            .material_name = null,
        }},
    );

    try render_resources.meshes.put(gpa, mesh.name, mesh);
    const self = try init(gpa, vma, device, render_resources, offset);
    try self.surfaces.append(gpa, .{ .mesh_id = mesh.name, .local_matrix = nz.Mat4x4(f32).identity });
    return self;
}
