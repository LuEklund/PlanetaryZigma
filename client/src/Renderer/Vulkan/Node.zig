const std = @import("std");
const nz = @import("shared").numz;

parent: ?usize = null,
children: std.ArrayList(usize) = .empty,
mesh_id: ?usize = null,
translation: nz.Vec3(f32) = @splat(0),
scale: nz.Vec3(f32) = @splat(1),
rotation: nz.quat.Hamiltonian(f32) = .identity,
skin_id: i32 = -1,
world_matrix: nz.Mat4x4(f32) = undefined,

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.children.deinit(gpa);
}

pub fn getLocalMatrix(self: *const @This()) nz.Mat4x4(f32) {
    return nz.Mat4x4(f32).translate(self.translation)
        .mul(self.rotation.toMat4x4())
        .mul(.scale(self.scale));
}
