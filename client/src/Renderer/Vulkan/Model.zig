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
        const player_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.8, 0 }, .rotation = face_camera, .scale = @splat(0.1) };
        const enemy_offset: nz.Transform3D(f32) = .{ .position = .{ 0, -0.6, 0 }, .rotation = face_camera };
        return switch (kind) {
            .unknown, .planet, .bullet => .{ .path = null, .offset = .{}, .skinned = false, .clip_names = null },
            .player => .{ .path = "objects/BenRun.glb", .offset = player_offset, .skinned = true, .clip_names = .{ .idle = "NlaTrack", .walk = "Walk", .attack = "NlaTrack.001" } },
            .teleporter => .{ .path = "objects/pillar.glb", .offset = .{}, .skinned = false, .clip_names = null },
            .tubloid => .{ .path = "objects/Tubloid.glb", .offset = enemy_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack" } },
            .tubloida => .{ .path = "objects/Tubloida.glb", .offset = enemy_offset, .skinned = true, .clip_names = .{ .idle = "idle", .walk = "walk", .attack = "attack_range" } },
            .wizard => .{ .path = "objects/Wizard.glb", .offset = enemy_offset, .skinned = true, .clip_names = .{ .idle = null, .walk = "Walking", .attack = "Summon" } },
            .health => .{ .path = "objects/oxigen_tank.glb", .offset = .{}, .skinned = false, .clip_names = null },
            .speed => .{ .path = "objects/energy_drink.glb", .offset = .{}, .skinned = false, .clip_names = null },
            .damage => .{ .path = "objects/damage.glb", .offset = .{}, .skinned = false, .clip_names = null },
            .attack_speed => .{ .path = "objects/attack_speed.glb", .offset = .{}, .skinned = false, .clip_names = null },
        };
    }
};

const ClipNames = struct {
    idle: ?[]const u8,
    walk: []const u8,
    attack: []const u8,
};

const Spec = struct {
    path: ?[]const u8,
    offset: nz.Transform3D(f32),
    skinned: bool,
    clip_names: ?ClipNames,
};

const Surface = struct {
    mesh_id: usize,
    local_matrix: nz.Mat4x4(f32),
};

const StateClip = struct {
    index: usize,
    loop: bool,
};

surfaces: std.ArrayList(Surface),
nodes: std.ArrayList(Node),
clips: []AnimationClip,
skins: []Skin,
state_clips: std.EnumArray(shared.Entity.State, StateClip),
offset: nz.Transform3D(f32),

pub const empty: @This() = .{
    .surfaces = .empty,
    .nodes = .empty,
    .clips = &.{},
    .skins = &.{},
    .state_clips = .initFill(.{ .index = 0, .loop = true }),
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
        try gltf.parseScene(Mesh.SkinnedVertex, gpa, vma, device, resources, glb.gltf, glb.bin, &self.nodes, &self.skins, &self.clips);
    } else {
        try gltf.parseScene(Mesh.StaticVertex, gpa, vma, device, resources, glb.gltf, glb.bin, &self.nodes, null, null);
    }
    computeWorldMatrices(self.nodes.items);

    if (spec.skinned) {
        if (spec.clip_names) |clip_names| {
            const walk_index = try self.clipIndex(clip_names.walk, spec);
            const idle_index = if (clip_names.idle) |idle_name| try self.clipIndex(idle_name, spec) else walk_index;
            const attack_index = try self.clipIndex(clip_names.attack, spec);
            self.state_clips = .init(.{
                .idle = .{ .index = idle_index, .loop = true },
                .walk = .{ .index = walk_index, .loop = true },
                .attack = .{ .index = attack_index, .loop = false },
            });
        }
    } else {
        for (self.nodes.items) |node| {
            const mesh_id = node.mesh_id orelse continue;
            try self.surfaces.append(gpa, .{ .mesh_id = mesh_id, .local_matrix = node.world_matrix });
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

pub fn computeWorldMatrices(nodes: []Node) void {
    for (nodes, 0..) |*node, node_index| {
        const local_matrix = node.getLocalMatrix();
        node.world_matrix = if (node.parent) |parent_index| blk: {
            std.debug.assert(parent_index < node_index);
            break :blk nodes[parent_index].world_matrix.mul(local_matrix);
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
    self.surfaces.clearAndFree(gpa);
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.clear(gpa);
}
