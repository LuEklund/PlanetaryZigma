const std = @import("std");
const nz = @import("shared").numz;
const Node = @import("Node.zig");
const Interpolation = @import("zgltf").Interpolation;
const AnimationPathCore = @import("zgltf").AnimationPathCore;

const Sampler = struct {
    interpolation: Interpolation,
    inputs: std.ArrayList(f32) = .empty,
    outputs: std.ArrayList(nz.Vec4(f32)) = .empty,

    pub fn init(gpa: std.mem.Allocator, interpolation: Interpolation, num_inputs: usize, num_outputs: usize) !@This() {
        return .{
            .interpolation = interpolation,
            .inputs = try .initCapacity(gpa, num_inputs),
            .outputs = try .initCapacity(gpa, num_outputs),
        };
    }
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
    }
};

const Channel = struct {
    path: AnimationPathCore,
    node: ?u32,
    sampler_index: u32,
};

name: []const u8,
samplers: std.ArrayList(Sampler),
channels: std.ArrayList(Channel),
start: f32 = std.math.floatMax(f32),
end: f32 = std.math.floatMin(f32),

pub fn init(gpa: std.mem.Allocator, name: []const u8, num_samplers: usize, num_channels: usize) !@This() {
    return .{
        .name = try gpa.dupe(u8, name),
        .channels = try .initCapacity(gpa, num_channels),
        .samplers = try .initCapacity(gpa, num_samplers),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    gpa.free(self.name);
    self.channels.deinit(gpa);
    for (self.samplers.items) |*sampler| sampler.deinit(gpa);
    self.samplers.deinit(gpa);
}
