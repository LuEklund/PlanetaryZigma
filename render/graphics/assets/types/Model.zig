const Model = @This();

const std = @import("std");
const nz = @import("numz");
const Node = @import("Node.zig");
const AnimationClip = @import("AnimationClip.zig");
const gltf = @import("gltf.zig");

surfaces: std.ArrayList(Surface),
mesh_handles: []usize,
nodes: std.ArrayList(Node),
node_names: [][]const u8,
clips: []AnimationClip,
skins: []Skin,

pub const empty: Model = .{
    .mesh_handles = &.{},
    .surfaces = .empty,
    .nodes = .empty,
    .node_names = &.{},
    .clips = &.{},
    .skins = &.{},
};

const Surface = struct {
    mesh_id: usize,
    model_matrix: nz.Mat4x4(f32),
};

pub const Skin = struct {
    name: []const u8,
    inverse_bind_matrices: ?[]nz.Mat4x4(f32),
    joints: []usize,

    pub fn init(gpa: std.mem.Allocator, skin_name: []const u8, inverse_bind_matrices: ?[]nz.Mat4x4(f32), joints: []usize) !Skin {
        return .{
            .name = try gpa.dupe(u8, skin_name),
            .inverse_bind_matrices = inverse_bind_matrices,
            .joints = joints,
        };
    }

    pub fn deinit(self: *Skin, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.inverse_bind_matrices) |matrices| gpa.free(matrices);
        gpa.free(self.joints);
    }
};

pub fn isEmpty(self: *const Model) bool {
    return self.surfaces.items.len == 0 and self.nodes.items.len == 0;
}

pub fn nodeIndex(self: *const Model, name: []const u8) ?usize {
    for (self.node_names, 0..) |node_name, index| {
        if (std.mem.eql(u8, node_name, name)) return index;
    }
    return null;
}

pub fn isSkinned(self: *const Model) bool {
    return self.skins.len > 0;
}

pub fn parseGlb(
    self: *Model,
    comptime VertexType: type,
    gpa: std.mem.Allocator,
    glb: *const gltf.Glb,
) !gltf.UploadData(VertexType) {
    self.clear(gpa);

    const upload_data = try gltf.parseScene(VertexType, gpa, glb.gltf, glb.bin, &self.nodes, &self.node_names, &self.skins, &self.clips);

    computeMatrices(self.nodes.items);

    if (!self.isSkinned()) {
        for (self.nodes.items) |node| {
            const mesh_id = node.mesh_id orelse continue;
            try self.surfaces.append(gpa, .{ .mesh_id = mesh_id, .model_matrix = node.model_matrix });
        }
        self.nodes.clearAndFree(gpa);
    }

    return upload_data;
}

pub fn clipIndex(self: *const Model, name: []const u8) ?usize {
    for (self.clips, 0..) |clip, index| {
        if (std.mem.eql(u8, clip.name, name)) return index;
    }
    return null;
}

pub fn computeMatrices(nodes: []Node) void {
    for (nodes, 0..) |*node, node_index| {
        const local_matrix = node.getLocalMatrix();
        node.model_matrix = if (node.parent) |parent_index| blk: {
            std.debug.assert(parent_index < node_index);
            break :blk nodes[parent_index].model_matrix.mul(local_matrix);
        } else local_matrix;
    }
}

pub fn clear(self: *Model, gpa: std.mem.Allocator) void {
    for (self.node_names) |name| gpa.free(name);
    gpa.free(self.node_names);
    self.node_names = &.{};
    gpa.free(self.mesh_handles);
    self.mesh_handles = &.{};
    self.nodes.clearAndFree(gpa);
    for (self.clips) |*clip| clip.deinit(gpa);
    gpa.free(self.clips);
    self.clips = &.{};
    for (self.skins) |*skin| skin.deinit(gpa);
    gpa.free(self.skins);
    self.skins = &.{};
    self.surfaces.clearAndFree(gpa);
}

pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
    self.clear(gpa);
}
