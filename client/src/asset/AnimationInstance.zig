const AnimationInstance = @This();

const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const Model = @import("Model.zig");
const Node = @import("Node.zig");

model_handle: ?Model.Handle,
state: shared.entity.State,
spawn_time: f32,
death_time: f32,
spawn_duration: f32,
death_duration: f32,
skeleton: ?Skeleton,

pub const fade_duration: f32 = 0.15;

pub const Player = struct {
    current_time: f32 = 0,
    active: usize = 0,
};

pub const JointTransform = struct {
    translation: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    scale: nz.Vec3(f32),
};

pub const Skeleton = struct {
    nodes: []Node,
    fade_joints: []JointTransform,
    fade_time: f32,
    joint_matrices: [][]nz.Mat4x4(f32),
    player: Player,
    overlay: ?Player,

    pub fn init(gpa: std.mem.Allocator, model: *Model) !Skeleton {
        const nodes = try gpa.alloc(Node, model.nodes.items.len);
        for (model.nodes.items, nodes) |source, *node| {
            node.* = source;
            node.children = try source.children.clone(gpa);
        }
        const fade_joints = try gpa.alloc(JointTransform, model.nodes.items.len);
        const joint_matrices = try gpa.alloc([]nz.Mat4x4(f32), model.skins.len);
        for (model.skins, joint_matrices) |skin, *matrices| {
            matrices.* = try gpa.alloc(nz.Mat4x4(f32), skin.inverse_bind_matrices.?.len);
            @memset(matrices.*, .identity);
        }
        return .{
            .nodes = nodes,
            .fade_joints = fade_joints,
            .fade_time = 0,
            .joint_matrices = joint_matrices,
            .player = .{},
            .overlay = null,
        };
    }

    pub fn deinit(self: *Skeleton, gpa: std.mem.Allocator) void {
        for (self.nodes) |*node| node.deinit(gpa);
        gpa.free(self.nodes);
        gpa.free(self.fade_joints);
        for (self.joint_matrices) |matrices| gpa.free(matrices);
        gpa.free(self.joint_matrices);
    }

    pub fn startFade(self: *Skeleton) void {
        for (self.nodes, self.fade_joints) |node, *pose| {
            pose.* = .{ .translation = node.translation, .rotation = node.rotation, .scale = node.scale };
        }
        self.fade_time = fade_duration;
    }

    pub fn playClip(self: *Skeleton, model: *const Model, clip_index: usize) void {
        self.startFade();
        self.player = .{
            .current_time = model.clips[clip_index].start,
            .active = clip_index,
        };
    }

    pub fn playOverlay(self: *Skeleton, model: *const Model, clip_index: usize) void {
        self.startFade();
        self.overlay = .{
            .current_time = model.clips[clip_index].start,
            .active = clip_index,
        };
    }
};

pub fn init(gpa: std.mem.Allocator, model_handle: ?Model.Handle, model: ?*Model) !AnimationInstance {
    return .{
        .model_handle = model_handle,
        .state = .idle,
        .spawn_time = 0,
        .death_time = 0,
        .spawn_duration = if (model) |file_model| file_model.spawn_duration else 0,
        .death_duration = if (model) |file_model| file_model.death_duration else 0,
        .skeleton = if (model) |file_model|
            (if (file_model.isSkinned()) try Skeleton.init(gpa, file_model) else null)
        else
            null,
    };
}

pub fn deinit(self: *AnimationInstance, gpa: std.mem.Allocator) void {
    if (self.skeleton) |*skeleton| skeleton.deinit(gpa);
}

pub fn spawnDuration(self: *const AnimationInstance) f32 {
    return self.spawn_duration;
}

pub fn deathDuration(self: *const AnimationInstance) f32 {
    return self.death_duration;
}

pub fn deathDone(self: *const AnimationInstance) bool {
    return self.death_time >= self.deathDuration();
}
