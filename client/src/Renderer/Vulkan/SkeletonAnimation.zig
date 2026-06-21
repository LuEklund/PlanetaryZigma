const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;
const Model = @import("GltfModel.zig");
const Node = @import("Node.zig");
const Buffer = @import("Buffer.zig");

nodes: []Node,
buffers: []Buffer,
model: *Model,
curremt_time: f32 = 0,
active: usize = 0,
default: usize = 0,
loop: bool = true,

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device, model: *Model) !@This() {
    const nodes = try gpa.alloc(Node, model.nodes.items.len);
    for (model.nodes.items, nodes) |src, *dst| {
        dst.* = src;
        dst.children = try src.children.clone(gpa);
    }
    const buffers = try gpa.alloc(Buffer, model.skins.items.len);
    for (model.skins.items, buffers) |skin, *buf| {
        buf.* = try .init(
            device,
            vma,
            nz.Mat4x4(f32),
            skin.inverse_bind_matrices.?.items.len,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
            .{
                .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            },
        );
    }

    return .{ .nodes = nodes, .model = model, .buffers = buffers };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    for (self.nodes) |*node| node.deinit(gpa);
    gpa.free(self.nodes);
    for (self.buffers) |*buffer| buffer.deinit(vma);
    gpa.free(self.buffers);
}
