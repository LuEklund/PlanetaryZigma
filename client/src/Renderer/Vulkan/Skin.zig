const std = @import("std");
const nz = @import("shared").numz;

name: []const u8,
inverse_bind_matrices: ?std.ArrayList(nz.Mat4x4(f32)),
joints: []usize,

pub fn init(
    gpa: std.mem.Allocator,
    name: []const u8,
    inversse_bind_matrices: ?[]nz.Mat4x4(f32),
    joints: []usize,
) !@This() {
    return .{
        .name = try gpa.dupe(u8, name),
        .inverse_bind_matrices = if (inversse_bind_matrices) |matrices| .fromOwnedSlice(matrices) else null,
        .joints = joints,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    gpa.free(self.name);
    if (self.inverse_bind_matrices) |*matrices| matrices.deinit(gpa);
    gpa.free(self.joints);
}
