const SkeletonInstance = @This();

const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Model = @import("../../asset/Model.zig");
const Mesh = @import("Mesh.zig");
const Node = @import("../../asset/Node.zig");
const Buffer = @import("Buffer.zig");

nodes: []Node,
meshes: []Mesh,
fade_joints: []JointTransform,
fade_time: f32,
joint_matrices: []JointMatrices,
model: *Model,
player: AnimationPlayer = .{},
overlay: ?AnimationPlayer,

pub const fade_duration: f32 = 0.15;

pub const AnimationPlayer = struct {
    current_time: f32 = 0,
    active: usize = 0,
};

pub const JointMatrices = struct {
    cpu: []nz.Mat4x4(f32),
    gpu: Buffer,
};

pub const JointTransform = struct {
    translation: nz.Vec3(f32),
    rotation: nz.Quat(f32),
    scale: nz.Vec3(f32),
};

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device, model: *Model, meshes: []Mesh) !SkeletonInstance {
    const nodes = try gpa.alloc(Node, model.nodes.items.len);
    for (model.nodes.items, nodes) |src, *dst| {
        dst.* = src;
        dst.children = try src.children.clone(gpa);
    }
    const fade_joints = try gpa.alloc(JointTransform, model.nodes.items.len);
    const joint_matrices = try gpa.alloc(JointMatrices, model.skins.len);
    for (model.skins, joint_matrices) |skin, *matrices| {
        matrices.cpu = try gpa.alloc(nz.Mat4x4(f32), skin.inverse_bind_matrices.?.len);
        matrices.gpu = try .init(
            device,
            vma,
            nz.Mat4x4(f32),
            skin.inverse_bind_matrices.?.len,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
            .{
                .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            },
        );
    }

    return .{ .nodes = nodes, .meshes = meshes, .fade_joints = fade_joints, .fade_time = 0, .model = model, .joint_matrices = joint_matrices, .overlay = null };
}

pub fn deinit(self: *SkeletonInstance, gpa: std.mem.Allocator, vma: Vma) void {
    for (self.nodes) |*node| node.deinit(gpa);
    gpa.free(self.nodes);
    gpa.free(self.fade_joints);
    for (self.joint_matrices) |*matrices| {
        gpa.free(matrices.cpu);
        matrices.gpu.deinit(vma);
    }
    gpa.free(self.joint_matrices);
}

pub fn startFade(self: *SkeletonInstance) void {
    for (self.nodes, self.fade_joints) |node, *pose| {
        pose.* = .{ .translation = node.translation, .rotation = node.rotation, .scale = node.scale };
    }
    self.fade_time = fade_duration;
}

pub fn playClip(self: *SkeletonInstance, clip_index: usize) void {
    self.startFade();
    self.player = .{
        .current_time = self.model.clips[clip_index].start,
        .active = clip_index,
    };
}

pub fn playOverlay(self: *SkeletonInstance, clip_index: usize) void {
    self.startFade();
    self.overlay = .{
        .current_time = self.model.clips[clip_index].start,
        .active = clip_index,
    };
}
