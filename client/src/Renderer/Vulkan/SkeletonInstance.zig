const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Model = @import("Model.zig");
const Node = @import("Node.zig");
const Buffer = @import("Buffer.zig");

pub const AnimationPlayer = struct {
    current_time: f32 = 0,
    active: usize = 0,
    loop: bool = true,
};

pub const JointMatrices = struct {
    cpu: []nz.Mat4x4(f32),
    gpu: Buffer,
};

nodes: []Node,
joint_matrices: []JointMatrices,
model: *Model,
player: AnimationPlayer = .{},

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device, model: *Model) !@This() {
    const nodes = try gpa.alloc(Node, model.nodes.items.len);
    for (model.nodes.items, nodes) |src, *dst| {
        dst.* = src;
        dst.children = try src.children.clone(gpa);
    }
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

    return .{ .nodes = nodes, .model = model, .joint_matrices = joint_matrices };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    for (self.nodes) |*node| node.deinit(gpa);
    gpa.free(self.nodes);
    for (self.joint_matrices) |*matrices| {
        gpa.free(matrices.cpu);
        matrices.gpu.deinit(vma);
    }
    gpa.free(self.joint_matrices);
}
