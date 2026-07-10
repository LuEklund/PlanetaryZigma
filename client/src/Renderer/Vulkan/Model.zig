const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Mesh = @import("Mesh.zig");
const Node = @import("Node.zig");
const Skin = @import("Skin.zig");
const AnimationClip = @import("AnimationClip.zig");
const Resources = @import("Resources.zig");
const gltf = @import("gltf.zig");

pub const Kind = enum {
    unknown,
    player,
    planet,
    bullet,
    teleporter,
    tubloid,
    tubloida,
    wizard,
    health,
    speed,
    damage,
    attack_speed,

    pub fn fromKind(kind: shared.Entity.Kind) Kind {
        return switch (kind) {
            .unknown => .unknown,
            .player => .player,
            .planet => .planet,
            .bullet => .bullet,
            .teleporter => .teleporter,
            .enemy => |enemy_kind| switch (enemy_kind) {
                .tubloid => .tubloid,
                .tubloida => .tubloida,
                .wizard => .wizard,
            },
            .item => |item_kind| switch (item_kind) {
                .health => .health,
                .speed => .speed,
                .damage => .damage,
                .attack_speed => .attack_speed,
            },
        };
    }

    pub fn spec(kind: Kind) Spec {
        const face_camera = nz.Quat(f32).angleAxis(std.math.pi, .{ 0, 1, 0 });
        const player_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.8, 0 }, .rotation = face_camera };
        const enemy_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.6, 0 }, .rotation = face_camera };
        return switch (kind) {
            .unknown, .planet, .bullet => .{ .path = null, .skinned = false, .clip_names = null },
            .player => .{
                .path = "objects/BenBozo.glb",
                .offset = player_offset,
                .skinned = true,
                .clip_names = .{
                    .idle = "Idle",
                    .walk = "Run",
                    .attack = "shoot",
                },
                .look_node_names = .{ .spine = "mixamorig:Spine2", .neck = "mixamorig:Neck", .head = null },
                .overlay_root_name = "mixamorig:Spine1",
            },
            .teleporter => .{ .path = "objects/pillar.glb", .skinned = false, .clip_names = null },
            .tubloid => .{ .path = "objects/Tubloid.glb", .offset = enemy_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack" } },
            .tubloida => .{ .path = "objects/Tubloida.glb", .offset = enemy_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack_range" } },
            .wizard => .{ .path = "objects/Wizard.glb", .offset = enemy_offset, .skinned = true, .clip_names = .{ .idle = null, .walk = "Walking", .attack = "Summon" } },
            .health => .{ .path = "objects/oxigen_tank.glb", .skinned = false, .clip_names = null },
            .speed => .{ .path = "objects/energy_drink.glb", .skinned = false, .clip_names = null },
            .damage => .{ .path = "objects/damage.glb", .skinned = false, .clip_names = null },
            .attack_speed => .{ .path = "objects/attack_speed.glb", .skinned = false, .clip_names = null },
        };
    }
};

const ClipNames = struct {
    idle: ?[]const u8,
    walk: []const u8,
    attack: []const u8,
};

const LookNodeNames = struct {
    spine: ?[]const u8,
    neck: ?[]const u8,
    head: ?[]const u8,
};

const Spec = struct {
    path: ?[]const u8,
    offset: nz.Transform3D(f32) = .{},
    skinned: bool,
    clip_names: ?ClipNames,
    look_node_names: ?LookNodeNames = null,
    overlay_root_name: ?[]const u8 = null,
};

const Surface = struct {
    mesh_id: usize,
    model_matrix: nz.Mat4x4(f32),
};

surfaces: std.ArrayList(Surface),
nodes: std.ArrayList(Node),
clips: []AnimationClip,
skins: []Skin,
look_nodes: []usize,
overlay_mask: ?[]bool,
state_clips: std.EnumArray(shared.Entity.State, usize),
offset: nz.Transform3D(f32),

pub const empty: @This() = .{
    .surfaces = .empty,
    .nodes = .empty,
    .clips = &.{},
    .skins = &.{},
    .look_nodes = &.{},
    .overlay_mask = null,
    .state_clips = .initFill(0),
    .offset = .{},
};

pub fn isEmpty(self: *const @This()) bool {
    return self.surfaces.items.len == 0 and self.nodes.items.len == 0;
}

pub fn isSkinned(self: *const @This()) bool {
    return self.skins.len > 0;
}

pub fn loadGlb(
    self: *@This(),
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    vma: Vma,
    device: Device,
    resources: *Resources,
    spec: Spec,
) !void {
    self.clear(gpa);

    var glb = try gltf.readGlb(gpa, io, file);
    defer glb.deinit(gpa);

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
        try gltf.parseScene(Mesh.SkinnedVertex, gpa, vma, device, resources, glb.gltf, glb.bin, &self.nodes, &self.skins, &self.clips, look_node_names, &self.look_nodes, spec.overlay_root_name, &overlay_root);
        if (spec.overlay_root_name != null) {
            const overlay_mask = try gpa.alloc(bool, self.nodes.items.len);
            for (self.nodes.items, overlay_mask, 0..) |node, *masked, node_index| {
                masked.* = node_index == overlay_root or if (node.parent) |parent| overlay_mask[parent] else false;
            }
            self.overlay_mask = overlay_mask;
        }
    } else {
        try gltf.parseScene(Mesh.StaticVertex, gpa, vma, device, resources, glb.gltf, glb.bin, &self.nodes, null, null, null, null, null, null);
    }
    computeMatrices(self.nodes.items);

    if (spec.skinned) {
        if (spec.clip_names) |clip_names| {
            const walk_index = try self.clipIndex(clip_names.walk, spec);
            const idle_index = if (clip_names.idle) |idle_name| try self.clipIndex(idle_name, spec) else walk_index;
            const attack_index = try self.clipIndex(clip_names.attack, spec);
            self.state_clips = .init(.{
                .idle = idle_index,
                .walk = walk_index,
                .attack = attack_index,
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
    self.offset = spec.offset;
}

fn clipIndex(self: *const @This(), name: []const u8, spec: Spec) !usize {
    for (self.clips, 0..) |clip, index| {
        if (std.mem.eql(u8, clip.name, name)) return index;
    }
    std.log.err("clip \"{s}\" not found in {s}; clips in this file:", .{ name, spec.path.? });
    for (self.clips) |clip| std.log.err("  \"{s}\"", .{clip.name});
    std.log.err("in Model.Kind.spec assign null or one of these", .{});
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

pub fn clear(self: *@This(), gpa: std.mem.Allocator) void {
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

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.clear(gpa);
}
