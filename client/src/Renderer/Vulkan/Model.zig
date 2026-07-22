const Model = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Mesh = @import("Mesh.zig");
const Node = @import("../../asset/Node.zig");
const Skin = @import("../../asset/Skin.zig");
const AnimationClip = @import("../../asset/AnimationClip.zig");
const Resources = @import("Resources.zig");
const gltf = @import("../../asset/gltf.zig");

pub const Spec = shared.entity.ModelSpec;

//NOTE: store meta data about clip duration?
pub const Handle = enum(u32) {
    default = 0,
    _,

    pub fn index(self: Handle) usize {
        return @intFromEnum(self);
    }
};

surfaces: std.ArrayList(Surface),
nodes: std.ArrayList(Node),
clips: []AnimationClip,
skins: []Skin,
look_nodes: []usize,
overlay_mask: ?[]bool,
state_clips: std.EnumArray(shared.entity.State, usize),

pub const empty: Model = .{
    .surfaces = .empty,
    .nodes = .empty,
    .clips = &.{},
    .skins = &.{},
    .look_nodes = &.{},
    .overlay_mask = null,
    .state_clips = .initFill(0),
};

const Surface = struct {
    mesh_id: usize,
    model_matrix: nz.Mat4x4(f32),
};

pub fn isEmpty(self: *const Model) bool {
    return self.surfaces.items.len == 0 and self.nodes.items.len == 0;
}

pub fn isSkinned(self: *const Model) bool {
    return self.skins.len > 0;
}

pub fn loadGlb(
    self: *Model,
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    resources: *Resources,
    spec: Spec,
) !void {
    self.clear(gpa);

    var glb: gltf.Glb = try .read(gpa, io, file);
    defer glb.deinit(gpa);

    var base_mesh_index: usize = 0;
    if (spec.skinned) {
        var look_node_name_buffer: [3][]const u8 = undefined;
        var look_node_count: usize = 0;
        if (spec.look_node_names) |look_node_names| {
            inline for (.{ look_node_names.spine, look_node_names.neck, look_node_names.head }) |maybe_node_name| {
                if (maybe_node_name) |node_name| {
                    look_node_name_buffer[look_node_count] = node_name;
                    look_node_count += 1;
                }
            }
        }
        const look_node_names: ?[]const []const u8 = if (look_node_count > 0) look_node_name_buffer[0..look_node_count] else null;
        var overlay_root: usize = undefined;
        var upload_data = try gltf.parseScene(Mesh.SkinnedVertex, gpa, glb.gltf, glb.bin, &self.nodes, &self.skins, &self.clips, look_node_names, &self.look_nodes, spec.overlay_root_name, &overlay_root);
        defer upload_data.deinit(gpa);
        base_mesh_index = try resources.uploadModel(gpa, Mesh.SkinnedVertex, upload_data, spec.key);
        if (spec.overlay_root_name != null) {
            const overlay_mask = try gpa.alloc(bool, self.nodes.items.len);
            for (self.nodes.items, overlay_mask, 0..) |node, *masked, node_index| {
                masked.* = node_index == overlay_root or if (node.parent) |parent| overlay_mask[parent] else false;
            }
            self.overlay_mask = overlay_mask;
        }
    } else {
        var upload_data = try gltf.parseScene(Mesh.StaticVertex, gpa, glb.gltf, glb.bin, &self.nodes, null, null, null, null, null, null);
        defer upload_data.deinit(gpa);
        base_mesh_index = try resources.uploadModel(gpa, Mesh.StaticVertex, upload_data, spec.key);
    }
    for (self.nodes.items) |*node| {
        if (node.mesh_id) |mesh_id| node.mesh_id = base_mesh_index + mesh_id;
    }
    computeMatrices(self.nodes.items);

    if (spec.skinned) {
        if (spec.clip_names) |clip_names| {
            const walk_index = try self.createClipIndex(clip_names.walk, spec);
            const idle_index = if (clip_names.idle) |idle_name| try self.createClipIndex(idle_name, spec) else walk_index;
            const attack_index = try self.createClipIndex(clip_names.attack, spec);
            const death_index = if (clip_names.death) |death_name| try self.createClipIndex(death_name, spec) else walk_index;
            self.state_clips = .init(.{
                .idle = idle_index,
                .walk = walk_index,
                .attack = attack_index,
                .death = death_index,
            });
        }
    } else {
        for (self.nodes.items) |node| {
            const mesh_id = node.mesh_id orelse continue;
            try self.surfaces.append(gpa, .{ .mesh_id = mesh_id, .model_matrix = node.model_matrix });
        }
        for (self.nodes.items) |*node| node.deinit(gpa);
        self.nodes.clearAndFree(gpa);
    }
}

fn createClipIndex(self: *const Model, name: []const u8, spec: Spec) !usize {
    for (self.clips, 0..) |clip, index| {
        if (std.mem.eql(u8, clip.name, name)) return index;
    }
    std.log.err("clip \"{s}\" not found in {s}; clips in this file:", .{ name, spec.key });
    for (self.clips) |clip| std.log.err("  \"{s}\"", .{clip.name});
    std.log.err("in the model spec assign null or one of these", .{});
    return error.ClipNotFound;
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
    for (self.nodes.items) |*node| node.deinit(gpa);
    self.nodes.clearAndFree(gpa);
    for (self.clips) |*clip| clip.deinit(gpa);
    gpa.free(self.clips);
    self.clips = &.{};
    for (self.skins) |*skin| skin.deinit(gpa);
    gpa.free(self.skins);
    self.skins = &.{};
    gpa.free(self.look_nodes);
    self.look_nodes = &.{};
    if (self.overlay_mask) |overlay_mask| gpa.free(overlay_mask);
    self.overlay_mask = null;
    self.surfaces.clearAndFree(gpa);
}

pub fn deinit(self: *Model, gpa: std.mem.Allocator) void {
    self.clear(gpa);
}
