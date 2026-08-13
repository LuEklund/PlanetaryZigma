const AnimationClip = @This();

const std = @import("std");
const nz = @import("numz");

const Sampler = struct {
    inputs: []f32,
    outputs: []nz.Vec4(f32),
};

const Channel = struct {
    path: enum { translation, rotation, scale },
    node: usize,
    sampler_index: u32,
};

name: []const u8,
samplers: []Sampler,
channels: []Channel,
start: f32,
end: f32,

pub fn init(gpa: std.mem.Allocator, name: []const u8, sampler_count: usize, channel_count: usize) !AnimationClip {
    return .{
        .name = try gpa.dupe(u8, name),
        .samplers = try gpa.alloc(Sampler, sampler_count),
        .channels = try gpa.alloc(Channel, channel_count),
        .start = std.math.floatMax(f32),
        .end = std.math.floatMin(f32),
    };
}

pub fn deinit(self: *AnimationClip, gpa: std.mem.Allocator) void {
    gpa.free(self.name);
    for (self.samplers) |sampler| {
        gpa.free(sampler.inputs);
        gpa.free(sampler.outputs);
    }
    gpa.free(self.samplers);
    gpa.free(self.channels);
}
